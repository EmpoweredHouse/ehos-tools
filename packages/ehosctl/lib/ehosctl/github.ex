defmodule Ehosctl.GitHub do
  @moduledoc """
  The releases of EHOS's components on GitHub, which say what exists and what changed (eh-os
  D-91, [releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)):

  | Component | Repository | Tag |
  | --- | --- | --- |
  | `ehosctl` | ehos-tools | `vX.Y.Z` |
  | `ehos_app` | ehos-tools | `ehos_app-vX.Y.Z` |
  | `ehos_design` | ehos-tools | `ehos_design-vX.Y.Z` |
  | `ehos` | eh-os | `vX.Y.Z` |
  | `eh_os_contract` | eh-os-contract | `vX.Y.Z` |

  A draft or a pre-release is left out, and so is a tag whose version has a pre-release part.
  Releases are ordered by their version, as SemVer orders it, not by when they were published.

  A repository's tags are read too (`tags/3`), for the commits they name: a release made before
  eh-os D-91, such as `ehos_app`'s before 0.7.0, is a tag alone, with no GitHub release or no
  `release.json`.

  Each release may carry `release.json` (`ehos.release/v1`), read by `release_json/2`, and its
  notes are the attached `notes.md` when there is one, else its description (`notes/2`): a
  release's description holds at most 125,000 characters, and eh-os-contract attaches its longer
  notes.

  GitHub's API is read with the token the developer already gives mise, `MISE_GITHUB_TOKEN`, else
  `GITHUB_TOKEN`, while the repositories are private. It is sent only to the API's own origin and
  never kept. An asset is downloaded through the API, which redirects to another host; that
  request carries no token. Without a token, a repository GitHub does not show is said to need one.

  Every answer is read no further than a bound of its own (`Ehosctl.HTTP.get/3`). Every function
  takes `:env`, `:timeout`, and for the tests `:github_api`, the API's origin, and `:allow_http`,
  which lets a redirect go to plain HTTP.
  """

  alias Ehosctl.HTTP
  alias Ehosctl.Output

  @api "https://api.github.com"

  @components %{
    "ehosctl" => {"EmpoweredHouse/ehos-tools", "v"},
    "ehos" => {"EmpoweredHouse/eh-os", "v"},
    "ehos_app" => {"EmpoweredHouse/ehos-tools", "ehos_app-v"},
    "ehos_design" => {"EmpoweredHouse/ehos-tools", "ehos_design-v"},
    "eh_os_contract" => {"EmpoweredHouse/eh-os-contract", "v"}
  }

  # A page of 100 releases with descriptions of up to 125,000 characters each could reach 12.5 MB;
  # `release.json` is a few hundred bytes; eh-os-contract's `notes.md` was 162 KB for 0.3.0.
  @max_page_bytes 16 * 1024 * 1024
  # A page of 100 tags is some 50 KB.
  @max_tags_page_bytes 1024 * 1024
  @max_release_json_bytes 64 * 1024
  @max_notes_bytes 2 * 1024 * 1024
  @max_compare_bytes 8 * 1024 * 1024
  @max_pages 10

  @type component :: String.t()

  @typedoc """
  A release: its component, version, tag, page on GitHub (`url`), when it was published, its
  description (`body`), the repository it is in, and its assets by name, each as its id.
  """
  @type release :: %{
          component: component(),
          version: String.t(),
          tag: String.t(),
          url: String.t(),
          published_at: String.t() | nil,
          body: String.t(),
          repository: String.t(),
          assets: %{String.t() => pos_integer()}
        }

  @typedoc "A component's tag: its component, version, tag, the commit it names, and repository."
  @type tag :: %{
          component: component(),
          version: String.t(),
          tag: String.t(),
          commit: String.t(),
          repository: String.t()
        }

  @type error :: {:error, Output.kind(), String.t()}

  @doc "The components whose releases this module reads, in the order `ehosctl` lists them."
  @spec components() :: [component()]
  def components, do: ~w(ehosctl ehos ehos_app eh_os_contract ehos_design)

  @doc """
  The repository a component is released from, `owner/name`.

      iex> Ehosctl.GitHub.repository("ehos_app")
      "EmpoweredHouse/ehos-tools"
  """
  @spec repository(component()) :: String.t()
  def repository(component), do: @components |> Map.fetch!(component) |> elem(0)

  @doc """
  The releases of `component`, newest first by version, or why GitHub did not say.
  """
  @spec releases(component(), keyword()) :: {:ok, [release()]} | error()
  def releases(component, opts) do
    with {:ok, listed, _whole_or_cut} <- list(repository(component), opts),
         do: {:ok, of(component, listed)}
  end

  @doc """
  Every release of `repository` that is neither a draft nor a pre-release, as GitHub lists them,
  newest first, following its pages up to #{@max_pages} of 100, and `:whole`, or `:cut` when
  more pages remain. `of/2` keeps those of one component; a repository that releases several is
  listed once for all of them.
  """
  @spec list(String.t(), keyword()) :: {:ok, [map()], :whole | :cut} | error()
  def list(repository, opts) do
    url = api(opts) <> "/repos/#{repository}/releases?per_page=100"
    pages(url, repository, {&listed/1, @max_page_bytes, fn _listed -> false end}, [], 0, opts)
  end

  @doc "How many releases of a repository `list/2` reads at most, before it says `:cut`."
  @spec max_listed() :: pos_integer()
  def max_listed, do: @max_pages * 100

  # Each item of a page is kept as `kept` says, from pages read no further than `max_bytes`, and
  # no further page is asked for once `enough?` holds of what is kept.
  defp pages(url, repository, {kept, max_bytes, enough?} = read, listed, count, opts) do
    with {:ok, answer} <- get(url, "application/vnd.github+json", max_bytes, opts),
         {:ok, page} <- decoded(answer, repository, opts) do
      listed = listed ++ Enum.flat_map(page, kept)

      case {enough?.(listed), next(answer.headers["link"], opts)} do
        {true, _next} ->
          {:ok, listed, :whole}

        {false, next} when is_binary(next) and count + 1 < @max_pages ->
          pages(next, repository, read, listed, count + 1, opts)

        {false, next} when is_binary(next) ->
          {:ok, listed, :cut}

        {false, nil} ->
          {:ok, listed, :whole}
      end
    end
  end

  defp decoded(%{status: 200, body: body}, repository, _opts) do
    case JSON.decode(body) do
      {:ok, page} when is_list(page) ->
        {:ok, page}

      _other ->
        {:error, :failed, "GitHub answered about #{repository} with something unreadable."}
    end
  end

  defp decoded(answer, repository, opts), do: refused(answer, repository, opts)

  # Only what a release is said with, of a release that is published, with its assets by name.
  defp listed(
         %{"tag_name" => tag, "draft" => false, "prerelease" => false, "html_url" => url} =
           release
       )
       when is_binary(tag) and is_binary(url) do
    if String.starts_with?(url, "https://github.com/") and Output.printable?(url) and
         Output.printable?(tag) do
      [
        %{
          tag: tag,
          url: url,
          published_at: moment(release["published_at"]),
          body: text(release["body"]) || "",
          assets:
            for(
              %{"name" => name, "id" => id} <- List.wrap(release["assets"]),
              is_binary(name) and is_integer(id) and id > 0,
              into: %{},
              do: {name, id}
            )
        }
      ]
    else
      []
    end
  end

  defp listed(_release), do: []

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  # A moment as GitHub gives it, ISO 8601, kept only when it is one: it is printed.
  defp moment(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _moment, _offset} -> value
      {:error, _reason} -> nil
    end
  end

  defp moment(_value), do: nil

  @doc """
  The releases of `component` among `listed` (`list/2`'s), newest first by version: those whose
  tag is the component's form with a version that has no pre-release part.
  """
  @spec of(component(), [map()]) :: [release()]
  def of(component, listed), do: versioned(component, listed)

  # Those of `listed` whose tag is `component`'s form with a version that has no pre-release
  # part, each with its version, newest first.
  defp versioned(component, listed) do
    {repository, prefix} = Map.fetch!(@components, component)

    listed
    |> Enum.flat_map(fn item ->
      with true <- String.starts_with?(item.tag, prefix),
           rest = String.replace_prefix(item.tag, prefix, ""),
           {:ok, %Version{pre: []} = version} <- Version.parse(rest) do
        [
          Map.merge(item, %{
            component: component,
            version: to_string(version),
            repository: repository
          })
        ]
      else
        _other -> []
      end
    end)
    |> Enum.sort_by(& &1.version, &(Version.compare(&1, &2) != :lt))
  end

  @doc """
  The tag of each `{component, commit}` in `wanted` that names that commit, all components of
  `repository`, or why GitHub did not say: a tag of the component's form with a version that has
  no pre-release part, as `of/2` keeps releases, the newest when several name it. GitHub names an
  annotated tag's commit, not the tag object, so either kind is the commit it tags.

  The repository's tags are listed once for all of `wanted`, a page of 100 at a time, until each
  is found or #{@max_pages} pages are read; `:cut` when more pages remain and one is not found,
  else `:whole`. A `{component, commit}` no tag names is left out.
  """
  @spec tags(String.t(), [{component(), String.t()}], keyword()) ::
          {:ok, %{{component(), String.t()} => tag()}, :whole | :cut} | error()
  def tags(repository, wanted, opts) do
    wanted = Enum.uniq(wanted)
    url = api(opts) <> "/repos/#{repository}/tags?per_page=100"
    enough? = &(map_size(found(wanted, &1)) == length(wanted))

    with {:ok, listed, whole_or_cut} <-
           pages(url, repository, {&tagged/1, @max_tags_page_bytes, enough?}, [], 0, opts),
         do: {:ok, found(wanted, listed), whole_or_cut}
  end

  defp found(wanted, listed) do
    for {component, commit} = one <- wanted,
        tag <-
          component |> versioned(listed) |> Enum.filter(&(&1.commit == commit)) |> Enum.take(1),
        into: %{},
        do: {one, tag}
  end

  # A tag GitHub lists, kept only with a name a terminal can print and a whole commit.
  defp tagged(%{"name" => name, "commit" => %{"sha" => commit}})
       when is_binary(name) and is_binary(commit) do
    if Output.printable?(name) and commit =~ ~r/\A[0-9a-f]{40}\z/,
      do: [%{tag: name, commit: commit}],
      else: []
  end

  defp tagged(_tag), do: []

  @doc """
  The `release.json` attached to `release`, decoded: `{:ok, nil}` for a release that carries
  none, as those made before eh-os D-91 do. An error, which says why, when it cannot be read, is
  not a JSON object, or is not this release's: its `schema` is not `ehos.release/v1`, or its
  `component` or `version` is not the release's.
  """
  @spec release_json(release(), keyword()) :: {:ok, map() | nil} | error()
  def release_json(release, opts) do
    with {:ok, bytes} when is_binary(bytes) <-
           asset(release, "release.json", @max_release_json_bytes, opts) do
      case JSON.decode(bytes) do
        {:ok, %{} = described} ->
          case unlike(described, release) do
            nil -> {:ok, described}
            why -> {:error, :failed, "The release.json of #{release.tag} #{why}."}
          end

        _other ->
          {:error, :failed, "The release.json of #{release.tag} is not a JSON object."}
      end
    end
  end

  # Why a release.json is not the release's, or `nil` when it is.
  defp unlike(described, release) do
    version =
      case Version.parse(to_string_or_nil(described["version"])) do
        {:ok, version} -> to_string(version)
        :error -> nil
      end

    cond do
      described["schema"] != "ehos.release/v1" ->
        "has the schema #{said(described["schema"])}, not ehos.release/v1"

      described["component"] != release.component ->
        "names #{said(described["component"])}, not #{release.component}"

      version != release.version ->
        "names version #{said(described["version"])}, not #{release.version}"

      true ->
        nil
    end
  end

  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(_value), do: ""

  defp said(nil), do: "nothing"
  defp said(value), do: Ehosctl.Refusal.shown(value)

  @doc """
  A release's notes: the attached `notes.md` when there is one, else its description.
  """
  @spec notes(release(), keyword()) :: {:ok, String.t()} | error()
  def notes(release, opts) do
    case asset(release, "notes.md", @max_notes_bytes, opts) do
      {:ok, nil} -> {:ok, release.body}
      {:ok, notes} -> {:ok, notes}
      error -> error
    end
  end

  # An asset is asked of the API, which answers with a redirect to where it is kept: that
  # request goes without the token, which is the API's alone.
  defp asset(release, name, max_bytes, opts) do
    case release.assets[name] do
      nil ->
        {:ok, nil}

      id ->
        url = api(opts) <> "/repos/#{release.repository}/releases/assets/#{id}"

        with {:ok, answer} <- get(url, "application/octet-stream", max_bytes, opts),
             {:ok, answer} <- followed(answer, max_bytes, opts) do
          case answer do
            %{status: 200, body: body} -> {:ok, body}
            answer -> refused(answer, release.repository, opts)
          end
        end
    end
  end

  defp followed(%{status: status, headers: %{"location" => location}}, max_bytes, opts)
       when status in [301, 302, 303, 307, 308] do
    schemes = if opts[:allow_http], do: ["https", "http"], else: ["https"]

    case URI.new(location) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(host) and host != "" ->
        if scheme in schemes,
          do: get(location, "application/octet-stream", max_bytes, opts),
          else: {:error, :failed, "GitHub sent an asset's download elsewhere than https."}

      _other ->
        {:error, :failed, "GitHub sent an asset's download to an address ehosctl cannot read."}
    end
  end

  defp followed(answer, _max_bytes, _opts), do: {:ok, answer}

  @doc """
  How `head` stands to `base`, two commits of `component`'s repository, as GitHub compares
  them: `"ahead"`, `"behind"`, `"identical"` or `"diverged"`, with how many commits `head` has
  that `base` has not (`ahead_by`) and the other way round (`behind_by`).
  """
  @spec compare(component(), String.t(), String.t(), keyword()) ::
          {:ok, %{status: String.t(), ahead_by: non_neg_integer(), behind_by: non_neg_integer()}}
          | error()
  def compare(component, base, head, opts) do
    repository = repository(component)

    if sha?(base) and sha?(head) do
      url = api(opts) <> "/repos/#{repository}/compare/#{base}...#{head}?per_page=1"

      with {:ok, answer} <- get(url, "application/vnd.github+json", @max_compare_bytes, opts) do
        with %{status: 200, body: body} <- answer,
             {:ok, %{"status" => status, "ahead_by" => ahead, "behind_by" => behind}}
             when status in ~w(ahead behind identical diverged) and is_integer(ahead) and
                    is_integer(behind) and ahead >= 0 and behind >= 0 <- JSON.decode(body) do
          {:ok, %{status: status, ahead_by: ahead, behind_by: behind}}
        else
          %{status: _} = answer -> refused(answer, repository, opts)
          _other -> {:error, :failed, "GitHub's comparison in #{repository} is unreadable."}
        end
      end
    else
      {:error, :invalid, "Only two commits can be compared."}
    end
  end

  defp sha?(text), do: text =~ ~r/\A[0-9a-f]{7,40}\z/

  @doc """
  The token GitHub's API is read with, and the variable it came from: `MISE_GITHUB_TOKEN`, else
  `GITHUB_TOKEN`; `nil` when neither holds one.

      iex> Ehosctl.GitHub.token(%{"GITHUB_TOKEN" => "ghp_x", "MISE_GITHUB_TOKEN" => ""})
      {"GITHUB_TOKEN", "ghp_x"}
  """
  @spec token(%{String.t() => String.t()}) :: {String.t(), String.t()} | nil
  def token(env) do
    Enum.find_value(~w(MISE_GITHUB_TOKEN GITHUB_TOKEN), fn name ->
      case env[name] do
        token when is_binary(token) and token != "" -> {name, String.trim(token)}
        _none -> nil
      end
    end)
  end

  # The token goes with a request to the API's own origin and with nothing else.
  defp get(url, accept, max_bytes, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    headers =
      [{"accept", accept}, {"user-agent", "ehosctl/#{Ehosctl.version()}"}] ++
        case {origin(url) == origin(api(opts)), token(env)} do
          {true, {_name, token}} ->
            [{"authorization", "Bearer " <> token}, {"x-github-api-version", "2022-11-28"}]

          {true, nil} ->
            [{"x-github-api-version", "2022-11-28"}]

          {false, _token} ->
            []
        end

    # EHOSCTL_CA_FILE and the CA kept for an installation (T-14) are an installation's: GitHub is
    # trusted through the system's alone, and a CA that will not do for EHOS does not stop a
    # command that reads only GitHub.
    HTTP.get(
      url,
      headers,
      opts
      |> Keyword.delete(:ca)
      |> Keyword.merge(
        env: Map.delete(env, "EHOSCTL_CA_FILE"),
        max_bytes: max_bytes,
        installation?: false
      )
    )
  end

  defp refused(%{status: status} = answer, repository, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    limited? = status in [403, 429] and answer.headers["x-ratelimit-remaining"] == "0"

    message =
      case {status, token(env)} do
        # Without a token GitHub allows 60 requests an hour, and says so with a 403.
        {status, _token} when limited? ->
          "GitHub's rate limit is used up (HTTP #{status}); try again later."

        {status, nil} when status in [401, 403, 404] ->
          # The same words for every repository, so a command that reads several says it once.
          "GitHub does not show EHOS's releases without a token, since their repositories are " <>
            "private. Set MISE_GITHUB_TOKEN or GITHUB_TOKEN, for example to `gh auth token`."

        {401, {name, _token}} ->
          "GitHub refused the token in #{name} (HTTP 401): it may have expired."

        {404, {name, _token}} ->
          "GitHub answered 404 for #{repository}: the token in #{name} cannot read it."

        {status, _token} when status in [403, 429] ->
          "GitHub refused to answer about #{repository} (HTTP #{status})."

        {status, _token} ->
          "GitHub answered HTTP #{status} about #{repository}."
      end

    {:error, :failed, message}
  end

  # The link whose relation is `next` (RFC 8288), when it is on the API's own origin: a page
  # anywhere else would be sent the token.
  defp next(nil, _opts), do: nil

  defp next(header, opts) do
    Regex.scan(~r/<([^>]*)>\s*;\s*rel="([^"]*)"/, header)
    |> Enum.find_value(fn [_, target, rel] ->
      if "next" in String.split(rel) and origin(target) == origin(api(opts)), do: target
    end)
  end

  defp api(opts), do: Keyword.get(opts, :github_api, @api)

  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} -> {scheme, host, port}
    end
  end
end

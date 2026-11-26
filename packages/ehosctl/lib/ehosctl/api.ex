defmodule Ehosctl.Api do
  @moduledoc """
  Calls to EHOS's API. What it tells a person's terminal about them
  ([eh-os `docs/terminal-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/terminal-api.md)):
  the roles they hold (`GET /api/v1/me/roles`) and the applications they may use, where each one is
  and what it grants them (`GET /api/v1/me/applications`); and for the commands that manage what the
  console's pages manage, a read (`read/3`) and a change (`write/4`) of any of its routes.

  Each call carries a credential for EHOS's API from `Ehosctl.Credentials.fetch/3`, and a refusal
  is an error of its kind (`Ehosctl.Refusal.ehos/2`). Takes the options a command is handed.

  Every route is below `/api/v1`, EHOS's API as `ehos.api/v1` (eh-os D-91). `describe/2` reads
  what the installation says about itself there, and a call EHOS answers 404 without a refusal of
  its own, or with `no_route`, as its router does for a route it lacks, is checked against the
  routes it lists: one it does not have is said to need a later EHOS, rather than a bare 404
  (`answer/5`).
  """

  alias Ehosctl.AtCount
  alias Ehosctl.Config
  alias Ehosctl.Credentials
  alias Ehosctl.Failure
  alias Ehosctl.HTTP
  alias Ehosctl.Refusal

  @typedoc """
  One application in one environment where the person holds a role: `"application"`,
  `"environment"`, `"audience"`, `"address"`, `"roles"`, and `"capabilities"`, each with its
  `"name"`, `"label"` and `"kind"` (`"command"`, `"query"` or `"record"`).
  """
  @type application :: %{String.t() => term()}

  @type error :: Refusal.error()

  @kinds ~w(command query record)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @doc "The roles bound to the person and to their agents, as `GET /api/v1/me/roles` lists them."
  @spec roles({Config.name(), Config.installation()}, keyword()) :: {:ok, [map()]} | error()
  def roles(installation, opts) do
    with {:ok, body} <- read(installation, "/api/v1/me/roles", opts) do
      roles_read(body, installation)
    end
  end

  defp roles_read(%{"roles" => roles}, installation) when is_list(roles) do
    if Enum.all?(roles, &role?/1), do: {:ok, roles}, else: unexpected(installation)
  end

  defp roles_read(_other, installation), do: unexpected(installation)

  @doc """
  The applications the person may use, each in one environment, as
  `GET /api/v1/me/applications` lists them. An entry whose address is not an `https` URL is
  refused as an answer EHOS would not give.
  """
  @spec applications({Config.name(), Config.installation()}, keyword()) ::
          {:ok, [application()]} | error()
  def applications(installation, opts) do
    with {:ok, body} <- read(installation, "/api/v1/me/applications", opts) do
      applications_read(body, installation)
    end
  end

  defp applications_read(%{"applications" => entries}, installation)
       when is_list(entries) do
    if Enum.all?(entries, &application?/1),
      do: {:ok, entries},
      else: unexpected(installation)
  end

  defp applications_read(_other, installation), do: unexpected(installation)

  @doc """
  The entry of `applications` for `application` in `environment`. When `environment` is `nil`,
  the one environment where the person holds a role in it; when they hold one in several, an
  error of kind `:invalid` that names them. An application or environment where they hold none
  is of kind `:refused`, as the credential for it would be.
  """
  @spec choose(
          [application()],
          {String.t(), String.t() | nil},
          {Config.name(), Config.installation()}
        ) :: {:ok, application()} | error()
  def choose(applications, {application, environment}, installation) do
    entries = Enum.filter(applications, &(&1["application"] == application))
    environments = Enum.map(entries, & &1["environment"])
    shown = Refusal.shown(application)

    case {entries, environment} do
      {[], _environment} ->
        {:error, :refused,
         Failure.new("None of your roles is bound in #{shown}.",
           advice: "See the applications that you may use:",
           to_do: [Config.command("ehosctl apps", installation)]
         )}

      {[entry], nil} ->
        {:ok, entry}

      {_several, nil} ->
        {:error, :invalid,
         "You hold roles in #{shown} in #{list(environments)}. Name one with --env."}

      {entries, environment} ->
        case Enum.find(entries, &(&1["environment"] == environment)) do
          nil ->
            {:error, :refused,
             "None of your roles is bound in #{shown} in #{Refusal.shown(environment)}. You " <>
               "hold roles in #{shown} in #{list(environments)}."}

          entry ->
            {:ok, entry}
        end
    end
  end

  defp list(names), do: Enum.map_join(names, ", ", &Refusal.shown/1)

  @doc """
  Whether `word` names nothing as a segment of a route's path: it is empty, or it would leave its
  place in the path (`.`, `..`), which a proxy that resolves dot segments would send elsewhere. A
  command refuses such a name before anything is sent, in its own words. Usable in a guard.

      iex> require Ehosctl.Api
      iex> Enum.map(["", ".", "..", "staging", ".hidden"], &Ehosctl.Api.is_nameless(&1))
      [true, true, true, false, false]
  """
  defguard is_nameless(word) when word in ["", ".", ".."]

  @doc """
  Whether `word` is a UUID, as EHOS names a record by, in either case.

      iex> Enum.map(["4C7A6B5E-0000-4000-8000-000000000004", "4c7a6b5e", "ada@example.com"], &Ehosctl.Api.uuid?/1)
      [true, false, false]
  """
  @spec uuid?(String.t()) :: boolean()
  def uuid?(word), do: Regex.match?(@uuid, word)

  @doc """
  `name` as one segment of a route's path, with every character that is not unreserved
  percent-encoded, so that a `/`, `?` or `#` in it stays inside the segment. Check it with
  `is_nameless/1` first: `.` and `..` are unreserved.

      iex> Ehosctl.Api.segment("a b/c")
      "a%20b%2Fc"
  """
  @spec segment(String.t()) :: String.t()
  def segment(name), do: URI.encode(name, &URI.char_unreserved?/1)

  @doc """
  The body of `GET path`, a JSON object answered 200, or the refusal of whatever else EHOS's API
  answered, or why it did not.
  """
  @spec read({Config.name(), Config.installation()}, String.t(), keyword()) ::
          {:ok, map()} | error()
  def read(installation, path, opts) do
    case read_if_routed(installation, path, opts) do
      {:lacking, message} -> {:error, :failed, message}
      result -> result
    end
  end

  @doc """
  `read/3`, for a command that does without a route an older EHOS lacks: when the installation
  has no such route, `{:lacking, message}`, the message `answer/5` would have given as an error.
  """
  @spec read_if_routed({Config.name(), Config.installation()}, String.t(), keyword()) ::
          {:ok, map()} | {:lacking, String.t()} | error()
  def read_if_routed(installation, path, opts) do
    case routed(installation, :get, path, nil, opts) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, answer} -> refusal(answer, installation)
      {:error, _kind, _message, :sent} = unanswered -> HTTP.unanswered_read(unanswered)
      other -> other
    end
  end

  @doc """
  Sends a change, `{method, path, body}`, and says what EHOS says was done, else its refusal.

  `expect` holds the `:status` and the `:key` of a success's body, or `nil` when the body is the
  value itself, `:valid?`, whether the value is what was asked for, `:only`, the fields of it that
  are printed, under `--json` too, so nothing else an answer holds reaches a script, and `:look`,
  the command that shows whether a change was done, its values quoted with
  `EhosPlatform.Shell.word/1`, and, optionally, `:refused`, which turns a
  refusal's body into a sentence printed after EHOS's, or `{sentence, fields}` when `--json` also
  keeps `fields` beside the refusal's code, or `nil`. `said` turns the value into words, or into
  `{words, warnings}`, the warnings that follow them (`t:Ehosctl.Output.warning/0`); words are
  never a tuple.

  A change that went unanswered, or a gateway's 5xx without EHOS's code, may have been done; one
  EHOS answered with a success `ehosctl` cannot read was done; and one answered for something other
  than what was asked did something: each way the person is told to look.
  """
  @spec write(
          keyword(),
          {:post | :put | :patch | :delete, String.t(), term()},
          keyword(),
          (map() -> Ehosctl.Output.text() | {Ehosctl.Output.text(), [Ehosctl.Output.warning()]})
        ) :: {:ok, Ehosctl.Output.t()} | error()
  def write(opts, {method, path, body}, expect, said) do
    installation = Keyword.fetch!(opts, :installation)
    status = Keyword.fetch!(expect, :status)
    key = Keyword.fetch!(expect, :key)
    look = Keyword.fetch!(expect, :look)

    case answer(installation, method, path, body, opts) do
      {:ok, %{status: ^status, body: %{} = body}} when is_nil(key) or is_map_key(body, key) ->
        done(installation, body, key, expect, said, look)

      {:ok, %{status: answered}} when answered in 200..299 ->
        done_unread(installation, look)

      {:ok, %{status: answered} = answer} when answered >= 500 ->
        failed(answer, installation, look)

      {:ok, answer} ->
        refused(answer, installation, expect[:refused])

      {:error, kind, message, :sent} ->
        {:error, kind, maybe_done(message, look, installation)}

      error ->
        error
    end
  end

  defp done(installation, body, key, expect, said, look) do
    value = if key, do: body[key], else: body

    if expect[:valid?].(value) do
      value = expect[:only].(value)
      json = if key, do: %{key => value}, else: value

      case said.(value) do
        {text, warnings} when is_list(warnings) ->
          {:ok, %{text: text, json: json, warnings: warnings}}

        text ->
          {:ok, %{text: text, json: json}}
      end
    else
      {:error, kind, message} = unexpected(installation)

      {:error, kind,
       message
       |> Failure.added(" It answered that something was done, but not as what was asked.")
       |> to_look("See what was done", look(look, installation))}
    end
  end

  defp failed(answer, installation, look) do
    refused = refusal(answer, installation)

    if coded?(answer.body),
      do: refused,
      else: Refusal.updated(refused, &maybe_done(&1, look, installation))
  end

  defp refused(answer, installation, refused) do
    refusal = refusal(answer, installation)

    case more(answer.body, refused) do
      {more, fields} when is_binary(more) and is_map(fields) ->
        refusal |> Refusal.added(more) |> with_fields(fields)

      more when is_binary(more) ->
        Refusal.added(refusal, more)

      _nothing ->
        refusal
    end
  end

  # Only a refusal EHOS coded carries fields for `--json`, beside its code.
  defp with_fields({:error, kind, message, refusal}, fields),
    do: {:error, kind, message, Map.merge(fields, refusal)}

  defp with_fields(error, _fields), do: error

  # Only a refusal's JSON object is read for more, so a body of another shape adds nothing.
  defp more(%{} = body, refused) when is_function(refused, 1), do: refused.(body)
  defp more(_body, _refused), do: nil

  # The look command as `expect` gives it, run against `installation`.
  defp look(look, installation), do: Config.command(look, installation)

  # The warning not to send the change again holds without the command too.
  defp maybe_done(message, look, installation) do
    message
    |> Failure.added(" EHOS possibly made the change.")
    |> to_look("See whether it did before you run the command again", look(look, installation))
  end

  defp done_unread(installation, look) do
    {:error, kind, message} = unexpected(installation)

    {:error, kind,
     message
     |> Failure.added(" EHOS said that it made the change.")
     |> to_look("See it", look(look, installation))}
  end

  # The advice to look holds without the command too, which a value that is not
  # `Ehosctl.Output.pastable?/1` leaves out: then it is a sentence of its own, not one that ends
  # in a colon and is left out with the command.
  defp to_look(message, advice, command) do
    if Ehosctl.Output.pastable?(command),
      do: Failure.with_to_do(message, advice <> ":", [command]),
      else: Failure.with_to_do(message, advice <> ".", [])
  end

  @doc """
  Sends `method` to `path` of EHOS's API with a credential for it, and `body`
  (`c:Ehosctl.HTTP.request/5`'s), and returns the answer whatever its status, or why none came:
  `{:error, kind, message, :sent}` when the request was sent and no answer came, so it may have
  been done.
  """
  @spec answer(
          {Config.name(), Config.installation()},
          :get | :post | :put | :patch | :delete,
          String.t(),
          term(),
          keyword()
        ) ::
          {:ok, HTTP.answer()}
          | error()
          | {:error, Ehosctl.Output.kind(), Ehosctl.Failure.message(), :sent}
  def answer(installation, method, path, body, opts) do
    case routed(installation, method, path, body, opts) do
      {:lacking, message} -> {:error, :failed, message}
      result -> result
    end
  end

  defp routed({_name, installation} = named, method, path, body, opts) do
    with {:ok, credential} <- Credentials.fetch(named, :ehos, opts) do
      case HTTP.current().request(method, installation["url"] <> path, credential, body, opts) do
        {:ok, answer} -> routed_answer(named, method, path, answer, opts)
        result -> result
      end
    end
  end

  @doc """
  An answer EHOS's API gave to `method` at `path`, as `answer/5` reads it: a 404 without EHOS's own
  code, or with `no_route`, from an installation whose routes do not include it, is
  `{:lacking, message}`, the message saying the command needs a later EHOS; any other answer is
  `{:ok, answer}`. For an answer `answer/5` does not ask for itself, as a tail of the logs, which
  is read as it comes.
  """
  @spec routed_answer(
          {Config.name(), Config.installation()},
          :get | :post | :put | :patch | :delete,
          String.t(),
          HTTP.answer(),
          keyword()
        ) :: {:ok, HTTP.answer()} | {:lacking, String.t()}
  # Only a JSON object, as EHOS's router answers, is taken for EHOS's: a proxy's or another host's
  # 404 keeps its error.
  def routed_answer(named, method, path, %{status: 404, body: %{} = answered} = answer, opts) do
    if coded?(answered) and answered["error"] != "no_route",
      do: {:ok, answer},
      else: lacking(named, method, path, answer, opts)
  end

  def routed_answer(_named, _method, _path, answer, _opts), do: {:ok, answer}

  # A 404 without EHOS's own code, or with `no_route` from an EHOS that answers so, is what its
  # router answers for a route it does not have: an installation older than this ehosctl.
  # `GET /api/v1` lists its routes, so the person is told that rather than a bare 404. When it
  # lists the route, or cannot be read, the 404 stands.
  defp lacking(named, method, "/api/v1/" <> _ = path, answer, opts) do
    route = %{"method" => method |> Atom.to_string() |> String.upcase(), "path" => path}

    case describe(named, opts) do
      {:ok, :predates} ->
        {:lacking,
         "#{url(named)} has no /api/v1, the API this ehosctl calls: its EHOS is older than " <>
           "this ehosctl. The operator upgrades EHOS to have it."}

      {:ok, %{"routes" => routes} = described} ->
        if route?(routes, route["method"], path) do
          {:ok, answer}
        else
          {:lacking,
           "#{url(named)} runs EHOS #{running(described)}, which has no " <>
             "`#{route["method"]} #{path |> URI.parse() |> Map.fetch!(:path) |> Refusal.shown()}`: " <>
             "this command needs a later EHOS. The operator upgrades EHOS to have it."}
        end

      _unknown ->
        {:ok, answer}
    end
  end

  defp lacking(_named, _method, _path, answer, _opts), do: {:ok, answer}

  defp url({_name, installation}), do: installation["url"]

  @doc """
  An installation's EHOS as a person reads it: its version, and the short commit it was built
  from when it says one.

      iex> Ehosctl.Api.running(%{"version" => "0.5.0-dev", "commit" => "1a000cc4e50fd1e75558dfb1638c8b08286fe0bd"})
      "0.5.0-dev (1a000cc)"

      iex> Ehosctl.Api.running(%{"version" => "0.5.0", "commit" => nil})
      "0.5.0"
  """
  @spec running(described()) :: String.t()
  def running(%{"version" => version} = described) do
    case described["commit"] do
      commit when is_binary(commit) -> "#{version} (#{String.slice(commit, 0, 7)})"
      nil -> version
    end
  end

  @typedoc """
  What an installation says about itself at `GET /api/v1` (eh-os `docs/releases.md`, D-91):
  `"component"`, `"version"`, `"commit"` (or `nil`), `"produces"` and `"accepts"`, the interfaces
  as `<name>/v<N>`, `"requires"`, a component's name to an Elixir version requirement, and
  `"routes"`, each `%{"method" => …, "path" => …}`.
  """
  @type described :: %{String.t() => term()}

  @doc """
  What the installation says about itself, `GET /api/v1`, kept to the fields above; `:predates`
  for an installation that answers 404 there with a JSON object, as an EHOS older than its
  versioned API does; a 404 that is not one, as a proxy or another host answers, is an error. Any
  credential for EHOS's API may ask. An answer of another shape is one `ehosctl` cannot read.
  """
  @spec describe({Config.name(), Config.installation()}, keyword()) ::
          {:ok, described() | :predates} | error()
  def describe(installation, opts) do
    case answer(installation, :get, "/api/v1", nil, opts) do
      {:ok, %{status: 200, body: body}} ->
        case described(body) do
          {:ok, described} -> {:ok, described}
          :error -> unexpected(installation)
        end

      {:ok, %{status: 404, body: %{}}} ->
        {:ok, :predates}

      {:ok, answer} ->
        refusal(answer, installation)

      {:error, _kind, _message, :sent} = unanswered ->
        HTTP.unanswered_read(unanswered)

      error ->
        error
    end
  end

  @doc """
  `body` as what an installation says about itself (`t:described/0`), its fields checked and
  nothing else kept, or `:error`. Every text is one a terminal can print, and a version one
  Elixir's `Version` reads.
  """
  @spec described(term()) :: {:ok, described()} | :error
  def described(%{} = body) do
    fields = Map.take(body, ~w(component version commit produces accepts requires routes))

    with %{"component" => component, "version" => version}
         when is_binary(component) and is_binary(version) <- fields,
         {:ok, _version} <- Version.parse(version),
         true <- printable?(component) and printable?(version),
         true <- is_nil(fields["commit"]) or printable?(fields["commit"]),
         true <- texts?(fields["produces"]) and texts?(fields["accepts"]),
         %{} = requires <- fields["requires"],
         true <- Enum.all?(requires, fn {k, v} -> printable?(k) and printable?(v) end),
         routes when is_list(routes) <- fields["routes"],
         true <- Enum.all?(routes, &route?/1) do
      {:ok, Map.merge(%{"commit" => nil}, fields)}
    else
      _other -> :error
    end
  end

  def described(_body), do: :error

  defp texts?(list), do: is_list(list) and Enum.all?(list, &printable?/1)
  defp printable?(text), do: is_binary(text) and text != "" and Ehosctl.Output.printable?(text)

  defp route?(%{"method" => method, "path" => path}), do: printable?(method) and printable?(path)
  defp route?(_route), do: false

  @doc """
  Whether `routes`, as `GET /api/v1` lists them, have one for `method` at `path`. A route's
  segment that starts with `:` matches any one segment, as Phoenix's router reads it; the query
  is not part of the route.

      iex> routes = [%{"method" => "PATCH", "path" => "/api/v1/people/:id"}]
      iex> Ehosctl.Api.route?(routes, "PATCH", "/api/v1/people/8b3e?x=1")
      true
      iex> Ehosctl.Api.route?(routes, "POST", "/api/v1/people/8b3e")
      false
  """
  @spec route?([map()], String.t(), String.t()) :: boolean()
  def route?(routes, method, path) do
    segments = path |> URI.parse() |> Map.fetch!(:path) |> String.split("/")

    Enum.any?(routes, fn route ->
      route["method"] == method and matches?(String.split(route["path"], "/"), segments)
    end)
  end

  defp matches?([], []), do: true

  defp matches?([":" <> _ | pattern], [segment | path]) when segment != "",
    do: matches?(pattern, path)

  defp matches?([same | pattern], [same | path]), do: matches?(pattern, path)
  defp matches?(_pattern, _path), do: false

  @doc """
  An answer of EHOS's API that is not what was asked for, as an error: a success that is not
  JSON as an answer `ehosctl` cannot read, any other its refusal (`Ehosctl.Refusal.ehos/2`), with
  the ephemeral environments that hold a count when it is a refusal at one (`Ehosctl.AtCount`).
  """
  @spec refusal(HTTP.answer(), {Config.name(), Config.installation()}) :: error()
  def refusal(%{status: status}, installation) when status in 200..299,
    do: unexpected(installation)

  def refusal(answer, {_name, installation}),
    do: answer |> Refusal.ehos(installation["url"]) |> AtCount.added(answer.body)

  defp role?(%{"role" => role, "held_by" => %{"kind" => kind, "name" => name}} = entry),
    do:
      is_binary(role) and kind in ["person", "agent"] and is_binary(name) and
        nil_or_text?(entry["application"]) and nil_or_text?(entry["environment"]) and
        grant?(entry["grant"]) and from_template?(entry["from_template"])

  defp role?(_entry), do: false

  # EHOS's D-161 (eh-os#1402): the environment template whose role entry made the role binding,
  # and who set the entry; null, or absent from an EHOS before it, for any other.
  defp from_template?(nil), do: true

  defp from_template?(%{"template" => template, "by" => by}),
    do: is_binary(template) and nil_or_text?(by)

  defp from_template?(_from_template), do: false

  # EHOS's D-112 (eh-os#798): who gave the role through an application; null, or absent from an
  # EHOS before it, for one bound in the console.
  defp grant?(nil), do: true

  defp grant?(%{"by" => by, "rule" => rule, "through" => through}),
    do: nil_or_text?(by) and is_binary(rule) and is_binary(through)

  defp grant?(_grant), do: false

  defp application?(%{} = entry) do
    texts = ~w(application environment audience address)

    Enum.all?(texts, &(is_binary(entry[&1]) and entry[&1] != "")) and
      address?(entry["address"]) and is_list(entry["roles"]) and
      Enum.all?(entry["roles"], &is_binary/1) and is_list(entry["capabilities"]) and
      Enum.all?(entry["capabilities"], &capability?/1)
  end

  defp application?(_entry), do: false

  # A name that would leave its place in the path (`.`, `..`) is not one EHOS gives. Any kind is
  # read, so that one a later EHOS adds is said to need a later `ehosctl` (`known_kind?/1`),
  # rather than making every application unreadable.
  defp capability?(%{"name" => name, "kind" => kind}) when is_binary(name) and is_binary(kind),
    do: not is_nameless(name)

  defp capability?(_capability), do: false

  @doc "Whether this version of `ehosctl` can call a capability of `kind`."
  @spec known_kind?(String.t()) :: boolean()
  def known_kind?(kind), do: kind in @kinds

  # The address the credential is sent to, so nothing but an origin over https, with an optional
  # path, is taken from EHOS's answer.
  defp address?(address) do
    case URI.new(address) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        scheme == "https" and Ehosctl.Output.printable?(address)

      _ ->
        false
    end
  end

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  @doc """
  Whether a body is one of EHOS's own refusals, with its code: a 5xx without one came from
  something in front of EHOS, a gateway, possibly after EHOS did what was asked.
  """
  @spec coded?(term()) :: boolean()
  def coded?(body), do: is_map(body) and is_binary(body["error"])

  @doc "An answer from `installation` that `ehosctl` cannot read, as an error of kind `:failed`."
  @spec unexpected({Config.name(), Config.installation()}) :: error()
  def unexpected({_name, installation}),
    do: {:error, :failed, "#{installation["url"]} answered with something ehosctl cannot read."}
end

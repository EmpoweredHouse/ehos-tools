defmodule Ehosctl.Versions do
  @moduledoc """
  `ehosctl versions`: for each of EHOS's components, the version in use, whether the installation
  accepts it, the newest release, whether the installation would accept that, and the command
  that moves to it (eh-os D-91, ehos-tools#97).

  The components are `ehosctl` itself, the installation's EHOS (`ehos`), and in an application's
  directory its `ehos_app`, `eh_os_contract` and `ehos_design`, with a line for each document it
  gives EHOS. Three sources answer, and each can fail alone:

    * **the installation**, `GET /api/v1` (`Ehosctl.Api.describe/2`), says what it runs and what
      it accepts (`Ehosctl.Acceptance`);
    * **GitHub's releases** (`Ehosctl.GitHub`) say what exists, with each release's
      `release.json`;
    * **the application's `mix.lock`** (`Ehosctl.Project`) says what it uses: a git dependency's
      commit is matched to the release whose `release.json` names it, and one that is no
      release's is said as a commit, with how far it is from the newest release when GitHub
      compares them.

  What a source could not say is said, with why, and the rest is printed: the command exits 0
  whatever its sources answered, and fails only on its own command line.

  It is on the governed plane, since it talks to EHOS as the person (eh-os D-87), and chooses its
  installation itself, as `verify` does, so it also runs without one. A newer release the
  installation does not accept is shown as newer and not accepted, and no command moves to it.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Acceptance
  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.GitHub
  alias Ehosctl.Output
  alias Ehosctl.Project
  alias Ehosctl.Refusal

  # How many of a component's releases are read to find the one a locked commit is, newest first,
  # and how many of their files at once.
  @matched_releases 30
  @read_at_once 8

  @impl Ehosctl.Command
  def name, do: :versions

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def chooses_installation?, do: true

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Show the version of each EHOS component in use, the newest release, whether the " <>
          "installation accepts each, and the command that moves to it.",
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    dir = Keyword.get_lazy(opts, :dir, &File.cwd!/0)

    with {:ok, chosen} <- Config.chosen(parsed.options[:installation], opts) do
      report = report(chosen, dir, opts)
      {:ok, %{text: text(report), json: json(report)}}
    end
  end

  @doc """
  What the installation says about itself, or why it is not known: `{:unknown, why}` when no
  installation is chosen, when it predates `GET /api/v1`, or when it did not answer.
  """
  @spec installation({Config.name(), Config.installation()} | nil, keyword()) ::
          Acceptance.installation()
  def installation(nil, _opts), do: {:unknown, "no installation is chosen"}

  def installation({name, _installation} = chosen, opts) do
    case Api.describe(chosen, opts) do
      {:ok, :predates} ->
        {:unknown,
         "#{name} has no GET /api/v1, which says what it accepts: its EHOS is older than " <>
           "this ehosctl"}

      {:ok, described} ->
        described

      {:error, _kind, message} ->
        {:unknown, "#{name} did not say what it accepts: #{trim(message)}"}
    end
  end

  @doc """
  The release `dependency`, as `mix.lock` has it, is: the one among `releases` whose
  `release.json`, as `jsons` holds them by `key/1`, names its commit, else for a Hex dependency the
  one of its version; `nil` when it is none of them.
  """
  @spec matched(Project.dependency(), [GitHub.release()], %{{String.t(), String.t()} => term()}) ::
          GitHub.release() | nil
  def matched(%{scm: :git, commit: commit}, releases, jsons),
    do: Enum.find(releases, &(commit_of(jsons[key(&1)]) == commit))

  def matched(%{scm: :hex, version: version}, releases, _jsons),
    do: Enum.find(releases, &(&1.version == version))

  @doc """
  The `release.json` files read to find the release a git `dependency` is: those of the newest
  #{@matched_releases} of `releases`, #{@read_at_once} at a time, newest first, until one names its
  commit. Each is kept by `key/1`, as decoded, or as `{:unread, message}`. None for a dependency
  that is not a git one.
  """
  @spec located(Project.dependency(), [GitHub.release()], keyword()) :: %{
          {String.t(), String.t()} => term()
        }
  def located(%{scm: :git} = dependency, releases, opts) do
    releases
    |> Enum.take(@matched_releases)
    |> Enum.chunk_every(@read_at_once)
    |> Enum.reduce_while(%{}, fn some, jsons ->
      jsons = Map.merge(jsons, read_jsons(some, opts))
      if matched(dependency, releases, jsons), do: {:halt, jsons}, else: {:cont, jsons}
    end)
  end

  def located(_dependency, _releases, _opts), do: %{}

  @doc """
  The version a dependency is at, when it can be told without GitHub: a Hex dependency's, or the
  version in the tag of the component's form its `mix.exs` names.
  """
  @spec locked_version(GitHub.component(), Project.dependency()) :: String.t() | nil
  def locked_version(_component, %{scm: :hex, version: version}), do: version

  def locked_version(component, %{scm: :git, tag: tag}) when is_binary(tag) do
    prefix = if component in ~w(ehosctl ehos eh_os_contract), do: "v", else: component <> "-v"

    with true <- String.starts_with?(tag, prefix),
         {:ok, version} <- Version.parse(String.replace_prefix(tag, prefix, "")) do
      to_string(version)
    else
      _other -> nil
    end
  end

  def locked_version(_component, _dependency), do: nil

  @doc """
  What a release's `release.json` is kept under: its repository and its tag, since ehosctl,
  EHOS and eh_os_contract are all tagged `vX.Y.Z`, each in its own repository.
  """
  @spec key(GitHub.release()) :: {String.t(), String.t()}
  def key(release), do: {release.repository, release.tag}

  defp commit_of(%{"commit" => commit}) when is_binary(commit), do: commit
  defp commit_of(_json), do: nil

  # Everything the sources say, read at once where they do not depend on each other.
  defp report(chosen, dir, opts) do
    asked = Task.async(fn -> installation(chosen, opts) end)

    {project, project_note} =
      case Project.read(dir) do
        {:ok, project} -> {project, nil}
        :none -> {nil, nil}
        {:error, message} -> {nil, message}
      end

    components =
      if project,
        do: ~w(ehosctl ehos ehos_app eh_os_contract ehos_design),
        else: ~w(ehosctl ehos)

    listed = listed(components, opts)
    releases = Map.new(components, &{&1, releases(&1, listed)})
    jsons = jsons(components, releases, project, opts)
    installation = Task.await(asked, :infinity)

    rows =
      Enum.map(components, fn component ->
        row(component, installation, releases[component], jsons, project, opts)
      end)

    %{
      installation: {chosen, installation},
      dir: dir,
      project: project,
      project_note: project_note,
      github: listed |> Enum.sort() |> Enum.flat_map(&unread/1) |> Enum.uniq(),
      rows: rows,
      documents: documents(project, installation)
    }
  end

  defp unread({_repository, {:ok, _listed, :whole}}), do: []

  defp unread({repository, {:ok, _listed, :cut}}),
    do: [
      "GitHub listed only the first 1000 releases of #{repository}, the newest it " <>
        "published; older ones are not shown."
    ]

  defp unread({_repository, {:error, _kind, message}}), do: ["GitHub was not read: #{message}"]

  # Each repository is listed once, for every component released from it.
  defp listed(components, opts) do
    components
    |> Enum.map(&GitHub.repository/1)
    |> Enum.uniq()
    |> Task.async_stream(&{&1, GitHub.list(&1, opts)}, timeout: :infinity, ordered: false)
    |> Map.new(fn {:ok, listed} -> listed end)
  end

  defp releases(component, listed) do
    case listed[GitHub.repository(component)] do
      {:ok, all, _whole_or_cut} -> {:ok, GitHub.of(component, all)}
      {:error, _kind, message} -> {:error, message}
    end
  end

  # The `release.json` of each release that is needed: every component's newest, for what it
  # accepts and produces, and for a git dependency those `located/3` reads to find the one it is.
  defp jsons(components, releases, project, opts) do
    components
    |> Task.async_stream(
      fn component ->
        case releases[component] do
          {:ok, [newest | _] = all} ->
            located = if project, do: located(project.deps[component], all, opts), else: %{}

            if Map.has_key?(located, key(newest)),
              do: located,
              else: Map.merge(located, read_jsons([newest], opts))

          _none ->
            %{}
        end
      end,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, jsons}, all -> Map.merge(all, jsons) end)
  end

  defp read_jsons(releases, opts) do
    releases
    |> Task.async_stream(
      fn release ->
        case GitHub.release_json(release, opts) do
          {:ok, json} -> {key(release), json}
          {:error, _kind, message} -> {key(release), {:unread, message}}
        end
      end,
      timeout: :infinity,
      max_concurrency: @read_at_once
    )
    |> Map.new(fn {:ok, pair} -> pair end)
  end

  defp row("ehosctl", installation, releases, jsons, _project, _opts) do
    version = Ehosctl.version()

    in_use = %{
      version: version,
      commit: if(dev?(version), do: Ehosctl.commit()),
      said:
        version <>
          if(dev?(version) and Ehosctl.commit(), do: " (#{short(Ehosctl.commit())})", else: "")
    }

    newest(releases, jsons, %{
      component: "ehosctl",
      in_use: in_use,
      accepted: Acceptance.ehosctl(installation, version, Ehosctl.Version.accepts()),
      judge: fn release, json ->
        Acceptance.combine([
          Acceptance.ehosctl(installation, release.version, interfaces(json, "accepts")),
          Acceptance.release(installation, json)
        ])
      end,
      move: fn _release, _json -> "mise upgrade ehosctl" end
    })
  end

  defp row("ehos", installation, releases, jsons, _project, _opts) do
    in_use =
      case installation do
        %{"version" => version} = described ->
          %{version: version, commit: described["commit"], said: Api.running(described)}

        {:unknown, _why} ->
          nil
      end

    newest(releases, jsons, %{
      component: "ehos",
      in_use: in_use,
      accepted: :not_applicable,
      judge: fn _release, _json -> :not_applicable end,
      move: fn _release, _json ->
        "The operator upgrades EHOS; `ehosctl upgrade`, which will do it, does not exist yet."
      end
    })
  end

  defp row(component, installation, releases, jsons, project, opts) do
    dependency = project.deps[component]
    all = with {:ok, all} <- releases, do: all, else: (_ -> [])
    matched = dependency && matched(dependency, all, jsons)
    newest = List.first(all)
    newest_json = newest && usable(jsons[key(newest)])

    in_use =
      case dependency do
        nil ->
          nil

        dependency ->
          in_use(component, dependency, matched, newest, newest_json, opts)
      end

    newest(releases, jsons, %{
      component: component,
      in_use: in_use,
      accepted:
        accepted(
          component,
          installation,
          dependency,
          matched && usable(jsons[key(matched)]),
          project
        ),
      judge: fn _release, json -> judge(component, installation, json, project) end,
      move: fn release, json -> move(component, dependency, release, json) end
    })
  end

  # What is in use is judged by its own release's `release.json`: a commit that is no release's
  # says nothing of what it writes.
  defp accepted(_component, _installation, nil, _json, _project), do: :not_applicable
  defp accepted("ehos_design", _installation, _dependency, _json, _project), do: :not_applicable
  defp accepted(_component, {:unknown, why}, _dependency, _json, _project), do: {:unknown, why}

  defp accepted(_component, _described, _dependency, nil, _project),
    do: {:unknown, "it is no release ehosctl knows, so what it writes is not known"}

  defp accepted(component, installation, _dependency, json, project),
    do: judge(component, installation, json, project)

  # Each release is judged both ways: what it writes against what the installation accepts, and
  # what the installation produces and runs against what the release accepts and requires.
  defp judge("ehos_app", installation, json, _project),
    do:
      Acceptance.combine([
        Acceptance.ehos_app(installation, interfaces(json, "produces")),
        Acceptance.release(installation, json)
      ])

  defp judge("eh_os_contract", installation, json, project),
    do:
      Acceptance.combine([
        Acceptance.eh_os_contract(installation, interfaces(json, "produces"), project.manifest),
        Acceptance.release(installation, json)
      ])

  defp judge("ehos_design", _installation, _json, _project), do: :not_applicable

  # A dependency as a person reads it: its release's version, or its commit with what `mix.exs`
  # names it by, and how far it is from the newest release when GitHub compares them.
  defp in_use(component, dependency, matched, newest, newest_json, opts) do
    case {dependency, matched} do
      {%{scm: :hex, version: version}, _matched} ->
        %{version: version, commit: nil, said: version, position: nil}

      {%{commit: commit}, %{version: version}} ->
        %{version: version, commit: commit, said: "#{version} (#{short(commit)})", position: nil}

      {%{commit: commit} = dependency, nil} ->
        named =
          cond do
            dependency.branch -> "#{dependency.branch} at #{short(commit)}"
            dependency.tag -> "#{short(commit)} (tag #{dependency.tag})"
            true -> short(commit)
          end

        position = position(component, commit, newest, newest_json, opts)

        %{
          version: locked_version(component, dependency),
          commit: commit,
          said: named <> said_position(position, newest),
          position: position
        }
    end
  end

  defp position(component, commit, %{} = _newest, %{"commit" => released}, opts)
       when is_binary(released) do
    case GitHub.compare(component, released, commit, opts) do
      {:ok, compared} -> compared
      {:error, _kind, _message} -> nil
    end
  end

  defp position(_component, _commit, _newest, _json, _opts), do: nil

  defp said_position(nil, _newest), do: ""
  defp said_position(%{status: "identical"}, newest), do: ", which is #{newest.version}"

  defp said_position(%{status: "behind", behind_by: n}, newest),
    do: ", #{commits(n)} behind #{newest.version}"

  defp said_position(%{status: "ahead", ahead_by: n}, newest),
    do: ", #{commits(n)} past #{newest.version}"

  defp said_position(%{status: "diverged", ahead_by: a, behind_by: b}, newest),
    do: ", #{commits(b)} behind #{newest.version} and #{commits(a)} not in it"

  defp commits(1), do: "1 commit"
  defp commits(n), do: "#{n} commits"

  # The newest release, whether the installation accepts it, and the command that moves to it:
  # offered only when it is newer than what is in use and not refused.
  defp newest(releases, jsons, row) do
    case releases do
      {:error, message} ->
        Map.merge(row, %{
          newest: nil,
          newest_unread: message,
          newest_accepted: {:unknown, "GitHub was not read"},
          move: nil
        })

      {:ok, []} ->
        Map.merge(row, %{
          newest: nil,
          newest_unread: nil,
          newest_accepted: :not_applicable,
          move: nil
        })

      {:ok, [release | _]} ->
        json = usable(jsons[key(release)])
        verdict = row.judge.(release, json)

        verdict =
          case {jsons[key(release)], verdict} do
            {{:unread, message}, {:unknown, _why}} ->
              {:unknown, "its release.json is not used: #{String.trim_trailing(message, ".")}"}

            _read ->
              verdict
          end

        move =
          if newer?(release, row.in_use) and not match?({:no, _}, verdict),
            do: row.move.(release, json)

        Map.merge(row, %{
          newest: release,
          newest_unread: nil,
          newest_accepted: verdict,
          move: move
        })
    end
    |> Map.drop([:judge])
  end

  defp usable(%{} = json), do: json
  defp usable(_none), do: nil

  # A release's interfaces, `nil` when its release.json names none, or names them otherwise than
  # as a list of texts a terminal can print.
  defp interfaces(%{} = json, key) do
    case json[key] do
      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and Output.printable?(&1))), do: list

      _other ->
        nil
    end
  end

  defp interfaces(_json, _key), do: nil

  # Newer than what is in use: by version where both have one, else by GitHub's comparison of
  # the locked commit with the release's. When neither tells, it is not said to be newer.
  defp newer?(_release, nil), do: false

  defp newer?(release, %{position: %{status: status}}) when status in ~w(behind diverged),
    do: release.version != nil

  defp newer?(_release, %{position: %{status: _status}}), do: false

  defp newer?(release, %{version: version}) when is_binary(version) do
    case Version.parse(version) do
      {:ok, version} -> Version.compare(Version.parse!(release.version), version) == :gt
      :error -> false
    end
  end

  defp newer?(_release, _in_use), do: false

  defp move("ehos_app", dependency, release, json) do
    "In mix.exs, set :ehos_app's `ref:` to #{commit_said(release, json)} and its requirement " <>
      "to \"== #{release.version}\" in place of its `#{pinned_by(dependency)}`, run `mix deps.get`, " <>
      "then `mix ehos_app.install` again."
  end

  defp move("eh_os_contract", %{branch: branch}, _release, _json) when is_binary(branch),
    do:
      "mix deps.update eh_os_contract eh_os_contract_auth (they follow #{branch}, which " <>
        "moves them to its newest commit, not to the release)"

  defp move("eh_os_contract", _dependency, release, json),
    do:
      "In mix.exs, set the `ref:` of :eh_os_contract and :eh_os_contract_auth to " <>
        "#{commit_said(release, json)}, then run `mix deps.get`."

  defp move("ehos_design", dependency, release, json),
    do:
      "In mix.exs, set :ehos_design's `ref:` to #{commit_said(release, json)} in place of its " <>
        "`#{pinned_by(dependency)}`, then run `mix deps.get`."

  defp pinned_by(%{tag: tag}) when is_binary(tag), do: "tag:"
  defp pinned_by(%{branch: branch}) when is_binary(branch), do: "branch:"
  defp pinned_by(%{scm: :hex}), do: "version"
  defp pinned_by(_dependency), do: "ref:"

  # A commit as `release.json` names it, and only one that is a commit: the line is a command
  # to copy into `mix.exs`.
  defp commit_said(release, %{"commit" => commit}) when is_binary(commit) do
    if commit =~ ~r/\A[0-9a-f]{40}\z/,
      do: "\"#{commit}\" (#{release.tag})",
      else: commit_said(release, nil)
  end

  defp commit_said(release, _json),
    do:
      "the commit #{release.tag} names (`git ls-remote https://github.com/#{release.repository} " <>
        "refs/tags/#{release.tag}^{}`, or the tag itself for a lightweight tag)"

  defp documents(nil, _installation), do: []

  defp documents(project, installation) do
    [
      %{
        document: "ehos.yaml",
        schema: project.ehos_yaml,
        accepted: Acceptance.document(installation, project.ehos_yaml)
      }
    ] ++
      if project.manifest,
        do: [
          %{
            document: "manifest",
            schema: project.manifest,
            accepted: Acceptance.document(installation, project.manifest)
          }
        ],
        else: []
  end

  defp dev?(version), do: match?({:ok, %Version{pre: [_ | _]}}, Version.parse(version))
  defp short(commit), do: String.slice(commit, 0, 7)
  defp trim(message), do: String.trim_trailing(message, ".")

  # The words: where each source stands, a table, then why, then what moves each.
  defp text(report) do
    {chosen, installation} = report.installation

    head =
      [
        installation_line(chosen, installation),
        report.project && "Application: #{Refusal.shown(report.dir)}",
        report.project_note && "The application's mix.lock was not read: #{report.project_note}",
        report.github
      ]
      |> List.flatten()
      |> Enum.filter(&is_binary/1)

    known = known_reason(installation)

    rows =
      Enum.map(report.rows, fn row ->
        %{
          "COMPONENT" => row.component,
          "IN USE" => (row.in_use && row.in_use.said) || in_use_unknown(row, report),
          "ACCEPTED" => verdict(row.accepted),
          "NEWEST" => newest_said(row),
          "NEWEST ACCEPTED" => if(row.newest, do: verdict(row.newest_accepted), else: "")
        }
      end) ++
        Enum.map(report.documents, fn document ->
          %{
            "COMPONENT" => document.document,
            "IN USE" => document.schema || "no schema ehosctl reads",
            "ACCEPTED" => verdict(document.accepted),
            "NEWEST" => "",
            "NEWEST ACCEPTED" => ""
          }
        end)

    table =
      Output.table(rows, ["COMPONENT", "IN USE", "ACCEPTED", "NEWEST", "NEWEST ACCEPTED"])

    why =
      Enum.flat_map(report.rows, fn row ->
        [
          reason(row.component, row.accepted, known),
          row.newest &&
            reason("#{row.component} #{row.newest.version}", row.newest_accepted, known)
        ]
      end) ++ Enum.map(report.documents, &reason(&1.document, &1.accepted, known))

    moves =
      for row <- report.rows,
          row.move,
          do: "  #{row.component} to #{row.newest.version}: #{row.move}"

    [
      Enum.join(head, "\n"),
      table,
      section("Why:", Enum.filter(why, &is_binary/1)),
      section("To move:", moves)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp installation_line(nil, _installation),
    do:
      "No installation is chosen, so what one accepts is not shown: run `ehosctl login`, or " <>
        "name one with --installation."

  defp installation_line({name, %{"url" => url}}, %{} = described),
    do: "Installation: #{name} (#{Refusal.shown(url)}), EHOS #{Api.running(described)}"

  defp installation_line({name, %{"url" => url}}, {:unknown, why}),
    do: "Installation: #{name} (#{Refusal.shown(url)}). #{sentence(why)}."

  # The first letter raised, and the rest as it is, which `String.capitalize/1` would lower.
  defp sentence(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp known_reason({:unknown, why}), do: why
  defp known_reason(_described), do: nil

  defp in_use_unknown(%{component: "ehos"}, _report), do: "not known"
  defp in_use_unknown(_row, _report), do: "not a dependency"

  defp newest_said(%{newest: %{version: version}}), do: version
  defp newest_said(%{newest_unread: message}) when is_binary(message), do: "not known"
  defp newest_said(_row), do: "none released"

  defp verdict(:yes), do: "yes"
  defp verdict({:no, _why}), do: "no"
  defp verdict({:unknown, _why}), do: "unknown"
  defp verdict(:not_applicable), do: "n/a"

  # A reason the installation's line already gives is not said again on every row.
  defp reason(what, {kind, why}, known) when kind in [:no, :unknown] and why != known,
    do: "  #{what}: #{why}."

  defp reason(_what, _verdict, _known), do: nil

  defp section(_title, []), do: ""
  defp section(title, lines), do: Enum.join([title | lines], "\n")

  defp json(report) do
    {chosen, installation} = report.installation

    %{
      installation:
        case chosen do
          nil ->
            nil

          {name, %{"url" => url}} ->
            %{
              name: name,
              url: url,
              described: if(is_map(installation), do: installation),
              unknown: known_reason(installation)
            }
        end,
      application:
        report.project &&
          %{
            dir: report.dir,
            ehos_yaml: report.project.ehos_yaml,
            manifest: report.project.manifest
          },
      unread: %{github: report.github, application: report.project_note},
      components:
        Enum.map(report.rows, fn row ->
          %{
            component: row.component,
            in_use: row.in_use && Map.take(row.in_use, [:version, :commit, :said]),
            accepted: verdict_json(row.accepted),
            newest: row.newest && Map.take(row.newest, [:version, :tag, :url]),
            newest_accepted: row.newest && verdict_json(row.newest_accepted),
            move: row.move
          }
        end),
      documents:
        Enum.map(report.documents, fn document ->
          %{
            document: document.document,
            schema: document.schema,
            accepted: verdict_json(document.accepted)
          }
        end)
    }
  end

  defp verdict_json(:yes), do: %{verdict: "yes", why: nil}
  defp verdict_json({:no, why}), do: %{verdict: "no", why: why}
  defp verdict_json({:unknown, why}), do: %{verdict: "unknown", why: why}
  defp verdict_json(:not_applicable), do: %{verdict: "not_applicable", why: nil}
end

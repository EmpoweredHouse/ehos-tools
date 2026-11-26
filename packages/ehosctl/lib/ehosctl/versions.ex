defmodule Ehosctl.Versions do
  @moduledoc """
  `ehosctl versions`: for each of EHOS's components, the version in use, whether the installation
  accepts it, the newest release, whether the installation would accept that, and the command
  that moves to it (eh-os D-91, ehos-tools#97).

  The components are `ehosctl` itself, the installation's EHOS (`ehos`), and in an application's
  directory its `ehos_app`, `ehos_contract` and `ehos_design`, with a line for each document it
  gives EHOS. Three sources answer, and each can fail alone:

    * **the installation**, `GET /api/v1` (`Ehosctl.Api.describe/2`), says what it runs and what
      it accepts (`Ehosctl.Acceptance`);
    * **GitHub's releases** (`Ehosctl.GitHub`) say what exists, with each release's
      `release.json`;
    * **the application's `mix.lock`** (`Ehosctl.Project`) says what it uses: a git dependency's
      commit is matched to the release whose `release.json` names it, else to the tag of the
      component's form that names it, for a release made before `release.json` was; one that is
      neither is said as a commit, with how far it is from the newest release when GitHub
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

  # The release of ehos_contract that renamed it from eh_os_contract, and the first ehos_app whose
  # installer moves a project to the new name.
  @renamed_in "0.16.0"
  @renaming_app "0.38.0"

  @impl Ehosctl.Command
  def name, do: :versions

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Show the version in use and the newest of each component."

  @impl Ehosctl.Command
  def chooses_installation?, do: true

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Show the version in use and the newest release of each EHOS component, if the " <>
          "installation accepts each, and the command that moves to the newest.",
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

      {:error, _kind, message, _refusal} ->
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
  The tags of the components that name the commits their git `dependencies` are locked at, for
  ones no `release.json` names: `ehos_app`'s releases before 0.7.0 are tags alone, made before
  eh-os D-91 gave a release its `release.json`. Each repository's tags are listed once, for all
  its components (`GitHub.tags/3`). Also the repositories whose tags GitHub did not list, with
  why (`unread`), and those it listed only in part before every commit was found (`cut`): a
  dependency of theirs no tag was found for is said as a commit.
  """
  @spec tagged(%{GitHub.component() => Project.dependency()}, keyword()) :: %{
          tags: %{GitHub.component() => GitHub.tag()},
          unread: [{String.t(), String.t()}],
          cut: [String.t()]
        }
  def tagged(dependencies, opts) do
    dependencies
    |> Enum.filter(&match?({_component, %{scm: :git}}, &1))
    |> Enum.group_by(
      fn {component, _dependency} -> GitHub.repository(component) end,
      fn {component, dependency} -> {component, dependency.commit} end
    )
    |> Task.async_stream(
      fn {repository, wanted} -> {repository, GitHub.tags(repository, wanted, opts)} end,
      timeout: :infinity
    )
    |> Enum.reduce(%{tags: %{}, unread: [], cut: []}, fn
      {:ok, {repository, {:ok, found, whole_or_cut}}}, all ->
        tags = for {{component, _commit}, tag} <- found, into: all.tags, do: {component, tag}
        cut = if whole_or_cut == :cut, do: [repository | all.cut], else: all.cut
        %{all | tags: tags, cut: Enum.sort(cut)}

      {:ok, {repository, {:error, _kind, message}}}, all ->
        %{all | unread: Enum.sort([{repository, message} | all.unread])}
    end)
  end

  @doc """
  The version a dependency is at, when it can be told without GitHub: a Hex dependency's, or the
  version in the tag of the component's form its `mix.exs` names.
  """
  @spec locked_version(GitHub.component(), Project.dependency()) :: String.t() | nil
  def locked_version(_component, %{scm: :hex, version: version}), do: version

  def locked_version(component, %{scm: :git, tag: tag}) when is_binary(tag) do
    prefix = if component in ~w(ehosctl ehos ehos_contract), do: "v", else: component <> "-v"

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
  EHOS and ehos_contract are all tagged `vX.Y.Z`, each in its own repository.
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
        do: ~w(ehosctl ehos ehos_app ehos_contract ehos_design),
        else: ~w(ehosctl ehos)

    listed = listed(components, opts)
    releases = Map.new(components, &{&1, releases(&1, listed)})
    jsons = jsons(components, releases, project, opts)
    tagged = by_tag(project, components, releases, jsons, opts)
    jsons = Map.merge(jsons, tagged_jsons(tagged.tags, releases, jsons, opts))
    installation = Task.await(asked, :infinity)

    # In this order, so that ehos_contract's row knows the ehos_app in use (`carrier/6`).
    {rows, _in_use} =
      Enum.map_reduce(components, %{}, fn component, in_use ->
        known = %{tags: tagged.tags, in_use: in_use}
        row = row(component, installation, releases, jsons, known, project, opts)
        {row, Map.put(in_use, component, row.in_use)}
      end)

    %{
      installation: {chosen, installation},
      dir: dir,
      project: project,
      project_note: project_note,
      github: for({_repository, {:error, _kind, message}} <- listed, do: message) |> Enum.uniq(),
      cut: for({repository, {:ok, _listed, :cut}} <- listed, do: repository) |> Enum.sort(),
      tags_unread: tagged.unread,
      tags_cut: tagged.cut,
      rows: rows,
      documents: documents(project, installation)
    }
  end

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
    |> Task.async_stream(&component_jsons(&1, releases, project, opts), timeout: :infinity)
    |> Enum.reduce(%{}, fn {:ok, jsons}, all -> Map.merge(all, jsons) end)
  end

  defp component_jsons(component, releases, project, opts) do
    case releases[component] do
      {:ok, [newest | _] = all} ->
        located = if project, do: located(project.deps[component], all, opts), else: %{}

        if Map.has_key?(located, key(newest)),
          do: located,
          else: Map.merge(located, read_jsons([newest], opts))

      _none ->
        %{}
    end
  end

  # The tags are asked of GitHub only for a git dependency no release.json names, and only when
  # its component's releases were listed: a GitHub that did not answer is not asked again.
  defp by_tag(nil, _components, _releases, _jsons, _opts), do: %{tags: %{}, unread: [], cut: []}

  defp by_tag(project, components, releases, jsons, opts) do
    components
    |> Enum.filter(fn component ->
      case {project.deps[component], releases[component]} do
        {%{scm: :git} = dependency, {:ok, all}} -> matched(dependency, all, jsons) == nil
        _other -> false
      end
    end)
    |> Map.new(&{&1, project.deps[&1]})
    |> tagged(opts)
  end

  # A tag that has a GitHub release whose release.json `located/3` did not read, being older than
  # the releases it reads: that one is read, to judge the release by it, or to say why not.
  defp tagged_jsons(tags, releases, jsons, opts) do
    for {component, tag} <- tags,
        {:ok, all} <- [releases[component]],
        release <- Enum.filter(all, &(&1.tag == tag.tag)),
        not Map.has_key?(jsons, key(release)) do
      release
    end
    |> read_jsons(opts)
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

  defp row("ehosctl", installation, releases, jsons, _known, _project, _opts) do
    version = Ehosctl.version()

    in_use = %{
      version: version,
      commit: if(dev?(version), do: Ehosctl.commit()),
      said:
        version <>
          if(dev?(version) and Ehosctl.commit(), do: " (#{short(Ehosctl.commit())})", else: "")
    }

    newest(releases["ehosctl"], jsons, %{
      component: "ehosctl",
      in_use: in_use,
      accepted: Acceptance.ehosctl(installation, version, Ehosctl.Version.accepts()),
      judge: fn release, json ->
        Acceptance.combine([
          Acceptance.ehosctl(installation, release.version, interfaces(json, "accepts")),
          Acceptance.release(installation, json)
        ])
      end,
      move: fn release, _json -> Ehosctl.upgrade_command(release.version) end
    })
  end

  defp row("ehos", installation, releases, jsons, _known, _project, _opts) do
    in_use =
      case installation do
        %{"version" => version} = described ->
          %{version: version, commit: described["commit"], said: Api.running(described)}

        {:unknown, _why} ->
          nil
      end

    newest(releases["ehos"], jsons, %{
      component: "ehos",
      in_use: in_use,
      accepted: :not_applicable,
      judge: fn _release, _json -> :not_applicable end,
      move: fn release, _json ->
        Output.offered(
          [
            "The operator upgrades EHOS: ",
            {:command, "ehosctl upgrade --to #{EhosPlatform.Shell.word(release.version)}"},
            ", with the server's tunnel open."
          ],
          "The operator upgrades EHOS with `ehosctl upgrade`, with the server's tunnel open."
        )
      end
    })
  end

  # `known` holds the tags found for the dependencies no release.json names, and what is in use
  # of the components whose rows came before.
  defp row(component, installation, releases, jsons, known, project, opts) do
    dependency = project.deps[component]
    all = releases_listed(releases[component])
    by_json = dependency && matched(dependency, all, jsons)
    tag = if dependency && !by_json, do: known.tags[component]
    matched = by_json || tag
    json = used_json(by_json, tag, all, jsons)

    newest = List.first(all)
    newest_json = newest && usable(jsons[key(newest)])

    carrier =
      if component == "ehos_contract" and newest,
        do:
          carrier(
            newest,
            releases["ehos_app"],
            jsons,
            installation,
            project,
            known.in_use["ehos_app"]
          )

    in_use = dependency_in_use(component, dependency, matched, newest, newest_json, opts)

    newest(releases[component], jsons, %{
      component: component,
      in_use: in_use,
      accepted: accepted(component, installation, dependency, json, project),
      judge: fn _release, json -> judge(component, installation, json, project) end,
      move: fn release, json -> move(component, dependency, release, json, carrier) end
    })
  end

  defp releases_listed({:ok, all}), do: all
  defp releases_listed(_other), do: []

  # A version known by its tag alone has no release.json it can be judged by.
  defp used_json(by_json, tag, all, jsons) do
    cond do
      by_json -> usable(jsons[key(by_json)])
      tag -> {:tag_alone, tag_alone(tag, all, jsons)}
      true -> nil
    end
  end

  defp dependency_in_use(_component, nil, _matched, _newest, _newest_json, _opts), do: nil

  defp dependency_in_use(component, dependency, matched, newest, newest_json, opts),
    do: in_use(component, dependency, matched, newest, newest_json, opts)

  # What is in use is judged by its own release's `release.json`: a commit that is no release's
  # says nothing of what it writes.
  defp accepted(_component, _installation, nil, _json, _project), do: :not_applicable
  defp accepted("ehos_design", _installation, _dependency, _json, _project), do: :not_applicable
  defp accepted(_component, {:unknown, why}, _dependency, _json, _project), do: {:unknown, why}

  defp accepted(_component, _described, _dependency, nil, _project),
    do: {:unknown, "it is no release ehosctl knows, so what it writes is not known"}

  defp accepted(_component, _described, _dependency, {:tag_alone, why}, _project),
    do: {:unknown, why}

  defp accepted(component, installation, _dependency, json, project),
    do: judge(component, installation, json, project)

  # Why a version known by its tag is not judged: what is known of its release's release.json.
  defp tag_alone(tag, releases, jsons) do
    case Enum.find(releases, &(&1.tag == tag.tag)) do
      nil ->
        "#{tag.tag} has no GitHub release, so no release.json says what it writes"

      release ->
        tag_json_said(jsons[key(release)], tag)
    end
  end

  defp tag_json_said({:unread, message}, _tag),
    do: "its release.json is not used: #{trim(message)}"

  defp tag_json_said(%{} = json, tag) do
    if commit_of(json),
      do: "the release.json of #{tag.tag} names another commit than its tag",
      else: "the release.json of #{tag.tag} names no commit"
  end

  defp tag_json_said(nil, _tag), do: "its release has no release.json to say what it writes"

  # Each release is judged both ways: what it writes against what the installation accepts, and
  # what the installation produces and runs against what the release accepts and requires.
  defp judge("ehos_app", installation, json, _project),
    do:
      Acceptance.combine([
        Acceptance.ehos_app(installation, interfaces(json, "produces")),
        Acceptance.release(installation, json)
      ])

  defp judge("ehos_contract", installation, json, project),
    do:
      Acceptance.combine([
        Acceptance.ehos_contract(installation, interfaces(json, "produces"), project.manifest),
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
              {:unknown, "its release.json is not used: #{trim(message)}"}

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

  defp newer?(_release, %{position: %{status: status}}) when status in ~w(behind diverged),
    do: true

  defp newer?(_release, %{position: %{status: _status}}), do: false

  defp newer?(release, %{version: version}) when is_binary(version) do
    case Version.parse(version) do
      {:ok, version} -> Version.compare(Version.parse!(release.version), version) == :gt
      :error -> false
    end
  end

  defp newer?(_release, _in_use), do: false

  defp move("ehos_app", dependency, release, json, _carrier) do
    "In mix.exs, set :ehos_app's `ref:` to #{commit_said(release, json)} and its requirement " <>
      "to \"== #{release.version}\" in place of its `#{pinned_by(dependency)}`, run `mix deps.get`, " <>
      "then `mix ehos_app.install` again."
  end

  # T-11: a project on ehos_contract's `main`, as `ehos_app` 0.5.0 to 0.6.1 wrote it, takes the
  # release from the ehos_app that pins it, whose installer moves both packages together;
  # `mix deps.update` would take main's newest commit instead. The ehos_app release is named when
  # a `release.json` already read requires a range this release is in (`carrier/6`); it says the
  # range, not the commit its installer pins, so the line promises no more than that.
  # Anything else, a fork, another branch, a tag or a commit of the project's own, the installer
  # keeps: it moves by hand, both packages and their requirements.
  defp move("ehos_contract", %{former: _former} = dependency, release, json, carrier) do
    if renamed?(release),
      do: rename(dependency, release),
      else: move_contract(dependency, release, json, carrier)
  end

  defp move("ehos_contract", dependency, release, json, carrier),
    do: move_contract(dependency, release, json, carrier)

  defp move("ehos_design", dependency, release, json, _carrier),
    do:
      "In mix.exs, set :ehos_design's `ref:` to #{commit_said(release, json)} in place of its " <>
        "`#{pinned_by(dependency)}`, then run `mix deps.get`."

  defp move_contract(%{branch: "main", url: url} = dependency, release, json, carrier) do
    upstream? =
      url =~
        ~r{\A(https://github\.com/|git@github\.com:)EmpoweredHouse/(ehos_contract|eh-os-contract)(\.git)?\z}i

    cond do
      upstream? and match?({:in_use, _app}, carrier) ->
        {:in_use, app} = carrier

        "it moves with ehos_app. The release.json of ehos_app #{app.version}, in use, admits " <>
          "ehos_contract #{release.version}. Run `mix ehos_app.install` again: it moves " <>
          "#{packages(dependency)} off main to the release that ehos_app pins."

      upstream? and match?({:newer, _app}, carrier) ->
        {:newer, app} = carrier

        "it moves with ehos_app. Move :ehos_app to #{app.version}, whose release.json admits " <>
          "ehos_contract #{release.version}. Then run `mix ehos_app.install` again: it moves " <>
          "#{packages(dependency)} off main to the release that ehos_app pins."

      upstream? ->
        "it moves with ehos_app. When a release of ehos_app pins ehos_contract " <>
          "#{release.version}, move :ehos_app to it. Then run `mix ehos_app.install` again: it " <>
          "moves #{packages(dependency)} off main to the release that ehos_app pins."

      true ->
        by_hand(dependency, release, json)
    end
  end

  defp move_contract(dependency, release, json, _carrier),
    do: by_hand(dependency, release, json)

  # A project whose mix.exs still names the library as it was before 0.16.0 cannot take a release
  # from 0.16.0 on under that name: the release has no `packages/eh_os_contract`. It moves to the
  # new name first, which ehos_app's installer does from 0.38.0 where the packages come from
  # EmpoweredHouse's repository, on `main` or on a commit an earlier ehos_app pinned, and leaves
  # otherwise: a fork, another branch or a commit of the project's own.
  defp renamed?(release), do: Version.compare(release.version, @renamed_in) != :lt

  defp rename(dependency, release),
    do:
      "mix.exs names it :#{dependency.former}, its name before 0.16.0, and ehos_contract " <>
        "#{release.version} has no package by that name. Move the project to the name " <>
        ":ehos_contract first. If #{packages(dependency)} come from EmpoweredHouse's " <>
        "repository, on `branch: \"main\"` or on a commit an earlier ehos_app pinned, move " <>
        ":ehos_app to " <>
        "#{@renaming_app} or later and run " <>
        "`mix ehos_app.install` again: it renames them. Otherwise, rename them by hand as " <>
        "ehos_contract's CHANGELOG.md says for 0.16.0. Then run `ehosctl versions` again."

  # The packages by the names the project's mix.exs gives them.
  defp packages(%{former: former}), do: ":#{former} and :#{former}_auth"
  defp packages(_dependency), do: ":ehos_contract and :ehos_contract_auth"

  # The newest ehos_app release, among those whose release.json was already read, whose
  # `requires.ehos_contract` is a range `contract`'s version is in, that the installation does
  # not refuse, and that is newer than the ehos_app in use (`{:newer, app}`) or is the one in use
  # (`{:in_use, app}`, whose installer has not been run again since): an older one would move it
  # back. No request is made for it: ehos_app's newest release.json is always
  # read, and for a git ehos_app no release.json names, up to #{@matched_releases} of the newest.
  defp carrier(contract, {:ok, [newest | _] = apps}, jsons, installation, project, app_in_use) do
    Enum.find_value(apps, fn app ->
      json = usable(jsons[key(app)])

      with true <- admits?(json, contract.version),
           false <- match?({:no, _why}, judge("ehos_app", installation, json, project)) do
        carried(json, app, newest, app_in_use)
      else
        _other -> nil
      end
    end)
  end

  defp carrier(_contract, _apps, _jsons, _installation, _project, _app_in_use), do: nil

  defp carried(json, app, newest, app_in_use) do
    cond do
      in_use?(json, app, app_in_use) -> {:in_use, app}
      forward?(app, newest, app_in_use) -> {:newer, app}
      true -> nil
    end
  end

  # Newer than the ehos_app in use, or there is none. A commit's position is GitHub's comparison
  # with the newest release alone, so it says nothing of an older one.
  # The release in use: a git dependency by the commit its release.json names, a Hex one by
  # its version.
  defp in_use?(_json, _app, nil), do: false

  defp in_use?(json, _app, %{commit: commit}) when is_binary(commit),
    do: commit_of(json) == commit

  defp in_use?(_json, app, in_use), do: in_use.version == app.version

  defp forward?(_app, _newest, nil), do: true
  defp forward?(app, newest, %{position: %{}} = in_use), do: app == newest and newer?(app, in_use)
  defp forward?(app, _newest, in_use), do: newer?(app, in_use)

  # `requires` names the library as it was named when ehos_app was released: `eh_os_contract`
  # before 0.16.0.
  defp admits?(%{"requires" => %{"ehos_contract" => requirement}}, version)
       when is_binary(requirement),
       do: in_range?(requirement, version)

  defp admits?(%{"requires" => %{"eh_os_contract" => requirement}}, version)
       when is_binary(requirement),
       do: in_range?(requirement, version)

  defp admits?(_json, _version), do: false

  defp in_range?(requirement, version) do
    case Version.parse_requirement(requirement) do
      {:ok, requirement} -> Version.match?(Version.parse!(version), requirement)
      :error -> false
    end
  end

  defp by_hand(dependency, release, json),
    do:
      "In mix.exs, set the `ref:` of #{packages(dependency)} to " <>
        "#{commit_said(release, json)} in place of their `#{pinned_by(dependency)}`, and their " <>
        "requirements to that release's versions, then run `mix deps.get`."

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
      ehos_yaml(project.ehos_yaml, installation)
    ] ++
      if project.manifest,
        do: [
          %{
            document: "manifest",
            schema: project.manifest,
            said: project.manifest,
            accepted: Acceptance.document(installation, project.manifest)
          }
        ],
        else: []
  end

  # An application with no ehos.yaml, which one with ehos_app among its dependencies can be,
  # says so rather than that it names no schema.
  defp ehos_yaml(:missing, _installation),
    do: %{
      document: "ehos.yaml",
      schema: nil,
      said: "no ehos.yaml",
      accepted: {:unknown, "the application has no ehos.yaml"}
    }

  defp ehos_yaml(schema, installation),
    do: %{
      document: "ehos.yaml",
      schema: schema,
      said: schema || "no schema ehosctl reads",
      accepted: Acceptance.document(installation, schema)
    }

  defp dev?(version), do: match?({:ok, %Version{pre: [_ | _]}}, Version.parse(version))
  defp short(commit), do: String.slice(commit, 0, 7)
  # An error's message quoted in a sentence of this report, without its full stop.
  defp trim(message), do: message |> Ehosctl.Failure.sentence() |> String.trim_trailing(".")

  # The words: where each source stands, a table, then why, then what moves each.
  defp text(report) do
    {chosen, installation} = report.installation

    head =
      [
        installation_line(chosen, installation),
        report.project && "Application: #{Refusal.shown(report.dir)}",
        report.project_note &&
          "ehosctl could not read the mix.lock of the application: #{report.project_note}",
        Enum.map(report.github, &"ehosctl could not read GitHub: #{&1}"),
        Enum.map(
          report.cut,
          &("GitHub listed only the first #{GitHub.max_listed()} releases of #{&1}, the newest " <>
              "it published. ehosctl does not show older ones.")
        ),
        Enum.map(
          report.tags_unread,
          fn {repository, message} ->
            "ehosctl could not read the tags of #{repository} on GitHub, so it shows a locked " <>
              "commit that only a tag names as a commit: #{message}"
          end
        ),
        Enum.map(
          report.tags_cut,
          &("GitHub listed only the first #{GitHub.max_listed()} tags of #{&1}. ehosctl shows " <>
              "a locked commit that only a later tag names as a commit.")
        )
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
          "NEWEST ACCEPTED" =>
            if(row.newest, do: verdict(row.newest_accepted), else: verdict(:not_applicable))
        }
      end) ++
        Enum.map(report.documents, fn document ->
          %{
            "COMPONENT" => document.document,
            "IN USE" => document.said,
            "ACCEPTED" => verdict(document.accepted),
            "NEWEST" => verdict(:not_applicable),
            "NEWEST ACCEPTED" => verdict(:not_applicable)
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
      "No installation is chosen, so ehosctl cannot show what an installation accepts. Run " <>
        "`ehosctl login`, or name an installation with --installation."

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
  defp newest_said(%{newest_unread: message}) when not is_nil(message), do: "not known"
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
      installation: installation_json(chosen, installation),
      application:
        report.project &&
          %{
            dir: report.dir,
            # `null` as for one that names no schema; the document's row says which.
            ehos_yaml: if(report.project.ehos_yaml != :missing, do: report.project.ehos_yaml),
            manifest: report.project.manifest
          },
      unread: %{
        github: report.github,
        github_tags:
          for(
            {repository, message} <- report.tags_unread,
            do: %{repository: repository, message: message}
          ),
        application: report.project_note
      },
      listed_in_part: report.cut,
      tags_listed_in_part: report.tags_cut,
      components: Enum.map(report.rows, &row_json/1),
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

  defp installation_json(nil, _installation), do: nil

  defp installation_json({name, %{"url" => url}}, installation),
    do: %{
      name: name,
      url: url,
      described: if(is_map(installation), do: installation),
      unknown: known_reason(installation)
    }

  defp row_json(row),
    do: %{
      component: row.component,
      in_use: row.in_use && Map.take(row.in_use, [:version, :commit, :said]),
      accepted: verdict_json(row.accepted),
      newest: row.newest && Map.take(row.newest, [:version, :tag, :url]),
      newest_accepted: row.newest && verdict_json(row.newest_accepted),
      move: row.move
    }

  defp verdict_json(:yes), do: %{verdict: "yes", why: nil}
  defp verdict_json({:no, why}), do: %{verdict: "no", why: why}
  defp verdict_json({:unknown, why}), do: %{verdict: "unknown", why: why}
  defp verdict_json(:not_applicable), do: %{verdict: "not_applicable", why: nil}
end

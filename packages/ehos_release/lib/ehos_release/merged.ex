defmodule EhosRelease.Merged do
  @moduledoc """
  The stage `merged` of the release workflow, in a job that holds no key (eh-os D-205, "A
  release", step 4; T-34): on the commit a push to `main` brings, it finds the release pull request
  merged there, and refuses unless an administrator merged it, it changed nothing but the
  release's files, its version is in every version file, no fragment of its component is left, a
  protected tag names every pin, no other workflow names the App's key, and its tag does not exist
  yet.

  It reads the pull request from GitHub itself, and decides nothing on another job's word. Every
  check runs before any refusal is answered. `opts` names the ways out: `:git` and `:github`.
  """

  alias EhosRelease.{Config, Fragment, PinCheck, Pins, Source, VersionFile, Workflows}

  @typedoc "The release `merged/4` found and checked."
  @type release :: %{
          component: String.t(),
          version: String.t(),
          tag: String.t(),
          pull_request: pos_integer()
        }

  @branch ~r/\Arelease\/([a-z][a-z0-9_]*)-(\d+\.\d+\.\d+)\z/

  @doc """
  Checks the release merged at `commit` of `repository`, whose checkout at that commit is in
  `dir`.
  """
  @spec merged(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, release()} | {:error, [String.t()]}
  def merged(dir, repository, commit, opts \\ []) do
    github = Keyword.get(opts, :github, EhosRelease.GitHubImpl)
    git = Keyword.get(opts, :git, EhosRelease.GitImpl)
    source = Source.checkout(dir)

    with :ok <- commit(commit),
         {:ok, pull} <- release_pull(github, repository, commit),
         {:ok, config} <- EhosRelease.config(source),
         {:ok, component} <- one(Config.component(config, pull.component)),
         {:ok, changie_config} <- EhosRelease.changie_config(source),
         :ok <- EhosRelease.consistent(component, changie_config) do
      {fragments, fragment_refusals} =
        Fragment.read(source, changie_config, component.changie_projects)

      {pins, pin_refusals} = Pins.read(source, component.pins)
      tag = component.tag_prefix <> pull.version

      refusals =
        admin(github, repository, pull) ++
          files(github, repository, pull, component, changie_config) ++
          versions(source, component, pull.version) ++
          fragment_refusals ++
          left(fragments, component) ++
          pin_refusals ++
          PinCheck.tagged(pins, opts) ++
          Workflows.key_refusals(source, repository) ++ tag_free(git, repository, tag)

      case refusals do
        [] ->
          {:ok,
           %{
             component: component.name,
             version: pull.version,
             tag: tag,
             pull_request: pull.number
           }}

        refusals ->
          {:error, refusals}
      end
    end
  end

  defp commit(commit) do
    if commit =~ ~r/\A[0-9a-f]{40}\z/,
      do: :ok,
      else: {:error, ["#{inspect(commit)} is not a full commit"]}
  end

  # The pull requests of a commit come without `merged_by`, so the one that matches is read
  # again whole, and checked again on what that answer says.
  defp release_pull(github, repository, commit) do
    with {:ok, pulls} <- github.commit_pulls(repository, commit),
         {:ok, candidate} <-
           pulls |> Enum.find_value(&release(&1, repository, commit)) |> found(commit),
         {:ok, pull} <- github.pull(repository, candidate.number),
         {:ok, release} <- pull |> release(repository, commit) |> found(commit) do
      merged_by(release, pull)
    else
      {:error, reasons} when is_list(reasons) -> {:error, reasons}
      {:error, reason} -> {:error, [reason]}
    end
  end

  defp merged_by(release, %{"merged_by" => %{"login" => login}}) when is_binary(login),
    do: {:ok, Map.put(release, :merged_by, login)}

  defp merged_by(release, _pull),
    do: {:error, ["GitHub does not say who merged pull request #{release.number}"]}

  defp release(
         %{
           "number" => number,
           "merged_at" => merged_at,
           "merge_commit_sha" => commit,
           "base" => %{"ref" => "main"},
           "head" => %{"ref" => branch, "repo" => %{"full_name" => head_repository}}
         },
         repository,
         commit
       )
       when is_binary(merged_at) and is_binary(branch) and is_binary(head_repository) do
    with true <- String.downcase(head_repository) == String.downcase(repository),
         [_, component, version] <- Regex.run(@branch, branch) do
      %{number: number, component: component, version: version}
    else
      _other -> nil
    end
  end

  defp release(_pull, _repository, _commit), do: nil

  defp found(nil, commit),
    do:
      {:error,
       [
         "#{commit} is not the merge commit of a release pull request, " <>
           "release/<component>-X.Y.Z of this repository merged into main"
       ]}

  defp found(pull, _commit), do: {:ok, pull}

  # D-205: the people the tag ruleset admits; a role that cannot be read is a refusal.
  defp admin(github, repository, pull) do
    case github.permission(repository, pull.merged_by) do
      {:ok, "admin"} ->
        []

      {:ok, role} ->
        ["#{pull.merged_by} merged pull request #{pull.number} with the role #{role}, not admin"]

      {:error, reason} ->
        ["the role of #{pull.merged_by}, who merged pull request #{pull.number}: #{reason}"]
    end
  end

  defp files(github, repository, pull, component, changie_config) do
    case github.pull_files(repository, pull.number) do
      {:ok, files} -> Enum.flat_map(files, &file(&1, pull, component, changie_config))
      {:error, reason} -> [reason]
    end
  end

  # A changelog is written, a fragment added or deleted under `.changes/`, and a version file
  # changed on its version lines alone.
  defp file(%{"filename" => name, "status" => status} = file, pull, component, changie_config) do
    lines = for %{path: ^name, line: line} <- component.version_files, do: line

    cond do
      status not in ["added", "modified", "removed"] ->
        ["pull request #{pull.number} has #{name} #{status}, which a release never does"]

      lines != [] ->
        version_change(file, name, lines, pull)

      name in component.changelogs and status != "removed" ->
        []

      String.starts_with?(name, changie_config.changes_dir <> "/") ->
        []

      true ->
        ["pull request #{pull.number} changes #{name}, which is not a file of the release"]
    end
  end

  defp file(_file, pull, _component, _changie_config),
    do: ["pull request #{pull.number} lists a file without a name or a status"]

  # The lines that hold the version, each once, and no other: a release cannot add a dependency
  # to a `mix.exs` (T-34). eh-os's `Chart.yaml` has two, `version` and `appVersion`.
  defp version_change(file, path, lines, pull) do
    patch = file |> Map.get("patch", "") |> to_string() |> String.split("\n")
    removed = for "-" <> text <- patch, do: text
    added = for "+" <> text <- patch, do: text
    wanted = Enum.map(lines, &String.replace(&1, "{version}", pull.version))

    if file["status"] == "modified" and length(removed) == length(lines) and
         Enum.sort(added) == Enum.sort(wanted),
       do: [],
       else: ["pull request #{pull.number} changes #{path} beyond its version lines"]
  end

  defp versions(source, component, version) do
    Enum.flat_map(component.version_files, fn %{path: path, line: line} ->
      with {:ok, contents} <- Source.read(source, path),
           {:ok, ^version} <- VersionFile.version(contents, line) do
        []
      else
        {:ok, other} -> ["#{path} holds #{other}, not #{version}"]
        :missing -> ["#{path} is missing"]
        {:error, reason} -> ["#{path}: #{reason}"]
      end
    end)
  end

  defp left([], _component), do: []

  defp left(fragments, component) do
    files = Enum.map_join(fragments, ", ", & &1.file)

    [
      "fragments of #{component.name} are left on the merge commit, merged after the release " <>
        "was opened: #{files}"
    ]
  end

  defp tag_free(git, repository, tag) do
    case git.tags(repository) do
      {:ok, %{^tag => _commit}} -> ["the tag #{tag} exists already"]
      {:ok, _tags} -> []
      {:error, reason} -> [reason]
    end
  end

  defp one({:ok, value}), do: {:ok, value}
  defp one({:error, reason}), do: {:error, [reason]}
end

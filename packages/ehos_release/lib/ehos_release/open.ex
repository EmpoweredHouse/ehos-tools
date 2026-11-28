defmodule EhosRelease.Open do
  @moduledoc """
  The stage `open` of the release workflow, in the job that holds no key (eh-os D-205, "A
  release", step 1; T-34): for one component of the checkout, it collects the fragments, checks the
  pins and the workflows, computes the version, and makes the release's change in the checkout,
  which it answers as a patch, with the pull request's description.

  Every check runs before any refusal is answered, so one run names all that is wrong. Nothing is
  changed in the checkout until every check has passed.

  `opts` names the ways out: `:git`, `:github` and `:changie`.
  """

  alias EhosRelease.{
    Config,
    Description,
    Fragment,
    PinCheck,
    Pins,
    Source,
    Version,
    VersionFile,
    Workflows
  }

  @typedoc "The release `open/5` prepared."
  @type release :: %{
          component: String.t(),
          version: String.t(),
          tag: String.t(),
          branch: String.t(),
          patch: binary(),
          description: String.t()
        }

  @doc """
  Prepares the release of `component` from the checkout in `dir` of `repository`, at the version
  `input` when it is given, otherwise at the floor its fragments give.
  """
  @spec open(Path.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, release()} | {:error, [String.t()]}
  def open(dir, repository, component, input, opts \\ []) do
    git = Keyword.get(opts, :git, EhosRelease.GitImpl)
    changie = Keyword.get(opts, :changie, EhosRelease.ChangieImpl)
    source = Source.checkout(dir)

    with {:ok, config} <- EhosRelease.config(source),
         {:ok, component} <- one(Config.component(config, component)),
         {:ok, changie_config} <- EhosRelease.changie_config(source),
         :ok <- EhosRelease.consistent(component, changie_config),
         {:ok, plan} <- plan(source, repository, component, changie_config, input, opts),
         :ok <- apply_plan(dir, component, plan, changie),
         {:ok, patch} <- one(git.patch(dir)),
         {:ok, notes} <- notes(source, changie_config, plan) do
      issues = issues(plan.fragments, Keyword.get(opts, :github, EhosRelease.GitHubImpl))
      tag = component.tag_prefix <> plan.version

      {:ok,
       %{
         component: component.name,
         version: plan.version,
         tag: tag,
         branch: "release/#{component.name}-#{plan.version}",
         patch: patch,
         description:
           Description.write(%{
             component: component.name,
             version: plan.version,
             tag: tag,
             floor: plan.floor,
             highest: plan.highest,
             notes: notes,
             issues: issues
           })
       }}
    end
  end

  defp plan(source, repository, component, changie_config, input, opts) do
    git = Keyword.get(opts, :git, EhosRelease.GitImpl)
    changie = Keyword.get(opts, :changie, EhosRelease.ChangieImpl)

    {fragments, fragment_refusals} =
      Fragment.read(source, changie_config, component.changie_projects)

    {pins, pin_refusals} = Pins.read(source, component.pins)
    {floors, floor_refusals} = floors(source.dir, component, changie)
    {highest, tag_refusals} = highest(git, repository, component.tag_prefix)

    refusals =
      fragment_refusals ++
        none_left(fragments, floors, component) ++
        pin_refusals ++
        PinCheck.tagged(pins, opts) ++
        Workflows.key_refusals(source) ++ floor_refusals ++ tag_refusals

    with :ok <- refused(refusals),
         {:ok, version} <- one(Version.choose(Map.values(floors), input, highest)) do
      {:ok,
       %{
         version: version,
         floor: Enum.max(Map.values(floors), Version),
         highest: highest,
         projects: Map.keys(floors),
         fragments: fragments
       }}
    end
  end

  defp none_left([], _floors, component),
    do: ["#{component.name} has no changelog fragment, so there is nothing to release"]

  defp none_left(_fragments, floors, component) when map_size(floors) == 0,
    do: ["changie gives no next version of #{Enum.join(component.changie_projects, ", ")}"]

  defp none_left(_fragments, _floors, _component), do: []

  # The floor of each project that has fragments; a project with none is not released.
  defp floors(dir, component, changie) do
    component.changie_projects
    |> Enum.map(&{&1, changie.next(dir, &1)})
    |> Enum.reduce({%{}, []}, fn
      {project, {:ok, version}}, {floors, refusals} ->
        {Map.put(floors, project, version), refusals}

      {_project, :none}, acc ->
        acc

      {_project, {:error, reason}}, {floors, refusals} ->
        {floors, [reason | refusals]}
    end)
    |> then(fn {floors, refusals} -> {floors, Enum.reverse(refusals)} end)
  end

  defp highest(git, repository, prefix) do
    case git.tags(repository) do
      {:ok, tags} -> {Version.highest(Map.keys(tags), prefix), []}
      {:error, reason} -> {nil, [reason]}
    end
  end

  defp apply_plan(dir, component, plan, changie) do
    with :ok <- each(plan.projects, &changie.batch(dir, &1, plan.version)),
         :ok <- changie.merge(dir) do
      each(component.version_files, &write_version(dir, &1, plan.version))
    end
    |> refused_one()
  end

  defp write_version(dir, %{path: path, line: line}, version) do
    file = Path.join(dir, path)

    with {:ok, contents} <- read(file, path),
         {:ok, changed} <- VersionFile.replace(contents, line, version) do
      File.write(file, changed)
    else
      {:error, reason} -> {:error, "#{path}: #{reason}"}
    end
  end

  defp read(file, path) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> {:error, "#{path} could not be read"}
    end
  end

  defp notes(source, changie_config, plan) do
    plan.projects
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn project, {:ok, acc} ->
      path = Path.join([changie_config.changes_dir, project, "#{plan.version}.md"])

      case Source.read(source, path) do
        {:ok, text} -> {:cont, {:ok, [{changie_config.projects[project], text} | acc]}}
        _missing -> {:halt, {:error, ["changie wrote no notes in #{path}"]}}
      end
    end)
    |> then(fn
      {:ok, notes} -> {:ok, Enum.reverse(notes)}
      error -> error
    end)
  end

  defp issues(fragments, github) do
    fragments
    |> Enum.map(& &1.issue)
    |> Enum.uniq()
    |> Enum.map(fn issue ->
      {repository, number} = Fragment.issue(issue)

      case github.issue_state(repository, number) do
        {:ok, state} -> {issue, state}
        {:error, _reason} -> {issue, :unknown}
      end
    end)
  end

  defp each(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp refused([]), do: :ok
  defp refused(refusals), do: {:error, refusals}

  defp refused_one(:ok), do: :ok
  defp refused_one({:error, reason}), do: {:error, [reason]}

  defp one({:ok, value}), do: {:ok, value}
  defp one({:error, reason}), do: {:error, [reason]}
end

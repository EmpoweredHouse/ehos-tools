defmodule EhosRelease.Pins do
  @moduledoc """
  Reads every pin a repository keeps into eh-os, ehos-tools or ehos_contract, from the places
  its `EhosRelease.Config` names, each as data (eh-os D-205, "Between releases"; T-34):

  - `mix_lock`: each git dependency of a `mix.lock`, at the commit the lock holds, so a `branch:`
    dependency is read at the commit it resolved to; its path is its `sparse` directory;
  - `workflows`: each `uses:` of a job or a step in the directory's `.yml` and `.yaml` files;
  - `claude_settings`: each GitHub marketplace of a `.claude/settings.json`, at its `ref`;
  - `json`: a file whose object maps a name to `{"repository": "owner/name", "path": "…",
    "ref": "…"}`, `path` left out for the repository itself, where a package keeps the pins its
    code uses.

  Pins into any other repository are not D-205's, and are left out. A ref that is neither a full
  commit nor a tag's name, and a marketplace with no `ref`, which follows a branch, are refused.
  """

  alias EhosRelease.{MixLock, Pin, Producers, Source}

  @workflow_extensions [".yml", ".yaml"]

  @doc """
  The pins in `sources`, and a refusal for each that cannot be read. A file that is missing is a
  refusal, unless `missing: :empty` says that it may be, as at a pull request's base.
  """
  @spec read(Source.t(), [%{kind: String.t(), path: String.t()}], keyword()) ::
          {[Pin.t()], [String.t()]}
  def read(%Source{} = source, sources, opts \\ []) do
    missing = Keyword.get(opts, :missing, :refuse)

    {pins, refusals} =
      sources
      |> Enum.map(&read_source(source, &1, missing))
      |> Enum.unzip()

    {pins |> List.flatten() |> Enum.filter(&Producers.producer?(&1.repository)),
     List.flatten(refusals)}
  end

  @doc """
  The pins of `head` that `base` does not have with the same ref: those a pull request adds or
  moves.
  """
  @spec changed([Pin.t()], [Pin.t()]) :: [Pin.t()]
  def changed(base, head) do
    before = MapSet.new(base, &{key(&1), &1.ref})
    Enum.reject(head, &MapSet.member?(before, {key(&1), &1.ref}))
  end

  defp key(%Pin{} = pin), do: {pin.file, pin.name, String.downcase(pin.repository), pin.path}

  defp read_source(source, %{kind: "workflows", path: dir}, _missing) do
    case Source.list(source, dir, @workflow_extensions) do
      {:ok, files} ->
        files |> Enum.map(&read_file(source, "workflows", &1, :refuse)) |> Enum.unzip()

      {:error, reason} ->
        {[], [reason]}
    end
  end

  defp read_source(source, %{kind: kind, path: path}, missing),
    do: read_file(source, kind, path, missing)

  defp read_file(source, kind, path, missing) do
    case Source.read(source, path) do
      {:ok, contents} -> parse(kind, path, contents)
      :missing when missing == :empty -> {[], []}
      :missing -> {[], ["#{path} is missing"]}
      {:error, reason} -> {[], [reason]}
    end
  end

  defp parse("mix_lock", path, contents) do
    case MixLock.parse(contents) do
      {:ok, entries} ->
        entries
        |> MixLock.git_dependencies()
        |> Enum.map(fn {name, url, commit, opts} ->
          pin(path, name, url, Map.get(opts, "sparse", ""), commit)
        end)
        |> split()

      {:error, reason} ->
        {[], ["#{path}: #{reason}"]}
    end
  end

  defp parse("workflows", path, contents) do
    case YamlElixir.read_from_string(contents) do
      {:ok, %{"jobs" => %{} = jobs}} ->
        jobs |> Enum.sort() |> Enum.flat_map(&uses(path, &1)) |> split()

      {:ok, _other} ->
        {[], []}

      {:error, _reason} ->
        {[], ["#{path} is not valid YAML"]}
    end
  end

  defp parse("claude_settings", path, contents) do
    case JSON.decode(contents) do
      {:ok, %{} = settings} ->
        settings
        |> Map.get("extraKnownMarketplaces", %{})
        |> marketplaces()
        |> Enum.map(fn {name, source} -> marketplace(path, name, source) end)
        |> split()

      _other ->
        {[], ["#{path} is not a JSON object"]}
    end
  end

  defp parse("json", path, contents) do
    case JSON.decode(contents) do
      {:ok, %{} = pins} -> pins |> Enum.sort() |> Enum.map(&json_pin(path, &1)) |> split()
      _other -> {[], ["#{path} is not a JSON object"]}
    end
  end

  defp uses(path, {job_name, %{} = job}) do
    steps =
      for {%{"uses" => uses}, index} <- Enum.with_index(Map.get(job, "steps") || [], 1),
          is_binary(uses),
          do: {"#{job_name}, step #{index}", uses}

    own = if is_binary(job["uses"]), do: [{job_name, job["uses"]}], else: []

    for {name, uses} <- own ++ steps, not local_or_image?(uses) do
      workflow_pin(path, name, uses)
    end
  end

  defp uses(_path, _job), do: []

  defp local_or_image?(uses),
    do: String.starts_with?(uses, "./") or String.starts_with?(uses, "docker://")

  defp workflow_pin(file, name, uses) do
    case Regex.run(~r{\A([^/@]+)/([^/@]+)(?:/([^@]+))?@(.+)\z}, uses) do
      [_, owner, repo, sub_path, ref] -> pin_named(file, name, "#{owner}/#{repo}", sub_path, ref)
      [_, owner, repo, ref] -> pin_named(file, name, "#{owner}/#{repo}", "", ref)
      nil -> {:error, "#{file}: #{name} uses #{inspect(uses)}, which names no repository and ref"}
    end
  end

  defp marketplaces(%{} = marketplaces), do: Enum.sort(marketplaces)
  defp marketplaces(_other), do: []

  defp marketplace(file, name, %{"source" => %{"source" => "github", "repo" => repo} = source})
       when is_binary(repo) do
    case source["ref"] do
      ref when is_binary(ref) ->
        pin_named(file, "marketplace #{name}", repo, ".claude-plugin/marketplace.json", ref)

      _none ->
        if Producers.producer?(repo),
          do: {:error, "#{file}: marketplace #{name} has no ref, so it follows a branch"},
          else: :skip
    end
  end

  defp marketplace(_file, _name, _source), do: :skip

  defp json_pin(file, {name, %{"repository" => repository, "ref" => ref} = pin})
       when is_binary(repository) and is_binary(ref) do
    pin_named(file, name, repository, Map.get(pin, "path", ""), ref)
  end

  defp json_pin(file, {name, _pin}),
    do: {:error, "#{file}: #{name} needs a repository and a ref"}

  defp pin(file, name, url, path, ref) do
    case Regex.run(
           ~r{\A(?:https://github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?/?\z},
           url
         ) do
      [_, repository] -> pin_named(file, name, repository, path, ref)
      nil -> :skip
    end
  end

  defp pin_named(file, name, repository, path, ref) do
    cond do
      not is_binary(path) ->
        {:error, "#{file}: #{name}'s path is not a string"}

      not Producers.producer?(repository) ->
        :skip

      ref =~ ~r/\A[0-9a-f]{40}\z/ or ref =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/ ->
        {:ok, %Pin{file: file, name: name, repository: repository, path: path, ref: ref}}

      true ->
        {:error,
         "#{file}: #{name} pins #{repository} at #{inspect(ref)}, " <>
           "which is neither a full commit nor a tag"}
    end
  end

  defp split(results) do
    {for({:ok, pin} <- results, do: pin), for({:error, reason} <- results, do: reason)}
  end
end

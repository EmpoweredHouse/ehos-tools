defmodule EhosRelease.Config do
  @moduledoc """
  What a repository says about its components, read from its `.github/ehos-release.json` (T-34).

  ```json
  {
    "components": {
      "ehos_release": {
        "tag_prefix": "ehos_release-v",
        "changie_projects": ["ehos_release"],
        "changelogs": ["packages/ehos_release/CHANGELOG.md"],
        "version_files": [
          {"path": "packages/ehos_release/mix.exs", "line": "  @version \\"{version}\\""}
        ],
        "pins": [
          {"kind": "mix_lock", "path": "packages/ehos_release/mix.lock"},
          {"kind": "workflows", "path": ".github/workflows"}
        ]
      }
    }
  }
  ```

  - `tag_prefix` names the component's tags, `<prefix>X.Y.Z`; `ehosctl`'s is `v`.
  - `changie_projects` and `changelogs` are the changie projects a release batches and the
    changelogs it writes; the job that opens the pull request reads `changelogs` with `jq` to
    know which files the release may change.
  - `version_files` are the files that carry the version, each with the one whole line that holds
    it, `{version}` where the version goes. A release refuses a file where that line is not found
    exactly once.
  - `pins` are where the component pins the three repositories, each a `kind` that says how to
    read it (`EhosRelease.Pins`) and a path, which for `workflows` is a directory.

  The file is data: it is read as JSON and checked here, and never evaluated.
  """

  alias EhosRelease.Config.Component

  @path ".github/ehos-release.json"
  @pin_kinds ~w(mix_lock workflows claude_settings json)

  defstruct components: %{}

  @typedoc "A repository's components, by name."
  @type t :: %__MODULE__{components: %{String.t() => Component.t()}}

  defmodule Component do
    @moduledoc "One component of `EhosRelease.Config`, as its fields say there."

    @enforce_keys [:name, :tag_prefix, :changie_projects, :changelogs, :version_files, :pins]
    defstruct @enforce_keys

    @typedoc "A file that carries the version, and the line that holds it, with `{version}`."
    @type version_file :: %{path: String.t(), line: String.t()}

    @typedoc "Where a component pins the three repositories, and how that file is read."
    @type pin_source :: %{kind: String.t(), path: String.t()}

    @typedoc "A component."
    @type t :: %__MODULE__{
            name: String.t(),
            tag_prefix: String.t(),
            changie_projects: [String.t()],
            changelogs: [String.t()],
            version_files: [version_file()],
            pins: [pin_source()]
          }
  end

  @doc "Where in a repository the file is."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  Reads the configuration from its JSON text.

      iex> {:ok, config} = EhosRelease.Config.parse(~s({"components": {"a": {"tag_prefix": "a-v",
      ...>   "changie_projects": ["a"], "changelogs": ["CHANGELOG.md"],
      ...>   "version_files": [{"path": "Chart.yaml", "line": "version: {version}"}],
      ...>   "pins": [{"kind": "mix_lock", "path": "mix.lock"}]}}}))
      iex> config.components["a"].tag_prefix
      "a-v"

      iex> EhosRelease.Config.parse(~s({"components": {}}))
      {:error, ".github/ehos-release.json names no component"}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(json) do
    with {:ok, %{"components" => %{} = components}} <- decode(json),
         :ok <- some(components),
         {:ok, parsed} <- components(components) do
      {:ok, %__MODULE__{components: parsed}}
    else
      {:ok, _other} -> {:error, "#{@path} has no object `components`"}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The component named `name`, or a refusal that lists the ones there are.
  """
  @spec component(t(), String.t()) :: {:ok, Component.t()} | {:error, String.t()}
  def component(%__MODULE__{components: components}, name) do
    case Map.fetch(components, name) do
      {:ok, component} ->
        {:ok, component}

      :error ->
        {:error,
         "#{inspect(name)} is not a component of #{@path}: " <>
           Enum.join(Enum.sort(Map.keys(components)), ", ")}
    end
  end

  @doc "Every place any component pins the three repositories, each once."
  @spec pin_sources(t()) :: [Component.pin_source()]
  def pin_sources(%__MODULE__{components: components}) do
    components |> Map.values() |> Enum.flat_map(& &1.pins) |> Enum.uniq() |> Enum.sort()
  end

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, "#{@path} is not valid JSON"}
    end
  end

  defp some(components) when map_size(components) == 0,
    do: {:error, "#{@path} names no component"}

  defp some(_components), do: :ok

  defp components(components) do
    components
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, fields}, {:ok, acc} ->
      case component_of(name, fields) do
        {:ok, component} -> {:cont, {:ok, Map.put(acc, name, component)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp component_of(name, %{} = fields) do
    with :ok <- check(name =~ ~r/\A[a-z][a-z0-9_]*\z/, "#{inspect(name)} is not a component name"),
         {:ok, prefix} <- prefix(name, fields["tag_prefix"]),
         {:ok, projects} <- strings(name, "changie_projects", fields["changie_projects"]),
         {:ok, changelogs} <- paths(name, "changelogs", fields["changelogs"]),
         {:ok, version_files} <- version_files(name, fields["version_files"]),
         {:ok, pins} <- pins(name, fields["pins"]) do
      {:ok,
       %Component{
         name: name,
         tag_prefix: prefix,
         changie_projects: projects,
         changelogs: changelogs,
         version_files: version_files,
         pins: pins
       }}
    end
  end

  defp component_of(name, _fields), do: {:error, "#{@path}: #{name} is not an object"}

  defp prefix(name, prefix) when is_binary(prefix) do
    check(prefix =~ ~r/\A[A-Za-z0-9_.-]*\z/, "#{@path}: #{name}'s tag_prefix is not a tag prefix")
    |> ok(prefix)
  end

  defp prefix(name, _prefix), do: {:error, "#{@path}: #{name} has no tag_prefix"}

  defp strings(name, field, [_ | _] = values) do
    check(Enum.all?(values, &is_binary/1), "#{@path}: #{name}'s #{field} holds a non-string")
    |> ok(values)
  end

  defp strings(name, field, _values),
    do: {:error, "#{@path}: #{name}'s #{field} is not a list of strings"}

  defp paths(name, field, values) do
    with {:ok, values} <- strings(name, field, values) do
      check(Enum.all?(values, &relative?/1), "#{@path}: #{name}'s #{field} leaves the repository")
      |> ok(values)
    end
  end

  defp version_files(name, [_ | _] = files) do
    all(files, fn
      %{"path" => path, "line" => line} when is_binary(path) and is_binary(line) ->
        with :ok <- check(relative?(path), "#{@path}: #{name}'s #{path} leaves the repository"),
             :ok <-
               check(
                 one_version?(line),
                 "#{@path}: #{name}'s line for #{path} " <> "does not hold {version} exactly once"
               ) do
          {:ok, %{path: path, line: line}}
        end

      _other ->
        {:error, "#{@path}: #{name}'s version_files need a path and a line each"}
    end)
  end

  defp version_files(name, _files), do: {:error, "#{@path}: #{name} has no version_files"}

  defp pins(name, pins) when is_list(pins) do
    all(pins, fn
      %{"kind" => kind, "path" => path} when kind in @pin_kinds and is_binary(path) ->
        check(relative?(path), "#{@path}: #{name}'s #{path} leaves the repository")
        |> ok(%{kind: kind, path: path})

      _other ->
        {:error,
         "#{@path}: #{name}'s pins need a kind (#{Enum.join(@pin_kinds, ", ")}) and a path each"}
    end)
  end

  defp pins(name, _pins), do: {:error, "#{@path}: #{name}'s pins is not a list"}

  defp all(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, read} -> {:cont, {:ok, [read | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, Enum.reverse(read)}
      error -> error
    end
  end

  defp one_version?(line), do: length(String.split(line, "{version}")) == 2

  defp relative?(path) do
    path != "" and Path.type(path) == :relative and ".." not in Path.split(path)
  end

  defp check(true, _message), do: :ok
  defp check(false, message), do: {:error, message}

  defp ok(:ok, value), do: {:ok, value}
  defp ok(error, _value), do: error
end

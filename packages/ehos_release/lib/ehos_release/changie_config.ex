defmodule EhosRelease.ChangieConfig do
  @moduledoc """
  What a repository's `.changie.yaml` says that a release needs: where the fragments are, and each
  project's changelog. Read as YAML, never evaluated. A configuration with `replacements`, which
  changie applies to any path it names, `.git/config` included, is refused.
  """

  @enforce_keys [:changes_dir, :unreleased_dir, :projects]
  defstruct @enforce_keys

  @typedoc "Where the fragments are, and each project's changelog, by the project's key."
  @type t :: %__MODULE__{
          changes_dir: String.t(),
          unreleased_dir: String.t(),
          projects: %{String.t() => String.t()}
        }

  @doc "Where in a repository the file is."
  @spec path() :: String.t()
  def path, do: ".changie.yaml"

  @doc """
  Reads it from its YAML text.

      iex> EhosRelease.ChangieConfig.parse(\"""
      ...> changesDir: .changes
      ...> unreleasedDir: unreleased
      ...> projects:
      ...>   - key: shop
      ...>     changelog: packages/shop/CHANGELOG.md
      ...> \""")
      {:ok, %EhosRelease.ChangieConfig{changes_dir: ".changes", unreleased_dir: "unreleased",
        projects: %{"shop" => "packages/shop/CHANGELOG.md"}}}

      iex> EhosRelease.ChangieConfig.parse("replacements:\\n  - path: .git/config\\n")
      {:error, ".changie.yaml has replacements, which would let a release write any file of the checkout"}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{"replacements" => _replacements}} ->
        {:error,
         ".changie.yaml has replacements, which would let a release write any file of the " <>
           "checkout"}

      {:ok,
       %{"changesDir" => changes, "unreleasedDir" => unreleased, "projects" => [_ | _] = projects}}
      when is_binary(changes) and is_binary(unreleased) ->
        projects(changes, unreleased, projects)

      {:ok, _other} ->
        {:error, ".changie.yaml needs changesDir, unreleasedDir and projects"}

      {:error, _reason} ->
        {:error, ".changie.yaml is not valid YAML"}
    end
  end

  @doc "The directory that holds the fragments not released yet."
  @spec unreleased(t()) :: String.t()
  def unreleased(%__MODULE__{} = config), do: Path.join(config.changes_dir, config.unreleased_dir)

  defp projects(changes, unreleased, projects) do
    read =
      for %{"key" => key, "changelog" => log} <- projects,
          is_binary(key) and is_binary(log),
          do: {key, log}

    if length(read) == length(projects),
      do:
        {:ok,
         %__MODULE__{changes_dir: changes, unreleased_dir: unreleased, projects: Map.new(read)}},
      else: {:error, ".changie.yaml has a project without a key or a changelog"}
  end
end

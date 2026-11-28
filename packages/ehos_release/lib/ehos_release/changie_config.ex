defmodule EhosRelease.ChangieConfig do
  @moduledoc """
  What a repository's `.changie.yaml` says that a release needs: where the fragments are, and each
  project's changelog. Read as YAML, never evaluated. Only the keys a release needs are accepted,
  each held to what it may name: changie's `replacements`, at the top or in a project, rewrite any
  file, `.git/config` included, and changie joins its paths without a check, so anything else is
  refused.
  """

  # The keys a release reads changie's configuration with, and what each may hold: changie also
  # takes `replacements`, which rewrite any file, and paths it joins without a check (a
  # `headerPath` of `../../x` copies that file into a changelog), so a key not here is refused.
  @top %{
    "changesDir" => :name,
    "unreleasedDir" => :name,
    "changelogPath" => :path,
    "headerPath" => :name,
    "versionExt" => :name,
    "versionFormat" => :string,
    "kindFormat" => :string,
    "changeFormat" => :string,
    "headerFormat" => :string,
    "footerFormat" => :string,
    "projectsVersionSeparator" => :string,
    "newlines" => :integers,
    "custom" => {:entries, ~w(key label type enumOptions minLength maxLength optional)},
    "kinds" => {:entries, ~w(label key auto format changeFormat)},
    "projects" => {:entries, ~w(label key changelog)}
  }
  @name ~r/\A\.?[A-Za-z0-9_-][A-Za-z0-9_.-]*\z/
  @newlines ~w(afterChange afterChangelogHeader afterChangelogVersion afterComponent afterFooterFile
               afterFooter afterHeaderFile afterHeaderTemplate afterKind afterReleaseNotes
               afterVersion beforeChange beforeChangelogVersion beforeComponent beforeFooterFile
               beforeFooterTemplate beforeHeaderFile beforeHeaderTemplate beforeKind
               beforeReleaseNotes beforeVersion endOfVersion)

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
      {:error, ".changie.yaml has replacements, which a release does not accept"}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = config} -> check(config)
      {:ok, _other} -> {:error, ".changie.yaml is not a map"}
      {:error, _reason} -> {:error, ".changie.yaml is not valid YAML"}
    end
  end

  defp check(config) do
    with :ok <- known(config, Map.keys(@top), ".changie.yaml"),
         :ok <- each(@top, &value(config, &1)),
         {:ok, changes, unreleased, projects} <- required(config) do
      projects(changes, unreleased, projects)
    end
  end

  defp required(%{
         "changesDir" => changes,
         "unreleasedDir" => unreleased,
         "projects" => [_ | _] = projects
       }),
       do: {:ok, changes, unreleased, projects}

  defp required(_config),
    do: {:error, ".changie.yaml needs changesDir, unreleasedDir and projects"}

  defp value(config, {key, rule}) do
    case Map.fetch(config, key) do
      :error -> :ok
      {:ok, value} -> rule(rule, key, value)
    end
  end

  defp rule(:string, _key, value) when is_binary(value), do: :ok

  defp rule(:name, _key, value) when is_binary(value),
    do: if(value =~ @name, do: :ok, else: bad(value))

  defp rule(:path, _key, value) when is_binary(value),
    do: if(relative?(value), do: :ok, else: bad(value))

  defp rule(:integers, _key, %{} = map),
    do:
      if(Enum.all?(map, fn {k, v} -> k in @newlines and is_integer(v) end),
        do: :ok,
        else: bad("newlines")
      )

  defp rule({:entries, keys}, key, [_ | _] = entries), do: each(entries, &entry(&1, keys, key))

  defp rule(_rule, key, _value),
    do: {:error, ".changie.yaml's #{key} is not what a release accepts"}

  defp entry(%{} = entry, keys, key) do
    with :ok <- known(entry, keys, ".changie.yaml's #{key}") do
      if key == "projects" and
           not (is_binary(entry["changelog"]) and relative?(entry["changelog"])),
         do: {:error, ".changie.yaml's projects need a changelog inside the repository each"},
         else: :ok
    end
  end

  defp entry(_entry, _keys, key),
    do: {:error, ".changie.yaml's #{key} holds something other than a map"}

  defp known(map, keys, where) do
    case Map.keys(map) -- keys do
      [] ->
        :ok

      unknown ->
        {:error,
         "#{where} has #{Enum.join(Enum.sort(unknown), ", ")}, which a release does not accept"}
    end
  end

  defp bad(value),
    do:
      {:error, ".changie.yaml names #{inspect(value)}, which leaves the directory it belongs in"}

  defp each(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp relative?(path),
    do: path != "" and Path.type(path) == :relative and ".." not in Path.split(path)

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

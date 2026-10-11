defmodule Ehosctl.Project do
  @moduledoc """
  What the application in a directory uses of EHOS's components (eh-os D-91): the commit of each
  git dependency and the version of each Hex one, from its `mix.lock`, and the documents it gives
  EHOS: `ehos.yaml`'s `schema:`, and the manifest `ehosctl verify` last wrote.

  `mix.lock` is Elixir terms, which Mix itself reads by evaluating them. Here it is parsed and
  never evaluated, and no atom is created for what it names: the terms are read as literals
  (`Code.string_to_quoted/2`), and anything that is not one is refused, so a checkout cannot run
  code through its lock.
  """

  @components ~w(ehos_app eh_os_contract eh_os_contract_auth ehos_design)

  # A lock is a few kilobytes; a file past this is not one ehosctl reads.
  @max_bytes 1_048_576

  @typedoc """
  A dependency as the lock has it: `:git` with the `commit` it is locked at and the `branch`,
  `tag` or `ref` its `mix.exs` names, or `:hex` with its `version`.
  """
  @type dependency :: %{
          required(:scm) => :git | :hex,
          optional(:commit) => String.t(),
          optional(:version) => String.t(),
          optional(:branch) => String.t() | nil,
          optional(:tag) => String.t() | nil,
          optional(:ref) => String.t() | nil
        }

  @typedoc """
  What an application uses: `deps`, the components among its dependencies by name;
  `ehos_yaml`, the schema its `ehos.yaml` says, or `nil`; `manifest`, the schema of
  `_build/ehos.manifest.json`, or `nil` when `ehosctl verify` has not written one.
  """
  @type t :: %{
          deps: %{String.t() => dependency()},
          ehos_yaml: String.t() | nil,
          manifest: String.t() | nil
        }

  @doc "The dependencies that are EHOS's components, as `read/1` keeps them."
  @spec components() :: [String.t()]
  def components, do: @components

  @doc """
  What the application in `dir` uses, or `:none` when `dir` is not an application's: one with a
  `mix.exs` and a `mix.lock`. A lock that cannot be read as one is an error.
  """
  @spec read(Path.t()) :: {:ok, t()} | :none | {:error, String.t()}
  def read(dir) do
    if regular?(Path.join(dir, "mix.exs")) and regular?(Path.join(dir, "mix.lock")) do
      with {:ok, lock} <- file(Path.join(dir, "mix.lock")),
           {:ok, deps} <- lock(lock) do
        {:ok,
         %{
           deps: deps,
           ehos_yaml: ehos_yaml(Path.join(dir, "ehos.yaml")),
           manifest: manifest(Path.join(dir, "_build/ehos.manifest.json"))
         }}
      end
    else
      :none
    end
  end

  @doc """
  The components among a `mix.lock`'s entries, read without evaluating it.

      iex> Ehosctl.Project.lock(~S(%{"ehos_design": {:git, "https://github.com/EmpoweredHouse/ehos-tools.git", "0123456789abcdef0123456789abcdef01234567", [sparse: "packages/ehos_design", ref: "0123456789abcdef0123456789abcdef01234567"]}}))
      {:ok, %{"ehos_design" => %{scm: :git, commit: "0123456789abcdef0123456789abcdef01234567", branch: nil, tag: nil, ref: "0123456789abcdef0123456789abcdef01234567"}}}

      iex> Ehosctl.Project.lock(~S|%{"x" => System.halt()}|)
      {:error, "mix.lock is not one ehosctl can read: it holds something other than terms."}
  """
  @spec lock(String.t()) :: {:ok, %{String.t() => dependency()}} | {:error, String.t()}
  def lock(contents) do
    # Every atom is read as its name, so none is created for what a file names.
    encoder = fn name, _meta -> {:ok, {:atom, name}} end

    with {:ok, quoted} <-
           Code.string_to_quoted(contents,
             static_atoms_encoder: encoder,
             emit_warnings: false
           ),
         {:ok, %{} = entries} <- literal(quoted) do
      deps =
        for {name, entry} <- entries,
            name = key(name),
            name in @components,
            dependency = dependency(entry),
            dependency != nil,
            into: %{},
            do: {name, dependency}

      {:ok, deps}
    else
      _other ->
        {:error, "mix.lock is not one ehosctl can read: it holds something other than terms."}
    end
  end

  defp key({:atom, name}), do: name
  defp key(name) when is_binary(name), do: name
  defp key(_name), do: nil

  # `{:git, url, commit, opts}` and `{:hex, name, version, …}`, as Mix writes them.
  defp dependency({{:atom, "git"}, url, commit, opts})
       when is_binary(url) and is_binary(commit) do
    if commit =~ ~r/\A[0-9a-f]{40}\z/ do
      opts = if is_list(opts), do: Map.new(opts, fn {k, v} -> {key(k), v} end), else: %{}

      %{
        scm: :git,
        commit: commit,
        branch: text(opts["branch"]),
        tag: text(opts["tag"]),
        ref: text(opts["ref"])
      }
    end
  end

  defp dependency(entry) when is_tuple(entry) and tuple_size(entry) >= 3 do
    case Tuple.to_list(entry) do
      [{:atom, "hex"}, _name, version | _] when is_binary(version) ->
        case Version.parse(version) do
          {:ok, _} -> %{scm: :hex, version: version}
          :error -> nil
        end

      _other ->
        nil
    end
  end

  defp dependency(_entry), do: nil

  defp text(value) when is_binary(value), do: if(Ehosctl.Output.printable?(value), do: value)
  defp text(_value), do: nil

  # The quoted form of a literal, as its value; anything else, such as a call, is refused.
  defp literal({:%{}, _meta, pairs}) when is_list(pairs) do
    with {:ok, pairs} <- all(pairs, fn {k, v} -> both(k, v) end), do: {:ok, Map.new(pairs)}
  end

  defp literal({:{}, _meta, elements}) when is_list(elements) do
    with {:ok, elements} <- all(elements, &literal/1), do: {:ok, List.to_tuple(elements)}
  end

  defp literal({:atom, name}) when is_binary(name), do: {:ok, {:atom, name}}
  defp literal({left, right}), do: both(left, right)
  defp literal(list) when is_list(list), do: all(list, &literal/1)

  defp literal(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp literal(_quoted), do: :error

  defp both(left, right) do
    with {:ok, left} <- literal(left), {:ok, right} <- literal(right), do: {:ok, {left, right}}
  end

  defp all(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  The schema an `ehos.yaml` says, from its top-level `schema:` line, or `nil`. The line is matched
  strictly, as the template writes it, rather than the file parsed as YAML, which ehosctl has no
  parser for and needs only this of: a schema written otherwise is said to be unknown.

      iex> Ehosctl.Project.schema("# a comment\\nschema: ehos.yaml/v2\\nresources: {}\\n")
      "ehos.yaml/v2"

      iex> Ehosctl.Project.schema("needs:\\n  schema: ehos.yaml/v2\\n")
      nil
  """
  @spec schema(String.t()) :: String.t() | nil
  def schema(contents) do
    case Regex.run(~r/^schema:[ \t]*(["']?)(ehos\.yaml\/v[0-9]+)\1[ \t]*(?:#.*)?$/m, contents) do
      [_, _quote, schema] -> schema
      nil -> nil
    end
  end

  defp ehos_yaml(path) do
    case file(path) do
      {:ok, contents} -> schema(contents)
      {:error, _} -> nil
    end
  end

  defp manifest(path) do
    with {:ok, contents} <- file(path),
         {:ok, %{"schema" => "ehos.manifest/v" <> n = schema}} <- JSON.decode(contents),
         {_n, ""} <- Integer.parse(n) do
      schema
    else
      _other -> nil
    end
  end

  # A regular file, not followed through a link, read no further than a lock could be.
  # sobelow_skip ["Traversal.FileModule"]
  defp file(path) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, device} <- File.open(path, [:read, :binary]) do
      read = IO.binread(device, @max_bytes + 1)
      File.close(device)

      case read do
        bytes when is_binary(bytes) and byte_size(bytes) <= @max_bytes -> {:ok, bytes}
        :eof -> {:ok, ""}
        _other -> {:error, "#{Path.basename(path)} is too large or cannot be read."}
      end
    else
      _other -> {:error, "#{Path.basename(path)} is not a regular file."}
    end
  end

  defp regular?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))
end

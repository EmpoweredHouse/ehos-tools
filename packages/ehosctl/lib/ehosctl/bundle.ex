defmodule Ehosctl.Bundle do
  @moduledoc """
  A bundle, `ehos.bundle/v1` or `v2`, read from its directory: the application manifest and the graph
  documents one command wrote together from one checkout, `mix eh_os_contract.bundle
  --output-dir`, with `bundle.json`, the index that names each by its path, its size and its
  SHA-256 (eh-os
  [D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md),
  [`docs/bundle.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/bundle.md)).
  `ehosctl builds register` sends one as a build, and `ehosctl deploy --bundle` deploys one.
  `write/3` writes the bundle of a utility service, which has a manifest and no graph documents,
  and may hold one OpenAPI file, the description of its API, which only `v2` names (eh-os D-175).

  As `docs/bundle.md` asks of whoever reads a bundle, each file is checked against the size and
  digest the index gives before it is used, and no file the index does not name is read. The index
  is checked as far as these bounds need, and against the bounds EHOS would refuse it past, so a
  bundle EHOS would refuse for its form is refused here, before anything is sent; the rest of its
  schema is EHOS's to check. A file is read only when it is a regular file: a link in the
  directory could name one outside it.
  """

  alias Ehosctl.Refusal

  @index "bundle.json"
  @v1 "ehos.bundle/v1"
  @v2 "ehos.bundle/v2"
  @manifest "ehos.manifest.json"
  # The names an OpenAPI file has in a bundle, at its root, with the file's own extension.
  @openapi_paths ~w(openapi.json openapi.yaml openapi.yml)

  # EHOS's bounds (eh-os `docs/builds-api.md`, `docs/bundle.md`, D-123): the index's part, each
  # file, the graph documents in all, and how many there are.
  @max_index_bytes 262_144
  @max_file_bytes 1_048_576
  @max_graph_bytes 33_554_432
  @most_graphs 512
  @max_path 255

  @graph_path ~r/\Agraph\/[A-Za-z0-9][A-Za-z0-9._-]*\.json\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @typedoc """
  A bundle as read: `index`, the bytes of `bundle.json`; `manifest`, the manifest's; `graphs`,
  each graph document's, in the index's order; `graph_bytes`, theirs in all; `openapi`, the
  OpenAPI file a `v2` bundle names, its path and bytes, or `nil`; and `application`, the
  application the manifest names.
  """
  @type t :: %{
          index: binary(),
          manifest: binary(),
          graphs: [binary()],
          graph_bytes: non_neg_integer(),
          openapi: openapi() | nil,
          application: String.t()
        }

  @typedoc "An OpenAPI file: its path in the bundle, `openapi.yaml` or another, and its bytes."
  @type openapi :: %{path: String.t(), bytes: binary()}

  @doc """
  The bundle in `dir`, every file checked against its index, or an error of kind `:invalid` that
  says which file and why, and that nothing was sent.
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, :invalid, String.t()}
  def read(dir) do
    with {:ok, index} <- file(dir, @index, @max_index_bytes),
         {:ok, listed} <- indexed(index, dir),
         {:ok, manifest} <- listed(dir, listed.manifest),
         {:ok, application} <- application(manifest, dir),
         {:ok, graphs} <- graphs(dir, listed.graph),
         {:ok, openapi} <- openapi(dir, listed.openapi) do
      {:ok,
       %{
         index: index,
         manifest: manifest,
         graphs: graphs,
         graph_bytes: Enum.sum_by(listed.graph, & &1.bytes),
         openapi: openapi,
         application: application
       }}
    end
  end

  defp openapi(_dir, nil), do: {:ok, nil}

  defp openapi(dir, file) do
    with {:ok, bytes} <- listed(dir, file), do: {:ok, %{path: file.path, bytes: bytes}}
  end

  @doc """
  Writes into `dir`, which does not exist yet, a bundle of `manifest` with no graph documents: a
  utility service's, which has no contract to draw (eh-os D-175). `docs/bundle.md` allows an index
  that lists none. With `openapi`, its OpenAPI file, the bundle is `v2` and holds the file as it
  is; without, `v1`. Returns an error of kind `:failed` that says which file could not be written.
  """
  @spec write(String.t(), binary(), openapi() | nil) :: :ok | {:error, :failed, String.t()}
  def write(dir, manifest, openapi \\ nil) do
    files =
      [{@manifest, manifest}] ++
        if(openapi, do: [{openapi.path, openapi.bytes}], else: []) ++
        [{@index, index(manifest, openapi)}]

    with :ok <- made(dir), do: Enum.reduce_while(files, :ok, &written(dir, &1, &2))
  end

  @doc """
  The index of a bundle that holds `manifest`, no graph documents, and `openapi` when given, as
  `write/3` writes it.

      iex> Ehosctl.Bundle.index("{}")
      ~s({"graph":[],"manifest":{"bytes":2,"path":"ehos.manifest.json","sha256":"44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"},"schema":"ehos.bundle/v1"})

      iex> Ehosctl.Bundle.index("{}", %{path: "openapi.yaml", bytes: "{}"})
      ~s({"graph":[],"manifest":{"bytes":2,"path":"ehos.manifest.json","sha256":"44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"},"openapi":{"bytes":2,"path":"openapi.yaml","sha256":"44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"},"schema":"ehos.bundle/v2"})
  """
  @spec index(binary(), openapi() | nil) :: binary()
  def index(manifest, openapi \\ nil)

  def index(manifest, nil),
    do:
      JSON.encode!(%{"schema" => @v1, "manifest" => listing(@manifest, manifest), "graph" => []})

  def index(manifest, %{path: path, bytes: bytes}) do
    JSON.encode!(%{
      "schema" => @v2,
      "manifest" => listing(@manifest, manifest),
      "graph" => [],
      "openapi" => listing(path, bytes)
    })
  end

  @doc "The names an OpenAPI file may have in a bundle, and in the repository it is taken from."
  @spec openapi_paths() :: [String.t()]
  def openapi_paths, do: @openapi_paths

  defp listing(path, bytes),
    do: %{"path" => path, "bytes" => byte_size(bytes), "sha256" => sha256(bytes)}

  defp made(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> unwritable(dir, reason)
    end
  end

  # `:exclusive`, so a file is never written through a link put there.
  defp written(dir, {path, bytes}, :ok) do
    case File.write(Path.join(dir, path), bytes, [:exclusive]) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, unwritable(Path.join(dir, path), reason)}
    end
  end

  defp unwritable(path, reason),
    do:
      {:error, :failed,
       "#{Refusal.shown(path)}: ehosctl cannot write it (#{:file.format_error(reason)})."}

  defp graphs(dir, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, read} ->
      case listed(dir, file) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | read]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, Enum.reverse(read)}
      error -> error
    end
  end

  ## The index

  defp indexed(bytes, dir) do
    where = shown(dir, @index)

    with {:ok, %{} = index} <- decode(bytes, where),
         :ok <- schema(index["schema"], where),
         {:ok, manifest} <- entry(index["manifest"], where, "manifest"),
         :ok <- manifest_path(manifest, where),
         {:ok, graph} <- graph_entries(index["graph"], where),
         {:ok, openapi} <- openapi_entry(index["schema"], Map.fetch(index, "openapi"), where),
         :ok <- distinct([manifest | graph] ++ List.wrap(openapi), where),
         :ok <- in_all(graph, where) do
      {:ok, %{manifest: manifest, graph: graph, openapi: openapi}}
    end
  end

  # Only `v2` names an OpenAPI file, at the bundle's root under one of its names
  # (eh-os `docs/bundle.md`).
  defp openapi_entry(_schema, :error, _where), do: {:ok, nil}

  defp openapi_entry(@v2, {:ok, entry}, where) do
    with {:ok, file} <- entry(entry, where, "the OpenAPI file"),
         do: openapi_path(file, where)
  end

  defp openapi_entry(_v1, {:ok, _entry}, where),
    do: invalid("#{where} names an OpenAPI file, which only an index of the schema #{@v2} holds.")

  defp openapi_path(%{path: path} = file, where) do
    if path in @openapi_paths,
      do: {:ok, file},
      else:
        invalid(
          "#{where} names the OpenAPI file #{Refusal.shown(path)}, but an OpenAPI file of a " <>
            "bundle is #{Enum.join(@openapi_paths, ", ")}."
        )
  end

  defp decode(bytes, where) do
    case JSON.decode(bytes) do
      {:ok, %{} = index} -> {:ok, index}
      _other -> invalid("#{where} is not the index of a bundle: it does not hold a JSON object.")
    end
  end

  # An index without its version is refused, never guessed at (`docs/bundle.md`).
  defp schema(schema, _where) when schema in [@v1, @v2], do: :ok

  defp schema(nil, where),
    do:
      invalid(
        "#{where} is not the index of a bundle: it does not name the schema #{@v1} or #{@v2}."
      )

  defp schema(other, where),
    do:
      invalid(
        "#{where} has the schema #{Refusal.shown(inspect(other))}. This ehosctl reads only " <>
          "#{@v1} and #{@v2}."
      )

  defp entry(%{"path" => path, "bytes" => bytes, "sha256" => sha256}, where, what)
       when is_binary(path) and is_integer(bytes) and is_binary(sha256) do
    cond do
      bytes not in 1..@max_file_bytes ->
        invalid(
          "#{where} gives #{what} #{bytes} bytes. A file of a bundle has 1 to " <>
            "#{@max_file_bytes} bytes."
        )

      not Regex.match?(@sha256, sha256) ->
        invalid("#{where} gives #{what} a SHA-256 that is not 64 lowercase hexadecimal digits.")

      true ->
        {:ok, %{path: path, bytes: bytes, sha256: sha256}}
    end
  end

  defp entry(_entry, where, what),
    do: invalid("#{where} does not give #{what} as a file with its path, bytes and sha256.")

  defp manifest_path(%{path: @manifest}, _where), do: :ok

  defp manifest_path(%{path: path}, where),
    do:
      invalid(
        "#{where} names the application manifest #{Refusal.shown(path)}, but the application " <>
          "manifest of a bundle is #{@manifest}."
      )

  defp graph_entries(graph, where) when is_list(graph) and length(graph) > @most_graphs,
    do:
      invalid(
        "#{where} lists #{length(graph)} graph documents, and a bundle holds at most " <>
          "#{@most_graphs}."
      )

  defp graph_entries(graph, where) when is_list(graph) do
    graph
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, n}, {:ok, read} ->
      with {:ok, file} <- entry(entry, where, "graph document #{n}"),
           :ok <- graph_path(file.path, where) do
        {:cont, {:ok, [file | read]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, Enum.reverse(read)}
      error -> error
    end
  end

  defp graph_entries(_graph, where),
    do: invalid("#{where} does not give the graph documents as a list.")

  # Its form is the schema's, so a path can neither leave the directory nor name a file twice.
  defp graph_path(path, where) do
    if byte_size(path) <= @max_path and Regex.match?(@graph_path, path),
      do: :ok,
      else:
        invalid(
          "#{where} names the graph document #{Refusal.shown(path)}, which is not a path in " <>
            "graph/. A path is a letter or digit, then letters, digits, ., _ or -, and ends in " <>
            ".json."
        )
  end

  # As a file system that ignores case would unpack them, two paths that differ in case alone are
  # one, and EHOS refuses the index (`docs/bundle.md`).
  defp distinct(files, where) do
    case files |> Enum.map(&String.downcase(&1.path)) |> duplicate() do
      nil -> :ok
      path -> invalid("#{where} names #{Refusal.shown(path)} twice.")
    end
  end

  defp duplicate(paths) do
    Enum.reduce_while(paths, MapSet.new(), fn path, seen ->
      if MapSet.member?(seen, path),
        do: {:halt, path},
        else: {:cont, MapSet.put(seen, path)}
    end)
    |> case do
      %MapSet{} -> nil
      path -> path
    end
  end

  defp in_all(graph, where) do
    if Enum.sum_by(graph, & &1.bytes) > @max_graph_bytes,
      do:
        invalid("#{where} lists graph documents of more than #{@max_graph_bytes} bytes in all."),
      else: :ok
  end

  ## The files

  # A file the index names, read to one byte past its size, and checked against its size and
  # digest before it is used.
  defp listed(dir, %{path: path, bytes: bytes, sha256: sha256}) do
    where = shown(dir, path)

    with {:ok, read} <- file(dir, path, bytes) do
      cond do
        byte_size(read) != bytes ->
          invalid(
            "#{where} is #{byte_size(read)} bytes, but #{@index} gives #{bytes} bytes. The " <>
              "bundle changed after it was written."
          )

        sha256(read) != sha256 ->
          invalid(
            "#{where} is not the file that #{@index} names: its SHA-256 differs. The bundle " <>
              "changed after it was written."
          )

        true ->
          {:ok, read}
      end
    end
  end

  defp file(dir, path, max) do
    full = Path.join(dir, path)
    where = shown(dir, path)

    with :ok <- parent(dir, path),
         :ok <- regular(full, where) do
      read = File.open(full, [:read, :binary], &read_at_most(&1, max + 1))
      read_file(read, where, max)
    end
  end

  defp read_file({:ok, bytes}, where, max) when is_binary(bytes) and byte_size(bytes) > max,
    do: invalid("#{where} is larger than #{max} bytes, which is the most it may be.")

  defp read_file({:ok, bytes}, where, _max) when is_binary(bytes) do
    if String.valid?(bytes),
      do: {:ok, bytes},
      else: invalid("#{where} is not UTF-8, so it is not JSON.")
  end

  defp read_file({:ok, {:error, reason}}, where, _max),
    do: invalid("#{where}: ehosctl cannot read it (#{:file.format_error(reason)}).")

  defp read_file({:error, reason}, where, _max),
    do: invalid("#{where}: ehosctl cannot read it (#{:file.format_error(reason)}).")

  defp read_at_most(device, count) do
    case IO.binread(device, count) do
      :eof -> ""
      bytes -> bytes
    end
  end

  # `graph/` is a directory of the bundle's own, not a link that would name files outside it.
  defp parent(dir, path) do
    case Path.dirname(path) do
      "." ->
        :ok

      parent ->
        case File.lstat(Path.join(dir, parent)) do
          {:ok, %{type: :directory}} -> :ok
          {:ok, %{type: type}} -> invalid("#{shown(dir, parent)} is not a directory (#{type}).")
          {:error, _reason} -> :ok
        end
    end
  end

  defp regular(full, where) do
    case File.lstat(full) do
      {:ok, %{type: :regular}} ->
        :ok

      {:ok, %{type: type}} ->
        invalid("#{where} is not a regular file (#{type}).")

      {:error, :enoent} ->
        invalid("#{where} does not exist. Give the directory of a bundle.")

      {:error, reason} ->
        invalid("#{where}: ehosctl cannot read it (#{:file.format_error(reason)}).")
    end
  end

  # The manifest names the application the bundle is of, which the command sends it as.
  defp application(manifest, dir) do
    where = shown(dir, @manifest)

    case JSON.decode(manifest) do
      {:ok, %{"application" => application}} when is_binary(application) and application != "" ->
        {:ok, application}

      _other ->
        invalid("#{where} is not an application manifest: it does not name an application.")
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp shown(dir, path), do: Refusal.shown(Path.join(dir, path))

  defp invalid(message), do: {:error, :invalid, message <> " ehosctl sent nothing."}
end

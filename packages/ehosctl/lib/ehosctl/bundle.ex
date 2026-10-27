defmodule Ehosctl.Bundle do
  @moduledoc """
  A bundle, `ehos.bundle/v1`, read from its directory: the application manifest and the graph
  documents one command wrote together from one checkout, `mix eh_os_contract.bundle
  --output-dir`, with `bundle.json`, the index that names each by its path, its size and its
  SHA-256 (eh-os
  [D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md),
  [`docs/bundle.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/bundle.md)).
  `ehosctl builds register` sends one as a build, and `ehosctl deploy --bundle` deploys one.

  As `docs/bundle.md` asks of whoever reads a bundle, each file is checked against the size and
  digest the index gives before it is used, and no file the index does not name is read. The index
  is checked as far as these bounds need, and against the bounds EHOS would refuse it past, so a
  bundle EHOS would refuse for its form is refused here, before anything is sent; the rest of its
  schema is EHOS's to check. A file is read only when it is a regular file: a link in the
  directory could name one outside it.
  """

  alias Ehosctl.Refusal

  @index "bundle.json"
  @schema "ehos.bundle/v1"
  @manifest "ehos.manifest.json"

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
  each graph document's, in the index's order; `graph_bytes`, theirs in all; and `application`,
  the application the manifest names.
  """
  @type t :: %{
          index: binary(),
          manifest: binary(),
          graphs: [binary()],
          graph_bytes: non_neg_integer(),
          application: String.t()
        }

  @doc """
  The bundle in `dir`, every file checked against its index, or an error of kind `:invalid` that
  says which file and why, and that nothing was sent.
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, :invalid, String.t()}
  def read(dir) do
    with {:ok, index} <- file(dir, @index, @max_index_bytes),
         {:ok, listed} <- index(index, dir),
         {:ok, manifest} <- listed(dir, listed.manifest),
         {:ok, application} <- application(manifest, dir),
         {:ok, graphs} <- graphs(dir, listed.graph) do
      {:ok,
       %{
         index: index,
         manifest: manifest,
         graphs: graphs,
         graph_bytes: Enum.sum_by(listed.graph, & &1.bytes),
         application: application
       }}
    end
  end

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

  defp index(bytes, dir) do
    where = shown(dir, @index)

    with {:ok, %{} = index} <- decode(bytes, where),
         :ok <- schema(index["schema"], where),
         {:ok, manifest} <- entry(index["manifest"], where, "manifest"),
         :ok <- manifest_path(manifest, where),
         {:ok, graph} <- graph_entries(index["graph"], where),
         :ok <- distinct([manifest | graph], where),
         :ok <- in_all(graph, where) do
      {:ok, %{manifest: manifest, graph: graph}}
    end
  end

  defp decode(bytes, where) do
    case JSON.decode(bytes) do
      {:ok, %{} = index} -> {:ok, index}
      _other -> invalid("#{where} does not hold a JSON object, so it is not a bundle's index.")
    end
  end

  # An index without its version is refused, never guessed at (`docs/bundle.md`).
  defp schema(@schema, _where), do: :ok

  defp schema(nil, where),
    do: invalid("#{where} names no schema, so it is not a bundle's index (#{@schema}).")

  defp schema(other, where),
    do:
      invalid(
        "#{where} is #{Refusal.shown(inspect(other))}, which this ehosctl does not read: it " <>
          "reads #{@schema}."
      )

  defp entry(%{"path" => path, "bytes" => bytes, "sha256" => sha256}, where, what)
       when is_binary(path) and is_integer(bytes) and is_binary(sha256) do
    cond do
      bytes not in 1..@max_file_bytes ->
        invalid(
          "#{where} gives #{what} #{bytes} bytes; a file of a bundle is 1 to #{@max_file_bytes}."
        )

      not Regex.match?(@sha256, sha256) ->
        invalid("#{where} gives #{what} a SHA-256 that is not 64 lowercase hexadecimal digits.")

      true ->
        {:ok, %{path: path, bytes: bytes, sha256: sha256}}
    end
  end

  defp entry(_entry, where, what),
    do: invalid("#{where} does not give #{what} as a file: its path, bytes and sha256.")

  defp manifest_path(%{path: @manifest}, _where), do: :ok

  defp manifest_path(%{path: path}, where),
    do:
      invalid(
        "#{where} names the manifest #{Refusal.shown(path)}; a bundle's manifest is #{@manifest}."
      )

  defp graph_entries(graph, where) when is_list(graph) and length(graph) > @most_graphs,
    do:
      invalid(
        "#{where} lists #{length(graph)} graph documents; a bundle holds at most #{@most_graphs}."
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

  defp graph_entries(_graph, where), do: invalid("#{where} lists no graph documents as a list.")

  # Its form is the schema's, so a path can neither leave the directory nor name a file twice.
  defp graph_path(path, where) do
    if byte_size(path) <= @max_path and Regex.match?(@graph_path, path),
      do: :ok,
      else:
        invalid(
          "#{where} names the graph document #{Refusal.shown(path)}, which is not a path in " <>
            "graph/: a letter or digit, then letters, digits, ., _ or -, ending in .json."
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
            "#{where} is #{byte_size(read)} bytes, not the #{bytes} #{@index} gives it: the " <>
              "bundle was changed after it was written."
          )

        sha256(read) != sha256 ->
          invalid(
            "#{where} is not the file #{@index} names: its SHA-256 differs, so the bundle was " <>
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

    with :ok <- regular(full, where) do
      read =
        File.open(full, [:read, :binary], fn device ->
          case IO.binread(device, max + 1) do
            :eof -> ""
            bytes -> bytes
          end
        end)

      case read do
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > max ->
          invalid("#{where} is larger than #{max} bytes, which is the most it may be.")

        {:ok, bytes} when is_binary(bytes) ->
          if String.valid?(bytes),
            do: {:ok, bytes},
            else: invalid("#{where} is not UTF-8, so it is not JSON.")

        {:ok, {:error, reason}} ->
          invalid("cannot read #{where}: #{:file.format_error(reason)}")

        {:error, reason} ->
          invalid("cannot read #{where}: #{:file.format_error(reason)}")
      end
    end
  end

  defp regular(full, where) do
    case File.lstat(full) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, %{type: type}} -> invalid("#{where} is not a regular file (#{type}).")
      {:error, :enoent} -> invalid("#{where} does not exist: is it a bundle's directory?")
      {:error, reason} -> invalid("cannot read #{where}: #{:file.format_error(reason)}")
    end
  end

  # The manifest names the application the bundle is of, which the command sends it as.
  defp application(manifest, dir) do
    where = shown(dir, @manifest)

    case JSON.decode(manifest) do
      {:ok, %{"application" => application}} when is_binary(application) and application != "" ->
        {:ok, application}

      _other ->
        invalid("#{where} names no application, so it is not a manifest.")
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp shown(dir, path), do: Refusal.shown(Path.join(dir, path))

  defp invalid(message), do: {:error, :invalid, message <> " Nothing was sent."}
end

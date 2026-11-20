defmodule Ehosctl.PrivateFile do
  @moduledoc """
  Files only the user can read, in directories only the user can write to: the configuration
  (T-07) and the sign-ins (T-08).
  """

  import Bitwise

  @doc """
  Makes sure `dir` exists. A directory `ehosctl` creates is readable only by the user (`0700`);
  one that exists is left as it is, unless others can write to it, which is `{:error, :shared}`:
  they could put a file or a link where `ehosctl` writes.

  With `private: true`, for a directory that holds secrets (T-08), an existing one must also be
  the user's own and readable by nobody else, or it is `{:error, :shared}`.
  """
  @spec make_dir(Path.t(), keyword()) :: :ok | {:error, :shared | File.posix()}
  def make_dir(dir, opts \\ []) do
    others = if opts[:private], do: 0o077, else: 0o022

    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when (mode &&& others) != 0 ->
        {:error, :shared}

      {:ok, %File.Stat{type: :directory, uid: uid}} ->
        if opts[:private] && uid != Ehosctl.OS.current().user_id(),
          do: {:error, :shared},
          else: :ok

      {:ok, _not_a_directory} ->
        {:error, :enotdir}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads `file`, following links, and says whether no one but the user could have changed what was
  read: the file read, the one the links lead to, is the user's and writable by nobody else, and
  so is the directory it is in, where another could put a file or a link in its place.

  The links are followed first, the directory is checked, and the file is opened there and checked
  through what it opened, so the bytes returned are the bytes of the file checked.
  """
  @spec read(Path.t()) :: {:ok, binary(), boolean()} | {:error, File.posix()}
  def read(file) do
    with {:ok, target} <- resolve(file, 40),
         {:ok, device} <- :file.open(target, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(device, time: :posix),
             {:ok, contents} <- read_all(device, []) do
          {:ok, contents,
           yours?(File.Stat.from_record(info)) and yours?(File.stat(Path.dirname(target)))}
        end
      after
        :file.close(device)
      end
    end
  end

  # The path with every link in it followed, one component at a time as the kernel does, so a `..`
  # after a linked directory leaves the directory the link led to.
  defp resolve(path, hops), do: walk("/", path |> Path.absname() |> Path.split() |> tl(), hops)

  defp walk(current, [], _hops), do: {:ok, current}
  defp walk(_current, _rest, 0), do: {:error, :eloop}
  defp walk(current, ["." | rest], hops), do: walk(current, rest, hops)
  defp walk(current, [".." | rest], hops), do: walk(Path.dirname(current), rest, hops)

  defp walk(current, [name | rest], hops) do
    next = Path.join(current, name)

    case :file.read_link_all(next) do
      {:ok, target} ->
        case Path.split(to_string(target)) do
          ["/" | parts] -> walk("/", parts ++ rest, hops - 1)
          parts -> walk(current, parts ++ rest, hops - 1)
        end

      {:error, :einval} ->
        walk(next, rest, hops)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_all(device, read) do
    case :file.read(device, 65_536) do
      {:ok, data} -> read_all(device, [read, data])
      :eof -> {:ok, IO.iodata_to_binary(read)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp yours?({:ok, %File.Stat{} = stat}), do: yours?(stat)
  defp yours?({:error, _reason}), do: false

  defp yours?(%{mode: mode, uid: uid}),
    do: uid == Ehosctl.OS.current().user_id() and (mode &&& 0o022) == 0

  @doc """
  Writes `contents` to `file` whole, readable only by the user: `EhosPlatform.PrivateFile.write/2`.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  defdelegate write(file, contents), to: EhosPlatform.PrivateFile
end

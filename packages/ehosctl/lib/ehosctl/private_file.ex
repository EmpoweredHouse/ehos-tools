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
  the user's own and readable by nobody else, or it is `{:error, :shared}`: `write/2` creates a
  file before it makes it `0600`, and another user could open it in between.
  """
  @spec make_dir(Path.t(), keyword()) :: :ok | {:error, :shared | File.posix()}
  def make_dir(dir, opts \\ []) do
    others = if opts[:private], do: 0o077, else: 0o022

    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when (mode &&& others) != 0 ->
        {:error, :shared}

      {:ok, %File.Stat{type: :directory, uid: uid}} ->
        if opts[:private] && uid != user_id(), do: {:error, :shared}, else: :ok

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
    do: uid == user_id() and uid != nil and (mode &&& 0o022) == 0

  # The user's id, as the files they create are owned by it: asked of `/usr/bin/id` once, not
  # through PATH. `nil` when it cannot be, which no directory's owner matches.
  defp user_id do
    case :persistent_term.get({__MODULE__, :user_id}, :unknown) do
      :unknown ->
        id =
          with {output, 0} <- System.cmd("/usr/bin/id", ["-u"]),
               {id, _rest} <- Integer.parse(output) do
            id
          else
            _ -> nil
          end

        :persistent_term.put({__MODULE__, :user_id}, id)
        id

      id ->
        id
    end
  rescue
    ErlangError -> nil
  end

  @doc """
  Writes `contents` to `file` whole: to a new temporary file beside it, readable only by the
  user, flushed to disk and renamed over the old one, so a command interrupted half way leaves the
  old file rather than half of a new one.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  # Random rather than `System.unique_integer/1`, which repeats from one run to the next, and
  # opened `:exclusive`, so a file or a link already at that path is neither written through nor
  # removed.
  def write(file, contents) do
    temporary =
      Path.join(
        Path.dirname(file),
        ".#{Path.basename(file)}.#{Base.url_encode64(:crypto.strong_rand_bytes(9))}.tmp"
      )

    with {:ok, device} <- File.open(temporary, [:write, :exclusive, :binary]) do
      written =
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(device, contents),
             :ok <- :file.sync(device),
             :ok <- File.close(device) do
          File.rename(temporary, file)
        end

      if written != :ok do
        File.close(device)
        File.rm(temporary)
      end

      written
    end
  end
end

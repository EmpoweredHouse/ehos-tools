defmodule EhosPlatform.PrivateFile do
  @moduledoc """
  Writes a file that only its owner can read, from before it holds a byte, and whole: a command
  cut short leaves the file before, never half of a new one (ehos-tools T-30). An installation's
  files in `~/.ehos/<name>/` and `ehosctl`'s configuration and sign-ins are written so.
  """

  import Bitwise

  @doc """
  Writes `contents` to `file` through a new file beside it, renamed over `file` once it is
  written and flushed.

  The new file is made inside a new directory, which is made `0700` while it is still empty, so
  no other user can open the file whatever the mode of `file`'s own directory; the file is `0600`
  too. A file that was at `file` is replaced, not written through, so whoever opened it keeps
  reading the old contents, and a link at `file` is replaced rather than followed. On a failure,
  what was made beside `file` is removed and `file` is left as it was.

  Once `file` is written, what an earlier write killed before its rename left beside it is
  removed too (`remove_leftovers/2`), when it is more than an hour older than `file`. A write
  takes far less; one that stalls for more than an hour, stopped or on a filesystem that hangs,
  can find its directory removed and fail with `{:error, :enoent}`, leaving `file` as it was.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write(file, contents) do
    with :ok <- written_whole(file, contents) do
      remove_abandoned(file)
    end
  end

  # Measured against the file just written, so the time is the filesystem's own, the clock the
  # leftovers' times were set by.
  @abandoned_after 3600

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_abandoned(file) do
    case File.lstat(file, time: :posix) do
      {:ok, %File.Stat{mtime: written, uid: owner}} ->
        remove_owned(Path.dirname(file), owner, written - @abandoned_after)

      {:error, _reason} ->
        :ok
    end
  end

  # Random rather than `System.unique_integer/1`, which repeats from one run to the next, and made
  # with `mkdir`, which fails on anything already at that path, so a file or a link there is
  # neither written through nor removed.
  # sobelow_skip ["Traversal.FileModule"]
  defp written_whole(file, contents) do
    dir =
      Path.join(
        Path.dirname(file),
        ".#{Path.basename(file)}.#{Base.url_encode64(:crypto.strong_rand_bytes(9))}.tmp"
      )

    with :ok <- File.mkdir(dir) do
      temporary = Path.join(dir, Path.basename(file))

      dir
      |> written(temporary, contents)
      |> renamed(temporary, file)
      |> cleaned(dir, temporary)
    end
  end

  defp written(dir, temporary, contents) do
    with :ok <- File.chmod(dir, 0o700),
         {:ok, device} <- File.open(temporary, [:write, :exclusive, :binary]) do
      written_to(device, temporary, contents)
    end
  end

  defp written_to(device, temporary, contents) do
    with :ok <- File.chmod(temporary, 0o600),
         :ok <- IO.binwrite(device, contents),
         :ok <- :file.sync(device) do
      File.close(device)
    else
      error ->
        File.close(device)
        error
    end
  end

  defp renamed(:ok, temporary, file), do: File.rename(temporary, file)
  defp renamed(error, _temporary, _file), do: error

  defp cleaned(result, dir, temporary) do
    _removed = File.rm(temporary)
    _removed = File.rmdir(dir)
    result
  end

  @doc """
  Removes from `dir` what a `write/2` killed before its rename left there: a directory named
  `.<file>.<12 random characters>.tmp`, owned by the owner of `dir`, that holds nothing or only a
  file named `<file>`. Nothing else is touched: no other entry of `dir`, no directory of another
  shape or owner, and no link in that place. In a `dir` that another user can write to and that
  has no sticky bit, nothing is removed: that user could put a link in the place of a leftover
  between its check and its removal.

  With `before:`, a time in seconds since the epoch, only what was last changed before it is
  removed.
  """
  @spec remove_leftovers(Path.t(), before: integer()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  def remove_leftovers(dir, opts \\ []) do
    case File.stat(dir) do
      {:ok, %File.Stat{uid: owner}} -> remove_owned(dir, owner, Keyword.get(opts, :before))
      {:error, _reason} -> :ok
    end
  end

  # Only in a directory of `owner`'s that nobody else can rename in, as Erlang has no `unlinkat`:
  # `rm` follows no link in its last component but does in the leftover's own path, so another
  # who swapped a link in for it after its check would have `rm` remove a file of `owner`'s where
  # the link leads. Each entry is removed alone, never recursively, so a directory of that shape
  # costs one listing. `stat`, not `lstat`, as `ls` follows a link at `dir`.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_owned(dir, owner, before) do
    case File.stat(dir) do
      {:ok, %File.Stat{uid: ^owner, mode: mode}}
      when (mode &&& 0o022) == 0 or (mode &&& 0o1000) != 0 ->
        dir |> names() |> Enum.each(&remove_leftover(dir, &1, owner, before))

      _shared_or_gone ->
        :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_leftover(dir, name, owner, before) do
    path = Path.join(dir, name)

    with [_name, file] <- Regex.run(~r/\A\.(.+)\.[A-Za-z0-9_-]{12}\.tmp\z/, name),
         {:ok, %File.Stat{type: :directory, uid: ^owner, mtime: changed}} <-
           File.lstat(path, time: :posix),
         true <- before == nil or changed < before,
         {:ok, entries} when entries in [[], [file]] <- File.ls(path) do
      _removed = File.rm(Path.join(path, file))
      _removed = File.rmdir(path)
    end

    :ok
  end

  defp names(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end
end

defmodule EhosPlatform.PrivateFile do
  @moduledoc """
  Writes a file that only its owner can read, from before it holds a byte, and whole: a command
  cut short leaves the file before, never half of a new one (ehos-tools T-30). An installation's
  files in `~/.ehos/<name>/` and `ehosctl`'s configuration and sign-ins are written so.
  """

  @doc """
  Writes `contents` to `file` through a new file beside it, renamed over `file` once it is
  written and flushed.

  The new file is made inside a new directory, which is made `0700` while it is still empty, so
  no other user can open the file whatever the mode of `file`'s own directory; the file is `0600`
  too. A file that was at `file` is replaced, not written through, so whoever opened it keeps
  reading the old contents, and a link at `file` is replaced rather than followed. On a failure,
  what was made beside `file` is removed and `file` is left as it was.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  # Random rather than `System.unique_integer/1`, which repeats from one run to the next, and made
  # with `mkdir`, which fails on anything already at that path, so a file or a link there is
  # neither written through nor removed.
  # sobelow_skip ["Traversal.FileModule"]
  def write(file, contents) do
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
  `.<file>.<12 random characters>.tmp`, with the file it was writing. Nothing else in `dir` is
  touched, and a link with that name is removed, not followed.
  """
  @spec remove_leftovers(Path.t()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  def remove_leftovers(dir) do
    dir
    |> names()
    |> Enum.filter(&(&1 =~ ~r/\A\..+\.[A-Za-z0-9_-]{12}\.tmp\z/))
    |> Enum.each(&File.rm_rf(Path.join(dir, &1)))
  end

  defp names(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end
end

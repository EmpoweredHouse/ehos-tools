defmodule EhosPlatform.PrivateFile do
  @moduledoc """
  Writes a file in an installation's directory, `~/.ehos/<name>/`, readable by its owner alone
  from before it holds a byte, and whole: a command cut short leaves the file before, never half
  of a new one (ehos-tools T-30).
  """

  @doc """
  Writes `contents` to `file` through a new file beside it: opened `:exclusive`, made `0600` while
  it is still empty, flushed and renamed over `file`. A file that was there before is replaced,
  not written through, so whoever opened it keeps reading the old contents, and a link at `file`
  is replaced rather than followed. On a failure the file beside it is removed and `file` is left
  as it was.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  # Random rather than `System.unique_integer/1`, which repeats from one run to the next, and
  # opened `:exclusive`, so a file or a link already at that path is neither written through nor
  # removed.
  # sobelow_skip ["Traversal.FileModule"]
  def write(file, contents) do
    temporary =
      Path.join(
        Path.dirname(file),
        ".#{Path.basename(file)}.#{Base.url_encode64(:crypto.strong_rand_bytes(9))}.tmp"
      )

    with {:ok, device} <- File.open(temporary, [:write, :exclusive, :binary]) do
      temporary |> write_open(device, contents, file) |> removed_on_failure(temporary)
    end
  end

  defp write_open(temporary, device, contents, file) do
    with :ok <- File.chmod(temporary, 0o600),
         :ok <- IO.binwrite(device, contents),
         :ok <- :file.sync(device),
         :ok <- File.close(device) do
      File.rename(temporary, file)
    else
      error ->
        File.close(device)
        error
    end
  end

  defp removed_on_failure(:ok, _temporary), do: :ok

  defp removed_on_failure(error, temporary) do
    _removed = File.rm(temporary)
    error
  end
end

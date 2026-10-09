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
  """
  @spec make_dir(Path.t()) :: :ok | {:error, :shared | File.posix()}
  def make_dir(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when (mode &&& 0o022) != 0 ->
        {:error, :shared}

      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)

      {:error, reason} ->
        {:error, reason}
    end
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

defmodule EhosPlatform.TmpDir do
  @moduledoc """
  A fresh temporary directory for the duration of a function, for EHOS's developer tooling.
  """

  @doc """
  Creates an empty directory under the system's temporary directory, named after `prefix`, calls
  `fun` with its path, and deletes it afterwards, also when `fun` raises. Returns what `fun`
  returns.

  The directory is new and readable by this user alone: its name ends in random bytes, and it is
  made exclusively, so a path someone else created first, in a temporary directory other users
  share, is refused rather than used. What goes in it, a pull credential included, is not readable
  through it by anyone else.
  """
  # The path is built from the system's temporary directory and random bytes, never from input;
  # this runs only in `mix ehos.*` tasks.
  # sobelow_skip ["Traversal.FileModule"]
  @spec with_tmp_dir(String.t(), (Path.t() -> result)) :: result when result: term()
  def with_tmp_dir(prefix, fun) do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")

    case File.mkdir(dir) do
      :ok -> :ok
      {:error, reason} -> raise "#{dir} cannot be made: #{:file.format_error(reason)}"
    end

    try do
      private!(dir)
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  # The directory is the one made above, still empty, and closed to everyone else, before anything
  # is put in it: a directory made under a permissive umask is open for a moment.
  # sobelow_skip ["Traversal.FileModule"]
  defp private!(dir) do
    with :ok <- File.chmod(dir, 0o700),
         {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(dir),
         0o700 <- Bitwise.band(mode, 0o777),
         {:ok, []} <- File.ls(dir) do
      :ok
    else
      _other -> raise "#{dir} is not a new, empty directory only this user may read"
    end
  end
end

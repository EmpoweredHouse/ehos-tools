defmodule EhosPlatform.TmpDir do
  @moduledoc """
  A fresh temporary directory, readable by this user alone, for the duration of a function and
  removed after it: where `EhosPlatform.Install` writes a Secret or a rendered manifest before it
  applies it, and where `ehosctl` asks mise for a pinned tool from an empty directory.
  """

  import Bitwise

  @doc """
  Creates an empty directory under the system's temporary directory, named after `prefix`, calls
  `fun` with its path, and deletes it afterwards, also when `fun` raises. Returns what `fun`
  returns.

  The directory is new and readable by this user alone: its name is
  `<prefix>.<16 random characters>.tmp`, and it is made exclusively, so a path someone else created first, in a temporary directory other users
  share, is refused rather than used. What goes in it, a pull credential included, is not readable
  through it by anyone else.

  Once the directory is made, what a killed `with_tmp_dir/2` left beside it is removed
  (`remove_leftovers/2`), when it was last changed more than a day before the new directory. A
  function that holds its directory longer, unchanged, can find it removed by another call. Only
  a directory whose `prefix` starts with `ehos` is found so: a caller that writes a credential
  gives such a prefix.
  """
  # The path is built from the system's temporary directory and random bytes, never from input.
  # sobelow_skip ["Traversal.FileModule"]
  @spec with_tmp_dir(String.t(), (Path.t() -> result)) :: result when result: term()
  def with_tmp_dir(prefix, fun) do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "#{prefix}.#{suffix}.tmp")

    case File.mkdir(dir) do
      :ok -> :ok
      {:error, reason} -> raise "#{dir} cannot be made: #{:file.format_error(reason)}"
    end

    try do
      private!(dir)
      remove_abandoned(dir)
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  # Measured against the directory just made, so the time is the filesystem's own, the clock the
  # leftovers' times were set by. A day, not an hour as for `EhosPlatform.PrivateFile`'s writes:
  # a directory lives as long as the function, a `helm --wait` during an installation among them.
  @abandoned_after 86_400

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_abandoned(dir) do
    %File.Stat{mtime: made, uid: owner} = File.lstat!(dir, time: :posix)
    remove_leftovers(Path.dirname(dir), owner: owner, before: made - @abandoned_after)
  end

  @doc """
  Removes from `dir` what a `with_tmp_dir/2` killed before its end left there: a
  directory named `ehos….<16 random characters>.tmp`, or `<prefix>-<16 random characters>` for a
  prefix that an earlier version gave a directory that could hold a credential, owned by `owner`,
  readable by its owner alone, and last changed before `before`, a time in seconds since the epoch, with all it holds.
  Nothing else is touched: no other entry of `dir`, no directory of another shape, owner or mode,
  and no link in that place. In a `dir` that another user can write to and that has no sticky
  bit, nothing is removed: that user could put a link in the place of a leftover between its
  check and its removal.
  """
  @spec remove_leftovers(Path.t(), owner: non_neg_integer(), before: integer()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  def remove_leftovers(dir, opts) do
    owner = Keyword.fetch!(opts, :owner)
    before = Keyword.fetch!(opts, :before)

    case File.stat(dir) do
      {:ok, %File.Stat{mode: mode}} when (mode &&& 0o022) == 0 or (mode &&& 0o1000) != 0 ->
        dir |> names() |> Enum.each(&remove_leftover(dir, &1, owner, before))

      _shared_or_gone ->
        :ok
    end
  end

  # ehos-tools#1108: a SIGKILL leaves a Secret or rendered values with a credential behind.
  # What the leftover holds was written by its owner alone, in a directory nobody else can enter,
  # so the recursive removal meets nothing another put there; `rm_rf` removes a link it meets
  # rather than follow it.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_leftover(dir, name, owner, before) do
    path = Path.join(dir, name)

    with true <- leftover_name?(name),
         {:ok, %File.Stat{type: :directory, uid: ^owner, mode: mode, mtime: changed}} <-
           File.lstat(path, time: :posix),
         0o700 <- mode &&& 0o777,
         true <- changed < before do
      _removed = File.rm_rf(path)
    end

    :ok
  end

  # The shape a directory has now, and the one an earlier version gave it, which took any name that
  # ended in a dash and 16 such characters: there, only the prefixes that version used, but for
  # `ehos-<chart release>`, which holds a pulled chart and no credential. A Secret was written from
  # a directory named after it: the pull credential, the SMTP password, the Let's Encrypt account
  # keys, and the managing role of a database outside the installation, `ehos-external-<name>`,
  # whose name is `ExternalDatabases`' shape.
  defp leftover_name?(name) do
    Regex.match?(~r/\Aehos.*\.[A-Za-z0-9_-]{16}\.tmp\z/, name) or
      Regex.match?(
        ~r/\A(?:ehos-(?:install|cluster|move|values|acme-dns|acme-issuer|pull-credential|smtp
                    |acme-console|acme-addresses|external(?:-[a-z](?:[-a-z0-9]{0,48}[a-z0-9])?)?)
              |ehosctl-mise)
          -[A-Za-z0-9_-]{16}\z/x,
        name
      )
  end

  defp names(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _reason} -> []
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

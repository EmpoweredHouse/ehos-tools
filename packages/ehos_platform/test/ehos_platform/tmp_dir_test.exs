defmodule EhosPlatform.TmpDirTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.TmpDir

  test "gives the function an empty directory and returns its result" do
    {dir, listed} = TmpDir.with_tmp_dir("ehos-test", &{&1, File.ls!(&1)})

    assert listed == []
    # The name ends in random bytes, the one part of it a test cannot know.
    assert Path.join(System.tmp_dir!(), Path.basename(dir)) == dir
    assert Path.basename(dir) =~ ~r/\Aehos-test\.[A-Za-z0-9_-]{16}\.tmp\z/
  end

  test "gives a directory only this user may read, never one twice" do
    {first, mode} = TmpDir.with_tmp_dir("ehos-test", &{&1, File.stat!(&1).mode})
    second = TmpDir.with_tmp_dir("ehos-test", & &1)

    assert Bitwise.band(mode, 0o777) == 0o700
    refute first == second
  end

  test "deletes the directory afterwards, also when the function raises" do
    parent = self()

    assert_raise RuntimeError, fn ->
      TmpDir.with_tmp_dir("ehos-test", fn dir ->
        File.write!(Path.join(dir, "file"), "")
        send(parent, {:dir, dir})
        raise "boom"
      end)
    end

    assert_received {:dir, dir}
    refute File.exists?(dir)
  end

  test "removes beside the new directory what a killed call left more than a day before" do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    left = leftover(System.tmp_dir!(), "ehos-test.#{suffix}.tmp", 1_000)
    on_exit(fn -> File.rm_rf(left) end)

    TmpDir.with_tmp_dir("ehos-test", & &1)

    refute File.exists?(left)
  end

  # The Secrets 0.20.0 and earlier wrote from a directory named after each.
  @secret_prefixes ~w(ehos-pull-credential ehos-smtp ehos-acme-console ehos-acme-addresses
                      ehos-external ehos-external-ledger ehos-external-ledger-eu-2)

  describe "remove_leftovers/2" do
    @describetag :tmp_dir

    # ExUnit makes the directory under the umask, and a umask of 002 leaves it group-writable,
    # where nothing is removed.
    setup %{tmp_dir: dir} do
      File.chmod!(dir, 0o700)
    end

    test "removes what a killed call left before the time it is given, and nothing else",
         %{tmp_dir: dir} do
      owner = File.stat!(dir).uid
      old = leftover(dir, "ehos-install.QUJDREVGR0hJSktM.tmp", 1_000)
      new = leftover(dir, "ehos-install.UFFSU1RVVldYWVph.tmp", 3_000)
      other = leftover(dir, "notes.QUJDREVGR0hJSktM.tmp", 1_000)
      short = leftover(dir, "ehos-install-short", 1_000)
      open = leftover(dir, "ehos-move.QUJDREVGR0hJSktM.tmp", 1_000)
      File.chmod!(open, 0o755)
      file = Path.join(dir, "ehos-cluster.QUJDREVGR0hJSktM.tmp")
      File.write!(file, "kept")
      File.touch!(file, 1_000)
      File.ln_s!(old, Path.join(dir, "ehos-cluster.UFFSU1RVVldYWVph.tmp"))
      # A directory of the person's own, which only the start of its name relates to ehosctl.
      own = leftover(dir, "ehos-tools-review-pr-1106-backup", 1_000)
      # What an earlier version, which named a directory <prefix>-<random>, left.
      earlier = leftover(dir, "ehos-values-QUJDREVGR0hJSktM", 1_000)
      # A Secret was written from a directory named after it: these held a credential.
      for name <- @secret_prefixes, do: leftover(dir, "#{name}-QUJDREVGR0hJSktM", 1_000)
      # A pulled chart, which holds no credential, and names a Secret's shape almost has.
      kept =
        for name <-
              ~w(ehos-cnpg-QUJDREVGR0hJSktM ehos-external-Archive-QUJDREVGR0hJSktM
                 ehos-smtp-QUJDREVGR0hJSktM1 ehos-smtpx-QUJDREVGR0hJSktM),
            do: leftover(dir, name, 1_000)

      assert TmpDir.remove_leftovers(dir, owner: owner, before: 2_000) == :ok

      refute File.exists?(old)
      refute File.exists?(earlier)

      assert Enum.sort(File.ls!(dir)) ==
               Enum.sort(
                 Enum.map([new, other, short, open, file, own | kept], &Path.basename/1) ++
                   ["ehos-cluster.UFFSU1RVVldYWVph.tmp"]
               )
    end

    test "removes nothing of another owner's", %{tmp_dir: dir} do
      left = leftover(dir, "ehos-install.QUJDREVGR0hJSktM.tmp", 1_000)

      assert TmpDir.remove_leftovers(dir, owner: File.stat!(dir).uid + 1, before: 2_000) == :ok

      assert File.exists?(left)
    end

    # Another who can write the directory could swap a link in for a leftover between its check
    # and its removal.
    test "removes nothing from a directory others can write to, unless it is sticky",
         %{tmp_dir: dir} do
      shared = Path.join(dir, "shared")
      File.mkdir_p!(shared)
      left = leftover(shared, "ehos-install.QUJDREVGR0hJSktM.tmp", 1_000)
      owner = File.stat!(dir).uid

      File.chmod!(shared, 0o777)
      assert TmpDir.remove_leftovers(shared, owner: owner, before: 2_000) == :ok
      assert File.exists?(left)

      # Erlang's chmod drops the sticky bit on macOS; the system's sets it.
      {"", 0} = System.cmd("chmod", ["1777", shared])
      assert TmpDir.remove_leftovers(shared, owner: owner, before: 2_000) == :ok
      refute File.exists?(left)
    end

    test "removes nothing from a directory that is not there", %{tmp_dir: dir} do
      assert TmpDir.remove_leftovers(Path.join(dir, "gone"), owner: 0, before: 2_000) == :ok
    end
  end

  # A directory as `with_tmp_dir/2` leaves it when it is killed: private, with a credential in
  # it, last changed at `changed`.
  defp leftover(dir, name, changed) do
    path = Path.join(dir, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "secret.json"), "the credential")
    File.chmod!(path, 0o700)
    File.touch!(path, changed)
    path
  end
end

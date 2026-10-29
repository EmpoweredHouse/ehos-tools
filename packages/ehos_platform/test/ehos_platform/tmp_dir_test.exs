defmodule EhosPlatform.TmpDirTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.TmpDir

  test "gives the function an empty directory and returns its result" do
    {dir, listed} = TmpDir.with_tmp_dir("ehos-test", &{&1, File.ls!(&1)})

    assert listed == []
    # The name ends in random bytes, the one part of it a test cannot know.
    assert Path.join(System.tmp_dir!(), Path.basename(dir)) == dir
    assert Path.basename(dir) =~ ~r/\Aehos-test-[A-Za-z0-9_-]{16}\z/
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
end

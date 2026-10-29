defmodule Ehosctl.OSTest do
  use Ehosctl.Case, async: true
  use Hammox.Protect, module: Ehosctl.OSImpl, behaviour: Ehosctl.OS

  @moduletag :tmp_dir

  test "finds a program on the PATH, and nothing for one that is not there" do
    assert find_executable("sh") == System.find_executable("sh")
    assert find_executable("ehosctl-no-such-program") == nil
  end

  test "reads the user's id as the owner of the files they create", %{tmp_dir: dir} do
    assert user_id() == File.stat!(dir).uid
  end

  test "says this process's OS process runs, and one that ended does not" do
    assert alive?(String.to_integer(System.pid()))

    {ended, 0} = System.cmd("sh", ["-c", "echo $$"])
    refute alive?(ended |> String.trim() |> String.to_integer())
  end

  test "resolves the links in a directory's path", %{tmp_dir: dir} do
    real = Path.join(dir, "real")
    File.mkdir_p!(real)
    File.ln_s!(real, Path.join(dir, "link"))

    assert physical(Path.join(dir, "link")) == physical(real)
    assert String.ends_with?(physical(Path.join(dir, "link")), "/real")
  end
end

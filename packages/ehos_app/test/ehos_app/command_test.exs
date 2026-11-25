defmodule EhosApp.CommandTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  test "returns stdout from an installed program", %{tmp_dir: dir} do
    assert {:ok, version} = EhosApp.CommandImpl.run("git", ["--version"], dir)
    assert version =~ "git version"
  end

  test "returns a missing-program error without raising", %{tmp_dir: dir} do
    assert EhosApp.CommandImpl.run("ehos-missing-command-in-test-931", [], dir) ==
             {:error, :not_installed}
  end

  test "returns a bounded failure when the working directory does not exist", %{tmp_dir: dir} do
    assert {:error, {:exit, status}} =
             EhosApp.CommandImpl.run("git", ["--version"], Path.join(dir, "missing"))

    assert status > 0
  end

  test "reports a failed command without its output", %{tmp_dir: dir} do
    assert EhosApp.CommandImpl.run("git", ["rev-parse", "--verify", "missing"], dir) ==
             {:error, {:exit, 128}}
  end
end

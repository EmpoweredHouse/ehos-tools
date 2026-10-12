defmodule Ehosctl.PlatformRunnerTest do
  use ExUnit.Case, async: true

  alias Ehosctl.PlatformRunner

  doctest PlatformRunner

  # T-13: what EHOS is tested with, whatever else is on the PATH, and nothing installed on the way.
  test "runs every pinned tool through mise at its pin, with auto-install off" do
    for {program, spec} <- [
          {"tofu", "opentofu@1.13.1"},
          {"helm", "helm@4.3.0"},
          {"kubectl", "kubectl@1.36.4"}
        ] do
      assert PlatformRunner.command(program, ["a", "b"]) ==
               {"mise", ["exec", spec, "--", program, "a", "b"],
                [{"MISE_EXEC_AUTO_INSTALL", "false"}]}
    end
  end

  test "runs ssh, sh and gh as the system's" do
    for program <- ["ssh", "sh", "gh"] do
      assert PlatformRunner.command(program, ["x"]) == {program, ["x"], []}
    end
  end

  test "is the runner ehos_platform asks for" do
    behaviours = PlatformRunner.module_info(:attributes)[:behaviour]
    assert EhosPlatform.CommandRunner in behaviours
  end

  test "a system program runs bounded as itself" do
    assert PlatformRunner.run_bounded("sh", ["-c", "echo here"], 5_000) == {"here\n", 0}
  end
end

defmodule EhosPlatform.CommandRunner.SystemTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.CommandRunner.System, as: Runner

  test "run_bounded/3 returns what a program printed and its status when it ends in time" do
    assert Runner.run_bounded("sh", ["-c", "echo out; echo err >&2; exit 3"], 5_000) ==
             {"out\nerr\n", 3}
  end

  # #291: a command that would wait for ever is killed, and nothing of it is left running.
  @tag :tmp_dir
  test "run_bounded/3 kills a program that runs past its time", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "pid")
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             Runner.run_bounded("sh", ["-c", "echo $$ > #{pid_file}; exec sleep 30"], 300)

    assert System.monotonic_time(:millisecond) - started < 5_000

    # Gone once the VM has reaped it, which may take a moment after the kill.
    pid = pid_file |> File.read!() |> String.trim()
    assert Enum.any?(1..50, fn _try -> gone?(pid) or (Process.sleep(20) && false) end)
  end

  test "run_bounded/3 says when the program is not installed" do
    assert Runner.run_bounded("no-such-program-ehos", [], 1_000) == {:error, :not_found}
  end

  defp gone?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
      {stat, 0} -> String.starts_with?(String.trim(stat), "Z")
      {_none, _status} -> true
    end
  end
end

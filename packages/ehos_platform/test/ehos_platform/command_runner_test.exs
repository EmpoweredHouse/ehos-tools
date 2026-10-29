defmodule EhosPlatform.CommandRunnerTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.CommandRunnerImpl, as: Runner

  describe "run_bounded/3" do
    test "returns what a program printed and its status when it ends in time" do
      assert Runner.run_bounded("sh", ["-c", "echo out; echo err >&2; exit 3"], 5_000) ==
               {"out\nerr\n", 3}
    end

    # eh-os#291: a command that would wait for ever is killed, and nothing of it is left running.
    @tag :tmp_dir
    test "kills a program that runs past its time", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "pid")
      started = System.monotonic_time(:millisecond)

      assert Runner.run_bounded("sh", ["-c", "echo $$ > #{pid_file}; exec sleep 30"], 300) ==
               {:error, :timeout}

      assert System.monotonic_time(:millisecond) - started < 5_000
      assert gone_within?(String.trim(File.read!(pid_file)), 50)
    end

    test "says when the program is not installed" do
      assert Runner.run_bounded("no-such-program-ehos", [], 1_000) == {:error, :not_found}
    end
  end

  # Gone once the VM has reaped it, which may take a moment after the kill: asked `tries` times,
  # 20 ms apart.
  defp gone_within?(_pid, 0), do: false

  defp gone_within?(pid, tries) do
    if gone?(pid) do
      true
    else
      Process.sleep(20)
      gone_within?(pid, tries - 1)
    end
  end

  defp gone?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
      {stat, 0} -> String.starts_with?(String.trim(stat), "Z")
      {_none, _status} -> true
    end
  end
end

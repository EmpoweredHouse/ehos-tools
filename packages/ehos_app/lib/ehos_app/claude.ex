defmodule EhosApp.Claude do
  @moduledoc """
  The `claude` command line, as a way out (ehos-tools T-20): where `EhosApp.Plugins` asks which
  marketplaces and plugins this machine holds, so a test says what it holds without running
  Claude Code. A caller names an implementation in `opts[:claude]`, and `EhosApp.ClaudeImpl`, the
  installed `claude`, is the default.
  """

  @doc """
  Runs `claude` with `args` in `dir`, and returns `{:ok, stdout}` when it exits with status 0.

  Returns `{:error, :not_installed}` when no `claude` is on the path,
  `{:error, {:exit, status}}` when it exits with another status, and `{:error, :timeout}` when it
  does not answer in time: a hook waits on it at the start of every session.
  """
  @callback run(args :: [String.t()], dir :: Path.t()) ::
              {:ok, String.t()}
              | {:error, :not_installed}
              | {:error, :timeout}
              | {:error, {:exit, pos_integer()}}
end

defmodule EhosApp.ClaudeImpl do
  @moduledoc "The `EhosApp.Claude` of this machine: the `claude` on the path, run through a port."

  @behaviour EhosApp.Claude

  # `claude` answers these in about a second; one that waits on a prompt would hold the session's
  # start for the hook's whole timeout. A port gives the program's OS process, so a `claude` that
  # does not answer in time is killed with the check, not left running (ehos-tools#849).
  @timeout 20_000

  @impl true
  def run(args, dir) do
    case System.find_executable("claude") do
      nil -> {:error, :not_installed}
      claude -> run_claude(claude, args, dir)
    end
  end

  # Standard error is not gathered: the answer is JSON on standard output.
  defp run_claude(claude, args, dir) do
    port =
      Port.open({:spawn_executable, claude}, [
        :binary,
        :exit_status,
        :hide,
        args: args,
        cd: dir
      ])

    gather(port, [], System.monotonic_time(:millisecond) + @timeout)
  end

  defp gather(port, output, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> gather(port, [output | data], deadline)
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(output)}
      {^port, {:exit_status, status}} -> {:error, {:exit, status}}
    after
      left -> kill(port)
    end
  end

  # Kills the program the port started, not the programs it started in turn. A program whose exit
  # is already known is not killed, since its pid may belong to another process by now. What the
  # port still sends once it is closed is taken out of the caller's mailbox.
  defp kill(port) do
    receive do
      {^port, {:exit_status, _status}} -> flush(port)
    after
      0 -> kill_running(port)
    end
  end

  defp kill_running(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid),
         kill when is_binary(kill) <- System.find_executable("kill") do
      System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    close(port)
  end

  defp close(port) do
    Port.close(port)
    flush(port)
  catch
    :error, :badarg -> flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> {:error, :timeout}
    end
  end
end

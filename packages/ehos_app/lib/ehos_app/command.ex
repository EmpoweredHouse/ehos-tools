defmodule EhosApp.Command do
  @moduledoc "A bounded external command, replaceable through a caller's `:command` option."

  @doc "Runs a program in a directory; returns stdout or a bounded failure without its output."
  @callback run(String.t(), [String.t()], Path.t()) ::
              {:ok, String.t()} | {:error, :not_installed | :timeout | {:exit, pos_integer()}}
end

defmodule EhosApp.CommandImpl do
  @moduledoc "Runs installed command-line tools through a bounded port, without collecting stderr."

  @behaviour EhosApp.Command

  # Bound a stalled CLI call and terminate its OS process, preserving the review hook's
  # existing timeout guarantee (ehos-tools#849).
  @timeout 20_000

  @impl true
  def run(program, args, dir) do
    case System.find_executable(program) do
      nil -> {:error, :not_installed}
      executable -> run_program(executable, args, dir)
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, {:exit, 1}}
  end

  # Standard error can contain credentials and is not part of the returned answer.
  defp run_program(executable, args, dir) do
    port =
      Port.open({:spawn_executable, executable}, [
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

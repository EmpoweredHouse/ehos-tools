defmodule EhosPlatform.CommandRunner.System do
  @moduledoc """
  The `EhosPlatform.CommandRunner` that runs programs on this machine with `System.cmd/3`.
  """

  @behaviour EhosPlatform.CommandRunner

  @impl true
  def run(program, args), do: cmd(program, args, [])

  @impl true
  def run_in(dir, program, args), do: cmd(program, args, cd: dir)

  @impl true
  def run_env(program, args, env), do: cmd(program, args, env: env)

  # A port, so that the program's OS process can be killed: a task that times out would leave it
  # running. Its output is gathered until it exits or the time is up.
  @impl true
  # sobelow_skip ["CI.System"]
  def run_bounded(program, args, timeout) do
    case System.find_executable(program) do
      nil ->
        {:error, :not_found}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args
          ])

        deadline = System.monotonic_time(:millisecond) + timeout
        gather(port, [], deadline)
    end
  end

  defp gather(port, output, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> gather(port, [output | data], deadline)
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(output), status}
    after
      left -> kill(port)
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    Port.close(port)
    {:error, :timeout}
  catch
    :error, :badarg -> {:error, :timeout}
  end

  # Running programs is this module's purpose. Callers are EHOS's own Mix tasks, which pass fixed
  # program names and directories; nothing here is reachable from a request.
  # sobelow_skip ["CI.System"]
  defp cmd(program, args, opts) do
    case System.find_executable(program) do
      nil -> {:error, :not_found}
      path -> System.cmd(path, args, [stderr_to_stdout: true] ++ opts)
    end
  end
end

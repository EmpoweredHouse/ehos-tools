defmodule EhosPlatform.CommandRunner do
  @moduledoc """
  Running an external program, as a way out (T-20): `EhosPlatform.Server` and
  `EhosPlatform.Install` run `tofu`, `ssh`, `helm` and `kubectl` only through this behaviour, and
  eh-os's Mix tasks run theirs through it too, so the logic is tested without those programs
  installed (eh-os D-27). A caller names an implementation in `opts[:runner]`, and
  `EhosPlatform.CommandRunnerImpl`, which runs them on this machine, is the default. A caller that
  runs them its own way implements it too, as `ehosctl` does to run the versions
  `EhosPlatform.Tools` pins through mise (T-13).
  """

  @typedoc "What a finished program returned: its combined output and its exit status."
  @type result :: {output :: String.t(), exit_status :: non_neg_integer()}

  @doc """
  Runs `program` with `args` and returns its output and exit status.

  Returns `{:error, :not_found}` when `program` is not on the `PATH`, so a missing tool is an
  ordinary result rather than an exception.
  """
  @callback run(program :: String.t(), args :: [String.t()]) :: result() | {:error, :not_found}

  @doc """
  Runs `program` with `args` in the directory `dir`, otherwise as `c:run/2`.
  """
  @callback run_in(dir :: Path.t(), program :: String.t(), args :: [String.t()]) ::
              result() | {:error, :not_found}

  @doc """
  Runs `program` with `args` and these variables added to its environment, otherwise as `c:run/2`.

  For values a program must not get on its command line, where any user of the machine can read
  them: a passphrase, for one. A variable given `nil` is taken out of the program's environment.
  """
  @callback run_env(
              program :: String.t(),
              args :: [String.t()],
              env :: [{String.t(), String.t() | nil}]
            ) :: result() | {:error, :not_found}

  @doc """
  Runs `program` with `args`, as `c:run/2`, for at most `timeout` milliseconds: a program still
  running then is killed, and the result is `{:error, :timeout}`. For a command that can wait for
  ever on something it does not control, an SSH control socket whose master is wedged, for one.
  """
  @callback run_bounded(program :: String.t(), args :: [String.t()], timeout :: pos_integer()) ::
              result() | {:error, :not_found} | {:error, :timeout}
end

defmodule EhosPlatform.CommandRunnerImpl do
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

  # What the port still sends once it is closed is taken out of the caller's mailbox, so a
  # long-lived caller never meets it.
  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid),
         kill when is_binary(kill) <- System.find_executable("kill") do
      System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    Port.close(port)
    flush(port)
    {:error, :timeout}
  catch
    :error, :badarg ->
      flush(port)
      {:error, :timeout}
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
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

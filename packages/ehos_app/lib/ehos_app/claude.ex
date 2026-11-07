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
  @moduledoc "The `EhosApp.Claude` of this machine: the `claude` on the path, run with `System.cmd/3`."

  @behaviour EhosApp.Claude

  # `claude` answers these in about a second; one that waits on a prompt would hold the session's
  # start for the hook's whole timeout.
  @timeout 20_000

  @impl true
  def run(args, dir) do
    case System.find_executable("claude") do
      nil -> {:error, :not_installed}
      claude -> run_claude(claude, args, dir)
    end
  end

  defp run_claude(claude, args, dir) do
    task = Task.async(fn -> System.cmd(claude, args, cd: dir) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {_output, status}} -> {:error, {:exit, status}}
      nil -> {:error, :timeout}
    end
  end
end

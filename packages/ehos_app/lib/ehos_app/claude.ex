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
  @moduledoc "Runs the installed Claude CLI through the shared bounded command runner."
  @behaviour EhosApp.Claude

  @impl true
  def run(args, dir), do: EhosApp.CommandImpl.run("claude", args, dir)
end

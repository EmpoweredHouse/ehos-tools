defmodule EhosApp.Claude do
  @moduledoc """
  The `claude` command line, as a way out (ehos-tools T-20): where `EhosApp.Plugins` asks which
  marketplaces and plugins this machine holds, so a test says what it holds without running
  Claude Code. A caller names an implementation in `opts[:claude]`, and `EhosApp.ClaudeImpl`, the
  installed `claude`, is the default.
  """

  @doc """
  Runs `claude` with `args` in `dir`, and returns `{:ok, stdout}` when it exits with status 0.

  Returns `{:error, :not_installed}` when no `claude` is on the path, and
  `{:error, {:exit, status}}` when it exits with another status.
  """
  @callback run(args :: [String.t()], dir :: Path.t()) ::
              {:ok, String.t()}
              | {:error, :not_installed}
              | {:error, {:exit, pos_integer()}}
end

defmodule EhosApp.ClaudeImpl do
  @moduledoc "The `EhosApp.Claude` of this machine: the `claude` on the path, run with `System.cmd/3`."

  @behaviour EhosApp.Claude

  @impl true
  def run(args, dir) do
    case System.find_executable("claude") do
      nil -> {:error, :not_installed}
      claude -> claude |> System.cmd(args, cd: dir) |> result()
    end
  end

  defp result({output, 0}), do: {:ok, output}
  defp result({_output, status}), do: {:error, {:exit, status}}
end

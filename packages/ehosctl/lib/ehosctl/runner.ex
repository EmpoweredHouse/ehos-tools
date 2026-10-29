defmodule Ehosctl.Runner do
  @moduledoc """
  Running a program, as a way out (T-20): git for a checkout, mise for `init` and `verify`, the
  browser's opener, the keychain's tool. A test mocks it and reads the programs a command would
  run; none starts one unless it says so.
  """

  @typedoc """
  Where a program runs: `:cd`, its directory, and `:env`, variables added or, as `nil`, taken
  out.
  """
  @type opts :: [cd: Path.t(), env: [{String.t(), String.t() | nil}]]

  @doc """
  Runs `program` with `args` and waits for it, as `System.cmd/3` does with stderr merged into
  stdout: its output and exit status. Raises `ErlangError` when `program` cannot be started.
  """
  @callback run(program :: String.t(), args :: [String.t()], opts()) ::
              {output :: String.t(), status :: non_neg_integer()}

  @doc """
  Runs `program` with `args` and `env` on the terminal's own input and output, so it can ask a
  question and its errors stay on stderr, and returns its exit status.
  """
  @callback interactive(
              program :: String.t(),
              args :: [String.t()],
              env :: [{String.t(), String.t()}]
            ) :: non_neg_integer()

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.RunnerImpl do
  @moduledoc "The `Ehosctl.Runner` that runs programs on this machine."

  @behaviour Ehosctl.Runner

  @impl true
  def run(program, args, opts), do: System.cmd(program, args, [stderr_to_stdout: true] ++ opts)

  # `System.cmd/3` gives the command a pipe for stdin that nobody writes to, so a command that asks
  # a question would wait forever, and it can only merge stderr into stdout. A port with
  # `:nouse_stdio` talks to the command over other descriptors and leaves it the terminal's stdin,
  # stdout and stderr: prompts can be answered, and errors stay on stderr.
  @impl true
  def interactive(program, args, env) do
    env =
      Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    port =
      Port.open({:spawn_executable, program}, [:nouse_stdio, :exit_status, args: args, env: env])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end
end

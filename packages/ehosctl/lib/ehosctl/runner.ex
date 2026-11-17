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
  Runs `program` with `args` and `env`, variables added or, as `nil`, taken out, on the
  terminal's own input and output, so it can ask a question and its errors stay on stderr, and
  returns its exit status.
  """
  @callback interactive(
              program :: String.t(),
              args :: [String.t()],
              env :: [{String.t(), String.t() | nil}]
            ) :: non_neg_integer()

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.RunnerImpl do
  @moduledoc """
  The `Ehosctl.Runner` that runs programs on this machine. A program it starts gets this
  process's environment without any `RELEASE_*` variable, `__BURRITO*` or `_IS_TTY`, which
  ehosctl's release sets: with `RELEASE_ROOT` set, `mix test` takes itself for a release, and an
  application refuses to start. A `RELEASE_*` variable the person exported is taken out too; one
  the caller sets is kept. `ROOTDIR` and `BINDIR` are kept, since every `erl` sets its own.
  """

  @behaviour Ehosctl.Runner

  @impl true
  def run(program, args, opts) do
    {env, opts} = Keyword.pop(opts, :env, [])
    System.cmd(program, args, [stderr_to_stdout: true, env: child_env(env)] ++ opts)
  end

  # `System.cmd/3` gives the command a pipe for stdin that nobody writes to, so a command that asks
  # a question would wait forever, and it can only merge stderr into stdout. A port with
  # `:nouse_stdio` talks to the command over other descriptors and leaves it the terminal's stdin,
  # stdout and stderr: prompts can be answered, and errors stay on stderr.
  @impl true
  def interactive(program, args, env) do
    env =
      Enum.map(child_env(env), fn {name, value} ->
        {String.to_charlist(name), port_value(value)}
      end)

    port =
      Port.open({:spawn_executable, program}, [:nouse_stdio, :exit_status, args: args, env: env])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  # This is the edge of the machine, so it reads this process's environment itself, not through
  # `Ehosctl.SystemEnv`: what it takes out is what the program would otherwise inherit.
  defp child_env(env) do
    set = MapSet.new(env, &elem(&1, 0))

    released =
      for {name, _value} <- System.get_env(),
          release_variable?(name) and not MapSet.member?(set, name),
          do: {name, nil}

    released ++ env
  end

  defp release_variable?(name),
    do: String.starts_with?(name, ["RELEASE_", "__BURRITO"]) or name == "_IS_TTY"

  defp port_value(nil), do: false
  defp port_value(value), do: String.to_charlist(value)
end

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

  @doc """
  Runs `program` with `args` in the foreground of the person's terminal, and returns its exit
  status: its standard input, output and error are the terminal itself, and the keys that send a
  signal, such as Ctrl-C, reach it alone, not `ehosctl`. `env` adds variables, and takes out each
  one given as `nil`. For `psql` in `ehosctl db connect`, and for the wait of `ehosctl db tunnel`.
  """
  @callback foreground(
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

  # Under Burrito, `ehosctl`'s standard output is a pipe to its launcher, and `psql` writes no
  # prompt when its output is not a terminal. And Ctrl-C sends SIGINT to the terminal's
  # foreground process group: the launcher, which then ends, and the VM, which then stops in its
  # break menu, with every tunnel. So the program runs from `/dev/tty`, as a job of a shell with
  # job control (`set -m`), which puts it in a process group of its own and makes that group the
  # terminal's foreground (`fg`) until it ends. Checked on 17 November 2026 with macOS's
  # /bin/sh (bash 3.2), dash and BusyBox: Ctrl-C reached the job alone (ehos-tools#924).
  # `fg`'s own output, the job's command line, is dropped; its error output stays on the
  # terminal, where bash needs it for job control.
  @foreground ~S(set -m; "$0" "$@" </dev/tty >/dev/tty 2>/dev/tty & fg >/dev/null)

  @impl true
  def foreground(program, args, env) do
    env =
      Enum.map(env, fn
        {name, nil} -> {String.to_charlist(name), false}
        {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
      end)

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:nouse_stdio, :exit_status, args: ["-c", @foreground, program | args], env: env]
      )

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end
end

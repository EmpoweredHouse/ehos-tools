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

  @doc """
  Runs `program` with `args` and `env`, variables added or, as `nil`, taken out, and gives what
  it prints on stdout and stderr, as it prints it, to `fun` with `acc`, each part when it comes:
  `fun` returns the next `acc`. Returns the exit status and the last `acc`. Its standard input
  is ehosctl's own, the terminal's when a person runs it, so a question it asks can still be
  answered.
  """
  @callback streamed(
              program :: String.t(),
              args :: [String.t()],
              env :: [{String.t(), String.t() | nil}],
              acc :: term(),
              fun :: (binary(), term() -> term())
            ) :: {status :: non_neg_integer(), acc :: term()}

  @doc """
  Runs `program` with `args` in the foreground of the person's terminal, and returns its exit
  status: its standard input, output and error are a terminal that shows on the person's, and the
  keys that send a signal, such as Ctrl-C, reach it alone, not `ehosctl`. `env` adds variables,
  and takes out each one given as `nil`. For `psql` in `ehosctl db connect`, and for the wait of
  `ehosctl db tunnel`.
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
    port =
      Port.open({:spawn_executable, program}, [
        :nouse_stdio,
        :exit_status,
        args: args,
        env: port_env(env)
      ])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  # `:in` reads the program's output and writes nothing to it: its standard input stays this
  # process's, the terminal when a person runs ehosctl, so a question it asks can be answered.
  # Its stderr is read with its stdout, in the order it wrote them.
  @impl true
  def streamed(program, args, env, acc, fun) do
    port =
      Port.open({:spawn_executable, program}, [
        :in,
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: port_env(env)
      ])

    streaming(port, acc, fun)
  end

  defp streaming(port, acc, fun) do
    receive do
      {^port, {:data, printed}} -> streaming(port, fun.(printed, acc), fun)
      {^port, {:exit_status, status}} -> {status, acc}
    end
  end

  # Under Burrito, `ehosctl`'s standard output is a pipe to its launcher, and `psql` writes no
  # prompt when its output is not a terminal. And Ctrl-C sends SIGINT to the terminal's
  # foreground process group: the launcher, which then ends, and the VM, which then stops in its
  # break menu, with every tunnel. A port cannot give its program the person's terminal: OTP's
  # `erl_child_setup` calls `setsid()` for every program it starts, so the program has no
  # controlling terminal, cannot open `/dev/tty`, and cannot join the terminal's foreground, and
  # no new session can take a terminal that is already another session's (ehos-tools#976).
  # So the program runs under `script`, which opens a new pseudo-terminal, makes it the program's
  # controlling terminal, and copies between it and the person's terminal, which it puts in raw
  # mode: Ctrl-C comes to it as a key, and reaches the program alone. `script` comes with macOS
  # (BSD's) and with util-linux, which most Linux distributions install; the two take different
  # arguments.
  @script "/usr/bin/script"

  @impl true
  def foreground(program, args, env) do
    {script_args, env} = script(:os.type(), program, args, env)

    port =
      Port.open(
        {:spawn_executable, @script},
        [:nouse_stdio, :exit_status, args: script_args, env: port_env(env)]
      )

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  # No typescript is kept (`/dev/null`), and `script` says nothing of its own (`-q`). BSD's
  # `script` runs the program itself, and returns its exit status, or the number of the signal
  # that ended it. util-linux's runs a command line in `$SHELL`, and with `-e` returns the exit
  # status, or 128 and the signal's number. That shell is `/bin/sh`, not the person's: their
  # shell reads its own files before it runs the line (fish's config.fish, zsh's .zshenv), which
  # could set a libpq variable over the session's, and it may not read the line as `sh` does.
  # The line gives the program the person's `SHELL` back, which psql's `\!` starts.
  defp script({:unix, :darwin}, program, args, env),
    do: {["-q", "/dev/null", program | args], env}

  defp script({:unix, _linux}, program, args, env) do
    line =
      shell(List.keyfind(env, "SHELL", 0)) <>
        "exec " <> Enum.map_join([program | args], " ", &quoted/1)

    {["-q", "-e", "-c", line, "/dev/null"], List.keystore(env, "SHELL", 0, {"SHELL", "/bin/sh"})}
  end

  defp shell(nil), do: shell({"SHELL", System.get_env("SHELL")})
  defp shell({"SHELL", nil}), do: "unset SHELL; "
  defp shell({"SHELL", value}), do: "SHELL=" <> quoted(value) <> "; export SHELL; "

  # In single quotes, with each single quote closed, escaped and reopened, as `sh` reads it.
  defp quoted(word), do: "'" <> String.replace(word, "'", ~S('\'')) <> "'"

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

  defp port_env(env),
    do:
      Enum.map(child_env(env), fn {name, value} ->
        {String.to_charlist(name), port_value(value)}
      end)

  defp port_value(nil), do: false
  defp port_value(value), do: String.to_charlist(value)
end

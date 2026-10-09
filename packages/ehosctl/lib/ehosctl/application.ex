defmodule Ehosctl.Application do
  @moduledoc """
  The OTP application, and inside the binary the one place that runs a command and halts.

  Burrito's launcher boots the release and would then hand argv to Elixir's own CLI, so the
  command runs in `start/2` instead and the VM halts with its exit code (see the comment
  there). Under `mix test` the application starts and runs nothing.
  """

  use Application

  # Burrito's launcher boots the release and then runs `-s elixir start_cli`, which reads
  # the same command line as Elixir's own CLI: `--version` prints the Erlang banner and
  # `ehosctl deploy` looks for a script file called `deploy`. So the command runs here,
  # synchronously, and halts the VM before `start_cli` is reached. Under `mix test` the
  # application starts without running anything.
  @impl true
  def start(_type, _args) do
    if Burrito.Util.running_standalone?() do
      System.halt(run(Burrito.Util.Args.argv()))
    end

    Supervisor.start_link([], strategy: :one_for_one, name: Ehosctl.Supervisor)
  end

  # An exception escaping `start/2` fails the application's boot, and the VM answers
  # that with a kernel crash report and possibly an `erl_crash.dump` in the user's
  # directory. One line on stderr and exit code 1 say the same thing.
  @doc """
  Runs `main` on `argv` and returns its exit code, turning an exception that escapes it into
  one line on stderr and exit code 1, rather than a crash report and an `erl_crash.dump`.
  """
  @spec run([String.t()], ([String.t()] -> non_neg_integer())) :: non_neg_integer()
  def run(argv, main \\ &Ehosctl.CLI.main/1) do
    main.(argv)
  rescue
    exception ->
      IO.puts(:stderr, "ehosctl: " <> Exception.message(exception))
      1
  end
end

defmodule Ehosctl.Application do
  @moduledoc false

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
  @doc false
  @spec run([String.t()], ([String.t()] -> non_neg_integer())) :: non_neg_integer()
  def run(argv, main \\ &Ehosctl.CLI.main/1) do
    main.(argv)
  rescue
    exception ->
      IO.puts(:stderr, "ehosctl: " <> Exception.message(exception))
      1
  end
end

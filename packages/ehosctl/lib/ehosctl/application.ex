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
      System.halt(Ehosctl.CLI.main(Burrito.Util.Args.argv()))
    end

    Supervisor.start_link([], strategy: :one_for_one, name: Ehosctl.Supervisor)
  end
end

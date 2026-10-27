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
      # ehosctl says nothing through Logger, and a crash report would print the value a process
      # crashed over, as `run/2` does not (`shown/1`).
      :logger.set_primary_config(:level, :none)
      System.halt(run(Burrito.Util.Args.argv()))
    end

    Supervisor.start_link([], strategy: :one_for_one, name: Ehosctl.Supervisor)
  end

  # An exception escaping `start/2` fails the application's boot, and the VM answers
  # that with a kernel crash report and possibly an `erl_crash.dump` in the user's
  # directory. One line on stderr and exit code 1 say the same thing.
  @doc """
  Runs `main` on `argv`, by default the command line with the update notice after it
  (`Ehosctl.Notice`), and returns its exit code, turning an exception that escapes it into
  one line on stderr and exit code 1, rather than a crash report and an `erl_crash.dump`.
  Stdout and stderr write UTF-8 whatever the locale says.
  """
  @spec run([String.t()], ([String.t()] -> non_neg_integer())) :: non_neg_integer()
  def run(argv, main \\ &Ehosctl.CLI.main(&1, notice: [])) do
    unicode_io()
    # A task the command starts is linked to it: one that crashes would kill this process with
    # its reason, the value it raised over in it, past the `rescue`. Trapped, it reaches
    # `Task.await/2` or `Task.async_stream/3` as an exit, which the `catch` reports.
    trapping? = Process.flag(:trap_exit, true)

    try do
      main.(argv)
    rescue
      exception ->
        IO.puts(:stderr, "ehosctl: " <> shown(exception))
        1
    catch
      kind, _reason ->
        IO.puts(:stderr, "ehosctl: " <> unshown(kind))
        1
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  # An exception's message may hold the value it was raised over: a KeyError the whole list or map
  # it searched, a MatchError the term that did not match, an ErlangError its reason, many an
  # ArgumentError its argument. That value can be the process environment, a GitHub Actions job's
  # request token in it, or a credential, and stderr is the job's log. So only the messages known
  # to hold no value are printed, a missing key's with the key alone; any other exception, and an
  # exit or a throw, is named without it.
  @doc false
  @spec shown(Exception.t()) :: String.t()
  def shown(%KeyError{message: nil, key: key} = exception) when is_atom(key) or is_binary(key),
    do: Exception.message(%{exception | term: nil})

  def shown(%RuntimeError{} = exception), do: Exception.message(exception)
  def shown(%module{}), do: unshown(module)

  defp unshown(kind),
    do:
      "#{what(kind)}, whose value is not shown: it may hold the environment or a credential. " <>
        "Please report it at https://github.com/EmpoweredHouse/ehos-tools/issues."

  defp what(:exit), do: "a process exited"
  defp what(:throw), do: "a value was thrown"
  defp what(module), do: inspect(module)

  # `erl` takes stdio's encoding from the locale, and where it names no UTF-8 (LANG unset, as
  # under cron, in CI or over a bare SSH session) writes latin1: an application's
  # "Lista komputerów" came out as "komputer\xF3w", and "rezerwację" lost its last letter. As
  # Go's and Rust's tools do, ehosctl writes UTF-8 whatever the locale; a terminal set to
  # another encoding (ISO-8859-2) shows non-ASCII wrong, which it would for those tools too. A device that refuses
  # the option (a closed stdout) is left as it is: there is nowhere to say so.
  defp unicode_io do
    for device <- [:standard_io, :standard_error], do: :io.setopts(device, encoding: :unicode)
    :ok
  end
end

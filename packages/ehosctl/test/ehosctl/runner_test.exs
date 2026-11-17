defmodule Ehosctl.RunnerTest do
  # Not async: it sets the variables a Burrito release sets in this process's own environment,
  # which every async test would otherwise see. ExUnit runs this module after them, alone.
  use Ehosctl.Case, async: false

  alias Ehosctl.RunnerImpl

  @release %{
    "RELEASE_ROOT" => "/opt/ehosctl/0.0.0",
    "RELEASE_SYS_CONFIG" => "/opt/ehosctl/0.0.0/releases/0.0.0/sys",
    "__BURRITO" => "1",
    "__BURRITO_BIN_PATH" => "/usr/local/bin/ehosctl",
    "_IS_TTY" => "1"
  }

  @print ~s(printf '%s|' "${RELEASE_ROOT-unset}" "${RELEASE_SYS_CONFIG-unset}" "${__BURRITO-unset}" "${__BURRITO_BIN_PATH-unset}" "${_IS_TTY-unset}" "${HOME-unset}")

  setup do
    before = Map.new(Map.keys(@release), &{&1, System.get_env(&1)})
    System.put_env(@release)
    on_exit(fn -> Enum.each(before, &restore/1) end)
  end

  test "a program run does not get the variables ehosctl's release set" do
    assert RunnerImpl.run("/bin/sh", ["-c", @print], []) ==
             {"unset|unset|unset|unset|unset|#{System.get_env("HOME")}|", 0}
  end

  test "a program run keeps a release variable its caller sets, and takes out one it unsets" do
    assert RunnerImpl.run("/bin/sh", ["-c", @print],
             env: [{"RELEASE_ROOT", "/srv/shop"}, {"HOME", nil}]
           ) ==
             {"/srv/shop|unset|unset|unset|unset|unset|", 0}
  end

  test "an interactive program does not get the variables ehosctl's release set" do
    check =
      ~s(test -z "${RELEASE_ROOT+x}${RELEASE_SYS_CONFIG+x}${__BURRITO+x}${__BURRITO_BIN_PATH+x}${_IS_TTY+x}")

    assert RunnerImpl.interactive("/bin/sh", ["-c", check], []) == 0
  end

  test "an interactive program keeps a variable its caller sets, and takes out one it unsets" do
    check = ~s(test "$RELEASE_ROOT" = /srv/shop && test -z "${HOME+x}")

    assert RunnerImpl.interactive("/bin/sh", ["-c", check], [
             {"RELEASE_ROOT", "/srv/shop"},
             {"HOME", nil}
           ]) ==
             0
  end

  # ehos-tools#976: a port's program has no controlling terminal, so this runs `foreground/3` in a
  # VM of its own, in a pseudo-terminal of another `script`, as a person's terminal holds
  # `ehosctl`, with its standard output a pipe, as Burrito's launcher makes it. Ctrl-C is typed
  # once the program is ready.
  test "a foreground program has the terminal, gets Ctrl-C alone, and gives its exit status" do
    program =
      ~S(trap 'echo interrupted; exit 7' INT; : </dev/tty && [ -t 0 ] && [ -t 1 ] && echo ready; while :; do sleep 1; done)

    eval =
      ~S|application:ensure_all_started(elixir), | <>
        ~S|Status = 'Elixir.Ehosctl.RunnerImpl':foreground(<<"/bin/sh">>, | <>
        ~S|[<<"-c">>, list_to_binary(os:getenv("PROGRAM"))], []), | <>
        ~S|io:format("status ~p~n", [Status]), halt().|

    vm = ~S("$ERL" -noshell -pa "$EHOSCTL" "$ELIXIR" -eval "$EVAL" | cat)

    terminal =
      Port.open({:spawn_executable, "/usr/bin/script"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: terminal_args(:os.type(), vm),
        env: [
          {~c"SHELL", ~c"/bin/sh"},
          {~c"ERL", Path.join([:code.root_dir(), "bin", "erl"]) |> String.to_charlist()},
          {~c"EHOSCTL", :code.which(RunnerImpl) |> Path.dirname() |> String.to_charlist()},
          {~c"ELIXIR", :code.lib_dir(:elixir) |> Path.join("ebin") |> String.to_charlist()},
          {~c"EVAL", String.to_charlist(eval)},
          {~c"PROGRAM", String.to_charlist(program)}
        ]
      ])

    ready = read_until(terminal, "ready", "")
    Port.command(terminal, <<3>>)
    {output, status} = read_until_exit(terminal, ready)

    assert {lines(output), status} == {["ready", "^Cinterrupted", "status 7"], 0}
  end

  # On Linux, `script` runs the program from a command line in a shell, which must not be the
  # person's: fish and zsh read files of their own first, which could set a libpq variable over
  # the session's (ehos-tools#976). The program still gets the person's shell as `SHELL`.
  @tag :tmp_dir
  test "a foreground program gets the person's shell as SHELL, and nothing the shell sets", %{
    tmp_dir: tmp_dir
  } do
    shell = Path.join(tmp_dir, "shell")
    File.write!(shell, "#!/bin/sh\nPGSSLMODE=prefer; export PGSSLMODE; exec /bin/sh \"$@\"\n")
    File.chmod!(shell, 0o755)
    seen = Path.join(tmp_dir, "seen")

    status =
      RunnerImpl.foreground(
        "/bin/sh",
        ["-c", ~S(printf '%s|%s' "${PGSSLMODE-unset}" "$SHELL" > "$0"), seen],
        [{"SHELL", shell}, {"PGSSLMODE", nil}]
      )

    assert {status, File.read!(seen)} == {0, "unset|" <> shell}
  end

  defp terminal_args({:unix, :darwin}, command), do: ["-q", "/dev/null", "/bin/sh", "-c", command]
  defp terminal_args({:unix, _linux}, command), do: ["-q", "-e", "-c", command, "/dev/null"]

  defp read_until(port, text, output) do
    if String.contains?(output, text) do
      output
    else
      receive do
        {^port, {:data, data}} -> read_until(port, text, output <> data)
      after
        15_000 -> flunk("No #{inspect(text)} in the terminal: #{inspect(output)}")
      end
    end
  end

  defp read_until_exit(port, output) do
    receive do
      {^port, {:data, data}} -> read_until_exit(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      15_000 -> flunk("The terminal did not end: #{inspect(output)}")
    end
  end

  defp lines(output),
    do: output |> String.replace("\r", "") |> String.split("\n", trim: true)

  defp restore({name, nil}), do: System.delete_env(name)
  defp restore({name, value}), do: System.put_env(name, value)
end

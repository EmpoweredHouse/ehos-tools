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
    "_IS_TTY" => "1",
    "EHOS_STATE_PASSPHRASE" => "a passphrase of 16+"
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

  test "a program run does not get the passphrase of the state, unless its caller sets it" do
    print = ~s(printf '%s' "${EHOS_STATE_PASSPHRASE-unset}")

    assert RunnerImpl.run("/bin/sh", ["-c", print], []) == {"unset", 0}

    assert RunnerImpl.run("/bin/sh", ["-c", print], env: [{"EHOS_STATE_PASSPHRASE", "set"}]) ==
             {"set", 0}
  end

  test "a streamed program does not get the passphrase of the state" do
    print = ~s(printf '%s' "${EHOS_STATE_PASSPHRASE-unset}")

    assert RunnerImpl.streamed("/bin/sh", ["-c", print], [], "", &(&2 <> &1)) == {0, "unset"}
  end

  test "a streamed program does not get the variables ehosctl's release set" do
    assert RunnerImpl.streamed("/bin/sh", ["-c", @print], [], "", &(&2 <> &1)) ==
             {0, "unset|unset|unset|unset|unset|#{System.get_env("HOME")}|"}
  end

  test "a streamed program keeps a variable its caller sets, and takes out one it unsets" do
    check = ~s(test "$RELEASE_ROOT" = /srv/shop && test -z "${HOME+x}")

    assert RunnerImpl.streamed(
             "/bin/sh",
             ["-c", check],
             [{"RELEASE_ROOT", "/srv/shop"}, {"HOME", nil}],
             nil,
             fn _printed, acc -> acc end
           ) == {0, nil}
  end

  test "a streamed program gives its stdout and stderr as it prints them, and its exit status" do
    {status, parts} =
      RunnerImpl.streamed(
        "/bin/sh",
        [
          "-c",
          "printf one; printf ' two\\n' >&2; test -z \"${RELEASE_ROOT+x}\" && exit 3; exit 4"
        ],
        [],
        [],
        &[&1 | &2]
      )

    assert {status, parts |> Enum.reverse() |> Enum.join()} == {3, "one two\n"}
  end

  # ehos-tools#976: a port's program has no controlling terminal, so this runs `foreground/3` in a
  # VM of its own, in a terminal (`terminal/2`). Ctrl-C is typed once the program is ready.
  test "a foreground program has the terminal, gets Ctrl-C alone, and gives its exit status" do
    program =
      ~S(trap 'echo interrupted; exit 7' INT; : </dev/tty && [ -t 0 ] && [ -t 1 ] && echo ready; while :; do sleep 1; done)

    terminal =
      terminal(
        ~S|Status = 'Elixir.Ehosctl.RunnerImpl':foreground(<<"/bin/sh">>, | <>
          ~S|[<<"-c">>, list_to_binary(os:getenv("PROGRAM"))], []), |,
        %{"PROGRAM" => program}
      )

    ready = read_until(terminal, "ready", "")
    Port.command(terminal, <<3>>)
    {output, status} = read_until_exit(terminal, ready)

    assert {lines(output), status} == {["ready", "^Cinterrupted", "status 7"], 0}
  end

  # On Linux, `script` runs the program from a command line in a shell, which must not be the
  # person's: fish and zsh read files of their own first, which could set a libpq variable over
  # the session's (ehos-tools#976). The program still gets the person's shell as `SHELL`.
  #
  # `foreground/3` runs in a VM of its own, in a terminal, as in the test above: `script` takes the
  # VM's standard input, and macOS's ends at once, with 1, when that is a socket, which some
  # runners give `mix test` (ehos-tools#990).
  @tag :tmp_dir
  test "a foreground program gets the person's shell as SHELL, and nothing the shell sets", %{
    tmp_dir: tmp_dir
  } do
    shell = Path.join(tmp_dir, "shell")
    File.write!(shell, "#!/bin/sh\nPGSSLMODE=prefer; export PGSSLMODE; exec /bin/sh \"$@\"\n")
    File.chmod!(shell, 0o755)
    seen = Path.join(tmp_dir, "seen")

    terminal =
      terminal(
        ~S|Status = 'Elixir.Ehosctl.RunnerImpl':foreground(<<"/bin/sh">>, | <>
          ~S|[<<"-c">>, list_to_binary(os:getenv("PROGRAM")), list_to_binary(os:getenv("SEEN"))], | <>
          ~S|[{<<"SHELL">>, list_to_binary(os:getenv("PERSON_SHELL"))}, {<<"PGSSLMODE">>, nil}]), |,
        %{
          "PROGRAM" => ~S(printf '%s|%s' "${PGSSLMODE-unset}" "$SHELL" > "$0"),
          "SEEN" => seen,
          "PERSON_SHELL" => shell
        }
      )

    {output, status} = read_until_exit(terminal, "")
    assert {lines(output), status, File.read!(seen)} == {["status 0"], 0, "unset|" <> shell}
  end

  # A VM of its own, in a pseudo-terminal of `script` as a person's terminal holds `ehosctl`, with
  # its standard output a pipe, as Burrito's launcher makes it. It runs `eval`, Erlang that calls
  # `RunnerImpl` and leaves `Status`, with `vars` in its environment, then prints the status and
  # stops.
  defp terminal(eval, vars) do
    eval =
      "application:ensure_all_started(elixir), " <>
        eval <> ~S|io:format("status ~p~n", [Status]), halt().|

    env =
      Map.merge(vars, %{
        "SHELL" => "/bin/sh",
        "ERL" => Path.join([:code.root_dir(), "bin", "erl"]),
        "EHOSCTL" => Application.app_dir(:ehosctl, "ebin"),
        # `Ehosctl.RunnerImpl` reads the variables `ehos_platform`'s runner withholds.
        "EHOS_PLATFORM" => Application.app_dir(:ehos_platform, "ebin"),
        "ELIXIR" => :code.lib_dir(:elixir) |> Path.join("ebin"),
        "EVAL" => eval
      })

    vm = ~S("$ERL" -noshell -pa "$EHOSCTL" "$EHOS_PLATFORM" "$ELIXIR" -eval "$EVAL" | cat)

    Port.open({:spawn_executable, "/usr/bin/script"}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: terminal_args(:os.type(), vm),
      env: Enum.map(env, fn {name, value} -> {~c"#{name}", ~c"#{value}"} end)
    ])
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

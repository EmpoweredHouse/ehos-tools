defmodule Ehosctl.CLITest do
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run
  # beside each other would read each other's errors, and each test compares stderr whole.
  use Ehosctl.Case, async: false

  import ExUnit.CaptureIO

  @invalid_name "is not a valid name for an application. The name has lowercase letters, " <>
                  "digits and underscores. It starts with a letter and ends with a letter or a " <>
                  "digit."

  @not_shown "whose value is not shown: it may hold the environment or a credential. Please " <>
               "report it at https://github.com/EmpoweredHouse/ehos-tools/issues.\n"

  test "prints the version" do
    printed = capture_io(fn -> assert Ehosctl.CLI.main(["--version"]) == 0 end)

    # A -dev build says on a second line the commit it was built from; CI compares only the
    # first with a release's tag.
    commit_line =
      case Version.parse!(Ehosctl.version()) do
        %Version{pre: []} -> ""
        _dev -> Enum.map_join(List.wrap(Ehosctl.commit()), &"commit #{&1}\n")
      end

    assert printed == "ehosctl #{Ehosctl.version()}\n" <> commit_line
  end

  test "prints its help without a command, and for help, --help and -h" do
    [help | others] =
      for argv <- [[], ["help"], ["--help"], ["-h"]],
          do: capture_io(fn -> assert Ehosctl.CLI.main(argv) == 0 end)

    assert others == [help, help, help]

    # Compared up to init's line: the rest lists every command's own declaration, and under it
    # Ehosctl.Template's pins, which each release of ehos_app moves.
    [head, _rest] = String.split(help, "\n    installations ", parts: 2)

    assert head == """
           ehosctl #{Ehosctl.version()}
           The command-line tool for EHOS.

           USAGE:
               ehosctl
               ehosctl --version
               ehosctl --help
               ehosctl help subcommand

           SUBCOMMANDS:

               init                 Create a new EHOS application in the directory NAME.\
           """
  end

  test "prints a command's help from its declaration, however it is asked for" do
    for argv <- [
          ["init", "--help"],
          ["init", "-h"],
          ["help", "init"],
          ["init", "shop", "--help"],
          ["init", "shop", "-h"]
        ] do
      assert capture_io(fn -> assert Ehosctl.CLI.main(argv) == 0 end) == init_help()
    end
  end

  test "prints a subcommand's help after its arguments, too" do
    help =
      capture_io(fn -> assert Ehosctl.CLI.main(["installations", "use", "x", "--help"]) == 0 end)

    assert help == """
           ehosctl #{Ehosctl.version()}
           Make an installation the current one.

           USAGE:
               ehosctl installations use [--json] NAME

           ARGS:

               NAME        The name of the installation.

           FLAGS:

               --json        Print one JSON document instead of words.

           Plane: local. This command works on this machine only, and needs no EHOS.

           """
  end

  test "hands a -h after -- to the command as its argument, which init refuses as a name" do
    for flag <- ["-h", "--help"] do
      stderr =
        capture_io(:stderr, fn -> assert Ehosctl.CLI.main(["init", "--", flag]) == 1 end)

      assert stderr == "ehosctl init: #{inspect(flag)} #{@invalid_name}\n"
    end
  end

  test "refuses a mistyped subcommand before --help, rather than printing its parent's help" do
    stderr =
      capture_io(:stderr, fn ->
        assert Ehosctl.CLI.main(["installations", "lsit", "--help"]) == 2
      end)

    assert stderr == """
           ehosctl: "installations lsit" is not a command of ehosctl.

           See `ehosctl --help`.
           """
  end

  test "reads help <command> --help as the command's help" do
    assert capture_io(fn -> assert Ehosctl.CLI.main(["help", "init", "--help"]) == 0 end) ==
             init_help()
  end

  test "pads no line of its help with spaces" do
    for argv <- [["--help"], ["init", "--help"]] do
      refute capture_io(fn -> Ehosctl.CLI.main(argv) end) =~ ~r/ +$/m
    end
  end

  test "refuses an unknown command as an invalid command line" do
    for argv <- [["rollback"], ["help", "rollback"], ["rollback", "--help"]] do
      stderr = capture_io(:stderr, fn -> assert Ehosctl.CLI.main(argv) == 2 end)

      assert stderr == """
             ehosctl: "rollback" is not a command of ehosctl.

             See `ehosctl --help`.
             """
    end
  end

  test "refuses arguments a command does not take, and points to its help" do
    for {argv, refused} <- [
          {["init"], "missing required arguments: NAME"},
          {["init", "a", "b"], ~s(unrecognized arguments: "b")},
          {["init", "a", "--bogus"], ~s(unrecognized arguments: "--bogus")}
        ] do
      stderr = capture_io(:stderr, fn -> assert Ehosctl.CLI.main(argv) == 2 end)

      assert stderr == """
             ehosctl: #{refused}

             See `ehosctl help init`.
             """
    end
  end

  test "refuses arguments after --version" do
    assert capture_io(:stderr, fn -> assert Ehosctl.CLI.main(["--version", "x"]) == 2 end) ==
             """
             ehosctl: unrecognized arguments: "--version", "x"

             See `ehosctl --help`.
             """
  end

  test "under --json, reports an error as one JSON object on stderr, with its kind's code" do
    {code, stderr} =
      with_io(:stderr, fn ->
        capture_io(fn -> send(self(), {:code, Ehosctl.CLI.main(["rollback", "--json"])}) end)
        assert_received {:code, code}
        code
      end)

    assert code == 2

    assert JSON.decode!(stderr) == %{
             "error" => %{
               "kind" => "invalid",
               "message" => ~s("rollback" is not a command of ehosctl.)
             }
           }
  end

  test "under --json, refuses a command that has no JSON output" do
    stderr = capture_io(:stderr, fn -> assert Ehosctl.CLI.main(["init", "x", "--json"]) == 2 end)

    assert JSON.decode!(stderr) == %{
             "error" => %{"kind" => "invalid", "message" => ~s(unrecognized arguments: "--json")}
           }
  end

  test "hands init the name it read, and runs nothing for one it refuses" do
    mock_no_program_run()

    stderr =
      capture_io(:stderr, fn ->
        assert Ehosctl.CLI.main(["init", "Bad"]) == 1
      end)

    assert stderr == ~s(ehosctl init: "Bad" #{@invalid_name}\n)
  end

  test "turns an exception into one line and exit code 1" do
    stderr =
      capture_io(:stderr, fn ->
        assert Ehosctl.Application.run([], fn _ -> raise "boom" end) == 1
      end)

    assert stderr == "ehosctl: boom\n"
  end

  # The value an exception was raised over can be the environment, a job's request token in it:
  # stderr is a GitHub Actions job's log.
  @tag :capture_log
  @tag :tmp_dir
  test "names what failed, never the value it failed over", %{tmp_dir: tmp_dir} do
    env = %{"ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "secret-token"}
    missing = Path.join(tmp_dir, "missing")

    for {raised, said} <- [
          {fn -> Keyword.fetch!([env: env], :installation) end, "key :installation not found\n"},
          {fn -> Map.fetch!(env, "EHOSCTL_URL") end, ~s(key "EHOSCTL_URL" not found\n)},
          # What the user can act on still says what it is.
          {fn -> File.read!(missing) end,
           ~s(could not read file "#{missing}": no such file or directory\n)},
          {fn -> %{"other" => _} = env end, "MatchError, " <> @not_shown},
          {fn -> case env, do: (%{"x" => _} -> :ok) end, "CaseClauseError, " <> @not_shown},
          {fn -> :erlang.error({:failed, env}) end, "ErlangError, " <> @not_shown},
          {fn -> Keyword.validate!([env: env], [:dir]) end, "ArgumentError, " <> @not_shown},
          {fn -> raise KeyError, key: :a, term: env, message: inspect(env) end,
           "KeyError, " <> @not_shown},
          {fn -> exit({:failed, env}) end, "a process exited, " <> @not_shown},
          {fn -> throw(env) end, "a value was thrown, " <> @not_shown},
          # A task the command starts, crashing over it, past the command's own `rescue`.
          {fn -> Task.await(Task.async(fn -> :erlang.error({:failed, env}) end)) end,
           "a process exited, " <> @not_shown},
          # Trapped, a crashed stream task is an `{:exit, reason}`, which no `{:ok, _}` matches.
          {fn ->
             [env] |> Task.async_stream(&Map.fetch!(&1, :nope)) |> Enum.map(fn {:ok, v} -> v end)
           end, "FunctionClauseError, " <> @not_shown}
        ] do
      stderr =
        capture_io(:stderr, fn ->
          assert Ehosctl.Application.run([], fn _ -> raised.() end) == 1
        end)

      assert stderr == "ehosctl: " <> said
    end
  end

  test "writes UTF-8 to a stdout the locale made latin1" do
    {:ok, device} = StringIO.open("", encoding: :latin1)
    test = self()

    # As the binary's stdout under an empty LANG: the group leader is a latin1 device.
    Task.async(fn ->
      Process.group_leader(self(), device)
      send(test, {:code, Ehosctl.Application.run([], fn _ -> IO.write("komputerów") && 0 end)})
    end)
    |> Task.await()

    assert_received {:code, 0}
    assert :io.getopts(device)[:encoding] == :unicode
    assert StringIO.contents(device) == {"", "komputerów"}
  end

  defp init_help do
    """
    ehosctl #{Ehosctl.version()}
    Create a new EHOS application in the directory NAME.

    USAGE:
        ehosctl init NAME

    ARGS:

        NAME        The name of the OTP application. The name has lowercase letters,
                    digits and underscores. It starts with a letter and ends with a
                    letter or a digit. ehosctl writes a dash as an underscore. In
                    EHOS, the application has dashes instead: `my_shop` is `my-shop`
                    there.

    Plane: local. This command works on this machine only, and needs no EHOS.

    """
  end

  defp mock_no_program_run,
    do: expect(Ehosctl.RunnerMock, :interactive, 0, fn _cmd, _args, _env -> 0 end)
end

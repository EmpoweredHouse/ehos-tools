defmodule Ehosctl.CLITest do
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run
  # beside each other would read each other's errors.
  use Ehosctl.Case, async: false

  import ExUnit.CaptureIO

  test "prints the version" do
    printed = capture_io(fn -> assert Ehosctl.CLI.main(["--version"]) == 0 end)

    # A -dev build says on a second line the commit it was built from; CI compares only the
    # first with a release's tag.
    assert [first | rest] = String.split(printed, "\n", trim: true)
    assert first == "ehosctl #{Ehosctl.version()}"

    case Version.parse!(Ehosctl.version()) do
      %Version{pre: []} -> assert rest == []
      _dev -> assert rest == for(commit <- List.wrap(Ehosctl.commit()), do: "commit #{commit}")
    end
  end

  test "prints its help without a command, and for help, --help and -h" do
    for argv <- [[], ["help"], ["--help"], ["-h"]] do
      help = capture_io(fn -> assert Ehosctl.CLI.main(argv) == 0 end)
      assert help =~ "USAGE:\n    ehosctl"
      assert help =~ ~r/^    init +Create a new EHOS application/m
    end
  end

  test "prints a command's help from its declaration, however it is asked for" do
    for argv <- [
          ["init", "--help"],
          ["init", "-h"],
          ["help", "init"],
          ["init", "shop", "--help"],
          ["init", "shop", "-h"]
        ] do
      help = capture_io(fn -> assert Ehosctl.CLI.main(argv) == 0 end)
      assert help =~ "USAGE:\n    ehosctl init NAME\n"
      assert help =~ ~r/^    NAME +The OTP application's name/m
      assert help =~ "Plane: local."
    end
  end

  test "prints a subcommand's help after its arguments, too" do
    help =
      capture_io(fn -> assert Ehosctl.CLI.main(["installations", "use", "x", "--help"]) == 0 end)

    assert help =~ "USAGE:\n    ehosctl installations use [--json] NAME"
  end

  test "hands a -h after -- to the command as its argument, which init refuses as a name" do
    for flag <- ["-h", "--help"] do
      stderr =
        capture_io(:stderr, fn -> assert Ehosctl.CLI.main(["init", "--", flag]) == 1 end)

      assert stderr =~ ~s(#{inspect(flag)} is not a valid application name)
    end
  end

  test "refuses a mistyped subcommand before --help, rather than printing its parent's help" do
    stderr =
      capture_io(:stderr, fn ->
        assert Ehosctl.CLI.main(["installations", "lsit", "--help"]) == 2
      end)

    assert stderr =~ ~s(unknown command "installations lsit")
  end

  test "reads help <command> --help as the command's help" do
    assert capture_io(fn -> assert Ehosctl.CLI.main(["help", "init", "--help"]) == 0 end) =~
             "USAGE:\n    ehosctl init NAME"
  end

  test "pads no line of its help with spaces" do
    for argv <- [["--help"], ["init", "--help"]] do
      refute capture_io(fn -> Ehosctl.CLI.main(argv) end) =~ ~r/ +$/m
    end
  end

  test "refuses an unknown command as an invalid command line" do
    for argv <- [["rollback"], ["help", "rollback"], ["rollback", "--help"]] do
      stderr = capture_io(:stderr, fn -> assert Ehosctl.CLI.main(argv) == 2 end)
      assert stderr =~ ~s(ehosctl: unknown command "rollback")
      assert stderr =~ "See `ehosctl --help`."
    end
  end

  test "refuses arguments a command does not take, and points to its help" do
    for argv <- [["init"], ["init", "a", "b"], ["init", "a", "--bogus"]] do
      stderr = capture_io(:stderr, fn -> assert Ehosctl.CLI.main(argv) == 2 end)
      assert stderr =~ "See `ehosctl help init`."
    end
  end

  test "refuses arguments after --version" do
    assert capture_io(:stderr, fn -> assert Ehosctl.CLI.main(["--version", "x"]) == 2 end) =~
             ~s(unrecognized arguments: "--version", "x")
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
             "error" => %{"kind" => "invalid", "message" => ~s(unknown command "rollback")}
           }
  end

  test "under --json, refuses a command that has no JSON output" do
    stderr = capture_io(:stderr, fn -> assert Ehosctl.CLI.main(["init", "x", "--json"]) == 2 end)
    assert %{"error" => %{"kind" => "invalid"}} = JSON.decode!(stderr)
  end

  test "hands init the name it read, with what the test injects" do
    runner = fn _cmd, _args, _env -> 0 end

    stderr =
      capture_io(:stderr, fn ->
        assert Ehosctl.CLI.main(["init", "Bad"], runner: runner, mise: "/bin/mise") == 1
      end)

    assert stderr =~ ~s("Bad" is not a valid application name)
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
          {fn -> File.read!(missing) end, ~s(could not read file "#{missing}")},
          {fn -> %{"other" => _} = env end, "MatchError, whose value is not shown"},
          {fn -> case env, do: (%{"x" => _} -> :ok) end, "CaseClauseError, whose value"},
          {fn -> :erlang.error({:failed, env}) end, "ErlangError, whose value is not shown"},
          {fn -> Keyword.validate!([env: env], [:dir]) end, "ArgumentError, whose value"},
          {fn -> raise KeyError, key: :a, term: env, message: inspect(env) end,
           "KeyError, whose"},
          {fn -> exit({:failed, env}) end, "a process exited, whose value is not shown"},
          {fn -> throw(env) end, "a value was thrown, whose value is not shown"},
          # A task the command starts, crashing over it, past the command's own `rescue`.
          {fn -> Task.await(Task.async(fn -> :erlang.error({:failed, env}) end)) end,
           "a process exited, whose value is not shown"},
          # Trapped, a crashed stream task is an `{:exit, reason}`, which no `{:ok, _}` matches.
          {fn ->
             [env] |> Task.async_stream(&Map.fetch!(&1, :nope)) |> Enum.map(fn {:ok, v} -> v end)
           end, "FunctionClauseError, whose value is not shown"}
        ] do
      stderr =
        capture_io(:stderr, fn ->
          assert Ehosctl.Application.run([], fn _ -> raised.() end) == 1
        end)

      assert stderr =~ said
      refute stderr =~ "secret-token"
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
    assert {_, "komputerów"} = StringIO.contents(device)
  end
end

defmodule Ehosctl.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "prints the version" do
    assert capture_io(fn -> assert Ehosctl.CLI.main(["--version"]) == 0 end) ==
             "ehosctl #{Ehosctl.version()}\n"
  end

  test "prints usage without a command" do
    assert capture_io(fn -> assert Ehosctl.CLI.main([]) == 0 end) =~ "init <name>"
  end

  test "refuses an unknown command" do
    assert capture_io(:stderr, fn -> assert Ehosctl.CLI.main(["deploy"]) == 1 end) =~
             ~s(unknown command "deploy")
  end

  test "refuses arguments after a flag" do
    assert capture_io(:stderr, fn -> assert Ehosctl.CLI.main(["--version", "x"]) == 1 end) =~
             "--version takes no arguments"
  end

  test "turns an exception into one line and exit code 1" do
    stderr =
      capture_io(:stderr, fn ->
        assert Ehosctl.Application.run([], fn _ -> raise "boom" end) == 1
      end)

    assert stderr == "ehosctl: boom\n"
  end
end

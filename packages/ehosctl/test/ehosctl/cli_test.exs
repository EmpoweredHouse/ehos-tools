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
end

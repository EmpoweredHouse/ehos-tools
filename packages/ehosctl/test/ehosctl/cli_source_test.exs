defmodule Ehosctl.CLISourceTest do
  # Sets EHOSCTL_TEMPLATE_SOURCE, which is global: so this module runs alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    on_exit(fn -> System.delete_env("EHOSCTL_TEMPLATE_SOURCE") end)
  end

  test "says in its help when EHOSCTL_TEMPLATE_SOURCE replaces the pinned template" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "ref:main")

    assert capture_io(fn -> Ehosctl.CLI.main(["--help"]) end) =~
             "ehos_app is taken from EHOSCTL_TEMPLATE_SOURCE=ref:main instead."
  end

  test "says nothing of it when it is empty, as a shell's VAR= means" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "")

    refute capture_io(fn -> Ehosctl.CLI.main(["--help"]) end) =~ "EHOSCTL_TEMPLATE_SOURCE"
  end
end

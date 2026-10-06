defmodule Ehosctl.CLISourceTest do
  # The help reads EHOSCTL_TEMPLATE_SOURCE, which is global, and these tests set it: so this
  # module runs alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    System.delete_env("EHOSCTL_TEMPLATE_SOURCE")
    on_exit(fn -> System.delete_env("EHOSCTL_TEMPLATE_SOURCE") end)
  end

  test "names in its help the version and what init creates an application from" do
    help = capture_io(fn -> assert Ehosctl.CLI.main(["--help"]) == 0 end)

    assert help =~ ~r/\Aehosctl #{Regex.escape(Ehosctl.version())}\n/
    assert help =~ "init <name>"

    for {label, value} <- Ehosctl.Template.pins() do
      assert help =~ ~r/^  #{Regex.escape(label)} +#{Regex.escape(value)}$/m
    end
  end

  test "says in its help when EHOSCTL_TEMPLATE_SOURCE replaces the pinned template" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "ref:main")

    assert capture_io(fn -> Ehosctl.CLI.main(["--help"]) end) =~
             ~s(ehos_app is taken from EHOSCTL_TEMPLATE_SOURCE="ref:main" instead.)
  end

  test "says in its help that init refuses a source it cannot use" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "bogus")

    help = capture_io(fn -> Ehosctl.CLI.main(["--help"]) end)

    assert help =~ ~s(EHOSCTL_TEMPLATE_SOURCE is "bogus", which init refuses)
    refute help =~ "taken from"
  end

  test "says nothing of it when it is empty, as a shell's VAR= means" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "")

    refute capture_io(fn -> Ehosctl.CLI.main(["--help"]) end) =~ "EHOSCTL_TEMPLATE_SOURCE"
  end
end

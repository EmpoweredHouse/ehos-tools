defmodule Ehosctl.CLISourceTest do
  use Ehosctl.Case, async: true

  import ExUnit.CaptureIO

  test "names with its version what init creates an application from, and not in its help" do
    printed = capture_io(fn -> assert Ehosctl.CLI.main(["--version"]) == 0 end)
    help = capture_io(fn -> assert Ehosctl.CLI.main(["--help"]) == 0 end)

    assert hd(String.split(printed, "\n")) == "ehosctl #{Ehosctl.version()}"
    assert pinned(printed) == pins()
    refute help =~ "Creates applications from"
  end

  test "says with its version when EHOSCTL_TEMPLATE_SOURCE replaces the pinned template" do
    stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => "ref:main"})

    printed = capture_io(fn -> Ehosctl.CLI.main(["--version"]) end)

    assert pinned(printed) ==
             pins() <>
               """

                 ehos_app is taken from EHOSCTL_TEMPLATE_SOURCE="ref:main" instead.
               """
  end

  test "says with its version that init refuses a source it cannot use" do
    stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => "bogus"})

    printed = capture_io(fn -> Ehosctl.CLI.main(["--version"]) end)

    assert pinned(printed) ==
             pins() <>
               """

                 EHOSCTL_TEMPLATE_SOURCE is "bogus", and init does not accept it.
                 Give path:PATH, with the absolute path of packages/ehos_app, or ref:REF, with a git ref of EmpoweredHouse/ehos-tools.
               """
  end

  test "says nothing of it when it is empty, as a shell's VAR= means" do
    stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => ""})

    printed = capture_io(fn -> Ehosctl.CLI.main(["--version"]) end)

    assert pinned(printed) == pins()
    refute printed =~ "EHOSCTL_TEMPLATE_SOURCE"
  end

  # What `--version` says after the version: what init creates an application from.
  defp pinned(printed) do
    [_version, pinned] = String.split(printed, "\nCreates applications from:\n")
    pinned
  end

  # The pins as `--version` lists them: each label written out, each value the template's own, which
  # moves with every release.
  defp pins do
    pins = Map.new(Ehosctl.Template.pins())

    """
      ehos_app        #{pins["ehos_app"]}
      Erlang          #{pins["Erlang"]}
      Elixir          #{pins["Elixir"]}
      phx_new         #{pins["phx_new"]}
      igniter_new     #{pins["igniter_new"]}
      igniter         #{pins["igniter"]}
      ehos_contract   #{pins["ehos_contract"]}
    """
  end
end

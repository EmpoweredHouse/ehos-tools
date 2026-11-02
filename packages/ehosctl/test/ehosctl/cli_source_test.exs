defmodule Ehosctl.CLISourceTest do
  use Ehosctl.Case, async: true

  import ExUnit.CaptureIO

  # The line the help's list of commands gives `init`.
  @init "    init                 Create a new EHOS application in the directory NAME."

  test "names in its help the version and what init creates an application from" do
    help = capture_io(fn -> assert Ehosctl.CLI.main(["--help"]) == 0 end)

    lines = String.split(help, "\n")
    assert hd(lines) == "ehosctl #{Ehosctl.version()}"
    assert Enum.find(lines, &String.starts_with?(&1, "    init ")) == @init
    assert pinned(help) == pins()
  end

  test "says in its help when EHOSCTL_TEMPLATE_SOURCE replaces the pinned template" do
    stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => "ref:main"})

    help = capture_io(fn -> Ehosctl.CLI.main(["--help"]) end)

    assert pinned(help) ==
             pins() <>
               """

                 ehos_app is taken from EHOSCTL_TEMPLATE_SOURCE="ref:main" instead.
               """
  end

  test "says in its help that init refuses a source it cannot use" do
    stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => "bogus"})

    help = capture_io(fn -> Ehosctl.CLI.main(["--help"]) end)

    assert pinned(help) ==
             pins() <>
               """

                 EHOSCTL_TEMPLATE_SOURCE is "bogus", and init does not accept it.
                 Give path:PATH, with the absolute path of packages/ehos_app, or ref:REF, with a git ref of EmpoweredHouse/ehos-tools.
               """
  end

  test "says nothing of it when it is empty, as a shell's VAR= means" do
    stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => ""})

    help = capture_io(fn -> Ehosctl.CLI.main(["--help"]) end)

    assert pinned(help) == pins()
    refute help =~ "EHOSCTL_TEMPLATE_SOURCE"
  end

  # What the help says under its list of commands: what init creates an application from.
  defp pinned(help) do
    [_commands, pinned] = String.split(help, "\nCreates applications from:\n")
    pinned
  end

  # The pins as the help lists them: each label written out, each value the template's own, which
  # moves with every release.
  defp pins do
    pins = Map.new(Ehosctl.Template.pins())

    """
      ehos_app         #{pins["ehos_app"]}
      Erlang           #{pins["Erlang"]}
      Elixir           #{pins["Elixir"]}
      phx_new          #{pins["phx_new"]}
      igniter_new      #{pins["igniter_new"]}
      eh_os_contract   #{pins["eh_os_contract"]}
    """
  end
end

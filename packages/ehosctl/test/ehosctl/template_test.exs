defmodule Ehosctl.TemplateTest do
  # Not async: the tests set an environment variable, which is the VM's.
  use ExUnit.Case, async: false

  alias Ehosctl.Template

  setup do
    on_exit(fn -> System.delete_env("EHOSCTL_TEMPLATE_SOURCE") end)
  end

  test "installs the pinned ehos_app by default, at a commit of ehos-tools, which cannot move" do
    System.delete_env("EHOSCTL_TEMPLATE_SOURCE")

    assert {:ok,
            {:ehos_app,
             [
               github: "EmpoweredHouse/ehos-tools",
               sparse: "packages/ehos_app",
               ref: ref
             ]}} =
             Template.install_dep()

    assert ref =~ ~r/\A[0-9a-f]{40}\z/
  end

  test "EHOSCTL_TEMPLATE_SOURCE=path: installs a local checkout" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "path:/abs/ehos_app")
    assert Template.install_dep() == {:ok, {:ehos_app, path: "/abs/ehos_app", override: true}}
  end

  test "EHOSCTL_TEMPLATE_SOURCE=ref: installs another ref of ehos-tools" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "ref:1a2b3c")
    assert {:ok, {:ehos_app, opts}} = Template.install_dep()
    assert opts[:ref] == "1a2b3c"
    refute opts[:tag]
  end

  test "EHOSCTL_TEMPLATE_SOURCE refuses a relative path, or anything else" do
    for source <- ["path:rel/ehos_app", "github:EmpoweredHouse/ehos_app@v0.2.0", "ref:"] do
      System.put_env("EHOSCTL_TEMPLATE_SOURCE", source)
      assert {:error, message} = Template.install_dep()
      assert message =~ "path:<absolute path"
    end
  end

  test "an empty EHOSCTL_TEMPLATE_SOURCE is taken as unset" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "")
    default = Template.install_dep()
    System.delete_env("EHOSCTL_TEMPLATE_SOURCE")
    assert default == Template.install_dep()
  end

  test "installs through Igniter, which composes the installers ehos_app declares" do
    dep = {:ehos_app, path: "/abs/ehos_app", override: true}
    code = Template.install_expression(dep)

    assert {:ok, _} = Code.string_to_quoted(code)

    assert code =~
             ~s|Igniter.Util.Install.install([{:ehos_app, [path: "/abs/ehos_app", override: true]}], ["--example", "--yes"])|

    assert code =~ "Application.ensure_all_started(:rewrite)"
  end

  # The repository root's `.tool-versions` is what the template is developed under. It is
  # a copy of the pins above, so this keeps the two from drifting apart.
  test "the repository's .tool-versions matches the pinned toolchain" do
    assert File.read!(Path.expand("../../../../.tool-versions", __DIR__))
           |> String.split("\n", trim: true)
           |> Enum.reject(&String.starts_with?(&1, "#")) == [
             "erlang #{Template.erlang()}",
             "elixir #{Template.elixir()}"
           ]
  end
end

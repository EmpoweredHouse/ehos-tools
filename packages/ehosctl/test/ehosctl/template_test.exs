defmodule Ehosctl.TemplateTest do
  # Not async: the tests set an environment variable, which is the VM's.
  use ExUnit.Case, async: false

  alias Ehosctl.Template

  setup do
    on_exit(fn -> System.delete_env("EHOSCTL_TEMPLATE_SOURCE") end)
  end

  test "installs the pinned ehos_app by default" do
    System.delete_env("EHOSCTL_TEMPLATE_SOURCE")
    assert Template.install_spec() =~ ~r/\Aehos_app@github:.+@v\d/
  end

  test "EHOSCTL_TEMPLATE_SOURCE replaces the pinned source" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "path:/abs/ehos_app")
    assert Template.install_spec() == "ehos_app@path:/abs/ehos_app"
  end

  test "an empty EHOSCTL_TEMPLATE_SOURCE is taken as unset" do
    System.put_env("EHOSCTL_TEMPLATE_SOURCE", "")
    default = Template.install_spec()
    System.delete_env("EHOSCTL_TEMPLATE_SOURCE")
    assert default == Template.install_spec()
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

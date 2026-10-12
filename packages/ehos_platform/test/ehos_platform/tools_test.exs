defmodule EhosPlatform.ToolsTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.Tools

  doctest Tools

  test "every program the package runs with a version that matters is pinned, once" do
    programs = Enum.map(Tools.all(), & &1.program)
    assert Enum.sort(programs) == ["helm", "kubectl", "tofu"]
    assert programs == Enum.uniq(programs)

    for tool <- Tools.all(), do: assert({:ok, _} = Version.parse(tool.version))
  end
end

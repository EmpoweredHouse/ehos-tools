defmodule Mix.Tasks.EhosApp.LinkSkillsTest do
  # The task works in the current directory, which is the VM's.
  use ExUnit.Case, async: false

  alias Mix.Tasks.EhosApp.LinkSkills

  setup do
    dir =
      Path.join(System.tmp_dir!(), "ehos_app_link_skills_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, ".agents/skills/plan"))
    File.write!(Path.join(dir, ".agents/skills/plan/SKILL.md"), "# Plan\n")
    File.mkdir_p!(Path.join(dir, ".agents/skills/ship"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp run_in(dir), do: File.cd!(dir, fn -> LinkSkills.run([]) end)

  test "links every skill relatively, so the link survives a move of the project", %{dir: dir} do
    run_in(dir)

    assert File.read_link!(Path.join(dir, ".claude/skills/plan")) == "../../.agents/skills/plan"
    assert File.read!(Path.join(dir, ".claude/skills/plan/SKILL.md")) == "# Plan\n"
    assert File.read_link!(Path.join(dir, ".claude/skills/ship")) == "../../.agents/skills/ship"
  end

  test "leaves an entry that exists alone, and a second run changes nothing", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".claude/skills/ship"))
    run_in(dir)

    assert File.dir?(Path.join(dir, ".claude/skills/ship"))
    refute match?({:ok, %{type: :symlink}}, File.lstat(Path.join(dir, ".claude/skills/ship")))
    assert File.cd!(dir, &LinkSkills.missing/0) == []

    run_in(dir)
    assert File.ls!(Path.join(dir, ".claude/skills")) |> Enum.sort() == ["plan", "ship"]
  end
end

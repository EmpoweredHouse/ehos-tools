defmodule Mix.Tasks.EhosApp.UnlinkSkillsTest do
  # The task works in the current directory, which is the VM's.
  use ExUnit.Case, async: false

  alias Mix.Tasks.EhosApp.UnlinkSkills

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # What 0.8.1 left once the installer removed its copies: the links, and empty directories.
    File.mkdir_p!(Path.join(dir, ".agents/skills/plan"))
    File.mkdir_p!(Path.join(dir, ".agents/skills/review/references"))
    File.mkdir_p!(Path.join(dir, ".claude/skills"))
    File.write!(Path.join(dir, ".claude/settings.json"), "{}\n")

    for name <- ["plan", "review"],
        do: File.ln_s!("../../.agents/skills/#{name}", Path.join(dir, ".claude/skills/#{name}"))

    %{dir: dir}
  end

  defp run_in(dir), do: File.cd!(dir, fn -> UnlinkSkills.run([]) end)

  test "removes the links to skills that are gone, and the directories left empty", %{dir: dir} do
    run_in(dir)

    refute File.exists?(Path.join(dir, ".agents"))
    refute File.exists?(Path.join(dir, ".claude/skills"))
    assert File.read!(Path.join(dir, ".claude/settings.json")) == "{}\n"
  end

  test "keeps a directory of the developer's own, even an empty one", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".agents/memory"))
    File.mkdir_p!(Path.join(dir, ".agents/skills/ours"))

    run_in(dir)

    assert File.dir?(Path.join(dir, ".agents/memory"))
    assert File.dir?(Path.join(dir, ".agents/skills/ours"))
    refute File.exists?(Path.join(dir, ".agents/skills/plan"))
    refute File.exists?(Path.join(dir, ".claude/skills"))
  end

  test "touches nothing when .agents is a link to another directory", %{dir: dir} do
    shared = Path.join(dir, "shared")
    File.rename!(Path.join(dir, ".agents"), shared)
    File.ln_s!("shared", Path.join(dir, ".agents"))

    run_in(dir)

    assert File.dir?(Path.join(shared, "skills/plan"))
    assert File.ls!(Path.join(dir, ".claude/skills")) |> Enum.sort() == ["plan", "review"]
  end

  test "keeps a skill still there, its link, and entries of the developer's own", %{dir: dir} do
    File.write!(Path.join(dir, ".agents/skills/plan/SKILL.md"), "# Ours\n")
    File.mkdir_p!(Path.join(dir, ".claude/skills/deploy"))
    File.write!(Path.join(dir, ".claude/skills/deploy/SKILL.md"), "# Deploy\n")
    File.ln_s!("../../elsewhere/gone", Path.join(dir, ".claude/skills/other"))

    run_in(dir)

    assert File.read!(Path.join(dir, ".claude/skills/plan/SKILL.md")) == "# Ours\n"
    refute File.exists?(Path.join(dir, ".agents/skills/review"))

    assert File.ls!(Path.join(dir, ".claude/skills")) |> Enum.sort() == [
             "deploy",
             "other",
             "plan"
           ]

    assert File.cd!(dir, &UnlinkSkills.dangling/0) == []
    run_in(dir)

    assert File.ls!(Path.join(dir, ".claude/skills")) |> Enum.sort() == [
             "deploy",
             "other",
             "plan"
           ]
  end
end

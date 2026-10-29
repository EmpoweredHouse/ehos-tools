defmodule Mix.Tasks.EhosApp.UnlinkSkillsTest do
  # The task works in the current directory, which is the VM's.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

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

  test "removes the links to skills that are gone, and the directories left empty", %{dir: dir} do
    assert run_in(dir) ==
             "* unlinking .claude/skills/plan\n* unlinking .claude/skills/review\n"

    assert tree(dir) == [".claude", ".claude/settings.json"]
    assert File.read!(Path.join(dir, ".claude/settings.json")) == "{}\n"
  end

  test "keeps a directory of the developer's own, even an empty one", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".agents/memory"))
    File.mkdir_p!(Path.join(dir, ".agents/skills/ours"))

    run_in(dir)

    assert tree(dir) == [
             ".agents",
             ".agents/memory",
             ".agents/skills",
             ".agents/skills/ours",
             ".claude",
             ".claude/settings.json"
           ]
  end

  test "touches nothing when .agents is a link to another directory", %{dir: dir} do
    shared = Path.join(dir, "shared")
    File.rename!(Path.join(dir, ".agents"), shared)
    File.ln_s!("shared", Path.join(dir, ".agents"))

    assert run_in(dir) == ""

    assert tree(dir) == [
             ".agents -> shared",
             ".claude",
             ".claude/settings.json",
             ".claude/skills",
             ".claude/skills/plan -> ../../.agents/skills/plan",
             ".claude/skills/review -> ../../.agents/skills/review",
             "shared",
             "shared/skills",
             "shared/skills/plan",
             "shared/skills/review",
             "shared/skills/review/references"
           ]
  end

  test "keeps a skill still there, its link, and entries of the developer's own", %{dir: dir} do
    File.write!(Path.join(dir, ".agents/skills/plan/SKILL.md"), "# Ours\n")
    File.mkdir_p!(Path.join(dir, ".claude/skills/deploy"))
    File.write!(Path.join(dir, ".claude/skills/deploy/SKILL.md"), "# Deploy\n")
    File.ln_s!("../../elsewhere/gone", Path.join(dir, ".claude/skills/other"))

    run_in(dir)

    left = [
      ".agents",
      ".agents/skills",
      ".agents/skills/plan",
      ".agents/skills/plan/SKILL.md",
      ".claude",
      ".claude/settings.json",
      ".claude/skills",
      ".claude/skills/deploy",
      ".claude/skills/deploy/SKILL.md",
      ".claude/skills/other -> ../../elsewhere/gone",
      ".claude/skills/plan -> ../../.agents/skills/plan"
    ]

    assert tree(dir) == left
    assert File.read!(Path.join(dir, ".claude/skills/plan/SKILL.md")) == "# Ours\n"

    assert File.cd!(dir, &UnlinkSkills.dangling/0) == []
    assert run_in(dir) == ""
    assert tree(dir) == left
  end

  defp run_in(dir), do: capture_io(fn -> File.cd!(dir, fn -> UnlinkSkills.run([]) end) end)

  # Every path under `dir`, from it, sorted: a link as what it points to, never followed.
  defp tree(dir), do: dir |> entries("") |> Enum.sort()

  defp entries(dir, prefix) do
    for name <- File.ls!(Path.join(dir, prefix)),
        relative = Path.join(prefix, name) |> String.trim_leading("/"),
        entry <- entry(dir, relative),
        do: entry
  end

  defp entry(dir, relative) do
    path = Path.join(dir, relative)

    case File.lstat!(path).type do
      :symlink -> ["#{relative} -> #{File.read_link!(path)}"]
      :directory -> [relative | entries(dir, relative)]
      _file -> [relative]
    end
  end
end

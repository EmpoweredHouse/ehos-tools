defmodule EhosApp.SkillInstallTest do
  use Mix.Tasks.EhosApp.InstallCase, async: true
  alias EhosApp.SkillInstall
  @manifest ".agents/ehos-skills.json"
  @path ".agents/skills/ehos-app-example/"

  test "installs files and provenance, and a second run changes nothing" do
    installed = test_project() |> SkillInstall.install(skills()) |> apply_igniter!()
    assert content(installed, @path <> "SKILL.md") == "first\n"
    assert content(installed, @path <> "references/rules.md") == "rules\n"

    assert JSON.decode!(content(installed, @manifest))["skills"]["ehos-app-example"]["source"] ==
             %{"ref" => "v1"}

    assert SkillInstall.install(installed, skills()) |> diff() == ""
  end

  test "updates an untouched older skill and removes retired references" do
    next = %{
      "ehos-app-example" => %{
        "source" => %{"ref" => "v2"},
        "files" => %{"SKILL.md" => "next", "new.md" => "new"}
      }
    }

    updated =
      test_project()
      |> SkillInstall.install(skills())
      |> apply_igniter!()
      |> SkillInstall.install(next)

    assert content(updated, @path <> "SKILL.md") == "next\n"
    assert content(updated, @path <> "new.md") == "new\n"
    assert updated.rms == [@path <> "references/rules.md"]
  end

  test "keeps the whole skill when a reference was edited" do
    updated =
      test_project()
      |> SkillInstall.install(skills())
      |> apply_igniter!()
      |> replace_file(@path <> "references/rules.md", "our rules")
      |> apply_igniter!()
      |> SkillInstall.install(skills("next"))

    assert content(updated, @path <> "SKILL.md") == "first\n"
    assert content(updated, @path <> "references/rules.md") == "our rules"
    assert length(updated.notices) == 1
  end

  test "does not restore a skill or reference the developer removed" do
    installed = test_project() |> SkillInstall.install(skills()) |> apply_igniter!()

    for path <- ["SKILL.md", "references/rules.md"] do
      updated =
        installed
        |> Igniter.rm(@path <> path)
        |> apply_igniter!()
        |> SkillInstall.install(skills("next"))

      refute Igniter.exists?(updated, @path <> path)
      assert content(updated, @manifest) == content(installed, @manifest)
    end
  end

  test "keeps an existing skill and never claims it after removal" do
    updated =
      test_project()
      |> with_file(@path <> "SKILL.md", "ours")
      |> SkillInstall.install(skills())
      |> apply_igniter!()

    assert content(updated, @path <> "SKILL.md") == "ours"
    refute Igniter.exists?(updated, @path <> "references/rules.md")

    updated =
      updated
      |> Igniter.rm(@path <> "SKILL.md")
      |> apply_igniter!()
      |> SkillInstall.install(skills())

    refute Igniter.exists?(updated, @path <> "SKILL.md")
  end

  test "preserves files when the manifest is invalid or names a path outside a skill" do
    bad =
      JSON.encode!(%{
        "version" => 1,
        "skills" => %{
          "ehos-app-example" => %{
            "source" => %{},
            "files" => %{"../../outside" => String.duplicate("a", 64)}
          }
        }
      })

    for manifest <- ["not json", bad] do
      updated = test_project() |> with_file(@manifest, manifest) |> SkillInstall.install(skills())
      assert content(updated, @manifest) == manifest
      refute Igniter.exists?(updated, @path <> "SKILL.md")
      assert length(updated.warnings) == 1
    end
  end

  defp skills(text \\ "first"),
    do: %{
      "ehos-app-example" => %{
        "source" => %{"ref" => "v1"},
        "files" => %{"SKILL.md" => text, "references/rules.md" => "rules"}
      }
    }
end

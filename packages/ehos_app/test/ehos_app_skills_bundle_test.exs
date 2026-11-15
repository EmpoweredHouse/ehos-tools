defmodule Mix.Tasks.EhosApp.Skills.BundleTest do
  use ExUnit.Case, async: true
  import Hammox
  alias Mix.Tasks.EhosApp.Skills.Bundle

  setup :verify_on_exit!

  @plugin %{
    name: "example",
    repo: "owner/repo",
    ref: "example-v1.0.0",
    version: "1.0.0",
    commit: "commit"
  }

  test "reads every file from the configured commit and records its original hash" do
    mock_manifest("1.0.0")
    mock_tree("plugins/example/skills/plan/SKILL.md\n")

    expect(EhosApp.SkillGitMock, :run, fn ["show", "commit:plugins/example/skills/plan/SKILL.md"],
                                          "checkout" ->
      {:ok, "original"}
    end)

    assert Bundle.bundle(@plugin, "checkout", git: EhosApp.SkillGitMock) ==
             {%{"plan/SKILL.md" => "original"},
              %{
                "name" => "example",
                "repo" => "owner/repo",
                "ref" => "example-v1.0.0",
                "commit" => "commit",
                "files" => %{
                  "plan/SKILL.md" =>
                    Base.encode16(:crypto.hash(:sha256, "original"), case: :lower)
                }
              }}
  end

  test "refuses a failed Git read without printing its output" do
    expect(EhosApp.SkillGitMock, :run, fn [
                                            "show",
                                            "commit:plugins/example/.claude-plugin/plugin.json"
                                          ],
                                          "checkout" ->
      {:error, :command_failed}
    end)

    assert_raise Mix.Error, "Cannot read the pinned plugin commit from the source checkout", fn ->
      Bundle.bundle(@plugin, "checkout", git: EhosApp.SkillGitMock)
    end
  end

  test "refuses a different plugin version" do
    mock_manifest("0.9.0")

    assert_raise Mix.Error, "Pinned commit does not contain the configured plugin version", fn ->
      Bundle.bundle(@plugin, "checkout", git: EhosApp.SkillGitMock)
    end
  end

  test "refuses an empty skill tree" do
    mock_manifest("1.0.0")
    mock_tree("")

    assert_raise Mix.Error, "Pinned commit contains no skills", fn ->
      Bundle.bundle(@plugin, "checkout", git: EhosApp.SkillGitMock)
    end
  end

  defp mock_manifest(version) do
    expect(EhosApp.SkillGitMock, :run, fn [
                                            "show",
                                            "commit:plugins/example/.claude-plugin/plugin.json"
                                          ],
                                          "checkout" ->
      {:ok, JSON.encode!(%{"name" => "example", "version" => version})}
    end)
  end

  defp mock_tree(tree) do
    expect(EhosApp.SkillGitMock, :run, fn [
                                            "ls-tree",
                                            "-r",
                                            "--name-only",
                                            "commit",
                                            "--",
                                            "plugins/example/skills/"
                                          ],
                                          "checkout" ->
      {:ok, tree}
    end)
  end
end

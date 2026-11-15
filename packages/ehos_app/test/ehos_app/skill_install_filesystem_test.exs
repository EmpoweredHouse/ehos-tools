defmodule EhosApp.SkillInstallFilesystemTest do
  # File.cd!/2 changes the VM's working directory; these tests run after the async cases.
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "hashes the bytes Rewrite writes, including a file without its final newline", %{
    tmp_dir: dir
  } do
    File.cd!(dir, fn ->
      first = EhosApp.SkillInstall.install(Igniter.new(), skills())
      assert {:ok, _rewrite} = Rewrite.write_all(first.rewrite)
      assert File.read!(".agents/skills/example/SKILL.md") == "new\n"
      again = EhosApp.SkillInstall.install(Igniter.new(), skills())
      assert again.notices == []
      assert Igniter.changed?(again) == false
    end)
  end

  @tag :tmp_dir
  test "does not follow a linked agents directory", %{tmp_dir: dir} do
    outside = Path.join(dir, "outside")
    project = Path.join(dir, "project")
    File.mkdir_p!(outside)
    File.mkdir_p!(project)
    File.ln_s!(outside, Path.join(project, ".agents"))

    File.cd!(project, fn ->
      result = EhosApp.SkillInstall.install(Igniter.new(), skills())
      assert Enum.empty?(result.rewrite)
      assert length(result.warnings) == 1
    end)

    assert File.ls!(outside) == []
  end

  @tag :tmp_dir
  test "preserves a skill whose file links outside the project", %{tmp_dir: dir} do
    outside = Path.join(dir, "outside.md")
    File.write!(outside, "ours")
    File.mkdir_p!(Path.join(dir, ".agents/skills/example"))
    File.ln_s!(outside, Path.join(dir, ".agents/skills/example/SKILL.md"))

    File.cd!(dir, fn ->
      result = EhosApp.SkillInstall.install(Igniter.new(), skills())
      assert Rewrite.has_source?(result.rewrite, ".agents/skills/example/SKILL.md") == false
      assert length(result.notices) == 1
    end)

    assert File.read!(outside) == "ours"
  end

  defp skills, do: %{"example" => %{"source" => %{}, "files" => %{"SKILL.md" => "new"}}}
end

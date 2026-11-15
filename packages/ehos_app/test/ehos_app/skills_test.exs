defmodule EhosApp.SkillsTest do
  use ExUnit.Case, async: true
  alias EhosApp.Skills
  alias Mix.Tasks.EhosApp.Install

  test "ships the configured plugin versions and unchanged upstream files" do
    for source <- Skills.sources() do
      plugin = Enum.find(Install.plugins(), &(&1.name == source["name"]))

      assert Map.take(source, ["name", "repo", "ref"]) == %{
               "name" => plugin.name,
               "repo" => plugin.repo,
               "ref" => plugin.ref
             }

      if plugin[:commit], do: assert(source["commit"] == plugin.commit)

      for {path, hash} <- source["files"] do
        text = File.read!(Application.app_dir(:ehos_app, "priv/skills/#{source["name"]}/#{path}"))
        assert Base.encode16(:crypto.hash(:sha256, text), case: :lower) == hash
      end
    end
  end

  test "namespaces skills and sibling references while retaining nested files and provenance" do
    skills = Skills.bundled()
    assert Enum.sort(Map.keys(skills)) == Enum.sort(~w(
      eh-os-contract-add-event eh-os-contract-change-contract eh-os-contract-contract-distillation
      eh-os-contract-module-boundary-check eh-os-contract-write-decider eh-os-contract-write-reaction
      ehos-app-elixir ehos-app-elixir-anti-patterns-review ehos-app-plan ehos-app-pre-pr-review
      ehos-app-pull-request ehos-app-retro ehos-app-review ehos-app-sample-data ehos-app-ship
    ))

    for {name, skill} <- skills do
      assert skill["files"]["SKILL.md"] =~ "name: #{name}\n"

      assert skill["files"]["SKILL.md"] =~
               "Otherwise read this exact `SKILL.md` with a filesystem tool."

      assert skill["files"]["SKILL.md"] =~ skill["source"]["commit"]

      for {_path, text} <- skill["files"] do
        assert text == String.trim_trailing(text) <> "\n"
        refute text =~ "ehos-app:"
        refute text =~ "eh-os-contract:"
      end
    end

    assert skills["ehos-app-pre-pr-review"]["files"]["SKILL.md"] =~
             "../ehos-app-review/references/lenses.md"

    assert Map.has_key?(skills["ehos-app-elixir"]["files"], "references/testing.md")
    assert Map.has_key?(skills["ehos-app-elixir-anti-patterns-review"]["files"], "LICENSE")

    assert Map.has_key?(
             skills["eh-os-contract-contract-distillation"]["files"],
             "output-template.md"
           )

    for name <- ["ehos-app-review", "ehos-app-ship"] do
      assert skills[name]["files"]["agents/openai.yaml"] ==
               "policy:\n  allow_implicit_invocation: false\n"
    end

    for {name, skill} <- skills do
      [_, frontmatter, _body] = String.split(skill["files"]["SKILL.md"], "---", parts: 3)
      parsed = YamlElixir.read_from_string!(frontmatter)
      assert parsed["name"] == name
      assert String.length(parsed["description"]) <= 1024
      refute parsed["description"] =~ ~r/[<>]/

      assert Map.keys(parsed) -- ["name", "description", "license", "allowed-tools", "metadata"] ==
               []
    end
  end
end

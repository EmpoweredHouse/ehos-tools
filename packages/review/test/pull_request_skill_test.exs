defmodule PullRequestSkillTest do
  # Every EHOS repository and every application ehos_app generates writes its pull requests from
  # one template (ehos-tools#763). The pull-request skills of the two plugins carry a copy each,
  # since each plugin is installed alone, and ehos-tools and ehos_app write that template into
  # `.github/pull_request_template.md`. This package holds the review gate, and keeps them one.
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  @template "skills/pull-request/references/pull_request_template.md"

  test "both plugins' pull-request skills follow the same description" do
    [ehos_dev, ehos_app] = plugin_copies("skills/pull-request/references/description.md")

    assert ehos_app == ehos_dev,
           "edit one copy of the description and copy it over the other: " <>
             Enum.join(plugin_paths("skills/pull-request/references/description.md"), ", ")
  end

  test "both plugins' pull-request skills hold the same template" do
    [ehos_dev, ehos_app] = plugin_copies(@template)

    assert ehos_app == ehos_dev,
           "edit one copy of the template and copy it over the other: " <>
             Enum.join(plugin_paths(@template), ", ")
  end

  test "ehos-tools and ehos_app write the skill's template" do
    [template, _] = plugin_copies(@template)

    for path <- [
          ".github/pull_request_template.md",
          "packages/ehos_app/priv/templates/ehos_app.install/pull_request_template.md.eex"
        ] do
      assert File.read!(Path.join(@root, path)) == template,
             "#{path} differs from #{hd(plugin_paths(@template))}: copy the skill's template over it"
    end
  end

  defp plugin_copies(path), do: Enum.map(plugin_paths(path), &File.read!/1)

  defp plugin_paths(path),
    do: Enum.map(["ehos-dev", "ehos-app"], &Path.join([@root, "plugins", &1, path]))
end

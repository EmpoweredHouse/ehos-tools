defmodule EhosRelease.PinCheckTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosRelease.{GitHubMock, GitMock, Pin, PinCheck}

  setup :verify_on_exit!

  @tools "EmpoweredHouse/ehos-tools"
  @tagged String.duplicate("a", 40)
  @untagged String.duplicate("b", 40)

  @tags %{
    "ehos_platform-v0.21.0" => @tagged,
    "ehos_release-v0.1.0" => @tagged,
    "ehos_platform-v0.22.0-rc" => @untagged,
    "ehos-dev-v0.14.0" => @tagged
  }

  describe "tagged/2" do
    test "passes a pin a protected tag of its prefix names, by commit or by tag" do
      mock_tags(@tools, @tags)
      mock_rulesets(@tools, [protecting(["ehos_platform-v", "ehos-dev-v"])])

      assert PinCheck.tagged(
               [
                 pin("packages/ehos_platform", @tagged),
                 pin(".claude-plugin/marketplace.json", "ehos-dev-v0.14.0")
               ],
               mocks()
             ) == []
    end

    test "refuses a commit no tag of its prefix names, though another prefix's or a non-release " <>
           "tag does" do
      mock_tags(@tools, @tags)
      mock_rulesets(@tools, [protecting(["ehos_platform-v", "ehos_design-v"])])

      assert PinCheck.tagged(
               [pin("packages/ehos_design", @tagged), pin("packages/ehos_platform", @untagged)],
               mocks()
             ) == [
               "mix.lock: dep pins #{@tools} packages/ehos_design at #{@tagged}, " <>
                 "which no protected tag ehos_design-vX.Y.Z names",
               "mix.lock: dep pins #{@tools} packages/ehos_platform at #{@untagged}, " <>
                 "which no protected tag ehos_platform-vX.Y.Z names"
             ]
    end

    test "refuses a tag whose prefix no ruleset protects from being moved or deleted" do
      mock_tags(@tools, @tags)

      mock_rulesets(@tools, [
        # Creation alone, as "Only admins create release tags" refuses.
        %{protecting(["ehos_release-v"]) | "rules" => [%{"type" => "creation"}]},
        %{protecting(["ehos_release-v"]) | "enforcement" => "evaluate"},
        %{protecting(["ehos_release-v"]) | "bypass_actors" => [%{"actor_id" => 5}]},
        put_in(protecting(["ehos_release-v"]), ["conditions", "ref_name", "exclude"], [
          "refs/tags/ehos_release-v0.*"
        ]),
        put_in(protecting(["ehos_release-v"]), ["conditions", "ref_name", "exclude"], [
          "refs/tags/ehos_release-v?.1.0"
        ]),
        put_in(protecting(["ehos_release-v"]), ["conditions", "ref_name", "exclude"], ["~ALL"])
      ])

      assert PinCheck.tagged([pin(".github/workflows/ehos-release.yml", @tagged)], mocks()) == [
               "mix.lock: dep pins #{@tools} .github/workflows/ehos-release.yml at #{@tagged}, " <>
                 "which no protected tag ehos_release-vX.Y.Z names"
             ]
    end

    test "refuses a pin of a path its producer releases nothing from" do
      mock_tags(@tools, @tags)
      mock_rulesets(@tools, [protecting(["ehos_platform-v"])])

      assert PinCheck.tagged([pin("packages/review", @tagged)], mocks()) == [
               "mix.lock: dep pins #{@tools} packages/review at #{@tagged}: " <>
                 ~s(#{@tools} releases nothing from "packages/review")
             ]
    end

    test "refuses every pin of a producer whose rulesets cannot be read, reading them once" do
      mock_tags(@tools, @tags)
      expect(GitHubMock, :rulesets, fn @tools -> {:error, "GitHub's rulesets answered 403"} end)

      assert PinCheck.tagged(
               [pin("packages/ehos_platform", @tagged), pin("packages/ehos_tunnel", @tagged)],
               mocks()
             ) == [
               "mix.lock: dep pins #{@tools} packages/ehos_platform at #{@tagged}: " <>
                 "GitHub's rulesets answered 403",
               "mix.lock: dep pins #{@tools} packages/ehos_tunnel at #{@tagged}: " <>
                 "GitHub's rulesets answered 403"
             ]
    end
  end

  describe "on_main/2" do
    test "passes a commit main contains, tagged or not" do
      expect(GitHubMock, :compare, fn @tools, "main", @untagged -> {:ok, "behind"} end)
      expect(GitHubMock, :compare, fn @tools, "main", @tagged -> {:ok, "identical"} end)

      assert PinCheck.on_main(
               [pin("packages/ehos_platform", @untagged), pin("packages/ehos_app", @tagged)],
               mocks()
             ) == []
    end

    test "refuses a commit main does not contain, as a fork's or a branch's" do
      expect(GitHubMock, :compare, fn @tools, "main", @untagged -> {:ok, "diverged"} end)
      expect(GitHubMock, :compare, fn @tools, "main", @tagged -> {:ok, "ahead"} end)

      assert PinCheck.on_main(
               [pin("packages/ehos_platform", @untagged), pin("packages/ehos_app", @tagged)],
               mocks()
             ) == [
               "mix.lock: dep pins #{@tools} packages/ehos_platform at #{@untagged}, " <>
                 "which is diverged of its main, not on it",
               "mix.lock: dep pins #{@tools} packages/ehos_app at #{@tagged}, " <>
                 "which is ahead of its main, not on it"
             ]
    end

    test "reads a tag's commit before comparing it, and refuses a tag that does not exist" do
      mock_tags(@tools, @tags)
      expect(GitHubMock, :compare, fn @tools, "main", @tagged -> {:ok, "behind"} end)

      assert PinCheck.on_main(
               [
                 pin(".claude-plugin/marketplace.json", "ehos-dev-v0.14.0"),
                 pin(".claude-plugin/marketplace.json", "main")
               ],
               mocks()
             ) == [
               "mix.lock: dep pins #{@tools} .claude-plugin/marketplace.json at main: " <>
                 "no tag main exists"
             ]
    end

    test "refuses a pin GitHub cannot compare" do
      expect(GitHubMock, :compare, fn @tools, "main", @tagged ->
        {:error, "GitHub's compare of #{@tools} answered 404"}
      end)

      assert PinCheck.on_main([pin("packages/ehos_app", @tagged)], mocks()) == [
               "mix.lock: dep pins #{@tools} packages/ehos_app at #{@tagged}: " <>
                 "GitHub's compare of #{@tools} answered 404"
             ]
    end
  end

  defp pin(path, ref),
    do: %Pin{file: "mix.lock", name: "dep", repository: @tools, path: path, ref: ref}

  defp mocks, do: [git: GitMock, github: GitHubMock]

  defp protecting(prefixes) do
    %{
      "name" => "Release tags stay what they were",
      "target" => "tag",
      "enforcement" => "active",
      "bypass_actors" => [],
      "rules" => [%{"type" => "update"}, %{"type" => "deletion"}],
      "conditions" => %{
        "ref_name" => %{"include" => Enum.map(prefixes, &"refs/tags/#{&1}*"), "exclude" => []}
      }
    }
  end

  defp mock_tags(repository, tags), do: expect(GitMock, :tags, fn ^repository -> {:ok, tags} end)

  defp mock_rulesets(repository, rulesets),
    do: expect(GitHubMock, :rulesets, fn ^repository -> {:ok, rulesets} end)
end

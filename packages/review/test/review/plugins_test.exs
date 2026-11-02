defmodule Review.PluginsTest do
  use ExUnit.Case, async: true

  import Hammox

  setup :verify_on_exit!

  @skill "plugins/ehos-app/skills/elixir/SKILL.md"
  @manifest "plugins/ehos-app/.claude-plugin/plugin.json"
  @dev_skill "plugins/ehos-dev/skills/release/SKILL.md"
  @dev_manifest "plugins/ehos-dev/.claude-plugin/plugin.json"
  @tags ["ehos-app-v0.6.0", "ehos-dev-v0.10.0", "ehos_app-v0.26.0"]

  describe "check/4" do
    test "a change to a plugin that raises its version passes" do
      mock_first_parents("base", "merge", ["merge"])
      mock_tags(@tags)
      mock_changed_files("merge", [@skill, @manifest])
      mock_file(%{{"merge", @manifest} => manifest("0.7.0")})

      assert check("base", "merge") == :ok
    end

    test "the commit a plugin's tag names passes, as when the check runs again after the tag" do
      mock_first_parents("base", "merge", ["merge"])
      mock_tags(@tags)
      mock_changed_files("merge", [@skill])
      mock_file(%{{"merge", @manifest} => manifest("0.6.0")})

      mock_object(%{
        {"merge", "plugins/ehos-app"} => "tree-a",
        {"refs/tags/ehos-app-v0.6.0", "plugins/ehos-app"} => "tree-a"
      })

      assert check("base", "merge") == :ok
    end

    test "a change to a plugin whose version is already tagged fails, naming the tag" do
      mock_first_parents("base", "merge", ["merge"])
      mock_tags(@tags)
      mock_changed_files("merge", [@skill, "packages/ehos_app/lib/mix/tasks/ehos_app.install.ex"])
      mock_file(%{{"merge", @manifest} => manifest("0.6.0")})

      mock_object(%{
        {"merge", "plugins/ehos-app"} => "tree-b",
        {"refs/tags/ehos-app-v0.6.0", "plugins/ehos-app"} => "tree-a"
      })

      assert check("base", "merge") == {:error, [message("ehos-app", "0.6.0")]}
    end

    test "each plugin a commit changes is judged, and each commit of a push alone" do
      mock_first_parents("before", "second", ["first", "second"])
      mock_tags(@tags)
      mock_changed_files("first", [@skill, @manifest, @dev_skill])
      mock_changed_files("second", [@dev_skill, "plugins/README.md"])

      mock_file(%{
        {"first", @manifest} => manifest("0.7.0"),
        {"first", @dev_manifest} => manifest("0.10.0"),
        {"second", @dev_manifest} => manifest("0.10.0")
      })

      mock_object(%{
        {"first", "plugins/ehos-dev"} => "tree-b",
        {"second", "plugins/ehos-dev"} => "tree-c",
        {"refs/tags/ehos-dev-v0.10.0", "plugins/ehos-dev"} => "tree-a"
      })

      assert check("before", "second") ==
               {:error,
                [
                  message("ehos-dev", "0.10.0", "first"),
                  message("ehos-dev", "0.10.0", "second")
                ]}
    end

    test "a change outside the plugins, or one that removes a plugin, passes" do
      mock_first_parents("base", "merge", ["merge"])
      mock_tags(@tags)
      mock_changed_files("merge", ["packages/review/lib/review.ex", @skill, @manifest])
      mock_file(%{})

      assert check("base", "merge") == :ok
    end

    test "a manifest that names no version passes, since Claude Code caches the plugin by commit" do
      mock_first_parents("base", "merge", ["merge"])
      mock_tags(@tags)
      mock_changed_files("merge", [@skill])
      mock_file(%{{"merge", @manifest} => ~s({"name": "ehos-app"})})

      assert check("base", "merge") == :ok
    end

    test "a manifest Claude Code cannot read fails, naming what is wrong with it" do
      mock_first_parents("base", "merge", ["merge"])
      mock_tags(@tags)
      mock_changed_files("merge", [@skill, @dev_skill])

      mock_file(%{
        {"merge", @manifest} => ~s({"name": "ehos-app", "version": "0.7.0",}),
        {"merge", @dev_manifest} => ~s({"name": "ehos-dev", "version": 0.11})
      })

      assert check("base", "merge") ==
               {:error,
                [
                  "#{@manifest}, in merge: it is not a JSON object, so Claude Code cannot load " <>
                    "the plugin",
                  "#{@dev_manifest}, in merge: its `version` is not a string"
                ]}
    end

    test "raises when the repository has no tags, rather than passing every change" do
      mock_first_parents("base", "merge", ["merge"])
      mock_tags([])

      assert_raise RuntimeError,
                   "no tag in the repository: fetch the tags, or every plugin's version reads " <>
                     "as new",
                   fn -> check("base", "merge") end
    end
  end

  describe "mix review.plugins" do
    test "says how to use it" do
      assert_raise Mix.Error, "Usage: mix review.plugins <from> <to>", fn ->
        Mix.Tasks.Review.Plugins.run([])
      end
    end
  end

  defp check(from, to), do: Review.Plugins.check("repo", from, to, git: Review.GitMock)

  defp manifest(version), do: ~s({\n  "name": "a-plugin",\n  "version": "#{version}"\n}\n)

  defp message(plugin, version, commit \\ "merge"),
    do:
      "plugins/#{plugin}, in #{commit}: changes the plugin, but its version #{version} is the " <>
        "one #{plugin}-v#{version} released, and Claude Code keeps the copy of a version it " <>
        "has, so the change reaches nobody. Raise `version` in " <>
        "plugins/#{plugin}/.claude-plugin/plugin.json in the pull request that changes the " <>
        "plugin (CONTRIBUTING.md, \"Versions and releases\")."

  defp mock_first_parents(from, to, commits),
    do: expect(Review.GitMock, :first_parents, fn "repo", ^from, ^to -> commits end)

  defp mock_tags(tags), do: expect(Review.GitMock, :tags, fn "repo" -> tags end)

  defp mock_changed_files(commit, files),
    do: expect(Review.GitMock, :changed_files, fn "repo", ^commit -> files end)

  # Every file a commit holds that the test does not name is missing from it.
  defp mock_file(files),
    do: stub(Review.GitMock, :file, fn "repo", commit, path -> Map.get(files, {commit, path}) end)

  defp mock_object(objects),
    do: stub(Review.GitMock, :object, fn "repo", rev, path -> Map.get(objects, {rev, path}) end)
end

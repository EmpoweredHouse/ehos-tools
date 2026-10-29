defmodule Review.ChangelogTest do
  use ExUnit.Case, async: true

  import Hammox

  doctest Review.Changelog

  setup :verify_on_exit!

  @platform "packages/ehos_platform/CHANGELOG.md"
  @platform_mix "packages/ehos_platform/mix.exs"

  @released """
  ## [0.12.0] - 2026-10-29

  ### Added

  - Priority classes for cert-manager.

  ## [0.11.0] - 2026-10-28

  ### Fixed

  - A refusal names its code.
  """

  describe "released_sections/3" do
    test "a change to the Unreleased section alone passes" do
      assert Review.Changelog.released_sections(
               changelog("- Requests.\n"),
               changelog("- Requests, 70m and 336Mi.\n"),
               nil
             ) == :ok
    end

    test "a release moves Unreleased under the version mix.exs sets" do
      assert Review.Changelog.released_sections(
               changelog("### Added\n\n- Requests.\n"),
               "# Changelog\n\n## [Unreleased]\n\n## [0.13.0] - 2026-10-30\n\n### Added\n\n" <>
                 "- Requests.\n\n" <> @released,
               "0.13.0"
             ) == :ok
    end

    test "a package's first release adds its first section" do
      assert Review.Changelog.released_sections(
               "# Changelog\n\n## [Unreleased]\n\n- First.\n",
               "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-10-03\n\n- First.\n",
               "0.1.0"
             ) == :ok
    end

    test "an edit carried into a section a release made fails, naming its line and section" do
      assert Review.Changelog.released_sections(
               changelog(""),
               String.replace(changelog(""), "cert-manager.", "cert-manager, and requests."),
               nil
             ) ==
               {:error,
                "line 10, under `## [0.12.0] - 2026-10-29`, changes a released version's notes"}
    end

    test "a release that also edits an older version's section fails" do
      released = String.replace(@released, "names its code", "names its code and its fix")

      assert Review.Changelog.released_sections(
               changelog("- Requests.\n"),
               "## [Unreleased]\n\n## [0.13.0] - 2026-10-30\n\n- Requests.\n\n" <> released,
               "0.13.0"
             ) ==
               {:error,
                "line 17, under `## [0.11.0] - 2026-10-28`, changes a released version's notes"}
    end

    test "a section for a version mix.exs does not set fails" do
      assert Review.Changelog.released_sections(
               changelog("- Requests.\n"),
               "## [Unreleased]\n\n## [0.13.0] - 2026-10-30\n\n- Requests.\n\n" <> @released,
               nil
             ) ==
               {:error,
                "line 3, under `## [0.13.0] - 2026-10-30`, changes a released version's notes"}
    end

    test "removing a released section fails" do
      assert Review.Changelog.released_sections(
               changelog(""),
               String.replace(changelog(""), ~r/\n## \[0\.11\.0\].*/s, ""),
               nil
             ) ==
               {:error, "it removes released lines, the first under `## [0.11.0] - 2026-10-28`"}
    end
  end

  describe "check/4" do
    test "a release's own merge commit passes" do
      mock_first_parents(["merge"])
      mock_changed_files("merge", [@platform, @platform_mix])

      mock_files(%{
        {"merge^1", @platform_mix} => mix("0.13.0-dev"),
        {"merge", @platform_mix} => mix("0.13.0"),
        {"merge^1", @platform} => changelog("- Requests.\n"),
        {"merge", @platform} => release("0.13.0")
      })

      assert check("base", "merge") == :ok
    end

    test "a push holding a release and the move to the next -dev passes, each judged alone" do
      mock_first_parents(["release", "dev"])
      mock_changed_files("release", [@platform, @platform_mix])
      mock_changed_files("dev", [@platform_mix])

      mock_files(%{
        {"release^1", @platform_mix} => mix("0.13.0-dev"),
        {"release", @platform_mix} => mix("0.13.0"),
        {"release^1", @platform} => changelog("- Requests.\n"),
        {"release", @platform} => release("0.13.0"),
        {"dev^1", @platform_mix} => mix("0.13.0"),
        {"dev", @platform_mix} => mix("0.14.0-dev")
      })

      assert check("before", "dev") == :ok
    end

    test "a merge that edits released sections fails, once for each changelog" do
      mock_first_parents(["merge"])

      mock_changed_files("merge", [
        @platform,
        "packages/other/CHANGELOG.md",
        "packages/review/CHANGELOG.md",
        "docs/CHANGELOG.md"
      ])

      mock_files(%{
        {"merge^1", @platform} => changelog("- Requests.\n"),
        {"merge", @platform} => changelog("- Requests.\n") <> "- Requests, carried over.\n",
        {"merge", "packages/other/CHANGELOG.md"} => "## [0.1.0] - 2026-10-01\n",
        {"merge^1", "packages/review/CHANGELOG.md"} => "## [Unreleased]\n",
        {"merge", "packages/review/CHANGELOG.md"} => "## [Unreleased]\n\n- The check.\n"
      })

      assert check("base", "merge") ==
               {:error,
                [
                  message(
                    @platform,
                    "ehos_platform",
                    "line 18, under `## [0.11.0] - 2026-10-28`, changes a released " <>
                      "version's notes"
                  ),
                  message(
                    "packages/other/CHANGELOG.md",
                    "other",
                    "line 1, under `## [0.1.0] - 2026-10-01`, changes a released version's notes"
                  )
                ]}
    end

    test "a section for a version lower than mix.exs had is not a release" do
      mock_first_parents(["merge"])
      mock_changed_files("merge", [@platform, @platform_mix])

      mock_files(%{
        {"merge^1", @platform_mix} => mix("0.12.1"),
        {"merge", @platform_mix} => mix("0.12.0"),
        {"merge^1", @platform} => changelog(""),
        {"merge", @platform} => release("0.12.0")
      })

      assert check("base", "merge") ==
               {:error,
                [
                  message(
                    @platform,
                    "ehos_platform",
                    "line 5, under `## [0.12.0] - 2026-10-30`, changes a released version's notes"
                  )
                ]}
    end

    test "a -dev version in mix.exs is not a release" do
      mock_first_parents(["merge"])
      mock_changed_files("merge", [@platform, @platform_mix])

      mock_files(%{
        {"merge^1", @platform_mix} => mix("0.12.1"),
        {"merge", @platform_mix} => mix("0.13.0-dev"),
        {"merge^1", @platform} => changelog(""),
        {"merge", @platform} => release("0.13.0-dev")
      })

      assert check("base", "merge") ==
               {:error,
                [
                  message(
                    @platform,
                    "ehos_platform",
                    "line 5, under `## [0.13.0-dev] - 2026-10-30`, changes a released " <>
                      "version's notes"
                  )
                ]}
    end

    test "a changelog a commit removes fails" do
      mock_first_parents(["merge"])
      mock_changed_files("merge", [@platform])
      mock_files(%{{"merge^1", @platform} => changelog("")})

      assert check("base", "merge") ==
               {:error,
                [
                  message(
                    @platform,
                    "ehos_platform",
                    "it removes released lines, the first under `## [0.12.0] - 2026-10-29`"
                  )
                ]}
    end
  end

  describe "mix review.changelog" do
    test "says how to use it" do
      assert_raise Mix.Error, "Usage: mix review.changelog <from> <to>", fn ->
        Mix.Tasks.Review.Changelog.run([])
      end
    end
  end

  defp check(from, to), do: Review.Changelog.check("repo", from, to, git: Review.GitMock)

  defp changelog(unreleased),
    do: "# Changelog\n\n## [Unreleased]\n\n" <> unreleased <> "\n" <> @released

  defp release(version),
    do:
      "# Changelog\n\n## [Unreleased]\n\n## [#{version}] - 2026-10-30\n\n- Requests.\n\n" <>
        @released

  defp mix(version), do: ~s(  @version "#{version}"\n)

  defp message(path, package, problem),
    do:
      "#{path}: #{problem}. A pull request's line goes under `## [Unreleased]`, and only " <>
        "#{package}'s release turns that section into a version's. When #{package} was " <>
        "released while this pull request was open, merge `main` into it, put the released " <>
        "section back as it was released, and write the change under `## [Unreleased]`."

  defp mock_first_parents(commits),
    do: expect(Review.GitMock, :first_parents, fn "repo", _from, _to -> commits end)

  defp mock_changed_files(commit, files),
    do: expect(Review.GitMock, :changed_files, fn "repo", ^commit -> files end)

  # Every file a commit holds that the test does not name is missing from it.
  defp mock_files(files),
    do: stub(Review.GitMock, :file, fn "repo", commit, path -> Map.get(files, {commit, path}) end)
end

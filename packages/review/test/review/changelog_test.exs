defmodule Review.ChangelogTest do
  use ExUnit.Case, async: true

  doctest Review.Changelog

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

  describe "check/3" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      git!(repo, ["init", "--quiet", "--initial-branch=main"])
      write!(repo, "packages/ehos_platform/mix.exs", ~s(  @version "0.12.0-dev"\n))
      write!(repo, "packages/ehos_platform/CHANGELOG.md", changelog("- Priority classes.\n"))
      write!(repo, "packages/review/CHANGELOG.md", "## [Unreleased]\n")
      %{repo: repo, base: commit!(repo, "base")}
    end

    test "a release's own change passes", %{repo: repo, base: base} do
      write!(repo, "packages/ehos_platform/mix.exs", ~s(  @version "0.12.1"\n))

      write!(
        repo,
        "packages/ehos_platform/CHANGELOG.md",
        "## [Unreleased]\n\n## [0.12.1] - 2026-10-30\n\n- Priority classes.\n\n" <> @released
      )

      assert Review.Changelog.check(repo, base, commit!(repo, "release")) == :ok
    end

    test "an edit to a released section fails for each changelog that has one", %{
      repo: repo,
      base: base
    } do
      write!(
        repo,
        "packages/ehos_platform/CHANGELOG.md",
        changelog("- Priority classes.\n") <> "-\n"
      )

      write!(repo, "packages/review/CHANGELOG.md", "## [Unreleased]\n\n- The changelog check.\n")
      write!(repo, "packages/other/CHANGELOG.md", "## [0.1.0] - 2026-10-01\n")

      assert {:error, [platform, other]} =
               Review.Changelog.check(repo, base, commit!(repo, "edit"))

      assert other =~
               "packages/other/CHANGELOG.md: line 1, under `## [0.1.0] - 2026-10-01`, changes " <>
                 "a released version's notes. A pull request's line goes under " <>
                 "`## [Unreleased]`, and only other's release"

      assert platform =~ "packages/ehos_platform/CHANGELOG.md: line 18, under `## [0.11.0]"
    end

    test "a -dev version in mix.exs is not a release", %{repo: repo, base: base} do
      write!(repo, "packages/ehos_platform/mix.exs", ~s(  @version "0.13.0-dev"\n))

      write!(
        repo,
        "packages/ehos_platform/CHANGELOG.md",
        "## [Unreleased]\n\n## [0.13.0-dev] - 2026-10-30\n\n- Priority classes.\n\n" <> @released
      )

      assert {:error, [message]} = Review.Changelog.check(repo, base, commit!(repo, "dev"))
      assert message =~ "line 3, under `## [0.13.0-dev] - 2026-10-30`"
    end

    test "a commit git cannot read raises", %{repo: repo, base: base} do
      assert_raise RuntimeError, ~r/\Agit diff --name-only #{base} nothing -- exited with/, fn ->
        Review.Changelog.check(repo, base, "nothing")
      end
    end
  end

  test "mix review.changelog says how to use it" do
    assert_raise Mix.Error, "Usage: mix review.changelog <from> <to>", fn ->
      Mix.Tasks.Review.Changelog.run([])
    end
  end

  defp changelog(unreleased),
    do: "# Changelog\n\n## [Unreleased]\n\n" <> unreleased <> "\n" <> @released

  defp write!(repo, path, content) do
    path = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp commit!(repo, message) do
    git!(repo, ["add", "--all"])

    # With no global configuration (test_helper.exs), the commit's author is given here.
    git!(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      "--quiet",
      "-m",
      message
    ])

    git!(repo, ["rev-parse", "HEAD"])
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(output)
  end
end

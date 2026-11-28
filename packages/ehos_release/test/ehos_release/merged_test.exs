defmodule EhosRelease.MergedTest do
  use ExUnit.Case, async: true

  import Hammox
  import EhosRelease.ReleaseRepo

  alias EhosRelease.{GitHubMock, GitMock, Merged}

  setup :verify_on_exit!

  @moduletag :tmp_dir

  @repository "EmpoweredHouse/shop"
  @tools "EmpoweredHouse/ehos-tools"
  @commit String.duplicate("c", 40)

  @files [
    %{"filename" => "packages/shop/CHANGELOG.md", "status" => "modified", "patch" => "+x"},
    %{"filename" => ".changes/shop/0.5.0.md", "status" => "added", "patch" => "+x"},
    %{"filename" => ".changes/unreleased/a.yaml", "status" => "removed", "patch" => "-x"},
    %{
      "filename" => "packages/shop/mix.exs",
      "status" => "modified",
      "patch" =>
        "@@ -1,3 +1,3 @@\n defmodule Shop.MixProject do\n-  @version \"0.4.0\"\n+  @version \"0.5.0\"\n end"
    }
  ]

  setup %{tmp_dir: dir} do
    write!(dir, "0.5.0")
    :ok
  end

  test "passes a release an administrator merged, which changed only the release's files",
       %{tmp_dir: dir} do
    mock_pull(pull())
    mock_role("admin")
    mock_files(@files)
    mock_pins_and_tags()

    assert Merged.merged(dir, @repository, @commit, mocks()) ==
             {:ok, %{component: "shop", version: "0.5.0", tag: "v0.5.0", pull_request: 12}}
  end

  test "refuses a release merged by anyone but an administrator, or whose role it cannot read",
       %{tmp_dir: dir} do
    mock_pull(pull())
    mock_role("write")
    mock_files(@files)
    mock_pins_and_tags()

    assert Merged.merged(dir, @repository, @commit, mocks()) ==
             {:error, ["maintainer merged pull request 12 with the role write, not admin"]}
  end

  test "refuses a commit that no release pull request of this repository merged into main",
       %{tmp_dir: dir} do
    for pull <- [
          %{pull() | "merge_commit_sha" => String.duplicate("d", 40)},
          put_in(pull(), ["head", "repo", "full_name"], "someone/fork"),
          put_in(pull(), ["head", "ref"], "feature/1-x"),
          put_in(pull(), ["base", "ref"], "feature/1-x"),
          %{pull() | "merged_at" => nil}
        ] do
      mock_pull(pull)

      assert Merged.merged(dir, @repository, @commit, mocks()) ==
               {:error,
                [
                  "#{@commit} is not the merge commit of a release pull request, " <>
                    "release/<component>-X.Y.Z of this repository merged into main"
                ]}
    end
  end

  test "refuses a change outside the release's files, a renamed file, and a version file " <>
         "changed beyond its line",
       %{tmp_dir: dir} do
    mock_pull(pull())
    mock_role("admin")

    mock_files([
      %{"filename" => "lib/shop.ex", "status" => "modified", "patch" => "+x"},
      %{"filename" => ".changes/shop/0.5.0.md", "status" => "renamed", "patch" => ""},
      %{
        "filename" => "packages/shop/mix.exs",
        "status" => "modified",
        "patch" =>
          "@@ -1,3 +1,4 @@\n-  @version \"0.4.0\"\n+  @version \"0.5.0\"\n+  {:evil, \"~> 1.0\"}"
      }
    ])

    mock_pins_and_tags()

    assert Merged.merged(dir, @repository, @commit, mocks()) ==
             {:error,
              [
                "pull request 12 changes lib/shop.ex, which is not a file of the release",
                "pull request 12 has .changes/shop/0.5.0.md renamed, which a release never does",
                "pull request 12 changes packages/shop/mix.exs beyond its version line"
              ]}
  end

  test "refuses a fragment left on the merge commit, a version file without the version, and " <>
         "a tag that exists",
       %{tmp_dir: dir} do
    fragment!(dir, "late.yaml")
    write(dir, "packages/shop/mix.exs", "  @version \"0.4.0\"\n")
    mock_pull(pull())
    mock_role("admin")
    mock_files(@files)
    mock_pins_and_tags(%{"v0.5.0" => @commit})

    assert Merged.merged(dir, @repository, @commit, mocks()) ==
             {:error,
              [
                "packages/shop/mix.exs holds 0.4.0, not 0.5.0",
                "fragments of shop are left on the merge commit, merged after the release was " <>
                  "opened: .changes/unreleased/late.yaml",
                "the tag v0.5.0 exists already"
              ]}
  end

  test "refuses what is not a full commit before it asks GitHub", %{tmp_dir: dir} do
    assert Merged.merged(dir, @repository, "main", mocks()) ==
             {:error, [~s("main" is not a full commit)]}
  end

  defp pull do
    %{
      "number" => 12,
      "merged_at" => "2026-11-28T10:00:00Z",
      "merge_commit_sha" => @commit,
      "base" => %{"ref" => "main"},
      "head" => %{"ref" => "release/shop-0.5.0", "repo" => %{"full_name" => @repository}},
      "merged_by" => %{"login" => "maintainer"}
    }
  end

  defp mock_pull(pull),
    do: expect(GitHubMock, :commit_pulls, fn @repository, @commit -> {:ok, [pull]} end)

  defp mock_role(role),
    do: expect(GitHubMock, :permission, fn @repository, "maintainer" -> {:ok, role} end)

  defp mock_files(files),
    do: expect(GitHubMock, :pull_files, fn @repository, 12 -> {:ok, files} end)

  defp mock_pins_and_tags(own \\ %{"v0.4.0" => tagged()}) do
    expect(GitMock, :tags, 2, fn
      @tools -> {:ok, %{"ehos_platform-v0.21.0" => tagged()}}
      @repository -> {:ok, own}
    end)

    expect(GitHubMock, :rulesets, fn @tools -> {:ok, [protecting(["ehos_platform-v"])]} end)
  end

  defp mocks, do: [git: GitMock, github: GitHubMock]
end

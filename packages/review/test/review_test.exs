defmodule ReviewTest do
  # Runs real git in a throwaway repository: the marks live where git says they do. What the gate
  # refuses and how a description is read are EhosApp.Review's, tested in packages/ehos_app; this
  # is what ehos-tools gives it.
  use ExUnit.Case, async: true

  doctest Review

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet", "--initial-branch=main"])
    commit!(repo, "first")
    %{repo: repo}
  end

  test "an unreviewed commit is told to follow this repository's skill and task", %{repo: repo} do
    assert {:error, message} = Review.check(repo)
    assert message =~ "has not been reviewed"
    assert message =~ "ehos-dev:pre-pr-review"
    assert message =~ "`mix review record` in packages/review"

    assert {:ok, _message} = Review.record(repo)
    assert Review.check(repo) == :ok
  end

  test "keeps ehos-tools' marks under ehos-tools-review, apart from an application's", %{
    repo: repo
  } do
    {:ok, _message} = Review.record(repo)

    marks =
      Path.join(
        git!(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
        "ehos-tools-review"
      )

    assert File.ls!(marks) == [git!(repo, ["rev-parse", "HEAD"])]
    assert {:error, _unreviewed} = EhosApp.Review.check(repo)
  end

  test "the hook refuses to open a pull request from an unreviewed commit, and lets a reviewed one through",
       %{repo: repo} do
    assert {:error, message} = Review.gate(hook(repo, "gh pr create --fill"))
    assert message =~ "mix review record"

    {:ok, _message} = Review.record(repo)
    assert Review.gate(hook(repo, "gh pr create --fill")) == :ok
  end

  test "a description without a Review section is told to follow this repository's skill" do
    assert Review.pull_request_body("## What\n\nA fix.\n\n## Review\n\nNothing found.\n") == :ok

    assert {:error, message} = Review.pull_request_body("## What\n\nA fix.\n")
    assert message =~ ".claude/review.md"
  end

  defp hook(cwd, command),
    do:
      JSON.encode!(%{
        "cwd" => cwd,
        "tool_name" => "Bash",
        "tool_input" => %{"command" => command}
      })

  defp commit!(repo, message) do
    File.write!(Path.join(repo, "file.txt"), message)
    git!(repo, ["add", "file.txt"])

    git!(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      # A developer's global signing would make the test commit wait for a key, or fail.
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--quiet",
      "-m",
      message
    ])
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(output)
  end
end

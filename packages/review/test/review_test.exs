defmodule ReviewTest do
  # Runs real git in a throwaway repository: the marks live where git says they do. What the gate
  # refuses and how a description is read are EhosApp.Review's, tested in packages/ehos_app; this
  # is what ehos-tools gives it.
  use ExUnit.Case, async: true

  doctest Review

  @moduletag :tmp_dir

  @unreviewed "Follow the ehos-dev:pre-pr-review skill (this repository's part is " <>
                ".claude/review.md): review the change, settle what the reviews find, pass " <>
                "`mix check` in each package it touches, then run `mix review record` in " <>
                "packages/review, and open the pull request again."

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet", "--initial-branch=main"])
    commit!(repo, "first")
    %{repo: repo, head: git!(repo, ["rev-parse", "HEAD"])}
  end

  describe "record/1" do
    test "marks HEAD under ehos-tools-review, apart from an application's marks", %{
      repo: repo,
      head: head
    } do
      assert Review.record(repo) == {:ok, "#{short(head)} is marked as reviewed"}

      marks =
        Path.join(
          git!(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
          "ehos-tools-review"
        )

      assert File.ls!(marks) == [head]

      assert EhosApp.Review.check(repo) ==
               {:error,
                "#{short(head)} has not been reviewed. Follow the ehos-app:pre-pr-review " <>
                  "skill: review the change, settle what the reviews find, pass " <>
                  "`mix precommit`, then run `MIX_ENV=dev mix ehos_app.review record`, and " <>
                  "open the pull request again."}
    end
  end

  describe "check/1" do
    test "passes a commit that was recorded as reviewed", %{repo: repo} do
      {:ok, _message} = Review.record(repo)

      assert Review.check(repo) == :ok
    end

    test "tells an unreviewed commit to follow this repository's skill and task", %{
      repo: repo,
      head: head
    } do
      assert Review.check(repo) ==
               {:error, "#{short(head)} has not been reviewed. #{@unreviewed}"}
    end
  end

  describe "gate/1" do
    test "lets a reviewed commit open a pull request", %{repo: repo} do
      {:ok, _message} = Review.record(repo)

      assert Review.gate(hook(repo, "gh pr create --fill")) == :ok
    end

    test "refuses to open a pull request from an unreviewed commit", %{repo: repo, head: head} do
      assert Review.gate(hook(repo, "gh pr create --fill")) ==
               {:error, "#{short(head)} has not been reviewed. #{@unreviewed}"}
    end
  end

  # A description that passes is `Review.pull_request_body/1`'s doctest.
  describe "pull_request_body/1" do
    test "tells a description without a Review section to follow this repository's skill" do
      assert Review.pull_request_body("## What\n\nA fix.\n") ==
               {:error,
                "the pull request's description has no `## Review` section. Follow the " <>
                  "ehos-dev:pre-pr-review skill (this repository's part is .claude/review.md): " <>
                  "list what each of the two reviews found and what became of each finding, " <>
                  "or say the change is documentation alone, under `## Review`. Then edit the " <>
                  "description: re-running the job reads the description it had."}
    end
  end

  describe "mix review" do
    test "says how to use it, by its own name" do
      assert_raise Mix.Error, "Usage: mix review record | check | gate | pull_request", fn ->
        Mix.Tasks.Review.run([])
      end
    end
  end

  defp hook(cwd, command),
    do:
      JSON.encode!(%{
        "cwd" => cwd,
        "tool_name" => "Bash",
        "tool_input" => %{"command" => command}
      })

  defp short(commit), do: String.slice(commit, 0, 12)

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

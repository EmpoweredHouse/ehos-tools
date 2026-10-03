defmodule ReviewTest do
  # Runs real git in a throwaway repository: the marks live where git says they do.
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

  test "a commit is unreviewed until it is recorded", %{repo: repo} do
    assert {:error, message} = Review.check(repo)
    assert message =~ "has not been reviewed"
    assert message =~ "mix review record"

    assert {:ok, _message} = Review.record(repo)
    assert Review.check(repo) == :ok
  end

  test "a new commit after the review is unreviewed again", %{repo: repo} do
    {:ok, _message} = Review.record(repo)
    commit!(repo, "after the review")

    assert {:error, _message} = Review.check(repo)
  end

  test "refuses to record while changes are uncommitted, which the mark would not cover", %{
    repo: repo
  } do
    File.write!(Path.join(repo, "pending.txt"), "not committed")

    assert {:error, message} = Review.record(repo)
    assert message =~ "uncommitted changes"
    assert {:error, _unreviewed} = Review.check(repo)
  end

  test "every worktree of the repository sees the same marks", %{repo: repo, tmp_dir: tmp_dir} do
    worktree = Path.join(tmp_dir, "worktree")
    git!(repo, ["worktree", "add", "--quiet", "--detach", worktree])

    {:ok, _message} = Review.record(worktree)

    assert Review.check(repo) == :ok
  end

  test "keeps the marks out of the working tree", %{repo: repo} do
    {:ok, _message} = Review.record(repo)

    assert git!(repo, ["status", "--porcelain"]) == ""
  end

  test "says what failed when the directory is not a repository" do
    # Outside this repository, or git would find it by walking up.
    dir = Path.join(System.tmp_dir!(), "ehos-tools-review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, message} = Review.check(dir)
    assert message =~ "`git rev-parse HEAD` failed"
  end

  describe "hook_dir/1" do
    test "follows a quoted `cd` at the start of the command" do
      input = %{
        "cwd" => "/repo",
        "tool_input" => %{"command" => ~s(cd "/work trees/wt"; gh pr create --fill)}
      }

      assert Review.hook_dir(input) == {:ok, "/work trees/wt"}
    end

    test "follows a single-quoted `cd`, relative to the session's directory" do
      input = %{"cwd" => "/repo", "tool_input" => %{"command" => "cd '../wt' && gh pr create"}}

      assert Review.hook_dir(input) == {:ok, "/wt"}
    end

    test "refuses a command that changes directory in a way it cannot follow" do
      for command <- [
            "(cd ../wt && gh pr create)",
            "pushd ../wt && gh pr create",
            "cd ../wt && cd sub && gh pr create",
            "bash -c 'cd ../wt && gh pr create'",
            "sh -c \"cd ../wt; gh pr create\"",
            "env -C ../wt gh pr create",
            "env --chdir=../wt gh pr create",
            "popd && gh pr create"
          ] do
        assert {:error, message} =
                 Review.hook_dir(%{"cwd" => "/repo", "tool_input" => %{"command" => command}}),
               command

        assert message =~ "cannot tell which working tree"
      end
    end

    test "reads only what comes before the command that opens the pull request" do
      for command <- [
            "gh pr create --body 'To try it: cd packages/review && mix test'",
            "git -C packages/review log -1 && gh pr create --fill"
          ] do
        assert Review.hook_dir(%{"cwd" => "/repo", "tool_input" => %{"command" => command}}) ==
                 {:ok, "/repo"},
               command
      end
    end
  end

  describe "pull_request_body/1" do
    test "accepts a description with a Review section that says something" do
      for body <- [
            "## What\n\nA fix.\n\n## Review\n\n| Finding | Outcome |\n| --- | --- |\n| x | fixed |\n",
            "## Review\r\n\r\nDocumentation alone, so not reviewed.\r\n\r\n## Notes\r\n\r\nx\r\n",
            "## What\n\nx\n\n##  Review  \nTwo rounds, nothing found.\n",
            "## Review ✅\n\nNothing found.\n",
            "## review:\n\nNothing found.\n",
            "  ## **Review**\n\nNothing found.\n",
            "## Review ##\n\nNothing found.\n",
            "## Review\n\n### Correctness\n\nOne finding, fixed.\n",
            "## Review\n\n## Notes\n\nx\n\n## Review\n\nNothing found.\n",
            # `<!--` in code opens no comment.
            "## What\n\n```html\n<!-- x\n```\n\n## Review\n\nNothing found.\n",
            "## What\n\nStrips `<!--` comments.\n\n## Review\n\nNothing found.\n",
            # A fence closes on one at least as long; a line with backticks after ``` is inline code.
            "## What\n\n```\ncode\n````\n\n## Review\n\nNothing found.\n",
            "## What\n\n```elixir``` is inline.\n\n## Review\n\nNothing found.\n"
          ] do
        assert Review.pull_request_body(body) == :ok, body
      end
    end

    test "refuses a description without a Review section, or with an empty one" do
      for body <- [
            nil,
            "",
            "## What\n\nA fix.\n",
            "### Review\n\nA subsection is not the section.\n",
            "## Reviewers\n\nNot the section either.\n",
            "Review: done.\n",
            "## Review\n\n## How it was tested\n\nmix check\n",
            "## Review\n\n<!-- what each review found -->\n\n## Next\n",
            "## What\n\nx\n\n## Review\n\n   \n",
            "## Reviews\n\nAnother heading.\n",
            "## Review\n\n<!-- todo, never closed\n",
            "## Review\n\n​\n",
            "## Review\n\n### Correctness\n\n## Next\n\nx\n",
            "## Review\n\n# Appendix\n\nNot the section's.\n",
            "## What\n\n```md\n## Review\n\nQuoted from the template.\n```\n",
            "## What\n\n~~~\n## Review\nx\n~~~\n"
          ] do
        assert {:error, message} = Review.pull_request_body(body), inspect(body)
        assert message =~ "Review"
      end
    end
  end

  describe "gate/1" do
    test "lets through a command that opens no pull request, without asking git", %{repo: repo} do
      assert Review.gate(hook(repo, "git status")) == :ok
    end

    test "refuses to open a pull request from an unreviewed commit", %{repo: repo} do
      assert {:error, message} = Review.gate(hook(repo, "gh pr create --fill"))
      assert message =~ "has not been reviewed"
    end

    test "opens one from a reviewed commit, following a leading cd", %{repo: repo} do
      {:ok, _message} = Review.record(repo)

      assert Review.gate(hook("/somewhere/else", "cd #{repo} && gh pr create --fill")) == :ok
    end

    test "knows the command however it is written: gh's alias, and any spacing", %{repo: repo} do
      for command <- [
            "gh pr new --fill",
            "gh  pr\tcreate --fill",
            "gh pr \\\n  create --fill",
            "gh \\\npr create"
          ] do
        assert {:error, message} = Review.gate(hook(repo, command)), command
        assert message =~ "has not been reviewed"
      end
    end

    test "refuses a pull request for a branch or a repository other than the checkout's", %{
      repo: repo
    } do
      {:ok, _message} = Review.record(repo)

      for command <- [
            "gh pr create --fill --head feature-x",
            "gh pr create --fill -H feature-x",
            "gh pr create --fill --head=feature-x",
            "gh pr create --fill -Hfeature-x",
            "gh pr create -fH feature-x",
            "gh pr create --fill -Rother/repo",
            "gh pr -R other/repo create --fill",
            "gh pr --repo other/repo new",
            "GH_REPO=other/repo gh pr create --fill"
          ] do
        assert {:error, message} = Review.gate(hook(repo, command)), command
        assert message =~ "without --head, --repo or GH_REPO"
      end
    end

    test "checks the tree every pull request in the command opens from", %{repo: repo} do
      {:ok, _message} = Review.record(repo)

      command = "gh pr create --fill; cd ../other && gh pr create --fill"
      assert {:error, message} = Review.gate(hook(repo, command))
      assert message =~ "cannot tell which working tree"
    end

    test "does not take a line break between two commands for one that opens a pull request", %{
      repo: repo
    } do
      assert Review.gate(hook(repo, "gh pr\ncreate-notes.sh")) == :ok
    end

    test "refuses what it cannot read rather than letting it through" do
      assert {:error, _message} = Review.gate("not json")
      assert {:error, _message} = Review.gate(~s([1, 2]))
      assert {:error, _message} = Review.gate(~s({"tool_input": {"command": "gh pr create"}}))
    end
  end

  test "removes marks older than 90 days when it records a new one", %{repo: repo} do
    {:ok, _message} = Review.record(repo)

    marks =
      Path.join(
        git!(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
        "ehos-tools-review"
      )

    stale = Path.join(marks, String.duplicate("0", 40))
    File.write!(stale, "")
    File.touch!(stale, System.os_time(:second) - 91 * 86_400)
    commit!(repo, "next")

    {:ok, _message} = Review.record(repo)

    refute File.exists?(stale)
    assert length(File.ls!(marks)) == 2
  end

  test "records past anything in the marks' directory that is not a mark", %{repo: repo} do
    {:ok, _message} = Review.record(repo)

    marks =
      Path.join(
        git!(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
        "ehos-tools-review"
      )

    # Old enough to be pruned, were it a mark.
    not_a_mark = Path.join(marks, "not-a-mark")
    File.mkdir_p!(not_a_mark)
    File.touch!(not_a_mark, System.os_time(:second) - 91 * 86_400)
    commit!(repo, "next")

    assert {:ok, _message} = Review.record(repo)
    assert Review.check(repo) == :ok
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

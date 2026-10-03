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
            "git -C ../wt push && gh pr create"
          ] do
        assert {:error, message} =
                 Review.hook_dir(%{"cwd" => "/repo", "tool_input" => %{"command" => command}}),
               command

        assert message =~ "cannot tell which working tree"
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

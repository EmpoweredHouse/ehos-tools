defmodule EhosApp.ReviewTest do
  # Runs real git in a throwaway repository: the marks live where git says they do.
  use ExUnit.Case, async: true

  doctest EhosApp.Review

  @moduletag :tmp_dir

  setup {Hammox, :verify_on_exit!}

  @unreviewed "Follow the ehos-app:pre-pr-review skill: review the change, settle what the " <>
                "reviews find, pass `mix precommit`, then run `MIX_ENV=dev mix ehos_app.review " <>
                "record`, and open the pull request again."
  @rerun "Then edit the description: re-running the job reads the description it had."
  @no_section "the pull request's description has no `## Review` section. Follow the " <>
                "ehos-app:pre-pr-review skill: list what each of its reviews found and what " <>
                "became of each finding, or say the change is documentation alone, under " <>
                "`## Review`. " <> @rerun
  @empty_section "the pull request's `## Review` section is empty: say what each review found " <>
                   "and what became of each finding, or that the change is documentation " <>
                   "alone. " <> @rerun
  @cannot_tell "cannot tell which working tree this command opens a pull request from; run it " <>
                 "as `cd <worktree> && gh pr create ...`"
  @other_branch "the review mark covers the checked-out HEAD alone; open the pull request from " <>
                  "a checkout of its branch, without --head, --repo or GH_REPO"
  @moves_head "this command moves HEAD (a commit, a checkout, a rebase…) or points git " <>
                "elsewhere before it opens the pull request, so the review mark would not " <>
                "cover what is sent; run that first, review the commit it makes, then open the " <>
                "pull request on its own"

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet", "--initial-branch=main"])
    commit!(repo, "first")
    %{repo: repo}
  end

  test "a commit is unreviewed until it is recorded", %{repo: repo} do
    assert EhosApp.Review.check(repo) == unreviewed(repo)

    assert EhosApp.Review.record(repo) == {:ok, "#{short_head(repo)} is marked as reviewed"}
    assert EhosApp.Review.check(repo) == :ok
  end

  test "a new commit after the review is unreviewed again", %{repo: repo} do
    {:ok, _message} = EhosApp.Review.record(repo)
    commit!(repo, "after the review")

    assert EhosApp.Review.check(repo) == unreviewed(repo)
  end

  test "refuses to record while changes are uncommitted, which the mark would not cover", %{
    repo: repo
  } do
    File.write!(Path.join(repo, "pending.txt"), "not committed")

    assert EhosApp.Review.record(repo) ==
             {:error,
              "the working tree has uncommitted changes; commit them, review, then record"}

    assert EhosApp.Review.check(repo) == unreviewed(repo)
  end

  test "every worktree of the repository sees the same marks", %{repo: repo, tmp_dir: tmp_dir} do
    worktree = Path.join(tmp_dir, "worktree")
    git!(repo, ["worktree", "add", "--quiet", "--detach", worktree])

    {:ok, _message} = EhosApp.Review.record(worktree)

    assert EhosApp.Review.check(repo) == :ok
  end

  # ehos-tools' own gate is this one, with options of its own (T-17).
  test "keeps the marks of another repository's options apart, and says what they say", %{
    repo: repo
  } do
    opts = [marks: "other-review", unreviewed: "Run the other task.", no_section: "Say so."]

    {:ok, _message} = EhosApp.Review.record(repo, opts)

    assert EhosApp.Review.check(repo, opts) == :ok
    assert EhosApp.Review.check(repo) == unreviewed(repo)

    commit!(repo, "next")
    other = {:error, "#{short_head(repo)} has not been reviewed. Run the other task."}
    assert EhosApp.Review.check(repo, opts) == other
    assert EhosApp.Review.gate(hook(repo, "gh pr create --fill"), opts) == other

    assert EhosApp.Review.pull_request_body("## What\n", opts) ==
             {:error,
              "the pull request's description has no `## Review` section. Say so. " <> @rerun}
  end

  test "keeps the marks out of the working tree", %{repo: repo} do
    {:ok, _message} = EhosApp.Review.record(repo)

    assert git!(repo, ["status", "--porcelain"]) == ""
  end

  # The setup's repository is under `tmp_dir`, not around it, and the test helper keeps git from
  # walking up past `tmp/` into this repository.
  test "says what failed when the directory is not a repository", %{tmp_dir: tmp_dir} do
    # The rest is git's own words, which differ between its versions.
    assert {:error, "`git rev-parse HEAD` failed:\nfatal: not a git repository" <> _git} =
             EhosApp.Review.check(tmp_dir)
  end

  describe "hook_dir/1" do
    test "follows a quoted `cd` at the start of the command" do
      input = %{
        "cwd" => "/repo",
        "tool_input" => %{"command" => ~s(cd "/work trees/wt"; gh pr create --fill)}
      }

      assert EhosApp.Review.hook_dir(input) == {:ok, "/work trees/wt"}
    end

    test "follows a single-quoted `cd`, relative to the session's directory" do
      input = %{"cwd" => "/repo", "tool_input" => %{"command" => "cd '../wt' && gh pr create"}}

      assert EhosApp.Review.hook_dir(input) == {:ok, "/wt"}
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
            "popd && gh pr create",
            # env quoted, in a subshell, by its path, with -C bundled or GNU's prefix, continued.
            "(env -C ../wt gh pr create)",
            "bash -c \"env -C ../wt gh pr create\"",
            "bash -c 'env -C ../wt gh pr create'",
            "/usr/bin/env -C ../wt gh pr create",
            "env -iC ../wt gh pr create",
            "env --ch=../wt gh pr create",
            "env \\\n  -C ../wt \\\n  gh pr create",
            "x=$(env -C ../wt pwd) && gh pr create",
            "env --c=../wt gh pr create",
            "\\env -C ../wt gh pr create"
          ] do
        assert EhosApp.Review.hook_dir(%{
                 "cwd" => "/repo",
                 "tool_input" => %{"command" => command}
               }) == {:error, @cannot_tell},
               command
      end
    end

    test "reads only what comes before the command that opens the pull request" do
      for command <- [
            "gh pr create --body 'To try it: cd assets && npm test'",
            "git -C assets log -1 && gh pr create --fill"
          ] do
        assert EhosApp.Review.hook_dir(%{
                 "cwd" => "/repo",
                 "tool_input" => %{"command" => command}
               }) ==
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
            "## What\n\n```elixir``` is inline.\n\n## Review\n\nNothing found.\n",
            # A fence in a comment opens no code block.
            "<!--\n```\n-->\n\n## Review\n\nNothing found.\n",
            "## Review\n\n---\n\n- fixed: the gate\n",
            # Markers not followed by a space are text, as CommonMark has it.
            "## Review\n\n1.2.\n"
          ] do
        assert EhosApp.Review.pull_request_body(body) == :ok, body
      end
    end

    test "refuses a description without a Review section" do
      for body <- [
            nil,
            "",
            "## What\n\nA fix.\n",
            "### Review\n\nA subsection is not the section.\n",
            "## Reviewers\n\nNot the section either.\n",
            "Review: done.\n",
            "## Reviews\n\nAnother heading.\n",
            "## What\n\n```md\n## Review\n\nQuoted from the template.\n```\n",
            "## What\n\n~~~\n## Review\nx\n~~~\n",
            "<!-- a fence: -->\n## What\n\n<!--\n## Review\n\nx\n-->\n",
            # What follows removed text does not begin a line.
            "`x`## Review\n\nfoo\n",
            "<!-- -->## Review\n\nfoo\n"
          ] do
        assert EhosApp.Review.pull_request_body(body) == {:error, @no_section}, inspect(body)
      end
    end

    test "refuses a Review section that says nothing" do
      for body <- [
            "## Review\n\n## How it was tested\n\nmix check\n",
            "## Review\n\n<!-- what each review found -->\n\n## Next\n",
            "## What\n\nx\n\n## Review\n\n   \n",
            "## Review\n\n<!-- todo, never closed\n",
            "## Review\n\n\u200B\n",
            "## Review\n\n### Correctness\n\n## Next\n\nx\n",
            "## Review\n\n# Appendix\n\nNot the section's.\n",
            # An empty heading ends the section; Markdown's structure alone says nothing.
            "## Review\n\n##\n\nNotes text\n",
            "## Review\n\n---\n",
            "## Review\n\n* * *\n\n-\n\n1.\n\n>\n"
          ] do
        assert EhosApp.Review.pull_request_body(body) == {:error, @empty_section}, inspect(body)
      end
    end
  end

  describe "gate/1" do
    test "lets through a command that opens no pull request, without asking git", %{repo: repo} do
      assert EhosApp.Review.gate(hook(repo, "git status")) == :ok
    end

    test "refuses to open a pull request from an unreviewed commit", %{repo: repo} do
      assert EhosApp.Review.gate(hook(repo, "gh pr create --fill")) == unreviewed(repo)
    end

    test "opens one from a reviewed commit, following a leading cd", %{repo: repo} do
      {:ok, _message} = EhosApp.Review.record(repo)

      assert EhosApp.Review.gate(hook("/somewhere/else", "cd #{repo} && gh pr create --fill")) ==
               :ok
    end

    test "refuses a reviewed commit while the machine holds older plugins than the session's tree pins",
         %{repo: repo} do
      pin_marketplace!(repo)
      mock_held(repo, "ehos-dev-v0.12.0")
      mock_installed(repo)
      {:ok, _message} = EhosApp.Review.record(repo, claude: EhosApp.ClaudeMock)

      mock_held(repo, "ehos-dev-v0.11.0")

      assert {:error, "This machine has the marketplace ehos-tools at ehos-dev-v0.11.0" <> _} =
               EhosApp.Review.gate(hook(repo, "gh pr create --fill"),
                 claude: EhosApp.ClaudeMock,
                 project: repo
               )
    end

    test "reads the pins of the session's project, not of the directory the session is in", %{
      repo: repo,
      tmp_dir: tmp_dir
    } do
      {:ok, _message} = EhosApp.Review.record(repo)

      project = Path.join(tmp_dir, "project")
      File.mkdir_p!(project)
      git!(project, ["init", "--quiet", "--initial-branch=main"])
      pin_marketplace!(project)
      mock_held(project, "ehos-dev-v0.11.0")

      assert {:error, "This machine has the marketplace ehos-tools at ehos-dev-v0.11.0" <> _} =
               EhosApp.Review.gate(hook(repo, "gh pr create --fill"),
                 claude: EhosApp.ClaudeMock,
                 project: project
               )
    end

    test "refuses to record while the machine holds older plugins than the tree pins", %{
      repo: repo
    } do
      pin_marketplace!(repo)
      mock_held(repo, "ehos-dev-v0.11.0")

      assert {:error, "This machine has the marketplace ehos-tools at ehos-dev-v0.11.0" <> _} =
               EhosApp.Review.record(repo, claude: EhosApp.ClaudeMock)

      assert EhosApp.Review.check(repo) == unreviewed(repo)
    end

    test "knows the command however it is written: gh's alias, and any spacing", %{repo: repo} do
      for command <- [
            "gh pr new --fill",
            "gh  pr\tcreate --fill",
            "gh pr \\\n  create --fill",
            "gh \\\npr create"
          ] do
        assert EhosApp.Review.gate(hook(repo, command)) == unreviewed(repo), command
      end
    end

    test "refuses a pull request for a branch or a repository other than the checkout's", %{
      repo: repo
    } do
      {:ok, _message} = EhosApp.Review.record(repo)

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
        assert EhosApp.Review.gate(hook(repo, command)) == {:error, @other_branch}, command
      end
    end

    test "checks the tree every pull request in the command opens from", %{repo: repo} do
      {:ok, _message} = EhosApp.Review.record(repo)

      command = "gh pr create --fill; cd ../other && gh pr create --fill"
      assert EhosApp.Review.gate(hook(repo, command)) == {:error, @cannot_tell}
    end

    test "refuses a command that moves HEAD, or points git elsewhere, before opening",
         %{repo: repo} do
      {:ok, _message} = EhosApp.Review.record(repo)

      for command <- [
            "git commit -am wip && gh pr create --fill",
            "git -C . commit --amend --no-edit; gh pr create --fill",
            "git checkout other && gh pr create --fill",
            "git switch -c next && gh pr create --fill",
            "git rebase origin/main && gh pr create --fill",
            "git pull --rebase && gh pr create --fill",
            "git merge main && gh pr create --fill",
            "git reset --hard HEAD~1 && gh pr create --fill",
            "git am < fix.patch && gh pr create --fill",
            "git cherry-pick abc123 && gh pr create --fill",
            "git revert HEAD && gh pr create --fill",
            "git -c user.name=x commit -m y && gh pr create --fill",
            "git --no-pager commit -m y && gh pr create --fill",
            "git \\\n  commit -m y && gh pr create --fill",
            "bash -c 'git commit -m y' && gh pr create --fill",
            "git bisect start && gh pr create --fill",
            "gh pr checkout 12 && gh pr create --fill",
            "gh pr -R o/r checkout 12 && gh pr create --fill",
            "/usr/local/bin/gh pr checkout 12 && gh pr create --fill",
            "gh repo sync && gh pr create --fill",
            # Options that take a value, quoted or not, and a subcommand followed by `\` or `>`.
            "git --work-tree . commit -m y && gh pr create --fill",
            "git --namespace x commit -m y && gh pr create --fill",
            "git -C \"my dir\" commit -m y && gh pr create --fill",
            "git -c 'user.name=A B' commit -m y && gh pr create --fill",
            "git commit\\\n -m y && gh pr create --fill",
            "git commit>/dev/null && gh pr create --fill",
            # Read one way: options whose value starts with `-` once made the regex give up,
            # which read as nothing found.
            "git " <> String.duplicate("-c ", 40) <> "; git commit -m y && gh pr create --fill",
            "git " <> String.duplicate("-C ", 40) <> "; git commit -m y && gh pr create --fill",
            "GIT_DIR=../other/.git gh pr create --fill",
            "export GIT_WORK_TREE=../other; gh pr create --fill",
            # Plumbing that writes HEAD, and a rewrite of the branch's history.
            "git update-ref HEAD abc123 && gh pr create --fill",
            "git update-ref -m why HEAD abc123 && gh pr create --fill",
            "git symbolic-ref HEAD refs/heads/other && gh pr create --fill",
            "git filter-branch --tree-filter true && gh pr create --fill",
            "/usr/bin/git commit -m y && gh pr create --fill",
            "git -C git/ commit -m y && gh pr create --fill",
            "git -c git.x=y commit -m y && gh pr create --fill",
            "git update-ref -m \"a b\" HEAD abc123 && gh pr create --fill",
            "git update-ref --stdin < moves && gh pr create --fill",
            "git update-ref --no-deref \\\n  HEAD abc123 && gh pr create --fill",
            "git update-ref 'HEAD' abc123 && gh pr create --fill",
            "git update-ref -m why \"HEAD\" abc123 && gh pr create --fill"
          ] do
        assert EhosApp.Review.gate(hook(repo, command)) == {:error, @moves_head}, command
      end
    end

    test "lets through git commands that leave HEAD where it is, and any after the pull request",
         %{repo: repo} do
      {:ok, _message} = EhosApp.Review.record(repo)

      for command <- [
            "git push -u origin HEAD && gh pr create --fill",
            "git stash && gh pr create --fill",
            "git status; gh pr create --fill",
            "git merge-base main HEAD && gh pr create --fill",
            "git push origin revert-gate && gh pr create --fill",
            "git log --grep merge && gh pr create --fill",
            "git -c commit.gpgsign=false push && gh pr create --fill",
            "git commit-graph verify && gh pr create --fill",
            "git branch -d old-feature && gh pr create --fill",
            "git branch --list && gh pr create --fill",
            # git refuses to force the branch a worktree has checked out.
            "git branch -f other abc123 && gh pr create --fill",
            # The reading forms of the plumbing.
            "b=$(git symbolic-ref --short HEAD) && gh pr create --fill",
            "git update-ref refs/heads/other abc123 && gh pr create --fill",
            "git symbolic-ref --short HEAD 2>/dev/null && gh pr create --fill",
            "gh pr create --fill && git checkout main"
          ] do
        assert EhosApp.Review.gate(hook(repo, command)) == :ok, command
      end
    end

    test "reads gh's subcommand as the first word after pr, not a branch named like one", %{
      repo: repo
    } do
      # Unreviewed HEAD: anything read as opening a pull request would be refused.
      for command <- [
            "gh pr checkout new-feature",
            "gh pr checkout create-notes",
            "gh pr view 12 --json title,body | grep create",
            "gh pr list --search create",
            "gh pr comment 1 --body 'please create'",
            "my-gh pr create",
            "echo gh pr\ncreate-notes x"
          ] do
        assert EhosApp.Review.gate(hook(repo, command)) == :ok, command
      end

      # gh takes a flag before the subcommand as the subcommand's, with its value.
      for command <- [
            "gh pr --help create",
            "gh pr -B main create --fill",
            "gh pr --base main create",
            "gh pr --title x create",
            "gh pr --title \"two words\" create",
            "gh pr \"create\" --fill",
            "gh pr 'create' --fill",
            # A value of several words, or a continued line, before the subcommand.
            "gh pr --title=\"a b c\" create --fill",
            "gh pr --title \"say \\\"hi\\\"\" create",
            "gh pr --body \"$(cat body.md)\" create",
            "gh pr --draft \\\n  create --fill",
            # A flag's value that is one of gh's subcommands, or holds a gh of its own.
            "gh pr --title review create",
            "gh pr -t 'revert the gate' create",
            "gh pr --label ready create",
            "gh pr --title merge new",
            "gh pr --body \"$(gh pr view 12 --json body)\" create",
            # gh by its path, and a redirection with no space.
            "/usr/local/bin/gh pr create",
            "'/opt/homebrew/bin/gh' pr create --fill",
            "./gh pr create",
            "gh pr create>/tmp/out",
            "gh pr new</dev/null"
          ] do
        assert EhosApp.Review.gate(hook(repo, command)) == unreviewed(repo), command
      end

      # The same, with a flag that names another branch or repository.
      for command <- [
            "gh pr --head other create --fill",
            "gh pr -H other create",
            "gh pr --title=\"a b c\" create --head other",
            "gh pr -R o/r create --fill",
            "gh pr --repo o/r new",
            "gh pr -R 'o r' create"
          ] do
        assert EhosApp.Review.gate(hook(repo, command)) == {:error, @other_branch}, command
      end
    end

    test "reads 64 KB of what used to take seconds in a moment", %{repo: repo} do
      {:ok, _message} = EhosApp.Review.record(repo)

      for command <- [
            # About 12 s with the subcommand read anywhere on the line.
            String.duplicate("gh pr ", 10_800),
            # About 6 s with `env … -C` read as anything up to `-C`.
            String.duplicate("env ", 16_000) <> "&& gh pr create --fill",
            # About 7 s with `git` taken for the value of `-c`.
            String.duplicate("git -c ", 9_000) <> "&& gh pr create --fill",
            # About 32 s with a flag's value read as anything, and 14 s with `git` inside a flag.
            String.duplicate("-gh pr ", 9_300) <> "x && gh pr create --fill",
            String.duplicate("-git ", 13_000) <> "&& gh pr create --fill",
            # A flag and a value before the subcommand, repeated.
            "gh pr " <> String.duplicate("-x y ", 13_000) <> "create"
          ] do
        assert byte_size(command) < 65_536
        {time, _result} = :timer.tc(fn -> EhosApp.Review.gate(hook(repo, command)) end)
        # Loose, so a paused CI runner does not fail it.
        assert time < 2_000_000, "#{div(time, 1000)} ms"
      end
    end

    test "lets a long command that names no gh through, unread", %{repo: repo} do
      command =
        "cat <<'EOF'\n" <> String.duplicate("a prose line, enough to pr new text\n", 3_000)

      assert byte_size(command) > 65_536
      assert EhosApp.Review.gate(hook(repo, command)) == :ok
    end

    test "refuses a command longer than the gate reads, in a moment", %{repo: repo} do
      {:ok, _message} = EhosApp.Review.record(repo)
      # 80 KB that took the first version of the HEAD-move regex about 21 s.
      command = String.duplicate("git ", 20_000) <> "&& gh pr create --fill"

      {time, result} = :timer.tc(fn -> EhosApp.Review.gate(hook(repo, command)) end)

      assert result ==
               {:error,
                "this command is longer than 65536 bytes, more than the gate reads; open the " <>
                  "pull request with a command of its own, its body in a file"}

      # Loose, so a paused CI runner does not fail it; refused unread, it takes milliseconds.
      assert time < 5_000_000
    end

    test "does not take a line break between two commands for one that opens a pull request", %{
      repo: repo
    } do
      assert EhosApp.Review.gate(hook(repo, "gh pr\ncreate-notes.sh")) == :ok
    end

    test "refuses what it cannot read rather than letting it through" do
      assert EhosApp.Review.gate("not json") == {:error, "the hook's input is not a JSON object"}
      assert EhosApp.Review.gate(~s([1, 2])) == {:error, "the hook's input is not a JSON object"}

      assert EhosApp.Review.gate(~s({"tool_input": {"command": "gh pr create"}})) ==
               {:error, "the hook's input has no `cwd`"}
    end
  end

  test "removes marks older than 90 days when it records a new one", %{repo: repo} do
    {:ok, _message} = EhosApp.Review.record(repo)

    marks =
      Path.join(
        git!(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
        "ehos-app-review"
      )

    first = git!(repo, ["rev-parse", "HEAD"])
    stale = Path.join(marks, String.duplicate("0", 40))
    File.write!(stale, "")
    File.touch!(stale, System.os_time(:second) - 91 * 86_400)
    commit!(repo, "next")

    {:ok, _message} = EhosApp.Review.record(repo)

    assert Enum.sort(File.ls!(marks)) == Enum.sort([first, git!(repo, ["rev-parse", "HEAD"])])
  end

  test "records past anything in the marks' directory that is not a mark", %{repo: repo} do
    {:ok, _message} = EhosApp.Review.record(repo)

    marks =
      Path.join(
        git!(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
        "ehos-app-review"
      )

    # Old enough to be pruned, were it a mark.
    not_a_mark = Path.join(marks, "not-a-mark")
    File.mkdir_p!(not_a_mark)
    File.touch!(not_a_mark, System.os_time(:second) - 91 * 86_400)
    commit!(repo, "next")

    assert EhosApp.Review.record(repo) == {:ok, "#{short_head(repo)} is marked as reviewed"}
    assert EhosApp.Review.check(repo) == :ok
  end

  defp unreviewed(repo),
    do: {:error, "#{short_head(repo)} has not been reviewed. " <> @unreviewed}

  defp short_head(repo), do: repo |> git!(["rev-parse", "HEAD"]) |> String.slice(0, 12)

  defp pin_marketplace!(repo) do
    File.mkdir_p!(Path.join(repo, ".claude"))

    File.write!(
      Path.join([repo, ".claude", "settings.json"]),
      JSON.encode!(%{
        "extraKnownMarketplaces" => %{
          "ehos-tools" => %{
            "source" => %{"repo" => "EmpoweredHouse/ehos-tools", "ref" => "ehos-dev-v0.12.0"}
          }
        },
        "enabledPlugins" => %{"ehos-dev@ehos-tools" => true}
      })
    )

    git!(repo, ["add", ".claude"])
    commit!(repo, "pins a marketplace")
  end

  defp mock_held(repo, ref) do
    Hammox.expect(EhosApp.ClaudeMock, :run, fn ["plugin", "marketplace", "list", "--json"],
                                               ^repo ->
      {:ok,
       JSON.encode!([
         %{"name" => "ehos-tools", "repo" => "EmpoweredHouse/ehos-tools", "ref" => ref}
       ])}
    end)
  end

  defp mock_installed(repo) do
    Hammox.expect(EhosApp.ClaudeMock, :run, fn ["plugin", "list", "--json"], ^repo ->
      {:ok,
       JSON.encode!([
         %{"id" => "ehos-dev@ehos-tools", "version" => "0.12.0", "projectPath" => repo}
       ])}
    end)
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

defmodule Review.GitTest do
  # Runs real git in a throwaway repository: Review.GitImpl is what reads the checkout CI runs in.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @git Review.GitImpl

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet", "--initial-branch=main"])
    write!(repo, "packages/a/CHANGELOG.md", "## [Unreleased]\n")
    %{repo: repo, base: commit!(repo, "base")}
  end

  describe "first_parents/3" do
    test "lists the merges on main's first-parent line, oldest first, not the commits they merge",
         %{repo: repo, base: base} do
      git!(repo, ["switch", "--quiet", "--create", "feature"])
      write!(repo, "packages/a/lib.ex", "one")
      commit!(repo, "feature")
      git!(repo, ["switch", "--quiet", "main"])
      merge = merge!(repo, "feature")
      write!(repo, "packages/a/mix.exs", "two")
      next = commit!(repo, "next")

      assert @git.first_parents(repo, base, next) == [merge, next]
    end

    test "raises when the start is not on the first-parent line, as for a branch that merged main",
         %{repo: repo} do
      git!(repo, ["switch", "--quiet", "--create", "feature"])
      write!(repo, "packages/a/lib.ex", "one")
      commit!(repo, "feature")
      git!(repo, ["switch", "--quiet", "main"])
      write!(repo, "packages/a/mix.exs", "two")
      main = commit!(repo, "main")
      git!(repo, ["switch", "--quiet", "feature"])
      feature = merge!(repo, "main")

      assert_raise RuntimeError, "#{main} is not on #{feature}'s first-parent line", fn ->
        @git.first_parents(repo, main, feature)
      end
    end

    test "is empty when the start is the end", %{repo: repo, base: base} do
      assert @git.first_parents(repo, base, base) == []
    end

    test "raises when git cannot read a commit", %{repo: repo, base: base} do
      assert_raise RuntimeError,
                   "git rev-list --first-parent --reverse #{base}..nothing exited with 128",
                   fn -> @git.first_parents(repo, base, "nothing") end
    end
  end

  describe "changed_files/2" do
    test "lists files from the repository's root, whatever diff.relative says", %{repo: repo} do
      write!(repo, "packages/a/CHANGELOG.md", "## [Unreleased]\n\n- A line.\n")
      commit = commit!(repo, "edit")
      git!(repo, ["config", "diff.relative", "true"])

      assert @git.changed_files(Path.join(repo, "packages/a"), commit) == [
               "packages/a/CHANGELOG.md"
             ]
    end

    test "lists a renamed file's old and new paths, and a path git would quote as it is", %{
      repo: repo
    } do
      git!(repo, ["mv", "packages/a/CHANGELOG.md", "packages/a/CHANGES.md"])
      write!(repo, "packages/é/CHANGELOG.md", "## [Unreleased]\n")
      commit = commit!(repo, "rename")

      assert Enum.sort(@git.changed_files(repo, commit)) == [
               "packages/a/CHANGELOG.md",
               "packages/a/CHANGES.md",
               "packages/é/CHANGELOG.md"
             ]
    end
  end

  describe "file/3" do
    test "reads a file a commit holds, from the repository's root", %{repo: repo, base: base} do
      assert @git.file(Path.join(repo, "packages"), base, "packages/a/CHANGELOG.md") ==
               "## [Unreleased]\n"
    end

    test "is nil for a file the commit does not hold", %{repo: repo, base: base} do
      assert @git.file(repo, base, "packages/b/CHANGELOG.md") == nil
    end
  end

  defp write!(repo, path, content) do
    path = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp commit!(repo, message) do
    git!(repo, ["add", "--all"])
    git!(repo, author() ++ ["commit", "--quiet", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp merge!(repo, branch) do
    git!(repo, author() ++ ["merge", "--quiet", "--no-ff", "-m", "merge", branch])
    git!(repo, ["rev-parse", "HEAD"])
  end

  # With no global configuration (test_helper.exs), the commit's author is given here.
  defp author, do: ["-c", "user.name=Test", "-c", "user.email=test@example.com"]

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(output)
  end
end

defmodule EhosRelease.GitImplTest do
  # The implementation at the bottom, against a repository of the test's own.
  use ExUnit.Case, async: true

  alias EhosRelease.GitImpl

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    git(dir, ["init", "-q", "-b", "main"])
    File.mkdir_p!(Path.join(dir, ".github/workflows"))
    File.write!(Path.join(dir, ".github/workflows/ci.yml"), "jobs: {}\n")
    File.write!(Path.join(dir, "mix.lock"), "%{}\n")
    git(dir, ["add", "."])
    git(dir, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "one"])
    :ok
  end

  test "reads a file as a commit has it, and says when the commit has none", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "mix.lock"), "changed since\n")

    assert GitImpl.show(dir, "HEAD", "mix.lock") == {:ok, "%{}\n"}
    assert GitImpl.show(dir, "HEAD", "pins.json") == :missing
  end

  test "lists the files under a directory as a commit has them", %{tmp_dir: dir} do
    assert GitImpl.files(dir, "HEAD", ".github/workflows") == {:ok, [".github/workflows/ci.yml"]}
  end

  defp git(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args])
end

defmodule Mix.Tasks.Review do
  @shortdoc "Records or checks that the checked-out commit was reviewed"

  @moduledoc """
  Records that the checked-out commit was reviewed, and checks it before a pull request is opened.

      $ mix review record   # after the reviews, their fixes and `mix check`
      $ mix review check    # fails when HEAD is not marked as reviewed
      $ mix review gate     # the same check, as a Claude Code PreToolUse hook

  `record` and `check` act on the repository this package is in, whichever worktree of it is
  checked out here. `gate` reads the hook's input from standard input and, for a command that opens
  a pull request, checks the working tree that command runs in (`Review.gate/1`). It exits with
  status 2, which makes Claude Code refuse the command and show why. The hook in
  `.claude/settings.json` runs it for Bash commands that mention `gh pr create`.

  See `Review` for how a review is recorded, and the `pre-pr-review` skill in `.claude/skills/`
  for the review itself.
  """

  use Mix.Task

  @impl Mix.Task
  def run(["record"]) do
    case Review.record() do
      {:ok, message} -> Mix.shell().info(message)
      {:error, message} -> Mix.raise(message)
    end
  end

  def run(["check"]) do
    case Review.check() do
      :ok -> Mix.shell().info("HEAD is marked as reviewed")
      {:error, message} -> Mix.raise(message)
    end
  end

  def run(["gate"]) do
    case :stdio |> IO.read(:eof) |> to_string() |> Review.gate() do
      :ok ->
        :ok

      {:error, message} ->
        # Exit status 2 is how a PreToolUse hook blocks a command; its stderr reaches Claude.
        IO.puts(:stderr, message)
        exit({:shutdown, 2})
    end
  end

  def run(_args), do: Mix.raise("Usage: mix review record | check | gate")
end

defmodule Mix.Tasks.Review do
  @shortdoc "Records or checks that the checked-out commit was reviewed"

  @moduledoc """
  Records that the checked-out commit was reviewed, and checks it before a pull request is opened.

      $ mix review record         # after the reviews, their fixes and `mix check`
      $ mix review check          # fails when HEAD is not marked as reviewed
      $ mix review gate           # the same check, as a Claude Code PreToolUse hook
      $ mix review pull_request   # in CI: the description records the review

  `record` and `check` act on the repository this package is in, whichever worktree of it is
  checked out here. `gate` reads the hook's input from standard input and, for a command that opens
  a pull request, checks the working tree that command runs in (`Review.gate/1`). It exits with
  status 2, which makes Claude Code refuse the command and show why. The hook in
  `.claude/settings.json` runs it for a Bash call whose input names `gh`, then `pr`, then
  `create` or `new`, and the gate decides whether the command opens a pull request.

  `pull_request` reads a pull request's description from `PULL_REQUEST_BODY` and fails unless
  it records the author's review (`Review.pull_request_body/1`). The `review` workflow runs it
  on every pull request, and again whenever its description is edited.

  See `Review` for how a review is recorded, and the `ehos-dev:pre-pr-review` skill, with this
  repository's part in `.claude/review.md`, for the review itself.
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

      # Exit status 2 is how a PreToolUse hook blocks a command; its stderr reaches Claude.
      {:error, message} ->
        Mix.raise(message, exit_status: 2)
    end
  end

  # The description comes in an environment variable, which the workflow sets from the event,
  # so it never passes through a shell.
  def run(["pull_request"]) do
    case "PULL_REQUEST_BODY" |> System.get_env() |> Review.pull_request_body() do
      :ok -> Mix.shell().info("The pull request's description records its review")
      {:error, message} -> Mix.raise(message)
    end
  end

  def run(_args), do: Mix.raise("Usage: mix review record | check | gate | pull_request")
end

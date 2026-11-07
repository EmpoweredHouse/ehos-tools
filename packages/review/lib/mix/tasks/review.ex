defmodule Mix.Tasks.Review do
  @shortdoc "Records or checks that the checked-out commit was reviewed"

  @moduledoc """
  Records that the checked-out commit was reviewed, and checks it before a pull request is opened.

      $ mix review record         # after the reviews, their fixes and `mix check`
      $ mix review check          # fails when HEAD is not marked as reviewed
      $ mix review gate           # the same check, as a Claude Code PreToolUse hook
      $ mix review pull_request   # in CI: the description records the review
      $ mix review plugins        # this machine holds the plugins the repository pins

  Each exits with status 0 when it passes, or prints why it refuses and exits with status 1 (2
  for `gate`), and any other argument prints how to use the task. `record` and `check` act on
  the repository this package is in, whichever worktree of it is checked out here
  (`Review.record/1`, `Review.check/1`). `gate` reads the hook's input from standard input and,
  for a command that opens a pull request, checks the working tree that command runs in
  (`Review.gate/1`). It refuses with status 2, which makes Claude Code refuse the command and
  show why. The hook in `.claude/settings.json` runs it for a Bash call whose input names `gh`,
  then `pr`, then `create` or `new`, and the gate decides whether the command opens a pull
  request.

  `pull_request` reads a pull request's description from `PULL_REQUEST_BODY` and fails unless
  it records the author's review (`Review.pull_request_body/1`). The `review` workflow runs it
  on every pull request, and again whenever its description is edited.

  `plugins` fails while this machine holds other plugins than `.claude/settings.json` pins, and
  prints the commands that move it (`EhosApp.Plugins.check/2`, T-22). The `SessionStart` hook in
  `.claude/settings.json` runs it at the start of each session, and `gate` refuses a pull request
  for the same reason.

  See `Review` for how a review is recorded, and the `ehos-dev:pre-pr-review` skill, with this
  repository's part in `.claude/review.md`, for the review itself.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args), do: EhosApp.Review.run_task(args, "review", Review.options())
end

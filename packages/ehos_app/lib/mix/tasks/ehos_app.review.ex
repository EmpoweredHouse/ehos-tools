defmodule Mix.Tasks.EhosApp.Review do
  @shortdoc "Records or checks that the checked-out commit was reviewed"

  @moduledoc """
  Records that the application's checked-out commit was reviewed, and checks it before a pull
  request is opened.

      $ MIX_ENV=dev mix ehos_app.review record        # after the reviews, their fixes, precommit
      $ MIX_ENV=dev mix ehos_app.review check         # fails when HEAD is not marked as reviewed
      $ MIX_ENV=dev mix ehos_app.review gate          # the same check, as a PreToolUse hook
      $ MIX_ENV=dev mix ehos_app.review pull_request  # in CI: the description records the review
      $ MIX_ENV=dev mix ehos_app.review plugins       # this machine holds the pinned plugins

  Each exits with status 0 when it passes, or prints why it refuses and exits with status 1 (2
  for `gate`), and any other argument prints how to use the task. `record` and `check` act on
  the repository the application is in, whichever worktree of it is checked out here. `gate`
  reads the hook's input from standard input and, for a command that opens a pull request,
  checks the working tree that command runs in (`EhosApp.Review.gate/1`).
  It exits with status 2, which makes Claude Code refuse the command and show why. The hook the
  installer writes into `.claude/settings.json` runs it for a Bash call whose input names `gh`,
  then `pr`, then `create` or `new`, and the gate decides whether the command opens a pull
  request.

  For Codex, use `record --harness codex` and `check --harness codex`. These verify the installed
  filesystem skills' source pins and recorded hashes without consulting Claude's cache.
  Missing, stale or edited copies must be reconciled with `.agents/ehos-skills.json` first.
  The Codex check also requires a clean working tree; review marks still cover one commit.

  `pull_request` reads a pull request's description from `PULL_REQUEST_BODY` and fails unless it
  records the author's review (`EhosApp.Review.pull_request_body/1`). The `review` workflow the
  installer writes runs it on every pull request, and again whenever its description is edited.

  `plugins` fails while this machine holds other plugins than `.claude/settings.json` pins, and
  prints the commands that move it (`EhosApp.Plugins.check/2`); `gate` refuses a pull request for
  the same reason.

  `ehos_app` is a dependency in `:dev` only, so the task runs there: the hook and the workflow
  set `MIX_ENV=dev`. See `EhosApp.Review` for how a review is recorded, and the
  `ehos-app:pre-pr-review` skill for the review itself.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args), do: EhosApp.Review.run_task(args, "ehos_app.review")
end

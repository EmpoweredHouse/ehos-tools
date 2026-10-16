# review

The review gate of ehos-tools: it records that a commit was reviewed by its author, and refuses a
pull request from one that was not. It is a tool for working on this repository, never released
or depended on. The gate itself is `EhosApp.Review`, in `packages/ehos_app`, the one every
application `ehos_app` generates has: this package depends on it by path and gives it ehos-tools'
marks and messages ([T-17](../../docs/adr/0017-an-application-s-review-gate-is-ehos-app-s-tasks-a-hook-its-installer-writes-and-a-skill-an-assistant-runs.md)),
so a change to how the gate reads a command is made there, and tested there.

```sh
cd packages/review
mix review record   # after the reviews, their fixes and `mix check`
mix review check    # fails when HEAD is not marked as reviewed
mix review gate     # the same check, as a Claude Code PreToolUse hook
PULL_REQUEST_BODY="$(cat body.md)" mix review pull_request   # CI's check of a description
```

The review itself is the `ehos-dev:pre-pr-review` skill, from the `ehos-dev` plugin, with this
repository's part in `.claude/review.md`. The hook in
`.claude/settings.json` runs `mix review gate` for a Bash call whose input names `gh`, then `pr`,
then `create` or `new`. The gate refuses a command that opens a pull request (`gh pr create`, or
its alias `gh pr new`, however spaced or continued) while `HEAD` carries no mark, one that names
another branch or repository (`--head`, `--repo`, `GH_REPO`), and one that changes directory
before any pull request it opens in a way it cannot follow.

A mark is an empty file named after the commit, under `ehos-tools-review/` in the repository's
common git directory, so every worktree sees it and a new commit, amend or rebase needs a new
review.

It also refuses a command that, before it opens the pull request, moves HEAD (`git commit`,
`checkout`, `switch`, `rebase`, `pull`, `merge`, `reset`, `am`, `cherry-pick`, `revert`, `bisect`,
`filter-branch`, `update-ref HEAD`, `symbolic-ref HEAD <ref>`, `gh pr checkout`, `gh repo sync`)
or points git elsewhere (`GIT_DIR=`, `GIT_WORK_TREE=`): the gate reads HEAD before the command
runs, so what such a command sends is not what was reviewed. A script, a Mix alias or a git alias
that commits is not seen; open the pull request with a command of its own. A command that names
`gh` and is longer than 64 KiB is refused unread. The gate reads `gh pr` (gh by any path) word by
word: the word right after `pr` is gh's subcommand when it is one of gh's, so
`gh pr checkout new-feature` opens nothing. When a flag comes first, gh takes it as the
subcommand's, with a value of any shape (`gh pr --title "review it" create`), so the command opens
a pull request if `create` or `new` comes anywhere after `gh pr` in it. `update-ref` of the
branch HEAD is on, rather than of HEAD, is not seen.

The gate reads shell text, so it guards against an honest mistake, not an adversary. It does not
see a pull request opened through the API (`gh api`) or by a tool other than Bash, or a push to an
open pull request. It fails closed: input it cannot read, a directory change it cannot follow, a
regex that gives up at its match limit, or a gate that does not run (no `mix`, a compile error)
refuses the command. The one way it fails open is the hook's timeout, 120 s, past which Claude
Code runs the command: the gate takes about 0.4 s, and 0.5 s on its first run, when it compiles.
It reads every command of up to 64 KiB we have tried, the ones built to slow it down included,
in under 0.2 s, and none longer, so only a wait on Mix's build lock, while another `mix` holds it
in `packages/review`, could come near the timeout.

Where the pull request lands, CI checks what the hook cannot: `mix review pull_request`, in the
`review` workflow, fails while the pull request's description has no `## Review` section, or an
empty one ([T-03](../../docs/adr/0003-ci-checks-that-a-pull-request-records-its-authors-review.md)).
It runs again whenever the description is edited.

Both are ported from EHOS's `Ehos.Dev.Review`
([eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/lib/ehos/dev/review.ex)).

# review

The review gate of ehos-tools: it records that a commit was reviewed by its author, and refuses a
pull request from one that was not. It is a tool for working on this repository, never released
or depended on.

```sh
cd packages/review
mix review record   # after the reviews, their fixes and `mix check`
mix review check    # fails when HEAD is not marked as reviewed
mix review gate     # the same check, as a Claude Code PreToolUse hook
PULL_REQUEST_BODY="$(cat body.md)" mix review pull_request   # CI's check of a description
```

The review itself is the `pre-pr-review` skill (`.claude/skills/pre-pr-review/`). The hook in
`.claude/settings.json` runs `mix review gate` for a Bash call whose input names `gh`, then `pr`,
then `create` or `new`. The gate refuses a command that opens a pull request (`gh pr create`, or
its alias `gh pr new`, however spaced or continued) while `HEAD` carries no mark, one that names
another branch or repository (`--head`, `--repo`, `GH_REPO`), and one that changes directory
before any pull request it opens in a way it cannot follow.

A mark is an empty file named after the commit, under `ehos-tools-review/` in the repository's
common git directory, so every worktree sees it and a new commit, amend or rebase needs a new
review.

The gate reads shell text, so it guards against an honest mistake, not an adversary. It does not
see a pull request opened through the API (`gh api`) or by a tool other than Bash, a push to an
open pull request, or a commit made in the same command before the pull request is opened
([#21](https://github.com/EmpoweredHouse/ehos-tools/issues/21)). It fails closed: input it
cannot read, a directory change it cannot follow, or a gate that does not run (no `mix`, a
compile error) refuses the command.

Where the pull request lands, CI checks what the hook cannot: `mix review pull_request`, in the
`review` workflow, fails while the pull request's description has no `## Review` section, or an
empty one ([T-03](../../docs/adr/0003-ci-checks-that-a-pull-request-records-its-authors-review.md)).
It runs again whenever the description is edited.

Ported from EHOS's `Ehos.Dev.Review`
([eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/lib/ehos/dev/review.ex)).

# review

The review gate of ehos-tools: it records that a commit was reviewed by its author, and refuses a
pull request from one that was not. It is a tool for working on this repository, never released
or depended on.

```sh
cd packages/review
mix review record   # after the reviews, their fixes and `mix check`
mix review check    # fails when HEAD is not marked as reviewed
mix review gate     # the same check, as a Claude Code PreToolUse hook
```

The review itself is the `pre-pr-review` skill (`.claude/skills/pre-pr-review/`). The hook in
`.claude/settings.json` runs `mix review gate` for any Bash command that names the command that
opens a pull request, and refuses it while `HEAD` carries no mark. A mark is an empty file named
after the commit, under `ehos-tools-review/` in the repository's common git directory, so every
worktree sees it and a new commit, amend or rebase needs a new review.

Ported from EHOS's `Ehos.Dev.Review`
([eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/lib/ehos/dev/review.ex)).

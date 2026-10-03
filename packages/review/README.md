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
`gh pr checkout`, `gh repo sync`) or points git elsewhere (`GIT_DIR=`, `GIT_WORK_TREE=`): the gate
reads HEAD before the command runs, so what such a command sends is not what was reviewed. A
script, a Mix alias or a git alias that commits is not seen; open the pull request with a command
of its own. A command that names `gh` and is longer than 64 KiB is refused unread.

The gate reads shell text, so it guards against an honest mistake, not an adversary. It does not
see a pull request opened through the API (`gh api`) or by a tool other than Bash, or a push to an
open pull request. It fails closed: input it cannot read, a directory change it cannot follow, a
regex that gives up at its match limit, or a gate that does not run (no `mix`, a compile error)
refuses the command. The one way it fails open is the hook's timeout, 120 s, past which Claude
Code runs the command: the gate takes about 0.4 s, and 0.5 s on its first run, when it compiles.
The longest command it reads takes it at most about 12 s, which is why it reads none longer, so
only a wait on Mix's build lock, while another `mix` holds it in `packages/review`, could come
near the timeout.

Ported from EHOS's `Ehos.Dev.Review`
([eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/lib/ehos/dev/review.ex)).

# Changelog

All notable changes to `review` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package is never released, so
it has no versions: everything is under `Unreleased`.

## [Unreleased]

### Added

- `mix review record | check | gate`, the review gate, ported from EHOS's `mix ehos.review`, and
  the Claude Code hook that runs `gate` before a pull request is opened. Beyond the original, the
  gate knows `gh pr new` and the command however spaced or continued, refuses a pull request for
  another branch or repository (`--head`, `--repo`, `GH_REPO`), follows a `cd` before every pull
  request a command opens, and reads only what comes before the last one for it, so a body that
  mentions `cd` is not refused.
- The gate refuses a command that moves HEAD before it opens the pull request (`git commit`,
  `checkout`, `rebase` and the like, `gh pr checkout`) or sets `GIT_DIR` or `GIT_WORK_TREE`, since
  it reads HEAD before the command runs ([#21](https://github.com/EmpoweredHouse/ehos-tools/issues/21)),
  and a command longer than 64 KiB, which it would take too long to read. The README says how
  long the gate takes, against the hook's timeout.

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
- `mix review pull_request`, which fails unless the pull request's description (from
  `PULL_REQUEST_BODY`) has a `## Review` section with something in it, and the `review` workflow
  that runs it on every pull request and edit of its description
  ([T-03](../../docs/adr/0003-ci-checks-that-a-pull-request-records-its-authors-review.md),
  [#20](https://github.com/EmpoweredHouse/ehos-tools/issues/20)).
- The gate refuses a command that moves HEAD before it opens the pull request (`git commit`,
  `checkout`, `rebase`, `bisect` and the like, `gh pr checkout`, `gh repo sync`) or sets `GIT_DIR`
  or `GIT_WORK_TREE`, since it reads HEAD before the command runs
  ([#21](https://github.com/EmpoweredHouse/ehos-tools/issues/21)). It refuses a command that names
  `gh` and is longer than 64 KiB, which it would take too long to read, and one that makes a
  regex give up at its match limit, which Erlang otherwise reports as no match. The README says
  how long the gate takes, against the hook's timeout.
- gh's subcommand is read as its first word after `pr` that is neither a flag nor a flag's value,
  so a branch named like one (`gh pr checkout new-feature`) no longer reads as opening a pull
  request, while `gh pr --head x create` still does. `git filter-branch`, `update-ref HEAD` and
  `symbolic-ref HEAD <ref>` before the opening are refused; the reading forms pass. `env -C` is
  found quoted, in `$( )`, by its path, bundled (`-iC`) and continued. Commands built to slow the
  gate down, which took up to 12 s at 64 KiB, take under 0.1 s
  ([#27](https://github.com/EmpoweredHouse/ehos-tools/issues/27)).

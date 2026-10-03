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

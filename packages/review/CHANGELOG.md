# Changelog

All notable changes to `review` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package is never released, so
it has no versions: everything is under `Unreleased`.

## [Unreleased]

### Added

- `mix review record | check | gate`, the review gate, ported from EHOS's `mix ehos.review`, and
  the Claude Code hook that runs `gate` before a pull request is opened.

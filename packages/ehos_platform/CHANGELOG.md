# Changelog

All notable changes to `ehos_platform` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that does starts with **Breaking:**.

## [Unreleased]

## [0.1.0] - 2026-10-12

### Added

- The installation code of EHOS, moved from eh-os's `Ehos.Dev` (eh-os D-92, eh-os#404):
  `EhosPlatform.Server` makes, reaches and removes the server under an installation with
  OpenTofu, k3s and an SSH tunnel; `EhosPlatform.Install` installs the prerequisites, the
  installation's CA and EHOS's chart; `EhosPlatform.CommandRunner` runs the programs they need.
- `EhosPlatform.Source`: what is installed, either an eh-os checkout or what a release's
  `release.json` names. A release's modules' archive is refused, and nothing unpacked, unless its
  SHA-256 is the one named and it holds only files and directories under `deploy/tofu/`.

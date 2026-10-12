# Changelog

All notable changes to `ehos_platform` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that does starts with **Breaking:**.

## [Unreleased]

### Added

- `ehos_platform` is licensed under the Apache License 2.0, as the rest of ehos-tools
  ([LICENSE](https://github.com/EmpoweredHouse/ehos-tools/blob/main/LICENSE)).

## [0.2.0] - 2026-10-12

### Added

- `EhosPlatform.Tools`: the versions of OpenTofu, Helm and kubectl EHOS is tested with, for a
  caller that runs them pinned (T-13, #146).
- `EhosPlatform.Server.status/1` reports the node's CPUs, memory and load, read from `/proc`
  before Kubernetes is asked, so they are reported with k3s or EHOS stopped; a Kubernetes that
  does not answer is said so instead of failing the command (#153).
- `EhosPlatform.Server`'s `:command` and `:name_option`: how the caller's operator runs these
  commands, which its sentences name, `mix ehos.server` and `--name` unless given (#153).
- `EhosPlatform.Server.valid_passphrase?/1`, the rule `EHOS_STATE_PASSPHRASE` is held to, and
  `status_report/1`, which puts `status`'s reading of the node into words (#153).
- `EhosPlatform.Install.server/1`'s `:installed` records what runs, its `version`, `image` and
  `chart`, in the Helm release's values (eh-os D-92, #161). `installed/1` reads it back through the
  installation's kubeconfig, from the release's last deployed revision, found in its history (#164):
  what runs (none, unknown, or what was recorded), the image's digest and the console's host that
  revision runs, and the last revision when it is another, with its status. A release's chart,
  private in GHCR, is pulled by its digest with `GHCR_TOKEN`, which Helm is given in a registry
  configuration only the user reads, for the pull alone, and is then required. Its sentences name
  the server's command as `:server_command` gives it.

## [0.1.0] - 2026-10-12

### Added

- The installation code of EHOS, moved from eh-os's `Ehos.Dev` (eh-os D-92, eh-os#404):
  `EhosPlatform.Server` makes, reaches and removes the server under an installation with
  OpenTofu, k3s and an SSH tunnel; `EhosPlatform.Install` installs the prerequisites, the
  installation's CA and EHOS's chart; `EhosPlatform.CommandRunner` runs the programs they need.
- `EhosPlatform.Source`: what is installed, either an eh-os checkout or what a release's
  `release.json` names. A release's modules' archive is refused, and nothing unpacked, unless its
  SHA-256 is the one named and it holds only files and directories under `deploy/tofu/`.

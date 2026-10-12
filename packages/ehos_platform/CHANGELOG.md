# Changelog

All notable changes to `ehos_platform` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that does starts with **Breaking:**.

## [Unreleased]

### Added

- `EhosPlatform.Server` and `EhosPlatform.Install` take `:name_in_commands`: the commands their
  sentences suggest, such as opening the tunnel, then name the installation with `:name_option`
  (`--name` unless given), so that they reach the same server whatever the operator's default
  installation is when they run them (#194).
- `EhosPlatform.Install.invite/1` invites a person on an installation's server with EHOS's
  release command, `Ehos.Release.invite/1`, through the tunnel's kubeconfig, and returns the
  sign-in link EHOS printed. `EhosPlatform.Install.email/1` checks an address as EHOS does, and
  `EhosPlatform.Install.invite_expression/1` writes it into the expression as an Elixir string
  literal, parsed back to check it is that one call (#197).

### Changed

- The sentences of `EhosPlatform.Server` that say to run `up` again, when SSH does not answer,
  when a plan would replace the server, or when the module did not say an output, name the whole
  command, `mix ehos.server up` or the caller's `:command`, where they named `up` alone (#194).
- `EhosPlatform.Install.server/1` ends by naming `<server_command> invite <their email>
  --installation <name>` to invite the first person, instead of a line of `kubectl` (#197).

## [0.3.0] - 2026-10-12

### Added

- `ehos_platform` is licensed under the Apache License 2.0, as the rest of ehos-tools
  ([LICENSE](https://github.com/EmpoweredHouse/ehos-tools/blob/main/LICENSE)).
- `EhosPlatform.Install.pull_credential/1` says whether `ehos-system` holds the pull credential,
  `{:ok, true | false}`, or that kubectl could not say (#174).

### Deprecated

- `EhosPlatform.Install.pull_credential?/1`, which reads any failure to ask as no credential: use
  `pull_credential/1` (#174). It is deprecated in its documentation, so a caller that compiles
  with warnings as errors still builds.

### Fixed

- An install with no `GHCR_TOKEN` that could not ask the cluster for its pull credential, as when
  it did not answer, said to set `GHCR_TOKEN`; it says what kubectl answered and installs nothing
  (#174).

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

# Changelog

All notable changes to `ehos_platform` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that does starts with **Breaking:**.

## [Unreleased]

### Changed

- **Breaking:** `EhosPlatform.Server.up/1` refuses an installation not made yet without
  `:provider`, where it took Oracle's; `down/1`, `tunnel/1`, `status/1` and `remote/2` say such an
  installation is not made
  ([#343](https://github.com/EmpoweredHouse/ehos-tools/issues/343)).

## [0.5.3] - 2026-10-20

### Fixed

- The fields of the console's Certificate that cert-manager's ingress-shim set become Helm's apply,
  not only Helm's name (eh-os D-117): server-side apply counts an update renamed `helm` as another
  owner than Helm's apply, so an upgrade from a release before D-117 still failed on the labels
  whose values the chart changes. 0.5.2's fix did not reach its aim; an installation it left that
  way is taken over the same way on the next run.

## [0.5.2] - 2026-10-20

### Fixed

- The console's Certificate handed over to EHOS's chart (eh-os D-117) is also handed Helm's field
  ownership: Helm 4 installs by server-side apply as the field manager `helm`, and was refused the
  labels cert-manager's ingress-shim had applied, so an upgrade from a release before D-117 still
  failed. The shim's entries among the Certificate's managed fields are renamed `helm`'s.

## [0.5.1] - 2026-10-20

### Fixed

- `adopt_console_certificate/3` hands over the console's Certificate that cert-manager made for the
  console's Ingress, which 0.5.0 took for Helm's (eh-os D-117): cert-manager gives it the Ingress's
  labels, `app.kubernetes.io/managed-by: Helm` among them, so it is now told by its owner, the
  Ingress. Upgrading an installation made before D-117 failed on Helm's ownership check.

## [0.5.0] - 2026-10-19

### Added

- **`EhosPlatform.Install.keep_client_addresses/1`** (eh-os D-117): `prerequisites/1` has k3s's
  bundled Traefik keep each client's own address, with a `HelmChartConfig` setting its Service to
  `externalTrafficPolicy: Local`, so the PROXY protocol header Traefik sends the governance plane
  names the client and the governance plane can hold each client to its share of the console's
  connections. Not on a cluster that is not k3s, nor over a Traefik `HelmChartConfig` someone else
  wrote, which is said instead.
- **`EhosPlatform.Install.adopt_console_certificate/3`** (eh-os D-117): before EHOS's chart is
  installed, the console's Certificate that cert-manager made for the console's Ingress is marked as
  the release's and freed from the Ingress, since from the release that carries D-117 the chart
  makes it itself under the same name, which Helm would refuse to take over. `chart/2` does it,
  and only when the chart it installs makes the Certificate, so an installation made before is
  upgraded with the console served throughout and one reinstalled with its old chart is left as it
  is. Installing a chart from before D-117 over one after makes Helm delete the Certificate and its
  Secret: the console has no certificate until cert-manager issues one again for the Ingress.
- **`EhosPlatform.Install.tunnel_address/1`, `sslip_host/1` and `sslip_address/1`**: the address
  the installation's tunnel goes to, and the console's host of sslip.io for an address and the
  other way round. `EhosPlatform.Server.up/1` says when the server's address changed (eh-os
  D-124), and requires the server's known host key at the new address. The old address is kept
  in the installation's `previous_address` until the server is reached at the new one, so a run
  that stops in between still says it on the next.
- **`EhosPlatform.Install.permits_only?/2`**: whether the installation's CA permits one host alone.
- **`EhosPlatform.Install.server/1` takes `:four_eyes`** (eh-os D-105, ehos-tools#296): whether a
  promotion to production needs a second person, written into the chart's
  `governance.promotion.fourEyes`. `installed/1` reads it back as `:four_eyes`, however the running
  revision was given it, so an upgrade can keep it.
- **`EhosPlatform.Install.server/1` takes `:mail` and `:smtp_password`** (eh-os D-36,
  ehos-tools#298): the SMTP server, written into the chart's `governance.mail`, and its user's
  password, written into the Secret `ehos-smtp`, applied from a file only the user reads, as the
  pull credential is, after which the governance plane is restarted to read it; without one, the
  Secret the cluster holds is kept, and a user with neither is refused before anything changes.
  `installed/1` reads the server back as `:mail`, never the password, and as `:unreadable` where
  its settings are not ones `server/1` writes, as a hand-made `helm --set` may leave them. `mail_host?/1`,
  `mail_address?/1` and `mail_username?/1` say whether a value is one the chart and a header take.

- **`EhosPlatform.Install.server/1` takes `:sign_in`** (eh-os D-113), written into the chart's
  `governance.signIn`, and `installed/1` reads it back as `:sign_in`. `sign_in_limit?/1` says whether a value is
  one the chart takes.

### Fixed

- `EhosPlatform.Install.server/1` with another `:host` than the CA was issued for left the CA
  permitting the old host alone, so the console's and every application's certificates for the
  new one failed to verify. The CA is now issued again for the new host, with the same key, as it
  is when it lacks its IP exclusion (eh-os D-124).
- `EhosPlatform.Server.up/1` admits SSH from every address this machine was seen to leave from,
  asking three services twice each, and `:detect_address` may return a list. While SSH does not
  answer, and when it never does, the server's messages name the blocks admitted and say a
  network can leave through more than one address (#157).
- `EhosPlatform.Install.pull_credential/1` answers `{:ok, false}` when kubectl says the
  `ehos-system` namespace is not there, as on a cluster EHOS was never installed in, instead of
  saying kubectl could not tell. The first install on a new cluster, such as eh-os's
  `mix ehos.cluster up`, stopped there (#300).

## [0.4.0] - 2026-10-13

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
- `EhosPlatform.Install.server/1` ends by naming `<server_command> invite <their email>`, with
  the installation's option under `:name_in_commands`, to invite a person, instead of a line of
  `kubectl` (#197).

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

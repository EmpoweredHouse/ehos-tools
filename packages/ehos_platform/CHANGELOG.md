# Changelog

All notable changes to `ehos_platform` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that does starts with **Breaking:**.

## [Unreleased]

### Changed

- **Breaking:** `EhosPlatform.Clock` has a second callback, `utc_now/0`, the time a database's
  restart is marked with, so a test says what it is. An implementation of its own adds it;
  `EhosPlatform.ClockImpl` reads the system's time
  ([#680](https://github.com/EmpoweredHouse/ehos-tools/issues/680)).

### Fixed

- `Server.up/1` says which file it cannot write when it fails to carry a moved server's host key
  into `known_hosts`, as `{:error, message}`, where it returned `File.write/3`'s bare reason
  ([#535](https://github.com/EmpoweredHouse/ehos-tools/issues/535)).

- `Install.server/1` restarts each CloudNativePG cluster in `ehos-system` and `ehos-data` whose
  instance pods do not run with the priority class the cluster gives, one at a time, and waits
  until each is healthy on its new pods (`Install.restart_outdated_databases/1`). CloudNativePG
  gives a changed class only to a new pod, so an installation upgraded to EHOS 0.22.0 or later
  kept its databases without `ehos-platform` until each was restarted by hand. It says first that
  the console and an instance's applications are down while their cluster restarts, and leaves a
  cluster that is not healthy. It compares the pods with the spec, so a later upgrade restarts
  nothing
  ([#680](https://github.com/EmpoweredHouse/ehos-tools/issues/680)).

- `Server.up/1` records the path of the SSH key it logs in with in the installation's
  `installation.json`, never the key, from `~/` when it is under the operator's home (`HOME`), and
  every later command logs in with it unless given another `:ssh_key`; they took `~/.ssh/ehos_oci`.
  An Oracle installation made before the provider was recorded gets an `installation.json` with it.
  An installation `up` has not run on since keeps `~/.ssh/ehos_oci`, and `up` refuses to put that
  key on the server in place of another. A recorded key that is not a path is refused, and so are an
  `:ssh_key` that is not printable UTF-8 and a `.pub` that is not a public key. `tunnel/1` and
  `status/1` say before they connect when the key's `.pub` is not the one `up` put on the server.
  When the server refuses the key, the error names it and says to give the right one, or that the
  key `up` recorded is not on this machine, or, in `up`'s wait for the first boot, where to look;
  not that this machine's address changed
  ([#656](https://github.com/EmpoweredHouse/ehos-tools/issues/656)).

## [0.12.1] - 2026-10-29

### Changed

- An issue the code or a message names is named with its repository (`eh-os#218`,
  `ehos-tools#429`), since this package is read from eh-os as well as from ehos-tools: the
  installer's refusal for a missing `GHCR_TOKEN` now says `eh-os#218`, not `#218`
  ([#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).

### Fixed

- `prerequisites/1` gives cert-manager's controller, cainjector and webhook, trust-manager and
  CloudNativePG's operator CPU and memory requests, 70m and 336Mi among the five, so the scheduler
  keeps room for them; they requested none. They set no limit, so the kernel's OOM killer, should
  memory run out before the kubelet acts, still picks them nearly first. An installation made with
  an earlier `ehos_platform` is upgraded the next time the installer runs, each of the three
  releases once ([#576](https://github.com/EmpoweredHouse/ehos-tools/issues/576)).
- The `pkill -f` `Server` suggests for a tunnel that does not answer matches its ssh master alone,
  by the arguments it was started with, `-M -S <socket> -o ExitOnForwardFailure=yes`: the path
  alone also matched an `ssh -O check` that hung beside it, or any other command naming it
  ([#571](https://github.com/EmpoweredHouse/ehos-tools/issues/571)).
- The command `up/1` suggests for a missing or empty public key writes the file only once
  `ssh-keygen -y` succeeded, so a mistyped passphrase leaves no empty file behind, and with `>|`,
  so a shell under `noclobber` does not refuse to replace an empty one
  ([#571](https://github.com/EmpoweredHouse/ehos-tools/issues/571)).

## [0.12.0] - 2026-10-29

### Added

- `Install.server/1` warns, and goes on, when the cluster's API server runs a Kubernetes older
  than 1.37, on which EHOS's isolation policy, once deleted and made again, refuses every new
  environment's pods until the API server restarts. It reads the API server's own `/version`
  ([eh-os#923](https://github.com/EmpoweredHouse/eh-os/issues/923),
  [eh-os D-148](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0148-ehos-runs-on-kubernetes-1-37-a-new-server-gets-it-from-the-modules-and-the-servers-made-before-are-moved-by-hand-once.md),
  [#528](https://github.com/EmpoweredHouse/ehos-tools/issues/528)).
- `EhosPlatform.Shell`: `word/1` quotes a value as one word of a POSIX shell, and `pattern/1`
  escapes it as an extended regular expression, for the commands the platform and `ehosctl`
  suggest ([#568](https://github.com/EmpoweredHouse/ehos-tools/issues/568)).
- `EhosPlatform.Env`, `EhosPlatform.Clock` and `EhosPlatform.PublicAddress`: the process
  environment, waiting, and the services that say this machine's public address, each a
  behaviour with its implementation beside it (`EnvImpl`, `ClockImpl`, `PublicAddressImpl`), named
  in `opts[:env]` and `opts[:clock]` of `Server` and `Install`, and `opts[:public_address]` of
  `Server.up/1`
  ([T-20](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md),
  [#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).
- `Server.passphrase/1`: the state's passphrase, from `:passphrase` or `EHOS_STATE_PASSPHRASE`.

### Changed

- `EhosPlatform.Tools` pins `kubectl` 1.37.1 in place of 1.36.4, the Kubernetes EHOS runs on
  ([eh-os D-148](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0148-ehos-runs-on-kubernetes-1-37-a-new-server-gets-it-from-the-modules-and-the-servers-made-before-are-moved-by-hand-once.md),
  [#528](https://github.com/EmpoweredHouse/ehos-tools/issues/528)).
- The refusal of a cluster running k3s's bundled Traefik also names `gateway-api-crd` among what
  to disable: k3s 1.37 installs its Gateway API CRDs through a binding to cluster-admin, as it
  does its Traefik. Its k3d flags are quoted, so zsh does not take their `*` for a pattern
  ([eh-os D-148](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0148-ehos-runs-on-kubernetes-1-37-a-new-server-gets-it-from-the-modules-and-the-servers-made-before-are-moved-by-hand-once.md)).
- **Breaking:** `EhosPlatform.CommandRunner.System` is `EhosPlatform.CommandRunnerImpl`, in the
  behaviour's own file. A caller that names it as its default runner names the new module.
- **Breaking:** `Server` and `Install` take `:clock`, a module, in place of `:sleep`, a function;
  `Server.up/1` takes `:public_address`, a module, in place of `:detect_address`; and
  `Provider.variables/3`, `os_cloud/2` and `env/2` take `:env` as a module, not a function. A
  `:sleep` or a `:detect_address` still given raises `ArgumentError` naming what replaced it, and
  an `:env` that is not a module raises one that holds none of it.
- **Breaking:** `Provider.clouds_yaml/2` takes `OS_CLIENT_CONFIG_FILE`'s value and the home
  directory, both required, rather than a function that reads the environment.

### Fixed

- The commands `Server` suggests hold under any home, `/Users/Jane Doe` or `/Users/Jane O'Brien`
  among them: their paths are quoted for the shell when they need to be; `tunnel/1` suggests
  `kubectl --kubeconfig <path>`, which a `:` cannot split as it split `KUBECONFIG=<path>`; the
  `pkill -f` for a tunnel that does not answer escapes its path for the regular expression `pkill`
  reads; and `up/1` without a public key suggests writing it from the private key,
  `ssh-keygen -y -f <key> > <key>.pub`, when there is one, rather than `ssh-keygen -t ed25519`,
  which would offer to replace it. A `<key>.pub` that is empty is said to be, and has the same
  remedy, and one that cannot be read says why ([#566](https://github.com/EmpoweredHouse/ehos-tools/issues/566),
  [#568](https://github.com/EmpoweredHouse/ehos-tools/issues/568)).
- `Install.server/1` without `:source`, `invite/1` without `:email` and `chart/2` without
  `:repository`, `:digest` or `:ca_file` raise a `KeyError` that holds the key alone, rather than
  one that held every option, the token, the passphrase and `:registry_auth` among them. `server/1`
  checks `:source` before it reads or runs anything
  ([#543](https://github.com/EmpoweredHouse/ehos-tools/issues/543)).
- `Server.up/1` counts a public-address service whose ask crashed as that service's failure, and
  uses the others, rather than stopping on a `FunctionClauseError` in a caller that traps exits or
  exiting one that does not
  ([#544](https://github.com/EmpoweredHouse/ehos-tools/issues/544)).
- `prerequisites/1` runs cert-manager's controller, cainjector and webhook, trust-manager and
  CloudNativePG's operator as `system-cluster-critical`, as it ran Traefik, a class the kubelet's
  eviction never picks. Running as none, they were the first pods the kubelet evicted on a node
  short of memory, before EHOS's own (`ehos-platform`, from EHOS 0.22.0), although EHOS depends on
  them. The kernel's OOM killer still picks them first
  ([#576](https://github.com/EmpoweredHouse/ehos-tools/issues/576)). An installation made with an
  earlier `ehos_platform` is upgraded the next time the installer runs, each of the three releases
  once ([#500](https://github.com/EmpoweredHouse/ehos-tools/issues/500),
  [eh-os#1039](https://github.com/EmpoweredHouse/eh-os/issues/1039)).

## [0.11.0] - 2026-10-23

### Added

- `down/1`, and `up/1` with `:replace` when the plan removes the server, lift GCP's deletion
  protection from the server first: an apply on the server alone with the module's
  `deletion_protection` variable false, refused when it would change anything but that, and skipped
  when the protection is not on. A failure after it says the protection is lifted. AWS's provider
  lifts its own. Every other command runs with the module's own value, whatever
  `TF_VAR_deletion_protection` the shell sets. `Provider.deletion_protection?/1`,
  `protection_attribute/1`, `lifted_before_removal?/1` and `title/1` say which providers have it
  and how a person names them
  ([#430](https://github.com/EmpoweredHouse/ehos-tools/issues/430)).

### Fixed

- `prerequisites/1` upgrades its releases by server-side apply with `--force-conflicts`, taking back
  the fields anyone changed by hand. A `kubectl patch` on Traefik's Deployment had made its upgrade
  fail, and the revision before it, reading every Secret in the cluster, ran on. A release left as
  it is, deployed at its pin with its values, keeps them. It then refuses while Traefik's release
  has a ClusterRole or ClusterRoleBinding, or while the API server lets Traefik's service account
  list the cluster's Secrets or read those in `ehos-system`, whatever binding gives it that
  ([#429](https://github.com/EmpoweredHouse/ehos-tools/issues/429)).
- `server/1` warns when the cluster's nodes have less than two CPUs to allocate: EHOS's own pods
  request about one, and an application's grants Job and rollouts may then never be scheduled
  ([eh-os#892](https://github.com/EmpoweredHouse/eh-os/issues/892)).

## [0.10.0] - 2026-10-22

### Changed

- **Breaking:** Traefik reads only `ehos-ingress` and `ehos-addresses`, by Roles there, and no
  longer every namespace and every Secret in the cluster; it makes no IngressClass.
  `prerequisites/1` makes `ehos-addresses` before it, as EHOS's chart makes it and marked as that
  chart's, which takes it over. `server/1` refuses an EHOS release before 0.17.0, which keeps its
  console's route in `ehos-system`, changing nothing. Upgrading from an older EHOS, the console
  and its applications have no route from the moment Traefik is installed until the chart is:
  move to 0.17.0 with `ehosctl` 0.22 first
  ([eh-os#846](https://github.com/EmpoweredHouse/eh-os/issues/846)).
- **Breaking:** the installation's CA issues a certificate in `ehos-system` and `ehos-addresses`
  alone, no longer in an environment's namespace, where EHOS releases before 0.16.0 kept
  applications' addresses ([eh-os#846](https://github.com/EmpoweredHouse/eh-os/issues/846)).

## [0.9.0] - 2026-10-21

### Changed

- Traefik's CRD provider admits `ExternalName` Services, as its Ingress provider does, so the
  console's route can move to `ehos-ingress` and name the governance plane's Service from there.
  The installer's policy still admits such a Service only in `ehos-addresses` and `ehos-ingress`
  ([eh-os#846](https://github.com/EmpoweredHouse/eh-os/issues/846)).

## [0.8.0] - 2026-10-21

### Changed

- **Breaking:** `prerequisites/1` first applies an admission policy that admits an `ExternalName`
  Service only in `ehos-addresses` and `ehos-ingress`, whoever asks, since Traefik now follows one;
  and it installs no release while one made before is in another namespace, naming it
  ([eh-os#828](https://github.com/EmpoweredHouse/eh-os/issues/828)).
- The installation's CA issues a certificate in `ehos-addresses`, where EHOS keeps applications'
  addresses, for the names of the environment the certificate's `ehos.empowered.house/environment`
  label names, and still in an environment's own namespace; and Traefik's Ingress provider admits
  `ExternalName` Services, by which an address there reaches its application. An installation is
  given both, and the policy above, on its next `server/1`
  ([eh-os#828](https://github.com/EmpoweredHouse/eh-os/issues/828)).

## [0.7.0] - 2026-10-21

### Changed

- **Breaking:** `server/1` switches a server where k3s's bundled Traefik is installed, given
  `:switch_traefik`, and refuses it otherwise, changing nothing, since the switch takes the console
  and its applications down for a few minutes. What could still refuse is decided first. Over SSH,
  at the tunnel's address, a drop-in `/etc/rancher/k3s/config.yaml.d/ehos-traefik.yaml` adds
  `traefik` to k3s's `disable` list and k3s restarts, which takes its Traefik, its CRDs and every
  Traefik route out; once the cluster says they are gone, it installs as before. The SSH needs
  `:passphrase` (or `EHOS_STATE_PASSPHRASE`) and the server's key, `:ssh_key`. `prerequisites/1`
  still refuses such a cluster ([eh-os#823](https://github.com/EmpoweredHouse/eh-os/issues/823)).

## [0.6.0] - 2026-10-20

### Added

- `EhosPlatform.Install.no_bundled_traefik/1`: whether k3s's bundled Traefik is installed in the
  cluster, by its `traefik` and `traefik-crd` HelmCharts
  ([eh-os#762](https://github.com/EmpoweredHouse/eh-os/issues/762)).
- `EhosPlatform.Server.provider_named/1`: whether `up/1` would make the server in a cloud the
  operator named, read from the installation's files alone, so a caller refuses before it downloads
  anything, as `{:error, :invalid, _}` for what the command line can change and
  `{:error, :failed, _}` for a record that cannot be read
  ([#343](https://github.com/EmpoweredHouse/ehos-tools/issues/343), [#345](https://github.com/EmpoweredHouse/ehos-tools/issues/345)).
- `EhosPlatform.Server.Provider`'s `:ovh`, OVHcloud's Public Cloud ([eh-os D-127](https://github.com/EmpoweredHouse/eh-os/issues/742)): `:os_cloud` names
  the entry of OpenStack's `clouds.yaml`, which `clouds_yaml/2` finds and `os_cloud/2` checks; the
  region defaults to `GRA11`, the flavor is `:instance_type`, the project is pinned after the first
  apply and held by a plan that changes nothing before `down/1`, `tunnel/1` and `status/1`, and
  `env/2` takes every `OS_*` variable but the file's place out of OpenTofu's environment and
  hands it the file checked, absolute.
- `EhosPlatform.Install.installed/1`'s `:four_eyes_runs`: whether the deployed revision's server
  runs with four eyes on promotions, given or decided by the chart (eh-os D-128), read from what the
  revision applied ([#350](https://github.com/EmpoweredHouse/ehos-tools/issues/350)).

### Changed

- **Breaking:** `prerequisites/1` installs Traefik in `ehos-ingress` from its chart, 42.0.0, pinned
  by digest with the image of Traefik 3.7.15, and Traefik's CRDs from it, rather than relying on the
  one k3s bundles (eh-os D-117, [eh-os#762](https://github.com/EmpoweredHouse/eh-os/issues/762)). It
  and `server/1` refuse, before anything is written, a cluster where k3s's bundled Traefik is
  installed: one is made without it by `disable: [traefik]` in k3s's configuration, for k3d
  `--k3s-arg --disable=traefik@server:*`. The chart is installed with
  `environments.ingressController.namespace=ehos-ingress`, and the CoreDNS rule sends the
  installation's names to Traefik there.
- **Breaking:** `EhosPlatform.Server.up/1` refuses an installation not made yet without
  `:provider`, where it took Oracle's; `down/1`, `tunnel/1`, `status/1` and `remote/2` say such an
  installation is not made
  ([#343](https://github.com/EmpoweredHouse/ehos-tools/issues/343)).

### Removed

- **Breaking:** `EhosPlatform.Install.keep_client_addresses/1` and the `HelmChartConfig` it applied
  to k3s's Traefik: the Service of the Traefik `prerequisites/1` installs keeps clients' addresses
  itself ([eh-os#762](https://github.com/EmpoweredHouse/eh-os/issues/762)).

### Fixed

- `made?/1`, `down/1`, `tunnel/1`, `status/1` and `remote/2` take an installation as made only once
  `up/1` recorded where its server is (or an Oracle one made before D-83): variables alone, which
  an older `up` that stopped before anything was made left, are none, even with `:provider`
  given, so OpenTofu never runs against an empty state for them ([#345](https://github.com/EmpoweredHouse/ehos-tools/issues/345)).

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

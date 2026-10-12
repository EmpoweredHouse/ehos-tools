# Changelog

All notable changes to `ehosctl` are recorded here by hand, each in the pull request that makes
it, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehosctl` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that breaks something starts with
`**Breaking:**`. Between releases the version is the next minor's `-dev`. A release's section is
the notes of its GitHub release, tagged `vX.Y.Z`
([releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)).

A release pins one template (`lib/ehosctl/template.ex`), so every change to a pin is listed here:
it changes what `ehosctl init` generates.

## [Unreleased]

### Added

- `ehosctl doctor`: whether this machine can run the platform commands that make a server and
  install EHOS on it. It reports OpenTofu, Helm and kubectl at the versions EHOS is tested with,
  with the `mise install` command for each one missing, `ssh`, the cloud accounts it can see
  (Oracle Cloud, AWS, GCP), named but never printed, and whether `GHCR_TOKEN` is set. It exits 0
  when ready, 1 otherwise, and installs nothing (T-13, eh-os#406).
- `ehosctl login` keeps the CA `EHOSCTL_CA_FILE` names beside the installation, and every later
  command to that installation trusts it, so the variable is needed once, at `login`, and not on
  every command. `installations list` says which installation has a CA of its own (T-14, #148).

### Changed

- A TLS handshake that fails says to sign in with `EHOSCTL_CA_FILE` set to the installation's CA,
  for a server as for a local EHOS, and names the CA kept for the installation when that one did
  not sign the certificate.

## [0.4.0] - 2026-10-12

### Added

- `ehosctl deploy <application> --env E --manifest F --preview`: what deploying the manifest
  would do, as the console's deploy page shows it before it is confirmed, and deploys nothing:
  both digests and the version in force, whether the deployment registers the application, what
  its authority adds and takes away (in `ehosctl apps review`'s words), whether it also needs
  `ehos.application.register`, each need's binding, what it changes in sign-in and in reading the
  people, and every reason it would be refused. It exits 0 when the deployment would be taken and
  1 when it would be refused (eh-os#373). `--image`, which only deploying needs, is refused with
  it. `--json` prints the preview.
- `ehosctl terminals`: your terminals signed in with `ehosctl login`, newest first, as your
  settings in the console list them: when each signed in, was last used and ends at the latest,
  and its id (ehos-tools#111).
- `ehosctl terminals sign-out <id>`: signs one of your terminals out, as the console does; its
  commands stop within ten minutes.
- `ehosctl people sign-out <email|id>`: a people manager signs out every terminal of a person,
  without disabling them, and is told how many there were.
- `ehosctl apps sign-in list | agree | withdraw <application> [<client>] --env <environment>`:
  the applications whose pages ask for credentials for an application in an environment, and
  those agreed to, and agreeing to or withdrawing one, through EHOS's API, as the application's
  environment tab does (eh-os#374, D-70, ehos-tools#110).
- `ehosctl people agreements` and `ehosctl people agree | withdraw <application> --env
  <environment>`: the applications that ask to read the company's people, and those agreed to,
  and agreeing to or withdrawing one, as the people page does (eh-os#374, D-81).
- EHOS's refusal `not_requested`, of an agreement no deployment in force asks for, exits 1, as a
  conflict does.

### Changed

- `ehosctl init` creates applications from `ehos_app` 0.8.1, at the commit its tag
  `ehos_app-v0.8.1` names, in place of 0.7.0: the generated CI checks the project with
  `ehosctl verify` (0.8.0), which needs the CI App's *Attestations: read*, and the example
  contract's check says 0 errors, 0 warnings, 0 notices (0.8.1).
- **Breaking:** an `EHOSCTL_CA_FILE` that cannot be read, holds no certificate, or holds a
  certificate that does not decode, which 0.3.0 accepted, is refused with exit 2 (`invalid`), as
  another variable `ehosctl` cannot use is; the first two exited 1 (ehos-tools#123).
- Requests to GitHub, which `ehosctl versions`, `ehosctl changelog` and the update notice make,
  no longer read `EHOSCTL_CA_FILE`, on purpose, since it names a local EHOS's CA: they trust the
  system's CAs alone, so behind a TLS-intercepting proxy, add the proxy's CA to the system's
  trust store (ehos-tools#123).

### Fixed

- The update notice and `ehosctl versions` name the command that moves to a newer `ehosctl`,
  `mise use -g github:EmpoweredHouse/ehos-tools@<version>`, in place of `mise upgrade ehosctl`,
  which matches no tool mise knows. A command that names the version also takes a release younger
  than mise's `minimum_release_age`, which `mise use` and `mise upgrade` without a version do not
  see (ehos-tools#124). When the installation does not
  accept this `ehosctl`, the notice points to `ehosctl versions`, which says whether it accepts the
  newest release.
- An `EHOSCTL_CA_FILE` with no certificate in it that decodes, such as a PEM block left empty, is
  named before any connection, `EHOSCTL_CA_FILE=<path> holds no certificate ehosctl can read`; so
  is one with any certificate that does not decode, and a path that is not a regular file of at
  most 1 MiB. OTP's `SSL WARNING` notices, one per connection, no longer reach the
  terminal. A handshake that fails with `unknown_ca` while `EHOSCTL_CA_FILE` is set says that the
  CA in that file did not sign the certificate, instead of telling you to set it (ehos-tools#123).
- `ehosctl versions` names a locked commit that a release's tag names as that release, though
  it has no GitHub release or no `release.json`, as `ehos_app`'s releases before 0.7.0 do: a
  project on `ehos_app` 0.6.0 reads `0.6.0 (9c97894)`, not `9c97894, 194 commits behind 0.8.0`,
  and is offered the move to the newest release. Whether the installation accepts it stays
  `unknown`, with what is known of its `release.json`. Tags GitHub did not list, or listed only
  in part, are said, as releases are. `ehosctl changelog` finds the version in use the same way
  (ehos-tools#122).
- `ehosctl versions`' line that moves an `eh_os_contract` on eh-os-contract's `main` names the
  `ehos_app` release to move to, the newest whose `release.json` admits that release, that the
  installation does not refuse and that is newer than the `ehos_app` in use, or says only to run
  `mix ehos_app.install` again when the one in use admits it, instead of waiting for one
  (ehos-tools#122).

## [0.3.0] - 2026-10-11

### Added

- `ehosctl versions`: for `ehosctl`, the installation's EHOS and, in an application's
  directory, its `ehos_app`, `eh_os_contract` and `ehos_design`, the version in use, whether the
  installation accepts it, the newest release, whether the installation would accept that, and
  the command that moves to it, with a row for the application's `ehos.yaml` and manifest
  (eh-os D-91, ehos-tools#97). What is accepted comes from the installation's `GET /api/v1`,
  what exists from GitHub's releases and their `release.json`, what is in use from `mix.lock`; a
  locked commit that is no release's is said as a commit, with how far it is from the newest
  release. A newer release the installation refuses is shown, with why, and no command moves to
  it. Each source can fail alone (no installation, no GitHub token, offline): what one could not
  say is said, and the command exits 0.
- `ehosctl changelog <component> [--since VERSION] [--web]`: the notes of each release of
  `ehosctl`, `ehos`, `ehos_app`, `ehos_design` or `eh_os_contract` newer than the version in use,
  or than `--since`, newest first; `--web` opens the newest release's page.
- After a command, at most once a day, a notice on stderr that a newer `ehosctl` is released, or
  that the installation the command used no longer accepts this one. Never in CI, under
  `--json`, when stderr is not a terminal, or with `EHOSCTL_NO_UPDATE_NOTICE` set; it never
  changes a command's output or exit code. Its cache is `notice.json` in the user's cache
  directory.
- GitHub's releases are read with `MISE_GITHUB_TOKEN`, else `GITHUB_TOKEN`, sent to
  `api.github.com` alone; without one, `ehosctl` says a token is what is missing.
- A command whose route the installation lacks says that the installation's EHOS, at the version
  it names, is too old for it, and that the operator upgrades EHOS, instead of a bare 404 (exit 1).
- `ehosctl --version` prints, for a build between releases, the commit it was built from on a
  second line.
- `ehosctl verify [--no-test]`: the application in the current directory checked as its CI checks
  it, then by EHOS (eh-os#355, ehos-tools#93). It runs the template's CI gates in order under the
  application's own `.tool-versions`, with `MIX_ENV=test`: the lock check, format, compile with
  warnings as errors, tests, `mix eh_os_contract.check`, and `mix eh_os_contract.manifest` into
  `_build/ehos.manifest.json`. It stops at the first that fails, with exit 1, and then, when an
  installation is chosen, sends `ehos.yaml` and the manifest to `POST /api/v1/ehos-yaml/check`. With
  none chosen, EHOS's check is said to be left out. It submits nothing.
- `Ehosctl.Mise` runs a command under a pinned toolchain with the terminal's own input and
  output, for `init` and `verify`.
- `ehosctl installation`: where the installation runs and what it uses, through EHOS's API, as the
  console's Installation page shows it (eh-os#349, `docs/installation-api.md`, D-90): the
  installation's description, each node's capacity and use, and each environment's and
  application's use against its quota. It needs a platform capability; what EHOS could not read it
  says, and prints the rest (ehos-tools#91).
- `ehosctl audit [--limit N]`, `ehosctl activity [--limit N]` and `ehosctl agents list | create`:
  the audit record inside the scopes where you may read it, what was done in your name or your
  agents', and your agents, through EHOS's API, as the console's Audit, My activity and My roles
  pages show them (eh-os#343, `docs/audit-api.md`). Both lists follow the API's pages up to
  `--limit`, 100 by default and at most 10,000, and say when older rows remain. An agent's name
  used already exits 2; one past a person's 200 agents, `too_many_agents`, exits 1 (eh-os#344).
- `Ehosctl.Pages` follows any of EHOS's lists given in pages, which `people list` used alone.
- `ehosctl role-bindings list | bind | unbind` and `ehosctl apps register | show | review |
  activate`: role bindings, and an application's versions, their review and activation, through
  EHOS's API, as the console's Bindings and application pages do (eh-os#340,
  `docs/role-bindings-api.md`, `docs/versions-api.md`). A person is bound by their email, an agent
  by its owner's email and `--agent`; a version is named by its digest or by the start the console
  shows. `apps activate` prints what it changes, and activates only if the version in force is the
  one its review showed; one activated meanwhile is refused, `changed`, exit 1. `ehosctl apps`
  alone still lists the applications you may use.
- The codes EHOS's role bindings refuse with (eh-os#340): `unknown_role`, `platform_only`,
  `needs_environment` and `wrong_application` exit 2, and `not_in_force` exits 1.
- `ehosctl env list | show | create | remove | bind | unbind` and `ehosctl resources list |
  classify`: an installation's environments and resources through EHOS's API, as the console's
  pages manage them (eh-os#337, `docs/environments-api.md`). A refused bind, create or
  classification is printed in the page's words; `across_the_line` and the `schema_*` codes exit 2,
  `already_set`, `not_classified` and `used` exit 1, and `being_removed` exits 5, since trying again
  works once the cluster has removed the old environment.
- `ehosctl people list | show | invite | rename | disable | enable`: the company's people through
  EHOS's API (eh-os `docs/people-api.md`, #83). A person is named by id or email; `list` follows
  every page, or stops at `--limit`; `invite` says whether the sign-in link was mailed and never
  prints one. No command sets or resets a password.
- `ehosctl deploy <app> --env E --image I --manifest F`: deploys an image, by digest, with its
  manifest sent byte for byte, as the console's Deploy does (#83). A manifest of another
  application, one over 1 MiB, or one that is not UTF-8, from a file or stdin, is refused before
  anything is sent. A refused manifest lists its reasons; a gateway's 5xx or an answer ehosctl
  cannot read says the deployment may have been decided.
- `people` prints a person as people-api.md defines one, under `--json` too, so nothing else an
  answer holds is printed. A list whose next page cannot be followed, or goes back to one already
  read, is an error rather than taken as complete.
- The codes EHOS's people and deployment routes refuse with (eh-os#335): `person_disabled` and a
  deployment's `unbound`, `database_kept`, `name_taken`, `name_too_long`, `host_too_long`,
  `object_taken`, `schema_taken` and `binding_moved` exit 1, and `too_large` exits 2.

- `ehosctl roles [--app A] [--env E]` and `ehosctl apps`: the roles you and your agents hold, and
  the applications you may use, each environment with its address and what your roles grant
  there, from EHOS's API (eh-os `docs/terminal-api.md`, #79).
- `ehosctl call <app> <capability> [fields]`: a command, a recording or a query in an application,
  through `EhOsContract.Plug`'s routes, with the application's own credential (T-10). Fields are
  typed as HTTPie types them (`name=text`, `name:=<JSON>`, `--data`), and every command and
  recording carries a new idempotency key, or the one `--idempotency-key` gives. A capability
  none of your roles grants is still asked for, as each kind in turn, so that EHOS or the
  application refuses it and records the refusal (T-12, eh-os FM-21, P-4).
- `ehosctl credential <app>`: the credential `call` presents, for a script or `curl`. One holding
  a terminal's control characters is not printed, and no header holding a line break or
  non-ASCII is sent.
- When a command may have been done without an answer `ehosctl` can read (the connection broke
  after sending, or a 5xx other than one saying nothing was written), `call` names the
  idempotency key it sent. `--idempotency-key` is checked before anything is sent, and a word
  that starts with `-` is refused as an unknown option rather than sent as a field.
- A refusal from EHOS or from an application is said in eh-os `docs/refusals.md`'s words, and
  exits with its kind's code: 1 also for Not found, Conflict and Gone, 2 for Invalid, 3 for
  Refused, 4 for Not accepted, 5 for Unavailable.

- A renewal and `logout` post to the token and revocation endpoints the sign-in kept when
  `login` read them, so each is one request rather than discovery, the JWKS and the request
  (#76). EHOS's discovery, its issuer included, is checked at `login` and when the kept endpoints
  will not do: when they no longer pass the checks, or answer that they are not there, with a
  redirect, or that the sign-in is over. Then discovery alone is read, without the JWKS, and the
  request is posted again only to another address.

- `ehosctl login [URL]`, `ehosctl whoami` and `ehosctl logout` (eh-os D-89). `login` signs you
  in through your browser, as EHOS's public client `ehosctl`: the code flow with PKCE and a
  redirect to `127.0.0.1` (T-09). It adds or updates the installation and makes it current.
  `whoami` says who you are, where, and until when. `logout` revokes the sign-in at EHOS and
  forgets it here, even when EHOS does not answer.
- The sign-in's refresh token is kept in the system's keychain (macOS's Keychain, or the Secret
  Service through `secret-tool`), or else in a file only you can read, with a warning. Ten-minute
  credentials are cached beside it, and one renewal runs at a time, under a lock (T-08).
  `EHOSCTL_TOKEN_STORE=file` chooses the file, and `EHOSCTL_STATE_DIR` moves the state directory.
- The page the browser comes back to after `login` is the design system's outcome, with its
  stylesheet, tokens and fonts taken from `packages/ehos_design` when `ehosctl` is built. It loads
  nothing.
- `EHOSCTL_CA_FILE`: CA certificates trusted besides the system's, for a local EHOS whose
  certificate comes from a CA of its own (T-09). An installation's address is `https` only.
- `ehosctl installations list | use NAME | remove NAME`: the installations of EHOS you know, under
  names you give them, one of them current, kept in `~/.config/ehosctl/config.json` (T-07). A
  governed command talks to the one `--installation`, `EHOSCTL_INSTALLATION` or the current one
  names.
- `--json` on the commands that can answer in JSON, and stable exit codes per kind of error:
  1 failed, 2 invalid, 3 refused, 4 not signed in, 5 unreachable.
- Every command's help names its plane: governed, platform or local (eh-os D-87).
- The reference documentation, built by `mix docs`.
- Each release carries `release.json`, schema `ehos.release/v1`: its version, the commit it was
  built from, the interfaces it reads (EHOS's API, `ehos.api/v1`, and an application's routes,
  `eh_os_contract.api/v1`) and the `ehos_app` version it creates applications from, written from
  the code by `mix ehosctl.release_file` (eh-os D-91,
  [releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)).

### Changed

- **Breaking:** every call to EHOS's API goes to `/api/v1/…`, its versioned path (eh-os D-91),
  instead of `/api/…`. It needs an EHOS that serves `/api/v1`, eh-os after
  [#362](https://github.com/EmpoweredHouse/eh-os/pull/362); an older one answers 404 to every
  command that calls it. `ehosctl call`'s routes of an application are unchanged.
- A release's notes on GitHub are its section of this changelog, in place of the list GitHub
  generated of every pull request in ehos-tools since the last tag. A tag whose section is missing
  or empty publishes nothing.
- `ehosctl init` creates applications from `ehos_app` 0.7.0, at the commit its tag
  `ehos_app-v0.7.0` names (`7c6d527`), in place of 0.6.0. A new application's contract engine is
  eh-os-contract's release 0.3.0, which `ehos_app` 0.7.0 pins, not the newest commit of its
  `main` (ehos-tools' T-11); `ehosctl --help` says so.
- The command line is read with Optimus (T-06): the help has a new layout, and
  `ehosctl help init`, `ehosctl init -h` and `ehosctl init shop --help` work as
  `ehosctl init --help` does. An unknown command or option now exits with 2, not 1, and so does
  `ehosctl init` with no name or with more than one, or with a name that starts with a dash,
  which is read as an option. A name `init` refuses still exits with 1.

### Fixed

- `ehosctl init` generates under the pinned Erlang and Elixir when another version manager's
  shims (asdf's) come before mise's on the `PATH`. It generated under that manager's versions
  instead, and wrote them into the project's `.tool-versions` and Dockerfile, without a word:
  `mise install` and each Mix step now run with `MISE_ACTIVATE_AGGRESSIVE=1`
  ([#64](https://github.com/EmpoweredHouse/ehos-tools/issues/64)).
- The binary writes UTF-8 whatever the locale. `erl` takes stdio's encoding from it, and where
  it names no UTF-8 (`LANG` unset, as under cron, in CI or over a bare SSH session) wrote
  latin1: an application's "Lista komputerów" printed as "komputer\xF3w". `--json` escapes a
  bidirectional override or a C1 control a server sent, as the words already did.

## [0.2.0] - 2026-10-09

`ehosctl init` creates applications from `ehos_app` 0.6.0 at `9c97894`, in place of 0.5.0 at
`9f3cfd2`.

### Changed

- The template is `ehos_app` 0.6.0. A new application:
  - takes `ehos_design` 0.2.0, with the design system's listbox, `EhosDesign.Components.picker/1`
    and `combobox/1`, and its hooks in the LiveSocket
    ([eh-os D-86](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0086-the-design-system-s-source-holds-component-stylesheets-and-ehos-design-ships-the-components-built-on-them.md));
  - compiles against eh-os-contract's `main`, whose contracts name their id, as `ehos_app` 0.5.1
    made its example contract do.

## [0.1.2] - 2026-10-06

`ehosctl --help` says which template a binary creates applications from. The template is the
same as 0.1.1's, `ehos_app` 0.5.0 at `9f3cfd2`, so what `init` generates is unchanged.

### Added

- `ehosctl --help`, and `ehosctl` alone, print the version and what `init` creates an
  application from: `ehos_app`'s version and commit, Erlang, Elixir, `phx_new` and
  `igniter_new`, and that `eh_os_contract` follows eh-os-contract's `main`. When
  `EHOSCTL_TEMPLATE_SOURCE` replaces the pinned template it says so, and when it holds a value
  `init` refuses it says that instead. `ehosctl --version` still prints the version alone, as CI
  compares it with the tag.

### Fixed

- The READMEs say what to do when `mise use -g` has installed `ehosctl` and the shell does not
  find it: mise is not active in a shell that uses asdf, so its shims go at the end of the `PATH`.
  The root README gives the line for zsh, bash and fish.

## [0.1.1] - 2026-10-06

`ehosctl init` creates an application from `ehos_app` 0.5.0, whose contract engine follows
eh-os-contract's `main` and whose sign-in sits on the root layout. `mise upgrade ehosctl`, or
`mise use -g github:EmpoweredHouse/ehos-tools@0.1.1`, takes it; a project already created moves to
0.5.0 as `ehos_app`'s CHANGELOG says.

### Changed

- The template is `packages/ehos_app` of ehos-tools at `9f3cfd2`, the commit the tag
  `ehos_app-v0.5.0` names, with `"== 0.5.0"` as its requirement, in place of 0.4.0's `9ba6f3e`.
  A new project takes `eh_os_contract` and `eh_os_contract_auth` from eh-os-contract's `main`,
  so two projects created by this release on different days can have different commits of them
  in `mix.lock`
  ([T-05](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)).

### Fixed

- The READMEs say that mise, from 2026.10, reads a release's attestations with the token it is
  given, so a fine-grained token needs *Attestations: read*. CI's `install` job, which failed on
  every platform for v0.1.0 with a 403 from that API, has the permission.
- The READMEs say where mise finds a token: in the environment, or in `gh`'s `hosts.yml`, which
  stays empty when `gh` keeps its token in the system's keyring, as it does by default. Without
  one, GitHub answers mise with a 404 for the private repository. They lead with a fine-grained
  token, and show how to pass `gh`'s for one command.
- The moduledoc of `Ehosctl.Template` says the contract engine is the one part of the template a
  release does not pin: `ehos_app` follows eh-os-contract's `main`
  ([T-05](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)).

## [0.1.0] - 2026-10-03

The first release of `ehosctl`: one binary for each of macOS and Linux, on arm64 and x86_64,
that creates an EHOS application from `ehos_app` 0.4.0. While ehos-tools is private, it is an
internal release: `mise use -g github:EmpoweredHouse/ehos-tools@0.1.0` installs it with a GitHub
token that can read the repository. There is no Homebrew tap yet.

### Added

- The template is `packages/ehos_app` of ehos-tools at `9ba6f3e`, the commit the tag
  `ehos_app-v0.4.0` names, not at the tag: a tag can be moved, and the template is code the new
  project runs as its installer, so a new project's `mix.exs` names that commit, with
  `"== 0.4.0"` as its requirement, so that the project does not compile against another
  release. `init` generates the Phoenix project first, then installs it there with a `sparse:`
  dependency through `Igniter.Util.Install.install/2`, since `igniter.new --install` cannot name
  a subdirectory, and makes the project's first commit last.
- `EHOSCTL_TEMPLATE_SOURCE` takes `path:<absolute path>` or `ref:<git ref of ehos-tools>`.
- `init` writes a dash in the name as an underscore, which an OTP application's name needs, and
  says so. A name ends with a letter or a digit, as the DNS label EHOS makes of it does.
- `ehosctl init <name>` creates an EHOS application from the pinned template:
  - it runs `mix igniter.new --with phx.new` and installs `ehos_app` in the new project, under the
    pinned toolchain through `mise exec`;
  - it keeps the generator's archives in a directory owned by this version;
  - it finishes with Hex installed and `.tool-versions` trusted by mise.
- When `init` fails, it says what is left behind: a half-generated directory to remove before
  trying again, or the one setup step to finish by hand in a project that was generated.
- `ehosctl --version` and `ehosctl --help`.
- `EHOSCTL_TEMPLATE_SOURCE` replaces the pinned `ehos_app` source, for working on the template.
- A Burrito release, one self-contained binary for each of macOS and Linux, on arm64 and x86_64.
- `ehosctl init --help` prints the usage of `init`.
- Linux support on x64 and arm64, next to macOS. CI has an end-to-end job for each of the four
  platforms.
- Releases carry the four binaries and a `SHA256SUMS` file, and install with
  `mise use -g github:EmpoweredHouse/ehos-tools`.

### Changed

- The targets, and so the binaries, are named `macos_arm64`, `macos_x64`, `linux_arm64` and
  `linux_x64`, which mise's `github:` backend recognises.
- The missing-mise message links to mise's installation page instead of suggesting Homebrew.
- `init` gives each step the terminal's own stdin, stdout and stderr, so a prompt can be answered
  and errors stay on stderr.
- The pins:
  - Erlang 28.5.0.7
  - Elixir 1.20.4-otp-28
  - `phx_new` 1.8.14
  - `igniter_new` 0.5.34
  - `ehos_app` `packages/ehos_app` of ehos-tools at `9ba6f3e`, the commit `ehos_app-v0.4.0`
    names, whose generated application signs people in through EHOS and preloads its fonts

### Fixed

- `init` installs the pinned Erlang and Elixir with `mise install --quiet` before its first
  `mise exec`, which cannot install a missing Elixir.
- A failed step is reported with the command that ran it (`mise …`), and a failed toolchain install
  says that mise builds Erlang from source where it has no precompiled build.
- An unexpected exception in the binary ends in one line on stderr and exit code 1, not a kernel
  crash report.
- An archive whose install was interrupted is installed again instead of being taken as present.
- `ehosctl --version x` and the other flags refuse extra arguments with a clear message.
- An empty `EHOSCTL_TEMPLATE_SOURCE` is taken as unset.

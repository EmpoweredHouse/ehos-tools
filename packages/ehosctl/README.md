# ehosctl

The command-line tool for [EHOS](https://github.com/empoweredhouse/eh-os).

`ehosctl` will be to EHOS what `gcloud` is to a cloud: one way in from the terminal, through the
same API and the same authorization as the console. Its first command needs no EHOS at all. It
creates a new application:

```sh
ehosctl init shop
```

It signs you in to an installation of EHOS from the terminal (`login`, `whoami`, `logout`), says
which roles you hold and which applications you may use (`roles`, `apps`), and calls those
applications as you (`call`, `credential`), and checks an application as its CI does (`verify`).
It deploys an application, prepares environments, lets people in, and makes the server an
installation runs on; [Commands](#commands) lists them all. The way from an empty machine to an
application deployed and in use, step by step, is the
[golden path](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/golden-path.md).

## Installing

`ehosctl` is a single binary that carries its own Erlang runtime, so it needs nothing installed to
run. It does need [mise](https://mise.jdx.dev/installing-mise.html), which `init` uses to provide
the generated project's toolchain, and `verify` to run an application under its own. It runs on
macOS and Linux, on arm64 and x64. Windows is not supported: see [Windows](#windows).

There are two ways to install it:

- **With mise**, on macOS and Linux. mise picks the binary for the machine from the release:

  ```sh
  mise use -g github:EmpoweredHouse/ehos-tools
  ```

  It is on your `PATH` if mise is active in your shell (`mise activate`, or its shims directory on
  the `PATH`); with asdf, see [With asdf](#with-asdf). While the repository is private, mise needs a
  token: see [below](#while-the-repository-is-private). `ehosctl --help` prints its version and
  what `init` creates an application from: the template's version and commit, and the Erlang,
  Elixir and generators it pins.

- **By hand.** Download `ehosctl_<target>` for your platform from the
  [release](https://github.com/empoweredhouse/ehos-tools/releases), check it against the release's
  `SHA256SUMS` (`sha256sum --check --ignore-missing SHA256SUMS`, or
  `shasum -a 256 --check --ignore-missing SHA256SUMS` on macOS), make it executable and put it on
  your `PATH` as `ehosctl`.

Homebrew is not one of them yet: it downloads a formula's binary without credentials, so it cannot
install from this private repository's releases. The formula,
[`packaging/homebrew/ehosctl.rb`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packaging/homebrew/ehosctl.rb),
waits until the repository is public.

| Target | Platform | Status |
| --- | --- | --- |
| `macos_arm64` | macOS on Apple silicon | Supported. Tested end to end by hand; CI's end-to-end job runs on `macos-15` |
| `macos_x64` | macOS on Intel | Supported. CI's end-to-end job runs on `macos-15-intel`, the last Intel image GitHub offers, which it retires in August 2027 |
| `linux_arm64` | Linux on arm64 | Supported. Tested end to end in an Ubuntu 24.04 arm64 container; CI's end-to-end job runs on Ubuntu 24.04. Other distributions: see [Linux](#linux) |
| `linux_x64` | Linux on x86_64 | Supported. CI's end-to-end job runs on Ubuntu 24.04. Other distributions: see [Linux](#linux) |

To run the code of a branch instead, [build it from source](#building-the-binary).

### While the repository is private

mise needs a GitHub token that can read it. It reads one from `GITHUB_TOKEN` or
`MISE_GITHUB_TOKEN`, or from `gh`'s `~/.config/gh/hosts.yml` (`github.gh_cli_tokens`, on by
default). `gh` keeps its token in the system's keyring instead, unless it was signed in with
`--insecure-storage`, and mise does not read the keyring. Without a token, GitHub answers mise with
a 404, as for a repository that does not exist. Prefer a fine-grained token that reads ehos-tools
alone, with *Contents: read* and, since mise 2026.10 reads the release's attestations with it,
*Attestations: read*, whose *Resource owner* is EmpoweredHouse:

```sh
read -rs MISE_GITHUB_TOKEN
MISE_GITHUB_TOKEN="$MISE_GITHUB_TOKEN" mise use -g github:EmpoweredHouse/ehos-tools
```

`read -rs` waits for the token, pasted, without showing it or keeping it in your shell's history,
and the next line gives it to that one command rather than exporting it.

`MISE_GITHUB_TOKEN=$(gh auth token)` works too, for the one command. That token can usually write to
every repository you can, so do not export it in a shell profile, where every process you start, a
dependency's build script included, would read it.

### Upgrading

After a command, at most once a day, `ehosctl` says when a newer one is released, with the command
that moves to it ([The update notice](docs/commands/versions.md#the-update-notice)); `ehosctl
versions` prints the same command, and says whether the installation you use accepts that release.
Both read the releases from GitHub with `MISE_GITHUB_TOKEN`, else `GITHUB_TOKEN`: while the
repository is private, a token given to `mise use` alone does not reach them: without one,
`versions` says it cannot see the releases and the notice says nothing.

```sh
mise use -g github:EmpoweredHouse/ehos-tools@<the new version>
```

It names the version on purpose. mise knows the tool as `github:EmpoweredHouse/ehos-tools`, not as
`ehosctl`, so `mise upgrade ehosctl` answers that all tools are up to date; and mise hides a release
younger than its `minimum_release_age` from `mise use` and `mise upgrade` without a version.
`mise ls-remote github:EmpoweredHouse/ehos-tools` then warns that newer releases are hidden.

### With asdf

If you manage Erlang and Elixir with asdf and never set mise up in the shell, `mise use -g` installs
`ehosctl` and the shell still answers `command not found`. Add mise's shims to the end of the
`PATH`, once, so that asdf's come first for the tools both know. In zsh (`~/.zshrc`) or bash
(`~/.bashrc`, or `~/.bash_profile` on macOS):

```sh
export PATH="$PATH:$HOME/.local/share/mise/shims"
```

In fish, add `fish_add_path --path --append ~/.local/share/mise/shims` to
`~/.config/fish/config.fish`: with `--path` it changes only the running shell's `PATH`, so it has to
run in every new one. `mise doctor` prints the shims directory yours uses (`shims:`) and whether
it is on the `PATH` (`shims_on_path`).

With asdf's shims first, `init` still generates under the versions it pins. In the generated
project, though, `mix` and `elixir` are then asdf's, even under `mise exec`. Ask mise to put its
tools first, for one command (`MISE_ACTIVATE_AGGRESSIVE=1 mise exec -- mix setup`) or for
every `mise exec` in the shell (`export MISE_ACTIVATE_AGGRESSIVE=1`).

## Commands

Each command's page says what it does, what it needs and what it prints. `ehosctl help COMMAND`
says the same in short.

| Command | Plane | What it does | Described in |
| --- | --- | --- | --- |
| `ehosctl init NAME` | local | Create a new EHOS application in the directory `./NAME` | [`ehosctl init NAME`](docs/commands/init.md) |
| `ehosctl installations list` | local | List the installations that this machine knows. A `*` marks the current one | [Installations](docs/commands/installations.md) |
| `ehosctl installations use NAME` | local | Make an installation the current one | [Installations](docs/commands/installations.md) |
| `ehosctl installations remove NAME` | local | Forget an installation. This does not end its sign-in: run `ehosctl logout` first | [Installations](docs/commands/installations.md) |
| `ehosctl login [URL]` | governed | Sign in to an installation of EHOS in your browser. ehosctl adds the installation if it is new | [Signing in](docs/commands/login.md) |
| `ehosctl whoami` | governed | Show who you are signed in as, and until when | [Signing in](docs/commands/login.md) |
| `ehosctl logout` | governed | Sign out of an installation. EHOS ends the sign-in, and ehosctl removes it from this computer | [Signing in](docs/commands/login.md) |
| `ehosctl terminals` | governed | List your terminals that are signed in with `ehosctl login`, the newest first | [Signing in](docs/commands/login.md) |
| `ehosctl terminals sign-out ID` | governed | Sign out one of your terminals. Its commands stop within 10 minutes | [Signing in](docs/commands/login.md) |
| `ehosctl roles [--app A] [--env E]` | governed | List the roles that you and your agents hold | [Your roles and applications](docs/commands/apps.md) |
| `ehosctl apps` | governed | List the applications that you can use, where they are, and what you can do there | [Your roles and applications](docs/commands/apps.md) |
| `ehosctl apps register \| show \| review` | governed | Register an application manifest as a version, show the versions of an application, and show what a version changes in an environment | [Your roles and applications](docs/commands/apps.md) |
| `ehosctl apps history APP --env E` | governed | Show the deployments of an application in an environment, with how each ended and what came after it | [Your roles and applications](docs/commands/apps.md) |
| `ehosctl apps sign-in list \| agree \| withdraw` | governed | List, give and withdraw sign-in agreements | [Sign-in, people, mail and service agreements](docs/commands/agreements.md) |
| `ehosctl call APP CAPABILITY [FIELD…]` | governed | Call an application as you: run a command, make a recording, or ask a query | [Calling an application](docs/commands/call.md) |
| `ehosctl credential APP` | governed | Print a credential for an application. A script or `curl` can send it to the application | [Calling an application](docs/commands/call.md) |
| `ehosctl people list \| show \| invite \| rename \| disable \| enable \| reset-password \| sign-out` | governed | Manage the people of the company: list, invite, rename, disable and enable them, reset their passwords, and sign out their terminals | [Managing people](docs/commands/people.md) |
| `ehosctl people agreements \| agree \| withdraw` | governed | List, give and withdraw people agreements: which applications can read the people in an environment | [Sign-in, people, mail and service agreements](docs/commands/agreements.md) |
| `ehosctl mail agreements \| agree \| withdraw` | governed | List, give and withdraw mail agreements: how far an application can send mail through EHOS in an environment | [Sign-in, people, mail and service agreements](docs/commands/agreements.md) |
| `ehosctl services list \| agree \| withdraw \| agree-hosts \| withdraw-hosts` | governed | List, give and withdraw service agreements: which application can call a utility service in an environment, and the agreement of the application to the hosts outside that the service sends data to | [Sign-in, people, mail and service agreements](docs/commands/agreements.md#let-an-application-call-a-utility-service) |
| `ehosctl deploy APP --env E --image I --manifest F [--graph G]… [--commit SHA] [--ref REF] [--no-wait]` | governed | Deploy an image by digest and its application manifest to an environment, and wait until the deployment is active. Each `--graph` adds one graph document, 512 at most | [Deploying](docs/commands/deploy.md) |
| `ehosctl deploy APP --env E --build ID \| COMMIT \| --build latest --ref REF [--repository OWNER/NAME]` | governed | Deploy a build that the CI of the application registered, with its image, application manifest and graph documents, and wait as above | [Deploying](docs/commands/deploy.md) |
| `ehosctl promotions APP \| --waiting` | governed | List the candidates and promotions of an application, or the promotions that wait for your approval | [Promotions](docs/commands/promotions.md) |
| `ehosctl promotions show ID` | governed | Show the review of a promotion: what an approval puts in force in production, and what you must know before you decide | [Promotions](docs/commands/promotions.md) |
| `ehosctl promote APP --candidate ID --env E [--replace ID] [--break REASON]` | governed | Ask for the promotion of a candidate to a production environment | [Promotions](docs/commands/promotions.md) |
| `ehosctl promote --withdraw ID` | governed | Withdraw a promotion that waits. Production does not change | [Promotions](docs/commands/promotions.md) |
| `ehosctl approve ID [--yes] [--no-wait]` | governed | Approve a promotion after you read its review, and wait until the deployment in production is active | [Promotions](docs/commands/promotions.md) |
| `ehosctl refuse ID --reason TEXT` | governed | Refuse a promotion, with a reason. Production does not change | [Promotions](docs/commands/promotions.md) |
| `ehosctl deploy APP --env E --image I --bundle DIR` | governed | Deploy an image with the application manifest and graph documents of a bundle, in place of `--manifest` and `--graph`. ehosctl checks each file against `bundle.json` | [Deploying](docs/commands/deploy.md) |
| `ehosctl builds register DIR --image I` | governed | Register an image and the bundle in DIR as a build of the application. In a GitHub Actions job, also state what the checkout says of the commit | [Builds](docs/commands/builds.md) |
| `ehosctl builds list APP [--ref REF] [--limit N]` | governed | List the builds of an application, newest first, with their ref, commit and title | [Builds](docs/commands/builds.md) |
| `ehosctl builds openapi SERVICE BUILD [--output FILE]` | governed | Download the OpenAPI file of a build of a utility service, as it came | [Builds](docs/commands/builds.md) |
| `ehosctl deploy APP --env E --manifest F --preview` | governed | Show what a deployment of an application manifest would do, and each reason that EHOS would refuse it. ehosctl deploys nothing | [Deploying](docs/commands/deploy.md) |
| `ehosctl landscape [--env E]` | governed | Show the applications of an environment as one system: who publishes each fact and who subscribes to it. Without `--env`, list the environments whose landscape you can read | `ehosctl help landscape` |
| `ehosctl graph APP DEPLOYMENT [--domain M \| --contract ID \| --process ID]` | governed | List the graph documents that a deployment carried, of its domains, contracts and process modules, or print one of them as JSON | `ehosctl help graph` |
| `ehosctl env list \| show \| create \| extend \| remove \| bind \| unbind` | governed | List, create, extend and remove environments, and bind resources in them | [Environments and resources](docs/commands/env.md) |
| `ehosctl env quota show \| set \| clear` | governed | Shows an environment's quota and limits, gives one that is not ephemeral its own within the installation's ceiling, and gives it back the installation's | [An environment's own quota](docs/commands/env-quota.md) |
| `ehosctl env template list \| show \| create \| update \| remove \| bind \| unbind` | governed | Lists, creates, changes and removes the templates ephemeral environments are made from, and names their resources | [Templates](docs/commands/env-template.md) |
| `ehosctl env template role-entry list \| set \| remove TEMPLATE --app A` | governed | Lists, sets and removes the role entries that an environment template holds for an application: a person and a role of the application | [Templates](docs/commands/env-template.md#give-people-a-role-in-advance) |
| `ehosctl env template people show \| agree \| withdraw TEMPLATE --app A` | governed | Shows, gives and withdraws a people agreement that an environment template holds for an application, given in advance | [Templates](docs/commands/env-template.md#give-a-people-agreement-in-advance) |
| `ehosctl secret list \| set \| rotate \| delete --app A (--env E \| --template T)` | governed | List, set, rotate and delete the secrets of an application. ehosctl never shows a value | [Secrets](docs/commands/secret.md) |
| `ehosctl db connect APP --env E [--write] [--ttl D]` | governed | Open a data session on the database of an application, and start `psql` on it. The data session ends when `psql` exits | [Data sessions](docs/commands/db.md) |
| `ehosctl db tunnel APP --env E [--write] [--ttl D]` | governed | Open a data session, and show how another database client connects to it. Ctrl-C ends it | [Data sessions](docs/commands/db.md) |
| `ehosctl db sessions APP --env E \| --mine` | governed | List the open data sessions of an application in an environment, or your own | [Data sessions](docs/commands/db.md) |
| `ehosctl db end ID` | governed | End a data session now. Its connections close | [Data sessions](docs/commands/db.md) |
| `ehosctl db trust-ca FINGERPRINT` | governed | Trust the new data CA or gateway CA of the installation, with the fingerprint that its administrator gave you | [Data sessions](docs/commands/db.md) |
| `ehosctl resources list \| classify` | governed | List the resources that environments can bind, and set whether each serves production | [Environments and resources](docs/commands/env.md) |
| `ehosctl role-bindings list \| bind \| unbind` | governed | Lists the role bindings where you manage them, with who granted one through an application and under which rule, and binds and removes roles | [Role bindings](docs/commands/role-bindings.md) |
| `ehosctl trust list \| add \| remove --app A` | governed | List, add and remove trusts. A trust lets the GitHub Actions jobs of a repository deploy to the ephemeral environments of an application | [Deploying from GitHub Actions](docs/commands/github-actions.md) |
| `ehosctl github list \| claim \| remove` | governed | List, claim and remove your GitHub accounts | [Deploying from GitHub Actions](docs/commands/github-actions.md) |
| `ehosctl people github list \| confirm \| remove` | governed | List, confirm and remove the GitHub accounts that people claim | [Deploying from GitHub Actions](docs/commands/github-actions.md) |
| `ehosctl logs APP --env E \| --platform [--deployment ID] [--since S] [--grep T] [--limit N] [--follow]` | governed | Print the logs of an application in an environment, or the logs of EHOS. The newest line is last. With `--follow`, print new lines when they come | `ehosctl help logs` |
| `ehosctl audit [--limit N]` | governed | List the newest decisions in the audit record, allowed and refused, in each place where you can read it | [The audit record, your activity and your agents](docs/commands/audit.md) |
| `ehosctl activity [--limit N]` | governed | List the decisions made in your name or in the name of your agents | [The audit record, your activity and your agents](docs/commands/audit.md) |
| `ehosctl agents list \| create NAME` | governed | List and create your agents | [The audit record, your activity and your agents](docs/commands/audit.md) |
| `ehosctl verify [--no-test]` | governed | Check the application in this directory as its CI does. If an installation is chosen, EHOS then checks its `ehos.yaml` and application manifest | [Checking an application](docs/commands/verify.md) |
| `ehosctl installation` | governed | Show where the installation runs, and the resources that it and its applications use now | [Where the installation runs, and what it uses](docs/commands/installation.md) |
| `ehosctl installation domain [--check]` | governed | Show the DNS records that the installation needs at your DNS provider, their state, and what to change | [The DNS records of the installation](docs/commands/installation.md#the-dns-records-of-the-installation) |
| `ehosctl domains [map DOMAIN --app A --env E [--entry N] \| show DOMAIN \| remove DOMAIN]` | governed | List, map, show and remove the domains of your company that show a production application | [Domains of your company](docs/commands/domains.md) |
| `ehosctl versions` | governed | Show the version in use and the newest release of each EHOS component, if the installation accepts each, and the command that moves to the newest | [What is in use, and what is newer](docs/commands/versions.md) |
| `ehosctl changelog COMPONENT [--since V] [--web]` | governed | Print what changed in the releases of a component that are newer than the version in use | [What is in use, and what is newer](docs/commands/versions.md) |
| `ehosctl doctor [--gcp-project P] [--json]` | platform | Check that this machine has what the platform commands need: OpenTofu, Helm and kubectl at the versions of EHOS, ssh, a cloud account and a GitHub token. It installs nothing | [The server under an installation](docs/commands/server.md) |
| `ehosctl server up \| tunnel [--close] \| status \| down` | platform | Make, reach, read and remove the server of an installation in Oracle Cloud, AWS, GCP or OVHcloud | [The server under an installation](docs/commands/server.md) |
| `ehosctl install [--installation N] [--version V] [--host H] [--sign-in-absolute D] [--sign-in-idle D] [--four-eyes \| --no-four-eyes] [--smtp-host H] [--smtp-port P] [--smtp-username U] [--mail-from A] [--no-mail] [--switch-traefik [--ssh-key PATH]] [--allowed-domain D … \| --no-allowed-domains]` | platform | Install a release of EHOS on the server of an installation, through the tunnel to the server. ehosctl keeps the installation for `ehosctl login` | [Installing EHOS on the server](docs/commands/install.md) |
| `ehosctl upgrade [--installation N] [--to V]` | platform | Move EHOS on the server of an installation to another release. ehosctl shows the release notes first | [Upgrading EHOS on the server](docs/commands/upgrade.md) |
| `ehosctl server invite EMAIL [--installation N]` | platform | Print a link that signs a person in one time, within 15 minutes. It invites a new person. If the platform has no administrator, the person becomes it. The link is a password. The command goes through the tunnel that `ehosctl server tunnel` opens | [Inviting a person as the operator](docs/commands/server-invite.md) |
| `ehosctl --version` | | Print the version. For a build between releases, also print the commit that it was built from |  |
| `ehosctl --help` | | Print the version, the commands, and what `ehosctl init` creates an application from: the version and commit of the application template `ehos_app`, Erlang, Elixir, `phx_new`, `igniter_new`, and the release of the contract engine that the application template pins |  |

Every command's help comes from its declaration, and is asked for in any of these ways:
`ehosctl help init`, `ehosctl init --help`, `ehosctl init -h`. It ends with the command's plane:

- **governed**: the command acts as you, through EHOS. EHOS decides and records each request. These
  commands take `--installation` ([Installations](docs/commands/installations.md)).
- **platform**: the command acts with an account that EHOS does not issue: an account of a cloud
  provider, an SSH key or a kubeconfig.
- **local**: the command works on this machine only, and needs no EHOS.

What a command prints, `--json` and the exit codes are in
[Output and exit codes](docs/commands/output.md).

## Environment variables

| Variable | Effect |
| --- | --- |
| `EHOSCTL_TEMPLATE_SOURCE` | Replaces the pinned `ehos_app` source, for working on the template: `path:/abs/path/to/packages/ehos_app` for a local checkout, or `ref:<commit, branch or tag>` for another ref of ehos-tools |
| `MISE_GITHUB_TOKEN`, else `GITHUB_TOKEN` | The token `versions`, `changelog` and the update notice read GitHub's releases with |
| `EHOSCTL_NO_UPDATE_NOTICE` | Set to anything, turns the update notice off |
| `CI` | Set to anything but nothing, turns the update notice off |
| `EHOSCTL_URL` | An installation's address, `https://host[:port]`, for a GitHub Actions job: commands talk to it with the job's own token, exchanged for each credential, and keep nothing ([T-18](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0018-in-a-github-actions-job-ehosctl-talks-to-the-installation-ehosctl-url-names-and-exchanges-the-job-s-token-for-each-credential-keeping-nothing.md)) |

## Linux

The binary runs on any x64 or arm64 Linux, since it carries its own runtime. The toolchain it
installs for the generated project comes from mise. Whether that is fast depends on the
distribution:

| Distribution | Erlang from mise |
| --- | --- |
| Ubuntu 22.04, 24.04 | precompiled, detected automatically. CI tests 24.04 |
| Ubuntu 20.04 | compiled from source: builds.hex.pm has no build of the pinned Erlang for it |
| Ubuntu 26.04 | precompiled once you set `MISE_ERLANG_PRECOMPILED_OS=ubuntu-26.04` |
| any other glibc distribution (Debian, Fedora, Arch, …) | compiled from source with kerl on first use: several minutes, and it needs a C toolchain, `make`, `autoconf`, and the ncurses and OpenSSL headers |
| musl (Alpine) | not available: mise refuses to install Erlang there |

Elixir is precompiled everywhere. Docker has to be running for `mix setup`, as on macOS: it starts
the project's PostgreSQL.

## Windows

Windows is not supported, and no Windows binary is built. The route to try is WSL 2 with the Linux
binary, which is not tested either. What stands in the way of a native build:

- **The terminal is not handed over.** `init` runs each step through an Erlang port with
  `:nouse_stdio`, so that a step can use the terminal directly. On Windows that option does
  nothing: the step's stdin and stdout are always pipes to the port
  ([`erts/emulator/sys/win32/sys.c`](https://github.com/erlang/otp/blob/OTP-28.5.0.7/erts/emulator/sys/win32/sys.c)),
  so `init` would show none of `mix`'s output. It would have to read the port and print what it
  gets instead.
- **x64 only.** Burrito has one Windows target, x64, and OTP publishes no Windows arm64 build.
- **Untested toolchain.** mise installs Erlang and Elixir on Windows from their official zips, and
  `mix` is `mix.bat` there. None of this has been run end to end, and the generated project
  (Phoenix with its asset tools, `phx.gen.release`) has not been tried on Windows either.

Supporting it means solving the first point, adding a `windows_x64` target and a `windows-2025` job
to `e2e` in CI, and building with `7z` installed, which Burrito needs for Windows targets.

## Building the binary

You need the toolchain in [`.tool-versions`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/.tool-versions) (for example, run `mise install` here),
plus [Zig](https://ziglang.org) 0.16.0 exactly and `xz`. With Homebrew: `brew install zig xz`.

```sh
mix deps.get
MIX_ENV=prod BURRITO_TARGET=macos_arm64 mix release
burrito_out/ehosctl_macos_arm64 --version
```

The targets are `macos_arm64`, `macos_x64`, `linux_arm64` and `linux_x64`. Without
`BURRITO_TARGET`, all four are built. Any of them builds from macOS or Linux: CI cross-builds each of
them on Linux. The names matter: mise chooses a release asset by the OS and architecture words in
it, and reads a bare `x86` as 32-bit and a bare `arm` as armv7.

Two things to know:

- **The build's OTP version.** Burrito bundles the ERTS of exactly the build host's OTP version,
  from its CDN. The CDN lags the newest patch release, so `.tool-versions` here pins a version that
  exists there. It is independent of the Erlang the template pins for generated projects.
- **Stale code after a rebuild.** A `prod` binary unpacks its payload once per version. After
  rebuilding without a version bump, run `burrito_out/ehosctl_<target> maintenance uninstall`, or
  the binary keeps running the previous build.

## Development

```sh
mix check
```

The gate audits the dependencies (it needs the network), checks the formatting, compiles with
warnings as errors, runs Credo, the tests with warnings as errors and Dialyzer, and builds the
documentation with warnings as errors. The tests never start mise, Mix or the network:
`Ehosctl.Init` builds its steps as data and runs them through an injected runner, and the
configuration is read from a temporary directory.
[`AGENTS.md`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/AGENTS.md#trying-a-change-end-to-end)
describes the end-to-end run, from the binary to a generated project passing `mix precommit`.

`mix docs` builds the reference into `doc/` with ExDoc, the command pages above included. A new
command is a module implementing `Ehosctl.Command`, added to `Ehosctl.CLI`'s list and, with its
plane, to the list in `Ehosctl.CommandTest`, which fails until it is, and described in a page of
`docs/commands/`.

Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## Background

- [T-06](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0006-ehosctl-reads-its-command-line-with-optimus-and-writes-to-the-terminal-with-owl.md):
  ehosctl reads its command line with Optimus, and each help comes from the declaration of its
  command.
- [eh-os D-87](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0087-ehosctl-is-one-tool-for-the-developer-and-the-operator-with-a-governed-plane-through-the-api-and-a-platform-plane-outside-it.md):
  each command belongs to one plane, and its help names that plane.

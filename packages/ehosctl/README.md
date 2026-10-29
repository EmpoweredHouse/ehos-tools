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
  the `PATH`). With asdf and no mise in the shell, `ehosctl` is installed and still not found: add
  mise's shims directory to the end of the `PATH`, after asdf's shims. `mise doctor` prints it
  (`shims:`, `~/.local/share/mise/shims` by default) and whether it is on the `PATH`
  (`shims_on_path`). The root README gives the line for zsh, bash and fish.

  While the repository is private, mise needs a token that can read it, in `GITHUB_TOKEN`,
  `MISE_GITHUB_TOKEN` or `gh`'s `hosts.yml`; without one, GitHub answers with a 404. `gh` keeps
  its token in the system's keyring unless signed in with `--insecure-storage`, and mise does not
  read the keyring. Prefer a fine-grained token that reads ehos-tools alone, with
  *Contents: read* and, since mise 2026.10 reads the release's attestations with it,
  *Attestations: read*, and EmpoweredHouse as its *Resource owner*.
  `MISE_GITHUB_TOKEN=$(gh auth token)` works for the one command, but that token can usually write
  to every repository you can: do not export it in a shell profile.

- **By hand.** Download `ehosctl_<target>` for your platform from the
  [release](https://github.com/empoweredhouse/ehos-tools/releases), check it against the release's
  `SHA256SUMS` (`sha256sum --check --ignore-missing SHA256SUMS`, or
  `shasum -a 256 --check --ignore-missing SHA256SUMS` on macOS), make it executable and put it on
  your `PATH` as `ehosctl`.

Homebrew is not one of them yet: it downloads a formula's binary without credentials, so it cannot
install from this private repository's releases. The formula, `packaging/homebrew/ehosctl.rb`,
waits until the repository is public.

| Target | Platform |
| --- | --- |
| `macos_arm64` | macOS on Apple silicon |
| `macos_x64` | macOS on Intel |
| `linux_arm64` | Linux on arm64 |
| `linux_x64` | Linux on x86_64 |

To run the code of a branch instead, [build it from source](#building-the-binary).

## Commands

Each command's page says what it does, what it needs and what it prints. `ehosctl help <command>`
says the same in short.

| Command | Plane | What it does | Described in |
| --- | --- | --- | --- |
| `ehosctl init <name>` | local | Creates the application `<name>` in the directory `./<name>` | [`ehosctl init <name>`](docs/commands/init.md) |
| `ehosctl installations list` | local | Lists the installations you know, marking the current one | [Installations](docs/commands/installations.md) |
| `ehosctl installations use <name>` | local | Makes an installation the current one | [Installations](docs/commands/installations.md) |
| `ehosctl installations remove <name>` | local | Forgets an installation, leaving its sign-in: run `logout` first | [Installations](docs/commands/installations.md) |
| `ehosctl login [<url>]` | governed | Signs you in to an installation through your browser, adding it if it is new | [Signing in](docs/commands/login.md) |
| `ehosctl whoami` | governed | Says who you are signed in as, to which installation, and until when | [Signing in](docs/commands/login.md) |
| `ehosctl logout` | governed | Ends your sign-in at EHOS, and forgets it on this machine | [Signing in](docs/commands/login.md) |
| `ehosctl terminals` | governed | Lists your terminals signed in with `login`: when each signed in, was last used and ends, marking this one | [Signing in](docs/commands/login.md) |
| `ehosctl terminals sign-out <id>` | governed | Signs one of your terminals out, a lost laptop's for one | [Signing in](docs/commands/login.md) |
| `ehosctl roles [--app A] [--env E]` | governed | Lists the roles you and your agents hold, where, and which grant nothing | [Your roles and applications](docs/commands/apps.md) |
| `ehosctl apps` | governed | Lists the applications you may use, in each environment: their address and what your roles grant there | [Your roles and applications](docs/commands/apps.md) |
| `ehosctl apps register \| show \| review \| activate` | governed | Registers an application's manifest as a version, lists its versions and each environment's deployment state, and reviews and activates one in an environment | [Your roles and applications](docs/commands/apps.md) |
| `ehosctl apps history <app> --env E` | governed | Lists an application's deployments in an environment: the one in force, and each before it with how it ended and what came after it | [Your roles and applications](docs/commands/apps.md) |
| `ehosctl apps sign-in list \| agree \| withdraw` | governed | Lists the applications whose pages ask for credentials for an application in an environment, and agrees to or withdraws one | [Agreements](docs/commands/agreements.md) |
| `ehosctl call <app> <capability> [fields]` | governed | Runs a command, records something or asks a query in an application, as you | [Calling an application](docs/commands/call.md) |
| `ehosctl credential <app>` | governed | Prints a credential for an application, for a script or `curl` | [Calling an application](docs/commands/call.md) |
| `ehosctl people list \| show \| invite \| rename \| disable \| enable \| sign-out` | governed | Lists the company's people, invites, renames, disables and enables them, and signs out every terminal of one | [Managing people](docs/commands/people.md) |
| `ehosctl people agreements \| agree \| withdraw` | governed | Lists the applications that ask to read the people, and agrees to or withdraws one in an environment | [Agreements](docs/commands/agreements.md) |
| `ehosctl mail agreements \| agree \| withdraw` | governed | Lists the applications that ask to send mail through EHOS, and agrees how far one may in an environment, changes that, or withdraws it | [Agreements](docs/commands/agreements.md) |
| `ehosctl deploy <app> --env E --image I --manifest F [--graph G]… [--commit SHA] [--ref REF] [--no-wait]` | governed | Deploys an image, by digest, with its manifest, and with each `--graph` one of its graph documents (a domain's, a contract's or a process module's, at most 512), to an environment, and waits until it is active or has failed | [Deploying](docs/commands/deploy.md) |
| `ehosctl deploy <app> --env E --build <id \| commit> \| --build latest --ref REF [--repository OWNER/NAME]` | governed | Deploys a build the application's CI registered, with its own image, manifest and graph documents, and waits as above | [Deploying](docs/commands/deploy.md) |
| `ehosctl deploy <app> --env E --image I --bundle DIR` | governed | Deploys an image with a bundle's manifest and graph documents, each checked against its `bundle.json`, in place of `--manifest` and `--graph` | [Deploying](docs/commands/deploy.md) |
| `ehosctl builds register <dir> --image I` | governed | Registers an image and the bundle beside it as a build of the application; in a GitHub Actions job, with what the checkout says of its commit | [Builds](docs/commands/builds.md) |
| `ehosctl builds list <app> [--ref REF] [--limit N]` | governed | Lists an application's builds, newest first, with their ref, commit and title | [Builds](docs/commands/builds.md) |
| `ehosctl deploy <app> --env E --manifest F --preview` | governed | Prints what deploying a manifest would do, and every reason it would be refused, and deploys nothing | [Deploying](docs/commands/deploy.md) |
| `ehosctl landscape [--env E]` | governed | Shows the environment's applications as one system: who publishes each fact and who subscribes to it, what the picture leaves out, and the deployment each application is drawn from; without `--env`, lists the environments whose landscape you may read, or draws the one there is | `ehosctl help landscape` |
| `ehosctl graph <app> <deployment> [--domain M \| --contract ID \| --process ID]` | governed | Lists the graph documents a deployment carried, its domains', contracts' and process modules', or prints one as JSON | `ehosctl help graph` |
| `ehosctl env list \| show \| create \| extend \| remove \| bind \| unbind` | governed | Lists, creates, extends and removes environments, and binds resources in them | [Environments and resources](docs/commands/env.md) |
| `ehosctl env quota show \| set \| clear` | governed | Shows an environment's quota and limits, gives one that is not ephemeral its own within the installation's ceiling, and gives it back the installation's | [An environment's own quota](docs/commands/env-quota.md) |
| `ehosctl env template list \| show \| create \| update \| remove \| bind \| unbind` | governed | Lists, creates, changes and removes the templates ephemeral environments are made from, and names their resources | [Templates](docs/commands/env-template.md) |
| `ehosctl secret list \| set \| rotate \| delete --app A (--env E \| --template T)` | governed | Lists an application's secrets, sets or rotates one from standard input or a file, and deletes one; never prints a value | [Secrets](docs/commands/secret.md) |
| `ehosctl resources list \| classify` | governed | Lists the resources environments may bind, and sets whether each serves production | [Environments and resources](docs/commands/env.md) |
| `ehosctl role-bindings list \| bind \| unbind` | governed | Lists the role bindings where you manage them, with who granted one through an application and under which rule, and binds and removes roles | [Role bindings](docs/commands/role-bindings.md) |
| `ehosctl trust list \| add \| remove --app A` | governed | Lists, adds and removes the GitHub repositories whose Actions jobs may deploy to an application's ephemeral environments with no stored secret | [Deploying from GitHub Actions](docs/commands/github-actions.md) |
| `ehosctl github list \| claim \| remove` | governed | Lists your GitHub accounts and the refused runs you may claim one from, claims one, and removes one | [Deploying from GitHub Actions](docs/commands/github-actions.md) |
| `ehosctl people github list \| confirm \| remove` | governed | Lists the GitHub accounts people claim, confirms one, and removes one | [Deploying from GitHub Actions](docs/commands/github-actions.md) |
| `ehosctl logs <app> --env E \| --platform [--deployment ID] [--since S] [--grep T] [--limit N] [--follow]` | governed | Prints an application's logs in an environment, or EHOS's own, newest last, and with `--follow` new lines as they come | `ehosctl help logs` |
| `ehosctl audit [--limit N]` | governed | Lists the audit record's newest decisions where you may read it | [The audit record, your activity and your agents](docs/commands/audit.md) |
| `ehosctl activity [--limit N]` | governed | Lists the decisions made in your name or your agents' | [The audit record, your activity and your agents](docs/commands/audit.md) |
| `ehosctl agents list \| create <name>` | governed | Lists your agents, and creates one | [The audit record, your activity and your agents](docs/commands/audit.md) |
| `ehosctl verify [--no-test]` | governed | Checks the application in this directory as its CI does, then asks EHOS to check its `ehos.yaml` and manifest when you are signed in | [Checking an application](docs/commands/verify.md) |
| `ehosctl installation` | governed | Shows where the installation runs, and what its nodes, environments and applications use now | [Where the installation runs, and what it uses](docs/commands/installation.md) |
| `ehosctl versions` | governed | Shows each EHOS component in use, the newest release, whether the installation accepts each, and the command that moves to it | [What is in use, and what is newer](docs/commands/versions.md) |
| `ehosctl changelog <component> [--since V] [--web]` | governed | Prints what changed in a component's releases newer than the version in use | [What is in use, and what is newer](docs/commands/versions.md) |
| `ehosctl doctor [--json]` | platform | Checks OpenTofu, Helm and kubectl at EHOS's versions, ssh and a cloud account, for the platform commands; installs nothing | [The server under an installation](docs/commands/server.md) |
| `ehosctl server up \| tunnel [--close] \| status \| down` | platform | Makes, reaches, reads and removes the server under an installation, in Oracle Cloud, AWS, GCP or OVHcloud, from an EHOS release's OpenTofu modules | [The server under an installation](docs/commands/server.md) |
| `ehosctl install [--installation N] [--version V] [--host H] [--sign-in-absolute D] [--sign-in-idle D] [--four-eyes \| --no-four-eyes] [--smtp-host H] [--smtp-port P] [--smtp-username U] [--mail-from A] [--no-mail] [--switch-traefik [--ssh-key PATH]]` | platform | Installs EHOS, by version, on the server under an installation, records what runs in the cluster, and keeps the installation for `login` | [Installing EHOS on the server](docs/commands/install.md) |
| `ehosctl upgrade [--installation N] [--to V]` | platform | Moves EHOS on the server under an installation to another release, after printing the notes of every release on the way | [Upgrading EHOS on the server](docs/commands/upgrade.md) |
| `ehosctl server invite <email> [--installation N]` | platform | Prints a link that signs a person in once, within 15 minutes, inviting them if they are new: the first person, who becomes the platform's administrator while nobody is, or one who forgot their password. The link is a password | [Inviting a person as the operator](docs/commands/server-invite.md) |
| `ehosctl --version` | | Prints the version, and for a build between releases the commit it was built from |  |
| `ehosctl --help` | | Prints the version, the commands, and what `init` creates an application from: the template (`ehos_app`'s version and commit), Erlang, Elixir, `phx_new` and `igniter_new`, and the contract engine's release that template pins |  |

Every command's help comes from its declaration ([T-06](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0006-ehosctl-reads-its-command-line-with-optimus-and-writes-to-the-terminal-with-owl.md)),
and is asked for in any of these ways: `ehosctl help init`, `ehosctl init --help`,
`ehosctl init -h`. It ends with the command's plane, as
[eh-os D-87](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0087-ehosctl-is-one-tool-for-the-developer-and-the-operator-with-a-governed-plane-through-the-api-and-a-platform-plane-outside-it.md)
requires of every command:

- **governed**: acts as you, through EHOS, which decides and records every request. These take
  `--installation` ([Installations](docs/commands/installations.md)).
- **platform**: acts with an account EHOS does not issue: a cloud provider's, an SSH key, or a
  kubeconfig.
- **local**: works on this machine alone, and needs no EHOS.

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

Elixir is precompiled everywhere. A PostgreSQL has to be running for `mix ecto.setup`, as on macOS.

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

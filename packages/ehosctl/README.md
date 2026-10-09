# ehosctl

The command-line tool for [EHOS](https://github.com/empoweredhouse/eh-os).

`ehosctl` will be to EHOS what `gcloud` is to a cloud: one way in from the terminal, through the
same API and the same authorization as the console. Its first command needs no EHOS at all. It
creates a new application:

```sh
ehosctl init shop
```

It signs you in to an installation of EHOS from the terminal (`login`, `whoami`, `logout`). The
other commands that talk to EHOS (`roles`, calling a declared command, `verify`) arrive as EHOS
defines the API behind them, in Stage 7 of its
[roadmap](https://github.com/empoweredhouse/eh-os/blob/main/docs/ROADMAP.md).

## Installing

`ehosctl` is a single binary that carries its own Erlang runtime, so it needs nothing installed to
run. It does need [mise](https://mise.jdx.dev/installing-mise.html), which `init` uses to provide
the generated project's toolchain. It runs on macOS and Linux, on arm64 and x64. Windows is not
supported: see [Windows](#windows).

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

| Command | Plane | What it does |
| --- | --- | --- |
| `ehosctl init <name>` | local | Creates the application `<name>` in the directory `./<name>` |
| `ehosctl installations list` | local | Lists the installations you know, marking the current one |
| `ehosctl installations use <name>` | local | Makes an installation the current one |
| `ehosctl installations remove <name>` | local | Forgets an installation, leaving its sign-in: run `logout` first |
| `ehosctl login [<url>]` | governed | Signs you in to an installation through your browser, adding it if it is new |
| `ehosctl whoami` | governed | Says who you are signed in as, to which installation, and until when |
| `ehosctl logout` | governed | Ends your sign-in at EHOS, and forgets it on this machine |
| `ehosctl --version` | | Prints the version |
| `ehosctl --help` | | Prints the version, the commands, and what `init` creates an application from: the template (`ehos_app`'s version and commit), Erlang, Elixir, `phx_new` and `igniter_new`, and that the contract engine follows eh-os-contract's `main` |

Every command's help comes from its declaration ([T-06](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0006-ehosctl-reads-its-command-line-with-optimus-and-writes-to-the-terminal-with-owl.md)),
and is asked for in any of these ways: `ehosctl help init`, `ehosctl init --help`,
`ehosctl init -h`. It ends with the command's plane, as
[eh-os D-87](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0087-ehosctl-is-one-tool-for-the-developer-and-the-operator-with-a-governed-plane-through-the-api-and-a-platform-plane-outside-it.md)
requires of every command:

- **governed**: acts as you, through EHOS, which decides and records every request. These take
  `--installation` (below).
- **platform**: acts with an account EHOS does not issue: a cloud provider's, an SSH key, or a
  kubeconfig.
- **local**: works on this machine alone, and needs no EHOS.

### Output and exit codes

A command prints words for a person on stdout. One that takes `--json` prints one JSON document
there instead, for a script; a command without it refuses `--json` as an invalid command line.
Errors go to stderr: one line, `ehosctl: …`, or under `--json` one JSON object,
`{"error": {"kind": "invalid", "message": "…"}}`.

The exit code says what kind of error it was, and a kind keeps its code from one version to the
next:

| Code | Kind | Meaning |
| --- | --- | --- |
| 0 | | Done |
| 1 | `failed` | The command failed for a reason of its own, which it names |
| 2 | `invalid` | The command line is not one `ehosctl` accepts: an unknown command, option or name |
| 3 | `refused` | EHOS refused the request |
| 4 | `not_signed_in` | Not signed in, or the sign-in has expired or ended: run `ehosctl login`. Also when no installation is current, or the one named is unknown |
| 5 | `unreachable` | The installation did not answer |

`init` is the exception: when one of its steps fails, it exits with that step's own exit code. It
also says what is left behind: a half-generated directory to remove before trying again, or, when
the project was already generated, the one setup step to finish by hand.

### Installations

The installations of EHOS you know are kept under names you give them, one of them current, as
kubectl keeps its contexts
([T-07](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md)).
A governed command talks to the one `--installation <name>` names, else the one
`EHOSCTL_INSTALLATION` names, else the current one.

They are kept in `config.json`, in `$EHOSCTL_CONFIG_DIR`, else `$XDG_CONFIG_HOME/ehosctl`, else
`~/.config/ehosctl`, on macOS too. The file holds no secret:

```json
{
  "version": 1,
  "current": "staging",
  "installations": {
    "local": {"url": "http://ehos.localhost"},
    "staging": {"url": "https://ehos.staging.example.com"}
  }
}
```

`ehosctl` writes it whole and renames it into place, creates its directory readable only by you,
and refuses a directory others can write to. A `config.json` that is a link, as a dotfiles manager
makes it, is rewritten through the link.

`ehosctl login <url>` adds an installation, and `ehosctl login` signs in to one again.

### Signing in

`ehosctl login https://ehos.example.com` opens your browser at EHOS's log-in page, where you type
your password; `ehosctl` never sees it
([eh-os D-89](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0089-ehosctl-signs-a-person-in-as-a-public-client-through-a-loopback-redirect-and-gets-each-credential-by-renewal.md)).
The browser comes back to `ehosctl` on `127.0.0.1`, on a port it picks. If the browser does not
open, `ehosctl` prints the address to open by hand. On a machine you reach over SSH, forward that
port, or sign in on your own machine.

- **The address** is an origin: `https://` and a host, with a port if it needs one, and nothing
  after it. EHOS signs no one in over plain HTTP, so neither does `ehosctl`.
- **A local EHOS** has a certificate from a CA of its own, which your system does not trust: for
  the k3d cluster at `https://ehos.localhost`, its `_build/k3d/ca.crt`. Name it in
  `EHOSCTL_CA_FILE`, a PEM file of CA certificates `ehosctl` trusts besides the system's, as
  `curl --cacert` does:

  ```sh
  EHOSCTL_CA_FILE=<path to eh-os>/_build/k3d/ca.crt ehosctl login https://ehos.localhost
  ```

  Every command that talks to EHOS needs it, so export it for as long as you use that
  installation.
- **The installation** is kept under `--installation <name>`, or under a name made from the host:
  `ehos.staging.example.com` is `staging`, and this machine is `local`. It becomes the current
  one. `ehosctl login` with no address signs in again to the current installation, or to the one
  `--installation` names.
- **How long it lasts.** Seven days from when you typed your password, or three days without a
  command that renews it, whichever comes first. EHOS can end it sooner: when you change your
  password, when someone disables your account, or when a terminal's sign-in is revoked from the
  console. `ehosctl whoami` says until when.
- **Where it is kept**
  ([T-08](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0008-ehosctl-keeps-a-sign-in-s-refresh-token-in-the-system-s-keychain-else-a-file-only-the-user-reads-and-renews-under-a-lock.md)).
  The refresh token goes in the system's keychain: Keychain on macOS, the Secret Service on Linux
  (it needs `secret-tool`, from `libsecret-tools`). Without one, it goes in a file only you can
  read, and `login` says so. `EHOSCTL_TOKEN_STORE=file` chooses the file. Beside it, in
  `$EHOSCTL_STATE_DIR`, else `$XDG_STATE_HOME/ehosctl`, else `~/.local/state/ehosctl`, are the
  ten-minute credentials it renews, each kept until it expires, and a lock that keeps two commands
  from renewing at once. Who you are and until when is in `config.json`, beside the installation.
- **`ehosctl logout`** ends the sign-in at EHOS, then forgets it here. When EHOS does not answer,
  it forgets the sign-in all the same, and says that EHOS was not told. It does not sign your
  browser out of EHOS: the two are separate sign-ins.

### `ehosctl init <name>`

`<name>` becomes the OTP application's name. It is lowercase letters, digits and underscores,
starts with a letter and ends with a letter or a digit. A dash is written as an underscore, since
an OTP application's name allows none, and `init` says so: `ehosctl init my-shop` generates
`my_shop/`. In EHOS the application is named with dashes, as its domain is: `my-shop`. `init`
refuses a directory that already exists.

What it runs, in order. Each step gets the terminal's own stdin, stdout and stderr, so a step that
asks a question can be answered and errors stay on stderr. Each Mix step runs under
`mise exec erlang@<pin> elixir@<pin> --`, and `mise install` and every Mix step with
`MISE_ACTIVATE_AGGRESSIVE=1`, so that the pinned versions come first on the `PATH` even where
asdf's shims come before mise's (the root README, "Getting started", says what that means for
the generated project):

0. `mise install erlang@<pin> elixir@<pin>`, which does nothing once they are installed. Without
   it, `mise exec` would have to install a missing Elixir itself, and it runs the new Elixir's
   check without the Erlang named next to it on the path, so it fails with `erl: not found`.
1. `mix local.hex`, `mix archive.install hex phx_new <pin>` and
   `mix archive.install hex igniter_new <pin>`. These go into a directory that belongs to this
   `ehosctl` version, not your `~/.mix`, and are skipped when already there.
2. `mix igniter.new <name> --with phx.new --with-args "--database postgres" --yes --no-git`,
   which creates the Phoenix project.
3. In `<name>/`, `mix run --no-start -e '… Igniter.Util.Install.install([<ehos_app>], ["--example", "--yes"])'`,
   which adds [`ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/README.md) from `packages/ehos_app` of ehos-tools at the
   pinned commit and runs its installer, and Oban's with it. `mix igniter.new --install` would be
   simpler, but its spec cannot name a subdirectory.
4. `mix local.hex --if-missing`, for the pinned Elixir, so the project's own first `mix` command
   does not stop to ask for Hex.
5. `mise trust <name>/.tool-versions`, so `cd <name>` puts the pinned toolchain on the path.
6. `git init`, `git add --all` and `git commit` in `<name>/`: the project's first commit, of
   everything above.

On the machine it was measured on (macOS arm64, Hex packages already cached), `init` took 80–85
seconds, most of it fetching and compiling dependencies. The first `mise exec` of a toolchain adds
about 10 seconds, since mise installs precompiled builds.

### What it pins

All of it is in [`lib/ehosctl/template.ex`](lib/ehosctl/template.ex). One release of `ehosctl`
always generates the same project:

| Pin | Value |
| --- | --- |
| Erlang | 28.5.0.7 |
| Elixir | 1.20.4-otp-28 |
| `phx_new` | 1.8.14 |
| `igniter_new` | 0.5.34 |
| `ehos_app` | [`packages/ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/tree/main/packages/ehos_app) of ehos-tools at `9c97894`, the commit the tag `ehos_app-v0.6.0` names |

### Where it writes

| What | macOS | Linux |
| --- | --- | --- |
| The new project | `./<name>` | `./<name>` |
| Installations (`config.json`) | `~/.config/ehosctl` | `$XDG_CONFIG_HOME/ehosctl`, by default `~/.config/ehosctl` |
| Sign-ins | the login keychain, and `~/.local/state/ehosctl` | the Secret Service, and `$XDG_STATE_HOME/ehosctl`, by default `~/.local/state/ehosctl` |
| Generator archives | `~/Library/Caches/ehosctl/<version>/mix_archives` | `$XDG_CACHE_HOME/ehosctl/<version>/mix_archives`, by default under `~/.cache` |
| Erlang and Elixir | wherever mise installs tools (`~/.local/share/mise` by default) | the same |
| The unpacked `ehosctl` runtime | `~/Library/Application Support/.burrito/` | `$XDG_DATA_HOME/.burrito/`, by default under `~/.local/share` |

`ehosctl maintenance uninstall` removes the unpacked runtime. `EHOSCTL_INSTALL_DIR` moves it.

### Environment variables

| Variable | Effect |
| --- | --- |
| `EHOSCTL_TEMPLATE_SOURCE` | Replaces the pinned `ehos_app` source, for working on the template: `path:/abs/path/to/packages/ehos_app` for a local checkout, or `ref:<commit, branch or tag>` for another ref of ehos-tools |

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

The gate checks the formatting, compiles with warnings as errors, runs the tests and builds the
documentation with warnings as errors. The tests never start mise, Mix or the network:
`Ehosctl.Init` builds its steps as data and runs them through an injected runner, and the
configuration is read from a temporary directory.
[`AGENTS.md`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/AGENTS.md#trying-a-change-end-to-end)
describes the end-to-end run, from the binary to a generated project passing `mix precommit`.

`mix docs` builds the reference into `doc/` with ExDoc. Every public module has a `@moduledoc`,
and every public function a `@doc` and a `@spec`; `Ehosctl.DocsTest` fails on one without.

| Module | Role |
| --- | --- |
| `Ehosctl.Application` | Runs the command in the binary and halts with its exit code, turning an unexpected exception into one line and exit code 1 |
| `Ehosctl.CLI` | Reads argv with Optimus, runs the command and returns its exit code |
| `Ehosctl.Command` | What every command declares: its name, its declaration for Optimus, its plane, and the function that runs it |
| `Ehosctl.Output` | Words or JSON on stdout, errors on stderr, and the exit code of each kind of error |
| `Ehosctl.Config` | The installations you know, and which one a governed command talks to |
| `Ehosctl.Init` | `init`: validates, builds its steps, runs them |
| `Ehosctl.Installations` | `installations list`, `use` and `remove` |
| `Ehosctl.Template` | Every pin `init` generates from |

A new command is a module implementing `Ehosctl.Command`, added to `Ehosctl.CLI`'s list and,
with its plane, to the list in `Ehosctl.CommandTest`, which fails until it is.

Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

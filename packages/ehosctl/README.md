# ehosctl

The command-line tool for [EHOS](https://github.com/empoweredhouse/eh-os).

`ehosctl` will be to EHOS what `gcloud` is to a cloud: one way in from the terminal, through the
same API and the same authorization as the console. Its first command needs no EHOS at all. It
creates a new application:

```sh
ehosctl init shop
```

The commands that talk to EHOS (`login`, `identities`, calling a declared command, `verify`) arrive
as EHOS defines the API behind them, in Stage 7 of its
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

| Command | What it does |
| --- | --- |
| `ehosctl init <name>` | Creates the application `<name>` in the directory `./<name>` |
| `ehosctl init --help` | Prints the usage of `init` |
| `ehosctl --version` | Prints the version |
| `ehosctl --help` | Prints the version, usage, and what `init` creates an application from: the template (`ehos_app`'s version and commit), Erlang, Elixir, `phx_new` and `igniter_new`, and that the contract engine follows eh-os-contract's `main` |

Every command exits with `0` on success and a non-zero code otherwise. When a step of `init` fails,
`init` exits with that step's own exit code. It also says what is left behind: a half-generated
directory to remove before trying again, or, when the project was already generated, the one setup
step to finish by hand.

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
   which adds [`ehos_app`](../ehos_app/README.md) from `packages/ehos_app` of ehos-tools at the
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
| `ehos_app` | [`packages/ehos_app`](../ehos_app) of ehos-tools at `c4e103f`, the commit the tag `ehos_app-v0.6.1` names |

### Where it writes

| What | macOS | Linux |
| --- | --- | --- |
| The new project | `./<name>` | `./<name>` |
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

You need the toolchain in [`.tool-versions`](.tool-versions) (for example, run `mise install` here),
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

The tests never start mise, Mix or the network: `Ehosctl.Init` builds its steps as data and runs
them through an injected runner. [`AGENTS.md`](../../AGENTS.md#trying-a-change-end-to-end)
describes the end-to-end run, from the binary to a generated project passing `mix precommit`.

| Module | Role |
| --- | --- |
| `Ehosctl.Application` | Runs the command in the binary and halts with its exit code, turning an unexpected exception into one line and exit code 1 |
| `Ehosctl.CLI` | Dispatches argv to a command and returns its exit code |
| `Ehosctl.Init` | `init`: validates, builds its steps, runs them |
| `Ehosctl.Template` | Every pin `init` generates from |

Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

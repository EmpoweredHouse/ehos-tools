# ehosctl

The command-line tool for [EHOS](https://github.com/EmpoweredHouse/eh-os).

`ehosctl` will be to EHOS what `gcloud` is to a cloud: one way in from the terminal, through the
same API and the same authorization as the console. Its first command needs no EHOS at all. It
creates a new application:

```sh
ehosctl init shop
```

The commands that talk to EHOS (`login`, `identities`, calling a declared command, `verify`) arrive
as EHOS defines the API behind them, in Stage 7 of its
[roadmap](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ROADMAP.md).

## Installing

`ehosctl` is a single binary that carries its own Erlang runtime, so it needs nothing installed to
run. It does need [mise](https://mise.jdx.dev), which `init` uses to provide the generated
project's toolchain.

Once the Homebrew tap is published, one command installs both:

```sh
brew install empoweredhouse/tap/ehosctl
```

Until then, [build it from source](#building-the-binary).

## Commands

| Command | What it does |
| --- | --- |
| `ehosctl init <name>` | Creates the application `<name>` in the directory `./<name>` |
| `ehosctl --version` | Prints the version |
| `ehosctl --help` | Prints usage |

Every command exits with `0` on success and a non-zero code otherwise. When a step of `init` fails,
`init` exits with that step's own exit code.

### `ehosctl init <name>`

`<name>` becomes the OTP application name. It is lowercase letters, digits and underscores, and
starts with a letter. `init` refuses a directory that already exists.

What it runs, in order. Each Mix step runs under `mise exec erlang@<pin> elixir@<pin> --`:

1. `mix local.hex`, `mix archive.install hex phx_new <pin>` and
   `mix archive.install hex igniter_new <pin>`. These go into a directory that belongs to this
   `ehosctl` version, not your `~/.mix`, and are skipped when already there.
2. `mix igniter.new <name> --with phx.new --with-args "--database postgres" --install ehos_app@<pin> --example --yes`.
   This creates the Phoenix project and runs the [`ehos_app`](../ehos_app/README.md) installer on
   it.
3. `mix local.hex --if-missing`, for the pinned Elixir, so the project's own first `mix` command
   does not stop to ask for Hex.
4. `mise trust <name>/.tool-versions`, so `cd <name>` puts the pinned toolchain on the path.

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
| `ehos_app` | `github:EmpoweredHouse/ehos_app@v0.1.0`, which does not exist yet: see [docs/spike.md](../../docs/spike.md) |

### Where it writes

| What | Where (macOS) |
| --- | --- |
| The new project | `./<name>` |
| Generator archives | `~/Library/Caches/ehosctl/<version>/mix_archives` |
| Erlang and Elixir | wherever mise installs tools (`~/.local/share/mise` by default) |
| The unpacked `ehosctl` runtime | `~/Library/Application Support/.burrito/`, removed by `ehosctl maintenance uninstall` |

On Linux, the caches follow the XDG directories.

### Environment variables

| Variable | Effect |
| --- | --- |
| `EHOSCTL_TEMPLATE_SOURCE` | Replaces the pinned `ehos_app` source, for working on the template. Takes Igniter's syntax: `path:/abs/path/to/ehos_app`, `github:org/repo@ref`, `git:url@ref` |

## Building the binary

You need the toolchain in [`.tool-versions`](.tool-versions) (for example, run `mise install` here),
plus [Zig](https://ziglang.org) 0.16.0 exactly and `xz`. With Homebrew: `brew install zig xz`.

```sh
mix deps.get
MIX_ENV=prod BURRITO_TARGET=macos_arm mix release
burrito_out/ehosctl_macos_arm --version
```

The targets are `macos_arm`, `macos_x86`, `linux_arm` and `linux_x86`. Without `BURRITO_TARGET`,
all four are built. Any of them builds from macOS or Linux.

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
| `Ehosctl.Application` | Runs the command in the binary and halts with its exit code |
| `Ehosctl.CLI` | Dispatches argv to a command and returns its exit code |
| `Ehosctl.Init` | `init`: validates, builds its steps, runs them |
| `Ehosctl.Template` | Every pin `init` generates from |

Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

# Research: how `ehosctl init` gets to a developer's machine

Done on 2026-09-24, before the spike in [`spike.md`](spike.md). Versions are the ones current on
that day.

## The requirement

A developer installs one tool and runs `ehosctl init <name>`. They do not need to know where the
template comes from, and they do not need Erlang or Elixir installed first. `init` needs no
EHOS: it only writes files. Later commands (`login`, `verify`, calling a command) go through the
EHOS API and are defined by EHOS's Stage 7.

There are two separate runtime needs, and conflating them is the trap:

1. **Running `ehosctl` itself.** Solved by shipping a binary that carries its own runtime.
2. **Working on the generated project.** Needs one specific, pinned pair of Erlang and Elixir, the
   same one CI and the Dockerfile use. A package manager's "latest Elixir" is not that.

## Decisions and why

| Question | Choice | Why | Rejected |
| --- | --- | --- | --- |
| How is `ehosctl` built? | [Burrito](https://github.com/burrito-elixir/burrito) 1.6.0: one binary per target, ERTS inside | No Erlang needed to run it; the precedent is Next LS, distributed the same way | escript (needs Erlang present first); Bakeware (archived) |
| How is it installed? | mise's `github:` backend (`mise use -g github:EmpoweredHouse/ehos-tools`), and a Homebrew tap, `EmpoweredHouse/homebrew-tap`, both from the binaries attached to a GitHub release | `ehosctl` needs mise anyway, so on Linux one tool is enough, and mise checks the download against the release's digest. Homebrew is what macOS developers expect; taps may ship binaries, homebrew-core may not | homebrew-core (forbids prebuilt binaries); a `curl … \| sh` installer (a script to maintain, and a pattern worth not teaching); Scoop and winget (Windows is out of scope) |
| Which platforms? | macOS and Linux, each on arm64 and x64 | What developers of EHOS applications use, and what CI can prove end to end on hosted runners | Windows, for now: `init` depends on handing the terminal to each step, which Erlang ports cannot do there (see the facts below) |
| How is it proven on each platform? | GitHub Actions: `jdx/mise-action`, `mlugg/setup-zig`, `ikalnytskyi/action-setup-postgres`, one Linux runner building all four targets, and one end-to-end job per platform on `macos-15`, `macos-15-intel`, `ubuntu-24.04` and `ubuntu-24.04-arm` | Each binary is tested where it runs, with only mise installed, as a developer would have it. The Postgres action works the same on macOS and Linux | `erlef/setup-beam` (would install the toolchain `init` must install itself); service containers (Linux only) |
| How does the project get Erlang and Elixir? | [mise](https://mise.jdx.dev/lang/erlang.html), a formula dependency; `init` runs everything under `mise exec erlang@X elixir@Y --` | Installs precompiled builds in seconds (measured: 11 s on macOS arm64), pins exact versions, and needs no global install | `depends_on "elixir"` in the formula: unpinned, and Homebrew's Elixir has shipped with an Erlang it did not support ([Homebrew #6192](https://github.com/orgs/Homebrew/discussions/6192)) |
| What pins the project's versions? | `.tool-versions` | Read by both mise and asdf; `mise.toml` is ignored by asdf (measured, see the spike) | `mise.toml` |
| What is the template? | An [Igniter](https://hexdocs.pm/igniter/readme.html) installer, run by `mix igniter.new --with phx.new --install ehos_app@…` | Standard in the ecosystem (Ash, Oban, Phoenix tooling), patches code instead of copying it, and has an upgrade path (`mix igniter.upgrade`) for projects generated long ago | a template repository (cannot be upgraded); our own generator (more to maintain) |
| Where does the template version come from? | Pinned into each `ehosctl` release | One `ehosctl` version means one template, the way one `phx_new` archive means one Phoenix template | fetching the latest at run time (what `encore app create` does) |

## Facts the design depends on

- **Burrito 1.6.0 requires Zig 0.16.0 exactly.** It refuses any other version, and its README
  still says 0.15.2, which is out of date. It needs `xz` too, and `7z` only for Windows targets.
- **Burrito bundles the ERTS matching the build host's exact OTP version**, downloaded from a
  third-party CDN (beam-machine). The CDN lags the newest patch: on 2026-09-24, OTP 28.5.0.7
  and 29.1.1 returned 404, while 28.5.0.6 and 29.0.6 were there.
- **Burrito's launcher runs `-s elixir start_cli` after boot**, which reads the same argv as
  Elixir's own CLI. The command therefore has to run synchronously in `Application.start/2` and
  halt the VM there.
- **Igniter's install spec** (`pkg@github:org/repo@ref`, `@git:`, `@path:`) **has no `sparse:` or
  subdirectory option.** A package installed by `--install` must sit at the root of its
  repository, or be on Hex. `eh_os_contract` lives in a subdirectory, so the installer adds it with
  `Igniter.Project.Deps.add_dep/2`, which does pass `sparse:` through.
- **`mix igniter.new` can run with no prompts:** `--yes --no-installer-version-check`. It needs the
  `phx_new` archive installed and appends `--install` to `phx.new` itself.
- **Oban ships its own Igniter installer**, so `ehos_app` composes it (`installs: [{:oban, …}]`)
  rather than copying Oban's config, migration and supervision child.
- **mise installs precompiled Erlang** on macOS (from `erlef/otp_builds`) and on Ubuntu 20.04–24.04
  (from builds.hex.pm). Elsewhere it compiles from source unless `erlang.precompiled_os` is set.
- **mise gives each Elixir install its own Mix home**, so `mix local.hex` under `mise exec` does not
  touch the developer's `~/.mix`.
- **mise's `github:` backend picks a release asset by name.** It scores the OS (`macos`, `darwin`,
  `linux`) and the architecture (`x64`, `x86_64`, `amd64`, `arm64`, `aarch64`), with `_` as a
  separator. A bare `x86` reads as 32-bit and a bare `arm` as armv7, which only score as a
  fallback, so the targets are named `*_x64` and `*_arm64`
  ([`asset_matcher.rs`](https://github.com/jdx/mise/blob/v2026.9.12/src/backend/asset_matcher.rs)).
- **`mise exec erlang@X elixir@Y --` fails on a machine with neither installed** (mise 2026.9.12):
  it checks the new Elixir by running it before the new Erlang is on its path. `mise install` of
  both at once orders them (measured on Ubuntu 24.04, see the spike).
- **mise's precompiled Erlang on Linux** is detected for Ubuntu 20.04, 22.04 and 24.04, from
  builds.hex.pm, on x64 and arm64. Ubuntu 26.04 needs `MISE_ERLANG_PRECOMPILED_OS=ubuntu-26.04`.
  Other glibc distributions build from source with kerl, and musl is refused.
- **On Windows, `:nouse_stdio` does nothing.** An Erlang port's child there always gets pipes for
  stdin and stdout
  ([`sys/win32/sys.c`](https://github.com/erlang/otp/blob/OTP-28.5.0.7/erts/emulator/sys/win32/sys.c)).
  Burrito has one Windows target, x64, and OTP publishes no Windows arm64 build.
- **Burrito cross-builds every target from one host** with Zig, including macOS from Linux. On Unix
  it pipes the BEAM's stdout ([burrito#234](https://github.com/burrito-elixir/burrito/issues/234)),
  so `mix` output shown through `ehosctl` loses its colours.
- **GitHub's last Intel macOS image is `macos-15-intel`**, available until August 2027
  ([runner-images#13045](https://github.com/actions/runner-images/issues/13045)).
- **Igniter 0.8.4 is the first release without CVE-2026-82584** (terminal escape injection in install
  prompts, 0.8.1–0.8.3).

## Prior art

| Tool | Where its template comes from | Pinned to the CLI version? |
| --- | --- | --- |
| `mix phx.new` | compiled into the `phx_new` archive | yes |
| `mix igniter.new` | installers fetched from Hex or git at run time | only if you pin them |
| `supabase init` | compiled into the Go binary | yes |
| `fly launch` | the project's own `mix phx.gen.release --docker` | follows the project's Phoenix |
| `encore app create` | fetched from a GitHub examples repository | no |

`ehosctl init` combines the first and the fourth: versions pinned in the binary, and the Dockerfile
left to the project's own Phoenix.

## Sources

- [Burrito](https://github.com/burrito-elixir/burrito), [hex.pm/packages/burrito](https://hex.pm/packages/burrito)
- [Next LS installation](https://www.elixir-tools.dev/docs/next-ls/installation/), [elixir-tools/homebrew-tap](https://github.com/elixir-tools/homebrew-tap)
- [Homebrew: How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap), [Homebrew discussion #6192](https://github.com/orgs/Homebrew/discussions/6192)
- [Igniter](https://github.com/ash-project/igniter), [`mix igniter.install`](https://igniter.hexdocs.pm/Mix.Tasks.Igniter.Install.html), [hex.pm/packages/igniter_new](https://hex.pm/packages/igniter_new)
- [mise: Erlang](https://mise.jdx.dev/lang/erlang.html), [mise: Elixir](https://mise.jdx.dev/lang/elixir.html), [mise: `github:` backend](https://mise.jdx.dev/dev-tools/backends/github.html)
- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [`jdx/mise-action`](https://github.com/jdx/mise-action), [`ikalnytskyi/action-setup-postgres`](https://github.com/ikalnytskyi/action-setup-postgres), [`mlugg/setup-zig`](https://codeberg.org/mlugg/setup-zig)
- [Erlang `open_port/2`](https://www.erlang.org/doc/apps/erts/erlang.html#open_port/2)
- [Elixir compatibility and deprecations](https://hexdocs.pm/elixir/compatibility-and-deprecations.html)
- [`mix escript.install`](https://hexdocs.pm/mix/Mix.Tasks.Escript.Install.html)

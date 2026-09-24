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
| How is it installed? | A Homebrew tap, `EmpoweredHouse/homebrew-tap`, with prebuilt binaries per architecture | What the user asked for; taps may ship binaries, homebrew-core may not | homebrew-core (forbids prebuilt binaries) |
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
- [mise: Erlang](https://mise.jdx.dev/lang/erlang.html), [mise: Elixir](https://mise.jdx.dev/lang/elixir.html)
- [Elixir compatibility and deprecations](https://hexdocs.pm/elixir/compatibility-and-deprecations.html)
- [`mix escript.install`](https://hexdocs.pm/mix/Mix.Tasks.Escript.Install.html)

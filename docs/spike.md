# Spike: `ehosctl init`, 2026-09-24

What was built, what was measured on a real machine (macOS arm64), and what is still open. The
reasons behind the stack are in [`research.md`](research.md).

## What works

Starting from the Burrito binary, with no Erlang in the shell:

```sh
EHOSCTL_TEMPLATE_SOURCE=path:…/packages/ehos_app ehosctl init shop
cd shop && mix ecto.setup && mix precommit
```

1. `ehosctl init shop` finished with exit code 0 in 79–85 s. It runs these steps, all under
   `mise exec erlang@28.5.0.7 elixir@1.20.4-otp-28 --`:
   - installs Hex, `phx_new` 1.8.14 and `igniter_new` 0.5.34 into an archives directory owned by
     this `ehosctl` version (`~/Library/Caches/ehosctl/0.1.0/mix_archives`), skipping any already
     there;
   - runs `mix igniter.new shop --with phx.new --install ehos_app@… --example --yes`;
   - installs Hex for the pinned Elixir (in mise's Mix home for it, not `~/.mix`);
   - runs `mise trust` on the new `.tool-versions`.
2. The generated project has:
   - Phoenix 1.8.14 with Postgres;
   - Oban, through Oban's own installer;
   - `eh_os_contract` v0.2.1 from git, pinned by tag;
   - its migration placed after Oban's;
   - `EhOsContract` in the supervision tree after the repo and Oban;
   - `eh_os_contract.check` in `precommit`;
   - `ehos.yaml`, `.tool-versions`, the EHOS section in `AGENTS.md`, `CLAUDE.md`;
   - an example contract, a release and a Dockerfile;
   - one initial git commit.
3. `mix ecto.setup` ran both migrations, and `mix precommit` passed: 5 tests, and
   `eh_os_contract.check` with 0 errors and 0 warnings.
4. The Dockerfile pins the same pair as `.tool-versions` (Elixir 1.20.4, OTP 28.5.0.7), because
   both come from the runtime the generation ran under.

Measured:

| What | Result |
| --- | --- |
| Binary size (macOS arm64) | 9.6 MB |
| Build of one target | about 60 s |
| First run (unpacks the payload) | 2.1 s |
| Later runs | 0.2 s |
| Signature | ad-hoc, applied by Zig's linker |
| First `mise exec` of the pinned Erlang and Elixir | 11 s (precompiled) |

## Found by testing, and fixed

- **Two migrations with one version.** Oban's installer and ours generated migrations in the same
  second, which Ecto refuses to run. Ours now takes the second after the newest existing one.
- **The pin was ignored under asdf.** The first version wrote `mise.toml`. asdf, which the author
  uses, ignores that file, and the project ran on the machine's global Elixir 1.18.4 / OTP 25. The
  template now writes `.tool-versions`, which both tools read.
- **No Hex for the project.** Keeping the generator's archives apart meant the project's own `mix`
  had no Hex and prompted on its first command. `init` now installs it as a final step.
- **The CLI's arguments were Elixir's.** Burrito's launcher runs Elixir's `start_cli` after boot, so
  `ehosctl deploy` ended in "No file named deploy". The command now runs synchronously in
  `Application.start/2` and halts.
- **Stale code after a rebuild.** A `prod` Burrito binary reuses the payload it already unpacked
  for its version, so a rebuild without a version bump runs the old code. This is documented in
  `packages/ehosctl/README.md` rather than fixed.
- **The example contract warned.** It lacked `accountable`, so it now declares one.

## Open: decisions this spike cannot make

1. **The engine is in a private repository, and a Docker build cannot fetch it.** `docker build`
   of the generated project failed at `mix deps.get`: `could not read Username for
   'https://github.com'`. It worked on the laptop only because of the author's git credentials, and
   CI has the same problem. There are three ways out, and choosing one is a product decision:
   - make `eh-os-contract` public (it is meant for the Community edition anyway);
   - publish it to a private Hex organisation;
   - make the template's Dockerfile and CI take a build secret (BuildKit `--mount=type=secret` or
     `--ssh`).
2. **Where does `ehos_app` live?** Igniter cannot install from a subdirectory, so the default
   source pinned in `ehosctl` (`github:EmpoweredHouse/ehos_app@v0.1.0`) assumes a repository whose
   root *is* `ehos_app`. That repository does not exist yet. The alternative is Hex, public or a
   private organisation, which would also solve point 1 for the engine.
3. **What EHOS requires of an application is guessed.** EHOS reads `ehos.yaml` from its Stage 6 and
   has not fixed the application's environment yet. The template therefore guesses:
   - the `ehos.yaml` fields, taken from EHOS's [ARCHITECTURE.md](https://github.com/empoweredhouse/eh-os/blob/main/docs/ARCHITECTURE.md) §5.1;
   - that health endpoints exist, which it names in `ehos.yaml` but does not serve;
   - one public port;
   - Phoenix's default environment variables (`DATABASE_URL`, `PORT`).
4. **The harness is thin.** It is an `AGENTS.md` section and a `CLAUDE.md`. The six skills in
   [eh-os-contract's `.claude/skills/`](https://github.com/empoweredhouse/eh-os-contract/tree/main/.claude/skills) are drafts that name the sandbox's paths, so they were not copied.
   An `ehosctl harness update` needs them made generic first, and a way to ship them (Igniter
   upgrade steps, or a Claude Code plugin).
5. **The toolchain CDN is a third party.** Burrito downloads ERTS from beam-machine's CDN, which
   lags the newest OTP patch, and nobody controls it. `ehosctl` is therefore built on OTP 29.0.6
   while the template pins 28.5.0.7. The fallback, if this becomes a problem, is Burrito's
   `custom_erts` with a self-hosted build.

## Not done yet

- **CI** that builds the four targets and publishes a release. One Linux runner can build all of
  them.
- **The Homebrew tap.** A draft formula is in `packaging/homebrew/ehosctl.rb`, not tested.
- **Linux**, where mise's precompiled Erlang covers only Ubuntu 20.04–24.04.
- **An upstream warning in eh-os-contract.** Elixir 1.20 warns about a clause that is never used in
  `EhOsContract.Trace.suspended?/3` (`lib/eh_os_contract/trace.ex:370`).

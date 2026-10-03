# Spike: `ehosctl init`, 2026-09-24

What was built, what was measured on a real machine (macOS arm64), and what is still open. The
reasons behind the stack are in [`research.md`](research.md). Linux and the CI that proves both
platforms came after, in [Linux and CI](#linux-and-ci).

## What works

Starting from the Burrito binary, with no Erlang in the shell:

```sh
EHOSCTL_TEMPLATE_SOURCE=path:…/packages/ehos_app ehosctl init shop
cd shop && mix ecto.setup && mix precommit
```

1. `ehosctl init shop` finished with exit code 0 in 79–85 s. It installs the pinned Erlang and
   Elixir with `mise install`, then runs these steps, all under
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

   **Decided on 2026-09-30: a BuildKit secret.** The generated Dockerfile mounts a GitHub token
   with `--mount=type=secret` for `mix deps.get` alone, so it never reaches a layer of the image.
   The generated CI gets that token from a GitHub App with read access to `eh-os-contract`. EHOS's
   own plan for its first deployment assumes the same
   ([stage-5-first-deployment.md](https://github.com/empoweredhouse/eh-os/blob/main/docs/plans/stage-5-first-deployment.md), step 3).
   Making `eh-os-contract` public would remove the secret, and stays possible later.
2. **Where does `ehos_app` live?** Igniter cannot install from a subdirectory, so the default
   source pinned in `ehosctl` (`github:EmpoweredHouse/ehos_app@v0.1.0`) assumes a repository whose
   root *is* `ehos_app`. That repository does not exist yet. The alternative is Hex, public or a
   private organisation, which would also solve point 1 for the engine.

   **Decided on 2026-09-30: from this repository, with `sparse:`.** A mirror,
   `EmpoweredHouse/ehos_app`, was decided first and replaced the same day, before it was ever
   filled: it was a second repository to explain and to grant CI write access to. Igniter's install
   spec has no `sparse:`, but `Igniter.Util.Install.install/2`, the function behind
   `mix igniter.install`, takes a dependency as Mix writes it and still composes the installers
   the package declares. So `ehosctl init` runs `igniter.new` without `--install` and without git,
   then `mix run --no-start` in the new project with
   `{:ehos_app, github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_app", tag: "ehos_app-v…"}`,
   then makes the first commit itself. Tried on 2026-09-30 with a macOS arm64 binary: `init shop`
   finished in 72 s, Oban was installed through its own installer, the project passed
   `mix ecto.setup` and `mix precommit`, and `mix igniter.upgrade ehos_app` found the git
   dependency. A generated project's CI and image never fetch `ehos_app`, which is `only: :dev`.
   A `path:` source stays for trying the template only: Igniter writes the absolute path into the
   generated `mix.exs`.
3. **What EHOS requires of an application is guessed.** EHOS reads `ehos.yaml` from its Stage 6 and
   has not fixed the application's environment yet. The template therefore guesses:
   - the `ehos.yaml` fields, taken from EHOS's [ARCHITECTURE.md](https://github.com/empoweredhouse/eh-os/blob/main/docs/ARCHITECTURE.md) §5.1;
   - that health endpoints exist, which it names in `ehos.yaml` but does not serve;
   - one public port;
   - Phoenix's default environment variables (`DATABASE_URL`, `PORT`).

   **Answered by EHOS on 2026-09-29, and followed since 2026-09-30:** see
   [The template on EHOS's decisions](#the-template-on-ehoss-decisions-2026-09-30).
4. **The harness is thin.** It is an `AGENTS.md` section and a `CLAUDE.md`. The six skills in
   [eh-os-contract's `.claude/skills/`](https://github.com/empoweredhouse/eh-os-contract/tree/main/.claude/skills) are drafts that name the sandbox's paths, so they were not copied.
   An `ehosctl harness update` needs them made generic first, and a way to ship them (Igniter
   upgrade steps, or a Claude Code plugin).

   **Built on 2026-10-02, on the model of shugyo's harness:** a lean `AGENTS.md`, `VISION.md` with
   what EHOS is, `ARCHITECTURE.md`, `TESTING.md`, nested `AGENTS.md` files for the contracts and
   the web layer, four skills from shugyo, CodeRabbit, and `test/harness_test.exs`
   ([packages/ehos_app](../packages/ehos_app/README.md#what-the-installer-does)). What EHOS
   requires is in sections the installer rewrites, so it reaches an application on an upgrade.

   Still open:
   - The copied skills and the seeds are never refreshed in an existing application, which is the
     `ehosctl harness update` question above.
   - The ecosystem's packages do not ship their own rules for agents. [`usage_rules`](https://hexdocs.pm/usage_rules)
     is the community's tool for it, and the markers in Phoenix's `AGENTS.md` are its format: each
     package ships a `usage-rules.md`, and `mix usage_rules.sync` writes them into `AGENTS.md` from
     the versions in `deps/`. It was not adopted yet because it needs a `usage-rules.md` in
     eh-os-contract, it may not find a `sparse:` dependency (it globs `deps/*/usage-rules.md`),
     and a `--check` in CI would need `ehos_app`, which is `only: :dev`, in `:test`. The
     installer's managed section of `AGENTS.md` is the part it would replace.
   - A project generated by 0.2 keeps Phoenix's rules in its `AGENTS.md`, over the 200 lines its
     harness test allows, until the developer moves them; the installer says how.
5. **The toolchain CDN is a third party.** Burrito downloads ERTS from beam-machine's CDN, which
   lags the newest OTP patch, and nobody controls it. `ehosctl` is therefore built on OTP 29.0.6
   while the template pins 28.5.0.7. The fallback, if this becomes a problem, is Burrito's
   `custom_erts` with a self-hosted build.

6. **The last two steps of `init` help only mise users.** Hex is installed into the Mix home of
   mise's Elixir, and `mise trust` is mise's own. Someone who opens the project under asdf gets
   asdf's Elixir, which has no Hex, so the first `mix` command asks for it: the problem listed
   above as fixed comes back for them. Fixing it means knowing which version manager the developer
   uses, or asking.

## The template on EHOS's decisions, 2026-09-30

EHOS answered Open point 3 on 29 September 2026, in eh-os
[D-51](https://github.com/empoweredhouse/eh-os/blob/main/docs/adr/0051-ehos-yaml-is-defined-by-ehos.md)
(`ehos.yaml` is EHOS's, as the JSON Schema `ehos.yaml/v1`),
[D-55](https://github.com/empoweredhouse/eh-os/blob/main/docs/adr/0055-operator-realises-environments-and-deployments.md)
(how the operator runs a workload) and
[D-56](https://github.com/empoweredhouse/eh-os/blob/main/docs/adr/0056-what-a-workload-is-given-at-start.md)
(what a workload is given at start). Its Stage 5 plan, step 3, asks the template to follow them
before the first client application, `EmpoweredHouse/ehos-ledger`, is created with `ehosctl init`.
`ehos_app` 0.2.0 does; `packages/ehos_app/README.md` lists what it writes. 0.2.1 fixes the two
things `ehos-ledger`'s first run of the generated CI found: a lock check that cannot pass with the
test environment's dependencies alone, and an image for amd64 only, which does not start on Apple
silicon. 0.3.0 makes the generated application sign people in through EHOS (eh-os D-64, its Stage
9), with `ehos.yaml/v2`.

Verified by hand on macOS arm64, from a project generated with
`mix igniter.new ledger --with phx.new --install ehos_app@path:… --example --yes` under the pinned
Erlang 28.5.0.7 and Elixir 1.20.4:

- `mix ecto.setup` and `mix precommit` passed: 10 tests, and `eh_os_contract.check` with 0 errors,
  0 warnings and 0 notices. `mix format` changed nothing in the generated code;
- `actionlint` passed on the generated workflow;
- `docker build --secret id=github_token,env=GITHUB_TOKEN .` built the image, with the token in
  no layer (`docker history --no-trunc`);
- against PostgreSQL 17 over TLS, in a schema `ledger_production` owned by an owner role with no
  `CREATE` on `public`, with a runtime role holding only `SELECT`, `INSERT`, `UPDATE` and
  `DELETE`, and nothing set but D-56's variables, `bin/migrate` ran the three migrations as the
  owner, and the image ran as the runtime role, as user 65534, with a
  read-only root and a `tmpfs` at `/tmp`. `/health/live` and `/health/ready` answered 200 on port
  4001, the second with keys fetched from a local EHOS (`https://ehos.localhost`) through
  `EHOS_CA_FILE`. Port 4000 served no health path, and `/api` refused a call without a
  credential with 401;
- `mix eh_os_contract.manifest` wrote an `ehos.manifest/v1` with the application `ledger`, its two
  capabilities and its two roles.

Found on the way, and fixed:

- **Oban names `public` in every statement** unless its migration is given a prefix, and its
  installer takes none. The owner of the schema EHOS gives an application may not create in
  `public`, so the first migration failed with `permission denied for schema public`. The
  installer now passes Oban's configured prefix and `create_schema: false`. Ecto's
  `migration_default_prefix` does not help: `Ecto.Migration.prefix/0` does not read it.
- **`phx.gen.release` writes the Dockerfile after the installer has run**, as a task, so the
  installer cannot change it. A second task, `mix ehos_app.dockerfile`, runs after it.
- **The example contract warned**, as in the spike: its events repeated their unit's name, and the
  recorded entry had no reader. They are now `:recorded` and `:flagged`, and a recorded entry is
  published as `<name>.entry.recorded.v1`.
- **`eh_os_contract`'s migrations failed outside `public`.** Both the engine's and the verifier's
  recorded their version with `COMMENT ON TABLE "public".…` and read it back from `public`, so in
  the schema EHOS gives an application they failed with `relation "public.eh_os_contract_events"
  does not exist`. Fixed in eh-os-contract
  ([eh-os-contract#51](https://github.com/EmpoweredHouse/eh-os-contract/issues/51), merged as
  [`50eb771`](https://github.com/EmpoweredHouse/eh-os-contract/commit/50eb7711c3235325834535d7d24239855c0e63d8)),
  which the template now pins. The run above was repeated on it, in `ledger_production`: all 14
  tables and both versions landed there and none in `public`, and the runtime role wrote the
  deployment's row.

Still open:

- **The schema's copy comes from eh-os's `main`**
  ([`99e036b`](https://github.com/empoweredhouse/eh-os/blob/99e036b0b1113be5f5ee3770d852d80260796748/priv/schemas/ehos.yaml/v2.json)),
  `ehos.yaml/v2`, whose `sign_in` signs people in (eh-os
  [D-69](https://github.com/empoweredhouse/eh-os/blob/main/docs/adr/0069-an-application-signs-people-in-only-when-its-ehos-yaml-declares-sign-in.md)).
  EHOS 0.3.0 froze v1 and freezes v2 in its next release; replace the copy with the release's then.
  No test compares the two, since CI here cannot read the private eh-os. At `eh-os-contract`'s
  `da9f56f`, which the template pins, `mix eh_os_contract.manifest` reads `ehos.yaml` and writes
  `ehos.manifest/v2` (D-52), `sign_in` included.
- **The names of an application disagree across repositories.** EHOS makes an application's name
  a DNS label, with dashes and no underscore; an OTP application's name has underscores and no
  dash. The template maps one onto the other (`my_shop` is `my-shop` in EHOS), and `ehosctl init`
  writes a dash it is given as an underscore. But eh_os_contract allows no dash in a publication's
  name, which must start with the domain's
  ([eh-os-contract#50](https://github.com/EmpoweredHouse/eh-os-contract/issues/50)), so for a name with an underscore the example
  publishes nothing, the installer says why, and `eh_os_contract.check` warns once.
- **Every test run logs that EHOS's keys could not be fetched**, from the issuer `https://ehos.test`
  the tests are configured with. Credentials are signed with a pinned test key, so nothing fails,
  but the log reads like an error.
- **A generated project's CI** needs `EHOS_CI_APP_ID` and `EHOS_CI_APP_PRIVATE_KEY` for an App
  that can read `eh-os-contract`. They are the user's to set.

## Linux and CI

Linux was tried after the spike, and CI was added to prove both platforms on every push.

- **One Mac builds all four binaries**, and the Linux ones run: `ehosctl_linux_arm64`, built on
  macOS arm64, ran in an Ubuntu 24.04 arm64 container.
- **On a clean Ubuntu 24.04 arm64**, with only git, curl and mise, `init shop` finished with exit
  code 0 in 85 s, and the project passed `mix ecto.setup` and `mix precommit` against PostgreSQL
  17. The private `eh-os-contract` was served from a local mirror through git's `insteadOf`,
  because the container has no GitHub credentials (Open, point 1).
- **Found there, and fixed: `mise exec` cannot install a missing Elixir.** `mise exec erlang@X
  elixir@Y --` runs the new Elixir's check without the Erlang named next to it on the path, and
  fails with `exec: erl: not found`, even on a second try with that Erlang installed (mise
  2026.9.12). macOS never showed it, because the toolchain was already installed there. `init` now
  runs `mise install --quiet erlang@X elixir@Y` first. `--quiet` drops mise's advice to
  `mise use` the new tools, which would pin them in the developer's global config.
- **Found there, and fixed: the missing-mise message said `brew install mise`**, which is no
  help on most Linux machines. It now links to mise's installation page.
- **The target names changed** to `macos_arm64`, `macos_x64`, `linux_arm64` and `linux_x64`.
  mise's `github:` backend picks a release asset by the OS and architecture words in its name, and
  reads a bare `x86` as 32-bit and a bare `arm` as armv7.
- **CI** ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) runs the gate for both
  packages, cross-builds the four binaries on Linux, and runs the same end-to-end path on
  macOS arm64 (`macos-15`), macOS x64 (`macos-15-intel`), Linux x64 (`ubuntu-24.04`) and Linux
  arm64 (`ubuntu-24.04-arm`). On a tag, it publishes the release and installs it back through
  `mise use -g github:EmpoweredHouse/ehos-tools` on all four. The end-to-end jobs read
  the private `eh-os-contract` with a token from a GitHub App installed on that repository alone
  (see `CONTRIBUTING.md`). `docker build` of a generated project had no such token, and failed
  (Open, point 1), until the template gave it a build secret on 2026-09-30.
- **Windows is not supported.** The reasons, starting with `:nouse_stdio` doing nothing on
  Windows, are in [`packages/ehosctl/README.md`](../packages/ehosctl/README.md#windows).

## Not done yet

- **The first release.** CI publishes one on a `v*` tag; none has been made.
- **The Homebrew tap, blocked by private repositories.** The formula in
  `packaging/homebrew/ehosctl.rb` installs, passes `brew test` and `brew audit --strict` from a
  local tap against a locally built binary (2026-09-24, macOS arm64). It is not published, because
  Homebrew downloads a formula's `url` without credentials, and the binaries live in the releases
  of the private `ehos-tools`. `HOMEBREW_GITHUB_API_TOKEN` only raises API limits, and Homebrew
  no longer ships a download strategy for private release assets. The ways out:
  - publish the binaries from a public repository, such as `EmpoweredHouse/ehosctl-releases`,
    while the code stays private;
  - keep a custom download strategy in the tap, which fetches through the GitHub API with each
    user's token;
  - wait until `ehos-tools` is public.

  After that: create `EmpoweredHouse/homebrew-tap`, let the `release` job render the formula from
  `SHA256SUMS` and commit it there (the CI GitHub App needs write access to the tap for that), and
  give the tap its own CI with `brew test` and `brew audit`.
- **Linux beyond Ubuntu.** mise has precompiled builds of the pinned Erlang only for Ubuntu
  22.04 and 24.04 (26.04 when asked). Elsewhere it compiles from source, which has not been tried.
- **Windows.** See above.
- **macOS x64 after August 2027**, when GitHub retires `macos-15-intel`, its last Intel image.
- **An upstream warning in eh-os-contract.** Elixir 1.20 warns about a clause that is never used in
  `EhOsContract.Trace.suspended?/3` (`lib/eh_os_contract/trace.ex:370`).

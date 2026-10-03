# Changelog

All notable changes to `ehos_app` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehos_app` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered.

The version is raised whenever what the installer writes changes: `mix igniter.upgrade` compares it
to decide which upgrade steps an existing project needs.

## [Unreleased]

### Added

- People sign in to a generated application's pages through EHOS (eh-os D-64), as
  `eh_os_contract_auth`'s README prescribes:
  - `ehos.yaml` declares `sign_in: {}`, so EHOS gives the workload a client;
  - `config/runtime.exs` configures the client from `EHOS_CLIENT_ID`, `EHOS_CLIENT_KEY_FILE`,
    `PHX_HOST`, `SECRET_KEY_BASE` and `EHOS_SIGN_IN_APPLICATIONS`, and passes `EHOS_CA_FILE` to it;
  - `<App>.SignIn` starts `EhOsContract.Auth.SignIn` after `EhOsContract.Auth`, where sign-in is
    configured: in a release, not in development or tests, which have no EHOS to sign in with;
  - the cookie session is encrypted, since it holds the sign-in's state, nonce and PKCE verifier
    between the redirect and the callback;
  - the router forwards `/auth/ehos` to `EhOsContract.Auth.SignIn.Router` behind the browser
    pipeline, and has a `:signed_in` pipeline for the pages that need a person;
  - the root shows a visitor a sign-in link and a signed-in browser a sign-out button
    (`<App>Web.SignInComponents`), tested in `test/<app>_web/sign_in_test.exs`;
  - `ARCHITECTURE.md` and the web layer's managed section say how a page gets the person.

  Run again on a project from an earlier version, the installer moves it to the new commit of
  `eh-os-contract` (asking, unless `--yes`), adds the runtime block on its own, and adds a migration
  to the verifier's version 3, which holds the people signed in, when it is on a commit an earlier
  version pinned; a project on another commit keeps it, and is told. Its `ehos.yaml` is left as it
  is, and the installer says what signing people in needs of it. The cookie session, now
  encrypted, cannot read a cookie that was only signed, so the first deploy after the upgrade
  starts every browser's session afresh.

- The agent harness of a generated application, on the model of shugyo's:
  - a lean `AGENTS.md`, under 200 lines, that opens with EHOS's section and points to the rest. The
    `AGENTS.md` Phoenix writes moves to `docs/phoenix.md`, as Phoenix wrote it;
  - `VISION.md`, opened by a section on what EHOS is, where the application sits in it, and the
    principles it inherits; `ARCHITECTURE.md` and `TESTING.md`, filled with what the installer
    knows; a `README.md` in place of Phoenix's;
  - an `AGENTS.md` and a `CLAUDE.md` in `lib/<app>/contracts/`, with the rules for writing a
    contract, and in `lib/<app>_web/`;
  - the skills `plan`, `ship`, `review` and `elixir-anti-patterns-review` in `.agents/skills/`,
    linked from `.claude/skills/` by the new task `mix ehos_app.link_skills`;
  - `.coderabbit.yaml`, `.github/pull_request_template.md`, and `/.plans/` in `.gitignore`;
  - `test/harness_test.exs`, which fails on a dangling link, an ADR citation, a guide over its line
    budget or a skill without its link.

  `AGENTS.md`, `README.md`, `VISION.md` and both nested `AGENTS.md` hold a section of the
  installer's between markers, which an upgrade rewrites. A project from 0.2 gets its sections and
  the new files; the installer says how to move Phoenix's rules out of its `AGENTS.md`.

### Changed

- `ehos.yaml` is `ehos.yaml/v2`, with the schema's copy at `.ehos/ehos.yaml.v2.json`, taken from
  eh-os at `99e036b`.
- `eh_os_contract` and `eh_os_contract_auth` are pinned to `eh-os-contract`'s `da9f56f`, the first
  commit with the browser-session Plug.

### Fixed

- A second run of the installer no longer overwrites a file it created once and the developer has
  changed since, such as `ehos.yaml`, `.tool-versions` or `CLAUDE.md`. Igniter's
  `create_new_file/4` with `on_exists: :skip` reads a file it has not read yet and puts the new
  content over it, which on a real project is every such file; the installer now leaves a file
  that exists before creating anything.

## [0.2.1] - 2026-09-30

Both fixes are to the CI workflow the installer writes once, so they reach new projects only. No
upgrade step brings a project from 0.2.0 along: the one project generated from 0.2.0,
`EmpoweredHouse/ehos-ledger`, has both changes by hand.

### Fixed

- The generated CI workflow no longer runs `mix deps.unlock --check-unused`. After
  `mix deps.get --only test` it reported `file_system`, a child of the dev-only
  `phoenix_live_reload`, as unused, so the first run on `main` of a project generated from
  `ehos_app-v0.2.0` failed. `mix precommit` still removes unused entries locally.
- The generated CI workflow builds the image for `linux/amd64` and `linux/arm64`, each on a
  runner of its own architecture, and deploys one index over both by its digest. An image for
  amd64 alone did not start on Apple silicon: Erlang/OTP 28 fails under Docker Desktop's x86-64
  emulation, so it could not run on a developer's Mac or on a local cluster there.

## [0.2.0] - 2026-09-30

The first release. Version 0.1.0 guessed what EHOS requires of an application and was never
released; 0.2.0 follows what EHOS decided on 29 September 2026 (eh-os D-51, D-55, D-56), so no
project needs an upgrade step from it.

### Added

- `mix ehos_app.install`, which turns a Phoenix project into an EHOS application:
  - it adds `eh_os_contract` and `eh_os_contract_auth` from git, both pinned to one commit of
    eh-os-contract's `main` with contracts v2, whose migrations run in the schema EHOS gives the
    application;
  - it installs Oban through Oban's own installer;
  - it wires the engine in: config with `EhOsContract.Auth` as the authorizer, the contract
    compiler after Elixir's, both packages' migrations after Oban's, and `EhOsContract`,
    `EhOsContract.Auth` and the health endpoints after the repo and Oban;
  - it adds `eh_os_contract.check` to `mix precommit`;
  - it serves `/health/live` and `/health/ready` on port 4001, ready once the application holds
    EHOS's keys;
  - it writes `ehos.yaml` as `ehos.yaml/v1`, with the schema EHOS publishes copied into
    `.ehos/ehos.yaml.v1.json`;
  - the endpoint listens on port 4000, the port `ehos.yaml` declares, and `runtime.exs` reads no
    `PORT`;
  - production is configured from the variables EHOS gives an application: `EHOS_ISSUER`,
    `EHOS_AUDIENCE`, `EHOS_CA_FILE`, `DATABASE_SCHEMA` as the connection's `search_path` and
    Oban's prefix, and `DATABASE_CA_CERT_FILE` for a verified TLS connection. Oban's migration
    takes the same prefix;
  - it writes `rel/env.sh.eex`, so the release writes under `/tmp` alone and starts no
    distribution;
  - it generates a release and a Dockerfile, whose `deps.get` reads a GitHub token from the
    BuildKit secret `github_token`;
  - it writes a GitHub Actions workflow: formatting, compilation, tests and
    `eh_os_contract.check`, then the image pushed to `ghcr.io` by digest beside the manifest of the
    same commit;
  - it writes `.tool-versions`;
  - it puts the EHOS section at the top of `AGENTS.md` and writes `CLAUDE.md`;
  - it keeps `ehos_app` itself to `only: :dev, runtime: false`.
- `mix ehos_app.dockerfile`, which gives the Dockerfile `phx.gen.release --docker` writes its
  build secret. The installer runs it after `phx.gen.release`.
- `--example` also generates a v2 domain and contract, their implementation, a route at `/api`
  behind `EhOsContract.Auth.Plug`, and a test: a clerk records an entry, an auditor flags one.
- The installer finds the project's Ecto repo instead of assuming `<App>.Repo`, and stops with an
  issue when there is none.
- The release and Dockerfile are generated only when the project has no Dockerfile yet.
- The generated `AGENTS.md` section and example point to the contract reference where the sparse
  dependency puts it: `deps/eh_os_contract/packages/eh_os_contract/docs/contract.md`.
- Running the installer a second time changes nothing.
- The `AGENTS.md` section is replaced between its markers when the installer writes a newer one.
  If its end marker has been removed, the section is left alone.
- When the full Erlang version cannot be read, `.tool-versions` is not written and the installer
  warns, instead of pinning the major version alone.
- A migration of Oban's that is not the one its installer writes, and a Dockerfile without
  Phoenix's `deps.get` step, are left alone, with a warning saying what to change.

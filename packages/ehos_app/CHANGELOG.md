# Changelog

All notable changes to `ehos_app` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehos_app` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered.

The version is raised whenever what the installer writes changes: `mix igniter.upgrade` compares it
to decide which upgrade steps an existing project needs.

## [Unreleased]

The first release will be 0.2.0. Version 0.1.0 guessed what EHOS requires of an application and was
never released; 0.2.0 follows what EHOS decided on 29 September 2026 (eh-os D-51, D-55, D-56), so
no project needs an upgrade step from it.

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

### Fixed

- The generated CI workflow no longer runs `mix deps.unlock --check-unused`. After
  `mix deps.get --only test` it reported `file_system`, a child of the dev-only
  `phoenix_live_reload`, as unused, so the first run on `main` of a project generated from
  `ehos_app-v0.2.0` failed. `mix precommit` still removes unused entries locally.

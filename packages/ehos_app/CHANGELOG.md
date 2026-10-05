# Changelog

All notable changes to `ehos_app` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehos_app` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered.

The version is raised whenever what the installer writes changes. An existing project takes it by
moving its `ehos_app` dependency to the commit the version's tag names and running
`mix ehos_app.install` again.

## [Unreleased]

### Changed

- `eh_os_contract` and `eh_os_contract_auth` follow eh-os-contract's `main` (`branch: "main"`)
  instead of one commit, while eh-os-contract tags no release
  ([T-04](../../docs/adr/0004-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md),
  [#39](https://github.com/EmpoweredHouse/ehos-tools/issues/39)). 0.4.0's `da9f56f` was about
  200 commits behind within days. `mix.lock` holds the commit a project builds with, and
  `mix deps.update eh_os_contract eh_os_contract_auth` moves both to `main`'s latest, as the
  generated `ARCHITECTURE.md` now says. A project on a commit an earlier version pinned,
  `da9f56f` included, is moved to `main`, asked first unless `--yes`; one on a commit of its own
  keeps it.

### Fixed

- The example contract of an application whose EHOS name has a dash (`my_shop`, `my-shop` in
  EHOS) publishes `my-shop.entry.recorded.v1`, and the installer no longer warns that it
  publishes nothing: eh-os-contract allows the dash since
  [eh-os-contract#50](https://github.com/EmpoweredHouse/eh-os-contract/issues/50), whose fix 0.4.0's
  pin already held. The contract is written once, so an existing project adds the `publish` by
  hand, as a new project's `lib/<app>/contracts/entries.ex` has it. The EHOS section of
  `lib/<app>/contracts/AGENTS.md` no longer names it as a limitation, and neither does a new
  project's `ARCHITECTURE.md`.

## [0.4.0] - 2026-10-03

A generated application preloads its fonts, keeps its session cookie Secure in production
whatever the proxy says, and never loses a README its developer wrote. A project from 0.3.0 is
brought along by moving its `ehos_app` dependency to the commit `ehos_app-v0.4.0` names, with
`"== 0.4.0"` as its requirement, and running `mix ehos_app.install` again
([T-02](../../docs/adr/0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)).
That rewrites the Secure cookie setting and gives an `AGENTS.md` that is the EHOS section alone
the application's part. What the installer writes once, it does not touch again, so three
changes are made by hand: the font preloads in the root layout, the `local/1` helper in
`test/harness_test.exs`, and `.coderabbit.yaml`'s base branches.

### Added

- A generated application preloads Albert Sans at 400 and 500, `latin`, in its root layout,
  before the stylesheet, so a first visit does not lay text out in the fallback font and then
  reflow it ([#10](https://github.com/EmpoweredHouse/ehos-tools/issues/10)). Written when the
  design system is first installed only; a project from 0.3.0 adds the two links by hand, as
  `ehos_design`'s README shows.

### Fixed

- Only the README `phx.new` writes, its title and then Phoenix 1.8's text word for word, is
  replaced by the seed. A README of the developer's that still quoted "To start your Phoenix
  server" anywhere, Phoenix's own with a few lines added included, was replaced whole, and what
  they wrote lost; it gets the section on top now
  ([#23](https://github.com/EmpoweredHouse/ehos-tools/issues/23)).
- The warning about an `ehos.yaml` without `sign_in` says the application starts and signs nobody
  in; it said the application does not start, which 0.3.0's runtime configuration no longer does.
- The generated `test/harness_test.exs` no longer takes `docs/<file>.md` in the text of a link to
  another repository, with a title or without, for a file of the project's own. `ehos-ledger`'s
  README, which names EHOS's `docs/ehos-yaml.md` that way, failed it. The file is written once,
  so an existing project takes the change by hand: the `local/1` helper and its use in that test.
- The session cookie is marked Secure in production itself (`secure_session: true` in
  `config/prod.exs`, read at compile time like `force_ssl`), rather than only when `force_ssl`
  has rewritten the scheme from a proxy's `X-Forwarded-Proto`. A `secure: false` the project
  wrote is replaced too; any other `secure:` of its own stays.
- The generated harness test fails a `.claude/skills` link that resolves to another skill than
  the one it is named for.
- The generated `.coderabbit.yaml` reviews pull requests into every base branch, so a stacked one
  is reviewed too; it named `main` alone, which is reviewed anyway.
- A root `AGENTS.md` that holds the EHOS section alone, as ehos_app 0.2 wrote it once Phoenix's
  rules are moved out, gets the application's part below it (the repository's structure, where to
  read, the nested `AGENTS.md` files), as a new project does; the section's "listed below this
  section" pointed at nothing ([#18](https://github.com/EmpoweredHouse/ehos-tools/issues/18)).
- Nothing names `mix igniter.upgrade ehos_app` as the way to a later version any more: it runs no
  step of the template's. A project moves the dependency and runs `mix ehos_app.install` again
  ([T-02](../../docs/adr/0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md),
  [#12](https://github.com/EmpoweredHouse/ehos-tools/issues/12)).

## [0.3.0] - 2026-10-03

A generated application signs people in to its pages through EHOS, with `ehos.yaml/v2`, and gets
the agent harness and the EmpoweredHouse design system. A project from 0.2 is brought along by
running the installer again (`mix ehos_app.install`), which adds what 0.3.0 writes and leaves what
the developer changed; `mix igniter.upgrade ehos_app` does not yet
([#12](https://github.com/EmpoweredHouse/ehos-tools/issues/12)).

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

  A new project's verifier migration names version 3, which holds the people signed in. Run again
  on a project from an earlier version, the installer moves a package on a commit an earlier version
  pinned to the new one (asking, unless `--yes`), and keeps one on any other commit, saying so. It
  adds the runtime block on its own, and a migration to version 3 when the project's verifier
  migration went to an earlier one. Its `ehos.yaml` is left as it is, and the installer says what
  signing people in needs of it. The cookie session, now
  encrypted, cannot read a cookie that was only signed, so the first deploy after the upgrade
  starts every browser's session afresh.

- The EmpoweredHouse design system as the application's default look
  ([eh-os D-72](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0072-the-design-system-is-a-library-ehos-design-kept-in-ehos-tools.md)):
  - `ehos_design` 0.1.0, from ehos-tools, pinned to the commit tagged `ehos_design-v0.1.0`;
  - its layer imported right after Tailwind in `assets/css/app.css`, in place of the two daisyUI
    themes Phoenix writes, and a section at the end for the application's own styles;
  - its fonts served at `/ehos_design/fonts/`, from the endpoint;
  - with `--example`, a page at `/design-system` that shows it, and its test;
  - in the agent harness, how to build on it and how to replace it.

  The comment above the import says how to decline it, and a later run never adds a declined
  design system back. A daisyUI theme the developer has tuned is kept, with a notice, and a
  version of `ehos_design` they have moved to is left as it is.

  `ehos-tools` is private, like `eh-os-contract`: the Dockerfile's build secret and the CI
  workflow's GitHub App token now read both. A workflow from 0.2 is left as it is, and the
  installer says what to add to it; a Dockerfile step from 0.2 is given the second repository.

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

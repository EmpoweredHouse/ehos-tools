# Changelog

All notable changes to `ehos_app` are recorded here by hand, each in the pull request that makes
it, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehos_app` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that breaks something starts with
`**Breaking:**`. Between releases the version is the next minor's `-dev`. A release's section is
the notes of its GitHub release, tagged `ehos_app-vX.Y.Z`
([releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)).

A change to what the installer writes reaches a project with the next release. An existing project
takes it by moving its `ehos_app` dependency to the commit the release's tag names and running
`mix ehos_app.install` again.

## [Unreleased]

### Changed

- **Breaking:** the workflow's check job runs `ehosctl verify`, the command a developer runs,
  instead of listing the gates itself. mise installs `ehosctl` 0.3.0 from its release, before any
  dependency's code runs, with a token of the CI App that reads ehos-tools alone, and the binary
  runs only if its SHA-256 is the one 0.3.0 published. The token needs the App's *Attestations:
  read* besides *Contents: read*, since mise asks for a release's attestations: an organisation
  owner adds it to the App before a project takes this workflow, or its check job fails at the
  token step. The dependencies are still fetched in a step of their own, and the manifest is
  uploaded from `_build/ehos.manifest.json`, where `verify` writes it (eh-os#385, #117). A
  workflow 0.6.1 or 0.7.0 wrote is replaced by this one when the installer runs again; a later
  `ehos_app` moves the pinned `ehosctl`.

## [0.7.0] - 2026-10-11

### Added

- Each release is published on GitHub, tagged `ehos_app-vX.Y.Z`, with its section of this
  changelog as the notes and `release.json` beside it: its version, its commit, the `ehos.yaml`
  it writes, `ehos.yaml/v2`, and the versions of `eh_os_contract`, `eh_os_contract_auth` and
  `ehos_design` it requires (eh-os D-91,
  [releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)). It is never
  the release GitHub marks latest, which is `ehosctl`'s.
- `EhosApp.ehos_yaml_version/0`, the version of `ehos.yaml` the installer writes,
  `EhosApp.requires/0`, the requirements it writes for the components it adds, and
  `EhosApp.release/1`, what a release says about itself.

### Changed

- **Breaking:** `eh_os_contract` and `eh_os_contract_auth` are pinned to eh-os-contract's release
  0.3.0, by the commit its tag `v0.3.0` names (`3304f355`), with the requirements `~> 0.3.0` and
  `~> 0.1.0`, instead of following its `main` (ehos-tools' T-11, which supersedes T-05). The
  installer moves a project on `main`, or on a commit an earlier version pinned, to the release,
  asking first unless `--yes`; the next `mix deps.get` takes that commit into `mix.lock`. A later
  eh-os-contract reaches a project with a release of `ehos_app`.

## [0.6.1] - 2026-10-09

### Changed

- The generated CI checks first that the repository has `EHOS_CI_APP_ID` and
  `EHOS_CI_APP_PRIVATE_KEY`, and when not, says so and where they come from. Without them the token
  step failed saying only that `client-id` must be set. A workflow 0.5.0 to 0.6.0 wrote, untouched
  since, is replaced on upgrade, as the earlier ones are.

## [0.6.0] - 2026-10-09

### Changed

- A generated application takes `ehos_design` 0.2.0, with the design system's listbox
  ([eh-os D-86](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0086-the-design-system-s-source-holds-component-stylesheets-and-ehos-design-ships-the-components-built-on-them.md)):
  `EhosDesign.Components.picker/1` and `combobox/1`.

### Added

- When it first installs the design system, the installer gives the LiveSocket in
  `assets/js/app.js` the design system's hooks, from `phoenix-colocated/ehos_design`, beside the
  application's own, and names the package's templates in `assets/css/app.css` as a source for
  Tailwind, after Phoenix's own sources. A script that is not Phoenix's is left alone, with what to
  add. A project that had the design system before keeps the version it pinned, which may have no
  hooks, and gets neither: when it moves to `ehos_design` 0.2.0 it adds both lines by hand, as
  the package's README says ("The components").

## [0.5.1] - 2026-10-06

A generated application compiles again. eh-os-contract's `main`, which 0.5.0 follows, now requires
every contract to name its id
([eh-os-contract#174](https://github.com/EmpoweredHouse/eh-os-contract/pull/174)), and 0.5.0's
example contract named none, so `ehosctl init` stopped at the project's first compile with
`D11: the contract names no id:`. A project from 0.5.0 keeps compiling until it takes that commit
of eh-os-contract, with `mix deps.update eh_os_contract eh_os_contract_auth`. Then every contract
it has, the example included, needs an id, added by hand: the installer writes a contract once.
An event's type becomes `"<id>.<event>"` in place of `"<process>.<event>"`, so the log's earlier
rows are no longer read as those events: as eh-os-contract's CHANGELOG says, a host that upgrades
resets the engine's schema, which for an application not yet deployed means
`mix ecto.reset`.

### Fixed

- The example contract names its id, the application's EHOS name and `entries`
  (`id: "my-shop.entries"`), which types every event it records (`"my-shop.entries.recorded"`).
  A project's own contracts need one too, and the rule is in the EHOS section of
  `lib/<app>/contracts/AGENTS.md`, which an upgrade rewrites.

## [0.5.0] - 2026-10-06

A generated application takes the contract engine from eh-os-contract's `main`, keeps its way in
and out when its home page is replaced, and an upgraded one gets the current CI workflow. A
project from 0.4.0 is brought along by moving its `ehos_app` dependency to the commit
`ehos_app-v0.5.0` names, with `"== 0.5.0"` as its requirement, and running
`mix ehos_app.install` again
([T-02](../../docs/adr/0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)).
That moves `eh_os_contract` and `eh_os_contract_auth` to `main`, so the next `mix deps.get` takes
`main`'s latest commit into `mix.lock`: read its diff. It moves the sign-in link from the home page
to the root layout and gives 0.4's component the session guard, and it replaces a CI workflow an
earlier version wrote, untouched, which then needs the GitHub App installed on ehos-tools too.
What the installer writes once it does not touch again, so one change is made by hand where it
applies: the `publish` in the example contract of an application whose EHOS name has a dash.

### Changed

- `eh_os_contract` and `eh_os_contract_auth` follow eh-os-contract's `main` (`branch: "main"`)
  instead of one commit, while eh-os-contract tags no release
  ([T-05](../../docs/adr/0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md),
  [#39](https://github.com/EmpoweredHouse/ehos-tools/issues/39)). 0.4.0's `da9f56f` was about
  200 commits behind within days. `mix.lock` holds the commit a project builds with, and
  `mix deps.update eh_os_contract eh_os_contract_auth` moves both to `main`'s latest, as the
  generated `ARCHITECTURE.md` now says. A project on a commit an earlier version pinned,
  `da9f56f` included, is moved to `main`, asked first unless `--yes`, and told that the next
  `mix deps.get` takes `main`'s latest commit into `mix.lock`; one on a source, commit or branch
  of its own keeps it. The dependency is read as code, so a fork named `eh-os-contract-fork` is
  not taken for eh-os-contract and replaced, and a `git:` URL to it, over HTTPS or SSH, is.

### Fixed

- A project upgraded from an earlier version gets this version's `.github/workflows/ci.yml` when
  its own is still, byte for byte, what that version wrote
  ([#38](https://github.com/EmpoweredHouse/ehos-tools/issues/38),
  [T-02](../../docs/adr/0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)).
  It kept 0.2's, which checked the lock against half its dependencies
  (`mix deps.unlock --check-unused`, failing on `file_system`), minted the token for
  eh-os-contract alone and built the image for amd64 alone. A workflow the developer changed is
  left as it is, with the diff to this version's in the notice, where 0.2's was told only about
  the token. Read the diff before committing it:
  - A replaced 0.2 workflow mints its GitHub App token for ehos-tools as well as eh-os-contract,
    still to read contents alone, so the App must be installed on ehos-tools too, or the job
    fails at the token. Code a same-repository pull request controls (`mix.exs`, the
    Dockerfile) can read that token, as it could read 0.2's for eh-os-contract.
  - From 0.2.0, it builds the image on two runners, one of them arm64, on every pull request,
    and on a push to `main` publishes from a third job that logs in to `ghcr.io` with the
    workflow's token: three jobs hold the `packages: write` 0.2.0's one build held. 0.2.1's had
    those already.
- The generated workflow fetches with `mix deps.get --only test --check-locked`, so a `mix.lock`
  out of step with `mix.exs` for a test dependency fails the job instead of testing the latest
  commit of eh-os-contract's `main`. A workflow from an earlier version that is replaced gets it;
  one the developer changed is shown it in the diff.
- The sign-in link and sign-out button are at the top of the root layout's `<body>`, which every
  page renders with the request's conn, a LiveView's included, as `phx.gen.auth` places its
  menu ([#37](https://github.com/EmpoweredHouse/ehos-tools/issues/37)). 0.4 put them on
  Phoenix's home page, so the first page an application built in its place, a `live "/"`, took
  them away, and the generated `sign_in_test.exs`, which read `GET /`, failed. A project from 0.4
  has the line moved, when its home page holds it where 0.4 wrote it, and its component brought
  to a new one's: the session guard below, and a bar in the page's flow for the corner it was
  fixed in, which would cover the header of `Layouts.app`. A component whose `get_session/2` call
  was changed is given the bar alone, with a notice saying what guard to add. A link the
  developer has moved stays where it is. The generated test renders the
  root layout instead of a page; the test is written once, so a project from 0.4 keeps its own,
  which passes on any `/` that renders the root layout. The web layer's `AGENTS.md` says where
  the way in and out lives. A new project's component renders nothing on a page whose request
  never fetched the session, where `get_session/2` would raise: an error page, if the project
  has set `render_errors` to render with the root layout (Phoenix's default renders none).
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

# ehos_app

The template for applications that run on [EHOS](https://github.com/EmpoweredHouse/eh-os),
EmpoweredHouse's platform for a company's own applications. It is an
[Igniter](https://hexdocs.pm/igniter/readme.html) installer, `mix ehos_app.install`, that turns a
Phoenix project into an application EHOS can deploy and govern: the contract engine wired in,
people signed in through EHOS, `ehos.yaml` saying what the application needs, the health
endpoints EHOS probes, a release image, CI, and the docs and skills a coding agent works by.

The application keeps `ehos_app` as a dependency, in `:dev` only, for two things: running the
installer again to take a later version, and `mix ehos_app.review`, the gate that checks each
change was reviewed before its pull request is opened (`EhosApp.Review`).

What the template writes about EHOS follows EHOS's
[specification](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ARCHITECTURE.md); what EHOS
has not decided yet is listed below, under "What is decided, and what is not yet".

## On a new project

`ehosctl init shop` is how an application is normally made
([`ehosctl`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/README.md)).
It runs, under the Erlang and Elixir its release pins (`Ehosctl.Template`):

```text
mix archive.install hex phx_new <pin>; mix archive.install hex igniter_new <pin>
mix igniter.new shop --with phx.new --with-args="--database postgres"
  then, in shop/: Igniter.Util.Install.install([{:ehos_app, "== X.Y.Z", github: …,
                  sparse: "packages/ehos_app", ref: <commit>}], …)
    └─ mix ehos_app.install, with Oban's installer composed
```

The installer comes from this repository's `packages/ehos_app`, at the commit the tag
`ehos_app-vX.Y.Z` of the `ehosctl` release names. Igniter's `ehos_app@github:…` spec cannot name a
subdirectory, so `init` installs it through `Igniter.Util.Install.install/2`, which takes a
dependency as Mix writes it, `sparse:` included, and runs the installers it declares, as
`mix igniter.install` would. On the fresh project the installer writes everything in "What the
installer does", below; a second run changes nothing.

## On an existing project, and running it again

A project takes a later `ehos_app` by moving its dependency to that release and running the
installer again
([T-02](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md));
`mix igniter.upgrade ehos_app` runs no step of the template's. The same run works on a Phoenix
project the template did not make. Either way, the installer:

- adds what the project does not have yet, brings up to date what it still has as an earlier
  version wrote it, byte for byte, such as its CI workflow, and removes what this version no
  longer writes while it is still as written, such as the skills 0.3.0 to 0.8.1 copied;
- rewrites only its own sections in the docs it shares with the developer, between markers
  (below), and leaves the rest of each file alone;
- leaves what the developer wrote or changed as it is, and says in a notice or a warning what this
  version would add or what to do by hand;
- writes nothing, and says why, when the project has no Ecto repo, which the contract engine keeps
  its event log in, and when the developer declines to move `eh_os_contract` and
  `eh_os_contract_auth` from `main`, or from a commit an earlier version pinned, to the release
  this version is written for.

To take a later version, point the `ehos_app` dependency in `mix.exs` at the commit that version's
tag names, in place of the `tag:` or `ref:` it has, with that version as its requirement
(`"== X.Y.Z"`; Mix checks it when the project compiles, so a commit of another release fails
there, not at `deps.get`), then run the installer. The commit is the full 40 characters, never the
tag's name, since a tag can be moved:

```sh
git ls-remote https://github.com/EmpoweredHouse/ehos-tools \
  'refs/tags/ehos_app-vX.Y.Z' 'refs/tags/ehos_app-vX.Y.Z^{}'
# an annotated tag prints two lines: the commit is the one ending in ^{}; a lightweight tag
# prints one, which is the commit. In mix.exs, set :ehos_app's `ref:` to it and its
# requirement to "== X.Y.Z", then:
mix deps.get
git diff mix.lock          # ehos_app's line names that commit, and nothing else moved
mix ehos_app.install
mix deps.get
git diff mix.lock          # eh_os_contract's two lines, if the installer moved them to its release
```

The [changelog](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/CHANGELOG.md)
says, release by release, what reaches a project this way.

The installer pins `eh_os_contract` and `eh_os_contract_auth` to eh-os-contract's release, by the
commit its tag names ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md)),
and moves a project from eh-os-contract's `main`, which 0.5.0 to 0.6.1 followed, or from a commit
an earlier version pinned, asking first unless `--yes`. A project on any other commit or source
chose it, and keeps it, with a warning. Mix keeps a locked commit only while the lock's options
match `mix.exs`, so the next `mix deps.get` takes the release's commit: read the diff of
`mix.lock` before committing it. A later eh-os-contract reaches a project with a release of
`ehos_app` that pins it; the two packages move together, since the verifier names the engine by
git without a ref.

## What a generated application gets

`ehosctl init shop` creates `shop/`, a Phoenix 1.8 application with PostgreSQL, plus:

```text
shop/
├── ehos.yaml                         what the application needs from EHOS, as ehos.yaml/v7
├── lib/shop/domain.ex                the domain: its words, contexts and actors, named as EHOS names the application
├── lib/shop/contracts/               a contract per business process, beside the rules for writing one
├── eh_os_contract.lock               every event's fields, so a change that leaves old rows unreadable fails the gate
├── lib/shop/application.ex           Repo → Oban → EhOsContract → EhOsContract.Auth → Health → SignIn → Endpoint
├── lib/shop_web/health.ex            /health/live and /health/ready, on port 4001, which EHOS probes
├── lib/shop_web/…                    sign-in through EHOS, and the routes to the contracts behind a credential check
├── config/runtime.exs                the variables EHOS gives the application at start, and nothing else
├── assets/                           Phoenix's assets, styled by the ehos_design dependency
├── README.md, DEVELOPMENT.md         the quick start and everyday commands; the cycle, contract first, and deploying
├── VISION.md, ARCHITECTURE.md, TESTING.md   what it is for, how it is built, how it is tested
├── AGENTS.md, CLAUDE.md              the rules for coding agents, with nested ones for the contracts and the web layer
├── .claude/settings.json             enables the ehos-app plugin: /ehos-app:plan, :ship, :review, …
├── .github/workflows/ci.yml          ehosctl verify, then the image by digest beside the manifest
├── Dockerfile, rel/                  a release, built with a GitHub token as a build secret
├── test/harness_test.exs             keeps the docs honest: links, line budgets, no ADRs
├── .tool-versions                    the Erlang and Elixir everything was built with
└── LICENSE                           Apache-2.0, the application's to change
```

### Ports and the database

A generated application listens on ports 4000 (the endpoint) and 4001 (health), set in
`config/config.exs` to match `ehos.yaml`, and in development uses the database `<name>_dev` at
`postgres:postgres@localhost:5432`. Nothing checks that these are free: another project's
PostgreSQL on 5432 takes the new databases without a word, and a port in use stops
`mix phx.server`. To run two applications side by side, give the second other ports in its
`config/dev.exs` alone; the ports in `ehos.yaml` and `config/config.exs` are what EHOS runs it on.

## What the installer does

| Change | Where | Why |
| --- | --- | --- |
| Adds [`eh_os_contract`](https://github.com/empoweredhouse/eh-os-contract) and `eh_os_contract_auth`, from git, pinned to eh-os-contract's release `v0.13.1` by the commit its tag names ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md)), and moves a project on `main` or a commit an earlier version pinned to it | `mix.exs` | The contract engine, and the verifier of the credentials EHOS issues. Neither is on Hex, and both live in subdirectories, hence `sparse:`. A test holds the pinned commit to the tag. The auth package names the engine without a ref, so the engine is overridden to the same commit |
| Adds [`ehos_design`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_design/README.md), the EmpoweredHouse design system, from ehos-tools, pinned to the commit of its release, unless the project has it already, at whatever version | `mix.exs` | The application's default look ([eh-os D-72](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0072-the-design-system-is-a-library-ehos-design-kept-in-ehos-tools.md)). Not on Hex, and in a subdirectory, hence `sparse:` |
| Imports the design system's layer right after Tailwind, names its components' templates as a source after Phoenix's own, removes the two daisyUI themes Phoenix writes, and leaves a section of the application's own at the end | `assets/css/app.css` | Tailwind's utilities and daisyUI's components take the design system's tokens, so `core_components.ex` follows it unchanged. A token is overridden in the application's section. To decline it, the developer removes the import and keeps the comment above it, as that comment says, and later runs never add it back. A daisyUI theme the developer has tuned is kept, with a notice. A stylesheet without Tailwind's import is left alone, with what to add |
| Serves the design system's fonts at `/ehos_design/fonts/`, after Phoenix's static files | `lib/<app>_web/endpoint.ex` | The page loads nothing from another origin |
| Gives the LiveSocket the design system's components' hooks, from `phoenix-colocated/ehos_design`, beside the application's own, when it first installs the design system | `assets/js/app.js` | The components' keyboard ([eh-os D-86](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0086-the-design-system-s-source-holds-component-stylesheets-and-ehos-design-ships-the-components-built-on-them.md)). A later run leaves the script alone, since a project that had the design system before keeps the version it pinned; a script that is not Phoenix's gets a notice with the two lines |
| Preloads Albert Sans at 400 and 500, before the stylesheet, when it first installs the design system | `lib/<app>_web/components/layouts/root.html.heex` | A first visit does not lay text out in the fallback font and then reflow it. A later run leaves the layout alone, so links the developer removed stay removed; a layout that is not Phoenix's gets a notice with the two links |
| Runs the contract compiler after Elixir's | `mix.exs` | The rules between a contract, its domain and its siblings record no compile dependency, so the engine checks them as a Mix compiler |
| Installs Oban through Oban's own installer | `mix.exs`, `config/`, a migration, `application.ex` | The engine runs asynchronous handlers as Oban jobs. Oban's setup stays Oban's to change, except for the engine's queue, in the row below |
| Configures the engine with the application, its repo and `EhOsContract.Auth` as the authorizer | `config/config.exs` | The repo is found in the project, not assumed to be `<App>.Repo`; with several, the installer asks which one. With none, it stops and changes nothing |
| Generates the engine's and the verifier's migrations after Oban's | `priv/repo/migrations/` | The engine's jobs run on Oban's tables. The installers run in the same second, so the timestamps are chosen explicitly |
| Adds the queue `:events`, `events: 10`, to the list of queues that Oban's installer writes, unless the project gave it a limit. Another form of `queues:`, or none, or Oban configured by more than one call or as a tuple, stays as it is, with what to add | `config/config.exs` | The engine runs the jobs of effects delivered `:at_least_once` and of process managers' timers in this queue. Without it, they wait and never run. These jobs use the repo's connections too, so a busy application may need a larger `POOL_SIZE` |
| Gives Oban's migration the application's schema | Oban's migration | Oban names `public` in every statement unless given a prefix, and EHOS gives the application a schema of its own, which its owner may use but not create |
| Starts `EhOsContract`, `EhOsContract.Auth`, `<App>Web.Health` and `<App>.SignIn` after the repo and Oban, before the endpoint | `lib/<app>/application.ex` | At boot the engine records the deployed contract version, and the key store loads EHOS's keys from its table and then from EHOS |
| Signs people in to the pages through EHOS: `<App>.SignIn`, which starts `EhOsContract.Auth.SignIn` where it is configured, the encrypted cookie session, `/auth/ehos` forwarded to `EhOsContract.Auth.SignIn.Router`, a `:signed_in` pipeline, a sign-in link and sign-out button at the top of the root layout, which every page renders, and their test | `lib/<app>/sign_in.ex`, `lib/<app>_web/endpoint.ex`, the router, `lib/<app>_web/sign_in_components.ex`, `lib/<app>_web/components/layouts/root.html.heex`, `test/<app>_web/sign_in_test.exs` | An application has no login of its own: people sign in at EHOS (eh-os D-64), as `eh_os_contract_auth`'s README prescribes. The session holds the sign-in's state, nonce and PKCE verifier between the redirect and the callback, so it is encrypted. Development and tests have no EHOS, so the client starts only where `config/runtime.exs` configures it, in a release, and the sign-in answers 503 elsewhere. A project from an earlier version gets a migration to the verifier's version 3, which holds the people signed in. 0.4 put the link on Phoenix's home page, which an application's first page replaces: the line 0.4 wrote there is moved to the root layout, and one the developer has moved stays |
| Replaces Phoenix's welcome page, while it is still Phoenix 1.8.14's byte for byte, with the application's own home page, and adds `/access`, a page behind `:signed_in` that shows the signed-in person their subject and which of the contracts' capabilities their roles grant, which `<App>.Access` says, a behaviour mocked in tests ([T-20](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)); replaces Phoenix's test of the home page while it is Phoenix's; removes ` · Phoenix Framework` from the title | `lib/<app>_web/controllers/page_html/home.html.heex`, `<App>Web.AccessController` and `<App>Web.AccessHTML` and their test, `<App>.Access` and its test, where Igniter puts modules, `config/`, `test/support/mocks.ex`, the router, `test/<app>_web/controllers/page_controller_test.exs`, `root.html.heex` | An application opens on a page of its own, and the browser shows sign-in through EHOS end to end. A home page the developer changed is theirs, and gets no access page, and so does a project with an `AccessController`, an `AccessHTML`, an `<App>.Access` or a route at `/access` of its own; a page they remove is not brought back, since the home page is no longer Phoenix's after the first run. The access page's route has a scope of its own, `/access`, so routes added later for `/` and `:browser` do not land behind `:signed_in` |
| Serves `/health/live` and `/health/ready` on port 4001, in a plug of their own | `lib/<app>_web/health.ex` and its test | What EHOS probes, on a port it never exposes. Ready once the application holds EHOS's keys, since without them it refuses every credential |
| Listens on port 4000 and reads no `PORT` | `config/config.exs`, `config/runtime.exs` | EHOS gives no port: the application listens on the ports its `ehos.yaml` declares, and a test pins that the two agree |
| Reads what EHOS gives an application at start, the sign-in's client included | `config/runtime.exs` | The names are fixed by EHOS (below). A `runtime.exs` from an earlier version gets the sign-in's block on its own |
| Writes `ehos.yaml` as `ehos.yaml/v7`, the newest version EHOS defines, with `sign_in: {}`, `needs.database.seed` naming `<App>.Seed.run/0`, a comment that says how to ask for CPU and memory under `needs.compute`, and a comment that points editors at its schema in `deps/eh_os_contract_auth/`; moves an `ehos.yaml` in v3 to v6 to v7, adding to a v3 the seed beside a one-line `migrate:` where it names none, and saying how otherwise | project root | What the application needs from EHOS, never how. `sign_in` is what makes EHOS give the application a client (eh-os D-69). The schema is EHOS's, which `eh_os_contract_auth` carries unchanged and checks the file against when it writes the manifest, so the project keeps no copy of it. An `ehos.yaml` the developer has keeps its keys: one in v3 to v6 moves to v7, and the installer says what signing people in needs of it; the copy of the schema 0.2.0 to 0.8.1 wrote into `.ehos/` is removed while it is still EHOS's, and the comment that named it points at the same version in `deps/` |
| Writes `<App>.Seed`, the seed `ehos.yaml` names, and its test, once: `run/0` runs `priv/repo/seeds.exs` with the repo and an Oban that runs no queue, and `add/2` records the steps of the profile `EHOS_SEED_PROFILE` names through the contracts' commands as the system actor `:sample_data`; with `:production_environments` in `config.exs`, the profile and `EHOS_ENVIRONMENT` read in `runtime.exs`, and the call in a `priv/repo/seeds.exs` that holds comments alone | `lib/<app>/seed.ex`, `test/<app>/seed_test.exs`, `config/`, `priv/repo/seeds.exs` | An ephemeral environment (eh-os D-98) starts with data to try, recorded as business facts are, each once, and a production environment never gets it ([#476](https://github.com/EmpoweredHouse/ehos-tools/issues/476)). The test holds the profiles, the guard, and that every command a person may issue is seeded or says why not, so a project that has a contract in `lib/<app>/contracts/` already, or whose `ehos.yaml` moves from v3, gets the seed without it, to write with its first step. A seed a project has is its own, and gets none of it |
| Writes `rel/env.sh.eex` | `rel/` | The release writes under `/tmp` alone and starts no distribution, for a read-only filesystem under Pod Security `restricted` |
| Runs `mix phx.gen.release --docker`, unless there is a Dockerfile already, then `mix ehos_app.dockerfile` | `Dockerfile`, `rel/`, `lib/<app>/release.ex` | A release image, as the project's own Phoenix version generates it, whose one `deps.get` step reads a GitHub token from the build secret `github_token`, since `eh_os_contract` and `ehos_design` are private, and which fetches Tailwind's executable with curl before `mix assets.setup`, since GitHub's release redirect refuses the `tailwind` package's own download (eh-os#973). An existing Dockerfile is the developer's: only those steps are changed, and only when they are Phoenix's |
| Writes a GitHub Actions workflow | `.github/workflows/ci.yml` | The gates on every pull request, run by `ehosctl verify`, the command a developer runs, which mise installs from `ehosctl`'s release; on `main`, the image built natively for amd64 and arm64 and pushed to `ghcr.io` as one index, by its digest, and the bundle of the same commit, the manifest and every graph document, its domains', contracts' and process modules', with `bundle.json`, as `ehosctl verify` writes it, published together as the artifact `ehos-deployment` and, once the repository names its EHOS installation and EHOS trusts it on `main`, registered there as a build with the commit it came from (eh-os D-146); a pull request of the repository is registered once the installation is named, and its preview deployed from its build. It fetches with `--check-locked`, so it tests the commits `mix.lock` names. A workflow that is still, byte for byte, what an earlier version wrote is replaced by this version's; one the developer changed is left, with the diff to this version's |
| Adds `eh_os_contract.check` to `mix precommit` | `mix.exs` | Whole-program contract checks the compiler cannot make |
| Adds `eh_os_contract.schema --check` to `mix precommit` once the project has a contract or a lock, and has the engine record a new project's `eh_os_contract.lock` | project root, `mix.exs` | The lock holds every event's fields, so a change old rows would not read fails before it is merged rather than on the deployed application's first old row. It is worth something only when recorded before any event changes, which is why the generator records it rather than a later `mix precommit`, and never records over one the project has. A project that had the engine before the run is told to record it once it compiles: the engine's task compiles it, and one that fails would end the run before its notices ([#274](https://github.com/EmpoweredHouse/ehos-tools/issues/274)) |
| Writes `.tool-versions` | project root | The Erlang and Elixir the project was generated with, read by both mise and asdf |
| Moves the `AGENTS.md` Phoenix writes to `docs/phoenix.md`, and writes a lean `AGENTS.md` that opens with EHOS's section, and a `CLAUDE.md` loading it | project root, `docs/` | Coding agents read EHOS's rules first, and a guide short enough to read whole points to the rest. Phoenix's rules stay as Phoenix wrote them |
| Writes `VISION.md`, opened by a section on what EHOS is and where the application sits in it; `DEVELOPMENT.md`, the development cycle, contract first, and how the application is run, built, deployed with `ehosctl` and kept current; and `ARCHITECTURE.md` and `TESTING.md`, each opened by what every EHOS application shares | project root | Every change starts by reading the vision, so the platform's idea is read with the application's, and from the contract, which the rest of the code serves. What the template knows is rewritten by an upgrade, so it does not go stale; the rest of each file is the application's to write. An `ARCHITECTURE.md` or a `TESTING.md` an earlier version wrote gets the section on top, with a notice that the parts below it it repeats can go |
| Replaces the `README.md` Phoenix writes with one that says what the application is built on, how to start it, and the everyday commands | project root | Nothing else in the project explains the ecosystem to a person, or to a reviewer on GitHub |
| Writes an `AGENTS.md` and a `CLAUDE.md` in `lib/<app>/contracts/` and in `lib/<app>_web/` | `lib/` | The rules for writing a contract, and for the web layer, load when an agent works there |
| Enables the [`ehos-app`](https://github.com/EmpoweredHouse/ehos-tools/tree/main/plugins/ehos-app) plugin, from the marketplace `ehos-app` ehos-tools publishes for applications, at the plugin's tag (`/ehos-app:plan`, `/ehos-app:ship`, `/ehos-app:review`, `/ehos-app:elixir`, `/ehos-app:elixir-anti-patterns-review`, `/ehos-app:sample-data`, `/ehos-app:retro`), and [`eh-os-contract`](https://github.com/EmpoweredHouse/eh-os-contract/tree/main/plugins/eh-os-contract), the skills for writing contracts, from eh-os-contract's marketplace at its tag (`/eh-os-contract:module-boundary-check`, `:change-contract`, …). Settings of the project's own keep their keys and order; a marketplace on an earlier tag of its plugin moves to this one, and any other `ref` stays. The marketplace 0.9 named `ehos-tools`, at its tag, becomes `ehos-app` in its place ([T-16](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md)). In a project 0.3.0 to 0.8.1 generated, removes the skills they copied into `.agents/skills/` that are still as written, and runs `mix ehos_app.unlink_skills` for the links in `.claude/skills/`, which Igniter cannot remove; a changed copy stays, with a notice | `.claude/settings.json` | One copy of each skill, versioned, which an upgrade of the template moves to its next version ([T-15](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md)) |
| Writes `LICENSE`, the Apache License 2.0 in the name of Empowered House PSA, in a new project that has none, and says to change it when the application is someone else's | project root | ehos-tools and eh-os-contract are Apache-2.0. A project with a `LICENSE` keeps it, and one an earlier version generated is not licensed by an upgrade |
| Writes a CodeRabbit configuration and a pull request template | `.coderabbit.yaml`, `.github/` | The AI review reads the same rules, and a PR says how it was tested |
| Writes `docs/platform-issues.md` once, empty, and a section in `AGENTS.md`, "The platform is ours" | `docs/`, project root | The platform's defects an application meets reach the repository that can fix them: `/ehos-app:retro` drafts an issue for each, files it on the user's go, and lists it there, with what changes in the application once it is fixed. A project's own list is never overwritten |
| Writes `test/harness_test.exs` | `test/` | It keeps the docs honest: links resolve, the guides stay within their line budgets, and nothing cites an ADR |
| Writes `docs/elixir.md`, how the application's Elixir is written where it is not a contract's part, opened by a section of the template's | `docs/` | Behaviours, queries, changesets, pages and tests are built one way in every application, and the reviews hold it |
| In a new project, adds Boundary, its compiler first, and declares the areas: the root module exports what the web and the application call, the web depends on it alone, the application sits above both, and the repo, `<App>.Clock` and `<App>.Access` are boundaries of their own; `ConnCase` is outside every boundary. A project made before, or one not on the Phoenix welcome page this version knows, is told how to adopt it | `mix.exs`, `lib/<app>.ex`, `lib/<app>_web.ex`, `lib/<app>/application.ex`, `lib/<app>/repo.ex`, `test/support/conn_case.ex` | The web cannot reach the repo, and a context names the siblings it uses, at compile time. A project made before may already cross them, so an upgrade does not fail its compile on it |
| Writes `test/callback_docs_test.exs` once, in a project made before too, with a notice there | `test/` | Every `@callback` of the application's behaviours has a `@doc`, which a mock is never held to; one without fails with a line of `@doc` to fix it |
| In a project with no `test/support/mocks.ex` yet, adds Hammox and ExMachina, `test/support/mocks.ex` with `setup_mocks/1` and `test/support/factories.ex`, and has `DataCase` and `ConnCase` call the one and import the other, once; a case it cannot place them in is told what to add | `mix.exs`, `test/support/` | A test replaces a way out with a mock that checks the behaviour's types, never with `Application.put_env/3`, and builds its data from factories |
| In a new project, adds Credo with `.credo.exs` and `"credo"` in `mix precommit`, `test/conventions_test.exs`, and `<App>.Clock`, the first way out, mocked in tests; a project made before, or one not on the Phoenix welcome page this version knows, is told how to have Credo and the conventions test | `mix.exs`, `test/`, `lib/<app>/clock.ex`, `config/` | They ask something of code written before them, so an upgrade does not fail its first `mix precommit` on it. `ehosctl verify` lints where `mix.lock` has Credo |
| Ignores `.plans/` | `.gitignore` | The `plan` skill writes working plans there, which are history, not current truth |
| Keeps `ehos_app` itself to development | `mix.exs` | It is needed only to run the installer again, so CI and the image never fetch it |
| With `--example`, writes a page that shows the design system, its route and its test | `lib/<app>_web/live/design_system_live.ex`, the router, `test/<app>_web/live/design_system_live_test.exs` | Type, colours, buttons, a form validated by a changeset and a table, at `/design-system`, in both themes |
| With `--example`, writes a domain, a contract, its implementation, a route and a test | `lib/<app>/domain.ex`, `lib/<app>/contracts/entries.ex`, `lib/<app>/entries/entry.ex`, the router, `test/<app>_web/entries_api_test.exs` | So the tests, the check and the manifest have something to read on day one. A clerk records an entry and an auditor flags one, each the only actor allowed their command, served at `POST /api/commands/<app>.<command>` behind `EhOsContract.Auth.Plug` |
| With `--example`, writes a page that records an entry as the person signed in, its context, its route and its test, where the router has the `:browser` and `:signed_in` pipelines and names neither `/entries` nor `/entries/new`, and the project has no `<Web>.EntryLive` or `<App>.Entries` of its own | `lib/<app>/entries.ex`, `lib/<app>_web/live/entry_live.ex`, the router, `test/<app>_web/live/entry_live_test.exs` | The pattern of a page that issues a command, at `/entries/new`: the context calls `EhOsContract.call/3` with the actor `EhOsContract.Auth.Session.actor/2` gives, and the engine asks whether the person may, as it does for `/api`. The test signs in with `EhOsContract.Auth.Testing.sign_in/3` |

A second run changes nothing, and a test pins that, including that it schedules no generator. Files the
installer creates are never overwritten. Nine files hold a section of the installer's between two
markers, `<!-- ehos_app:<name> -->` and `<!-- /ehos_app:<name> -->`: `AGENTS.md`, `README.md`,
`VISION.md`, `DEVELOPMENT.md`, `ARCHITECTURE.md`, `TESTING.md`, `docs/elixir.md`, and the
`AGENTS.md` in `lib/<app>/contracts/` and in `lib/<app>_web/`. A later version of
the installer replaces what is between the markers and leaves the rest of the file alone, so what EHOS
requires reaches an application through an upgrade. A file of the project's own gets the section on
top. If the end marker has been removed, the section is left as it is. A root `AGENTS.md` that holds
the section and nothing else gets the rest of the seed below it, as a new project does.

A project generated by 0.2 has the EHOS section on top of Phoenix's rules in `AGENTS.md`. Its section
is replaced, and its Phoenix rules are left where they are, since that part of the file may be the
developer's by now: the installer says how to move them to `docs/phoenix.md`, which
`test/harness_test.exs` asks for by holding `AGENTS.md` to 200 lines.

When the full Erlang version of the running installation cannot be read, `.tool-versions` is not
written and the installer says so, rather than pinning the major version alone, which asdf refuses.

## What EHOS gives the application

The generated `config/runtime.exs` reads these in production, and nothing else about EHOS
([eh-os D-56](https://github.com/empoweredhouse/eh-os/blob/main/docs/adr/0056-what-a-workload-is-given-at-start.md)):

| Variable | Read as |
| --- | --- |
| `EHOS_ISSUER`, `EHOS_AUDIENCE` | `config :eh_os_contract_auth, issuer:, audience:`: who issues the credentials the application accepts, and for which `<application>/<environment>` |
| `EHOS_CA_FILE` | The authority that certifies EHOS's address, when it is the installation's own |
| `DATABASE_URL` | The runtime role's connection, as Phoenix reads it. In the migrations, run before the application starts, the schema owner's |
| `DATABASE_SCHEMA` | The connection's `search_path`, and Oban's prefix |
| `DATABASE_CA_CERT_FILE` | The authority the connection verifies the database's certificate and name against |
| `PHX_HOST`, `PHX_SERVER`, `SECRET_KEY_BASE` | As Phoenix reads them |
| `EHOS_SIGN_IN_APPLICATIONS` | Whether the application signs people in, and `sign_in: [applications:]`: the other applications the pages call as the person, by name, as JSON. EHOS gives it only when `ehos.yaml` declares `sign_in`; without it the application signs nobody in, and the three below are not read for it |
| `EHOS_CLIENT_ID` | `config :eh_os_contract_auth, sign_in: [client_id:]`: the client EHOS made for this workload, given when `ehos.yaml` declares `sign_in`, and also when it reads the people ([eh-os D-81](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0081-an-application-reads-the-people-directory-as-itself-when-a-people-manager-agrees.md)) or sends mail ([eh-os D-140](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0140-an-application-sends-mail-through-ehos-as-itself-to-the-company-s-people-or-to-any-address-as-far-as-an-agreement-for-its-environment-allows.md)), which does not make it sign people in. Required with `EHOS_SIGN_IN_APPLICATIONS`: the release does not start without it |
| `EHOS_CLIENT_KEY_FILE` | `sign_in: [client_key_file:]`: the client's key. Required with `EHOS_SIGN_IN_APPLICATIONS`: the release does not start without it |
| `EHOS_SIGN_IN_ABSOLUTE` | `sign_in: [absolute_limit:]`: how long a session lasts from the person's sign-in at EHOS, in seconds, the installation's ([eh-os D-113](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0113-how-long-a-sign-in-lasts-is-set-when-ehos-is-installed-and-every-application-is-told.md)); twelve hours when absent. A project an earlier version made is told to add it |

`EHOS_EGRESS_PROXY`, with `HTTPS_PROXY` and `NO_PROXY`, is given only to an application whose
`ehos.yaml` names a host outside the installation, and is read at each call, not in
`config/runtime.exs`: the client that calls such a host attaches `EhOsContract.Auth.Egress`, a Req
plugin from `eh_os_contract_auth` that sends the call through the application's proxy and leaves a
host in `NO_PROXY` direct ([eh-os D-135](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0135-an-application-reaches-a-host-outside-the-installation-only-by-naming-it-in-ehos-yaml-through-a-proxy-of-its-own-that-checks-the-name-in-the-tls-handshake.md)). Req reads none of them by itself, and the proxy is
the only way out.

The application's name in EHOS is its contract domain's, which `--example` names as the OTP
application with any underscore written as a dash: EHOS makes the name a DNS label, which allows
no underscore, and an OTP application's name allows no dash. So `my_shop` is `my-shop` in EHOS,
and its example publishes `my-shop.entry.recorded.v1`.

## The application's CI

The generated `.github/workflows/ci.yml` needs a GitHub App's ID and private key as secrets
([The generated project's CI](https://github.com/EmpoweredHouse/ehos-tools#the-generated-projects-ci)).
It checks the project with `ehosctl verify`, which mise installs from ehos-tools' releases with a
token of the same App, and runs only once its SHA-256 is the one the workflow pins.

On `main`, the workflow builds the image for amd64 and arm64, pushes it to `ghcr.io` by digest, and
publishes it beside the bundle `ehosctl verify` wrote (the manifest and the graph documents, with
`bundle.json`) as the artifact `ehos-deployment`. Once the repository names its EHOS installation,
it also registers the two there as a build, with the commit it came from (`ehosctl builds
register`, eh-os D-146). Once both repositories are public, the token step and the secrets go.

A pull request of the repository is published and registered the same way, and its `preview` job
deploys its build to an ephemeral environment of its own, `<application>-pr-<number>`, with no
stored secret: `ehosctl` exchanges the job's GitHub Actions token at the installation the
repository variable `EHOSCTL_URL` names (`EHOSCTL_CA_PEM` for one with its own CA), for a
credential that reaches the application's ephemeral environments, and from EHOS 0.11.0 only that
pull request's environment ([T-18](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0018-in-a-github-actions-job-ehosctl-talks-to-the-installation-ehosctl-url-names-and-exchanges-the-job-s-token-for-each-credential-keeping-nothing.md),
eh-os D-110, D-121). Each push extends it by eight hours, a comment on the pull request links to
it, and `preview-remove` removes it when the pull request closes, for whoever closes it (a merged
one's expires unless a person removes it, [eh-os#672](https://github.com/EmpoweredHouse/eh-os/issues/672)),
and rewrites the comment to say which. EHOS must trust the repository (`ehosctl trust add`), on
`refs/pull/*/merge` for previews, and on `refs/heads/main` too for `main`'s builds once a ruleset
protects `main`; each developer needs `ehos.application.deploy` and `ehos.application.register` on
the application, since each preview's first deployment registers it there, and their GitHub
account linked to them (`ehosctl github claim`, confirmed by another people manager). Without the
variables, `preview` passes and says how to set them. The generated `DEVELOPMENT.md` has the
commands.

## Using it without `ehosctl`

In a Phoenix project with Igniter, for instance one from
`mix igniter.new shop --with phx.new --with-args="--database postgres"`, install it the way
`ehosctl init` does, with the function behind `mix igniter.install`, which runs Oban's installer
too. The `ref:` is the commit the tag `ehos_app-vX.Y.Z` names, found as in "On an existing project,
and running it again"; `ehosctl --help` prints the version and commit its release installs:

```sh
mix run --no-start -e '{:ok, _} = Application.ensure_all_started(:rewrite); Igniter.Util.Install.install([{:ehos_app, "== X.Y.Z", github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_app", ref: "<commit>"}], ["--example", "--yes"])'
```

ehos-tools and eh-os-contract are private, so git needs credentials for GitHub.
`mix ehos_app.install` run directly works too, but it does not run Oban's installer.

| Option | Effect |
| --- | --- |
| `--example` | Also generate the example domain, contract, route and test, the page that records an entry, and the page that shows the design system |
| `--yes` | Move `eh_os_contract` and `eh_os_contract_auth` to the release without asking, and accept Igniter's own questions |

## What is decided, and what is not yet

What the template says about EHOS follows EHOS's decisions:
[D-51](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0051-ehos-yaml-is-defined-by-ehos.md)
for `ehos.yaml`,
[D-55](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0055-operator-realises-environments-and-deployments.md)
for how a workload runs, and D-56 for what it is given. The contract engine's wiring follows its
[README](https://github.com/EmpoweredHouse/eh-os-contract/blob/main/packages/eh_os_contract/README.md),
and the release follows Phoenix. What is still open is in
[docs/spike.md](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/spike.md):

- a new project is written in `ehos.yaml/v7`, which only EHOS 0.21.0 and later deploy, since only
  they accept `ehos.manifest/v8`. One in v3 to v6 is moved to v7, a v3 with the seed beside
  `migrate:`, at every run, so one moved back is moved again; while `eh_os_contract_auth` is on a
  source of the project's own, which may not read v7, a v3 moves to v4 and a v4 to v6 stays. One
  in v1 or v2 stays in the version it is in, since the file is the developer's.
  v4 adds `needs.database.seed` and `needs.secrets`, v5 `needs.egress`, v6 `needs.mail`, and v7
  `needs.compute`, the CPU and memory the workload asks for (eh-os D-143). A version EHOS adds
  later reaches a project with the eh-os-contract release that carries its schema, and the
  `ehos_app` that pins it;
- `eh_os_contract` reaches a project only through a release of `ehos_app` that pins it
  ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md)):
  a fix in eh-os-contract waits for both releases;
- `eh_os_contract` and `ehos_design` are read from private repositories, so the image is built
  with a GitHub token as a BuildKit secret, which reaches the one step that fetches them;
- the harness links EHOS's own docs on `main`, since an application pins no version of EHOS.

The skills, now the [`ehos-app`](https://github.com/EmpoweredHouse/ehos-tools/tree/main/plugins/ehos-app/skills)
plugin's, and the CodeRabbit configuration were copied from shugyo, an EmpoweredHouse application,
at its commit `47f2b0c`, then adapted to an EHOS application. The copy and each adaptation are
commits of their own, so `git log --follow` on a skill's file shows what came from shugyo and what
changed. `elixir-anti-patterns-review` keeps its Apache-2.0 license and the Elixir Team's notices.

## Working on it

The package is a Mix project of its own, under the Erlang and Elixir of the repository's root
`.tool-versions`:

| Module | What it is |
| --- | --- |
| `Mix.Tasks.EhosApp.Install` | The installer. The files it writes are EEx templates in [`priv/templates/ehos_app.install/`](https://github.com/EmpoweredHouse/ehos-tools/tree/main/packages/ehos_app/priv/templates/ehos_app.install) |
| `Mix.Tasks.EhosApp.Dockerfile` | The Dockerfile's build secret and Tailwind's fetch, which the installer runs after `phx.gen.release` |
| `Mix.Tasks.EhosApp.UnlinkSkills` | Removes the links to the skills 0.3.0 to 0.8.1 copied, which Igniter cannot remove |
| `EhosApp.Review`, `Mix.Tasks.EhosApp.Review` | The review gate every application has, and ehos-tools' own runs (ehos-tools T-17); `EhosApp.Env` is the environment it reads a pull request's description from, a behaviour a test replaces |
| `EhosApp`, `EhosApp.Toolchain` | What a release produces and requires, for its `release.json`; the Erlang and Elixir `.tool-versions` records |

The code the templates write into an application follows the application's rules, the `ehos-app`
plugin's [`elixir` skill](https://github.com/EmpoweredHouse/ehos-tools/blob/main/plugins/ehos-app/skills/elixir/SKILL.md);
the package's own follows [CONTRIBUTING.md](https://github.com/EmpoweredHouse/ehos-tools/blob/main/CONTRIBUTING.md).
Two rules hold the installer: a second run changes nothing, and a change to what an existing
project should have works on one an earlier version made, with a test that starts from such a
project. Igniter is an optional dependency, the convention for installers: the installer
compiles only where Igniter is present, and an application depending on `ehos_app` at runtime
does not inherit it.

### Trying a change

A change to the installer alone needs a new project and nothing else:

```sh
cd "$(mktemp -d)"
mix igniter.new demo --with phx.new --install ehos_app@path:<absolute path to packages/ehos_app> --example --yes
cd demo && mix ecto.setup && mix precommit
```

The path is written into the new project's `mix.exs`, so such a project is for trying the
template, not for keeping. To try it as `ehosctl init` runs it, from a binary built from this
repository, set `EHOSCTL_TEMPLATE_SOURCE=path:<absolute path to packages/ehos_app>`
(`ref:<git ref>` takes another commit of ehos-tools instead); the repository's
[AGENTS.md](https://github.com/EmpoweredHouse/ehos-tools/blob/main/AGENTS.md), "Trying a change end
to end", has the commands, and CI runs the same path on four platforms for a tag or when started
by hand.

### Testing it

```sh
mix check
```

The dependency audit (it needs the network), formatting, compilation with warnings as errors,
Credo, the tests with warnings as errors, Dialyzer, and this reference, built with ExDoc with
warnings as errors (CONTRIBUTING.md, "The gate"). `mix docs` builds the reference into `doc/`.

The tests run the installer on `Igniter.Test.phx_test_project/1`, a Phoenix project held in
memory, and assert the files it creates and the patches it makes, on the lines each test is
about. A project an earlier version made starts from the files that version wrote, kept in
[`test/fixtures/`](https://github.com/EmpoweredHouse/ehos-tools/tree/main/packages/ehos_app/test/fixtures).
The generated `ehos.yaml` is checked against EHOS's schema, as eh-os-contract's release carries
it, with [JSV](https://hexdocs.pm/jsv), and its ports against the generated configuration. The
tests that hold the pinned commits to eh-os-contract's tags need the network and read access to
eh-os-contract, so `mix check` leaves them out and CI runs them with a token:
`mix test --only eh_os_contract` runs them locally.

Run the tests from a checkout whose path has no directory starting with a dot: Igniter's globs
skip such a component, and most tests then fail (`AGENTS.md`, "Traps already found").

### Releasing it

A change a user of the template can see, what the installer writes included, gets a line under
`## [Unreleased]` in
[CHANGELOG.md](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/CHANGELOG.md), in the pull request that makes it. It reaches
projects with the next release, tagged `ehos_app-vX.Y.Z`, which `ehosctl` then pins
(CONTRIBUTING.md, "Releasing `ehos_app`").

## License

Apache License 2.0, as the repository's
[LICENSE](https://github.com/EmpoweredHouse/ehos-tools/blob/main/LICENSE) says.

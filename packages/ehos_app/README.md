# ehos_app

What a Phoenix application needs in order to run on [EHOS](https://github.com/empoweredhouse/eh-os),
as a dependency the application keeps.

Today that is one [Igniter](https://hexdocs.pm/igniter/readme.html) installer, `mix ehos_app.install`.
It turns a fresh Phoenix project into an EHOS application. It is normally run for you by
[`ehosctl init`](../ehosctl/README.md), but it works on its own too. An application gets a later
version by pointing its `ehos_app` dependency in `mix.exs` at the commit that version's tag names,
in place of the `tag:` or `ref:` it has, with that version as its requirement (`"== X.Y.Z"`; Mix
checks it when the project compiles, so a commit of another release fails there, not at
`deps.get`), then running the installer again, which adds what the version writes and leaves the
files the developer changed (a managed section is rewritten, as below). The commit is the full 40
characters, never the tag's name, since a tag can be moved:

```sh
git ls-remote https://github.com/EmpoweredHouse/ehos-tools \
  'refs/tags/ehos_app-vX.Y.Z' 'refs/tags/ehos_app-vX.Y.Z^{}'
# an annotated tag prints two lines: the commit is the one ending in ^{}; a lightweight tag
# prints one, which is the commit. In mix.exs, set :ehos_app's `ref:` to it and its
# requirement to "== X.Y.Z", then:
mix deps.get
git diff mix.lock          # ehos_app's line names that commit, and nothing else moved
mix ehos_app.install
mix deps.update eh_os_contract eh_os_contract_auth   # once the installer has moved them to main
```

From the release after 0.4.0, the installer moves `eh_os_contract` and `eh_os_contract_auth` from a commit an
earlier version pinned to eh-os-contract's `main`
([T-04](../../docs/adr/0004-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)),
and `mix.lock` still names the old commit until `mix deps.update` takes `main`'s latest. Update
the two together: the verifier names the engine by git without a ref.

`mix igniter.upgrade ehos_app` runs no step of the template's: the second run of the installer is
the upgrade
([T-02](../../docs/adr/0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)).

## What the installer does

| Change | Where | Why |
| --- | --- | --- |
| Adds [`eh_os_contract`](https://github.com/empoweredhouse/eh-os-contract) and `eh_os_contract_auth`, from git, both following eh-os-contract's `main` ([T-04](../../docs/adr/0004-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)), and moves a project on a commit an earlier version pinned to it | `mix.exs` | The contract engine, and the verifier of the credentials EHOS issues. Neither is on Hex yet nor tags a release, and both live in subdirectories, hence `sparse:`. `mix.lock` holds the commit; `mix deps.update eh_os_contract eh_os_contract_auth` moves both to `main`'s latest. The auth package names the engine without a ref, so the engine is overridden to the same branch |
| Adds [`ehos_design`](../ehos_design/README.md), the EmpoweredHouse design system, from ehos-tools, pinned to the commit of its release, unless the project has it already, at whatever version | `mix.exs` | The application's default look ([eh-os D-72](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0072-the-design-system-is-a-library-ehos-design-kept-in-ehos-tools.md)). Not on Hex, and in a subdirectory, hence `sparse:` |
| Imports the design system's layer right after Tailwind, removes the two daisyUI themes Phoenix writes, and leaves a section of the application's own at the end | `assets/css/app.css` | Tailwind's utilities and daisyUI's components take the design system's tokens, so `core_components.ex` follows it unchanged. A token is overridden in the application's section. To decline it, the developer removes the import and keeps the comment above it, as that comment says, and later runs never add it back. A daisyUI theme the developer has tuned is kept, with a notice. A stylesheet without Tailwind's import is left alone, with what to add |
| Serves the design system's fonts at `/ehos_design/fonts/`, after Phoenix's static files | `lib/<app>_web/endpoint.ex` | The page loads nothing from another origin |
| Preloads Albert Sans at 400 and 500, before the stylesheet, when it first installs the design system | `lib/<app>_web/components/layouts/root.html.heex` | A first visit does not lay text out in the fallback font and then reflow it. A later run leaves the layout alone, so links the developer removed stay removed; a layout that is not Phoenix's gets a notice with the two links |
| Runs the contract compiler after Elixir's | `mix.exs` | The rules between a contract, its domain and its siblings record no compile dependency, so the engine checks them as a Mix compiler |
| Installs Oban through Oban's own installer | `mix.exs`, `config/`, a migration, `application.ex` | The engine runs asynchronous handlers as Oban jobs. Oban's setup stays Oban's to change |
| Configures the engine with the application, its repo and `EhOsContract.Auth` as the authorizer | `config/config.exs` | The repo is found in the project, not assumed to be `<App>.Repo`; with several, the installer asks which one. With none, it stops and changes nothing |
| Generates the engine's and the verifier's migrations after Oban's | `priv/repo/migrations/` | The engine's jobs run on Oban's tables. The installers run in the same second, so the timestamps are chosen explicitly |
| Gives Oban's migration the application's schema | Oban's migration | Oban names `public` in every statement unless given a prefix, and EHOS gives the application a schema of its own, which its owner may use but not create |
| Starts `EhOsContract`, `EhOsContract.Auth`, `<App>Web.Health` and `<App>.SignIn` after the repo and Oban, before the endpoint | `lib/<app>/application.ex` | At boot the engine records the deployed contract version, and the key store loads EHOS's keys from its table and then from EHOS |
| Signs people in to the pages through EHOS: `<App>.SignIn`, which starts `EhOsContract.Auth.SignIn` where it is configured, the encrypted cookie session, `/auth/ehos` forwarded to `EhOsContract.Auth.SignIn.Router`, a `:signed_in` pipeline, a sign-in link and sign-out button on the root, and their test | `lib/<app>/sign_in.ex`, `lib/<app>_web/endpoint.ex`, the router, `lib/<app>_web/sign_in_components.ex`, the root's template, `test/<app>_web/sign_in_test.exs` | An application has no login of its own: people sign in at EHOS (eh-os D-64), as `eh_os_contract_auth`'s README prescribes. The session holds the sign-in's state, nonce and PKCE verifier between the redirect and the callback, so it is encrypted. Development and tests have no EHOS, so the client starts only where `config/runtime.exs` configures it, in a release, and the sign-in answers 503 elsewhere. A project from an earlier version gets a migration to the verifier's version 3, which holds the people signed in |
| Serves `/health/live` and `/health/ready` on port 4001, in a plug of their own | `lib/<app>_web/health.ex` and its test | What EHOS probes, on a port it never exposes. Ready once the application holds EHOS's keys, since without them it refuses every credential |
| Listens on port 4000 and reads no `PORT` | `config/config.exs`, `config/runtime.exs` | EHOS gives no port: the application listens on the ports its `ehos.yaml` declares, and a test pins that the two agree |
| Reads what EHOS gives an application at start, the sign-in's client included | `config/runtime.exs` | The names are fixed by EHOS (below). A `runtime.exs` from an earlier version gets the sign-in's block on its own |
| Writes `ehos.yaml` as `ehos.yaml/v2`, with `sign_in: {}`, and `.ehos/ehos.yaml.v2.json` beside it | project root | What the application needs from EHOS, never how. `sign_in` is what makes EHOS give the application a client (eh-os D-69). The schema is EHOS's, copied unchanged, so an editor checks the file as it is typed. An `ehos.yaml` the developer has is left alone, and the installer says what signing people in needs of it |
| Writes `rel/env.sh.eex` | `rel/` | The release writes under `/tmp` alone and starts no distribution, for a read-only filesystem under Pod Security `restricted` |
| Runs `mix phx.gen.release --docker`, unless there is a Dockerfile already, then `mix ehos_app.dockerfile` | `Dockerfile`, `rel/`, `lib/<app>/release.ex` | A release image, as the project's own Phoenix version generates it, whose one `deps.get` step reads a GitHub token from the build secret `github_token`, since `eh_os_contract` and `ehos_design` are private. An existing Dockerfile is the developer's: only that step is changed, and only when it is Phoenix's |
| Writes a GitHub Actions workflow | `.github/workflows/ci.yml` | The gates on every pull request; on `main`, the image built natively for amd64 and arm64 and pushed to `ghcr.io` as one index, by its digest, and the manifest of the same commit, published together as the artifact `ehos-deployment` |
| Adds `eh_os_contract.check` to `mix precommit` | `mix.exs` | Whole-program contract checks the compiler cannot make |
| Writes `.tool-versions` | project root | The Erlang and Elixir the project was generated with, read by both mise and asdf |
| Moves the `AGENTS.md` Phoenix writes to `docs/phoenix.md`, and writes a lean `AGENTS.md` that opens with EHOS's section, and a `CLAUDE.md` loading it | project root, `docs/` | Coding agents read EHOS's rules first, and a guide short enough to read whole points to the rest. Phoenix's rules stay as Phoenix wrote them |
| Writes `VISION.md`, opened by a section on what EHOS is and where the application sits in it, and `ARCHITECTURE.md` and `TESTING.md`, filled with what the installer knows | project root | Every change starts by reading the vision, so the platform's idea is read with the application's. The rest is the application's to write |
| Replaces the `README.md` Phoenix writes with one that says what the application is built on | project root | Nothing else in the project explains the ecosystem to a person, or to a reviewer on GitHub |
| Writes an `AGENTS.md` and a `CLAUDE.md` in `lib/<app>/contracts/` and in `lib/<app>_web/` | `lib/` | The rules for writing a contract, and for the web layer, load when an agent works there |
| Copies four skills, `plan`, `ship`, `review` and `elixir-anti-patterns-review`, then runs `mix ehos_app.link_skills` while one has no link | `.agents/skills/`, `.claude/skills/` | Canonical where other agents read them, and linked where Claude Code does. Igniter cannot make a symlink, so a task does |
| Writes a CodeRabbit configuration and a pull request template | `.coderabbit.yaml`, `.github/` | The AI review reads the same rules, and a PR says how it was tested |
| Writes `test/harness_test.exs` | `test/` | It keeps the docs honest: links resolve, the guides stay within their line budgets, nothing cites an ADR, and every skill is linked |
| Ignores `.plans/` | `.gitignore` | The `plan` skill writes working plans there, which are history, not current truth |
| Keeps `ehos_app` itself to development | `mix.exs` | It is needed only to run the installer again, so CI and the image never fetch it |
| With `--example`, writes a page that shows the design system, its route and its test | `lib/<app>_web/live/design_system_live.ex`, the router, `test/<app>_web/live/design_system_live_test.exs` | Type, colours, buttons, a form validated by a changeset and a table, at `/design-system`, in both themes |
| With `--example`, writes a domain, a contract, its implementation, a route and a test | `lib/<app>/domain.ex`, `lib/<app>/contracts/entries.ex`, `lib/<app>/entries/entry.ex`, the router, `test/<app>_web/entries_api_test.exs` | So the tests, the check and the manifest have something to read on day one. A clerk records an entry and an auditor flags one, each the only actor allowed their command, served at `POST /api/commands/<app>.<command>` behind `EhOsContract.Auth.Plug` |

A second run changes nothing, and a test pins that, including that it schedules no generator. Files the
installer creates are never overwritten. Five files hold a section of the installer's between two
markers, `<!-- ehos_app:<name> -->` and `<!-- /ehos_app:<name> -->`: `AGENTS.md`, `README.md`,
`VISION.md`, and the `AGENTS.md` in `lib/<app>/contracts/` and in `lib/<app>_web/`. A later version of
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

The application's name in EHOS is its contract domain's, which `--example` names as the OTP
application with any underscore written as a dash: EHOS makes the name a DNS label, which allows
no underscore, and an OTP application's name allows no dash. So `my_shop` is `my-shop` in EHOS,
and its example publishes `my-shop.entry.recorded.v1`.

## Using it without `ehosctl`

The package is a subdirectory of ehos-tools, and `mix igniter.install ehos_app@github:…` cannot
name a subdirectory. Install it the way `ehosctl init` does: with the function behind
`mix igniter.install`, which takes a dependency as Mix writes it and runs Oban's installer too. In
a Phoenix project with Igniter, for instance one from
`mix igniter.new shop --with phx.new --with-args="--database postgres"`:

The `ref:` is the commit the tag `ehos_app-v0.4.0` names: a tag can be moved, a commit cannot.

```sh
mix run --no-start -e '{:ok, _} = Application.ensure_all_started(:rewrite); Igniter.Util.Install.install([{:ehos_app, "== 0.4.0", github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_app", ref: "9ba6f3ebacc1e6236a514534e9be6b8385d01fa0"}], ["--example", "--yes"])'
```

ehos-tools and eh-os-contract are private, so git needs credentials for GitHub. To try a change to
the installer, name `{:ehos_app, path: "<absolute path to this directory>", override: true}`
instead. The path is written into the new project's `mix.exs`, so such a project is for trying
the template, not for keeping. `mix ehos_app.install` run directly works too, but it does not run
Oban's installer.

### Options

| Option | Effect |
| --- | --- |
| `--example` | Also generate the example domain, contract, route and test |

## What is decided, and what is not yet

What the template says about EHOS follows EHOS's decisions:
[D-51](https://github.com/empoweredhouse/eh-os/blob/main/docs/adr/0051-ehos-yaml-is-defined-by-ehos.md)
for `ehos.yaml`,
[D-55](https://github.com/empoweredhouse/eh-os/blob/main/docs/adr/0055-operator-realises-environments-and-deployments.md)
for how a workload runs, and D-56 for what it is given. The contract engine's wiring follows its
[README](https://github.com/empoweredhouse/eh-os-contract/blob/main/packages/eh_os_contract/README.md),
and the release follows Phoenix. What is still open is in [docs/spike.md](../../docs/spike.md):

- the schema's copy is taken from eh-os's `main` (`Mix.Tasks.EhosApp.Install.ehos_yaml_schema_source/0`),
  because EHOS freezes `ehos.yaml/v2` in its release after 0.3.0, which is not out yet;
- `eh_os_contract` is pinned to a commit of its `main`, the first with the browser-session Plug,
  until it tags a release with it;
- the EmpoweredHouse design system is not published, so the harness names a placeholder for it
  (`Mix.Tasks.EhosApp.Install.design_system/0`), in managed sections alone;
- the harness links EHOS's own docs on `main`, since an application pins no version of EHOS.

The skills and the CodeRabbit configuration were copied from shugyo, an EmpoweredHouse application,
at its commit `47f2b0c`, then adapted to an EHOS application. The copy and each adaptation are
commits of their own, so `git log` on a file under `priv/templates/ehos_app.install/skills/` shows
what came from shugyo and what changed. `elixir-anti-patterns-review` keeps its Apache-2.0 license
and the Elixir Team's notices.

## Development

```sh
mix check
```

The tests run the installer on `Igniter.Test.phx_test_project/1`, a Phoenix project held in memory,
and assert what it creates and patches. The generated `ehos.yaml` is checked against the schema's
copy with [JSV](https://hexdocs.pm/jsv), and its ports against the generated configuration. The
files the installer writes are EEx templates in
[`priv/templates/ehos_app.install/`](priv/templates/ehos_app.install), and the schema's copy is
[`priv/schemas/ehos.yaml/v2.json`](priv/schemas/ehos.yaml/v2.json).

Run the tests from a checkout whose path has no directory starting with a dot: Igniter's globs skip
such a component, and most tests then fail (`AGENTS.md`, "Traps already found").

Igniter is an optional dependency, which is the convention for installers. The installer compiles
only where Igniter is present, and an application depending on `ehos_app` at runtime does not
inherit Igniter.

Changes are recorded in [CHANGELOG.md](CHANGELOG.md). Raise the version whenever what the installer
writes changes: it names the release a project moves its dependency to.

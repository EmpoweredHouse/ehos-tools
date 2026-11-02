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

## [0.27.0] - 2026-11-02

### Added

- With `--example`, the installer writes a page that records an entry as the person signed in, at
  `/entries/new`, behind the `:signed_in` pipeline. It calls a context, `<App>.Entries`, which
  calls `EhOsContract.call/3` with the actor of the person. Its test signs in with
  `EhOsContract.Auth.Testing.sign_in/3`, and shows that the engine refuses a person whose sign-in
  does not grant `<app>.record_entry`. The root boundary exports the context, or, where the
  project's boundaries are its own, a notice says to export it. A project without the `:browser`
  and `:signed_in` pipelines, or with an `<App>.Entries` of its own, gets no page (#700).

### Changed

- The generated docs name two ways for a command to reach a contract. A request to `/api` goes
  through `EhOsContract.Plug`. A page calls a context function, which calls `EhOsContract.call/3`
  with the actor that `EhOsContract.Auth.Session.actor/2` gives. `lib/<app>_web/AGENTS.md`,
  the Safety section of `AGENTS.md` and `ARCHITECTURE.md` say this, and the rule of the web
  layer no longer says that `EhOsContract.Plug` is the only way (#700).
- A project enables the `ehos-app` plugin's 0.7.0 instead of 0.6.0. Its skills show how a page
  issues a command as the person signed in, and their reviews check it (#700).
- A project enables the eh-os-contract plugin's 0.14.3, the one eh-os-contract's release v0.13.1
  carries, in place of 0.10.1. Its skills name the engine's pages as v0.13.1 has them.

### Security

- **Breaking:** a project is pinned to eh-os-contract's release v0.13.1 instead of v0.12.0
  (`eh_os_contract` `~> 0.13.0`, `eh_os_contract_auth` `~> 0.11.0`). `eh_os_contract_auth` 0.11.0
  requires `jsv` `~> 0.26.2`, which fixes EEF-CVE-2026-117680
  ([eh-os-contract#543](https://github.com/EmpoweredHouse/eh-os-contract/issues/543)). With
  v0.12.0, a new project's `mix hex.audit` fails on `jsv` 0.25.0. If a project is on v0.12.0's
  commit, the installer moves it when it runs again; a project on a commit of its own keeps it.
  What the release asks of a project, as its changelogs say:
  - Run `mix deps.update jsv`, and remove an `ignore_advisories:` entry for this advisory.
  - Build a domain value made of fields as its struct. A map in its place is refused.
  - A read model's `Row` is an Ecto schema: read it `from r in Row`, with no `select:` map.
  - A personal field is left out when a struct of a contract is inspected. Remove an `Inspect`
    of the project's own for such a struct: it now fails `compile --warnings-as-errors`.
  - A process module's guide is `docs/process.md` in `eh_os_contract`, not
    `docs/concepts/process.md`. The installer's warning names the new path.
  - Configure Oban to run the queue `:events` if a contract delivers an effect `:at_least_once` or
    a process manager has a timer: add `events: 10` to the `queues:` of `config :<app>, Oban`.
    Without the queue, these jobs wait and never run. The engine needed it before too, but its
    guide did not say so, and the installer does not add it.

## [0.26.0] - 2026-11-02

### Added

- A project enables the `ehos-app` plugin's 0.6.0, which has `/ehos-app:retro`. After a pull
  request, it drafts an issue for each defect of the platform that the work met, in the repository
  that owns the defect, and files it when the user agrees. It lists each issue in
  `docs/platform-issues.md`, with what changes in the application when the issue is fixed (#706).
  It reads the outside systems of the application in "Outside systems" in `ARCHITECTURE.md`, where
  the template asks for them, and checks a finding about one against its official documentation.
  In a new project, the template's comment there asks for the library that reaches each system and
  a link to its official documentation.
- The installer writes `docs/platform-issues.md` one time, with empty "Open" and "Done" tables. It
  never overwrites the file of a project. The section of `AGENTS.md` has "The platform is ours",
  and the cycle in `DEVELOPMENT.md` names `/ehos-app:retro` after the pull request. In a project
  from an earlier version, the installer tells you to add the file to "Where to read" in
  `AGENTS.md`.

### Changed

- In the section of `AGENTS.md`, the heading "EHOS's rules" is now "EHOS's rules come first". Its
  rule on topic docs and its rule on plans are now one rule: a change in behaviour, or a shipped
  plan, updates the topic doc of the area in its pull request (#706).
- The generated CI names the `ehosctl` it runs once, in the workflow's `env`:
  `PINNED_EHOSCTL_VERSION`, which every job installs, and `PINNED_EHOSCTL_SHA256`, which every job
  checks the binary against before it runs it. A step's name says the version through
  `${{ env.PINNED_EHOSCTL_VERSION }}`.
- The generated CI runs `ehosctl` 0.31.0 instead of 0.30.0, which creates from `ehos_app` 0.25.0
  and refuses and audits as 0.30.0 did. A workflow 0.25.0 wrote, untouched since, is replaced
  when the installer runs again. Its comment on `mix deps.get --check-locked` no longer says
  that `eh_os_contract` follows a branch: a new project pins it by a commit.
- Whether a project already has a contract, which keeps the seed's test out of it, is read in
  `lib/<app>/contracts/` alone, where the template's `AGENTS.md` has contracts written: reading
  every file under `lib/` that early made each install slower. A project whose contracts live
  elsewhere gets the test, which fails on their commands until a step issues them or
  `@not_seeded` names them.
- The generated `DEVELOPMENT.md` no longer says that a process owner bound `ehos.registrar` in
  production may activate a version there by hand: from EHOS 0.24.0 only a deployment puts a version
  in force, and `ehos.registrar`, with `ehos.process_owner`, lets them approve a promotion that
  changes the roles
  ([eh-os D-154](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0154-the-authority-in-force-in-an-environment-changes-only-with-a-deployment-and-nobody-puts-a-registered-version-in-force-by-hand.md),
  [#694](https://github.com/EmpoweredHouse/ehos-tools/issues/694)).

### Fixed

- The generated CI no longer fails when mise-action's cache restores a Hex older than 2.6.0,
  which `ehosctl verify` refuses for the dependency audit: it installs the newest Hex with
  `mix local.hex --force`, no longer `--if-missing`, which kept the cached one
  ([#532](https://github.com/EmpoweredHouse/ehos-tools/issues/532)).
- A Phoenix project not on the welcome page this version knows, such as one with a home page of
  its own, is no longer given Credo, `.credo.exs`, `test/conventions_test.exs` and `"credo"` in
  `precommit`, on which its first `mix precommit` could fail, nor `<App>.Clock`. Like a project
  made before, it gets a notice that says how to adopt Credo and the conventions test
  ([#634](https://github.com/EmpoweredHouse/ehos-tools/issues/634)).

## [0.25.0] - 2026-10-30

### Added

- A new project compiles with [Boundary](https://hexdocs.pm/boundary), its compiler first: the
  root module exports what the web and the application call (`Access`, `LogRedaction`), the web
  depends on the root alone and exports its endpoint, the application is a top-level boundary
  above both, and the repo, `<App>.Clock` and `<App>.Access` are boundaries of their own inside
  the root, so the web never reaches the repo and a context lists the siblings it uses.
  `ConnCase` is outside every boundary. `docs/elixir.md` and the `ehos-app:elixir` skill say how
  a new context declares its own. A project with code of its own, made before or a Phoenix
  project no longer on Phoenix's welcome page, is not given it, and a notice says how to adopt
  it; one that has Boundary already keeps its declarations, and is told to export `Access` when
  the run gives it the access page.
- **Breaking:** `test/callback_docs_test.exs`, which fails on a `@callback` of the application's
  behaviours that has no `@doc`, in a new project, and once in a project with code of its own,
  made before or a Phoenix project no longer on Phoenix's welcome page, where `mix precommit`
  fails until each callback it lists has one; a notice says so. Protocols, macro callbacks and
  modules compiled without docs are read as such.
- The `ehos-app` plugin's 0.5.0 has `/ehos-app:sample-data`, which a model invokes when a
  contract gains or changes a command, an event or a field: it drafts sample data from the
  contracts and has the seed record it through their commands, as the system actor
  `:sample_data`, once per step, by `EHOS_SEED_PROFILE`, refusing the application's production
  environments, with a test that every command a person may issue is seeded or says why not.
  It leaves out a command whose event holds a personal field, which the seed's container cannot
  seal for the application to read, until EHOS gives it the vault's master key.
  `DEVELOPMENT.md` names it for step 2 and in "Data to try a preview on".

### Changed

- A new project's seed, `<App>.Seed`, can record business facts: `run/0` starts the repo and
  an Oban that runs no queue and runs `priv/repo/seeds.exs`, which now calls `add/2`, and
  `add/2` issues the steps of the profile `EHOS_SEED_PROFILE` names (`empty`, or `small`)
  through the contracts' commands as the system actor `:sample_data`, each once. The seed refuses
  the environments `:production_environments` names, `run/0` also one EHOS did not name, and
  `test/<app>/seed_test.exs` holds the profiles, the guard and that every command a person may
  issue is seeded or says why not. The example's domain declares `:sample_data`, its commands
  name it and the seed records two entries and a flag. A project made before keeps its seed;
  one that had none but has a contract of its own, or whose `ehos.yaml` moves from v3, gets this
  one without its test
  ([#476](https://github.com/EmpoweredHouse/ehos-tools/issues/476)).
- The generated CI runs `ehosctl` 0.30.0 instead of 0.29.0, whose refusal of a job's token
  names the likeliest cause first, and whose `verify` refuses Hex before 2.6.0, as `mix precommit`
  does. A workflow 0.23.0 or 0.24.0 wrote, untouched since, is replaced when the installer runs
  again.
- A project enables the `ehos-app` plugin's 0.5.0, whose `/ehos-app:elixir` teaches
  [T-20](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)'s
  behaviours, the `Env` pattern, the wire shape in `*JSON` and `*HTML`, a context's boundary and
  the audit's smaller rules, numbered 1 to 12, and whose review marks each of them
  ([#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).
- **Breaking:** the `hex_audit/1` the installer writes into `mix.exs` needs Hex 2.6.0, whose
  `mix hex.audit` fails when it cannot fetch a package's registry entry, where 2.5 passed without
  checking it ([#537](https://github.com/EmpoweredHouse/ehos-tools/issues/537)). The copy 0.22.0
  to 0.24.0 wrote is replaced where the developer has not changed it; one they changed is kept,
  with a notice saying to raise its check. Run `mix local.hex --force` before `mix precommit`.
- **Breaking:** `mix precommit` runs `test --warnings-as-errors` in place of a plain `test`, in a
  new project and in one made before, so a test that warns fails the gate as code that warns
  does, and the run says so to a project that is not new. A test step with options of the
  project's own is kept. `TESTING.md` says so, and why
  Dialyzer is not a gate: on a new project its PLT takes about a minute, and it reports a pattern
  at line 1 of a Phoenix controller that comes from Phoenix's macros.
- The rules the installer writes follow
  [ehos-tools T-20](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md),
  in a new project and in one made before, whose template sections the installer rewrites:
  `docs/elixir.md`'s "Ways out" becomes "Behaviours", where a context a page calls is a behaviour
  too, every `@callback` has a `@doc`, an Oban worker calls its collaborators through their
  `current()`, and code reads the environment at run time through an `Env` behaviour of the
  application's own; a context function returns `{:ok, _}` or `{:error, _}` only where it can
  fail, and every public function has a `@spec`; the `*JSON` or `*HTML` module shapes what goes
  over the wire; a `case` for one call that succeeds or fails, no separator comments and no dead
  code. `TESTING.md` adds how a test reads (the happy path first, helpers last, no `impl` in a
  name, no literal for what a factory gave). `AGENTS.md`'s section gains "Essentials" and
  "Safety", and says the rest of how Elixir is written in a paragraph that points to
  `docs/elixir.md`.
- The access page asks `<App>.Access`, a behaviour with `<App>.AccessImpl` beside it, what the
  signed-in person may do, where its controller worked it out itself: `config/config.exs` names the
  implementation, `config/test.exs` `<App>.AccessMock`, which `test/support/mocks.ex` declares, so
  that a page's test that should not run it can expect it, and `test/<app>/access_test.exs` holds
  the implementation to the behaviour. The controller's test renders the page from an answer of
  `Access`'s shape it gives. A project the installer gives the access page now, from an earlier
  version on Phoenix's welcome page, gets the mock at the end of its own mocks module, and Hammox
  where it had none; one with an `<App>.Access` of its own keeps Phoenix's page, with a notice. An
  access page an earlier version wrote is the project's, and is left as it is.

## [0.24.0] - 2026-10-30

### Changed

- **Breaking:** a new project takes `ehos_design` 0.5.0 instead of 0.2.0 (`~> 0.5.0`, the commit
  `ehos_design-v0.5.0` names), with the outcome and badge components, `EhosDesign.Mail`, and
  premailex and Floki as its dependencies. A project still on the commit an earlier `ehos_app`
  pinned, 0.2.0's or 0.1.0's, as it wrote it, is moved when the installer runs again, after asking
  unless `--yes`, and from 0.1.0's commit, which was given neither, it is given the components'
  templates as a Tailwind source and their hooks. Any other source of `ehos_design` is kept, with a
  warning when it is an earlier version's commit beside a requirement or an option of the project's
  own, saying what to move by hand. A moved project commits the `mix.lock` its next `mix deps.get`
  writes; a module that imports `EhosDesign.Components` beside a `badge/1` of its own no longer
  compiles where it calls `<.badge>`; and daisyUI's `.badge` classes take the design system's look,
  as ehos_design 0.3.0's notes say.
- A project enables the `ehos-app` plugin's 0.4.0: a model invokes `/ehos-app:plan` beyond a small
  fix, `plan` writes phases that each end in a stop, and `/ehos-app:ship` stops after each for the
  user's go or no-go; `/ehos-app:pre-pr-review` follows the same procedure as EHOS's own
  repositories; the review checklist marks each of `/ehos-app:elixir`'s numbered rules; and every
  skill says first when it is for. The generated `AGENTS.md` and `DEVELOPMENT.md` say who starts
  which skill to match ([#509](https://github.com/EmpoweredHouse/ehos-tools/issues/509),
  [#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).

## [0.23.0] - 2026-10-30

### Added

- `mix help ehos_app.install` says what running the installer again does and when it writes
  nothing, `mix help ehos_app.dockerfile` when it leaves the Dockerfile with a notice, and every
  public function says what it returns and how it fails, with an example where one helps;
  `mix docs` builds the package's reference with ExDoc
  ([#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).
- `EhosApp.Review.run_task/3` takes `:env`, an `EhosApp.Env` that `pull_request` reads
  `PULL_REQUEST_BODY` through, so a caller's test says what the environment holds without
  setting it; `mix ehos_app.review pull_request` reads the process's environment, as before
  (ehos-tools T-20, [#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).

### Changed

- When EHOS refuses a push's build, the generated CI's warning and run summary name the likeliest
  cause first: the GitHub account that started the run is not linked yet, to be claimed from that
  run with `ehosctl github claim` and confirmed by another person holding `ehos.people.manage`. A
  trust that does not accept the ref comes second
  ([#595](https://github.com/EmpoweredHouse/ehos-tools/issues/595)).
- The generated `DEVELOPMENT.md` names the console's menu entry for what waits for a process
  owner's approval **Approvals**, as EHOS 0.24.0 and later call it
  ([eh-os#1095](https://github.com/EmpoweredHouse/eh-os/issues/1095)), and says that those EHOS
  versions mail a process owner who has signed in a link to a promotion that waits for them
  ([eh-os#1097](https://github.com/EmpoweredHouse/eh-os/issues/1097),
  [eh-os D-151](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0151-a-requested-promotion-is-mailed-to-the-nearest-of-the-people-it-waits-for-never-to-its-requester.md)).
- The generated CI runs `ehosctl` 0.29.0 instead of 0.28.0, whose `verify` audits the
  dependencies, so the `check` job no longer runs `mix hex.audit` as a step of its own. A workflow
  0.22.0 wrote, untouched since, is replaced when the installer runs again.
- The generated CI's `preview-remove` job runs `ehosctl` 0.29.0 instead of 0.23.0, as every other
  job does, with the security fixes to its bundled dependencies since; it removes a preview as
  before ([#611](https://github.com/EmpoweredHouse/ehos-tools/issues/611)).
- The generated `DEVELOPMENT.md` and the `preview` job's comment in the generated CI say that the
  people manager who confirms a GitHub account's claim first checks with its person that the run
  is theirs, as `ehosctl people github confirm` asks
  ([#608](https://github.com/EmpoweredHouse/ehos-tools/issues/608)).
- The generated `DEVELOPMENT.md` says that the only people manager of an installation confirms
  their own GitHub account's claim, as EHOS 0.24.0 and later let them
  ([eh-os#1092](https://github.com/EmpoweredHouse/eh-os/issues/1092),
  [eh-os D-152](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0152-a-people-manager-confirms-their-own-github-account-only-when-nobody-else-may-and-it-is-recorded-as-a-self-confirmation.md)).

## [0.22.0] - 2026-10-29

### Changed

- `/ehos-app:elixir` adds a key that is set only when its value is not `nil` with `maybe_put/3`,
  which skips `nil` alone; any other condition stays an `if` at the call site. It had said an `if`
  for every condition.
- **Breaking:** a new project's `ehos.yaml` is `ehos.yaml/v7`, which only EHOS 0.21.0 and later
  deploy, and one in `v3` to `v6` is moved to v7 whenever the installer runs, so one moved back is
  moved again: its `schema:` and its schema comment's version, nothing else, and to a v3 the seed
  beside `migrate:` as before. One whose `eh_os_contract_auth` is on a source of its own, which
  may not read v7, keeps its version, a v3 moving to v4 with its seed as before, and the
  installer says so. v7
  lets the workload say the CPU and memory its containers ask for under `needs.compute`, which the
  template leaves out and its comment shows; without it each takes its environment's defaults
  (eh-os D-143, [#481](https://github.com/EmpoweredHouse/ehos-tools/issues/481)).
- **Breaking:** a project is pinned to eh-os-contract's release v0.12.0 instead of v0.10.0
  (`eh_os_contract` `~> 0.12.0`, `eh_os_contract_auth` `~> 0.9.0`), which writes
  `ehos.manifest/v8` for an `ehos.yaml/v7`, and enables the eh-os-contract plugin's 0.10.1, the one
  that release carries, in place of 0.9.2. A project on v0.10.0's commit is moved when the
  installer runs again; one on a commit of its own keeps it. What the two releases ask of a project,
  as their changelogs say: a lock holding `decimal` below 3.2 or `jose` below 1.11.13 is updated
  with `mix deps.update decimal jose`; a contract's scenario whose data breaks one of its values'
  invariants now fails, as dispatch would refuse it; a caller of
  `EhOsContract.Auth.Mail.deliver/1` that matches every reason adds `:outcome_unknown`, some
  messages may have been sent; HTML it sends goes out as given from EHOS 0.21.0, so a value it
  did not write is escaped, with `verify_html: true` as a backstop; a test module that
  `use`s `EhOsContract.Auth.Testing` and defines its own `sign_in/3` or `sign_out/1` renames it,
  since the module now imports both; and `mix eh_os_contract.check` warns of an event an actor
  records that no scenario records, which fails `check --warnings-as-errors` until one does.
- **Breaking:** the generated CI registers every build it publishes with EHOS, on `main` and on a
  pull request, with the commit it came from (`ehosctl builds register`, eh-os D-146), and a pull
  request's preview is deployed from its build, by its id (#554). Previews need EHOS 0.22.0 or
  later. The artifact `ehos-deployment` holds `image` and `ehos.bundle/`, the bundle
  `ehosctl verify` writes, in place of `ehos.manifest.json` and `ehos.graph/`; a script that reads
  them reads `ehos.bundle/ehos.manifest.json` and `ehos.bundle/graph/`. For `main`'s builds, the
  repository's trust also accepts `refs/heads/main`. Protect `main` with a ruleset first. Until
  then, `main`'s run publishes as before and says how to add the ref. The workflow fails, saying
  why, when the project's `eh_os_contract` has no bundle task (#520).

- CI's `check` job runs `ehosctl verify` from `ehosctl` 0.28.0, the newest released, instead of
  0.3.0, so CI has the gates `verify` gained since, the schema check and Credo among them, and
  the workflow's own step for the schema check is gone. A workflow an earlier version wrote,
  untouched since, is replaced; one the project changed is left, with the diff. A project with
  Credo in `mix.lock` is linted in CI from then on: give it `only: [:dev, :test]`, and fix what
  `mix credo` finds, or its CI fails
  ([#332](https://github.com/EmpoweredHouse/ehos-tools/issues/332)).
- AGENTS.md's "Where the platform documents itself" moved to ARCHITECTURE.md, to keep AGENTS.md
  within its 200 lines, and its plan step joined "Execution discipline". TESTING.md's rule that
  an `async` test never changes `Application` env, which read as if one that is not async may,
  gave way to a section, "Doubles": how a test replaces a way out, never with
  `Application.put_env/3`
  ([#504](https://github.com/EmpoweredHouse/ehos-tools/issues/504)).

### Added

- A project fails on a package in `mix.lock` that is retired or has a security advisory, which `mix
  deps.get` only printed: an application deployed Bandit 1.13.1 with eleven. `mix precommit` runs
  `mix hex.audit` first, through `hex_audit/1`, a function the installer adds to `mix.exs`, since as
  a task of the alias it is not found after `compile` and a finding does not stop the steps after
  it; it refuses a Hex before 2.5.1, which checks retirements alone or, as 2.5.0, cannot acknowledge
  a finding. CI runs the audit right after `mix deps.get`. TESTING.md says how to acknowledge a
  finding that does not reach the application (`hex: [ignore_advisories: [...]]`), that the audit
  needs the network, and that a new advisory fails `main` and a hotfix too. A project with such a
  package fails from the upgrade on until it updates or acknowledges it; a plain `"hex.audit"` in
  its `precommit` is replaced ([#507](https://github.com/EmpoweredHouse/ehos-tools/issues/507)).
- A project gets `docs/elixir.md`, how its Elixir is written where it is not a contract's part: a
  way out of the application as a behaviour with `current/0`, mocked in tests; no test hook in
  production code; a table queried only by its owner; changesets for input, never a
  projection; a page or controller that orchestrates; flat control flow; moduledocs without
  tickets. The template keeps a section of it, rewritten on upgrade, above the application's own
  rules. AGENTS.md's section gains "How Elixir is written" and "Execution discipline" (phases
  with a stop after each, a green commit per step, `git log` before changing a pattern), the web
  layer's AGENTS.md the rule for a thin page. A project whose own part of AGENTS.md has no row
  for docs/elixir.md is told to add one
  ([#504](https://github.com/EmpoweredHouse/ehos-tools/issues/504)).
- A project with no `test/support/mocks.ex` yet gets the tools those rules assume, once:
  Hammox and ExMachina, `test/support/mocks.ex` with `setup_mocks/1` (Mox's mode from the test,
  expectations verified at its end, each mock's default) and `test/support/factories.ex`, and
  `DataCase` and `ConnCase` call the one and import the other. A project with a mocks module of
  its own keeps its way, a case that imports a factory module of its own gets no second one, a
  case the installer cannot place them in is told what to add, and what a developer removes is
  not brought back. A new project also gets Credo, with `.credo.exs` and `"credo"` last in
  `mix precommit`; `test/conventions_test.exs` (only a table's owner uses `Ecto.Query`, a
  contract's part aside); and `<App>.Clock`, its first way out, named in `config/config.exs`
  and mocked in `config/test.exs`. A project made before gets none of these three, since its
  first `mix precommit` would fail on code written before them, and is told how to adopt them
  ([#504](https://github.com/EmpoweredHouse/ehos-tools/issues/504)).
- A project enables the `ehos-app` plugin's 0.3.0, which has `/ehos-app:elixir`: how a module
  that is not a contract's part and its tests are written (a way out of the application as a
  behaviour mocked with Hammox, no test hook in production code, a table queried only by its
  owner, changesets for input, a page that orchestrates, flat control flow, factories). The tools
  it assumes, Hammox and `docs/elixir.md` among them, come with a later release of the template:
  until a project has them, the skill says so and its review skills leave those rules out. They
  no longer tell a reviewer to keep a client looked up from configuration so tests can swap it.
  The generated AGENTS.md names the skill
  ([#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).

### Fixed

- A step of the development cycle that has a skill is done with it, invoked through the Skill tool,
  not recalled. DEVELOPMENT.md's cycle has a table of each step's skill, which says which skills
  only the user starts and that one the harness does not know is reported to the user, or stops a
  run that has none; AGENTS.md names the skills at the steps of its cycle that have one.
  `/ehos-app:pre-pr-review` names the skills each review invokes, has each open its report with
  them, sends back one that leaves one out, and lists them in the pull request's `## Review`, as the
  pull request template now asks; a project's template still as 0.15.0 to 0.21.0 wrote it is
  replaced ([#453](https://github.com/EmpoweredHouse/ehos-tools/issues/453)).
- `/ehos-app:pre-pr-review`'s second review applies the application's lenses from their checklist.
  It was sent to `ehos-app:review`, which only a user may start, so a reviewer refused it reviewed
  from memory. In the plugin's 0.3.0 both skills read the lenses, the findings' format and the
  severity rubric from one file, the reviewer is told to read it rather than invoke the skill, its
  report marks every checklist item of each lens it applies, and a report without those marks is
  sent back once, after which the author applies the lens and says so in the pull request
  ([#482](https://github.com/EmpoweredHouse/ehos-tools/issues/482)).
- A project's image builds again: `mix assets.setup` downloaded Tailwind's executable with Erlang's
  `:httpc`, which GitHub's release redirect refuses since 23 October 2026 (`{:header_too_long,
  {:max, 10240}}`). The Dockerfile now installs curl and fetches the executable for the target being
  built before that step, checked against the release's `sha256sums.txt` for a corrupted download,
  as [eh-os#973](https://github.com/EmpoweredHouse/eh-os/issues/973) did for EHOS's own image. An
  existing project's Dockerfile is given it when the installer runs again, if its build dependencies
  and `mix assets.setup` step are Phoenix's; otherwise the installer says what to add (#466).
- A project whose `ehos.yaml` reads the people or asks for mail, but declares no `sign_in`, no
  longer signs people in: `config/runtime.exs` signs people in where EHOS gives
  `EHOS_SIGN_IN_APPLICATIONS`, which it gives only with `sign_in`, instead of wherever it gives
  `EHOS_CLIENT_ID`, which it gives for the people and for mail too (#460). A project an earlier
  version made keeps its block, and is told the condition to change.

## [0.21.0] - 2026-10-24

### Changed

- **Breaking:** a project is pinned to eh-os-contract's release v0.10.0 instead of v0.9.1
  (`eh_os_contract` `~> 0.10.0`, `eh_os_contract_auth` `~> 0.7.0`), which writes `ehos.manifest/v7`
  for an `ehos.yaml/v6`, so an application can ask to send mail through EHOS, and brings
  `EhOsContract.Auth.Mail.deliver/1` to send it (eh-os D-140, eh-os#979). A project on v0.9.1's
  commit is moved when the installer runs again; one on a commit of its own keeps it. A project
  that reads the people with `EhOsContract.Auth.People` names its process
  `EhOsContract.Auth.Workload` where it named it, as eh_os_contract_auth 0.7.0's changelog says;
  nothing else asks a project to change.

### Added

- The generated ARCHITECTURE.md says how an application asks for mail in `ehos.yaml/v6`, what
  `internal` and `external` allow, who agrees per environment, how it sends with
  `EhOsContract.Auth.Mail.deliver/1`, and how it reads the answers that arrive at its reply domains
  (eh-os D-140, eh-os#979).

## [0.20.0] - 2026-10-23

### Changed

- **Breaking:** a project is pinned to eh-os-contract's release v0.9.1 instead of v0.9.0
  (`eh_os_contract` `~> 0.9.0`, `eh_os_contract_auth` `~> 0.6.0`), which writes `ehos.manifest/v6`
  for an `ehos.yaml/v5`, so an application can name the hosts outside the installation it reaches,
  and brings `EhOsContract.Auth.Egress`, the Req plugin that calls them through the proxy EHOS gives
  (eh-os D-135, #427). A project on v0.9.0's commit is moved when the installer runs again; one on
  a commit of its own keeps it. `eh_os_contract_auth` 0.6.0 requires Mint 1.11, and Mint 1.11 hpax
  1.1: a project whose `mix.lock` holds older ones runs `mix deps.update mint hpax` after
  `mix deps.get`. Nothing else asks a project to change.

### Added

- The generated ARCHITECTURE.md says what EHOS gives an application that names a host outside the
  installation (`EHOS_EGRESS_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, from EHOS 0.19.0), how a host is
  named in `ehos.yaml/v5` and called with `EhOsContract.Auth.Egress.attach/1`, and how a client
  other than Req is given the proxy (#427).

## [0.19.0] - 2026-10-22

### Changed

- **Breaking:** a project is pinned to eh-os-contract's release v0.9.0 instead of v0.7.0
  (`eh_os_contract` `~> 0.9.0`, `eh_os_contract_auth` `~> 0.5.0`), and its eh-os-contract plugin
  to 0.9.2. Nothing in them asks a project to change; a project on v0.7.0's commit is moved when
  the installer runs again, and one on a commit of its own keeps it.
- **Breaking:** a pull request's preview needs EHOS 0.18.0 or later where the project has a
  contract: it sends every graph document of the application, and an older EHOS refuses a
  contract's or a process module's. The workflow writes them all in one run with
  `mix eh_os_contract.graph --output-dir`, into `ehos.graph/` of the `ehos-deployment` artifact:
  the domain's, which the landscape of applications draws, and each contract's and process
  module's, which the console shows inside the application (eh-os D-134,
  [#402](https://github.com/EmpoweredHouse/ehos-tools/issues/402)). The preview and its removal
  install `ehosctl` 0.23.0 in place of 0.19.0, which sends up to 512 documents with a deployment.
  `DEVELOPMENT.md` passes each of them to a deployment by hand. A workflow 0.18.0 wrote, untouched
  since, is replaced when the installer runs again.

## [0.18.0] - 2026-10-22

### Changed

- **Breaking:** a deployment that sends graph documents needs EHOS 0.14.0 or later, which takes
  them; an older EHOS refuses it. That is a pull request's preview of a project with a contract,
  and the deployment by hand `DEVELOPMENT.md` shows, which leaves `--graph` out on an older one.
  The workflow writes the domain's graph document, `ehos.graph.json`, beside the manifest in
  `ehos-deployment`, wherever the project has a contract, and a pull request's preview sends it
  with its deployment, with `ehosctl` 0.19.0's `deploy --graph`, so that EHOS draws the
  application in its environment's landscape of applications (eh-os D-123,
  [#361](https://github.com/EmpoweredHouse/ehos-tools/issues/361)). The preview and its removal
  install `ehosctl` 0.19.0 in place of 0.13.0. `DEVELOPMENT.md` passes the document to a
  deployment by hand too. A workflow an earlier version wrote, untouched since, is replaced when
  the installer runs again.
- A merged pull request's preview is kept until it expires, eight hours after the last push, and
  the CI says so ([eh-os#672](https://github.com/EmpoweredHouse/eh-os/issues/672)): EHOS gives
  the merge's closing run, on the base branch, no credential to remove it. `preview-remove` no
  longer tries, which failed every merge's closing run, and, for a merge a person made, rewrites
  the preview's comment to say it was kept and expires. `DEVELOPMENT.md`'s "Previews of pull
  requests" says the same, and that a person can remove such a preview sooner with `ehosctl env
  remove`, where it said a merge may not remove it. A workflow 0.17.0 wrote, untouched since, is
  replaced when the installer runs again.

## [0.17.0] - 2026-10-19

### Changed

- A workflow 0.16.0 wrote, untouched since, is replaced with this release's when the installer
  runs again, so an existing project takes the `preview` and `preview-remove` changes below, and
  `preview-remove`'s new `pull-requests: write`, with it. A workflow the project changed is left
  as it is.

### Fixed

- `DEVELOPMENT.md`'s "Deploying" and "Who deploys, and joining the team" say that an application's
  first promotion, and any that changes its roles or capabilities, is approved by someone who also
  holds `ehos.application.register` in production, and have the administrator bind the process
  owner `ehos.registrar` there beside `ehos.process_owner`, before the first promotion; the role is
  EHOS's from 0.11.0
  ([eh-os D-119](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0119-approving-a-promotion-that-puts-another-authority-in-force-needs-the-right-to-register-it-and-it-waits-only-for-whoever-holds-both.md),
  [#297](https://github.com/EmpoweredHouse/ehos-tools/issues/297)). It said the process owner
  approves, which EHOS refuses for a first promotion without the second right.
- A closed pull request's preview comment says what became of the preview
  ([eh-os D-110](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0110-a-pipeline-deploys-as-its-application-s-deployment-identity-trusted-per-github-repository-exchanging-github-actions-token-for-a-credential-that-reaches-only-ephemeral-environments.md),
  [#295](https://github.com/EmpoweredHouse/ehos-tools/issues/295)), instead of linking an address
  nothing answers: the CI's `preview-remove` job rewrites the one comment `preview` keeps when the
  pull request closes, to say the preview was removed. Where the removal fails, as for a preview
  that already expired, and perhaps for a merged pull request's close
  ([eh-os#672](https://github.com/EmpoweredHouse/eh-os/issues/672)), it says the preview expires by
  itself. The job is given `pull-requests: write` for it.
- `DEVELOPMENT.md` downloads the `ehos-deployment` artifact into `_build/deploy`, which git
  ignores, as the golden path does, and removes an earlier download first: it used `deploy/`,
  which `git add .` would commit, and a second download refused to write over the first
  ([#295](https://github.com/EmpoweredHouse/ehos-tools/issues/295)).
- `DEVELOPMENT.md`'s "Previews of pull requests" says that a person registers the application once,
  with `ehosctl apps register` and the manifest `main` published, before trusting the repository:
  EHOS refuses `trust add` for an application it does not know, and a preview's credential cannot
  register one. It says too that this takes `ehos.application.register` on the platform, and sets
  the repository variables last. The `preview` job says the same when no installation is named
  ([#266](https://github.com/EmpoweredHouse/ehos-tools/issues/266)).

## [0.16.0] - 2026-10-17

### Added

- A project records every event's fields in `eh_os_contract.lock`, and `mix precommit` and CI run
  `mix eh_os_contract.schema --check`, so a change to an event that old rows would not read fails
  before it is merged, not on the deployed application's first old row
  ([#274](https://github.com/EmpoweredHouse/ehos-tools/issues/274)). The installer has the engine
  record a new project's lock once the files are written, so its first commit holds the example's
  events. A project that had the engine before, as one an earlier version made does, gets the
  check when the installer runs again, and is told to record the lock, `mix eh_os_contract.schema`,
  once it compiles and before any event changes. A lock the project has is never recorded over,
  and is always checked. A project with neither a lock nor a module under `lib/` that uses
  `EhOsContract.Contract` gets no check, and is told how to add it after its first contract. A
  project's `ci.yml` gets the new step when the installer runs again, while it is still what an
  earlier version, 0.15.0 included, wrote.
- A session ends when EHOS ends the person's sign-in: `config/runtime.exs` reads
  `EHOS_SIGN_IN_ABSOLUTE`, the installation's limit, as `sign_in: [absolute_limit:]` (eh-os D-113,
  `eh_os_contract_auth` 0.4.0); without it a session lasts twelve hours whatever the installation
  sets. A project an earlier version made is told the line to add.

### Changed

- **Breaking:** a project is pinned to eh-os-contract 0.7.0 instead of 0.6.0, with
  `eh_os_contract_auth` 0.4 instead of 0.3
  ([#274](https://github.com/EmpoweredHouse/ehos-tools/issues/274)).
  eh-os-contract's [0.6.1](https://github.com/EmpoweredHouse/eh-os-contract/releases/tag/v0.6.1)
  and [0.7.0](https://github.com/EmpoweredHouse/eh-os-contract/releases/tag/v0.7.0) say what
  changes: a duration longer than 100 years no longer compiles, a promise may name the systems it
  waits on, and every `graph.v1` process document's digest moves once. A project on 0.6.0's commit
  moves to 0.7.0's when the installer runs again. The `eh-os-contract` plugin the project enables
  moves from 0.8.0 to 0.9.0, whose skills write contracts as 0.7.0 compiles them.

## [0.15.0] - 2026-10-17

### Added

- A preview is seeded with data to try it on (eh-os D-98,
  [ehos-tools#244](https://github.com/EmpoweredHouse/ehos-tools/issues/244)). `ehos.yaml` is
  `ehos.yaml/v4` and names `needs.database.seed`: the release's `<App>.Seed.run/0`, which runs
  `priv/repo/seeds.exs` with the repo started, and which EHOS runs in an ephemeral environment
  only, at every start, with `EHOS_SEED_PROFILE` set to the template's seed profile; the module
  says what such a script may and may not do. An `ehos.yaml/v3` an earlier version wrote moves to
  v4 when the installer runs again, with the seed beside a one-line `migrate:` where it names
  none, and otherwise says how to add it.

- A pull request of the project's repository is previewed on EHOS with no stored secret (eh-os
  D-110, [ehos-tools#266](https://github.com/EmpoweredHouse/ehos-tools/issues/266)). CI publishes
  its image and manifest as `main`'s, and a new `preview` job deploys them to an ephemeral
  environment of its own, `<application>-pr-<number>`. It is made on the first push, extended by
  eight hours on each later one, and linked in one comment on the pull request. `preview-remove`
  removes it when the pull request closes. The job exchanges its own GitHub Actions token through
  `ehosctl` 0.13.0, at the installation the repository variables `EHOSCTL_URL` and
  `EHOSCTL_CA_PEM` name, and runs actions pinned by commit. Without the variables it passes and says
  how to set them, and nothing is pushed; a fork's and a bot's pull request get no preview.
  `DEVELOPMENT.md` says how a repository gets its trust, and a developer the capabilities and their
  GitHub account linked. A project an earlier version made gets the new workflow when the
  installer runs again, unless its `ci.yml` is its own.

- A review gate for the application, as ehos-tools, eh-os and eh-os-contract have
  ([ehos-tools#229](https://github.com/EmpoweredHouse/ehos-tools/issues/229)).
  `mix ehos_app.review record` marks the reviewed commit, in every worktree of the repository; a
  hook in `.claude/settings.json` runs `mix ehos_app.review gate` and refuses `gh pr create` from a
  commit without the mark; and a workflow of its own, `.github/workflows/review.yml`, fails a pull
  request whose description has no `## Review` section saying what the review found, which the
  pull request template now ends with. The `ehos-app` plugin's 0.2.0, which the installer pins,
  has the review an assistant can run itself, `/ehos-app:pre-pr-review`: two reviews in parallel,
  the application's lenses among them, every finding settled, then the mark. `AGENTS.md` and
  `DEVELOPMENT.md` ask for it before every pull request, and `/ehos-app:ship` opens its draft once
  the change is reviewed. A project an earlier version made gets the hook, the workflow and the
  template when the installer runs again; a pull request template of the project's own is left,
  with a notice when it has no `## Review` section.

### Changed

- `DEVELOPMENT.md`'s "Deploying" deploys a candidate to an ephemeral environment of the
  application and has its process owner promote it, since EHOS 0.9.0 refuses a deployment straight
  to production (eh-os D-105, `promotion_required`), where it deployed to `production` before
  (eh-os#594).
- **Breaking:** a project is pinned to eh-os-contract 0.6.0 instead of 0.3.0, and its
  `ehos.yaml/v4` produces `ehos.manifest/v4`, which only EHOS 0.9 and later deploy.
  eh-os-contract's [0.4.0](https://github.com/EmpoweredHouse/eh-os-contract/releases/tag/v0.4.0),
  [0.5.0](https://github.com/EmpoweredHouse/eh-os-contract/releases/tag/v0.5.0) and
  [0.6.0](https://github.com/EmpoweredHouse/eh-os-contract/releases/tag/v0.6.0) say what changes.
  The engine's tables move to version 4, through a migration the installer adds to a project an
  earlier version made. Every contract's version moves once, so read models are marked stale. A
  reference against the context map, an event above `schema_version: 1` without its upcasts, and
  a contract's own `process`, stage groups or `terminal:` no longer compile. A run is a module of
  its own, `use EhOsContract.Process`, as `docs/concepts/process.md` of eh-os-contract says. The
  example contract (`--example`) declares neither now; one an earlier version generated is the
  developer's to change, and the installer names such a file. The example's context is of a
  `:supporting` subdomain and publishes `:flagged` too, so `mix eh_os_contract.check` finds
  nothing in a new project. The `eh-os-contract` plugin the project enables moves from 0.1.0 to
  0.8.0, whose skills write contracts as 0.6.0 compiles them.

## [0.14.0] - 2026-10-15

### Security

- A crashed process's report carries less of what the process held, which whoever may read the
  application's logs in EHOS would read. Its last message and state are logged as their shape
  (`config :logger, translator_inspect_opts`), and `<App>.LogRedaction`, started first in
  `start/2`, logs a stack frame's arity in place of its arguments, such as a LiveView's assigns,
  the params of a `handle_event/3` clause that did not match, or a request's cookies in the error
  it ends in. A generated test checks each. An exception's own message is kept and may quote a
  value, a `MatchError`'s changeset for one. `AGENTS.md` and `DEVELOPMENT.md` say to log ids and
  kinds, never content (#234).
- The application serves HTTP/1.1 alone, on its endpoint and on its probes' listener: Bandit's
  HTTP/2 stack, which a pod beside it could reach without TLS, is off. A trickle of WINDOW_UPDATE
  frames could pin its stream processes (EEF-CVE-2026-105659), for which Bandit has no fixed
  release yet. A project an earlier version made gets the endpoint's setting when the installer runs
  again; its `health.ex` is its own, so it adds `http_2_options: [enabled: false]` there by hand
  (eh-os#492, #239).

## [0.13.0] - 2026-10-14

### Added

- The application logs one JSON object a line in production, as EHOS does (`logger_json`'s
  Elastic formatter), with `request_id`, the trace and span ids and the business work's
  `correlation_id` as fields, so EHOS's console and `ehosctl logs` show its level and fields. Its
  traces go over OTLP to the collector EHOS names in `OTEL_EXPORTER_OTLP_ENDPOINT`, and nowhere
  when it names none, as on a laptop and in CI: `opentelemetry` with its exporter, and the
  instrumentation of Bandit, Phoenix and Ecto, set up at the top of `start/2`. The SDK starts
  `:temporary`, so the application serves on if it stops. A request's trace never continues one a
  caller sent, and the value of a field named exactly `password`, `secret`, `token`,
  `authorization` or `cookie` is replaced with `"[REDACTED]"`. A project with `opentelemetry`, or
  a formatter or `logger_json`, of its own keeps that part as it is, and is told what to set for
  EHOS; one an earlier version made gets what it lacks. `DEVELOPMENT.md` says how to read the
  logs (eh-os#485, #228).

## [0.12.0] - 2026-10-13

### Added

- The generated `DEVELOPMENT.md` says who deploys and how a developer joins, in "Who deploys,
  and joining the team": what the operator holds and what a developer who deploys needs, which is
  no cloud key but an EHOS account with `ehos.application_administrator` for the application and
  the installation's CA; the operator's four steps to let them in, the developer's by the golden
  path, and what to do when someone leaves. In a new project, the notes the application keeps
  below it also ask for the installation it runs on and its addresses; an existing project's notes
  are its own, and stay as they are.

## [0.11.0] - 2026-10-13

### Added

- The application opens on a home page of its own instead of Phoenix's welcome page: its name,
  that it runs on EHOS and what that means for the people who open it, and a link to `/access`.
  The Sign in button at the top of every page stays where 0.5 put it (#198).
- `/access`, behind `:signed_in`, shows the signed-in person the opaque subject EHOS gives them,
  each capability the contracts declare, the roles that grant it and whether their sign-in does,
  or that it grants nothing here. A visitor who opens it is sent to sign in through EHOS and
  back. It is `<App>Web.AccessController` and `<App>Web.AccessHTML`, routed in a
  `scope "/access"` of its own, with their test. Phoenix's `page_controller_test.exs` is
  replaced with one of the new home page while it is still Phoenix's; one the developer changed
  that still looks for Phoenix's tagline gets a notice.
- Both pages are written only while the home page is still Phoenix 1.8.14's welcome page, byte for
  byte, as `phx.new` wrote it for `ehosctl init`: in a new project, and in one from an earlier
  version whose home page nobody changed, on the run that moves it to this version. A home page
  the developer changed is left as it is, with no access page; to have it, copy
  `AccessController`, `AccessHTML`, their test and the `scope "/access"` from a project
  `ehosctl init` makes, and link `/access` from the home page. A project with an
  `AccessController`, an `AccessHTML` or a route at `/access` of its own keeps Phoenix's page,
  with a notice, and so does one whose page still carries Phoenix's tagline but is not that page.
  Once replaced, a later run changes neither page, and an access page the developer removed is
  not brought back.
- Recording an entry from a form on that page is not part of it: the web layer's rule still
  admits commands only behind `EhOsContract.Auth.Plug`
  ([#68](https://github.com/EmpoweredHouse/ehos-tools/issues/68)).

### Changed

- The root layout's title names the application alone: the installer removes the
  ` · Phoenix Framework` suffix Phoenix writes, in a new project and in one from an earlier
  version; a suffix of the application's own stays.

## [0.10.0] - 2026-10-12

### Changed

- `.claude/settings.json` enables the `ehos-app` plugin from a marketplace of its own name,
  `ehos-app`, which ehos-tools publishes from `.claude-plugin/ehos-app.json`, at the tag
  `ehos-app-v0.1.1`. 0.9 named it `ehos-tools`, as eh-os, ehos-tools and eh-os-contract name theirs
  at another tag, and Claude Code keeps one copy of a marketplace per name, so a developer working
  on both moved that copy back and forth. The installer renames the marketplace 0.9 wrote, in its
  place, and `ehos-app@ehos-tools` with it, or, where another plugin is enabled from it, keeps it
  for that plugin and moves `ehos-app`'s entry alone; where the template's `ehos-app` is already
  there, the old one goes. An `ehos-tools` marketplace of the developer's, on another repository or
  `ref`, stays: `ehos-app@ehos-app` is added turned off where the plugin is enabled from it, with a
  notice, and stays off where it was off there.

### Fixed

- An `ARCHITECTURE.md` or `TESTING.md` still word for word as 0.3.0 to 0.8.1 wrote it for the
  project, or with 0.9's section on top of that text, is replaced by the one a new project gets,
  rather than given the new section on top of the old text and a notice to delete it. A file the
  developer changed keeps its text, under the section.
- `.claude/settings.json` that already enables both plugins is left as it is, however it is laid
  out. One the installer adds to keeps its indent, its line ends and its last newline.
- In an `ehos.yaml` 0.2.0 to 0.8.1 wrote, the comment naming the `.ehos/` copy of the schema points
  at the dependency's copy with CRLF line ends too, also where 0.9 already removed the copy, and
  once no copy is left the header comment that described one becomes the one this version writes. A
  schema comment the installer cannot rewrite gets a warning naming the file to point it at, on
  every run while it names a copy that is gone, rather than being left silently.
- When the installer writes `AGENTS.md` again for a project whose file held its section alone, it
  keeps the sentence about the example as long as the example's contract and its implementation are
  there, with or without `--example`.
- `DEVELOPMENT.md`, `ARCHITECTURE.md` and the web layer's `AGENTS.md` no longer say `app.css`
  imports the design system when the installer could not add the import, and `DEVELOPMENT.md` no
  longer says CI reads `ehos_design` when the project has removed the dependency.

## [0.9.1] - 2026-10-12

### Fixed

- In a project 0.3.0 to 0.8.1 generated, the installer removes `elixir-anti-patterns-review`'s
  `LICENSE` from `.agents/skills/` too, and with it the skill's link: the file was released with no
  newline at its end and written into the project with one, so 0.9.0 took it for the developer's
  and kept it. Found moving TaxVision to 0.9.0.

## [0.9.0] - 2026-10-12

### Added

- `.claude/settings.json` also enables the `eh-os-contract` plugin, from eh-os-contract's
  marketplace at the tag `eh-os-contract-plugin-v0.1.0`: the skills for writing contracts,
  `/eh-os-contract:module-boundary-check`, `:contract-distillation`, `:add-event`,
  `:change-contract`, `:write-decider` and `:write-reaction`. `DEVELOPMENT.md`'s cycle, `AGENTS.md`
  and the contracts' `AGENTS.md` name them at the step each serves. A project's own settings keep
  their keys and order, and a marketplace `eh-os-contract` on another `ref` stays, with a notice.
- A new project gets a `LICENSE`, the Apache License 2.0 in the name of Empowered House PSA, as
  ehos-tools and eh-os-contract are licensed, and its `README.md` points to it; the installer says to
  change it when the application belongs to someone else. A project with a `LICENSE` of its own
  keeps it, and one generated earlier without any gets none from an upgrade. `ehos_app` itself is
  licensed under Apache-2.0.
- `DEVELOPMENT.md`, a section the installer keeps current: the development cycle, contract first
  (find what a change does to the contract, change the contract and its scenarios, check it with
  `mix eh_os_contract.check` and the scenarios, then implement), and how the application is run
  locally, built by CI, deployed with `ehosctl deploy --preview` and `ehosctl deploy`, given to
  people with `ehosctl role-bindings bind`, and kept current with `ehosctl versions`. The commands
  name the application as EHOS does.
- The contracts' `AGENTS.md` says that a change starts there, and what a change to a deployed
  contract does to the events already stored. The `ehos-app` plugin's `plan` and `ship` make the
  contract the first phase of a change that touches one.

### Changed

- **Breaking:** the skills `plan`, `ship`, `review` and `elixir-anti-patterns-review` are the
  [`ehos-app`](https://github.com/EmpoweredHouse/ehos-tools/tree/main/plugins/ehos-app) Claude Code
  plugin's, which the installer enables in `.claude/settings.json` from ehos-tools' marketplace at
  the tag `ehos-app-v0.1.0`, instead of copies in `.agents/skills/` linked from `.claude/skills/`
  ([T-15](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md)).
  They are called `/ehos-app:plan`, `/ehos-app:ship`, `/ehos-app:review` and
  `/ehos-app:elixir-anti-patterns-review`, and a later `ehos_app` moves the plugin's tag. Claude
  Code installs the plugin once the folder is trusted, with the machine's git credentials for
  GitHub: without an SSH key, set `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` and run
  `gh auth setup-git`. Agents other than Claude Code no longer get the skills.
- A `.claude/settings.json` of the project's own keeps its keys and their order: the installer
  adds the marketplace and the plugin, moves a marketplace on an earlier `ehos-app-v*` tag, and
  leaves any other `ref` and a plugin turned off as they are, with a notice.
- `README.md`'s section says how to start the application, the everyday commands (`mix
  precommit`, `ehosctl verify`, `mix eh_os_contract.view`, `ehosctl deploy`, `ehosctl versions`)
  and what to read next; `VISION.md`'s section is shorter, and `AGENTS.md`'s says how a change is
  made, contract first.
- `ARCHITECTURE.md` and `TESTING.md` hold a section the installer keeps current, what every EHOS
  application shares, above the application's own parts, instead of being written once: an
  upgrade reaches them. `ARCHITECTURE.md` says what `assets/` is beside the design system, and
  `TESTING.md` how a contract is tested, by its scenarios, its properties and its commands. A file
  an earlier version wrote gets the section on top, and the installer says that the parts below
  it which repeat it, or name the `.ehos/` copy and `.agents/skills/`, can be deleted.
- The generated `test/harness_test.exs` holds `DEVELOPMENT.md` to 400 lines, checks no skill
  links, and holds a skill of the project's own in `.claude/skills/` to the line budget.
- **Breaking:** a new project's `ehos.yaml` is `ehos.yaml/v3`, the newest version EHOS defines,
  which adds `needs.people` to v2 (eh-os D-81), and `release.json` says this `ehos_app` produces
  `ehos.yaml/v3`, which EHOS accepts since 0.4.0. A project generated earlier keeps the
  version its `ehos.yaml` is in, since the file is the developer's: to move, change `schema:` to
  `ehos.yaml/v3` and the version in the comment above it.
- `ehos.yaml`'s comment points editors at EHOS's schema where `eh_os_contract_auth` carries it,
  `deps/eh_os_contract_auth/packages/eh_os_contract_auth/priv/schemas/ehos.yaml/v3.json`, the one
  `mix eh_os_contract.manifest` checks the file against, instead of a copy in `.ehos/`. A version
  EHOS adds later arrives with the eh-os-contract release that carries it. The managed sections
  no longer name a schema file, which fixes
  [#55](https://github.com/EmpoweredHouse/ehos-tools/issues/55).

### Removed

- In a project 0.3.0 to 0.8.1 generated, the installer removes the skills they copied into
  `.agents/skills/` while each file is still as a release wrote it, then runs the new task
  `mix ehos_app.unlink_skills`, which removes the links in `.claude/skills/` left pointing at them
  and the directories left empty. A copy that was changed stays, and the installer names it. The
  task `mix ehos_app.link_skills` is gone.
- In a project 0.2.0 to 0.8.1 generated, the installer removes the copy of EHOS's schema they wrote
  into `.ehos/` while it is still EHOS's, and points the comment in `ehos.yaml` that named it at
  the same version in `deps/`. A copy that was changed stays, and so does its comment.

## [0.8.1] - 2026-10-12

### Fixed

- With `--example`, the domain's context `:entries` has a glossary, terms "Entry" and "Amount", so
  a new project's first `mix eh_os_contract.check` says 0 errors, 0 warnings, 0 notices instead of
  a `word-without-term` notice; and the example contract says that `entry_id` is the caller's to
  give, since `record_entry` refuses a call without it, and that it should be a fresh one
  ([#125](https://github.com/EmpoweredHouse/ehos-tools/issues/125)). Both files are the
  developer's once written, so running the installer again leaves an earlier project's as they
  are. To clear the notice there, give the context `:entries` in `lib/<app>/domain.ex` a block with
  the two terms as the template writes them; a term without its `definition:` does not compile:

  ```elixir
  context :entries, "Entries", subdomain: :core do
    term "Entry", definition: "An amount a clerk records, which an auditor may flag"
    term "Amount", definition: "What an entry records, a whole number"
  end
  ```

## [0.8.0] - 2026-10-11

### Changed

- **Breaking:** the workflow's check job runs `ehosctl verify`, the command a developer runs,
  instead of listing the gates itself. mise installs `ehosctl` 0.3.0 from its release, before any
  dependency's code runs, with a token of the CI App that reads ehos-tools alone, and the binary
  runs only if its SHA-256 is the one 0.3.0 published. The token needs the App's *Attestations:
  read* besides *Contents: read*, since mise asks for a release's attestations: an organisation
  owner adds it to the App before a project takes this workflow, or its check job fails at the
  token step; EmpoweredHouse's App has it since 11 October 2026. The dependencies are still fetched in a step of their own, and the manifest is
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

# Contributing to ehos-tools

People will judge this repository without having been in the room when it was built. Every rule
below exists so they can trust what they read: the code, the tests, and the reasons behind both. The
rules apply equally to people and to agents.

## Language

Everything is in English: code, identifiers, comments, commit messages, pull requests and
documentation.

## Where things are

| Path | What |
| --- | --- |
| `packages/ehosctl/` | the CLI, a Mix project released as Burrito binaries |
| `packages/ehos_app/` | the template, a Mix project with an Igniter installer |
| `packages/ehos_design/` | the EmpoweredHouse design system, a Mix project of CSS and fonts: the template's default look, and the one the EHOS console and `eh_os_contract`'s dashboard move to |
| `packages/review/` | the review gate, a Mix project never released: `mix review record` marks a reviewed commit, a Claude Code hook refuses `gh pr create` without the mark, and `mix review pull_request` checks in CI that a pull request's description records its review. The gate is `ehos_app`'s `EhosApp.Review`, the one every application has, which it depends on by path |
| `.claude/skills/`, `.claude/review.md` | skills for Claude Code: `sync-design-system` refreshes `ehos_design`'s tokens and components' stylesheets from Claude Design. `.claude/review.md` is this repository's part of `ehos-dev:pre-pr-review` |
| `plugins/ehos-app/`, `.claude-plugin/ehos-app.json` | `ehos-app`, the plugin every application `ehos_app` generates enables in its `.claude/settings.json`, at the tag `Mix.Tasks.EhosApp.Install` pins ([T-15](docs/adr/0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md)), from the marketplace `ehos-app` that `.claude-plugin/ehos-app.json` declares, a name of its own beside `ehos-tools` ([T-16](docs/adr/0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md)): `plan`, `ship`, `pre-pr-review`, `review`, `elixir` and `elixir-anti-patterns-review`, for working on an application. Released by a tag `ehos-app-vX.Y.Z` ("Versions and releases") |
| `plugins/ehos-dev/`, `.claude-plugin/` | `ehos-dev`, a Claude Code plugin in this repository's marketplace, with the skills eh-os, ehos-tools and eh-os-contract share: `release` says how a changelog line is written and a component released, `stage-issue` how a planned piece of work is run through a GitHub issue, `pre-pr-review` how a change is reviewed before its pull request, `write-adr` how a decision record is written in eh-os and here, not in eh-os-contract, which keeps dated amendments instead, `architecture` how eh-os's architecture pages are kept current with a change in any of the three. All three enable it in `.claude/settings.json`, and Claude Code offers to install it from GitHub, at the tag their `ref` names, once the folder is trusted; a change to it is released by a tag `ehos-dev-vX.Y.Z` ("Versions and releases"). A machine without a GitHub SSH key sets `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` and stores a credential with `gh auth setup-git` |
| `packaging/homebrew/` | the draft Homebrew formula, published to a tap once the repository is public |
| `docs/` | why the stack is what it is (`research.md`), where the work stands (`spike.md`), and the decisions since (`adr/`, numbered `T-xx`) |

Each package builds, tests and versions on its own. Nothing at the root is a Mix project.

## Where the work is recorded

ehos-tools has no roadmap or plan of its own: its work is planned in EHOS's stages, in eh-os's
[ROADMAP.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ROADMAP.md) and the stage's plan
in [docs/plans/](https://github.com/EmpoweredHouse/eh-os/tree/main/docs/plans). A step's status
lives in that plan's "Status / handoff" table, and nowhere here.

| Place | The question it answers | When it changes |
| --- | --- | --- |
| An eh-os stage's plan | Where is the stage, and which step is next? | When a step starts or ends, in eh-os |
| The eh-os step's issue | Why was the step done this way? Its decisions, for every repository it touches | While the step goes on |
| A GitHub issue here | What does this repository do for the step, or what did a review leave? In short for anyone, then the technical detail, scope, done when | While the work goes on; closed by the pull request that says `Closes #N` |
| `docs/adr/` (`T-xx`) | Why is ehos-tools built this way? A decision past the threshold in "Commits and pull requests" | When such a decision is made |
| A pull request | What changed in the code, how it was tested, what the review found | Once, when it is opened and as review comments are settled |
| A package's `CHANGELOG.md` | What changed for its user, version by version | In the pull request that changes what they see |

An issue here is one of three kinds. **The part of an eh-os step** that this repository does: its
first line names the step, "Part of EmpoweredHouse/eh-os#385 (Stage 7, step 15), which holds the
decisions". **A follow-up**, labelled `follow-up`: what a review here left, or a problem found while doing other work. **An issue of its own**,
outside any step, such as a change to how the three repositories work together. There are no
milestones or issue templates here; a step's issues here are linked from the eh-os step's issue.

## From an issue to `main`

1. **The step in eh-os's plan** says what it changes, this repository's part included. A part that
   needs more than the step's few lines gets an issue here, opened when the work starts.
2. **A branch** `stage-<n>/<issue>-<short-name>` for a step's part (`stage-7/110-agreements`),
   `issue-<issue>/<short-name>` for an issue of its own, and `release/<component>-X.Y.Z` for a
   release and for the move to the next `-dev` after it. Branches before 12 October 2026 also used
   the eh-os step's number (`stage-7/15-template-verify`).
3. **Commit subjects end with the issue**: `… (#110)` for an issue here, `… (eh-os#385)` when the
   only issue is eh-os's.
4. **Decisions go on the issue that holds them when they are made**: the eh-os step's, for a step's
   part; this repository's, for an issue of its own. One past the threshold gets its `T-xx` record
   first (`ehos-dev:write-adr`), or, when it is about EHOS itself, eh-os's `D-xx`.
5. **A pull request** whose first line is `Closes #N` on the one that finishes an issue here,
   `Part of #N` on earlier ones, and the eh-os step it belongs to:
   "Closes #110. Part of EmpoweredHouse/eh-os#371 (Stage 7, step 14)." A change that needs no issue
   says `No issue: <why>`.
6. **Before it is opened**, the author reviews it ("Commits and pull requests").
7. **When it is merged**, the issue gets a closing comment: what changed for a developer or an
   application, what showed it, what was left and where. The eh-os step's plan gets its ☑ in eh-os.
8. **When the eh-os stage closes**, nothing is written here: its evidence record, in eh-os, cites
   this repository's pull requests and runs from the issues' closing comments.

The `ehos-dev:stage-issue` skill is the same procedure for an assistant, with how an issue is
written; it reads this section and the one before it for what is this repository's.

## Code

- **Formatting.** `mix format` is the style. Formatting is not discussed in review.
- **Warnings.** Compile with warnings as errors. A warning is a failure, not a note.
- **Docs.** Every public module has a `@moduledoc`, and every public function a `@doc` and a `@spec`.
  Internal modules say `@moduledoc false` on purpose. A `@doc` says what the function does for its
  caller, what it returns and how it fails, with an example where one helps (doctests run). In
  `ehosctl`, `Ehosctl.DocsTest` fails on a public function without both, and the gate builds the
  ExDoc reference with warnings as errors. Every `@callback` has a `@doc` too: what the operation
  does, what it returns and how it fails.
- **Comments.** A comment says *why*, where the code cannot. This matters most for anything shaped
  by a limitation found elsewhere, such as a Burrito launcher detail, an Igniter spec limitation or
  a migration ordering. Name the limitation, so the next reader can check whether it still holds.
  No section comments (`# --- Helpers ---`): a module that needs sections is too big, or its
  private functions should read top-down. No dead code: a function whose last caller goes, goes
  with it.
- **Libraries.** Use the standard, community-proven library or tool for a job instead of writing
  one. Look for it first (hex.pm, the tool's documentation, the Elixir forum) and check its current
  version rather than relying on memory. Anything hand-rolled says in the pull request why no
  existing library fits.
- **Behaviour-driven**
  ([T-20](docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)).
  A way out (a program, the network, the process environment, the keychain, the terminal, and the
  clock or randomness where a test must say what they return), and any module whose callers'
  tests should not run it, is a behaviour `X`, with a `@doc` on each `@callback`, and its
  implementation `XImpl` in the same file; callers name `X`, never `XImpl`. A pure module (a
  parser, a calculation) gets none, and a path stays a parameter (`dir:`, a test's `tmp_dir`).
  - **Choosing the implementation.** `ehosctl` chooses it at compile time, in its `config/`:
    `X.current/0` reads `Application.compile_env!/2`, with no default in code, so a behaviour whose
    `config/test.exs` line is missing fails to compile rather than reaching the real keychain or
    installation from a test. Nothing chooses one at run time from the environment. A library
    (`ehos_platform`, `ehos_app`, `ehos_design`) takes it as a module in the call's `opts`,
    defaulting to `XImpl`, since its configuration is its consumer's; the module is named in
    code, never built from input or the environment.
  - **Mocks** are Hammox's, a test-only dependency, declared in the test helper or
    `test/support/`, never under `lib/`, so a release cannot hold one. Hammox checks each call
    and answer against the callbacks' types, and `Hammox.Protect` holds `XImpl` to `X` in its own
    test. Its errors print the arguments, so a test passes fixture credentials, never real ones.
  - No test hook in production code: a canned answer, a process to notify, a delay read from
    configuration. A test never changes `Application` env or the process environment to swap an
    implementation; configuration a library reads the same way everywhere (`:floki`,
    `phoenix_test`'s base URL) is not such a swap.
  - An option that stays in `opts` (a library's implementation, data such as `:installation` or
    `:ca`) is followed to every call it must reach: a `Keyword.take/2` on the way drops it
    (`.claude/review.md`).
  - The environment and credentials stay out of `opts` that a `fetch!` could print: `ehosctl`
    prints an exception's message, and a `KeyError`'s holds the whole list it searched. Read the
    keys you need through the environment's behaviour, and pass a credential to the request that
    sends it.
  - **Code written before this rule** moves to it area by area, each area in a pull request of its
    own; until its area moves, it is not a finding, even in a change that touches it. It includes
    more than a dozen functions in `ehosctl`'s `opts` (`runner:` in `Ehosctl.Init` and
    `Ehosctl.Verify`, `:now` in `Ehosctl.Notice`, `:sleep`, `:ask`, `:confirm`, `:open_browser`,
    `:find_executable`, `:print`, `:progress`), the whole environment as `env:` in the `opts`
    `Ehosctl.HTTP` takes, `Config.dir(env \\ System.get_env())`, the clock read directly in
    `Ehosctl.Credentials`, `System.cmd` in `Ehosctl.TokenStore`, `ehos_platform`'s functions in
    `opts` (`:progress`, `:sleep`, `:detect_address`) and its Mox mock of `CommandRunner`, whose
    implementation lives in a file of its own, and a test that sets the process environment.
- **Flat control flow.** No `case` or `with` inside another: the inner one becomes a function named
  for what it decides, or multi-clause heads. A `with` has no `else` when each step answers its own
  failure, multi-clause heads beat `if` and `cond` on an argument's shape, and the result of an `if`
  is bound, never a variable rebound inside it. A key added to a map only when its value is not
  `nil` goes through `maybe_put/3`, private to the module that needs it and skipping `nil` alone,
  which keeps a pipeline flat; any other condition is an `if` at the call site. Code that predates
  the rule is flattened package by package; until its package is, flatten the function you change.
- **Moduledocs and comments cite what outlives the work**: an issue, an eh-os decision or a
  `T-xx` record. Name an issue with its repository (`ehos-tools#505`, `eh-os#355`), since
  ehos_platform's code is read from eh-os too, where a bare `#505` means another issue. A
  template's rule for applications allows a platform decision but no task id, since their task
  ids live outside their repositories; here, the issues are the record ("Where the work is
  recorded"). A plan's language never: no "phase 2", "for now", "TODO from the plan".
- **Entry points.** Mix is the only entry point: aliases and Mix tasks, written in Elixir and tested
  like the rest. No Makefile, no shell scripts.
- **Paths.** Nothing committed refers to a local path. Other repositories are linked by their
  GitHub URL.

## The template

- **Idempotent.** Running the installer twice changes nothing, and a test pins it.
- **Compose.** A dependency that ships its own installer is installed through it (Oban is). Its
  config is not copied here.
- **Intent, never infrastructure.** What the template writes about EHOS follows the EHOS
  specification. `ehos.yaml` states what an application needs, never how it is provided. Anything
  EHOS has not decided yet is marked as a guess in the generated file and listed in `docs/spike.md`.
- **Upgrades.** A project from an earlier version is brought along by running the installer again
  ([T-02](docs/adr/0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)). A
  change to what an existing project should have works on one an earlier version made, and has a
  test that starts from such a project. `mix igniter.upgrade ehos_app` runs no step of its own.

## Tests

- **Behaviour, not implementation.** A test name reads as a statement of what the tool does, and
  a test compares the whole value a function returns with `==` where it can be known, so a field
  changed by mistake fails it. A generated file is asserted on the lines the test is about. A
  test module is named after the module it tests, never `*Impl`, and no test name says "impl" or
  how the code works.
- **Layout.** In each `describe`, the case that succeeds comes first, then the failures. A mock's
  expectation lives in a `mock_<function>` helper, and helpers at the bottom of the file, below the
  last test.
- **Mocks** are Hammox's, as "Behaviour-driven" says: `expect` for the call a test is about,
  `stub` only for one it does not count. A test is `async` unless it shares a process it does not
  start. Tests written before these rules move with their area, as code does.
- **Installer tests** run on `Igniter.Test.phx_test_project/1` and assert the files and patches it
  produces.
- **CLI tests** replace the command runner and read the steps a command would run. No test starts
  mise, Mix or the network.
- **Beyond the suite.** An end-to-end run, from the binary to a generated project passing
  `mix precommit`, is how a change to `ehosctl` or `ehos_app` is verified. `AGENTS.md` has the commands.
  Its result goes into the pull request.
- **Flakiness.** A flaky test is a failing test.

## The gate

`mix check`, in each package:

- the formatting check;
- compilation with warnings as errors;
- the tests;
- in `ehosctl`, the documentation, built with ExDoc with warnings as errors.

It passes before every commit and every pull request. Check its own exit code, not the exit code of
a pipe after it.

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every pull request and on every `v*`
tag, and on a push to `main` only when a `mix.lock` or a `.tool-versions` changes, to save the
caches pull requests restore. A pull request checks only the packages it touches, and trying the
binaries end to end waits for a tag, because the macOS runners cost ten times as much as Linux
ones ([T-04](docs/adr/0004-ci-runs-only-what-a-change-or-a-release-needs.md)). A pull request
that changes what goes into a binary (`packages/ehosctl`'s `lib/`, `config/`, `rel/`, `mix.exs`,
`mix.lock` or `.tool-versions`, or `ci.yml`) builds them, on Linux alone. To try them end to end on a
branch before a tag, start CI by hand, which takes write access to the repository:
`gh workflow run CI --ref <branch>`, or "Run workflow" in the Actions tab. Do it for a change to
how `init` runs or to what the template generates. Started on `main`, the run also shows what a
release of that commit would publish (`release`, below). Each job proves one thing:

| Job | Proves |
| --- | --- |
| `changes` | nothing: it lists the packages a pull request touches, counting the files outside a package that its tests read (the list is in `ci.yml`). Anything but a pull request lists all four |
| `check` | `mix check` passes in every package `changes` lists, under each package's own `.tool-versions`. For `ehos_design`, with Node and the Chromium Playwright installs (`mix browser.setup`), for its browser test |
| `build` | on a `v*` tag, a run started by hand, or a pull request that changes what goes into a binary: Linux builds all four binaries in one job (Burrito cross-compiles with Zig, macOS included), and `mix ehosctl.release_file` writes their `release.json` |
| `e2e` | after `build`, on a `v*` tag or a run started by hand only: on macOS arm64, macOS x64, Linux x64 and Linux arm64, the binary built for it runs `ehosctl init shop` with only mise installed, and the generated project passes `mix ecto.setup` and `mix precommit` against PostgreSQL |
| `release` | on a pushed `v*` tag, or a run started by hand on `main`: the commit is on `main`, the binaries and `release.json` are its, and `packages/ehosctl/CHANGELOG.md` has a section for it that is not empty. On a tag, also that the tag is of the form `vX.Y.Z`, names the run's commit and is the version the binaries were built as, and the section is that version's; on `main`, the section is `## [Unreleased]`, or the version's own when it has no `-dev`, as on a release's merged pull request. It writes the notes and `release.json` into its summary, with a read-only token |
| `publish` | on a pushed `v*` tag only, in the environment `release`: the binaries, `SHA256SUMS` and `release.json` are published as a GitHub release whose notes are the section `release` took, marked latest when it is the highest `v*` version. The one job whose token may write to the repository, and it compiles and runs nothing |
| `install` | after `publish`: on each of the four platforms, `mise use -g github:EmpoweredHouse/ehos-tools@<version>` installs that release and `ehosctl --version` prints it |

[`.github/workflows/review.yml`](.github/workflows/review.yml) runs one more job on every pull
request, and again whenever its description is edited, so that an edit does not run the whole of
CI:

| Job | Proves |
| --- | --- |
| `review section` | the description has a `## Review` section with something in it ([T-03](docs/adr/0003-ci-checks-that-a-pull-request-records-its-authors-review.md)); re-running a failed run reads the description it had, so edit the description instead |

[`.github/workflows/changelog.yml`](.github/workflows/changelog.yml) does the same for the
changelog, on every pull request and every edit of its description:

| Job | Proves |
| --- | --- |
| `changelog` | for each of `ehosctl`, `ehos_app` and `ehos_design` whose shipped code the pull request changes (for `ehosctl`, what goes into the binary, as `build` reads it: its `lib/`, `config/`, `rel/`, `mix.exs`, `mix.lock` and `.tool-versions`, and the files of `ehos_design` its sign-in page inlines; for the others, their `lib/`, `priv/` and `mix.exs`), its `CHANGELOG.md` changes too, or the description has a line `No changelog: <why>`; every package without one is named |

[`.github/workflows/release-package.yml`](.github/workflows/release-package.yml) releases
`ehos_app` and `ehos_design`, on a tag `ehos_app-v*` or `ehos_design-v*`, or started by hand with a
package and a commit or branch of `main` (`-f package=ehos_app -f ref=main`):

| Job | Proves |
| --- | --- |
| `Prepare` | the commit is on `main`, and `mix <package>.release_file` writes its `release.json`; the package's `CHANGELOG.md` has a section that is not empty, the tag's version's on a tag, and otherwise `## [Unreleased]` (or the version's own when it has no `-dev`). On a tag, also that the tag names the run's commit and is the version in the package's `mix.exs`. It writes the notes and `release.json` into its summary, with a read-only token |
| `Publish` | on a tag only, in the environment `release`: the GitHub release, never marked latest, with the section as its notes and `release.json`. The one job whose token may write, and it runs nothing but `gh` |

`e2e` fetches `eh_os_contract` and `ehos_design` from GitHub, from `eh-os-contract` and from this
repository, and both are private. A GitHub App, *ehos-tools CI*, installed on both with read
access to their contents, mints a token for the one step that runs `init`, and that token can read
nothing else. Git gets it through `GIT_CONFIG_*` variables on that step, so it is not
written to `~/.gitconfig` and no later step sees it. The App's ID and private key are the
repository secrets `EHOS_CI_APP_ID` and `EHOS_CI_APP_PRIVATE_KEY`. A run started by hand gets the
secrets, which is one reason only people with write access can start one. Once both repositories
are public, the token step and the two secrets can go. `e2e` caches only Hex's downloads: Erlang, Elixir and the generator's archives are
installed from nothing on every run, because that is what a developer's first `init` does.
Every job has a `timeout-minutes`; raise it in `ci.yml` if a job legitimately grows past it.

## Commits and pull requests

- A commit message is a short imperative sentence that says what changes for a reader, with a body
  explaining why when that is not obvious.
- One logical change per pull request. The description says what changed, why, and how it was
  tested.
- **Reviewed by its author first.** Before a pull request is opened, its change goes through two
  reviews, one for correctness and one for security and performance, and what they find is fixed,
  answered or filed as a `follow-up` issue (the `ehos-dev:pre-pr-review` skill, with this
  repository's part in `.claude/review.md`). The pull request
  lists the findings and what became of each. `mix review record`, in `packages/review`, marks the
  reviewed commit; a Claude Code hook (`.claude/settings.json`) refuses `gh pr create` from a
  commit without the mark, and any new commit needs a new review. The description's `## Review`
  section (the pull request template has it) says what the reviews found, or that the change is
  documentation alone. Where the pull request lands, CI's `review section` check fails while
  that section is missing or holds nothing but comments, code and Markdown's structure; what it
  says is for whoever reads the pull request to judge.
- **Decisions are recorded.** A choice that would cost more than a day to reverse, or where a
  reasonable engineer could have chosen differently, gets a record in `docs/adr/` before the code
  that depends on it merges (the `ehos-dev:write-adr` skill, with this repository's part in
  `docs/adr/README.md`). A decision about EHOS itself is EHOS's,
  in [eh-os](https://github.com/EmpoweredHouse/eh-os/tree/main/docs/adr).
- `main` is always releasable. Work happens on branches.

## Versions and releases

eh-os, ehos-tools and eh-os-contract release the same way, as eh-os's
[D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md)
decided and [releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)
describes. The `ehos-dev:release` skill says how to apply it.

- **Versions.** `ehosctl`, `ehos_app` and `ehos_design` each follow
  [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, any minor version may
  break what the one before it offered. Between releases a package's version is the next minor's
  `-dev`: `0.3.0-dev` after `0.2.0`. Only a release's pull request sets a plain version, and only
  the pull request after its tag moves to the next `-dev`: a feature's pull request never changes
  a version. `packages/review` is never released.
- **A line for every change a user can see.** It goes under `## [Unreleased]` in the package's
  `CHANGELOG.md`, in the pull request that makes the change. A pull request without one says why
  on a line of its description, `No changelog: <why>`, and the `changelog` check fails it
  otherwise. A user of `ehosctl` sees what goes into its binary, the files CI's `build` filter
  lists, and one of `ehos_app` or `ehos_design` its `lib/`, `priv/` and `mix.exs`; tests, docs
  and CI are not seen.
- **The format** is [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) as written:
  one `## [Unreleased]` and a `## [X.Y.Z] - YYYY-MM-DD` per release; only the subsections `Added`,
  `Changed`, `Deprecated`, `Removed`, `Fixed` and `Security`; prose only between a heading and its
  first subsection; no link references at the end. A breaking change starts its line with
  `**Breaking:**`. A release's section becomes its GitHub release's notes, so a line links another
  file by its GitHub URL, not by a relative path.
- **Releases.** Each tag publishes a GitHub release whose notes are the version's section, and
  which carries `release.json` (schema `ehos.release/v1`), written from the package's code:
  `vX.Y.Z` for `ehosctl`, with its binaries and `SHA256SUMS` (`ci.yml`), and `ehos_app-vX.Y.Z` and
  `ehos_design-vX.Y.Z` for the others (`release-package.yml`). Only `ehosctl`'s highest release is
  marked latest: mise installs `github:EmpoweredHouse/ehos-tools` from the release GitHub marks
  latest. A release job stops, publishing nothing, when the tag is not of its form, does not name
  a commit on `main`, is not the version in the package's `mix.exs`, or the changelog has no
  section for it or an empty one.
- **`ehos_app`.** A change to what the installer writes reaches a project only through a release:
  a project takes it by moving its dependency to the commit the release's tag names.
- **`ehosctl`.** A release pins one template. Changing any pin in `lib/ehosctl/template.ex` is a new
  release of `ehosctl`.
- **Releasing a package.** On a branch, set the version in the package's `mix.exs` (`X.Y.Z`, the
  `-dev` dropped), rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` with a new empty
  `## [Unreleased]` above it, and open, review and merge the pull request. Then tag the merge
  commit and push the tag; the release job publishes. The next pull request moves the version to
  the next minor's `-dev`, with `No changelog: moves to the next -dev` in its description.
- **Releasing `ehosctl`.** Before the tag, run CI by hand on `main` (`gh workflow run CI --ref
  main`) and wait for `e2e` to pass on all four platforms, and read `release`'s summary of what the
  tag will publish: the tag runs them again, and a tag whose `e2e` fails publishes nothing and is
  not moved, so the fix would be the next version. Then tag the merge commit `vX.Y.Z` and push the
  tag. CI publishes the release and installs it back through mise on all four platforms. The pull
  request that moves to the next `-dev` also moves the `ehosctl` that the template's CI pins
  (`ci.yml.eex`, the `check` job) to the release, with its `ehosctl_linux_x64` SHA-256 from
  `SHA256SUMS`, so a gate `verify` gains reaches applications' CI with the next `ehos_app`;
  `Ehosctl.TemplateTest` fails until it does. When an `ehos_app` release wrote the workflow it
  replaces, that workflow's hash goes in `@earlier_ci_workflows`, with its fixture.
- **Releasing `ehos_app`.** Read what the tag will publish first:
  `gh workflow run release-package.yml -f package=ehos_app -f ref=main`. Then tag the merge commit
  `ehos_app-vX.Y.Z` and push the tag. `ehosctl` installs `packages/ehos_app` at the commit that
  tag names (`git rev-parse ehos_app-vX.Y.Z^{commit}`), so point `lib/ehosctl/template.ex` at it,
  its `@template_ref` at that commit and its `@template_version` at the version, which is a release
  of `ehosctl`. A test fails while the two disagree.
- **Releasing `ehos_design`.** The same, with `-f package=ehos_design` and the tag
  `ehos_design-vX.Y.Z`. Applications take it by raising their dependency, and `ehos_app` pins new
  projects to the commit that tag names, since a tag can be moved: raising that pin is a release of
  `ehos_app`. A removed or renamed token, component class or component attribute is a major
  version, since an application may use any of them by name.
- **Releasing the `ehos-dev` plugin.** Raise `version` in
  `plugins/ehos-dev/.claude-plugin/plugin.json` in the pull request that changes the plugin, then
  tag its merge commit `ehos-dev-vX.Y.Z` and push the tag; it publishes no GitHub release. This repository, eh-os and eh-os-contract then move the
  `ref` of the `ehos-tools` marketplace in their `.claude/settings.json` to that tag, each in a pull
  request of its own. A `ref` moved without a new `version` updates nobody, since Claude Code keeps the
  cached copy of a version it has; a teammate takes the new one after `/reload-plugins` or a
  restart.
- **Releasing the `ehos-app` plugin.** As `ehos-dev`: raise `version` in
  `plugins/ehos-app/.claude-plugin/plugin.json` in the pull request that changes the plugin, and
  in the same pull request the version `Mix.Tasks.EhosApp.Install` pins (`ehos-app`'s entry in `@plugins`), which a test
  holds to that version; then tag its merge commit `ehos-app-vX.Y.Z` and push the tag, before
  `ehos_app` is released. An application takes it with the next `ehos_app` it moves to, whose
  installer moves the `ref` of the `ehos-app` marketplace in its `.claude/settings.json`. A plugin
  added to or removed from `.claude-plugin/marketplace.json` is added to or removed from
  `.claude-plugin/ehos-app.json` only if applications should have it.
- **The design system's tokens and components' stylesheets** in `packages/ehos_design/priv/css/`
  are copies, refreshed from Claude Design and never edited by hand (the package's README,
  "Refreshing the design system"). A token or a component's look the template needs changed is
  asked for in an issue, never patched here. The components' behaviour, in
  `packages/ehos_design/lib/`, is ordinary code.
- **Trying the Homebrew formula.** Before a release exists, install it from a local tap against a
  binary you built:

  ```sh
  brew tap-new --no-git empoweredhouse/local
  # copy packaging/homebrew/ehosctl.rb to "$(brew --repository empoweredhouse/local)/Formula/",
  # set `base` to "file://<absolute path to packages/ehosctl/burrito_out>", and the sha256 of
  # your target to `shasum -a 256 burrito_out/ehosctl_<target>`
  brew install empoweredhouse/local/ehosctl
  brew test empoweredhouse/local/ehosctl
  brew audit --strict empoweredhouse/local/ehosctl
  brew uninstall ehosctl && brew untap empoweredhouse/local
  ```

  Homebrew no longer installs a formula from a loose file, which is why it goes in a tap.
- **Asset names.** A binary is named `ehosctl_<target>`. mise picks the one for a machine by the OS
  and architecture words in that name, so a target name keeps `macos` or `linux` and `x64` or
  `arm64`.
- **Toolchains.** Erlang and Elixir are pinned in `.tool-versions`: the root one for the template,
  `ehos_design` and the review gate, and `packages/ehosctl/.tool-versions` for building the
  binary. The root one is a copy of the pins in `lib/ehosctl/template.ex`, and a test in `ehosctl`
  fails when the two differ. Dependencies are locked in each package's `mix.lock`.

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
| `packages/ehos_design/` | the EmpoweredHouse design system, a Mix project of CSS, fonts, LiveView components and the layout of a mailed message: the template's default look, and the look of the EHOS console and `eh_os_contract`'s dashboard |
| `packages/ehos_diagrams/` | the generator of EHOS's diagrams, a Mix project a repository takes in `:dev` and `:test`: it checks a hand-laid SVG source against the repository's vocabulary and writes it in `ehos_design`'s look ([T-21](docs/adr/0021-eh-os-s-diagram-generator-is-shared-as-ehos-diagrams-a-package-here-that-takes-its-vocabulary-and-ehos-design-from-its-host.md)) |
| `packages/review/` | the review gate, a Mix project never released: `mix review record` marks a reviewed commit, a Claude Code hook refuses `gh pr create` without the mark, `mix review pull_request` checks in CI that a pull request's description records its review, and `mix review.changelog` that a change leaves released changelog sections as they were. Its tests also keep the two plugins' copies of `pre-pr-review`'s procedure one. The gate is `ehos_app`'s `EhosApp.Review`, the one every application has, which it depends on by path |
| `.claude/skills/`, `.claude/review.md` | skills for Claude Code: `sync-design-system` refreshes `ehos_design`'s tokens and components' stylesheets from Claude Design. `.claude/review.md` is this repository's part of `ehos-dev:pre-pr-review` |
| `plugins/ehos-app/`, `.claude-plugin/ehos-app.json` | `ehos-app`, the plugin every application `ehos_app` generates enables in its `.claude/settings.json`, at the tag `Mix.Tasks.EhosApp.Install` pins ([T-15](docs/adr/0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md)), from the marketplace `ehos-app` that `.claude-plugin/ehos-app.json` declares, a name of its own beside `ehos-tools` ([T-16](docs/adr/0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md)): `plan`, `ship`, `pre-pr-review`, `review`, `elixir`, `elixir-anti-patterns-review` and `sample-data`, for working on an application. Released by a tag `ehos-app-vX.Y.Z` ("Versions and releases") |
| `plugins/ehos-dev/`, `.claude-plugin/` | `ehos-dev`, a Claude Code plugin in this repository's marketplace, with the skills eh-os, ehos-tools and eh-os-contract share: `release` says how a changelog line is written and a component released, `stage-issue` how a planned piece of work is run through a GitHub issue, `pre-pr-review` how a change is reviewed before its pull request, `write-adr` how a decision record is written in eh-os and here, not in eh-os-contract, which keeps dated amendments instead, `architecture` how eh-os's architecture pages are kept current with a change in any of the three, `elixir` how Elixir and its tests are written in the three, `voice` how any text a person reads about EHOS is written, in the docs and the console: as technical documentation, with the sentence rules of ASD-STE100 and the words of the glossary of the component that owns each word, `diagrams` how a diagram in that documentation is drawn and generated with `ehos_diagrams`. All three enable it in `.claude/settings.json`, and Claude Code offers to install it from GitHub, at the tag their `ref` names, once the folder is trusted; a change to it is released by a tag `ehos-dev-vX.Y.Z` ("Versions and releases"). A machine without a GitHub SSH key sets `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` and stores a credential with `gh auth setup-git` |
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

How Elixir and its tests are written here is the `ehos-dev:elixir` skill's
([`plugins/ehos-dev/skills/elixir/`](plugins/ehos-dev/skills/elixir/SKILL.md)), for a person and an
assistant alike: its rules, numbered in its `SKILL.md`, and its references, which explain each with
an example. It holds them for eh-os and eh-os-contract too, so they are not restated here. This
section and the next say what is this repository's own; where they differ from the skill, they win.

- **Formatting.** `mix format` is the style. Formatting is not discussed in review.
- **Docs.** The skill's rule 6, held by a package's own docs test (`Ehosctl.DocsTest` in
  `ehosctl`, `DocsTest` in `ehos_platform`, `review`, `ehos_design`, `ehos_diagrams` and
  `ehos_app`), which fails on a module, function or callback without its doc, and by the gates of
  the five released packages, `ehosctl`, `ehos_platform`, `ehos_design`, `ehos_diagrams` and
  `ehos_app`, which build their ExDoc reference with
  warnings as errors (doctests run); `review`, never released, has none to build. Each package
  carries a copy of that test, since sharing one would make a package depend on another for its
  tests alone (ehos-tools#506).
- **Libraries.** Use the standard, community-proven library or tool for a job instead of writing
  one. Look for it first (hex.pm, the tool's documentation, the Elixir forum) and check its current
  version rather than relying on memory. Anything hand-rolled says in the pull request why no
  existing library fits.
- **Behaviour-driven**
  ([T-20](docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)).
  A way out, and any module whose callers' tests should not run it, is a behaviour with its
  implementation beside it, mocked with Hammox: the skill's rules 1 to 4, in a CLI's and a
  library's form of the rule the template gives applications
  ([behaviours](plugins/ehos-app/skills/elixir/references/behaviours.md)). Here:
  - **`ehosctl` is the CLI**, choosing at compile time: `config/dev.exs` and `config/prod.exs`
    name `XImpl`, `config/test.exs` the mock. Its real implementations that choose among real
    backends at run time are `Ehosctl.SystemKeychainImpl` (macOS's keychain, or Linux's Secret
    Service where `secret-tool` is installed), `Ehosctl.TokenStore` (the keychain or a file, from
    `EHOSCTL_TOKEN_STORE`, T-08) and `Ehosctl.Credentials` (the GitHub Actions exchange when
    `EHOSCTL_URL` names the installation, T-18).
  - **`ehos_platform`, `ehos_app` and `ehos_design` are libraries**, choosing in `opts`.
    `ehos_platform`'s `:progress` is a function the caller gives, not a way out.
  - **The implementations at the bottom** are tested against something local, not through
    `Hammox.Protect`: `Ehosctl.HTTPImpl` against sockets of its own test's, and
    `Ehosctl.SignInImpl`, whose requests oidcc sends with its own HTTP client, against a fake
    provider on a local port (`Ehosctl.FakeIssuer`); every other test signs in and calls EHOS
    through their mocks.
  - **Code written before this rule** moves to it package by package, each package in a pull
    request of its own; until its package moves, it is not a finding, even in a change that touches
    it. `ehosctl` reads the process environment through `Ehosctl.SystemEnv`, runs programs through
    `Ehosctl.Runner`, asks the system through `Ehosctl.OS`, reads the time and waits through
    `Ehosctl.Clock`, reads what is typed through `Ehosctl.Terminal`, opens a page through
    `Ehosctl.Browser` and finds the system's keychain through `Ehosctl.SystemKeychain`; what it
    prints is written with `IO`, and a test captures it. `ehos_platform` has moved, except that
    `EhosPlatform.Server` and `EhosPlatform.Server.Provider` read the system's home directory
    when `HOME` gives none they can use. `ehos_design`, `ehos_diagrams` and `review` reach no way
    out. `ehos_app` has not moved.
  - **One conventions test holds every package but `ehos_app` to it**: `EhosTools.ConventionsCase`,
    in the repository's `test/support/`. Each package compiles it in `test` only, through its
    `elixirc_paths(:test)`, and uses it in its own `conventions_test.exs` with its application. The
    test reads each compiled module of the package's `lib/`. It fails on a module that runs a
    program, calls the network, or reads the environment, the home directory, the terminal or the
    clock, or waits, unless the module is an `XImpl` of its `X`. A module that has to do so anyway
    goes in the test's `allowed:` list, with its reason beside it. The test also fails on a module
    in that list that does none of these things any more (ehos-tools#690).
- **Flat control flow**, the skill's rule 5. Code that predates the rule is flattened package by
  package; until its package is, flatten the function you change.
- **Moduledocs and comments cite what outlives the work**, as the skill's style says. Name an issue
  with its repository (`ehos-tools#505`, `eh-os#355`), since ehos_platform's code is read from
  eh-os too, where a bare `#505` means another issue. A template's rule for applications allows a
  platform decision but no task id, since their task ids live outside their repositories; here,
  the issues are the record ("Where the work is recorded").
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
- **What asks something of code** is given to a new project, and a project made before is told
  how to adopt it: Credo, `test/conventions_test.exs` and Boundary, which its code may already
  break. A check that a line of a doc satisfies, such as `test/callback_docs_test.exs`, goes to
  both, with a notice there.

## Tests

The skill's rule 7 and its [tests](plugins/ehos-dev/skills/elixir/references/testing.md) say how a
test is written: Hammox's mocks, its name, its layout, `==` on the whole answer, `async`. Here:

- **A generated file** is asserted on the lines the test is about.
- **Tests written before these rules** move with their area, as code does.
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

- `mix hex.audit`, first and as a process of its own, which fails on a dependency in `mix.lock`
  that is retired or has a security advisory (it needs the network);
- the formatting check;
- compilation with warnings as errors;
- Credo, strict, with the repository's `.credo.exs`, named with `--config-file`;
- the tests, with warnings as errors, so a warning in a test file fails too;
- Dialyzer, in the test environment like the rest, whose PLTs live in the package's
  `_build/plts`; with `--force-check` in a package with a path dependency (`ehosctl`, `review`),
  since dialyxir judges a PLT current by `mix.lock`, which does not name one;
- in `ehosctl`, `ehos_platform`, `ehos_design`, `ehos_diagrams` and `ehos_app`, the
  documentation, built with
  ExDoc with warnings as errors.

Every package runs the audit, Credo, the tests' warnings and Dialyzer. An advisory on a
dependency that has no fixed release and does not reach what the package ships is acknowledged in
its `mix.exs` (`hex: [ignore_advisories: [...]]`), with why beside it, and goes when a fix does.

It passes before every commit and every pull request. Check its own exit code, not the exit code of
a pipe after it.

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every pull request and on every `v*`
tag, and on a push to `main` only when a `mix.lock` or a `.tool-versions` changes, to save the
caches pull requests restore. A pull request checks only the packages it touches, and trying the
binaries end to end waits for a tag, because the macOS runners cost ten times as much as Linux
ones ([T-04](docs/adr/0004-ci-runs-only-what-a-change-or-a-release-needs.md)). A pull request
that changes what goes into a binary (`packages/ehosctl`'s `lib/`, `config/`, `rel/`, `mix.exs`,
`mix.lock` or `.tool-versions`, `packages/ehos_platform`'s `lib/`, `priv/` or `mix.exs`, which it
compiles in, the stylesheets and fonts of `ehos_design` its sign-in page inlines, or `ci.yml`)
builds them, on Linux alone; `Ehosctl.BuildPathsTest` holds that list, in `ci.yml`, to the one the
`changelog` check reads. To try them end to end on a
branch before a tag, start CI by hand, which takes write access to the repository:
`gh workflow run CI --ref <branch>`, or "Run workflow" in the Actions tab. Do it for a change to
how `init` runs or to what the template generates. Started on `main`, the run also shows what a
release of that commit would publish (`release`, below). Each job proves one thing:

| Job | Proves |
| --- | --- |
| `changes` | nothing: it lists the packages a pull request touches, counting the files outside a package that its tests read (the list is in `ci.yml`). Anything but a pull request lists them all |
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
changelog, on every pull request and every edit of its description, and on every push to `main`:

| Job | Proves |
| --- | --- |
| `changelog` | for each of `ehosctl`, `ehos_app`, `ehos_design`, `ehos_diagrams` and `ehos_platform` whose shipped code the pull request changes (for `ehosctl`, what goes into the binary, as `build` reads it: its `lib/`, `config/`, `rel/`, `mix.exs`, `mix.lock` and `.tool-versions`, `ehos_platform`'s `lib/`, `priv/` and `mix.exs`, and the files of `ehos_design` its sign-in page inlines; for the others, their `lib/`, `priv/` and `mix.exs`), its `CHANGELOG.md` changes too, or the description has a line `No changelog: <why>`; every package without one is named. A change to `ehos_platform` is `ehosctl`'s too: both lines, or a `No changelog:`. And no released version's section of a `packages/*/CHANGELOG.md` changes, unless the change is that package's release, which sets a version with no `-dev` in `mix.exs`, above every one released before it, and adds its section above the others (`mix review.changelog`, [#585](https://github.com/EmpoweredHouse/ehos-tools/issues/585)). Both read the pull request's merge commit against its base, what merging would make. On a push to `main`, only the released sections are checked, each commit the push adds against its first parent, which catches a release merged after a pull request's last run. A pull request that means to change released notes, such as one repairing them, fails too, and is merged over the failure with the reason in its description |

[`.github/workflows/release-package.yml`](.github/workflows/release-package.yml) releases
`ehos_app`, `ehos_design`, `ehos_diagrams` and `ehos_platform`, on a tag `<package>-v*`, or started
by hand with a package and a commit or branch of `main` (`-f package=ehos_app -f ref=main`):

| Job | Proves |
| --- | --- |
| `Prepare` | the commit is on `main`, and `mix <package>.release_file` writes its `release.json`; the package's `CHANGELOG.md` has a section that is not empty, the tag's version's on a tag, and otherwise `## [Unreleased]` (or the version's own when it has no `-dev`). On a tag, also that the tag names the run's commit and is the version in the package's `mix.exs`. It writes the notes and `release.json` into its summary, with a read-only token |
| `Publish` | on a tag only, in the environment `release`: the GitHub release, never marked latest, with the section as its notes and `release.json`. The one job whose token may write, and it runs nothing but `gh` |

The environment `release` lets a job deploy only from the tags it lists, one pattern per released
package (`ehos_app-v*`, `ehos_design-v*`, `ehos_diagrams-v*`, `ehos_platform-v*`, and `v*` for
`ehosctl`). A new package released here needs its pattern there before its first tag, in the
repository's settings, "Environments", `release`. Without it `Publish` fails before its first step
and publishes nothing; once the pattern is added, re-run the failed job on the same tag
(`gh run rerun <run> --failed`), and leave the tag where it is.

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

- **Versions.** `ehosctl`, `ehos_app`, `ehos_design`, `ehos_diagrams` and `ehos_platform` each follow
  [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, any minor version may
  break what the one before it offered. Between releases a package's version is the next minor's
  `-dev`: `0.3.0-dev` after `0.2.0`. Only a release's pull request sets a plain version, and only
  the pull request after its tag moves to the next `-dev`: a feature's pull request never changes
  a version. `packages/review` is never released.
- **A line for every change a user can see.** It goes under `## [Unreleased]` in the package's
  `CHANGELOG.md`, in the pull request that makes the change. A pull request without one says why
  on a line of its description, `No changelog: <why>`, and the `changelog` check fails it
  otherwise. A user of `ehosctl` sees what goes into its binary, the files CI's `build` filter
  lists, and one of the other packages its `lib/`, `priv/` and `mix.exs`; tests, docs
  and CI are not seen. A section below `## [Unreleased]` is a release's notes: only that
  package's release changes them, and the check fails any other pull request that does.
- **The format** is [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) as written:
  one `## [Unreleased]` and a `## [X.Y.Z] - YYYY-MM-DD` per release; only the subsections `Added`,
  `Changed`, `Deprecated`, `Removed`, `Fixed` and `Security`; prose only between a heading and its
  first subsection; no link references at the end. A breaking change starts its line with
  `**Breaking:**`. A release's section becomes its GitHub release's notes, so a line links another
  file by its GitHub URL, not by a relative path.
- **Releases.** Each tag publishes a GitHub release whose notes are the version's section, and
  which carries `release.json` (schema `ehos.release/v1`), written from the package's code:
  `vX.Y.Z` for `ehosctl`, with its binaries and `SHA256SUMS` (`ci.yml`), and `<package>-vX.Y.Z`
  for the others (`release-package.yml`). Only `ehosctl`'s highest release is
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
  request that moves to the next `-dev` also moves the `ehosctl` that the template's CI pins to
  the release, by the two values every job reads: `ci.yml.eex`'s `PINNED_EHOSCTL_VERSION`, and
  `PINNED_EHOSCTL_SHA256`, the SHA-256 alone from the `ehosctl_linux_x64` line in `SHA256SUMS`. A
  gate `verify` gains then reaches applications' CI with the next `ehos_app`;
  `Ehosctl.TemplateTest` fails until it does. When an `ehos_app` release wrote the workflow it
  replaces, that workflow's hash goes in `@earlier_ci_workflows`, with its fixture.
- **Releasing `ehos_app`.** Read what the tag will publish first:
  `gh workflow run release-package.yml -f package=ehos_app -f ref=main`. Then tag the merge commit
  `ehos_app-vX.Y.Z` and push the tag. `ehosctl` installs `packages/ehos_app` at the commit that
  tag names (`git rev-parse ehos_app-vX.Y.Z^{commit}`), so point `lib/ehosctl/template.ex` at it,
  its `@template_ref` at that commit and its `@template_version` at the version, which is a release
  of `ehosctl`. A test fails while the two disagree, and another while the table of pins in
  `packages/ehosctl/docs/commands/init.md` does not say the same.
- **Releasing `ehos_design`.** The same, with `-f package=ehos_design` and the tag
  `ehos_design-vX.Y.Z`. Applications take it by raising their dependency, and `ehos_app` pins new
  projects to the commit that tag names, since a tag can be moved: raising that pin is a release of
  `ehos_app`. A removed or renamed token, component class or component attribute is a major
  version, since an application may use any of them by name.
- **Releasing `ehos_diagrams`.** The same, with `-f package=ehos_diagrams` and the tag
  `ehos_diagrams-vX.Y.Z`. A repository that draws diagrams takes it by moving its pin to the commit
  that tag names ([T-21](docs/adr/0021-eh-os-s-diagram-generator-is-shared-as-ehos-diagrams-a-package-here-that-takes-its-vocabulary-and-ehos-design-from-its-host.md)).
  A change to what an output looks like changes every host's outputs when it moves its pin.
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
- **Moving `diagram-design`.** The marketplace lists Cathryn Lavery's `diagram-design` from its own
  repository, pinned to one commit (`sha` in `.claude-plugin/marketplace.json`), since it has no
  tags and changes often. To take a later version, read what changed between the two commits: its
  skill, and anything that runs (`hooks/`, `.mcp.json`, the `hooks` and `mcpServers` of its
  `plugin.json`, `commands/`, `skills/*/scripts/`). Its fixes go only to its latest `main`. Pick a
  commit whose `plugin.json` has a later `version` than the pinned one: Claude Code keeps the cached
  copy of a version it has, so a new `sha` with the same version updates nobody. Raise the `sha` in
  a pull request, and release `ehos-dev` with it. Each of the three repositories enables
  `diagram-design@ehos-tools` in its `.claude/settings.json` in the pull request that moves its
  `ref` to `ehos-dev-v0.8.0`, the first tag whose marketplace lists it, and takes a new commit when
  it moves its `ref` to a later tag. A person who also has `diagram-design` from its own marketplace
  disables that copy, or the pin means nothing. After the update, check that the installed
  `diagram-design` is the new version (`claude plugin list`). Applications do not get it.
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
  fails when the two differ, as another does when the table in `docs/commands/init.md` differs
  from them.
  Dependencies are locked in each package's `mix.lock`.

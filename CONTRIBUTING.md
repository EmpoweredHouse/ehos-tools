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
| `packages/review/` | the review gate, a Mix project never released: `mix review record` marks a reviewed commit, a Claude Code hook refuses `gh pr create` without the mark, and `mix review pull_request` checks in CI that a pull request's description records its review |
| `.claude/skills/` | skills for Claude Code: `pre-pr-review` reviews a change before its pull request, `write-adr` writes a decision record, `sync-design-system` refreshes `ehos_design`'s tokens and components' stylesheets from Claude Design |
| `packaging/homebrew/` | the draft Homebrew formula, published to a tap once the repository is public |
| `docs/` | why the stack is what it is (`research.md`), where the work stands (`spike.md`), and the decisions since (`adr/`, numbered `T-xx`) |

Each package builds, tests and versions on its own. Nothing at the root is a Mix project.

## Code

- **Formatting.** `mix format` is the style. Formatting is not discussed in review.
- **Warnings.** Compile with warnings as errors. A warning is a failure, not a note.
- **Docs.** Every public module has a `@moduledoc`, and every public function a `@doc` and a `@spec`.
  Internal modules say `@moduledoc false` on purpose.
- **Comments.** A comment says *why*, where the code cannot. This matters most for anything shaped
  by a limitation found elsewhere, such as a Burrito launcher detail, an Igniter spec limitation or
  a migration ordering. Name the limitation, so the next reader can check whether it still holds.
- **Libraries.** Use the standard, community-proven library or tool for a job instead of writing
  one. Look for it first (hex.pm, the tool's documentation, the Elixir forum) and check its current
  version rather than relying on memory. Anything hand-rolled says in the pull request why no
  existing library fits.
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

- **Behaviour, not implementation.** A test name reads as a statement of what the tool does.
- **Installer tests** run on `Igniter.Test.phx_test_project/1` and assert the files and patches it
  produces.
- **CLI tests** inject the command runner and read the steps a command would run. No test starts
  mise, Mix or the network.
- **Beyond the suite.** An end-to-end run, from the binary to a generated project passing
  `mix precommit`, is how a change to `ehosctl` or `ehos_app` is verified. `AGENTS.md` has the commands.
  Its result goes into the pull request.
- **Flakiness.** A flaky test is a failing test.

## The gate

`mix check`, in each package:

- the formatting check;
- compilation with warnings as errors;
- the tests.

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
how `init` runs or to what the template generates. Each job proves one thing:

| Job | Proves |
| --- | --- |
| `changes` | nothing: it lists the packages a pull request touches, counting the files outside a package that its tests read (the list is in `ci.yml`). Anything but a pull request lists all four |
| `check` | `mix check` passes in every package `changes` lists, under each package's own `.tool-versions`. For `ehos_design`, with Node and the Chromium Playwright installs (`mix browser.setup`), for its browser test |
| `build` | on a `v*` tag, a run started by hand, or a pull request that changes what goes into a binary: Linux builds all four binaries in one job (Burrito cross-compiles with Zig, macOS included) |
| `e2e` | after `build`, on a `v*` tag or a run started by hand only: on macOS arm64, macOS x64, Linux x64 and Linux arm64, the binary built for it runs `ehosctl init shop` with only mise installed, and the generated project passes `mix ecto.setup` and `mix precommit` against PostgreSQL |
| `release` | on a pushed `v*` tag only, not a run started by hand on one: the tag names the version the binaries were built as; the binaries and `SHA256SUMS` are published as a GitHub release |
| `install` | on a `v*` tag only: on each of the four platforms, `mise use -g github:EmpoweredHouse/ehos-tools@<version>` installs that release and `ehosctl --version` prints it |

[`.github/workflows/review.yml`](.github/workflows/review.yml) runs one more job on every pull
request, and again whenever its description is edited, so that an edit does not run the whole of
CI:

| Job | Proves |
| --- | --- |
| `review section` | the description has a `## Review` section with something in it ([T-03](docs/adr/0003-ci-checks-that-a-pull-request-records-its-authors-review.md)); re-running a failed run reads the description it had, so edit the description instead |

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
  answered or filed as a `follow-up` issue (`.claude/skills/pre-pr-review/`). The pull request
  lists the findings and what became of each. `mix review record`, in `packages/review`, marks the
  reviewed commit; a Claude Code hook (`.claude/settings.json`) refuses `gh pr create` from a
  commit without the mark, and any new commit needs a new review. The description's `## Review`
  section (the pull request template has it) says what the reviews found, or that the change is
  documentation alone. Where the pull request lands, CI's `review section` check fails while
  that section is missing or holds nothing but comments, code and Markdown's structure; what it
  says is for whoever reads the pull request to judge.
- **Decisions are recorded.** A choice that would cost more than a day to reverse, or where a
  reasonable engineer could have chosen differently, gets a record in `docs/adr/` before the code
  that depends on it merges (`.claude/skills/write-adr/`). A decision about EHOS itself is EHOS's,
  in [eh-os](https://github.com/EmpoweredHouse/eh-os/tree/main/docs/adr).
- `main` is always releasable. Work happens on branches.

## Versions and releases

- Each package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, any
  minor version may break what the one before it offered.
- User-visible changes go into the package's `CHANGELOG.md`, in the
  [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format, in the same pull request.
- **`ehos_app`.** Raise its version whenever what the installer writes changes: a project takes the
  change by moving its dependency to the commit that version's tag names, so an unchanged version
  means an unreachable change.
- **`ehosctl`.** A release pins one template. Changing any pin in `lib/ehosctl/template.ex` is a new
  release of `ehosctl`.
- **Releasing `ehosctl`.** Raise `@version` in `packages/ehosctl/mix.exs`, move the `Unreleased`
  entries of its `CHANGELOG.md` under that version, and merge. Run CI by hand on `main`
  (`gh workflow run CI --ref main`) and wait for `e2e` to pass on all four platforms: the tag runs
  it again, and a tag whose `e2e` fails publishes nothing and is not moved, so the fix would be the
  next version. Then tag the merge commit `vX.Y.Z` and push the tag. CI publishes the release and installs it back through mise on all four
  platforms. The tag must equal the version, or the release job stops before publishing.
- **Releasing `ehos_app`.** Raise `@version` in `packages/ehos_app/mix.exs`, move its
  `Unreleased` entries under that version, and merge. Then tag the merge commit `ehos_app-vX.Y.Z`
  and push the tag. `ehosctl` installs `packages/ehos_app` at the commit that tag names
  (`git rev-parse ehos_app-vX.Y.Z^{commit}`), so point `lib/ehosctl/template.ex` at it, its
  `@template_ref` at that commit and its `@template_version` at the version, which is a release of
  `ehosctl`. A test fails while the two disagree.
- **Releasing `ehos_design`.** Raise `@version` in `packages/ehos_design/mix.exs`, move its
  `Unreleased` entries under that version, and merge. Then tag the merge commit
  `ehos_design-vX.Y.Z` and push the tag. Applications take it by raising their dependency, and
  `ehos_app` pins new projects to the commit that tag names, since a tag can be moved: raising
  that pin is a release of `ehos_app`. A removed or renamed token, component
  class or component attribute is a major version, since an application may use any of them by
  name.
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

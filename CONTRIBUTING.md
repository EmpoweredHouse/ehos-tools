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
| `.claude/skills/` | skills for Claude Code; `sync-design-system` refreshes `ehos_design`'s tokens from Claude Design |
| `packaging/homebrew/` | the Homebrew formula the release publishes to the tap |
| `docs/` | why the stack is what it is (`research.md`) and where the work stands (`spike.md`) |

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
- **Upgrades.** A change to what an existing project should have gets an upgrade step, so that
  `mix igniter.upgrade ehos_app` brings older projects along. Otherwise it only reaches new ones.

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

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every pull request and on every push
to `main`. Each job proves one thing:

| Job | Proves |
| --- | --- |
| `check` | `mix check` passes in every package, under each package's own `.tool-versions` |
| `build` | Linux builds all four binaries, one job per target (Burrito cross-compiles with Zig, macOS included) |
| `e2e` | on macOS arm64, macOS x64, Linux x64 and Linux arm64, the binary built for it runs `ehosctl init shop` with only mise installed, and the generated project passes `mix ecto.setup` and `mix precommit` against PostgreSQL |
| `release` | on a `v*` tag only: the tag names the version the binaries were built as; the binaries and `SHA256SUMS` are published as a GitHub release |
| `install` | on a `v*` tag only: on each of the four platforms, `mise use -g github:EmpoweredHouse/ehos-tools@<version>` installs that release and `ehosctl --version` prints it |

`e2e` fetches `eh_os_contract` and `ehos_design` from GitHub, from `eh-os-contract` and from this
repository, and both are private. A GitHub App, *ehos-tools CI*, installed on both with read
access to their contents, mints a token for the one step that runs `init`, and that token can read
nothing else. Git gets it through `GIT_CONFIG_*` variables on that step, so it is not
written to `~/.gitconfig` and no later step sees it. The App's ID and private key are the
repository secrets `EHOS_CI_APP_ID` and `EHOS_CI_APP_PRIVATE_KEY`. Pull requests from forks get no
secrets, so their `e2e` jobs fail at `deps.get`. Once both repositories are public, the token step
and the two secrets can go. `e2e` caches only Hex's downloads: Erlang, Elixir and the generator's archives are
installed from nothing on every run, because that is what a developer's first `init` does.

## Commits and pull requests

- A commit message is a short imperative sentence that says what changes for a reader, with a body
  explaining why when that is not obvious.
- One logical change per pull request. The description says what changed, why, and how it was
  tested.
- `main` is always releasable. Work happens on branches.

## Versions and releases

- Each package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, any
  minor version may break what the one before it offered.
- User-visible changes go into the package's `CHANGELOG.md`, in the
  [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format, in the same pull request.
- **`ehos_app`.** Raise its version whenever what the installer writes changes. `mix igniter.upgrade`
  decides which upgrade steps to run by comparing that version, so an unchanged version means an
  unapplied change.
- **`ehosctl`.** A release pins one template. Changing any pin in `lib/ehosctl/template.ex` is a new
  release of `ehosctl`.
- **Releasing `ehosctl`.** Raise `@version` in `packages/ehosctl/mix.exs`, move the `Unreleased`
  entries of its `CHANGELOG.md` under that version, and merge. Then tag the merge commit `vX.Y.Z`
  and push the tag. CI publishes the release and installs it back through mise on all four
  platforms. The tag must equal the version, or the release job stops before publishing.
- **Releasing `ehos_app`.** Raise `@version` in `packages/ehos_app/mix.exs`, move its
  `Unreleased` entries under that version, and merge. Then tag the merge commit `ehos_app-vX.Y.Z`
  and push the tag. `ehosctl` installs `packages/ehos_app` at that tag, so point
  `lib/ehosctl/template.ex` at it, which is a release of `ehosctl`.
- **Releasing `ehos_design`.** Raise `@version` in `packages/ehos_design/mix.exs`, move its
  `Unreleased` entries under that version, and merge. Then tag the merge commit
  `ehos_design-vX.Y.Z` and push the tag. Applications take it by raising their dependency, and
  `ehos_app` names the tag new projects get, which is a release of `ehos_app`. A removed or renamed
  token is a major version, since an application may use any token by name.
- **The design system's tokens** in `packages/ehos_design/priv/css/` are a copy, refreshed from
  Claude Design and never edited by hand (the package's README, "Refreshing the tokens"). A token
  the template needs changed is asked for in an issue, never patched here.
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
- **Toolchains.** Erlang and Elixir are pinned in `.tool-versions`: the root one for the template
  and `ehos_design`, and `packages/ehosctl/.tool-versions` for building the binary. The root one is a copy of the pins
  in `lib/ehosctl/template.ex`, and a test in `ehosctl` fails when the two differ. Dependencies are
  locked in each package's `mix.lock`.

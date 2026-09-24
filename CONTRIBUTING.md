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
  `mix precommit`, is how a change to either package is verified. `AGENTS.md` has the commands.
  Its result goes into the pull request.
- **Flakiness.** A flaky test is a failing test.

## The gate

`mix check`, in each package:

- the formatting check;
- compilation with warnings as errors;
- the tests.

It passes before every commit and every pull request. Check its own exit code, not the exit code of
a pipe after it.

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
- **Toolchains.** Erlang and Elixir are pinned in `.tool-versions`: the root one for the template,
  and `packages/ehosctl/.tool-versions` for building the binary. Dependencies are locked in each
  package's `mix.lock`.

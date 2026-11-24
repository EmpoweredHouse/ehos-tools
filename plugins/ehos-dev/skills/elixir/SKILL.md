---
name: elixir
description: Use before writing or changing Elixir or a test in eh-os, ehos-tools or ehos_contract, and when a review asks why code should take one shape — behaviours with Hammox mocks, how a CLI and a library choose the implementation, queries, changesets and transactions, contexts and their boundaries, supervision and settings, flat control flow, docs, test names. Not for an application ehos_app generates or the code its templates write (`ehos-app:elixir`).
---

# Writing Elixir in EHOS's own repositories

The code here is a CLI, libraries other repositories depend on, and the platform itself. These
are the rules for it; an application built on EHOS has its own, in `ehos-app:elixir`.

## First, read what this repository owns

Read the rules the repository keeps for its code: the file and sections its `AGENTS.md` or
`CLAUDE.md` names for how code and tests are written (in ehos-tools, `CONTRIBUTING.md`, "Code" and
"Tests"). They win where they differ from this skill, and they say which code predates a rule:
code written before a rule is not changed in passing unless they say so. If the repository names
no such rules, say so to the user and follow this skill alone.

Read also, before you change an established pattern, the `git log` of the files it lives in: the
design is often deliberate, and the commits say why.

Then the reference for what you are writing:

| You are writing | Reference |
| --- | --- |
| A call to a program, the network, the environment, the keychain, the terminal, the clock | [Behaviours](references/behaviours.md) |
| A query, a changeset, a form, a transaction, a constraint | [Data](references/data.md) |
| A context, a controller or LiveView, an OTP application, a supervised process, a setting | [Structure](references/structure.md) |
| A test, a mock | [Tests](references/testing.md) |
| Any function: control flow, maps, lists, docs | [Style](references/style.md) |

## The rules, in one place

Each is explained, with an example, in its reference.

1. **A collaborator a test replaces is a behaviour** `X`, with a `@doc` on each `@callback`, and
   its implementation `XImpl` in the same file; callers name `X`. That is every way out (a
   program, the network, the process environment, the keychain, the terminal, and the clock or
   randomness where a test must say what they return), and any module whose callers' tests should
   not run it. A pure module gets none; a path stays a parameter.
2. **A CLI chooses the implementation at compile time, a library in `opts`.** A CLI's
   `X.current/0` reads `Application.compile_env!/2` with no default, and only the
   environment-specific config files name an implementation. A library takes a module in the
   call's `opts`, defaulting to `XImpl`, named in code and never built from input. A real
   implementation may still pick among real backends at run time, from a fixed set. A Phoenix
   application, such as EHOS itself, follows the repository's own rules for its configuration.
3. **Tests mock with Hammox**, test-only, declared outside `lib/`; `Hammox.Protect` holds an
   implementation to its behaviour where that reaches no real resource. A test never swaps an
   implementation through `Application.put_env/3` or `System.put_env/2`.
4. **No test hook in production code**, an option in `opts` is followed to every call it must
   reach, and **no error prints a value**: credentials and the environment stay out of what an
   exception or an `{:error, message}` can carry to a log.
5. **Control flow stays flat**: no `case` or `with` inside another; a `with` without `else` when
   each step answers its own failure; multi-clause heads over `if` on an argument's shape; a key
   set only when not `nil` through `maybe_put/3`.
6. **Every public function has a `@doc` and a `@spec`**, every public module a `@moduledoc`, every
   callback a `@doc`. A moduledoc starts with what the module does for its caller and cites one
   or two decision records at most, and no issue. A comment says why; no section comments, no
   dead code.
7. **A test is a scenario**: named for what the code does, comparing the whole result with `==`,
   success first, `mock_<function>` helpers at the bottom of the file.
8. **Warnings are failures**: compile with warnings as errors, and run the tests with
   `--warnings-as-errors` where the repository's gate does.
9. **A table is queried only by the context that owns it**, which answers rows, not queries; a
   query that must read two contexts' tables in one statement for its speed, with the
   measurement beside it, belongs to the context whose question it answers, as data.md says.
   Input from outside goes through a changeset, a form is built from one, and a constraint is
   mapped to a refusal on it; input that a parser or a JSON Schema refuses in the context needs no
   second check. The writes of one decision commit together, in an `Ecto.Multi` where it names
   the steps; an `insert_all` or `update_all` stays where `on_conflict` or a `where` decides
   against a race, or for rows the code builds in bulk, with why beside it.
10. **Each context is a boundary**, and the web layer calls contexts only: no `Repo` and no
    `Ecto.Query` in a controller, a LiveView or a plug, and a call that stitches two contexts is a
    context function. Code that only a developer or CI runs stays out of the production build.
11. **A supervised process takes its settings, its collaborators and its name as start options**,
    each defaulting to its production value, and the application's children are a pure function
    of the settings. A setting's defaults are in the one function that validates it at boot; a
    setting a test varies is read through a behaviour, and a library takes its settings in `opts`.

## When a rule does not fit

Say which rule, why, and what you did instead, in the pull request; do not bend the code around it
silently. A rule the repository changes for good goes where it keeps its rules, with a decision
record when it is past the repository's threshold (`ehos-dev:write-adr`).

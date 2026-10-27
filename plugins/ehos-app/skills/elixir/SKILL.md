---
name: elixir
description: How this application's Elixir and its tests are written — what gets a behaviour and a Hammox mock, where a query and a changeset belong, flat control flow, factories and test names. Use whenever you write or change Elixir or a test in an application built on EHOS, before the first line, and when a review asks why code should take one shape over another.
---

# Writing Elixir in an EHOS application

These are the template's rules for code that is not a contract's part: a way out to another
system, a context, a form, a query, a page, a test. A contract's part (a decider, a read model, a
query, a policy, an effect) follows `lib/<app>/contracts/AGENTS.md` and the engine's behaviours.

## First, read the application's own

Read `docs/elixir.md` before writing. Its first section is the template's, the same rules as this
skill; what is below it is the application's, and wins where the two differ. Read also the nested
`AGENTS.md` of the directory you are changing, and `TESTING.md` before you write a test.

Then read the reference for what you are writing:

| You are writing | Reference |
| --- | --- |
| A call to an outside system, EHOS's APIs, mail, the clock, randomness | [Ways out](references/behaviours.md) |
| A test, a mock, a factory | [Tests](references/testing.md) |
| A context, a query, a changeset, a table, a page or controller | [Data and pages](references/data.md) |
| Any function: control flow, lists, maps, names | [Style](references/style.md) |

## The rules, in one place

Each is explained, with an example, in its reference.

1. **A way out of the application is a behaviour**, `<App>.<Name>`, with its implementation
   `<App>.<Name>Impl` and `current/0` choosing between them. A contract's part gets no behaviour
   of its own: it already implements the one the contract generates.
2. **A test replaces a way out with a Hammox mock**, which `config/test.exs` names once. A test
   never swaps an implementation with `Application.put_env/3`.
3. **No test hook in production code**: no canned answer, process to notify or delay read from
   configuration for a test's sake. A test that needs one mocks the way out instead.
4. **The clock, randomness and generated ids are ways out** when a test must sequence them.
5. **A table is read only by the module that owns it.** It answers rows, not queries, and is the
   only module that uses `Ecto.Query`; `test/conventions_test.exs` holds this.
6. **A changeset is for a form or an outside system's answer**, never for a projection, which
   writes with `insert_all`/`update_all`. The contract keeps the invariants; a changeset checks
   input.
7. **A page or controller orchestrates**: params in, one domain call, render. It neither composes
   domain calls nor reshapes domain data, and its test mocks what it calls.
8. **Control flow stays flat**: no `case` or `with` inside another, a `with` without `else` when
   each step answers its own failure, multi-clause heads over `if`/`cond`.
9. **Tests build data with factories**, read as scenarios, and compare the whole answer with `==`.
10. **A moduledoc says what the module is.** It may cite a platform decision (`eh-os D-112`) or a
    contract's `source:`, which a reader can follow; never a task id, a ticket or a plan.

## When the application lacks the tools

The template adds Hammox, ExMachina and Credo, `test/support/mocks.ex` with `setup_mocks/1`,
`test/support/factories.ex` and `test/conventions_test.exs` (`ehos_app`'s `CHANGELOG.md` names the
release). An application without them was generated earlier: say so to the user, and propose
upgrading the template (`mix igniter.upgrade ehos_app`) rather than adding them by hand, which
leaves a fork of what the template keeps. Until then, follow the rules with what the application
has, and do not add a second way of mocking beside the one the template will bring.

## When a rule does not fit

Say which rule, why, and what you did instead, in the pull request; do not bend the code around it
silently. A rule the application changes for good goes in its part of `docs/elixir.md`.

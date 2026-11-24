---
name: elixir-anti-patterns-review
description: Use when reviewing Elixir in eh-os, ehos-tools or ehos_contract for anti-patterns (code, design, process, macros), alone or inside the two reviews of `ehos-dev:pre-pr-review`, and when refactoring one away — findings with evidence and the smallest fix. Not for an application ehos_app generates (`ehos-app:elixir-anti-patterns-review`).
license: Apache-2.0; see LICENSE
---

# Elixir anti-patterns review

Elixir's anti-pattern names explain a concrete problem in a library, a CLI or the platform. A
snippet that matches a name is a candidate, and it becomes a finding only once its harm is shown.
The review reads and reports; it changes code only when the user also asks for fixes.

## Scope and context

- Follow the requested files, diff or package. For a branch, review against the pull request's
  actual base; include staged and unstaged changes only when they are part of the requested scope.
  With no scope, review local changes; if there are none, ask for a target rather than auditing
  the whole repository. Read the changed files and the callers needed to know what they do.
- Read the rules the repository keeps for its code, as `ehos-dev:elixir` says in "First, read what
  this repository owns", and that skill's numbered rules. They are the contract this review checks
  against, and they win over a reference here. Code written before one of their rules is not a
  finding until its area moves, even where the change touches it.
- Inside `ehos-dev:pre-pr-review`, this skill supplements each of its two reviews: keep that
  review's scope and its report, and add these findings to it. It does not replace either.
- Ignore generated output and dependencies; read a lockfile only for a dependency's risk.

## Choose the relevant checks

Read only the references that apply:

| Changed code | Reference |
|---|---|
| Functions, maps, input parsing, `with`, truthiness, atoms | [Code patterns](references/code.md) |
| Contexts, return shapes, options and configuration, Ecto, clients of outside systems | [Design patterns](references/design.md) |
| Tasks, GenServers, supervision, Ports and programs | [Process patterns](references/process.md) |
| Macros, `use`, compile-time configuration, generated code | [Macro patterns](references/macros.md) |

For each candidate, trace the input and the failure through its caller. A finding shows that the
code can produce wrong data, fail an operation, print a secret, lose work, leak a process, or
cost what can be measured. Search for an existing helper before you suggest a new abstraction.

## Report

Merge symptoms into one finding when one fix removes their cause, and order findings by impact.
Inside `ehos-dev:pre-pr-review`, write each finding as that review writes its own. On its own,
use this:

```text
file:line — <anti-pattern name>: <concrete problem>
Evidence: <input, call site, or failure path that demonstrates it>
Impact: <what a user of the library, the CLI or the platform sees>
Fix: <smallest change that keeps the behaviour; a short Elixir example when it helps>
```

Keep readability suggestions apart from defects, and leave them out when the review asked for
bugs only. Name a regression test only when it would fail on the reported behaviour. State what
you assumed and what you ran. If nothing is found, say so and name the scope reviewed; a review
has no quota of findings, and no finding means that scope, not the whole repository.

## Validation when needed

Reading is usually enough. Inside `ehos-dev:pre-pr-review`, run no Mix command: the two reviews
share one checkout and its `_build`, and the author runs the checks after them. On its own, to
reproduce a finding, run `mix test` on the one file in the package it is in, one command at a
time; in eh-os, with a `MIX_TEST_PARTITION` of your own, since sessions share its test database.
Never run `mix format` or `mix precommit` as a read-only step: they change files.

## Source

Adapted and condensed for Shugyo, then for EHOS applications, then for EHOS's own libraries,
CLI and platform, from [bekerk/elixir-anti-pattern-cc-skill](https://github.com/bekerk/elixir-anti-pattern-cc-skill/tree/034f99c6da971e604a668b12d68203879e4663ac/elixir-anti-patterns-review).
The references keep the upstream Elixir Team notices; their examples and checks are modified for
these repositories. The complete license terms are in [LICENSE](LICENSE).

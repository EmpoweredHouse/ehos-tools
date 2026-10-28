---
name: elixir-anti-patterns-review
description: Review this application's Elixir/Phoenix code for code, design, process, and macro anti-patterns. Use for reviews and targeted refactoring, with concrete evidence and minimal fixes that preserve the application's contracts.
license: Apache-2.0; see LICENSE
---

# Elixir anti-patterns review

Use Elixir's anti-pattern names to explain a concrete problem, not to demand that every matching
snippet be rewritten. Review is read-only unless the user also requests fixes.

## Scope and context

- Follow the requested files, diff, or subsystem. For a branch review, use the PR's actual base;
  include staged and unstaged changes only when they are part of the requested scope. With no
  scope, review local changes; if none exist, ask for a target rather than auditing the whole
  application. Read changed files and the callers needed to establish their behavior.
- Read the project's root `AGENTS.md`, the nested `AGENTS.md` of the changed directory, and the
  relevant topic doc it names. For test code or reproductions, also read
  `TESTING.md`.
- In a general branch review, supplement the `ehos-app:review` skill;
  preserve its scope and severity rubric. This skill does not replace that review.
- Ignore generated output and dependencies; inspect lockfiles only for dependency risk.

## Choose the relevant checks

Read only the references that apply:

| Changed code | Reference |
|---|---|
| Functions, maps, input parsing, `with`, truthiness | [Code patterns](references/code.md) |
| Contexts, return contracts, schemas, Ecto, service clients | [Design patterns](references/design.md) |
| Tasks, GenServer/Agent, Oban, runner lifecycle | [Process patterns](references/process.md) |
| Macros, `use`, compile-time configuration or generated code | [Macro patterns](references/macros.md) |

For each candidate, trace the input and failure through its caller. Establish whether it can
produce wrong data, fail an operation, break scope, lose work, or impose a demonstrated cost.
Search existing helpers before suggesting a new abstraction. A pattern match alone is not a finding.

## Report

Merge overlapping symptoms into one finding when one fix addresses their cause. Order findings by
impact, graded as `ehos-app:review`'s `references/lenses.md` says in "Severity" when this skill
supplements that review or `ehos-app:pre-pr-review`. Otherwise describe the impact plainly. Keep
optional readability suggestions separate from defects, and omit them when the requested review is
bugs only.

```text
file:line — <anti-pattern name>: <concrete problem>
Evidence: <input, call site, or failure path that demonstrates it>
Impact: <observable consequence in this application>
Fix: <smallest behavior-preserving change; short Elixir example when useful>
```

Name a regression case only when it would verify the reported behavior. State unverified
assumptions and checks actually run. If no actionable patterns are found, say so and identify the
reviewed scope; do not invent a quota of findings or claim full application health.

## Validation when needed

Static reading is usually enough for review. If reproducing a finding, run `mix test` on the one
file, one command at a time, following `TESTING.md`; use a unique `MIX_TEST_PARTITION`. Never use
`mix precommit` as a read-only review command: it formats files and unlocks dependencies.

## Source

Adapted and condensed for Shugyo, then for EHOS applications, from [bekerk/elixir-anti-pattern-cc-skill](https://github.com/bekerk/elixir-anti-pattern-cc-skill/tree/034f99c6da971e604a668b12d68203879e4663ac/elixir-anti-patterns-review).
The references retain the upstream Elixir Team notices; their examples and checks are modified
for this application. Complete license terms are in [LICENSE](LICENSE).

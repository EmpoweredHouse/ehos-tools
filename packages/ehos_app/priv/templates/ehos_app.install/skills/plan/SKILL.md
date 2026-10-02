---
name: plan
description: Develop an implementation plan for a change to this application through a back-and-forth with the user, then save it locally in gitignored .plans/.
argument-hint: "<what to build>"
disable-model-invocation: true
---

# Plan

Plan: $ARGUMENTS (the text after the skill name). If empty, ask what to build.

Develop the plan in conversation, then save the approved plan in gitignored `.plans/`.
Plans are local working files: never commit them or create new plans in `specs/features/`.
Use plan mode if your harness has it — research stays read-only until the plan is approved.

## 1. Pin the goal

- Read every file the request names, in full.
- Restate goal, scope and expected outcome in 3–5 lines and ask what is missing. Wait. Repeat
  until the user confirms.

## 2. Research

Read before proposing anything:

- Root `AGENTS.md` and `ARCHITECTURE.md` — service boundaries and who owns which write.
- `apps/<app>/AGENTS.md` and `apps/<app>/TESTING.md` for every app the change touches.
- The topic doc in `docs/` that governs the area (`claims.md`, `wiki.md`, `copilot.md`, `auth.md`,
  `tenancy.md`, `deployment.md`, `integrations.md`, …). Its **Decisions** section is what was
  already chosen and rejected — do not re-open one without saying so.
- `.plans/` and legacy `specs/features/` for an earlier plan in the same area. It is history; the code and the topic
  doc win where they disagree.
- The code: the pattern to copy (the reference module in each `apps/<app>/AGENTS.md`), the files
  that change, their tests, the contracts at each service boundary. Fan out read-only explorers,
  one per app, if your harness has subagents.

## 3. Decide, one at a time

List the decisions for yourself, then present **one per message**:

```
### Decision N: <name>
<what forces the choice, with file:line>

1. <Option> — what it means; cost in complexity, UX, performance, migration risk, flexibility.
2. <Option> — …

Recommendation: <n>, because <reason>. Trade-off: <what we give up>.
```

Stop and wait for the answer. Never bundle two decisions, and never ask "which do you prefer?"
without the costs. If the user wants more detail, research and come back with it.

Decisions that recur in this application: which app owns the write (backend owns every PostgreSQL write);
whether a wire shape changes (SSE events, `ai_contract_test.exs`, a mirrored type); public or
tenant migration, and whether a drop needs two deploys; whether a copilot tool writes (then it is
approval-gated); which of the wiki's writers a change belongs to.

## 4. Propose phases

A short list — `Phase N — name — what it accomplishes` — plus which phases can run in parallel.
Each phase should leave the tree green and be reviewable on its own. Wait for approval.

## 5. Save the plan locally

Create `.plans/` if needed and save the approved plan as `.plans/YYYY-MM-DD-<slug>.md`;
kebab-case, 3–5 words.
Use the structure below and give the user the path. Do not stage or commit the file.

```markdown
# <Title>

Status: planned · YYYY-MM-DD · target branch `<base>`

## Goal
## Decisions
| # | Decision | Choice | Rejected, and why |
## Current state        (what exists, with file paths)
## Out of scope
## Phase 1: <name>
<what it accomplishes>
- `path/to/file` (new | modified) — what changes; a snippet only where prose would be ambiguous
- Tests first: `path/to/test` — what it asserts
- [ ] focused test command
- [ ] `make check-<app>` and `make test-<app>`
- [ ] manual check, if any
## Phase 2: …
## Rollout              (migrations, two-deploy drops, tenant steps — only if it applies)
## Docs                 (which topic doc or AGENTS.md changes when this ships)
```

Before handing it over: every path exists; no open question is left; each phase lists tests before
code and ends in a checklist; someone with a clean context could execute it without this
conversation.

## 6. Iterate

Discuss revisions in the conversation and update the local plan in place.

## When the plan ships

The plan is history, not current truth. In the same PR that ships it, move what outlives it — the
contract, invariants, the decisions with their rejected alternative, gotchas — into the topic doc
(`docs/*.md`) or `apps/<app>/AGENTS.md`. If a saved plan exists, set its status line to
`shipped · PR #N`; do not create one for this purpose. Nobody should need the plan to understand the code.

## Rules

- Save plans only in gitignored `.plans/`; no open questions in the final plan.
- Respect the boundaries in root `AGENTS.md`; copy existing patterns rather than inventing new ones.
- Plans are written in English.

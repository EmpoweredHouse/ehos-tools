---
name: plan
description: Use before writing code for a change beyond a small fix (more than one commit, or a change to a rule, an interface or the file layout), and when the user asks for a plan. Settles the decisions with the user one at a time and saves the plan, in phases that end in a commit and a stop, to gitignored .plans/.
argument-hint: "<what to build>"
---

# Plan

Plan: $ARGUMENTS (the text after the skill name). If empty, ask what to build.

Develop the plan in conversation, then save the approved plan in gitignored `.plans/`.
Plans are local working files: never commit them.
Use plan mode if your harness has it — research stays read-only until the plan is approved.
A plan is the user's to approve: in a run with no user to answer, say what needs planning and
stop.

## 1. Pin the goal

- Read every file the request names, in full.
- Restate goal, scope and expected outcome in 3–5 lines and ask what is missing. Wait. Repeat
  until the user confirms.

## 2. Research

Read before proposing anything:

- `VISION.md` (what EHOS is, where this application sits in it, what the application is for),
  then `DEVELOPMENT.md` (the cycle, contract first), `ARCHITECTURE.md` and `TESTING.md`.
- `AGENTS.md`, and the nested `AGENTS.md` of every directory the change touches (the root one
  lists them); for a contract, `lib/<app>/contracts/AGENTS.md`.
- The topic doc in `docs/` that governs the area (the root `AGENTS.md` maps areas to docs). Its
  **Decisions** section is what was already chosen and rejected — do not re-open one without
  saying so.
- `.plans/` for an earlier plan in the same area. It is history; the code and the topic doc win
  where they disagree.
- The contracts first: `mix ehos_contract.view --details` prints the domain and every contract.
  Name what the change does to them: the commands and their `by:`, the events, the invariants,
  the queries and read models, the publications, the promises; or that it touches none.
- The code: the pattern to copy, the files that change, and their tests. Fan out read-only
  explorers if your harness has subagents.
- A page that changes data issues a command as the person signed in, through a context function
  that calls `EhosContract.call/3`: `/ehos-app:elixir`'s `references/data.md`, "A page that
  issues a command". Plan its test to sign in with `EhosContract.Auth.Testing.sign_in/3`.

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

Decisions that recur in this application: whether a business fact is a new event in a contract,
or a change to one (a published event is a contract with other applications); which actor may
issue a command (its `by:`, which becomes the capability EHOS grants); whether `ehos.yaml` changes
(what the application needs from EHOS); whether a migration can run before the new release starts,
and whether a drop needs two deploys; whether the process owner has to approve the change to the
contract.

## 4. Propose phases

A short list — `Phase N — name — what it accomplishes — done when` — plus which phases can run in
parallel. Each phase ends in a commit, or one per finished part of it, each green under
`mix precommit` and reviewable on its own. Each ends in a **stop**, where `ehos-app:ship` waits for
the user's go or no-go before the next. `Stop after: no` is written only where the user said that
phase runs straight into the next.
"Done when" is a check someone else could run: a test that passes, a command's output, a page that
shows something. Wait for approval.

When the change touches a contract, the contract is the first phase: the domain and contract
edited, a scenario for every new command and a `rejected` one for every new invariant, and
`mix compile --warnings-as-errors`, `mix ehos_contract.check` and the scenarios green, before
any phase that implements it. For a contract already deployed, the phase says what the change
does to stored events.

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
Done when: <the check>. Stop after: yes | no
- `path/to/file` (new | modified) — what changes; a snippet only where prose would be ambiguous
- Tests first: `path/to/test` — what it asserts
- [ ] focused test command
- [ ] `mix precommit`
- [ ] manual check, if any
## Phase 2: …
## Contract             (what changes in which contract, and what it does to stored events — or "none")
## Rollout              (migrations, two-deploy drops, a changed `ehos.yaml` — only if it applies)
## Docs                 (which topic doc or AGENTS.md changes when this ships)
```

Before handing it over: every path exists; no open question is left; each phase lists tests before
code, ends in a checklist and says whether it stops; someone with a clean context could execute
it without this conversation.

## 6. Iterate

Discuss revisions in the conversation and update the local plan in place.

## When the plan ships

The plan is history, not current truth. In the same PR that ships it, move what outlives it — the
contract, invariants, the decisions with their rejected alternative, gotchas — into the topic doc
(`docs/*.md`) or the nested `AGENTS.md` it belongs to. If a saved plan exists, set its status line to
`shipped · PR #N`; do not create one for this purpose. Nobody should need the plan to understand the code.

## Rules

- Save plans only in gitignored `.plans/`; no open questions in the final plan.
- Respect the rules in the root `AGENTS.md`; copy existing patterns rather than inventing new ones.
- Plans are written in English.

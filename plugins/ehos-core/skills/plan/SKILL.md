---
name: plan
description: Use before writing code for a change beyond a small fix (more than one commit, or a change to a rule, an interface or the file layout), and when the user asks for a plan, in an EHOS repository or an application built on EHOS. Names the outcome, the outside judge that shows it and what is expected, settles the decisions with the user one at a time, and lays the work out in phases that each end in a commit and a stop.
argument-hint: "<what to build>"
---

# Plan

Plan: $ARGUMENTS (the text after the skill name). If empty, ask what to build.

Develop the plan in conversation, and write the approved plan where the repository keeps its
plans. Use plan mode if your harness has it: research stays read-only until the plan is approved.
A plan is the user's to approve: in a run with no user to answer, say what needs planning and
stop.

The start names what the end checks. A plan names the work's **outcome**, the **judge** that shows
it, and what the judge is **expected** to show; `ehos-core:retro` later checks the finished work
against those three.

## First, read what this repository owns

This skill is the method; the facts are the repository's, and they win where the two differ.

- **Every repository:** the root `AGENTS.md`, and the nested `AGENTS.md` of each directory the
  change touches (the root one lists them).
- **eh-os, ehos-tools, ehos_contract:** `CONTRIBUTING.md`, its sections "Where the work is
  recorded" and the one after it, and `.claude/review.md`. A plan there is a step of eh-os's stage
  plan or of ehos_contract's programme, and its record is an issue: `ehos-dev:stage-issue` says how
  both are kept.
- **An application built on EHOS:** the `ehos-app` plugin's `plan` skill holds the application's
  part: the documents an application's plan reads (its step 2), the decisions that recur there
  (step 3), the contract as the first phase (step 4), the gate (`mix precommit`) and `.plans/`,
  where a plan is saved (step 5). Take those facts from it, and follow this skill's steps, not its
  own.

From these, know before step 1: where a plan is kept, the gate each phase's commit passes, when a
decision gets a record and where, and the decisions that recur in this repository. A question the
repository's part leaves open goes to the user, rather than taking another repository's answer.

## 1. Pin the outcome

- Read every file the request names, in full.
- Restate in 3–5 lines the goal and the scope, then the three things the end checks:
  - **Outcome**: what is true when the work is done, for a user, a developer or the repository. A
    state of the world, never a list of tasks.
  - **Judge**: the check outside the assistant's own opinion that shows the outcome: a test, a
    run, a measurement, named as the command or the steps that start it. The assistant can start
    it itself. When none exists yet, the first phase builds it; when none can, say so, and name
    what the user checks instead.
  - **Expected**: what the judge shows once the outcome holds: the test that turns green, the
    output, the number.
- Ask what is missing. Wait. Repeat until the user confirms all three.

## 2. Research

Read before proposing anything:

- The repository's part, above, and the domain plugin's part it names.
- What was already decided: the records (`docs/adr/` and the like) and the **Decisions** sections
  of the docs that govern the area. Re-opening one is said, never done quietly.
- An earlier plan in the same area. It is history; the code and the docs win where they disagree.
- Before planning to change an established pattern, the `git log` of the files it lives in: the
  design is often deliberate, and its commits say why.
- The code: the pattern to copy, the files that change, and their tests. Fan out read-only
  explorers if your harness has subagents.

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
without the costs. If the user wants more detail, research and come back with it. A decision past
the repository's threshold for a record gets its record, written the way the repository says.

## 4. Propose phases

A short list — `Phase N — name — what it accomplishes — done when` — plus which phases can run in
parallel, and the files each one touches. Each phase ends in a commit, or one per finished part of
it, each green under the repository's gate and reviewable on its own. Each ends in a **stop**,
where the user gives a go or no-go before the next. `Stop after: no` is written only where the
user said that phase runs straight into the next. A run with no user stops at the end of its phase
and reports.

"Done when" is a check someone else could run: a test that passes, a command's output, a page
that shows something. The last phase's is the judge, showing what was expected. Wait for approval.

## 5. Write the plan down

Where it goes is the repository's: an application's gitignored `.plans/`, as
`.plans/YYYY-MM-DD-<slug>.md`, never committed; in EHOS's repositories, the step of the stage's
plan and its issue, as `ehos-dev:stage-issue` says. A plan the repository keeps nowhere stays in the
conversation. Give the user the path or the link.

```markdown
# <Title>

Status: planned · YYYY-MM-DD · target branch `<base>`

## Outcome
## Judge                (the command or run that shows the outcome, and who starts it)
## Expected             (what the judge shows once the outcome holds)
## Decisions
| # | Decision | Choice | Rejected, and why |
## Current state        (what exists, with file paths)
## Out of scope
## Phase 1: <name>
<what it accomplishes>
Done when: <the check>. Stop after: yes | no
- `path/to/file` (new | modified) — what changes; a snippet only where prose would be ambiguous
- Tests first: `path/to/test` (new | modified) — what it asserts
- [ ] focused test command
- [ ] the repository's gate
- [ ] manual check, if any
## Phase 2: …
## Docs                 (which doc or AGENTS.md changes when this ships)
```

The repository's part may add sections of its own; an application's adds its contract and its
rollout.

Before handing it over: every path the plan reads or modifies exists, and every new one is marked
new in a directory that exists or under another new path the plan names; no open question is left;
the judge is a check the assistant can start, or the user's check that step 1 named because none
can; each phase lists tests before code, ends in a checklist and says whether it stops; someone with
a clean context could execute it without this conversation.

## 6. Iterate

Discuss revisions in the conversation and update the plan in place.

## When the work ships

The plan is history, not current truth. In the same pull request that ships it, move what outlives
it — the decisions with their rejected alternative, the rules, the gotchas — into the doc or the
`AGENTS.md` it belongs to, as the repository's part says. Keep the outcome, the judge and what was
expected where `ehos-core:retro` reads them: the saved plan, the step's issue, or the pull
request's description. If a saved plan exists, set its status line to `shipped · PR #N`. Nobody
should need the plan to understand the code.

## Rules

- Plans are written in English.
- Respect the root `AGENTS.md`; copy existing patterns rather than inventing new ones.

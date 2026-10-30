---
name: ship
description: Use to take a plan in .plans/, or a small fix agreed in the conversation, to a ready-for-review pull request — phase by phase, each ending in a commit and a stop, tests first, `mix precommit` green, docs in the same PR, reviewed and recorded before its draft opens.
argument-hint: "<.plans/<plan>.md>"
disable-model-invocation: true
---

# Ship

Input: $ARGUMENTS (the text after the skill name) — a plan path.
If empty, ask; offer the plans in `.plans/` that are not marked shipped.

## 1. Load

- **Plan** — read it in full and resume from the first unchecked `- [ ]`.
- **No plan** — a change beyond a small fix is planned first, with `ehos-app:plan`. A small fix
  settles any decision still open with the user, then states its approach and validation steps in
  the conversation; an existing approval remains sufficient. It is one phase: its validation steps
  are its checklist and its "Done when".
- Read `VISION.md`, `TESTING.md`, the nested `AGENTS.md` of every directory you will touch (the
  root `AGENTS.md` lists them), and the `docs/*.md` topic doc that governs the area.

## 2. Branch from the right base

Default to `main`; an approved plan may name a different
base for a stacked change.

- Take the base from the plan's status line. Otherwise check where the code you touch
  lives — `git fetch origin`, then `git ls-tree origin/main -- <path>` or
  `git merge-base --is-ancestor <commit> origin/main` — and, for a stacked change,
  `gh pr view <parent> --json baseRefName,state`. Unsure: ask.
- Clean tree (`git status`); if it is dirty, ask.
- Name: `<user>/<slug>`, from the plan filename.
- `git switch -c <branch> origin/<base>`.
- In a worktree, run everything from the worktree path; a fresh one needs its dependencies
  installed first (root `AGENTS.md`).

## 3. Push early, open the pull request once reviewed

Push the branch as you go (`git push -u origin <branch>`), so the work is never only local. The
pull request waits: the review gate in `.claude/settings.json` refuses to open one from a commit
`ehos-app:pre-pr-review` has not reviewed and recorded, so it is opened, as a draft, in step 8.

## 4. Implement phase by phase (TDD)

**The contract comes first.** When the change touches a contract, its first phase edits the
domain and the contract, with a scenario for every new command and a `rejected` one for every new
invariant, and ends with `mix compile --warnings-as-errors`, `mix eh_os_contract.check` and the
scenarios green. Only then does a phase implement it (`DEVELOPMENT.md`, "The cycle: contract
first"). A change to a command's name, fields or `by:`, to a publication or to a promise needs the
process owner's agreement: ask the user before making it.

Before writing Elixir or a test, load `ehos-app:elixir` and read `docs/elixir.md`: they say what
gets a behaviour and a mock, where a query belongs, and how a test is built.

For behaviour changes:

1. **Red** — a failing test that states the behaviour.
2. **Green** — the minimum code that passes it.
3. **Refactor** — clean up, still green.

Run only the focused test file while cycling (`mix test test/path_test.exs:42`), never two `mix`
commands at once. Documentation edits use the harness test (`mix test test/harness_test.exs`);
fixture/assertion refactors preserve meaning and reuse existing coverage.

Test conventions: the project's `TESTING.md`.

Independent work can go to parallel subagents if your harness has them. Give each its task, its
file paths, the TDD rule and the `AGENTS.md` that governs them, and keep `mix` to one of them at a
time.

End of each phase: run its checklist, check its "Done when", and commit: once for the phase, or
once per finished part of it, each green under `mix precommit`. If a saved plan was provided, tick
its completed items. Then **stop**: report what the phase did and how it was checked, and ask the
user for go or no-go on the next. Run on only where the plan says `Stop after: no`, or the user
said to run straight through; a manual check the plan lists always waits for the user. In a run
with no user to answer, stop at the end of the phase and report.

The code does not match the plan? Stop. Show *plan says / code says / impact* with two or three
options, and wait.

## 5. Before every push

Once the PR is open:

```bash
gh pr view <n> --json state,baseRefName
```

A push to a branch whose PR is already `MERGED` ships nowhere — and a merged stacked child landed
in its base, not in `main`. If it merged, branch again from the updated base and open a new PR.
New commits on an open PR are reviewed before they are pushed (`ehos-app:pre-pr-review`, "After
the pull request is open").

## 6. Gate

```bash
mix precommit
```

It runs the compiler with warnings as errors, the contract checks, formatting and the tests,
the harness test (`test/harness_test.exs`) among them. CI runs `ehosctl verify` instead
(`.github/workflows/ci.yml`), which also checks `mix.lock` and generates the manifest, and checks
the formatting rather than applying it: run it before pushing to check what CI checks, and,
signed in, to have EHOS check `ehos.yaml` and the manifest.

- Renamed or removed a field, column, endpoint, event, type or module? `git grep <old_name>`. The
  old name may survive only in migration and schema files; every other hit — serializer, type,
  prompt, fixture, component, doc — is stale, and tests won't catch it because the old field is
  usually nullable or ignored.
- A column or table drop ships in two deploys (stop reading it, then drop it): migrations run
  before the new release starts — `ARCHITECTURE.md`.
- If docs CI differs locally, check the PR's merged tree. Leave room inside guide line budgets.

## 7. Docs in the same PR

If behaviour, a contract or a decision changed, update the doc that owns it — `docs/*.md`,
a nested `AGENTS.md` or `TESTING.md` — in this PR. Present tense, only what the code cannot tell;
a decision is a 2–4 line entry in the doc's Decisions section (chosen, why, rejected). Code comments
link a doc file, never an ADR number or a section number. Move lasting plan decisions into the topic
doc; if a saved plan exists, mark it `shipped · PR #N` once step 8 has opened the PR. Do not
create a plan file for shipping.

## 8. Ready

1. Run the `ehos-app:pre-pr-review` skill on the branch: its two reviews, every finding settled
   before anything is recorded (its P0s and P1s fixed, or declined explicitly by the human author;
   P2s do not gate readiness), `mix precommit`, the review recorded, and the draft PR opened
   against the base from step 2. A fix after that is new commits, reviewed before they are pushed.
2. PR body, from the template: what changed, how to test (automated and manual steps), what the
   reviewer should look at, and the `## Review` section the skill fills in.
3. Give the human the manual test: the exact steps (a request to `/api`, a page, a `mix`
   command), and what working looks like. Then wait for them to say they ran it. Your own testing
   does not substitute, and you never mark this step done yourself. For a change to docs alone,
   the human confirms the content instead.
4. `gh pr ready`, once the human has confirmed.

## Rules

- Never implement on `main` or directly on the base branch.
- Never skip tests; never report done with a red `mix precommit`.
- Conventional commits: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`.

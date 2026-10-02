---
name: ship
description: Take a local plan in .plans/, or an approach agreed in the conversation, to a ready-for-review PR — right base branch, draft PR early, TDD phase by phase, `mix precommit` green, topic doc updated in the same PR.
argument-hint: "<.plans/<plan>.md>"
disable-model-invocation: true
---

# Ship

Input: $ARGUMENTS (the text after the skill name) — a plan path.
If empty, ask; offer the plans in `.plans/` that are not marked shipped.

## 1. Load

- **Plan** — read it in full and resume from the first unchecked `- [ ]`.
- **No plan** — state the approach and validation steps in the conversation. Resolve missing
  decisions before implementation; an existing approval remains sufficient. Do not require the
  `plan` skill or generate a plan file based on file count or app count. Save useful working plans
  in gitignored `.plans/`; never stage or commit them.
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

## 3. Draft PR early

```bash
git commit --allow-empty -m "chore: open PR for <slug>"
git push -u origin <branch>
gh pr create --draft --base <base> --title "<what the work does>" --body "<the plan's goal>"
```

## 4. Implement phase by phase (TDD)

For behaviour changes:

1. **Red** — a failing test that states the behaviour.
2. **Green** — the minimum code that passes it.
3. **Refactor** — clean up, still green.

Run only the focused test file while cycling (`mix test test/path_test.exs:42`), never two `mix`
commands at once. Documentation edits use the harness test (`mix test test/harness_test.exs`);
fixture/assertion refactors preserve meaning and reuse existing coverage.

Test conventions: [`TESTING.md`](../../../TESTING.md).

Independent work can go to parallel subagents if your harness has them. Give each its task, its
file paths, the TDD rule and the `AGENTS.md` that governs them, and keep `mix` to one of them at a
time.

End of each phase: run its checklist and report progress in the conversation. If a saved plan was
provided, tick its completed items. Commit once for the phase. If the plan lists a manual check,
pause for the user unless told to run straight through.

The code does not match the plan? Stop. Show *plan says / code says / impact* with two or three
options, and wait.

## 5. Before every push

```bash
gh pr view <n> --json state,baseRefName
```

A push to a branch whose PR is already `MERGED` ships nowhere — and a merged stacked child landed
in its base, not in `main`. If it merged, branch again from the updated base and open a new PR.

## 6. Gate

```bash
mix precommit
```

It is the gate CI runs: the compiler with warnings as errors, the contract checks, formatting and
the tests, the harness test (`test/harness_test.exs`) among them.

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
doc; if a saved plan exists, mark it `shipped · PR #N`. Do not create a plan file for shipping.

## 8. Ready

1. Run the [`review`](../review/SKILL.md) skill on the branch. Fix its P0s and P1s, or have the
   human author decline each one explicitly. P2s do not gate readiness.
2. PR body: what changed, how to test (automated and manual steps), what the reviewer should
   look at.
3. Give the human the manual test: the exact steps (a request to `/api`, a page, a `mix`
   command), and what working looks like. Then wait for them to say they ran it. Your own testing
   does not substitute, and you never mark this step done yourself. For a change to docs alone,
   the human confirms the content instead.
4. `gh pr ready`, once the human has confirmed.

## Rules

- Never implement on `main` or directly on the base branch.
- Never skip tests; never report done with a red `mix precommit`.
- Conventional commits: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`.

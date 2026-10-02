---
name: ship
description: Take a Linear issue (SHU-id) and/or a local plan in .plans/ to a ready-for-review PR — right base branch, draft PR early, TDD phase by phase, make check/test green for every touched app, topic doc updated in the same PR, Linear kept in step.
argument-hint: "<SHU-123 and/or .plans/<plan>.md>"
disable-model-invocation: true
---

# Ship

Input: $ARGUMENTS (the text after the skill name) — one or more SHU-ids, a plan path, or both.
If empty, ask; offer the plans in `.plans/` that are not marked shipped.

## 1. Load

- **Issue** — with the Linear MCP: `get_issue` with relations and `list_comments` for each id; look
  at images in the description. If the Linear MCP is not connected, stop and say so rather than
  guessing the issue. Several ids: ask whether they share one PR — unrelated issues in one PR are
  harder to review and to revert.
- **Plan** — read it in full and resume from the first unchecked `- [ ]`.
- **No plan** — state the approach and validation steps in the conversation. Resolve missing
  decisions before implementation; an existing approval remains sufficient. Do not require the
  `plan` skill or generate a plan file based on file count or app count. Save useful working plans
  in gitignored `.plans/`; never stage or commit them.
- Read `apps/<app>/AGENTS.md` and `apps/<app>/TESTING.md` for each app you will touch, and the
  `docs/*.md` topic doc that governs the area.

## 2. Branch from the right base

Wiki and claims are on `main`. Default to `main`; an issue or approved plan may name a different
base for a stacked change.

- Take the base from the plan's status line or the issue. Otherwise check where the code you touch
  lives — `git fetch origin`, then `git ls-tree origin/main -- <path>` or
  `git merge-base --is-ancestor <commit> origin/main` — and, for a stacked change,
  `gh pr view <parent> --json baseRefName,state`. Unsure: ask.
- Clean tree (`git status`); if it is dirty, ask.
- Name: the issue's Linear `branchName`; otherwise `<user>/shu-123-<slug>`, or `<user>/<slug>`
  from the plan filename.
- `git switch -c <branch> origin/<base>`.
- In a worktree, run everything from the worktree path; a fresh one needs its dependencies
  installed first (root `AGENTS.md`).

## 3. Draft PR early

```bash
git commit --allow-empty -m "chore: open PR for SHU-123"
git push -u origin <branch>
gh pr create --draft --base <base> --title "<what the work does>" --body "Fixes SHU-123"
```

`Fixes SHU-…` closes the issue on merge; `Part of SHU-…` links without closing. Move the issue to
In Progress (`save_issue`).

## 4. Implement phase by phase (TDD)

For behaviour changes:

1. **Red** — a failing test that states the behaviour.
2. **Green** — the minimum code that passes it.
3. **Refactor** — clean up, still green.

Run only the focused test file while cycling (commands per app in its `AGENTS.md`/`TESTING.md`;
backend tests always from `apps/backend`, never two `mix` commands at once). Documentation edits
use the docs gate; fixture/assertion refactors preserve meaning and reuse existing coverage.

Backend test conventions: [`TESTING.md`](../../../apps/backend/TESTING.md).

Independent work in different apps can go to parallel subagents if your harness has them. Give
each its task, its file paths, the TDD rule and its app's `AGENTS.md`.

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

For every app the diff touches (`git diff --name-only origin/<base>...HEAD`):

```bash
make check-<app> && make test-<app>    # web, backend, ai, bigquery, wiki-agent
make check-docs                         # whenever a doc, TESTING.md or AGENTS.md changed
```

- MCP code lives in `apps/ai` → `check-ai`/`test-ai`.
- The `:docker` wiki tests run the prebuilt `wiki-agent:dev` image; rebuild it after touching
  `apps/wiki-agent/` (command in `apps/wiki-agent/AGENTS.md`).
- Renamed or removed a field, column, endpoint, event, type or module? `git grep <old_name>`. The
  old name may survive only in migration and schema files; every other hit — serializer, type,
  prompt, fixture, component, doc — is stale, and tests won't catch it because the old field is
  usually nullable or ignored.
- A column or table drop ships in two deploys (stop reading it, then drop it): migrations run
  before the new revision rolls out — `docs/deployment.md`.
- If docs CI differs locally, check the PR's merged tree. Leave room inside guide line budgets.

## 7. Docs in the same PR

If behaviour, a contract or a decision changed, update the doc that owns it — `docs/*.md`,
`apps/<app>/AGENTS.md` or `TESTING.md` — in this PR. Present tense, only what the code cannot tell;
a decision is a 2–4 line entry in the doc's Decisions section (chosen, why, rejected). Code comments
link a doc file, never an ADR number or a section number. Move lasting plan decisions into the topic
doc; if a saved plan exists, mark it `shipped · PR #N`. Do not create a plan file for shipping.

## 8. Ready

1. PR body: what changed per app, how to test (automated and manual steps), what the reviewer
   should look at.
2. Comment the summary on each Linear issue (`create_comment`); move it to In Review.
3. `gh pr ready`.

## Rules

- Never implement on `main` or directly on the base branch.
- Never skip tests; never report done with a red `make` target.
- Conventional commits: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`.
- **Never** add `Co-Authored-By`, "Generated with", or any other AI attribution to commits or PRs.

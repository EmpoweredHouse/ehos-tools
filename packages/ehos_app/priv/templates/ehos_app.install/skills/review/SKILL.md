---
name: review
description: Review the current branch against its base through Shugyo's own lenses — tenancy, frozen contracts and mirrors, migrations and rollout order, the invalidation net, approval-gated tools, the wiki's writers, docs in the same PR — on top of the harness's generic bug hunt. `summary` mode produces a comprehension map of the branch instead of findings.
argument-hint: "[summary] [focus, e.g. 'tenancy', 'backend only', 'contracts on ai']"
disable-model-invocation: true
---

# Review

Input: $ARGUMENTS (the text after the skill name). Empty → review everything. Starts with
`summary` → [Summary mode](#summary-mode). Otherwise a lens or an app/path to narrow to.

## 0. Scope

The base is the PR's base (`gh pr view --json baseRefName`), not always `main` — epic branches
stack. Then, yourself:

```bash
git fetch origin
git diff --stat origin/<base>...HEAD
git log --oneline origin/<base>..HEAD
git diff --name-status origin/<base>...HEAD
```

Ignore lockfiles and build output (`bun.lock`, `mix.lock`, `uv.lock`, `_build/`, `deps/`,
`node_modules/`, `dist/`, snapshots) except as dependency risk. Narrow to the apps, paths or lenses
the input names.

## 1. Generic pass — delegate it

Correctness bugs, reuse and simplification are the harness's job: run its built-in reviewer if it
has one (Claude Code `/code-review`, Codex `/review`) and carry its findings into the report after
the severity check in step 4. Without one, read the diff for correctness yourself. Don't repeat that
pass under the lenses below.

For backend Elixir changes, also use [elixir-anti-patterns-review](../elixir-anti-patterns-review/SKILL.md)
as a language-specific supplement. Keep this review's scope and severity rubric.

## 2. Shugyo lenses

Choose the lenses the changed paths trigger. Each is a section of
[`references/checklist.md`](references/checklist.md) — read that section and mark every item
PASS / FAIL / N/A; each FAIL becomes a finding.

| Lens | Triggered by | Catches |
|---|---|---|
| Boundaries & security | controllers, plugs, service clients, `apps/bigquery`, `apps/ai/src/mcp`, `/api/agent` | AI writing PostgreSQL, web calling AI/BigQuery, fail-open key, widened agent scope |
| Tenancy | Ecto queries, schemas, migrations, Oban workers, fixtures in `apps/backend` | missing explicit prefix, public/tenant mix-up, a second sandbox owner |
| Frozen contracts | `streaming.py`, `StreamingHandler`, internal views the AI reads, `backend_http_client.py`, taxonomy, view context | wire change without its pinned test or its mirror |
| Migrations & rollout | `priv/repo/**`, removed or renamed fields | single-deploy drop, irreversible migration, stale references |
| Invalidation net | `apps/web/src/hooks`, backend payloads that embed another domain | missing `declareInvalidates`, embedding with no `FANOUT` edge |
| Approval-gated tools | `apps/ai/src/agents/**/tools`, `approvals.py`, `parse-agent-write.ts` | write tool not gated, `apply_` name missing from `WRITE_TOOLS` |
| Wiki writers | `apps/backend/apps/wiki`, `apps/wiki-agent` | new `Wiki.Edit.publish/2` caller without the checks, run writing a person's page |
| App conventions | any app | the per-app rules in `apps/<app>/AGENTS.md` |
| Docs | any behaviour or contract change | topic doc not updated in this PR, ADR citations |

Small diff (≤3 files, ≤50 lines): do it yourself. Larger: one subagent per lens or per app, if your
harness has them. Give each, verbatim: its lens and checklist section, its exact changed-file list,
"read every file in full at HEAD", the format, the anti-drift rules and the severity rubric below.

## 3. Findings

```
**P# `file:line` — title**
Why: one sentence of impact.
Fix: the concrete change, not "consider".
Proof: snippet, hunk or call site.
```

Anti-drift: no redesign unless a P0/P1 needs one; no "add tests" without naming the case and what
it asserts; no security claim without an exploit path; no style or naming unless it causes a bug;
only the assigned files; only what this branch changed.

**Severity** — when in doubt, downgrade; more than three P0s means inflation.

- **P0** — a real user hits it in normal use and it is serious: data loss or corruption, an
  exploitable hole (auth bypass, injection, XSS, a cross-tenant read), a 500 on a happy path,
  silently wrong data, a frozen contract broken or a mirror out of step.
  *Not* P0: theoretical races, a user seeing their own data, missing rate limits, UUID-guarded IDOR,
  input the UI never sends.
- **P1** — real but survivable: a UX bug with a workaround, edge-case data bugs, confusing errors,
  perf that profiles but isn't felt, dead code, a FE/BE type mismatch, stale references after a
  rename, a doc not updated.
- **P2** — style, DRY, hardening, accessibility beyond keyboard, unlikely-path coverage.

## 4. Report

Re-check every P0 against the rubric and deduplicate across agents, then:

```markdown
## Review: <branch> → <base>
<2–3 sentences: what the branch does, and how>
Commits N · files N · apps … · lenses … (and why)
### P0 — must fix before merge
### P1 — fix before or right after merge
### P2 — suggestions
### Contracts and rollout
<frozen surfaces and mirrors touched, migration order — or "none">
### Verdict
<merge-ready | ready after P1 fixes | blocked on P0>
```

## Summary mode

A comprehension map, not a judgement: no severities, no suggestions.

1. ≤10 changed files: read each in full yourself. More: one subagent per app, each reading its
   files in full at HEAD plus `git diff origin/<base>...HEAD -- <file>`, and returning one row per
   file and the app's cross-service touchpoints (REST, WebSocket, SSE, internal API, DB, Oban,
   BigQuery, the wiki-agent container, external providers).
2. Trace the flow across service boundaries with `ARCHITECTURE.md` as the map.
3. Write:

```markdown
## Changemap: <branch> → <base>
Commits N · files N · apps …
### Overall idea
<2–3 sentences a non-engineer can follow: the problem, the capability>
### Key features
- <a capability, not an implementation task>
### Flow
1. trigger → web → backend → DB / AI / BigQuery / wiki-agent → back
### Files
#### apps/<app>
| File | Change | What changed | Rule it implements |
```

Leave out apps with no changes. Within an app order files migration → schema → context →
controller → client. On large branches collapse trivial test- or type-only changes into one row.

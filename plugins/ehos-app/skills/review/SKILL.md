---
name: review
description: Review the current branch against its base through this application's own lenses — its contracts, the credential in front of every command, ehos.yaml, migrations that run before the release starts, other applications' data, docs in the same PR — on top of the harness's generic bug hunt. `summary` mode produces a comprehension map of the branch instead of findings.
argument-hint: "[summary] [focus, e.g. 'contracts', 'migrations', 'lib/<app>_web only']"
disable-model-invocation: true
---

# Review

To review your own change before its pull request, and record it for the review gate, use
`ehos-app:pre-pr-review`, which reviews through these lenses too.

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

Ignore lockfiles and build output (`mix.lock`, `_build/`, `deps/`, `priv/static/assets/`) except
as dependency risk. Narrow to the paths or lenses the input names.

## 1. Generic pass — delegate it

Correctness bugs, reuse and simplification are the harness's job: run its built-in reviewer if it
has one (Claude Code `/code-review`, Codex `/review`) and carry its findings into the report after
the severity check in step 4. Without one, read the diff for correctness yourself. Don't repeat that
pass under the lenses below.

For Elixir changes, also use the `ehos-app:elixir-anti-patterns-review` skill
as a language-specific supplement. Keep this review's scope and severity rubric. What code should
look like instead is the `ehos-app:elixir` skill's, and the application's `docs/elixir.md`.

## 2. The application's lenses

Choose the lenses the changed paths trigger. Each is a section of
[`references/checklist.md`](references/checklist.md) — read that section and mark every item
PASS / FAIL / N/A; each FAIL becomes a finding.

| Lens | Triggered by | Catches |
|---|---|---|
| Contracts | `lib/<app>/domain.ex`, `lib/<app>/contracts/**`, their implementations, their tests | an event the contract does not declare, a command without a test, an invariant without its `rejected` scenario, a published event changed in place, a promise changed without the process owner |
| Credentials | the router, plugs, `by:` in a contract, `EhOsContract.Auth` config | a command reachable without `EhOsContract.Auth.Plug`, a widened `by:`, a test key trusted outside tests |
| `ehos.yaml` and runtime | `ehos.yaml`, `config/runtime.exs`, the endpoint's and the health plug's config | a host, a connection string or a secret in `ehos.yaml`; ports that disagree with it; a variable EHOS does not give |
| Migrations & rollout | `priv/repo/migrations/**`, removed or renamed fields | DDL at run time, a single-deploy drop, a table outside the application's schema, stale references |
| Other applications | Ecto queries, repos, HTTP clients, `publish` in a contract | reading another application's data, a fact shared other than as a published event |
| App conventions | any file | the rules in the nested `AGENTS.md` that governs it |
| How Elixir is written | `.ex` and `.exs` files | a way out without a behaviour, `put_env` in a test, a test hook in production code, a query outside a table's owner, a changeset on a projection, a page doing a context's work, nested `case`/`with` |
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
  exploitable hole (auth bypass, injection, XSS, a command reachable without a credential, another
  application's data read), a 500 on a happy path, silently wrong data, a published event changed
  in place.
  *Not* P0: theoretical races, a user seeing their own data, missing rate limits, UUID-guarded IDOR,
  input the UI never sends.
- **P1** — real but survivable: a UX bug with a workaround, edge-case data bugs, confusing errors,
  perf that profiles but isn't felt, dead code, a new `eh_os_contract.check` finding, stale
  references after a rename, a doc not updated.
- **P2** — style, DRY, hardening, accessibility beyond keyboard, unlikely-path coverage.

## 4. Report

Re-check every P0 against the rubric and deduplicate across agents, then:

```markdown
## Review: <branch> → <base>
<2–3 sentences: what the branch does, and how>
Commits N · files N · lenses … (and why)
### P0 — must fix before merge
### P1 — fix before or right after merge
### P2 — suggestions
### Contracts and rollout
<contracts and published events touched, `ehos.yaml`, migration order — or "none">
### Verdict
<merge-ready | ready after P1 fixes | blocked on P0>
```

## Summary mode

A comprehension map, not a judgement: no severities, no suggestions.

1. ≤10 changed files: read each in full yourself. More: one subagent per directory (`lib/<app>/`,
   `lib/<app>_web/`, `priv/`, `test/`), each reading its files in full at HEAD plus
   `git diff origin/<base>...HEAD -- <file>`, and returning one row per file and its touchpoints
   (a contract's commands and events, the router, the database, Oban, EHOS, external systems).
2. Trace the flow with `ARCHITECTURE.md` as the map.
3. Write:

```markdown
## Changemap: <branch> → <base>
Commits N · files N
### Overall idea
<2–3 sentences a non-engineer can follow: the problem, the capability>
### Key features
- <a capability, not an implementation task>
### Flow
1. trigger → router → credential → contract → implementation → event log → reactions → back
### Files
#### <directory>
| File | Change | What changed | Rule it implements |
```

Leave out directories with no changes. Within one, order files migration → schema → contract →
implementation → context → controller → template. On large branches collapse trivial test- or type-only changes into one row.

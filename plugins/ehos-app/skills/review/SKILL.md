---
name: review
description: Use to review a branch against its base through this application's lenses (contracts, credentials, ehos.yaml, migrations, other applications' data, docs), or with `summary` for a map of what it changes. Not for your own change before its pull request (`ehos-app:pre-pr-review`).
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

## 1. Generic pass

Correctness bugs, reuse and simplification: read the diff as `ehos-app:pre-pr-review`'s
[references/correctness.md](../pre-pr-review/references/correctness.md) says, with this checkout,
the range `origin/<base>...HEAD`, and as the repository's part that skill's
[references/application.md](../pre-pr-review/references/application.md). Carry its findings into
the report after the severity check in step 4. Do not invoke the harness's own reviewer: it reads
the session's directory, and its rules are not this application's. Don't repeat that pass under
the lenses below.

For Elixir changes, also use the `ehos-app:elixir-anti-patterns-review` skill
as a language-specific supplement. Keep this review's scope and severity rubric. What code should
look like instead is the `ehos-app:elixir` skill's, and the application's `docs/elixir.md`.

## 2. The application's lenses

Read [`references/lenses.md`](references/lenses.md): which lenses the changed paths trigger, how
each is applied with its section of [`references/checklist.md`](references/checklist.md), item by
item, and the table the report shows for each.

Small diff (≤3 files, ≤50 lines): do it yourself. Larger: one subagent per lens or per app, if your
harness has them. Give each, verbatim: its lens and checklist section, its exact changed-file list,
"read every file in full at HEAD", and the absolute path of `references/lenses.md` to read for the
table, the format, the anti-drift rules and the severity rubric. When a subagent's report has no
table for its lens, or one that leaves an item of the lens's checklist section unmarked, send it
back once; if the second has none either, apply that lens yourself and say so in the report.

## 3. Findings

Write and grade each finding as [`references/lenses.md`](references/lenses.md) says, in its
sections "Findings" and "Severity".

## 4. Report

Re-check every P0 against the rubric in `references/lenses.md`, "Severity", and deduplicate across
agents, then, with each lens's table under "Lenses":

```markdown
## Review: <branch> → <base>
<2–3 sentences: what the branch does, and how>
Commits N · files N · lenses … (and why)
### P0 — must fix before merge
### P1 — fix before or right after merge
### P2 — suggestions
### Lenses
<one table per lens applied, as `references/lenses.md` shows>
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

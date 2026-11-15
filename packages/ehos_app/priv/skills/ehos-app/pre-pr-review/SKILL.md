---
name: pre-pr-review
description: Use before `gh pr create` or before pushing new commits to an open pull request, when the review gate refuses `gh pr create`, and when the user asks to review a change before it is sent — two parallel reviews, correctness and the application's lenses, every finding settled, `mix precommit` green, the review recorded. Not for someone else's pull request (`ehos-app:review`).
argument-hint: "[base branch, when it is not the PR's or main]"
---

# Reviewing a change before its pull request

Every pull request to this application is reviewed by its author before it is opened. The review
gate, a hook in `.claude/settings.json`, refuses `gh pr create` until the review is recorded for
`HEAD`, and any new commit, amend or rebase leaves the new `HEAD` unrecorded.

Input: $ARGUMENTS (the text after the skill name) — the base branch, when it is neither the open
pull request's base nor `main`.

Read [references/procedure.md](references/procedure.md) now, in full: it is the procedure, step by
step. This file fills in what it leaves to the skill.

## The repository's part

[references/application.md](references/application.md), beside the procedure.

## The two reviews

At step 4, once `mix precommit` has run and what it changed is committed:

- **correctness**: as [references/correctness.md](references/correctness.md) says: each line,
  what was removed, callers and callees, Elixir, the conventions of the root `AGENTS.md` and the
  nested one of every directory the change touches, depth, and reuse and cost. Give the subagent
  that file's absolute path: this skill's own directory, followed by `references/correctness.md`.
  It reads the change itself, and invokes no skill from outside this plugin. The skills below
  come with this plugin, and none is optional.
- **the application's lenses, security and performance**: every lens the changed paths trigger,
  as `ehos-app:review`'s [references/lenses.md](../review/references/lenses.md) lists them,
  applied with its [checklist.md](../review/references/checklist.md). Give the subagent the
  absolute paths of both files: this skill's own directory (Claude Code shows it when the skill
  loads), followed by `../review/references/lenses.md` and `../review/references/checklist.md`.
  Tell it to read them with its file-reading tool and not to invoke `ehos-app:review`, which only
  a user starts: the Skill tool refuses it to a model, and a reviewer refused it has reviewed from
  memory before. Its report has a table for every lens triggered, each item marked PASS, FAIL or
  N/A, as `lenses.md` shows. Then security beyond the lenses (input that reaches a query, a log
  line that carries a person's data or a credential, a secret in the code) and performance (a
  query in a loop, an unbounded read, work in a request that belongs in Oban). For Elixir changes,
  it invokes `ehos-app:elixir-anti-patterns-review` and `ehos-app:elixir` too, and applies the
  "How Elixir is written" lens, with `ehos-app:elixir` for what the code should be. Every finding
  of this review, from a lens or not, is written and graded as `lenses.md` says.

At step 5, the second report has a table for every lens the changed paths trigger, with every item
of that lens's checklist section marked. A report that lacks one, or says it reviewed without the
checklist, is sent back to read the two files and apply the missing lens; if the second report
still lacks it, apply that lens yourself, and say so in the pull request's `## Review`.

## Keeping the review-proven rules

The root `AGENTS.md` has a section, **Review-proven rules**, for the defects reviews of this
application keep finding. When a finding is of a kind an earlier pull request's review found too
(its `## Review` section, or its review threads: `gh pr list --state merged --search "<words>"`),
propose a rule to the user: one bold sentence, then how to apply it, then the pull requests it came
from. Once they agree, add it in the same pull request. A rule is not style, and not a one-off.

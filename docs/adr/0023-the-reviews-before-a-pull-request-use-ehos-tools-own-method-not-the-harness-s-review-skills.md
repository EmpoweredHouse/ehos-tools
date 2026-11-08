---
status: accepted
date: 2026-11-08
decision-makers: [emil]
consulted: []
---

# T-23 · The reviews before a pull request use ehos-tools' own method, not the harness's review skills

## Context and problem statement

`ehos-dev:pre-pr-review` and `ehos-app:pre-pr-review` run two reviews of each change before its
pull request. Until now, the correctness review invoked Claude Code's built-in `code-review`, and
eh-os's security and performance review invoked `engineering:code-review`, a skill of Anthropic's
`engineering` plugin. Both were "optional": a review without one did its work by a list.

On 7 November 2026 ([#845](https://github.com/EmpoweredHouse/ehos-tools/issues/845)) the work on
that issue showed three faults:

- No EHOS repository enables the `engineering` plugin, so every security review ran without its
  skill, and said so as for an optional one.
- The built-in `code-review` and `security-review` read the session's own directory: `code-review`
  diffs against the upstream or `main` there, and `security-review` against `origin/HEAD`, with no
  range and no other checkout. A session in eh-os that reviewed an ehos-tools change got the eh-os
  worktree's diff, or none; a worktree behind `main` showed other people's merged commits as the
  change.
- `security-review` leaves out by design what this repository's list asks for: pins, cookie flags
  and other hardening, workflows, secrets on disk, Markdown, and findings below a confidence
  threshold.

A subagent read both built-in skills once, on 7 November 2026, and recorded their method: separate
angles that find candidates, a concrete failure scenario for each, a verdict on each candidate that
only a line of the code can refute, and a narrow list of what is noise.

## Decision drivers

- A review reads the change it was asked to review, in whichever checkout it is.
- A review checks everything the repository's part lists.
- A missing skill stops the review, rather than passing as optional.
- The method is ours to read, change and review, in the plugin that the repositories pin.

## Considered options

1. **Keep the harness's skills**, with the repository's list checked by hand after them.
2. **Our own method, in the plugin**: two reference files, `correctness.md` (shared by both
   plugins) and `security.md` (ehos-dev's; ehos-app keeps its lenses), written in our words from
   what the built-in skills do well, with the checkout, the range and the repository's list as
   their input.

## Decision outcome

Chosen option: **"Our own method, in the plugin"**, because it is the only one that reads the right
change in every checkout and checks the whole list, and the user chose it.

The procedure gives each review subagent the absolute path of the checkout and the range, and the
subagent runs its git commands as `git -C <checkout>`. Every skill a review invokes comes with the
plugin, and none is optional: a review that cannot invoke one stops and says so. `ehos-app:review`'s
generic pass reads the same `correctness.md`.

### Consequences

- Good, because a review from another repository's session reads the right change, and stops when
  the range shows none.
- Good, because the security review starts from the repository's list, and nothing in its method
  takes an item away.
- Good, because each finding has a scenario and a verdict that a line of the code decides.
- Bad, because improvements to the harness's reviewers do not reach us by themselves: the method
  changes only when someone changes these files.
- Bad, because the harness's reviewers spread finding and checking over many subagents; ours runs
  each review in one subagent, which may find less on a large change.
- Neutral: `correctness.md` has two copies, one per plugin, which `packages/review` holds equal, as
  it holds `procedure.md`.

### Confirmation

- `ProcedureTest` fails when the two copies of `procedure.md` or of `correctness.md` differ.
- `ProcedureTest` fails when a file under `plugins/` names `code-review`, `security-review` or
  `engineering:code-review`.

## Pros and cons of the options

### Keep the harness's skills

- Good, because Anthropic keeps them current, and `code-review` fans out to many subagents.
- Bad, because they read the session's directory, not the change's checkout.
- Bad, because `security-review` excludes much of what the list asks for, and the `engineering`
  plugin is not enabled anywhere.

### Our own method, in the plugin

- Good, because of the drivers above.
- Bad, because we keep it.

## More information

Decided under [#845](https://github.com/EmpoweredHouse/ehos-tools/issues/845), at the user's
request to read the harness's skills once, use them to fix the review, and then stop using them.
[T-17](0017-an-application-s-review-gate-is-ehos-app-s-tasks-a-hook-its-installer-writes-and-a-skill-an-assistant-runs.md)
named `/code-review` for an application's correctness review; this record replaces that part.

Revisit when the harness's reviewers take a checkout and a range, and their rules can be set per
repository.

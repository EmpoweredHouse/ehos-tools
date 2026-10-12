---
name: stage-issue
description: Run a planned piece of work through a GitHub issue, the same way in eh-os, ehos-tools and eh-os-contract — a step of an eh-os stage, the ehos-tools part of one, or a stage of an eh-os-contract programme. Tighten it in the plan before it starts, open the issue with a plain "In short" for anyone and the technical detail after it, record each decision on it as it is made, link every pull request with `Closes #N` or `Part of #N`, and close it with what came of it. Use when starting a step or stage from a plan's status table, when a decision about one is made, when opening its pull request, when it is merged, and when a new plan is written. Not for a decision record, which is `write-adr`, and not for one-off fixes outside a plan, which need no issue.
---

# A planned piece of work as a GitHub issue

A plan is what a session reads first: where the work stands, what comes next, what the next piece
changes. It cannot also hold every decision, CI run, follow-up and rejected option. When this
procedure was first written (6 October 2026), Stage 5's "Status / handoff" in eh-os had grown to 920
of its plan's 1478 lines, and eh-os-contract's `PLAN.md` had passed 11 000 lines. So the record of a
piece of work moves to its issue, and the plan points there.

**One rule keeps the two from drifting: status lives in the plan, reasons live in the issue.** The
plan's table says ☐ / ◐ / ☑ and links the issue and its pull requests; the issue says what was
decided, why, and what showed it works. Copying either into the other makes two versions, and one of
them goes stale.

Below, "a step" is the piece of work a plan's table tracks: a step of a stage in eh-os, a stage of a
programme in eh-os-contract, the ehos-tools part of an eh-os step in ehos-tools.

## First, read what this repository owns

Read `CONTRIBUTING.md` at the root of the repository you are working in: its section "Where the work
is recorded" and the section after it, on how a step goes from its issue to `main`. They are the
repository's half of this procedure, and they win where the two differ. They say:

- where the plan is, what its status table is called, and what one step is called there;
- the issue template, its labels, and the milestone, if the repository has them;
- how a branch is named and how a commit message names the issue;
- when a decision gets a record and where, and when it stays a comment on the issue;
- what the closing comment says, and what happens when the larger unit (a stage, a programme)
  closes, which may be nothing.

If the file or the section is missing, or does not answer one of these, stop and ask the user
rather than taking another repository's answer.

## Steps

1. **Before the step starts, tighten it in the plan.** A step not yet started may be rewritten: say
   in a few lines what it changes, what it depends on and how it ends; drop references that have
   gone stale; move anything that turned out to belong to another step there. Do not touch steps
   already done: history is not rewritten, and steps finished before the repository took this
   procedure keep their rows as they are; the repository says whether they got issues after the
   fact.
2. **Open the issue** from the repository's template, with its labels and milestone. Open it when
   the step starts, not all at once when the plan is written: a step not yet started may still be
   rewritten, split or dropped. The title names the change, not the step: "Applications generated
   from the template sign people in", not "Stage 9, step 7". The step's code and its place in the
   plan go in the first line of the body.
3. **Mark the start in the plan:** ◐ and the issue in the step's row, in the step's first commit.
   Name the branch and end every commit message as the repository says, so `git blame` leads from
   a line to the issue. A code comment that cites the step cites the issue too.
4. **Record each decision on the issue when it is made**, as a comment: what was decided, the
   options that lost and why, and who decided — the user, or the assistant on a mechanical
   question. Not at the end, from memory. A decision past the repository's threshold for a record
   gets its record first, written the way the repository says, and the comment links it; the issue
   lists the records it wrote under its own heading.
5. **Each pull request of the step says what it belongs to in its first line**: `Closes #N` on the
   one that finishes the step, `Part of #N` on any before it, and `owner/repo#N` for an issue in
   another repository. If the step ends without such a pull request, close the issue by hand after
   the closing comment. When the review of a pull request is recorded (`ehos-dev:pre-pr-review`), what each
   review found and what happened to each finding go on the issue as a comment too, with the
   follow-ups filed.
6. **When the step is merged:** ☑ and the pull requests in the plan's row, and whatever the plan
   keeps beside its table that names the next step brought up to date; a closing comment on the
   issue with what came of the step — what changed for whoever uses what the repository makes, what
   showed it (tests, CI runs, a command and its output), and what was left and where (follow-ups by
   number). Check the issue is closed; a comment alone does not close it.
7. **When the larger unit closes**, do what the repository says it does then, and nothing it does
   not say. In eh-os, for example, the stage's evidence record is written from its milestone's
   closing comments, the milestone is closed, and the roadmap names the next stage.

## How an issue reads

An issue has two readers, and both read the same issue: someone outside the team, not necessarily
technical, who wants to know what goes wrong and what changes, and an engineer who will build or
review it. Neither part is cut down for the other.

- **"In short" first, for anyone.** What goes wrong today or what is missing, for whom, with one
  example (an application, a person signing in, an operator deploying, a clinic using a contract),
  and what will be different once the step is done. No module or function names, codes or file
  paths in this section; a reader who stops here knows what the step is for.
- **The technical part has no such limit.** Modules, files, endpoints, records, refusal and rule
  codes, the order of the work — whatever an engineer needs. A code still never stands alone: its
  meaning first, then the code, linked where it has a page: "a sign-in lasts at most 12 hours
  ([D-66](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0066-pkce-stays-required-and-the-conformance-gate-runs-the-basic-modules-with-private-key-jwt.md))",
  "a reaction to another context's event that leaves delivery out (X10)". Line numbers stay out;
  they go stale before the issue closes.
- **Concrete over abstract.** "Two contracts could record events that look identical in the log"
  beats "improves identity guarantees". A number, a name or an example beats an adjective.
- **Scope as two short lists:** what is in, and what is deliberately out, with why for each "out".
- **Done when, as something checkable:** a test that passes, a page that shows something, a command
  and what it prints, a warning or a refusal, a CI job.
- **Plain writing.** The problem before the solution, active voice, direct verbs, sentences that
  each say one thing. No filler ("leverage", "robust", "seamless", "it's worth noting"), no "not X
  but Y" constructions, no colon reveals, no bold scattered mid-sentence, no closing summary. Where
  the `no-ai-slop` skill is installed, run its detect mode on a draft when in doubt.
- **Decisions in the same plain form:** "We chose A. B would have meant …; C would have meant …."
- **In English**, like everything else these repositories leave on GitHub.

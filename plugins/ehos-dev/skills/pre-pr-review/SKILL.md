---
name: pre-pr-review
description: Review your own change to eh-os, ehos-tools or eh-os-contract before its pull request is opened, or before new commits are pushed to one — two reviews run in parallel, /code-review for correctness and one for security and performance, every finding settled, the repository's checks passed and the review recorded where the repository's gate looks for it. Use whenever you are about to run `gh pr create`, when a hook refuses `gh pr create` because HEAD has not been reviewed, and when the user asks to review a change before it is sent. Not for reviewing someone else's pull request.
---

# Reviewing a change before its pull request

Every pull request to eh-os, ehos-tools and eh-os-contract is reviewed by its author before it is
opened: run two reviews in parallel, settle what they find, prove it, record it. Each repository has
a Claude Code hook that refuses `gh pr create` until the review is recorded for `HEAD`, and any new
commit, amend or rebase leaves the new `HEAD` unrecorded.

## First, read what this repository owns

Read `.claude/review.md` at the root of the repository the change is in
(`git rev-parse --show-toplevel`). It is the repository's half of this procedure, and wins where the
two differ. Its sections, by heading:

- **Recording the review**: the command that records it, what the hook refuses and what it cannot
  see.
- **Documentation alone**: exactly which changes count as documentation alone here.
- **Security and performance**: what the second review looks at in this repository.
- **The checks**: what must pass before the review is recorded.
- **Verifying for real**: what the tests cannot see here, and how to see it.
- **A finding skipped**: how a skipped finding is filed.
- **The pull request**: what its description must say, and the repository's rules for opening it.
- **Before a fix**: anything the repository asks before a finding is fixed. It may be empty.
- **What reviews of this repository keep finding**: the traps already paid for.

If the file is missing, or a section the step needs is, stop and ask the user rather than taking
another repository's answer.

## Steps

1. **Commit everything.** The review reads committed history, and the record covers one commit.
2. **Rebase onto the current `origin/main`** (`git fetch origin && git rebase origin/main`), so the
   review covers only this change.
3. **Documentation alone?** If the change is documentation alone as "Documentation alone" defines
   it (check with `git diff --stat origin/main..HEAD`), neither review has code to read: check the
   documentation's claims against the code instead, say in the pull request how, and go to step 7.
   The hook still asks for the record.
4. **Review the exact range with two reviews, in parallel.** They look for different things, and
   on the change where both were first run (eh-os's Stage 4, step 8a, 27 September 2026) neither
   found what the other did: `/code-review` found that `up` reported a cluster from before D-45 as
   serving HTTPS and that a kubectl warning broke the CA's base64; the security-and-performance pass
   found plain HTTP still served with a session cookie not marked `Secure`, and a CA that could
   vouch for any name. Start both as subagents in one message (the Agent tool, two calls), each told
   to report findings and change nothing, and to read "What reviews of this repository keep
   finding" in `.claude/review.md` and look for those on purpose:
   - **correctness**: invoke the `code-review` skill with `high origin/main..HEAD`: bugs, removed
     guards, callers, reuse, simplification, altitude, and the conventions of the repository's
     `AGENTS.md`, `CLAUDE.md` and `CONTRIBUTING.md`;
   - **security and performance**: invoke the `engineering:code-review` skill on the same range,
     naming "security and performance" as the focus and the list in "Security and performance".
     Without that plugin, the subagent reviews against the list itself.
5. **Pool what both return, drop duplicates, and settle every finding** as one of:
   - **fixed**: a real problem. Fix it in its own commit, with a message stating the failure
     scenario, and a test that fails on the old code. Check that it does in reverse: revert the fix
     and watch that test, and no other, go red. The mutation has to apply in full: a substitution
     that matches half of a change, or a Perl pattern that interpolates `@module_attribute` as an
     empty array, breaks the code rather than undoing the fix, and whatever fails then proves
     nothing. Check the mutated file's diff.
   - **no change needed**: the finding is wrong. Write down why in one sentence.
   - **skipped**: real but out of scope, or of low weight. File it as "A finding skipped" says,
     rather than a branch of its own, and say so in the pull request, with why.

   Follow "Before a fix" first, where it asks something. Where the session has the ReportFindings
   tool, report the outcomes with it (`fixed` / `no_change_needed` / `skipped`); the pull request's
   Review section records them in any case.
6. **Review the fixes the same way.** A fix is a change like any other: the commits that fix
   findings go through both reviews before the pull request is opened. On eh-os's step 8a the
   second round found that the first fix for plain HTTP made every request loop behind a proxy that
   ends TLS in front of the Ingress. **Two rounds are the most:** what the second finds beyond a
   defect in those fixes is skipped and filed.
7. **Pass "The checks"**, checking each command's own exit code, never `tail`'s:
   `out=$(<command> 2>&1); rc=$?; echo "$out" | tail -30; echo $rc`.
8. **Verify for real** what the unit tests cannot see, as "Verifying for real" says. Note what you
   ran and what you saw.
9. **Record the review** as "Recording the review" says. Uncommitted changes are not covered, so
   `git status --porcelain` must print nothing first.
10. **Open the pull request** as "The pull request" says. Its "How it was tested" section says what
    you ran; its Review section lists what each of the two reviews found and what happened to each
    finding, or says the change is documentation alone. For a step run through an issue
    (`ehos-dev:stage-issue`), the same list goes on the issue as a comment, with the follow-ups
    filed.

## After the pull request is open

After review comments or a failed CI run, fix, commit, and go through steps 4–9 again, both reviews
included, for the new commits before pushing them. The hook guards only the command that opens a
pull request, not later pushes: this part is yours to keep.

Before any push to an existing pull request, check it is still open: a commit pushed to a merged
pull request's branch never reaches `main`. Test the state itself, since `gh pr view` exits 0 for a
merged pull request too:

```bash
[ "$(gh pr view <number> --json state --jq .state)" = OPEN ] && git push
```

## Keeping the list

When a review finds a new kind of problem, add it to "What reviews of this repository keep finding"
in `.claude/review.md`, in the same pull request. A rule about the code itself belongs where the
repository keeps its code rules (`AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`); the list keeps what a
reviewer should look for.

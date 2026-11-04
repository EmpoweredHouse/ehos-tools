# The procedure

How a change is reviewed before its pull request: run two reviews in parallel, settle what they
find, prove it, record it. `ehos-dev:pre-pr-review` and `ehos-app:pre-pr-review` both follow it.
Each plugin is installed alone, so each carries a copy of this file; ehos-tools' `packages/review`
holds the two copies equal.

The skill that sent you here fills in two things:

- **The repository's part**: a file whose sections, by heading, say what this procedure leaves to
  the repository. A step that names a section reads it there. Where the part has no "The base",
  the base is `main`; any other section a step needs and the part lacks: stop and ask the user
  rather than taking another repository's answer.
- **The two reviews**: what each looks for, which skills each invokes, which of those are
  optional, and what its report holds.

## Steps

1. **Commit everything.** The review reads committed history, and the record covers one commit.
2. **Find the base.** The open pull request's (`gh pr view --json baseRefName`), or the one the
   part's "The base" names: a stacked change is reviewed against its parent branch. Before the
   branch is first pushed, rebase onto it (`git fetch origin && git rebase origin/<base>`), so the
   review covers only this change. Once it is pushed, rebasing rewrites what others may have, so
   merge the base instead (`git fetch origin && git merge origin/<base>`), or ask the user; never
   force-push on your own.
3. **Documentation alone?** If the change is documentation alone as the part's "Documentation
   alone" defines it (check with `git diff --stat origin/<base>..HEAD`), neither review has code to
   read: check every claim the documentation makes against the code instead, say in the pull
   request how, and skip steps 4 to 7. "The checks" still run where they cover what the change
   touches, and the gate still asks for the record.
4. **Review the exact range with the two reviews, in parallel.** They look for different things,
   and each misses what the other finds. Start both as subagents in one message, each told to
   report findings and change nothing, to read every changed file in full at `HEAD`, and to read
   the part's "What reviews of this repository keep finding" and look for those on purpose. Each
   is also told to invoke its skills through the Skill tool, never to do a skill's work from what
   it remembers of it, and to open its report with the skills it invoked and any it could not.
5. **Check each report** before settling anything. A report that does not name each skill the
   skill file gives its review, without saying the session lacks it, did that part from memory;
   one that lacks what the skill file says its report holds has not done that review. Send that
   subagent back, once, for both at once. When a review says it could not invoke a skill, try it
   yourself: if that works, the subagent lacked the Skill tool, so run that review again with it.
   If this session does not know it either: a skill the skill file names as optional is done
   without, as it says, and the pull request says so; any other means its plugin did not load, or
   the session holds an older version of it (`/reload-plugins` or a restart takes the one
   settings name): tell the user, and in a run with no user, stop and report it.
6. **Pool what both return, drop duplicates, and settle every finding** as one of:
   - **fixed**: a real problem. Fix it in its own commit, with a message stating the failure
     scenario, and a test that fails on the old code. Check that it does in reverse: undo the fix in
     the working tree alone, committing nothing, run the test's file, and watch that test fail for
     the defect the fix removes (at its assertion, or by raising the error the finding names), not
     at an error the mutation itself brings (a compile failure, a half-applied substitution), and
     any other in it that fails do so for the same defect. Where the test calls something the fix
     adds, keep that, and undo only the behaviour. Then restore it (`git restore <files>`), and
     check that `git status --porcelain` prints nothing. The mutation has to apply in full: a
     substitution that matches half of a change, or a Perl pattern that interpolates
     `@module_attribute` as an empty array, breaks the code rather than undoing the fix, and
     whatever fails then proves nothing. Check the mutated file's diff, or mutate with a tool that
     does not interpolate.
   - **no change needed**: the finding is wrong. Write down why in one sentence.
   - **skipped**: real but out of scope, or of low weight. File it as the part's "A finding
     skipped" says, and say so in the pull request, with why.

   Follow the part's "Before a fix" first, where it asks something. Where the session has the
   ReportFindings tool, report the outcomes with it (`fixed` / `no_change_needed` / `skipped`);
   the pull request's Review section records them in any case.
7. **Review the fixes the same way.** A fix is a change like any other: the commits that fix
   findings go through both reviews before the pull request is opened. **Two rounds are the
   most:** what the second finds beyond a defect in those fixes is skipped and filed.
8. **Pass "The checks"**, checking each command's own exit code, never `tail`'s:
   `out=$(<command> 2>&1); rc=$?; echo "$out" | tail -30; echo $rc`.
9. **Verify for real** what the tests cannot see, as "Verifying for real" says. Note what you ran
   and what you saw.
10. **Record the review** as "Recording the review" says. Uncommitted changes are not covered, so
    `git status --porcelain` must print nothing first.
11. **Open the pull request** with the `pull-request` skill of the same plugin, as "The pull
    request" says, once the user has asked for the pull request. If they asked for the review
    alone, stop after step 10 and ask. Its section on testing says what you ran; its Review section names the skills
    each review invoked, and lists what each of the two reviews found and what became of each
    finding, or says the change is documentation alone. The skill also puts that list on the
    issue, where the work runs through one.

## After the pull request is open

After review comments or a failed CI run, fix, commit, and go through steps 4 to 10 again, both
reviews included, for the new commits before pushing them, and add what they found to the
description's Review section. The gate guards only the command that opens a pull request, not
later pushes: this part is yours to keep.

Before any push to an existing pull request, check it is still open: a commit pushed to a merged
pull request's branch never reaches its base. Test the state itself, since `gh pr view` exits 0
for a merged pull request too:

```bash
[ "$(gh pr view <number> --json state --jq .state)" = OPEN ] && git push
```

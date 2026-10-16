---
name: pre-pr-review
description: Review your own change to this application before its pull request is opened, or before new commits are pushed to one — two reviews run in parallel, /code-review for correctness and one through the application's lenses and for security and performance, every finding settled, `mix precommit` passed, and the review recorded with `mix ehos_app.review record`, which the review gate looks for. Use whenever you are about to run `gh pr create`, when a hook refuses `gh pr create` because HEAD has not been reviewed, and when the user asks to review a change before it is sent. Not for reviewing someone else's pull request; that is `ehos-app:review`.
argument-hint: "[base branch, when it is not the PR's or main]"
---

# Reviewing a change before its pull request

Every pull request to this application is reviewed by its author before it is opened: run two
reviews in parallel, settle what they find, prove it, record it. The review gate, a hook in
`.claude/settings.json`, refuses `gh pr create` until `mix ehos_app.review record` has marked
`HEAD`, and any new commit, amend or rebase leaves the new `HEAD` unmarked. Where the pull request
lands, the `review` workflow fails it while its description has no `## Review` section that says
something.

Input: $ARGUMENTS (the text after the skill name) — the base branch, when it is neither the open
pull request's base nor `main`.

## Steps

1. **Commit everything.** The review reads committed history, and the mark covers one commit.
2. **Find the base.** The open pull request's (`gh pr view --json baseRefName`), the one the input
   or an approved plan names, or `main`: a stacked change is reviewed against its parent branch,
   not `main`. Before the branch is first pushed, rebase onto it
   (`git fetch origin && git rebase origin/<base>`), so the review covers only this change. Once it
   is pushed, rebasing rewrites what others may have, so merge the base instead
   (`git merge origin/<base>`), or ask the user; never force-push on your own.
3. **Documentation alone?** A change to Markdown files alone (`*.md`: the docs, the nested
   `AGENTS.md`, `VISION.md`) and nothing else — no code, config, migration, `ehos.yaml`, workflow,
   `.claude/` or dependency — is documentation alone (check with
   `git diff --stat origin/<base>..HEAD`). Neither review has code to read: check every claim the
   documentation makes against the code instead, say in the pull request how, and skip steps 4 to
   6. `mix precommit` still runs (the harness test reads the docs), and the gate still asks for the
   mark.
4. **Review the exact range with two reviews, in parallel.** They look for different things, and
   each misses what the other finds. Start both as subagents in one message, each told to report
   findings and change nothing, to read every changed file in full at `HEAD`, and to read the
   **Review-proven rules** in the root `AGENTS.md` and look for those on purpose:
   - **correctness**: invoke the `code-review` skill with `high origin/<base>..HEAD`: bugs,
     removed guards, callers, reuse, simplification, and the conventions of the root `AGENTS.md`
     and the nested one of every directory the change touches. Without that skill (a harness other
     than Claude Code), the subagent reads the diff for correctness itself.
   - **the application's lenses, security and performance**: the lenses of the `ehos-app:review`
     skill, from its [SKILL.md](../review/SKILL.md), sections 2 and 3, with its
     [checklist](../review/references/checklist.md): contracts, the credential in front of every
     command, `ehos.yaml` and runtime, migrations that run before the release starts, other
     applications' data, docs in the same PR. Then security beyond them (input that reaches a
     query, a log line that carries a person's data or a credential, a secret in the code) and
     performance (a query in a loop, an unbounded read, work in a request that belongs in Oban).
     For Elixir changes, the `ehos-app:elixir-anti-patterns-review` skill too. Its severity rubric
     is `ehos-app:review`'s.
5. **Pool what both return, drop duplicates, and settle every finding** as one of:
   - **fixed**: a real problem. Fix it in its own commit, with a message stating the failure
     scenario, and a test that fails on the old code. Check that it does: revert the fix, run the
     test's file, and watch that test go red, then restore the fix.
   - **no change needed**: the finding is wrong. Write down why in one sentence.
   - **skipped**: real but out of scope, or of low weight. File it as an issue, and say so in the
     pull request, with why.

   A change to a command's name, fields or `by:`, to a publication or to a promise needs the
   process owner's agreement: ask the user before making it, whatever a review says. Where the
   session has the ReportFindings tool, report the outcomes with it (`fixed` /
   `no_change_needed` / `skipped`); the pull request's `## Review` section records them in any
   case.
6. **Review the fixes the same way.** A fix is a change like any other: the commits that fix
   findings go through both reviews before the pull request is opened. **Two rounds are the
   most:** what the second finds beyond a defect in those fixes is skipped and filed.
7. **Pass the gate**, checking its own exit code, never `tail`'s:
   `out=$(mix precommit 2>&1); rc=$?; echo "$out" | tail -30; echo $rc`. `mix precommit`
   formats files, so commit what it changed, and run it again until it changes nothing.
8. **Verify for real** what the tests cannot see: a page in the browser, a request to `/api` with
   a credential, a migration against a database with data. Note what you ran and what you saw.
9. **Record the review**: `git status --porcelain` must print nothing first, then
   `MIX_ENV=dev mix ehos_app.review record`. `ehos_app` is a dependency in `:dev` alone.
10. **Open the pull request** as a draft, from a checkout of its branch, without `--head`,
    `--repo` or `GH_REPO`, which the gate refuses: `gh pr create --draft --base <base>`, its body
    in a file. Fill the repository's template (`.github/pull_request_template.md`): "How to test"
    says what you ran; `## Review`, the last section, lists what each of the two reviews found and
    what became of each finding, or says the change is documentation alone. A human tests it and
    makes it ready (`ehos-app:ship`).

## After the pull request is open

After review comments or a failed CI run, fix, commit, and go through steps 4–9 again, both
reviews included, for the new commits before pushing them, and add what they found to the
description's `## Review` section. The gate guards only the command that opens a pull request, not
later pushes: this part is yours to keep.

Before any push to an existing pull request, check it is still open: a commit pushed to a merged
pull request's branch never reaches its base. Test the state itself, since `gh pr view` exits 0
for a merged pull request too:

```bash
[ "$(gh pr view <number> --json state --jq .state)" = OPEN ] && git push
```

## Keeping the review-proven rules

The root `AGENTS.md` has a section, **Review-proven rules**, for the defects reviews of this
application keep finding. When a finding is of a kind an earlier pull request's review found too
(its `## Review` section, or its review threads: `gh pr list --state merged --search "<words>"`),
propose a rule to the user: one bold sentence, then how to apply it, then the pull requests it came
from. Once they agree, add it in the same pull request. A rule is not style, and not a one-off.

---
name: pre-pr-review
description: Review your own ehos-tools change with two reviews run in parallel — /code-review for correctness, and one for security and performance (engineering:code-review where it is installed) — fix what they find and record the review, before opening a pull request or pushing new commits to one. Use whenever you are about to run `gh pr create`, when a hook refuses `gh pr create` because HEAD has not been reviewed, and when the user asks to review a change before it is sent. Not for reviewing someone else's pull request.
---

# Reviewing a change before its pull request

Every ehos-tools pull request is reviewed by its author before it is opened: run two reviews in
parallel, fix what they find, prove it, record it. A Claude Code hook (`.claude/settings.json`)
enforces the last step: `gh pr create` is refused until `mix review record`, run in
`packages/review`, has marked `HEAD` as reviewed, and any new commit, amend or rebase clears the
mark.

Skip the review only for a change to documentation alone, and say so in the pull request. The
hook still asks for the mark: record it once you have checked the change is documentation only.

## Steps

1. **Commit everything.** The review reads committed history, and the mark covers one commit.
2. **Rebase onto the current `origin/main`** (`git fetch && git rebase origin/main`), so the
   review covers only this change.
3. **Review the exact range with two reviews, in parallel.** They look for different things. On
   EHOS's step 8a of Stage 4 (27 September 2026), where this skill comes from, neither found what
   the other did. Start both as subagents in one message (the Agent tool, two calls), each told to
   report findings and change nothing:
   - **correctness**: invoke the `code-review` skill with `high origin/main..HEAD`: bugs, removed
     guards, callers, reuse, simplification, altitude, `AGENTS.md` and `CONTRIBUTING.md`
     conventions;
   - **security and performance**: invoke the `engineering:code-review` skill on the same range,
     naming "security and performance" as the focus: secrets and tokens (in CI, in a Dockerfile,
     in what a generated project commits), trust in fetched code and pins (a tag can move, a
     commit cannot), what a generated application serves and which cookies, authentication and
     sign-in, unbounded work, work repeated on every run of the installer. Without that plugin,
     the subagent reviews against this list itself.

   Pool what both return, drop duplicates, and settle the pool. A fix is a change like any other:
   review the commits that fix findings the same way, with both reviews, before the pull request
   is opened. Two rounds are the most: what the second finds beyond a defect in those fixes is
   filed as a follow-up.
4. **Settle every finding** as one of:
   - **fixed**: a real problem. Fix it in its own commit, with a message stating the failure
     scenario, and add a test that fails on the old code. Check that it does, for example by
     reverting the fix and running the test.
   - **no change needed**: the finding is wrong. Write down why in one sentence.
   - **skipped**: real but out of scope, or of low weight. File it as a GitHub issue labelled
     `follow-up` rather than a branch of its own, and say so in the pull request, with why.

   Where the session has the ReportFindings tool, report the outcomes with it (`fixed` /
   `no_change_needed` / `skipped`); the pull request's "Review" section records them in any case.
5. **Pass `mix check` in every package the change touches**, checking its own exit code:
   `out=$(mix check 2>&1); rc=$?; echo "$out" | tail -30; echo $rc`. Run `ehos_app`'s from a
   checkout whose path has no dot directory (`AGENTS.md`, "Traps already found").
6. **Verify for real** anything the unit tests cannot see. A change to `ehos_app` generates a
   project and runs its `mix precommit`; a change to `ehosctl` builds the binary and runs
   `init` with it (`AGENTS.md`, "Trying a change end to end"). Note what you ran and what you saw.
7. **Record the review:** `cd packages/review && mix review record`. It refuses while changes are
   uncommitted.
8. **Open the pull request** from the reviewed checkout, with the body in a file
   (`gh pr create --body-file <file>`): the gate reads the command's arguments, and refuses a body
   written inline that happens to name `--head` or `--repo`. Its "How it was tested" section
   says what you ran. Its `## Review` section lists what each of the two reviews found and what
   happened to each finding (for documentation alone, it says so): CI's `review section` check
   fails while the section is missing or empty, and runs again when the description is edited.

After review comments or a failed CI run, fix, commit, and go through steps 3–7 again, both
reviews included, for the new commits before pushing them. The hook guards only the command
that opens a pull request (`gh pr create` or `gh pr new`), from the checkout it runs in, and
refuses one that names another branch or repository (`--head`, `--repo`), or that commits,
checks out or rebases before it opens the pull request: commit, record, then open it on its own.
It does not see a push to an open pull request, or one opened through the API: this part is
yours to keep. It also refuses, while `HEAD` is unreviewed, any other Bash command that names the
one that opens a pull request, a `grep` included, and, whatever `HEAD` is, a `git commit` whose
message names it; write such text through a file (`git commit -F <file>`).

## What reviews of this repository keep finding

Look for these on purpose; each one has already happened here.

**The installer (`packages/ehos_app`)**

- A second run changes nothing. A file the developer owns is written once (`write_rendered/3`,
  never `Igniter.create_new_file/4` with `on_exists: :skip`, which overwrites a file Igniter has
  not read yet), and what the developer removed or declined is never brought back: a declined
  design system, a moved sign-in link, a tuned daisyUI theme.
- A project from an earlier version is a separate case from a new one, with its own test: what it
  already has (a migration that went to an earlier version, a workflow from 0.2, a package on a
  commit no version pinned) decides what the run adds. Test the project moved by hand before the
  run as well as the one left as it was.
- Code is read as code. A regular expression over source matched a call in a comment and missed
  one split over lines; parse it (`Code.string_to_quoted/2`) instead, and say what a file that
  does not parse means.
- Supervision order is what Igniter makes of it, not what the call suggests: it inserts after the
  child that follows the last `after:` match. Check the generated `application.ex`, and that the
  endpoint starts last.
- A literal the project wrote that defeats the change (`secure: false`) is replaced; an expression
  of its own stays.
- A notice says what the developer has to do, in words that match what the run did.

**Pins and releases**

- A dependency from GitHub is pinned to a commit, with the tag it carries in a comment: a tag can
  move. The one exception is eh-os-contract, which a generated project follows by `branch: "main"`
  until it tags 0.3.0
  ([T-05](../../../docs/adr/0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)); it
  is not a precedent for another dependency. The toolchain, archives and installer version are pinned in
  `packages/ehosctl/lib/ehosctl/template.ex` alone.
- A change to what the installer writes is an `ehos_app` version; a release of `ehos_app` is a
  release of `ehosctl` once `template.ex` points at it. Unreleased fixes do not reach anyone who
  installs a binary.
- Every repository a generated project reads that is private (`eh-os-contract`, this one) is
  readable in its CI workflow and through its Dockerfile's build secret.

**Docs and messages**

- Documentation says what the code does. A commit message that claims a fix the code makes only
  in part costs the next round; the review compares the two.
- A changelog line describes the change for a reader of the package, under `Unreleased`, wrapped
  at 100 columns.
- No local paths, and links to other repositories by their GitHub URL.

**Elixir and tooling**

- `Regex.replace/3` with a string replacement reads `\1` followed by digits as a larger group
  number: when the inserted text can start with a digit, replace with a function.
- A test that writes to the filesystem does it under its own `tmp_dir`; a test of the installer
  runs on `Igniter.Test.phx_test_project/1`, and a CLI test reads the steps a command would run.
- Burrito binaries reuse an unpacked payload for their version: an end-to-end check after a
  rebuild without a version bump runs `maintenance uninstall` first, or it tests the old code.

Add to this list when a review finds a new kind of problem.

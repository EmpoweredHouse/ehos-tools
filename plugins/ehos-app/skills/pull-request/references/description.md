# Writing and opening the pull request

Every pull request in eh-os, ehos-tools, eh-os-contract and an application generated from
`ehos_app` has the same sections, in the same order:
[pull_request_template.md](pull_request_template.md), beside this file. `ehos-dev:pull-request`
and `ehos-app:pull-request` both follow this file. Each plugin is installed alone, so each carries a
copy of both files; ehos-tools' `packages/review` holds the copies equal, and equal to the template
ehos-tools and `ehos_app` write into `.github/pull_request_template.md`.

The skill that sent you here says where the repository's part is: its section "The pull request"
says the base, whether the pull request opens as a draft, the form of the title, the sections the
repository adds and where, and the lines its checks read. Where the part says something different
from this file, the part wins.

## Before you start

1. **Check that the review is recorded for `HEAD`.** The `pre-pr-review` skill of the same plugin
   reviews the change and records it. If it has not run on this commit, run it first: the review
   gate refuses to open a pull request from a commit it has not recorded.
2. **Collect what the description needs**:
   - the issue, and its "In short", where the work runs through one;
   - the commits and the files: `git log --oneline origin/<base>..HEAD` and
     `git diff --stat origin/<base>..HEAD`;
   - what each review found and what became of each finding;
   - the commands you ran, with their exit codes, and what you saw by hand.

## The order: top-down

Each section is for a reader who knows less than the reader of the section after it. A person who
stops after "Risks and consequences" knows what the change does, why it is good, and what it can
cost. A reviewer reads on, for the code, the decisions and the evidence.

## The language

Write every sentence of the description in Simplified Technical English (ASD-STE100). Where the
session has `ehos-dev:voice`, it has the full rules and the words of each glossary. The rules that
matter most here:

- One fact in one sentence, 25 words or fewer.
- The active voice, with who does the action: the person, the application, CI, the installer.
- The simple word: "use", not "utilize"; "start", not "initiate"; "make sure", not "ensure".
- The condition first: "If the token has expired, `ehosctl` asks for a new sign-in."
- No more than three nouns in a cluster.
- Numbers as digits, with the unit: "2 minutes", "3 files".
- No "simply", "just", "easy", "obviously", no idioms, no emoji.
- Do not tell how the work went. Say what the change does.

"In short" has one more rule: no module or function names, file paths, codes or issue numbers. Use
the words of the people who use the thing.

## The sections

### The first line

`Closes #N` on the pull request that finishes an issue's work, `Part of #N` on an earlier one,
`owner/repo#N` for an issue in another repository, or `No issue: <why>`. The repository's part can
add more, such as the step of a plan.

### In short

Four items, one or two sentences each:

- **Problem:** what goes wrong now, or what is missing, and for whom.
- **Fix:** what is different after the merge.
- **How:** the method, in words a person who does not read the code understands.
- **Benefit:** what the person gets: less time, fewer errors, a thing they can now do.

```markdown
- **Problem:** A developer who signs in with an expired token sees "unauthorized", with no
  reason and no next step.
- **Fix:** `ehosctl` tells the developer that the sign-in has expired, and how to sign in again.
- **How:** `ehosctl` reads the reason that EHOS gives for a refusal, and prints a message for it.
- **Benefit:** The developer knows what to do from the message, without help from the team.
```

A command a person types, such as `ehosctl login`, is a word of that person, not a code.

### Before and after

One example that shows the change. Use the strongest evidence that the change permits:

1. **A screenshot**, when the change is visible in a browser or a terminal and the session can
   take one.
2. **A command and its output, or a test that failed and now passes**, in code blocks.
3. **A diff-sketch** of what a person writes or gets, when the change has no output to show.

````markdown
**Before:**

```text
$ ehosctl apps
error: unauthorized
```

**After:**

```text
$ ehosctl apps
Your sign-in has expired. Run `ehosctl login`.
```
````

Show one example. Two examples are correct only when the change has two different effects.

### Risks and consequences

- **Can it be undone:** If a revert of the merge restores the old state, write "Yes, a revert
  undoes it." If the change has an effect that a revert does not remove, write "No", and the effect.
  Examples: data that a migration writes or drops, a tag or a release that is published, a file
  that the installer writes into applications, a message that is sent.
- **What it can break, and for whom:** the people and the systems that use what changed, and what
  they see if the change is wrong. Examples: the developers of generated applications, CI of
  eh-os, an operator who installs EHOS, the users of an application.
- **What a user must do:** "Nothing", or the step: run a migration, move a pin, edit a file,
  sign in again.

Write "None" only when you checked. A change that every caller reads has a large reach, also if
the diff is small.

### What

For the reviewer: what the change does in the code. Use the smallest view that makes the change
clear, next to the sentence that it supports:

- **Pseudocode** for logic.
- **A call tree** for the order of calls at run time.
- **A file tree** for the files that the change adds, moves or removes.
- **A component tree** for a page, with the state that matters.
- **A Mermaid diagram** for an exchange between two or more parts.
- **A diff-sketch** when the shape already exists and the point is what changes in it:

```diff
 ehosctl apps
   Ehosctl.Config.installation()
   Ehosctl.Http.get("/api/applications")
+  Ehosctl.Output.refusal(reason)
```

Show a whole block only when most of it is new, or when the reviewer needs the exact final shape.
Keep only the calls, files and states that the point needs. One or two views are usually enough.
Then say where the reviewer must look with most attention, and why.

### Why

The decisions that the change makes, the options that lost and why, and their links: the issue,
the decision record, the discussion. "In short" has the problem; do not say it again. If the change
makes no decision, write the link to the issue that asked for it.

### How it was tested

- **Automated:** the tests that the change adds or changes, by name, and the gate that ran
  (`mix check`, `mix precommit`), with its exit code.
- **By hand:** the exact steps and what you saw at each step. If the change needs no check by hand,
  say why.

### Review

What each of the two reviews of the `pre-pr-review` skill found, with the skills that each review
used, and what became of each finding: fixed, no change needed (with why), or skipped (with the
follow-up issue). For documentation alone, say so, and say how you checked each claim against the
code. CI's `review section` check fails while this section is empty.

### The sections that the repository adds

Put them where the repository's part says. Do not add a section that the part does not name.

## Before you open it

- [ ] The first line names the issue, or says `No issue:` and why.
- [ ] Each section has text, and the comments of the template are removed.
- [ ] "In short" has no module names, file paths, codes or issue numbers.
- [ ] "Before and after" has one concrete example, not a description of one.
- [ ] Each item of "Risks and consequences" has an answer.
- [ ] Each sentence has 25 words or fewer and says one fact.
- [ ] The lines that the repository's checks read are there (in ehos-tools, `No changelog:`).

## Open it

1. Write the description to a file outside the repository, such as the session's scratchpad. The
   review gate reads the arguments of the command, so the body never goes inline.
2. Write the title as one sentence that says what changes for its reader, in the form that the
   repository's part gives.
3. Open the pull request from the checkout of its branch, in a command of its own:

   ```bash
   gh pr create --base <base> --title "<title>" --body-file <file>
   ```

   Add `--draft` where the repository's part says so. Do not add `--head`, `--repo` or `GH_REPO`,
   and do not commit, check out or rebase in the same command: the gate refuses each of these.
4. Where the work runs through an issue, put what the reviews found on the issue as a comment, with
   the follow-ups filed.

## After new commits

New commits are reviewed before they are pushed (`pre-pr-review`, "After the pull request is
open"). Then change the sections that the commits change, usually "What", "How it was tested" and
"Review", in the same file, and update the pull request:

```bash
gh pr edit <number> --body-file <file>
```

CI's `review section` check runs again when the description changes.

## Credits

"Before and after", "Risks and consequences" (a one-way or a two-way door, and how far a mistake
reaches) and the views of "What" come from the `pr` skill of
[mattpocock/skills](https://github.com/mattpocock/skills), by Matt Pocock (MIT). Its views come from
the `show-me` skill of [HumanLayer](https://github.com/humanlayer/skills), by Dex Horthy. This file
says them again in its own words.

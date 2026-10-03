---
status: accepted
date: 2026-10-03
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-03 · CI checks that a pull request's description records its author's review

## Context and problem statement

Every pull request to ehos-tools is reviewed by its author first, with two reviews, and their
findings settled (`.claude/skills/pre-pr-review/`). A Claude Code hook enforces that locally: it
refuses to open a pull request from a commit `mix review record` has not marked. The hook reads
shell text on the author's machine, so it does not see a pull request opened through the API, the
web, or a tool other than Bash, nor a push to an open one, and whoever merges cannot see the mark
([#20](https://github.com/EmpoweredHouse/ehos-tools/issues/20)).

## Decision drivers

- Whoever merges sees, where they merge, whether the author's review happened and what it found.
- Nothing to install, no token, nothing an outside contributor's pull request cannot run.
- One more check, not a second review process.

## Considered options

1. A CI job that requires a `## Review` section in the pull request's description
2. A commit status that `mix review record` sets on `HEAD` through the GitHub API, required by CI
3. Both

## Decision outcome

Chosen option: **"A CI job that requires a `## Review` section"**, because the description is
where the review's findings are written down anyway (step 8 of `pre-pr-review`), it is what a
reviewer reads, and a job that reads it needs no token. The `review` workflow runs
`mix review pull_request` on every pull request and whenever its description is edited; it
fails while the description has no `## Review` section, or none with anything in it but
comments, sub-headings or code blocks. A change to documentation alone says so there. The
repository's pull request template carries the section.

### Consequences

- Good, because a pull request opened any way at all, by anyone, is checked, and the result is
  on the pull request.
- Bad, because the check proves that the author wrote down a review, not that it happened, nor
  that it covers the last commit. A reviewer reading the section, and the local mark, cover the
  rest; a section that does not match the commits is something to ask about in review.
- Bad, because it binds only once the check is required for `main` in the repository's settings,
  which this record does not change.
- Bad, because the workflow and `packages/review` run from the pull request itself, so a pull
  request can change its own check. A reviewer sees such a change in the diff; the check guards
  against forgetting, not against intent, like the local hook.
- Bad, because re-running a failed run reads the description it had: an author fixes the section
  by editing the description, which runs the check again. The failure says so.
- Neutral: the local hook stays as the early guard, before a pull request exists.

### Confirmation

`Review.pull_request_body/1`'s tests in `packages/review` fail if a description without the
section, or with an empty one, is accepted. The `review section` check on each pull request is
the decision holding in practice.

## Pros and cons of the options

### A `## Review` section, checked in CI

- Good, because it needs no token and no setup on the author's machine.
- Bad, because it checks a text, not an act.

### A commit status set by `mix review record`

- Good, because it ties the review to the exact commit.
- Bad, because the author needs a token that can write statuses, and `gh`, and an outside
  contributor has neither; a status can be set without a review just as a section can be written.

### Both

- Good, because each covers part of the other's gap.
- Bad, because it adds the token and its setup for a gain a reviewer reading the section mostly
  gives already.

## More information

Revisit if sections start to say nothing (a copied "nothing found"), or if CI can run the
reviews itself.

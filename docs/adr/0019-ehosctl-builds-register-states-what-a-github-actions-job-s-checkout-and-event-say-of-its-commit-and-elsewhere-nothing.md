---
status: accepted
date: 2026-10-27
decision-makers: [Emil Wojtaszek]
consulted: [eh-os D-129, eh-os D-146, T-18]
---

# T-19 · `ehosctl builds register` states what a GitHub Actions job's checkout and event say of its commit, and elsewhere nothing

## Context and problem statement

[eh-os D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md)
makes a build a record of its own: an application's CI registers each image it publishes, with
the bundle written beside it. EHOS takes the repository, ref, commit and run from the job's token,
and a run may state more of the commit: its first line, author and time, a pull request's number,
head and title, and up to 100 commits before it along first parents. EHOS checks a stated field's
form, never its truth, and refuses the build when one is outside it. D-146 leaves to ehos-tools
where `ehosctl builds register` reads these from, which commit it reads them of, and what it does
when it cannot read them or they do not fit
([#498](https://github.com/EmpoweredHouse/ehos-tools/issues/498)).

## Decision drivers

1. A commit's details never fail a pipeline: a title, a clock or a shallow checkout is never a
   reason the build is not registered.
2. What is stated describes the commit a person would look for: on a pull request, the commits
   its author pushed, not GitHub's test merge.
3. Nothing is stated that `ehosctl` cannot tie to the image, as `ehosctl deploy` states no
   checkout's commit (eh-os D-129).
4. The template's workflow stays the commands a developer types, as T-18 keeps it.

## Considered options

1. **git and the event file, in a job alone**: read the commit with `git log` in the checkout and
   a pull request from `GITHUB_EVENT_PATH`; outside a GitHub Actions job, state nothing.
2. **GitHub's API**: ask GitHub for the commit, the pull request and the commits before it, with
   the job's `GITHUB_TOKEN`.
3. **The checkout everywhere**: state what `git log` says of `HEAD`, in a job or on a terminal.
4. **Flags**: the workflow passes `--title`, `--author` and the rest, which the command sends as
   they are.

## Decision outcome

Chosen option: **1, git and the event file, in a job alone**, because it needs no token or call
beyond the checkout the job already has, and states nothing it cannot tie to the run.

- **In a job** (`GITHUB_ACTIONS=true`), the commit is `GITHUB_SHA`, except on a `pull_request`
  run, where it is the pull request's head from the event, since `GITHUB_SHA` is then GitHub's
  test merge. A `pull_request_target` run is of the base's commit, `GITHUB_SHA`, and states its
  pull request beside it. `git log --first-parent` gives that commit's
  first line, author name and committer time, and the 100 commits before it, each its first line.
  The event gives the pull request's number, head and title.
- **To fit EHOS's form**, a title or a name loses every control character and every mark that
  sets the direction of text (U+200E, U+200F, U+061C, U+202A to U+202E, U+2066 to U+2069), is
  normalised to NFC, and is cut to 256 code points on a character's boundary; one with nothing
  left is left out. A committer time later than the runner's clock is left out, since EHOS refuses
  it and `ehosctl` cannot correct another machine's clock. The list of commits stops before the
  first with no first line, since EHOS requires one.
- **What cannot be read is left out**: a commit not in a shallow checkout, a checkout git cannot
  read, an event that is not JSON. The build is still registered, with what was read.
- **Outside a job**, nothing is stated. A person's build is registered by them, shown as theirs,
  and deployed by its id alone.
- **Never stated**: the commit and the ref, which a pipeline's are GitHub's token's (EHOS refuses
  them stated).

### Consequences

- Good, because registering needs only the checkout and the event the job has, and no call to
  GitHub that could fail or be limited.
- Good, because what a pull request's build states is what its author pushed.
- Bad, because the commits before it need history: a checkout of depth 1 states none of them, and
  a pull request's head, when the checkout lacks it, states no commit at all. Mitigation: the
  template's workflow checks out with `fetch-depth: 102` (eh-os's plan, step 7, says 101: a pull
  request's test merge is one commit above its head).
- Bad, because what is stated is what the workflow's checkout says, which a workflow can make say
  anything. It is a label, shown as stated (D-146); the token's commit is what is checked.
- Neutral: a person who wants their build described states nothing today; a flag for it can be
  added later without changing what a job states.

### Confirmation

`Ehosctl.CheckoutTest`, on a git repository made for each test: a push states its commit's first
line, author and time in UTC and the commits before it along first parents, at most 100; a pull
request states its number, head and title and its head's commit; a time later than the clock is
left out, and the list stops before a commit with no first line; a checkout without the commit, or
no checkout, states only what the event gives; outside a job nothing is stated.
`Ehosctl.BuildsTest`: the build's part holds what `Ehosctl.Checkout` states in a job, and the image
alone outside one.

## Pros and cons of the options

### git and the event file, in a job alone

- Good, because it reads only what the job already holds.
- Bad, because it needs the checkout's history.

### GitHub's API

- Good, because it needs no history in the checkout.
- Bad, because it needs a token with read access, network calls that GitHub limits, and a
  pipeline that fails or states nothing when GitHub is slow.

### The checkout everywhere

- Good, because a person's build would be described too.
- Bad, because a person's checkout has no tie to the image they register: it may be another
  commit, or have changes not committed, as D-129 says of `ehosctl deploy`.

### Flags

- Good, because the command would state exactly what it is told.
- Bad, because every workflow would repeat the reading, the stripping and the cutting, and one
  that did not would fail its pipeline on a title.

## More information

Decided under [#498](https://github.com/EmpoweredHouse/ehos-tools/issues/498), ehos-tools' part of
[eh-os#1051](https://github.com/EmpoweredHouse/eh-os/issues/1051) (builds as records, step 6). The
form EHOS checks: eh-os
[`docs/builds-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/builds-api.md#what-a-run-or-a-person-states).

Revisit if a person's builds should carry what they state, or if GitHub gives a job a commit's
details without its history.

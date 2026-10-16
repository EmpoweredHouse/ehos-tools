---
status: proposed
date: 2026-10-16
decision-makers: []
consulted: []
---

# T-17 · An application's review gate is ehos_app's: Mix tasks, a hook and a workflow its installer writes, and a review skill an assistant can run

## Context and problem statement

eh-os, ehos-tools and eh-os-contract refuse `gh pr create` until the author's review is recorded
for `HEAD`, and ehos-tools' CI fails a pull request whose description does not record it
([T-03](0003-ci-checks-that-a-pull-request-records-its-authors-review.md)). An application
`ehos_app` generates had none of that. Its review skill, `/ehos-app:review`, can be started by a
person alone (`disable-model-invocation`), its `AGENTS.md` asked for a review only before a draft
was made ready, and its settings had no hook. On 14 October 2026 an assistant opened a pull
request in TaxVision, the first application, and nothing asked for a review
([#229](https://github.com/EmpoweredHouse/ehos-tools/issues/229)).

The repositories' gate does not carry over. `packages/review` is never released, so an
application cannot depend on it, and `ehos-dev:pre-pr-review` is written for EHOS's own
repositories: it reads a `.claude/review.md` an application does not have, and its plugin is not
one an application enables ([T-15](0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md)).

## Decision drivers

- A freshly generated application refuses to open a pull request from an unreviewed commit, in
  every worktree, and its CI fails one whose description records no review.
- An existing application gets all of it by running the installer again
  ([T-02](0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)).
- An assistant can run the review and record it without a person starting the skill.
- No second copy of anything an application would have to keep in step by hand.

## Considered options

1. The gate in `ehos_app`, as `mix ehos_app.review`, with the hook and a `review` workflow the
   installer writes, and a model-invocable `pre-pr-review` skill in the `ehos-app` plugin
2. Release `packages/review` and add it to every application as a dependency of its own
3. Write the gate's code into each application, as a Mix task under `lib/mix/tasks/`
4. Drop `disable-model-invocation` from `/ehos-app:review` and teach it to record the mark

## Decision outcome

Chosen option: **"The gate in `ehos_app`"**, because every application already depends on
`ehos_app` (in `:dev`), whose installer writes `.claude/settings.json`, `AGENTS.md` and CI, so one
release of `ehos_app` reaches the gate's code, its hook and its workflow together.

- `EhosApp.Review` is `packages/review`'s `Review`, moved with its hardening (commands that move
  `HEAD`, `--head`/`--repo`/`GH_REPO`, marks in the common git directory), its messages pointing
  at the application's skill and task. `mix ehos_app.review record | check | gate | pull_request`
  runs it. `packages/review` depends on `ehos_app` by path and keeps only what is ehos-tools' own:
  its marks' directory and its messages, which it passes as options. The gate exists once.
- The installer adds a PreToolUse hook on Bash to `.claude/settings.json` that runs
  `MIX_ENV=dev mix ehos_app.review gate` for a command naming gh's pull request commands, and
  refuses whenever the gate cannot run. A hook of the developer's that already runs the gate is
  theirs, and no second one is added.
- `.github/workflows/review.yml`, a workflow of its own so that editing a description reruns it
  alone, fetches the development dependencies with the GitHub App CI already uses and runs
  `mix ehos_app.review pull_request`. The pull request template ends with an empty `## Review`
  section, so a description left as the template fails.
- The `ehos-app` plugin gets `pre-pr-review`, which an assistant can invoke: `/code-review` and a
  pass through `/ehos-app:review`'s lenses with security and performance, in parallel, every
  finding settled, `mix precommit`, then `mix ehos_app.review record`, then the draft pull
  request. `/ehos-app:review` stays a person's skill, for reviewing a branch or someone else's
  pull request.
- An application's review-proven rules stay in its `AGENTS.md`, which every session reads, rather
  than a `.claude/review.md` as in eh-os: `pre-pr-review` looks for them and proposes a new one
  when a finding repeats.

### Consequences

- Good, because `gh pr create` from an unreviewed commit is refused in every application, and
  every worktree of it sees the same marks.
- Good, because an upgrade brings the hook, the workflow and the template, and the developer's
  own hooks, workflow and template are kept.
- Good, because a fix to the gate reaches ehos-tools' own at once, and every application with the
  next `ehos_app` it moves to.
- Bad, because ehos-tools' gate now builds `ehos_app` before it runs, and runs whatever `ehos_app`
  a branch has: a branch that breaks `ehos_app`'s compile breaks its own gate. Mitigation: it fails
  closed, as any gate that does not run does, and CI's `review` check runs on a change to
  `EhosApp.Review`.
- Bad, because the hook and the workflow run Mix in `:dev`, which compiles the development
  dependencies first: the first hook after `mix deps.get` may take a while (its timeout is two
  minutes, and a gate that times out refuses), and the workflow fetches with the App's token and
  caches `deps` and `_build`. A pull request from a fork gets no secrets, and its check fails;
  Dependabot's are skipped.
- Bad, because, like T-03's, the workflow checks that a review was written down, not that it
  happened, and the hook reads shell text: a pull request opened through the API or the web is
  seen by the workflow alone.
- Neutral: `/ehos-app:ship` no longer opens a draft pull request at its start; it pushes the
  branch, and opens the draft once `pre-pr-review` has recorded the change.

### Confirmation

`EhosApp.ReviewTest` fails if an unreviewed commit passes the gate, or a description without a
review passes `pull_request_body/1`. The installer's tests fail if a new project's settings lack
the hook, if the hook is added twice or beside a developer's that runs the gate, if `review.yml`
reads the description other than through the environment, or if the pull request template's
`## Review` section passes the check while empty; its idempotency test, if a second run changes
the settings.

## Pros and cons of the options

### The gate in `ehos_app`

- Good, because the application's one dependency on EHOS's tooling carries it, at the version its
  installer wrote.
- Good, because `packages/review` uses it too, so the gate exists once.
- Bad, because ehos-tools' gate then builds `ehos_app` before it runs.

### Release `packages/review` as a dependency of every application

- Good, because the code exists once.
- Bad, because it is a fourth package to release and pin, and the installer still has to write
  the hook and the workflow, so `ehos_app` changes with it anyway.

### The gate's code in each application

- Good, because it needs no dependency at all, and its CI job none.
- Bad, because a fix to the gate reaches no application: the installer cannot tell its copy from
  the developer's changes, so each would keep the version it was generated with.

### `/ehos-app:review` records the mark

- Good, because there is one review skill.
- Bad, because `/ehos-app:review` also reviews a branch that is not the reader's, and in summary
  mode produces no findings: recording a mark from it would mark commits nobody settled findings
  for.

## More information

Revisit when EHOS's repositories and its applications should share one `pre-pr-review`, or when
eh-os's and eh-os-contract's gates, still copies of `Ehos.Dev.Review`, should use this one.

---
status: accepted
date: 2026-10-05
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-04 · CI tries the binaries end to end only for a release, and checks and builds only what a change touches

## Context and problem statement

CI ([`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)) ran in full on every pull
request and on every push to `main`. Each run had four `check` jobs, four `build` jobs that
cross-build the binaries, and four `e2e` jobs, one per platform, as
[`docs/research.md`](../research.md) chose ("How is it proven on each platform?").

The repository is private, and GitHub bills a minute of a hosted macOS runner as ten Linux
minutes. In the successful runs of 3 October 2026, `e2e (macos_x64)` on `macos-15-intel` took 12
to 19 minutes and `e2e (macos_arm64)` on `macos-15` about 3. Every other job together took about
25 Linux minutes. That makes the two macOS jobs about 190 of each run's roughly 215 billed minutes,
close to 90%.

The rest was spent where nothing could fail. A pull request that changed one package, or only
documentation, ran `check` for all four. A merged pull request ran all of CI again on `main`, for
the code its pull request had just passed: more than twenty runs on 3 October alone. And GitHub
bills every job by the minute, rounded up, so the four `build` jobs, each one or two minutes of
mostly setup, were billed as about eight.

## Decision drivers

- A release is never published without its binaries having been tried on every platform it
  supports.
- A change is checked by every package whose result it can change, and by no other.
- The cost of CI follows releases and changes, not pushes.
- A pull request finds the caches it needs, so skipping work does not make each run slower.
- No hung job runs until GitHub's six-hour limit.

## Considered options

1. Run `e2e` only for a release or on demand; check and build only what a change touches; run on
   `main` only to refresh caches; one `build` job; a timeout on every job
2. `e2e` on Linux on every pull request, and on macOS only on a tag
3. Skip CI for documentation with `paths-ignore`, and keep the rest as it was
4. Move `main` behind a merge queue, so CI runs once, on what lands
5. Keep CI as it was until the repository is public, where hosted runners cost nothing

## Decision outcome

Chosen option: **"Run `e2e` only for a release or on demand, check and build only what a change
touches"**, because it ties the cost to releases and changes while keeping the property that
matters: `release` needs `e2e`, so no binary is published that has not passed on all four
platforms.

- **`e2e`** runs when `github.ref` is a `v*` tag or the run was started by hand
  (`workflow_dispatch`). Anyone with write access can start the whole of CI on a branch from the
  Actions tab, or with `gh workflow run CI --ref <branch>`. `release` publishes only for a pushed
  tag, never for a run started by hand on one.
- **`build`**, which is Linux alone, runs in those cases and also on a pull request that changes
  what goes into a binary: `packages/ehosctl`'s `lib/`, `config/`, `rel/`, `mix.exs`, `mix.lock`
  or `.tool-versions`, or `ci.yml`. A mistake there would otherwise be found by the tag, which
  cannot be moved.
- **`check`** runs for the packages a `changes` job lists with
  [`dorny/paths-filter`](https://github.com/dorny/paths-filter). A package also counts as touched
  when something its tests read outside it changes: the root `.tool-versions`, `packaging/`,
  `.gitattributes`, `ehos_design`'s fonts, or the workflow itself. A tag, a push to `main` and a
  run started by hand check every package.
- **A push to `main`** runs CI only when a `mix.lock` or a `.tool-versions` changes. A pull
  request restores the caches of `main` and its own, never another pull request's, so `main` still
  saves them when what they hold changes. `check`'s cache gets `restore-keys`, so a changed lock
  file starts from the previous cache built under the same toolchain.
- **`build`** is one job that builds every target `mix.exs` names into one artifact, and **every
  job** has `timeout-minutes`, about twice its longest run so far.

### Consequences

- Good, because a pull request to one package runs two short jobs, `changes` and one `check`,
  a few Linux minutes instead of about 215, plus a Linux `build` of a few minutes when it changes
  `ehosctl`'s code or build; one to documentation alone runs `changes`.
- Bad, because a bug that only `e2e` finds, such as the Linux-only failure of `mise exec` in
  [`docs/spike.md`](../spike.md#linux-and-ci), is found when the version is tagged, not when the
  change is reviewed. Mitigation: run CI by hand on a pull request that changes how `init` runs or
  what the template generates, and on `main` before tagging a release
  ([`CONTRIBUTING.md`](../../CONTRIBUTING.md#versions-and-releases)).
- Bad, because a tag whose `e2e` fails publishes nothing, and since a tag is not moved, the fix is
  the next patch version. The manual run before tagging is what keeps this rare.
- Bad, because an `ehos_app-v*` tag does not run `e2e`: a template release is tried end to end
  only when the `ehosctl` that pins it is tagged, or when someone runs CI by hand.
- Bad, because nothing checks `main` after a merge. Two pull requests that pass apart can fail
  together, and the next pull request finds it, since GitHub tests a pull request merged with
  `main`. Requiring a pull request to be up to date before it merges would close the gap, at the
  price of a re-run whenever `main` moves.
- Bad, because a package that starts reading a file outside its directory has to be added to the
  filter by hand, or a change to that file will not check it. The comment over the filter says
  which files count, and a reviewer of such a test is who catches it.
- Bad, because one `build` builds the targets one after another, so a release waits a few minutes
  longer for its binaries.
- Neutral: `check` still runs `Ehosctl.TemplateTest` and the installer's idempotency test, which
  catch most changes to the template without a binary, and `review section`
  ([T-03](0003-ci-checks-that-a-pull-request-records-its-authors-review.md)) keeps running on
  every pull request.

### Confirmation

On a pull request, `e2e` shows as skipped, and `build` too unless the pull request changes what
goes into a binary; the `check` jobs listed are those of the packages its files belong to, and
one that changes only `docs/` skips `check`. `release` keeps
`needs: [check, e2e]`, and `Ehosctl.TargetsTest` still fails if `ci.yml` stops running a target
end to end.

## Pros and cons of the options

### Release-only `e2e`, changed packages only, and the rest

- Good, because it removes nearly all the cost of a run that is not a release, and saves on
  every pull request, not only on documentation.
- Bad, because platform bugs surface late unless someone runs CI by hand, and it adds a job and a
  list of paths that must stay right.

### `e2e` on Linux on every pull request, macOS only on a tag

- Good, because the Linux path, where the one platform-specific bug so far was found, is still
  tried on every pull request.
- Bad, because it still builds binaries and runs two `e2e` jobs, about 20 Linux minutes, on
  every push, for a path that only changes when `ehosctl` or `ehos_app` does.

### `paths-ignore` for documentation

- Good, because it is two lines.
- Bad, because a change to one package still checks all four, and `main` still runs everything.

### A merge queue

- Good, because CI runs once, on exactly what lands, and catches pull requests that fail only
  together.
- Bad, because GitHub offers merge queues on a private repository only with GitHub Enterprise
  Cloud.

### Keep CI until the repository is public

- Good, because nothing is lost.
- Bad, because the cost runs until a date nobody has set.

## More information

Revisit when the repository is public: hosted runners cost nothing there, `e2e` on every pull
request can come back, and a merge queue is available. Revisit sooner if a platform bug reaches a
tag that a run on the pull request would have caught.

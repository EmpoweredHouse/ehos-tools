---
status: proposed
date: 2026-11-27
decision-makers: []
consulted: [EmpoweredHouse/eh-os#1902; EmpoweredHouse/eh-os#1900; changie's source at v1.26.0; GitHub's Actions and REST documentation, read on 27 November 2026]
---

# T-34 · D-205's release workflow is `ehos-release.yml` and the Mix package `ehos_release`, tagged `ehos_release-vX.Y.Z`, which a repository calls before and after its own costly checks; `ehosctl`'s tag publishes the binaries `e2e` tested in that run

## Context and problem statement

[eh-os D-205](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0205-a-release-is-one-pull-request-a-workflow-opens-from-changelog-fragments-and-tags-on-its-merge-main-keeps-the-last-released-version-and-a-component-pins-another-by-a-commit.md)
makes a release of eh-os, ehos-tools or ehos_contract one pull request. A workflow of ehos-tools
collects the changelog fragments, computes the version, checks every pin into the three
repositories, and opens `release/<component>-X.Y.Z` with a GitHub App's token. An admin merges
it. On the merge commit the workflow checks again, runs the repository's costly checks once, and
tags. Each repository's own release job then runs on the tag, as
[eh-os D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md)
describes. D-205 says what the workflow does and leaves to ehos-tools how it is built.

Four constraints of this repository shape that:

- **Mix is the only entry point**, with no shell scripts (`AGENTS.md`). Today's release jobs are
  inline `run:` steps of `bash`, `jq` and `gh`: in `release-package.yml`, `ci.yml`'s `release`,
  eh-os's `release.yml` and ehos_contract's `release.yml`. Reading `mix.lock`, workflows'
  `uses:`, `.claude/settings.json` and the refs `ehos_app` writes, and checking each against a
  protected tag, is too much logic for inline steps, and D-205's Confirmation asks for tests of it.
- **The callers differ in their costly checks.** ehos-tools runs `ehosctl`'s `e2e` on macOS and
  Linux today only on a `v*` tag or by hand (`ci.yml`; [T-04](0004-ci-runs-only-what-a-change-or-a-release-needs.md)),
  and a release runs it twice: once by hand on `main` to preview, once on the tag. eh-os's full
  cluster run ([eh-os D-183](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0183-the-cluster-tests-run-in-two-tiers-a-core-a-pull-request-waits-for-in-shards-and-a-full-run-nightly-and-before-a-release-which-is-tagged-only-on-a-commit-it-passed.md))
  waits for the image `ci.yml` builds, and its `release.yml` finds that run by its name, "Cluster
  full on `<commit>`". ehos_contract runs neither. A reusable workflow cannot run its caller's
  jobs, and its `uses:` cannot be an expression.
- **Callers pin what they call by a commit an ehos-tools tag names**, with the tag as a comment, as
  `ehos-service.yml`'s callers do ([T-27](0027-a-utility-service-s-pipeline-is-a-workflow-of-ehos-tools-released-by-ehosctl-s-tag-which-installs-the-ehosctl-of-that-tag.md)),
  and D-205's own pin check refuses a pin that no protected tag of the pinned package's prefix
  names. So the release workflow is itself a component with a tag prefix.
- **The App can tag and push release branches.** Its key must reach the jobs that need it and no
  other, as eh-os [D-197](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0197-ci-gets-its-read-tokens-from-one-workflow-on-main-whose-environment-alone-holds-the-ci-github-app-s-key.md)
  does for eh-os's CI App, and as this repository does for Renovate's
  ([T-24](0024-acme-dns-s-image-is-kept-current-by-renovate-run-in-a-workflow-of-ehos-tools-under-a-github-app-of-its-own.md)).

This record decides six things: where the logic lives; how a caller puts its costly checks between
the merge and the tag; which tag callers pin the workflow by; how ehos-tools' `ci.yml` runs `e2e`
once and publishes the same binaries; what the App, its environment and its rulesets are; and
how changie is configured.

## Decision drivers

1. **D-205 holds as written**: two acts of the maintainer, the costliest checks once per release,
   on the commit that is tagged, chained by `needs:` and not polled, and no automation that writes
   to `main`.
2. **The job that holds the App's key runs no code from the caller's repository and no text from a
   fragment or an issue.** The job that reads them holds no write token.
3. **Logic is tested where it is written**: in Elixir with ExUnit, behaviour-driven as
   [T-20](0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)
   says, and run with Mix.
4. **One implementation for three repositories**, which each pins, and moves in a reviewed pull
   request.
5. **Standard tools before our own**: changie for the changelog, GitHub's own reusable workflows,
   artifacts, environments and rulesets.
6. **Cheap where it runs often.** The workflow starts on every push to `main` of three
   repositories; most of those pushes are not a release.

## Considered options

**Where the logic lives**

1. **A new Mix package, `packages/ehos_release`**, whose tasks the workflow runs from a checkout
   of ehos-tools at the workflow's own commit.
2. **Commands of `ehosctl`**, which the workflow installs from a release.
3. **Inline steps in the workflow**, `bash`, `jq` and `gh`, as the release jobs are today.
4. **A JavaScript action**, with `actions/github-script` or an action of our own.
5. **`packages/review`**, which `changelog.yml` already runs.

**How a caller composes its costly checks**

1. **The caller's own workflow calls `ehos-release.yml` in stages, with its costly checks as jobs
   between them**, chained by `needs:`.
2. **The release workflow starts the caller's checks** with a dispatch and waits for the run.
3. **A chain of `workflow_run` events**: the check workflow starts on the release workflow's
   end, and the tagging on the check workflow's end.

**Which tag callers pin the workflow by**

1. **A tag of its own, `ehos_release-vX.Y.Z`.**
2. **`ehosctl`'s tag `vX.Y.Z`**, as `ehos-service.yml` is released (T-27).
3. **A moving major tag, `v1`**, as most published actions do.

**How `ehosctl`'s tag publishes the binaries `e2e` tested**

1. **The tag names the run of the release workflow, and `ci.yml`'s release job downloads that
   run's artifact.**
2. **The release job finds the run by its commit**, as eh-os's `release.yml` finds its full
   cluster run.
3. **The release workflow uploads the binaries to a draft release**, which the tag publishes.
4. **The tag builds and runs `e2e` again** (today).

**Where the App's key lives**

1. **An environment `release-app`, whose deployment branch is `main` alone**, passed by name
   from one caller workflow to the release workflow, whose jobs name the environment.
2. **A repository secret.**
3. **D-197's token workflow**, which mints a token on `main` and hands it back encrypted.

**How the version is computed**

1. **changie's `auto`, templated on the `Breaking` field** in each repository's `.changie.yaml`.
2. **Computed by `ehos_release`** from the fragments, and passed to changie as a version.

## Decision outcome

Chosen options: **"A new Mix package, `ehos_release`"**, **"The caller calls `ehos-release.yml`
in stages, with its costly checks between them"**, **"A tag of its own, `ehos_release-vX.Y.Z`"**,
**"The tag names the run, and `ci.yml` downloads its artifact"**, **"An environment
`release-app`"** and **"changie's `auto`, templated on `Breaking`"**. Together they put every rule
of D-205 in code tested here (drivers 3 and 4), keep the key's jobs free of the caller's code and
of fragment text (driver 2), and run each costly check once, on the tagged commit (driver 1).

### Where the logic lives

- **`packages/ehos_release`** is a Mix package. No project depends on it; it is released only as
  the code `ehos-release.yml` runs (below). Its tasks:
  - `mix ehos_release.open <component>` collects the component's fragments, computes the version,
    checks the pins and the workflows, reads each named issue's state, and writes the release's
    change as a patch, and the pull request's description as a file.
  - `mix ehos_release.merged <commit>` finds the commit's pull request, checks that an admin merged
    it and that it came from `release/<component>-X.Y.Z` of the same repository, checks the pins
    and the workflows again, and checks that no fragment of the component is left.
  - `mix ehos_release.pins`, the pin check alone, for each repository's CI on every pull request
    (D-205, "Between releases").
- **It reads the caller's repository as data and never compiles or evaluates it.** `mix.lock`
  with `Code.string_to_quoted/2`, accepting literals alone; workflows and `.changie.yaml` with a
  YAML parser; `.claude/settings.json` as JSON. Refs a repository keeps in Elixir source, such as
  `Ehosctl.Template`'s `@template_ref` and `ehos_app`'s `@ehos_contract_ref` and `@ehos_design_ref`,
  are read the same way, as the literal of a module attribute the caller's configuration names.
  A caller's `mix.exs` is code; running it would run the caller's code in a job that reads the
  GitHub API on its behalf.
- **Each repository describes its components in `.github/ehos-release.json`**, data read by the
  package: each component's changie projects, its tag prefix, the files that carry its version,
  each with the one literal the package replaces (a `@version` in a `mix.exs`, `version` and
  `appVersion` in eh-os's `Chart.yaml`), and the Elixir attributes that hold pins. The package
  refuses a file where it does not find exactly one such literal.
- **Collaborators are behaviours**, as T-20 says: GitHub's API (through Req), changie and git
  (through a command runner, as `EhosPlatform.CommandRunner` runs programs), each mocked with
  Hammox in the package's tests.
- **The workflow checks out ehos-tools at its own commit**, `job.workflow_sha`, which GitHub's
  `job` context gives a reusable workflow since September 2026, with `job.workflow_repository`.
  Nothing in the caller names that commit twice. The toolchain is the root `.tool-versions` of
  that checkout, installed with `cache: false`, as a release job installs it today.

### How a caller composes its costly checks

- **Each repository has one caller workflow, `.github/workflows/release-pull-request.yml`.** It
  runs on `workflow_dispatch` (input `action`: `open` with a `component`, or `tag` with a
  `commit`), and on a push to `main` that changes a `CHANGELOG.md`, which after D-205 only a release
  pull request does. Its jobs:

  ```yaml
  open:      # dispatch, action open
    uses: EmpoweredHouse/ehos-tools/.github/workflows/ehos-release.yml@<commit> # ehos_release-vX.Y.Z
    with: {stage: open, component: …, version: …}
    secrets: {RELEASE_APP_CLIENT_ID: …, RELEASE_APP_PRIVATE_KEY: …}
  merged:    # push to main, or dispatch with action tag
    uses: …ehos-release.yml@<commit>
    with: {stage: merged, commit: …}
  checks:    # the caller's own, once, on the merge commit
    needs: merged
    if: needs.merged.outputs.release == 'true'
    uses: ./.github/workflows/ci.yml
    with: {commit: …, release: …}
  tag:
    needs: [merged, checks]
    if: always() && needs.merged.outputs.release == 'true'
    uses: …ehos-release.yml@<commit>
    with: {stage: tag, commit: …, component: …, version: …, results: ${{ toJSON(needs) }}}
    secrets: {…}
  ```

  ehos-tools calls `./.github/workflows/ehos-release.yml` instead, the copy at the commit being
  released.
- **`ehos-release.yml` has three stages**, chosen by an input:
  - `open`: a job with no key and a read-only token runs `mix ehos_release.open` and uploads the
    patch and the description as an artifact; a second job, in the environment `release-app`,
    checks out the caller at the same commit, applies the patch with `git apply`, commits, pushes
    the branch and opens the pull request with the App's token. It runs no Mix and no changie.
  - `merged`: one job, with no key, runs `mix ehos_release.merged` and outputs `release`
    (whether this commit is a release pull request's merge an admin made), the component, the
    version and the commit. On any other push it says `false`, and every later job is skipped: one
    short job per merge to `main` that changes a changelog.
  - `tag`: a job in `release-app` tags the commit when every result in `results` is `success` or
    `skipped`; otherwise a job with `issues: write` and no key opens an issue naming the jobs that
    failed and the run, and saying the two ways out D-205 gives. The tag is annotated, and its
    message names the run (`ehos-release: run <id>`).
- **The caller's costly checks are its own CI, called as a reusable workflow on the merge
  commit.** In ehos-tools, `ci.yml` with `e2e` for an `ehosctl` release (below); in eh-os, a workflow that builds the image of
  the commit and runs every tier of the cluster tests on it, chained by `needs:`, which eh-os
  shapes in its own step of the plan (step 4); ehos_contract calls its CI or nothing. A caller's
  check workflow only has to take the commit as an input and check it out in every job. A
  check that fails by chance is retried with "Re-run failed jobs" on the same run, which runs the
  `tag` stage again.
- **The version the maintainer wants above the floor is a dispatch input**, `version`, refused
  when it is below the floor. Only the App may push to `release/*`, so the version cannot be raised
  in the pull request itself, as D-205's "Versions" puts it; a pull request whose version is wrong
  is closed and the release started again.

### Which tag callers pin the workflow by

- **`ehos-release.yml` and `packages/ehos_release` are one component, `ehos_release`, tagged
  `ehos_release-vX.Y.Z`**, with a changie project and a `CHANGELOG.md` of their own. It is
  released through itself, like the other packages of ehos-tools, and its tag publishes a GitHub
  release through `release-package.yml`, never marked latest.
- eh-os and ehos_contract pin
  `EmpoweredHouse/ehos-tools/.github/workflows/ehos-release.yml@<commit> # ehos_release-vX.Y.Z`, the
  same commit in every `uses:` line of their caller workflow, and `ehos-pins.yml` (below) the same
  way. The pin check holds a `uses:` of `ehos-release.yml` or `ehos-pins.yml` to that prefix, as it
  holds `ehos-service.yml` to `ehosctl`'s `v*`.
- **The prefix goes into both of ehos-tools' tag rulesets**, "Only admins create release tags" and
  "Release tags stay what they were", and into the environment `release`'s tag patterns, before
  the first tag. Read on 27 November 2026, both rulesets list `v*`, `ehos_app-v*`,
  `ehos_design-v*`, `ehos-dev-v*`, `ehos_platform-v*` and `ehos-app-v*`; eh-os#1901 adds
  `ehos_tunnel-v*` and `ehos_diagrams-v*`.
- **The pin check is a second reusable workflow, `ehos-pins.yml`**, which runs
  `mix ehos_release.pins` and holds no key. Each repository's CI calls it on every pull request.
  It is a file of its own so that `ehos-release.yml` keeps one caller per repository, which the
  test below can hold.

### How `ehosctl`'s tag publishes the binaries `e2e` tested

- **`ci.yml` gains `workflow_call`**, with the inputs `commit` and `release`. Called from
  `release-pull-request.yml`, it checks out `commit` in every job, runs every package's check,
  builds the binaries with `cache: false` and `release.json --commit <commit>`, and runs `e2e` when
  the component is `ehosctl`. The push of the release's merge starts no `ci.yml` of its own: it
  changes no `mix.lock` or `.tool-versions`.
- **On a `v*` tag, `ci.yml` runs no `build` and no `e2e`.** `release` reads the run's id from the
  tag's message, and checks through the API that the run is of
  `.github/workflows/release-pull-request.yml` in this repository, on `main`, and that its `build`
  and every `e2e` job concluded `success`. It downloads that run's `ehosctl` artifact with
  `actions/download-artifact`'s `run-id` and `github-token` (`actions: read`), and checks what it
  checks today: `release.json`'s commit is the tag's, and `--version` is the tag's version.
  `publish` downloads the same run's artifact the same way, and `install` is unchanged.
- **The artifact lasts 7 days**, as today. The tag is pushed minutes after `e2e`, in the same run.
  A tagging an admin starts later by hand builds and runs `e2e` again, in a run of its own, which
  its tag names. The repository's limit is 90 days, since it is public.

### The App, its environment and its rulesets

- **Each repository has a GitHub App of its own** (*ehos-tools release*, *eh-os release*,
  *ehos_contract release*), installed on that repository alone, with `contents` and
  `pull_requests` write and no other permission: no `workflows`, no `issues`. The issue on
  refusal is opened with the job's own `GITHUB_TOKEN`. A job mints a token with
  `actions/create-github-app-token`, narrowed to the permissions that job needs, for that
  repository alone.
- **Its Client ID and key are the secrets `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY`
  of the caller's environment `release-app`**, whose deployment branches are `main` alone. GitHub
  gives an environment's secret to a reusable workflow's job that names the environment, when the
  caller passes the secret by name; the caller's job cannot name an environment itself. Set it up
  in the order `CONTRIBUTING.md` gives for `renovate`: the environment, its branch rule, then the
  secrets.
- **A branch ruleset, "Only the release App pushes release branches"**, on `refs/heads/release/*`,
  restricts creations and updates, with the App alone in its bypass list. Deletions stay allowed,
  so a merged branch is deleted. It comes into force with the move of each repository (D-205's
  plan, steps 3 to 5): until then people push `release/*` branches by hand.
- **The App joins the bypass list of "Only admins create release tags"**, and of no other
  ruleset. `main`'s protection keeps it out: it is not an admin.
- **Who merged** is read from the pull request's `merged_by`, and that user's role from
  `GET /repos/{owner}/{repo}/collaborators/{username}/permission`; a role the job cannot read is a
  refusal, not a pass.
- **A test in each repository holds** that one workflow, `release-pull-request.yml`, calls
  `ehos-release.yml`, on `workflow_dispatch` and a push to `main` alone; that no other workflow
  names `RELEASE_APP_*` or the environment `release-app`; and that no workflow of the caller names
  the environment (the release workflow's jobs, in ehos-tools, do). In ehos-tools it is
  `WorkflowSecretsTest`; in eh-os, `test/ci_test.exs`, beside D-197's. `mix ehos_release.open` and
  `merged` run the same check, and refuse.

### changie

- **One `.changie.yaml` at each repository's root**, with a project per released package in
  ehos-tools (`ehosctl`, `ehos_app`, `ehos_design`, `ehos_diagrams`, `ehos_platform`,
  `ehos_tunnel`, `ehos_release`) and in ehos_contract (each package), and none in eh-os. A fragment
  names its projects with `changie new -j`; a change to `ehos_platform` that `ehosctl` ships names
  both, as it asks for two lines today.
- **Kinds are Keep a Changelog's six**, with `kindFormat: '### {{.Kind}}'`.
- **Custom fields**: `Breaking`, an `enum` of `Yes` and `No` (changie has no boolean); `Issue`, a
  `string` such as `EmpoweredHouse/eh-os#1836`, not optional; in ehos_contract, `Moves a verdict`,
  an `enum` too, as an `additionalChoices` of the kinds it applies to. `changie new
  --interactive=false` fails when one is missing.
- **Formats**: `versionFormat: '## [{{.VersionNoPrefix}}] - {{.Time.Format "2006-01-02"}}'`, and
  `changeFormat` prints `**Breaking:** ` (and in ehos_contract `**Moves a verdict:** `) before the
  body when the field says `Yes`, and the issue after it, so the released sections read as D-91
  describes.
- **The floor is changie's `auto`**, a template on each kind since changie 1.25.0:
  `{{if eq .Custom.Breaking "Yes"}}minor{{else}}…{{end}}`, `minor` for `Added`, `Changed`,
  `Deprecated` and `Removed`, `patch` for `Fixed` and `Security`. Before 1.0 a breaking change is a
  minor, which changie cannot know from the version (its `auto` sees one change, not the version),
  so the template says `minor`; at 1.0 it says `major`. In ehos_contract, `Moves a verdict` makes a
  minor too.
- **The tag is formed by `ehos_release` from the component's prefix**, not from changie's
  `next`, since `ehosctl`'s tag has none. The package refuses a version not above the highest tag
  of that prefix.
- **The history moves into changie once**: each `CHANGELOG.md`'s released sections become
  `.changes/<project>/<latest version>.md`, as changie's guide does it, and `changie merge` writes
  `CHANGELOG.md` from then on. `## [Unreleased]` goes.
- **changie is pinned twice, through mise**: in `packages/ehos_release/.tool-versions`, which the
  workflow runs, and in each repository's root `.tool-versions`, for `changie new`. A fragment is a
  small YAML file, so a contributor's changie can differ from the workflow's without harm.

### Consequences

- Good, because every rule of D-205 is Elixir in one package, tested with ExUnit and Hammox, and
  run in the three repositories at a commit each pins.
- Good, because the job that holds the key runs `git`, `gh` and GitHub's own token action, on a
  patch and a description another job wrote: no Mix, no changie, no fragment text as a command.
- Good, because `e2e` runs once per `ehosctl` release, on the merge commit, and the tag publishes
  what it tested; the preview run by hand on `main` goes.
- Good, because a caller's costly checks are its own workflow, called once, and the tag waits for
  them through `needs:`, with nothing polled.
- Bad, because a release workflow now has a release of its own, and eh-os and ehos_contract move a
  pin to take a fix of it. Mitigation: ehos-tools calls its local copy, so a fix is tried in
  ehos-tools' own releases first.
- Bad, because the collecting and checking jobs install Erlang and Elixir with no cache, a minute
  or two each. Mitigation: `merged` is skipped on pushes that change no changelog, and says
  `false` within that job on the others.
- Bad, because the package reads the refs kept in Elixir source as literals of module attributes,
  not by running the code. A pin computed at compile time would be missed. Mitigation: the
  configuration names each attribute, and the package refuses one whose value is not a literal.
- Bad, because `ci.yml` grows a third way to run, called from the release workflow, beside a pull
  request and a tag; and its jobs read `commit` instead of the run's own commit.
- Bad, because a tag's message now carries the run that tested it. A tag made by hand without one
  publishes nothing, which is intended: an admin starts the tagging through the workflow instead.
- Bad, because a release's version can no longer be raised in its pull request; a wrong one is
  closed and started again with `version`.
- Bad, because the breaking rule before 1.0 lives in three `.changie.yaml` files. Mitigation:
  `ehos_release`'s tests run changie on a fixture of each, and D-205's "Revisit" names 1.0.
- Bad, because `job.workflow_sha` is new (September 2026). If a runner lacks it, the checkout of
  ehos-tools fails rather than taking another commit, since an empty ref is refused before the
  checkout.

### Confirmation

- `ehos_release`'s tests: it refuses to open a release, and `merged` says `false` or fails, when a
  pin names a commit no protected tag of the pinned package's prefix names, when a fragment of the
  component is left on the merge commit, when the pull request was merged by anyone but an admin
  or came from another branch or repository, and when another workflow names the App's secrets or
  `release-app`; and the version is the floor changie's `auto` gives, refused below it and below
  the highest tag.
- `WorkflowSecretsTest` (ehos-tools) and `test/ci_test.exs` (eh-os) fail when a workflow other
  than `release-pull-request.yml` calls `ehos-release.yml`, calls it on another event, or names
  `RELEASE_APP_*` or `release-app`; and when the `open` or `tag` stage's job that names
  `release-app` runs anything but a checkout, `git`, `gh` and the token action.
- A test of `ci.yml` fails when a `v*` tag would run `build` or `e2e`, or `release` would take
  binaries from any run but the one the tag names.
- The first release of each repository through the workflow: one `e2e` (or full cluster) run on
  the merge commit, a tag the App made, and the release job on the tag publishing what that run
  built, linked from eh-os#1900.

## Pros and cons of the options

### Where the logic lives

#### A new Mix package, `ehos_release`

- Good, because it is Elixir and Mix, tested like every package here, and the workflow runs the
  package at its own commit.
- Bad, because each job that runs it installs a toolchain and its dependencies.

#### Commands of `ehosctl`

- Good, because a released binary runs in seconds with no toolchain, as `ehos-service.yml` runs
  one.
- Bad, because `ehosctl` is the tool of an application's developer, and its planes (eh-os D-87)
  have no place for releasing EHOS's own repositories.
- Bad, because a fix of the release logic would be a release of `ehosctl`, the most costly release
  here, which is what D-205 sets out to make rarer.

#### Inline steps in the workflow

- Good, because it is what the release jobs do today, and runs fast.
- Bad, because the pin check and the version are logic with many cases, which a step of `bash`
  cannot unit test, and `AGENTS.md` keeps logic in Mix.

#### A JavaScript action

- Good, because it is the usual shape of a GitHub Action, fast and with GitHub's client.
- Bad, because it is a second language and test runner in this repository, against Mix as the
  only entry point.

#### `packages/review`

- Good, because `changelog.yml` already runs it.
- Bad, because it compiles `ehos_app`'s `lib/` for its gate, is never released, and would carry
  three repositories' release logic beside ehos-tools' review.

### How a caller composes its costly checks

#### The caller calls `ehos-release.yml` in stages

- Good, because the costly checks stay the caller's, run once, and the tag waits for them through
  `needs:`; GitHub shows the whole release as one run.
- Bad, because each caller writes a workflow of four jobs, and the stages are three calls of one
  file.

#### The release workflow dispatches the caller's checks and waits

- Good, because the caller writes less.
- Bad, because it polls another run, which D-205 rules out, and needs `actions: write` on the
  caller.

#### A chain of `workflow_run` events

- Good, because no workflow waits.
- Bad, because a release becomes three runs linked by events, each running on `main`'s copy with
  its secrets, which is hard to follow and to re-run.

### Which tag callers pin the workflow by

#### A tag of its own, `ehos_release-vX.Y.Z`

- Good, because a fix of the release workflow is its own small release, and the pin check holds
  its pins like any other package's.
- Bad, because the prefix is one more in two rulesets and an environment.

#### `ehosctl`'s tag `vX.Y.Z`

- Good, because the prefix is protected already, as for `ehos-service.yml`.
- Bad, because every fix to the release workflow would be a release of `ehosctl`, with its `e2e`,
  and `ehosctl`'s changelog would carry lines no user of `ehosctl` reads.

#### A moving major tag, `v1`

- Good, because callers take fixes with no pull request.
- Bad, because a moving tag is what this repository's rulesets forbid, and a caller would run code
  it never reviewed.

### How `ehosctl`'s tag publishes the binaries `e2e` tested

#### The tag names the run

- Good, because the tag is protected, so the run it names cannot change, and a tagging started by
  hand on a later commit names its own run.
- Bad, because the tag's message becomes something `ci.yml` reads.

#### The release job finds the run by its commit

- Good, because nothing is written into the tag, and eh-os's `release.yml` does it today.
- Bad, because a run started by hand reports `main`'s head as its commit, not the one it tests,
  which is why eh-os names its runs after the commit; a name anyone who starts a run can choose.

#### A draft release

- Good, because GitHub's immutable releases expect assets to be attached to a draft before it is
  published.
- Bad, because it needs `contents: write` in the run that tests, and anyone with write access can
  change a draft's assets until it is published; an artifact cannot be changed after upload.

#### The tag builds and runs `e2e` again

- Good, because nothing changes.
- Bad, because `e2e`'s macOS minutes are paid twice per release, which is what D-205 removes.

### Where the App's key lives

#### An environment `release-app`

- Good, because a branch's copy of a workflow cannot reach it, and one test holds which workflow
  passes it, as T-24 and D-197 do.
- Bad, because the environment's rule admits any workflow on `main`. Mitigation: the test.

#### A repository secret

- Bad, because any branch can add a workflow that reads it.

#### D-197's token workflow

- Good, because no job of the release holds the key.
- Bad, because it is built for read tokens in eh-os alone, costs a run per token, and would need
  write tokens and three copies.

### How the version is computed

#### changie's `auto`, templated on `Breaking`

- Good, because it is changie's own feature, and the rule is in the configuration beside the
  kinds it reads.
- Bad, because changie cannot tell 0.x from 1.x, so the template changes at 1.0.

#### Computed by `ehos_release`

- Good, because the rule before and after 1.0 is one function, tested once.
- Bad, because it rebuilds what changie does, against driver 5.

## More information

Decided under [EmpoweredHouse/eh-os#1902](https://github.com/EmpoweredHouse/eh-os/issues/1902),
step 1 of D-205's plan ([eh-os#1900](https://github.com/EmpoweredHouse/eh-os/issues/1900)), whose
part here is [#1191](https://github.com/EmpoweredHouse/ehos-tools/issues/1191). It builds on D-205
and D-91, D-197's environment for an App's key, T-04 (`e2e` only for a release), T-20 (behaviours
and Hammox), T-24 (an App of its own in an environment on `main`) and T-27 (a reusable workflow
pinned by the commit of a tag). Once accepted, step 2 builds `ehos_release`, `ehos-release.yml`
and `ehos-pins.yml`; step 3 moves ehos-tools (`ci.yml`, `release-package.yml`, `changelog.yml`,
`mix review.changelog`, `CONTRIBUTING.md` and `ehos-dev:release`).

What was checked, and where: changie's `projects`, custom field types, `additionalChoices`, the
templated `auto` (changie 1.25.0, "#902 Support templating in kinds auto"), `batch` and `merge`
in its source at v1.26.0 (20 August 2026, MIT, in mise's registry through aqua); `job.workflow_sha`
in GitHub's contexts reference and its changelog of 3 September 2026; environment secrets in
reusable workflows, `download-artifact`'s `run-id`, tags pushed with an App's token starting
workflows, rulesets' bypass lists and `merged_by` in GitHub's documentation, on 27 November 2026.
Not yet tried: that the environment a reusable workflow's job names is the caller's, which step 2's
first run shows.

Revisit:

- at 1.0, when the `auto` templates move a breaking change to `major`;
- if GitHub's immutable releases are turned on, which may favour a draft release over an artifact;
- if a fourth repository calls the workflow, or callers start to need stages this record does not
  have.

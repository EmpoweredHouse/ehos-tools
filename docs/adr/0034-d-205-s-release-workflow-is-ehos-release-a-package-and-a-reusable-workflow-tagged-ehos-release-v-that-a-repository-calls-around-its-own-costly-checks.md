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
  Linux only on a `v*` tag or by hand (`ci.yml`; [T-04](0004-ci-runs-only-what-a-change-or-a-release-needs.md)),
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
  does for eh-os's CI App, and as
  [T-24](0024-acme-dns-s-image-is-kept-current-by-renovate-run-in-a-workflow-of-ehos-tools-under-a-github-app-of-its-own.md)
  decides for Renovate's here.

This record decides six things: where the logic lives; how a caller puts its costly checks between
the merge and the tag; which tag callers pin the workflow by; how ehos-tools' `ci.yml` runs `e2e`
once and publishes the same binaries; what the App, its environment and its rulesets are; and
how changie is configured.

## Decision drivers

1. **D-205 holds**: two acts of the maintainer, the costliest checks once per release, on the
   commit that is tagged, chained by `needs:` and not polled, and no automation that writes to
   `main`. Where this record changes D-205's mechanism, it says so.
2. **The job that holds the App's key runs no code from the caller's repository, no third-party
   package, and no text from a fragment or an issue, and decides nothing on another job's word
   alone.** The jobs that read the caller's files hold no write token.
3. **Logic is tested where it is written**: in Elixir with ExUnit, behaviour-driven as
   [T-20](0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)
   says, and run with Mix.
4. **One implementation for three repositories**, which each pins, and moves in a reviewed pull
   request.
5. **Standard tools before our own**: changie for the changelog, GitHub's own reusable workflows,
   artifacts, environments and rulesets.
6. **Cheap where it runs often**: on every pull request and every push to `main` of three
   repositories.

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

**The App and where its key lives**

1. **One App per repository, its key in an environment `release-app` whose deployment branch is
   `main` alone**, passed by name from one caller workflow to the release workflow, whose jobs
   name the environment.
2. **Two Apps per repository**, one that opens release pull requests and one that tags.
3. **A repository secret.**
4. **D-197's token workflow**, which mints a token on `main` and hands it back encrypted.

**How the version is computed**

1. **changie's `auto`, templated on the `Breaking` field** in each repository's `.changie.yaml`.
2. **Computed by `ehos_release`** from the fragments, and passed to changie as a version.

## Decision outcome

Chosen options: **"A new Mix package, `ehos_release`"**, **"The caller calls `ehos-release.yml`
in stages, with its costly checks between them"**, **"A tag of its own, `ehos_release-vX.Y.Z`"**,
**"The tag names the run, and `ci.yml` downloads its artifact"**, **"One App per repository, its
key in `release-app`"** and **"changie's `auto`, templated on `Breaking`"**. Together they put
every rule of D-205 in code tested here (drivers 3 and 4), keep the key's jobs to fixed commands
that check again what they act on (driver 2), and run each costly check once, on the tagged commit
(driver 1).

### Where the logic lives

- **`packages/ehos_release`** is a Mix package. No project depends on it; it is released only as
  the code `ehos-release.yml` runs (below). Its tasks:
  - `mix ehos_release.open <component> [<version>]` collects the component's fragments, computes
    the version, checks the pins against tags and the workflows, reads each named issue's state,
    and writes the release's change as a patch, and the pull request's description as a file.
  - `mix ehos_release.merged <commit>` checks the pins against tags and the workflows again on the
    merge commit, checks that no fragment of the component is left, and that the pull request
    changed nothing outside the release's files (below).
  - `mix ehos_release.pins <base>` checks, for every pin a pull request adds or moves, that it
    names a commit the producer's `main` contains (`compare/main...<commit>` is `behind` or
    `identical`), as D-205's "Between releases" asks of every pull request. It does not ask for a
    tag: a pin to an untagged commit of `main` is what D-205 allows between releases. The
    release's tasks ask for the tag.
- **It reads the caller's repository as data and never compiles or evaluates it.** `mix.lock`
  with `Code.string_to_quoted/2`, accepting literals alone and keeping atoms as strings
  (`static_atoms_encoder`, with `existing_atoms_only: true` for any other name), so a crafted
  file cannot fill the atom table; workflows and
  `.changie.yaml` with a YAML parser; `.claude/settings.json` and every other pin file as JSON.
  A caller's `mix.exs` is code, and running it would run the caller's code in a job that reads the
  GitHub API on its behalf.
- **Pins a repository keeps in Elixir move into a JSON file its code reads at compile time.**
  `Ehosctl.Template`'s `@template_ref`, `ehos_app`'s `@ehos_contract_ref` and `@ehos_design_ref`,
  and `EhosApp.PluginPins`, whose refs are computed from a tag and a version, become entries of a
  file in the package's `priv/`, which the package then reads as data too. Step 3 of the plan moves
  them; the code stays the one place that uses them. This changes `AGENTS.md`'s rule that pins live
  in `template.ex` and nowhere else: they live in `template.ex` or the JSON file it reads, and step
  3 rewrites the rule there and in `.claude/review.md`.
- **Each repository describes its components in `.github/ehos-release.json`**, data read by the
  package: each component's changie projects, its tag prefix, the files that carry its version,
  each with the one literal the package replaces (a `@version` in a `mix.exs`, `version` and
  `appVersion` in eh-os's `Chart.yaml`), and the JSON files that hold pins. The package refuses a
  file where it does not find exactly one such literal.
- **Collaborators are behaviours**, as T-20 says: GitHub's API (through Req), changie and git
  (through a command runner, as `EhosPlatform.CommandRunner` runs programs), each mocked with
  Hammox in the package's tests.
- **The workflow checks out ehos-tools at its own commit**, `job.workflow_sha` of
  `job.workflow_repository`, which GitHub's `job` context gives a reusable workflow since
  September 2026. Nothing in the caller names that commit a second time. A step before the
  checkout fails when either value is empty (GitHub Enterprise Server has no such context), since
  `actions/checkout` would otherwise check out the caller's own repository. The toolchain is that
  checkout's: Erlang and Elixir from its root `.tool-versions`, the template's, and changie from
  `packages/ehos_release/.tool-versions`, which mise reads beside it and which holds changie alone.
- **Tags are read with `git ls-remote --tags`**, one call per producer repository, not one API call
  per pin, and `compare` is called only for the pins a pull request adds or moves. That a tag is
  protected is read once per producer from its tag rulesets through the API: the prefix must be in
  "Release tags stay what they were". A ruleset the job cannot read is a refusal, not a pass.

### How a caller composes its costly checks

- **Each repository has one caller workflow, `.github/workflows/release-pull-request.yml`.** It
  runs on `workflow_dispatch` (input `action`: `open` with a `component` and an optional
  `version`, or `tag` with a `commit`), and on a push to `main` that changes a `CHANGELOG.md`,
  which after D-205 only a release pull request does. It sets `permissions: {}` at the top and
  grants each job what it needs. Its jobs:

  ```yaml
  open:      # dispatch, action open
    uses: EmpoweredHouse/ehos-tools/.github/workflows/ehos-release.yml@<commit> # ehos_release-vX.Y.Z
    with: {stage: open, component: …, version: …}
    secrets: {RELEASE_APP_CLIENT_ID: …, RELEASE_APP_PRIVATE_KEY: …}
  merged:    # push to main, or dispatch with action tag
    uses: …ehos-release.yml@<commit>
    with: {stage: merged, commit: …}
  checks:    # the caller's own, once, on the merge commit; read permissions only
    needs: merged
    if: needs.merged.outputs.release == 'true' && needs.merged.outputs.refused == ''
    uses: ./.github/workflows/ci.yml
    with: {commit: …, release: …}
  tag:
    needs: [merged, checks]
    if: ${{ !cancelled() && needs.merged.outputs.release == 'true' }}
    uses: …ehos-release.yml@<commit>
    with: {stage: tag, commit: …, component: …, version: …, refused: …, checks: ${{ needs.checks.result }}}
    secrets: {…}
  ```

  ehos-tools calls `./.github/workflows/ehos-release.yml` instead, the copy at the commit being
  released.
- **`ehos-release.yml` has three stages**, chosen by an input. Every action in it is pinned by
  commit, with its tag in a comment. Every input reaches a `run:` step through `env:`, never
  through `${{ }}`, and the job that uses it checks its form first: a version
  `^[0-9]+\.[0-9]+\.[0-9]+$`, a component among those `.github/ehos-release.json` lists, a commit
  `^[0-9a-f]{40}$`.
  - `open`: a job with no key and a read-only token runs `mix ehos_release.open` and uploads the
    patch and the description as an artifact. A second job, in the environment `release-app`,
    checks out the caller at the same commit and checks the patch with `git apply --numstat
    --summary` before it applies it: it refuses a rename, a mode change, a symbolic link, or any
    path but the component's own `CHANGELOG.md` files, a file under `.changes/`, and the version
    files, all as `.github/ehos-release.json` names them, which it reads itself with `jq` from that
    checkout. In a version file it allows one changed line, the one literal the configuration
    names, with the new version in it: a release pull request cannot add a dependency to a
    `mix.exs`. It refuses when `release/<component>-X.Y.Z` exists already. Then it commits,
    pushes the branch and opens the pull request with the App's token. It runs no Mix, no changie
    and no Hex package.
  - `merged`: a first job, with no key, uses `gh` and `jq` alone to find the commit's pull request
    (`commits/<commit>/pulls`) and outputs `release: true` when it is a merged pull request from
    `release/<component>-X.Y.Z` of this repository whose `merge_commit_sha` is the commit; on any
    other push it says `false`, and every later job is skipped. A second job, with no key, runs
    `mix ehos_release.merged` and outputs `refused`, the reasons, empty when it passes; it also
    refuses when an admin did not merge it, read from `merged_by` and
    `GET /repos/{owner}/{repo}/collaborators/{username}/permission`, a role it cannot read being a
    refusal.
  - `tag`: runs when the first job of `merged` said `true`. When `refused` is empty and `checks`
    is exactly `success`, a job in `release-app` checks again, with `gh` and `jq` alone and before
    it mints the token, what it is about to tag: the pull request is merged, its `merge_commit_sha`
    is the commit, it came from `release/<component>-<version>` of this repository, `merged_by`
    has the admin role, its files and their changed lines are within what the `open` stage allows,
    and the commit is on `main`.
    Then it creates the tag, annotated, with a message that names the run
    (`ehos-release: run <id>`). Otherwise a job with `issues: write` and no key opens an issue
    with the reasons, the jobs that did not pass and the run, and the two ways out D-205's step 6
    gives. Its text is fixed; the reasons go in a fenced block whose fence is longer than any run
    of backquotes in them, so no text in a reason becomes a mention or a link.
- **The release pull request's description has a `## Review` section** saying what the workflow
  checked, so the `review section` check that `main` requires ([T-03](0003-ci-checks-that-a-pull-request-records-its-authors-review.md))
  passes like every other pull request's.
- **The caller's costly checks are its own CI, called as a reusable workflow on the merge
  commit.** In ehos-tools, `ci.yml` with `e2e` for an `ehosctl` release (below); in eh-os, a
  workflow that builds the image of the commit and runs every tier of the cluster tests on it,
  chained by `needs:`, which eh-os shapes in its own step of the plan (step 4); ehos_contract calls
  its CI. A caller's check workflow takes the commit as an input and checks it out in every job,
  and it ends in a job, as `ci.yml`'s `CI passed` does, that fails when a job the release needs was
  skipped or did not pass: the caller sees only the called workflow's result, `success` even when
  a job inside it was skipped. Its concurrency group includes the commit when it is called, so it
  never shares a group with the run of a push to `main`.
- **A check that fails by chance** is retried with "Re-run failed jobs" on the same run, which runs
  the `tag` stage again.
- **The version above the floor is a dispatch input**, `version`, refused when it is below the
  floor. This changes D-205's "Versions", which says the maintainer raises the version in the
  release pull request: D-205's step 3 lets only the App push to `release/*`, so the pull request
  cannot be changed. A pull request whose version is wrong is closed, its branch deleted, and the
  release started again.

### Which tag callers pin the workflow by

- **`ehos-release.yml`, `ehos-pins.yml` and `packages/ehos_release` are one component,
  `ehos_release`, tagged `ehos_release-vX.Y.Z`**, with a changie project and a `CHANGELOG.md` of
  their own. It is released through itself, like the other packages of ehos-tools, and its tag
  publishes a GitHub release through `release-package.yml`, never marked latest.
- eh-os and ehos_contract pin
  `EmpoweredHouse/ehos-tools/.github/workflows/ehos-release.yml@<commit> # ehos_release-vX.Y.Z`, the
  same commit in every `uses:` line of their caller workflow, and `ehos-pins.yml` the same way.
  The release's pin check holds a `uses:` of either to that prefix, as it holds `ehos-service.yml`
  to `ehosctl`'s `v*`.
- **The caller checks these pins with its own code, not with what they pin.** A pull request that
  moved them to a fork's commit, which GitHub serves under ehos-tools' name, would otherwise have
  the moved `ehos-pins.yml` approve itself, and the moved `ehos-release.yml` would hold the key
  once merged. Each caller's own test (`test/ci_test.exs` in eh-os) checks with `git ls-remote`
  that every such commit is named by an `ehos_release-v*` tag of ehos-tools, and that all name the
  same commit.
- **The prefix goes into both of ehos-tools' tag rulesets**, "Only admins create release tags" and
  "Release tags stay what they were", and into the environment `release`'s tag patterns, before
  the first tag. Read on 27 November 2026, both rulesets list `v*`, `ehos_app-v*`,
  `ehos_design-v*`, `ehos-dev-v*`, `ehos_platform-v*`, `ehos-app-v*`, `ehos_tunnel-v*` and
  `ehos_diagrams-v*`.
- **The pin check of every pull request is a second reusable workflow, `ehos-pins.yml`**, which
  runs `mix ehos_release.pins` and holds no key. Each repository's CI calls it on every pull
  request. It may restore a cache, since it decides nothing a release relies on: the release
  checks again, with none. It is a file of its own, so that `ehos-release.yml` keeps one caller per
  repository, which the test below holds.

### How `ehosctl`'s tag publishes the binaries `e2e` tested

- **`ci.yml` gains `workflow_call`**, with the inputs `commit` and `release`. Called from
  `release-pull-request.yml`, it checks out `commit` in every job, runs every package's check,
  builds the binaries and writes `release.json --commit <commit>`, and runs `e2e` when the
  component is `ehosctl`. Every guard that today reads "not from a cache on a tag" reads the input
  `release` too: `build`'s mise cache and `e2e`'s restore of `ehos_app`'s build; and `e2e`'s
  cache of Hex's downloads, which has no guard today, gains one. The push of the release's merge
  starts no `ci.yml` of its own: it changes no `mix.lock` or `.tool-versions`.
- **On a `v*` tag, `ci.yml` runs no `build` and no `e2e`.** `release` reads the run's id from the
  tag's message, and checks through the API that the run is of
  `.github/workflows/release-pull-request.yml` in this repository, that its event is `push` or
  `workflow_dispatch`, that its commit is on `main` (`head_branch` alone is not trusted: a tag
  named `main` reports it too), and that its `build` and every `e2e` job concluded `success`. It
  downloads that run's `ehosctl` artifact with `actions/download-artifact`'s `run-id` and
  `github-token` (`actions: read`), and checks what it checks today: `release.json`'s commit is the
  tag's, and `--version` is the tag's version. `publish` downloads the same run's artifact the same
  way, and `install` is unchanged. `publish` and `install` run on the tag alone, never when
  `ci.yml` is called.
- **The artifact lasts 7 days**, as today. The tag is pushed minutes after `e2e`, in the same run.
  A tagging an admin starts later by hand builds and runs `e2e` again, in a run of its own, which
  its tag names. The repository's limit is 90 days, since it is public.

### The App, its environment and its rulesets

- **Each repository has a GitHub App of its own** (*ehos-tools release*, *eh-os release*,
  *ehos_contract release*), installed on that repository alone, with `contents` and
  `pull_requests` write and no other permission. Without `workflows`, GitHub refuses any push of
  the App that changes `.github/workflows/`. The issue on refusal is opened with the job's own
  `GITHUB_TOKEN`. A job mints a token with `actions/create-github-app-token`, narrowed to the
  permissions that job needs, for that repository alone.
- **Its Client ID and key are the secrets `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY`
  of the caller's environment `release-app`**, whose deployment branches are `main` alone. GitHub
  gives an environment's secret to a reusable workflow's job that names the environment, when the
  caller passes the secret by name; the caller's job cannot name an environment itself. Set it up
  in the order `CONTRIBUTING.md` gives for `renovate`: the environment, its branch rule, then the
  secrets; and read the rule back with
  `gh api repos/<owner>/<repo>/environments/release-app`, since no test sees a setting.
- **A branch ruleset, "Only the release App pushes release branches"**, on `refs/heads/release/*`,
  restricts creations and updates, with the App alone in its bypass list. Deletions stay allowed,
  so a merged branch is deleted. It comes into force with the move of each repository (D-205's
  plan, steps 3 to 5): until then people push `release/*` branches by hand.
- **The App joins the bypass list of "Only admins create release tags"**, and of no other
  ruleset. `main`'s protection keeps it out: it is not an admin. A tag ruleset that refuses a tag
  named `main` comes with it, as D-197 asks for eh-os.
- **A test in each repository holds** that one workflow, `release-pull-request.yml`, calls
  `ehos-release.yml`, on `workflow_dispatch` and a push to `main` alone, and passes it the
  `RELEASE_APP_*` secrets; that no other workflow names them or the environment `release-app`, but
  `ehos-release.yml` itself in ehos-tools; that the jobs of `ehos-release.yml` that name
  `release-app` run only a checkout, `git`, `gh`, `jq` and the token action; that every job of
  `ehos-release.yml` pins every action by commit and has no `${{ inputs.* }}` or `${{ needs.* }}`
  inside a `run:`; and that
  `release-pull-request.yml` grants `checks` read permissions alone. It reads the workflows as YAML,
  as eh-os's `test/ci_test.exs` does. In ehos-tools it is a new `ReleaseWorkflowTest` in
  `packages/review`, beside `WorkflowSecretsTest`; in eh-os, `test/ci_test.exs`, beside D-197's.
  `mix ehos_release.open` and `merged` run the same checks, and refuse.

### changie

- **One `.changie.yaml` at each repository's root**, with a project per released package in
  ehos-tools (`ehosctl`, `ehos_app`, `ehos_design`, `ehos_diagrams`, `ehos_platform`,
  `ehos_tunnel`, `ehos_release`) and in ehos_contract (each package), and none in eh-os. A fragment
  names its projects with `changie new -j`; a change to `ehos_platform` that `ehosctl` ships names
  both, as it asks for two lines today.
- **Kinds are Keep a Changelog's six**, with `kindFormat: '### {{.Kind}}'`.
- **Custom fields**: `Breaking`, an `enum` of `Yes` and `No` (changie has no boolean); `Issue`, a
  `string` such as `EmpoweredHouse/eh-os#1836`, not optional, which the package holds to an issue
  of the three repositories; in ehos_contract, `MovesVerdict`, labelled "Moves a verdict", an
  `enum` too, as an `additionalChoices` of the kinds it applies to. `changie new
  --interactive=false` fails when one is missing.
- **Formats**: `versionFormat: '## [{{.VersionNoPrefix}}] - {{.Time.Format "2006-01-02"}}'`, and
  `changeFormat` prints `**Breaking:** ` (and in ehos_contract `**Moves a verdict:** `) before the
  body when the field says `Yes`, and the issue after it, so the released sections read as D-91
  describes.
- **The floor is changie's `auto`**, a template on each kind since changie 1.25.0:
  `{{if eq .Custom.Breaking "Yes"}}minor{{else}}…{{end}}`, `minor` for `Added`, `Changed`,
  `Deprecated` and `Removed`, `patch` for `Fixed` and `Security`. Before 1.0 a breaking change is a
  minor, which changie cannot know from the version (its `auto` sees one change, not the version),
  so the template says `minor`; at 1.0 it says `major`. In ehos_contract, `MovesVerdict` makes a
  minor too.
- **The tag is formed by `ehos_release` from the component's prefix**, not from changie's
  `next`, since `ehosctl`'s tag has none. The package refuses a version not above the highest tag
  of that prefix.
- **The history moves into changie once**: each `CHANGELOG.md`'s released sections become
  `.changes/<project>/<latest version>.md`, as changie's guide does it, and `changie merge` writes
  `CHANGELOG.md` from then on. `## [Unreleased]` goes.
- **The release pull request's description shows each issue as `owner/repo#n` and its state**,
  not its title, since anyone may write the title of an issue in a public repository. An issue
  the job cannot read is listed as unknown, as D-205 says.
- **changie is pinned through mise twice**: in `packages/ehos_release/.tool-versions`, alone,
  which the workflow runs, and in a root `mise.toml` of each repository, for `changie new`.
  ehos-tools' root `.tool-versions` stays the template's toolchain alone, which
  `Ehosctl.TemplateTest` holds. A fragment is a small YAML file, so a contributor's changie can
  differ from the workflow's without harm.

### Consequences

- Good, because every rule of D-205 is Elixir in one package, tested with ExUnit and Hammox, and
  run in the three repositories at a commit each pins.
- Good, because the jobs that hold the key run `git`, `gh`, `jq` and GitHub's own token action, on
  a patch whose paths they check themselves, and check again through the API what they tag; a
  compromised dependency of `ehos_release` can refuse a release, but not tag one.
- Good, because `e2e` runs once per `ehosctl` release, on the merge commit, and the tag publishes
  what it tested; the preview run by hand on `main` goes.
- Good, because a caller's costly checks are its own workflow, called once, and the tag waits for
  them through `needs:`, with nothing polled.
- Bad, because a release workflow now has a release of its own, and eh-os and ehos_contract move a
  pin to take a fix of it. Mitigation: ehos-tools calls its local copy, so a fix is tried in
  ehos-tools' own releases first.
- Bad, because one token holds both of the App's powers: the job that opens a pull request could
  also create a release tag, and the job that tags could push a release branch, since a ruleset's
  bypass belongs to the App, not to a token. Mitigation: both jobs run fixed commands on values
  they check themselves; two Apps per repository would split the powers, at six Apps to keep.
- Bad, because the jobs that run `ehos_release` install Erlang and Elixir with no cache, a minute
  or two each. Mitigation: the push of a merge that changes no changelog starts nothing; on one
  that does, `merged` says `false` within its first job, with no toolchain; `ehos-pins.yml`
  restores a cache.
- Bad, because the pins kept in Elixir move into JSON files, which `ehosctl` and `ehos_app` read at
  compile time: a change in two packages, in step 3.
- Bad, because `ci.yml` grows a third way to run, called from the release workflow, beside a pull
  request and a tag, and its jobs read `commit` instead of the run's own commit. This changes
  [T-04](0004-ci-runs-only-what-a-change-or-a-release-needs.md): a tag no longer runs `e2e`, and
  a release's `e2e` runs in the release workflow's run.
- Bad, because a tag's message now carries the run that tested it. A tag made by hand without one
  publishes no `ehosctl`, which is intended: an admin starts the tagging through the workflow
  instead.
- Bad, because a release's version can no longer be raised in its pull request; a wrong one is
  closed and started again with `version`.
- Bad, because the breaking rule before 1.0 lives in three `.changie.yaml` files. Mitigation:
  `ehos_release`'s tests run changie on a fixture of each, and D-205's "Revisit" names 1.0.
- Bad, because eh-os is private and the App of ehos-tools or ehos_contract reads its own
  repository alone: a fragment there that names an eh-os issue is listed as unknown, and most
  ehos-tools fragments name one. Mitigation: the description links each, for the admin to open
  before the merge; a read token for eh-os's issues is a later change, if the unknowns hide
  unfinished work.
- Bad, because the key is safe only while `release-app`'s branch rule is set, which no test in a
  repository can read. Mitigation: the order of setup above, and reading the rule back after it.

### Confirmation

Each is written in step 2 or 3 of the plan; none exists yet.

- `ehos_release`'s tests: `open` and `merged` refuse when a pin names a commit no protected tag of
  the pinned package's prefix names, when a fragment of the component is left on the merge commit,
  when the pull request was merged by anyone but an admin, came from another branch or repository,
  has a `merge_commit_sha` that is not the commit, or changed a file outside the release's files,
  and when another workflow names the App's secrets or `release-app`; `pins` refuses a pin to a
  commit `main` does not contain, and passes one to an untagged commit of `main`; the version is
  the floor changie's `auto` gives, refused below it and below the highest tag; a `mix.lock` with
  unknown atoms is read without creating any.
- `ReleaseWorkflowTest` (ehos-tools) and `test/ci_test.exs` (eh-os) fail on each case the test
  above lists, and when the jobs that name `release-app` lose the check of the patch's paths, or
  the `tag` job its own check of the pull request through the API before it mints the token.
- eh-os's and ehos_contract's tests fail when a `uses:` of `ehos-release.yml` or `ehos-pins.yml`
  names a commit no `ehos_release-v*` tag names, or two such lines name two commits.
- A test in `packages/review` of `ci.yml` fails when a `v*` tag would run `build` or `e2e`, when
  `release` would take binaries from a run without checking its workflow, event, commit and jobs,
  or when a guard against a cache does not read `release`.
- A release that a check refuses on the merge commit, or that a non-admin merged, opens an issue:
  shown in step 2 on a test repository before the first real release.
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
  cannot unit test, and `AGENTS.md` keeps logic in Mix. The keyed jobs keep inline steps of `gh`
  and `jq`, for the few checks they repeat.

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
- Bad, because the tag's message becomes something `ci.yml` reads, and checks.

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

### The App and where its key lives

#### One App per repository, its key in `release-app`

- Good, because a branch's copy of a workflow cannot reach the key while the branch rule is set,
  and one test holds which workflow passes it, as D-197's does.
- Bad, because the environment's rule admits any workflow on `main`. Mitigation: the test.
- Bad, because one App holds both powers (Consequences).

#### Two Apps per repository

- Good, because the job that opens a pull request could not tag, and the job that tags could not
  push a branch.
- Bad, because there are six Apps, keys and environments to keep, where D-205 asks for one per
  repository; the keyed jobs' fixed commands and own checks already keep each to its act.

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
and D-91, D-197's environment for an App's key, T-20 (behaviours and Hammox), T-24 (an App of its
own in an environment on `main`) and T-27 (a reusable workflow pinned by the commit of a tag).

It changes two records, which get a line under their title once it is accepted, and one rule of
this repository:

- [T-04](0004-ci-runs-only-what-a-change-or-a-release-needs.md): `e2e` runs in the release
  workflow's run, on the merge commit, and no longer on a `v*` tag;
- eh-os D-205, "Versions": the maintainer raises a release's version with the workflow's input
  `version`, not in the release pull request, which only the App may push to; filed on
  eh-os#1902;
- `AGENTS.md`'s "Pins live in `template.ex`, and nowhere else", with `.claude/review.md`'s copy of
  it: pins live in `template.ex` or the JSON file it reads, rewritten in step 3.

Once accepted, step 2 builds `ehos_release`, `ehos-release.yml` and `ehos-pins.yml`; step 3 moves
ehos-tools (`ci.yml`, `release-package.yml`, `changelog.yml`, `mix review.changelog`, the pins
kept in Elixir, `AGENTS.md`, `.claude/review.md`, `CONTRIBUTING.md` and `ehos-dev:release`).

What was checked, and where: changie's `projects`, custom field types, `additionalChoices`, the
templated `auto` (changie 1.25.0, "#902 Support templating in kinds auto"), `batch` and `merge`
in its source at v1.26.0 (20 August 2026, MIT, in mise's registry through aqua); `job.workflow_sha`
in GitHub's contexts reference and its changelog of 3 September 2026; environment secrets in
reusable workflows, `needs` in a called workflow's `with:`, `download-artifact`'s `run-id`, tags
pushed with an App's token starting workflows, rulesets' bypass lists and `merged_by` in GitHub's
documentation, on 27 November 2026. Not yet tried: that the environment a reusable workflow's job
names is the caller's, which step 2's first run shows.

Revisit:

- at 1.0, when the `auto` templates move a breaking change to `major`;
- if GitHub's immutable releases are turned on, which may favour a draft release over an artifact;
- if a fourth repository calls the workflow, or callers start to need stages this record does not
  have.

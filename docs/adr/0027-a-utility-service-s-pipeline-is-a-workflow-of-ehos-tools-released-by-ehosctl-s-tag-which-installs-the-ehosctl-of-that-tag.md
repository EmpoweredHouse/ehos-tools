---
status: accepted
date: 2026-11-14
decision-makers: [Emil]
consulted: [EmpoweredHouse/ehos-tools#917; the application template's ci.yml.eex; eh-os#1574]
---

# T-27 · A utility service's pipeline is a workflow of ehos-tools, released by `ehosctl`'s tag `vX.Y.Z`, which installs the `ehosctl` of that tag

## Context and problem statement

A utility service is a program with no contract, in any language, that EHOS deploys once in an
environment for the applications there to share (eh-os
[D-175](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0175-a-utility-service-is-an-application-with-no-contract-deployed-to-environments-as-any-other-and-another-application-reaches-it-only-once-the-service-s-side-agrees.md)).
Its repository has no Elixir project, so no installer can bring its pipeline up to date, as `ehos_app`
does for an application ([T-02](0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)).
The user decided on #917, on 13 November 2026, that the pipeline is a shared, versioned workflow in
this repository, which a service's repository calls from a file of a few lines that
`ehosctl init --service` writes once; that the workflow's tag pins the `ehosctl` it installs, so the
pipeline and the binary are one version; and that the caller passes its secrets by name and grants
`id-token: write`.

What is left is how that workflow is released and how it pins `ehosctl`. Callers name a ref of this
repository in their `uses:` line, so whatever is chosen is read by every service's repository from
its first run. An application's pipeline pins `ehosctl` by version and by the SHA-256 of
`ehosctl_linux_x64`, both written into the file, and moves them in the pull request after an
`ehosctl` release (`ci.yml.eex`'s `PINNED_EHOSCTL_VERSION` and `PINNED_EHOSCTL_SHA256`,
`CONTRIBUTING.md`, "Versions and releases"). A workflow whose tag is the same as the release it
installs cannot do that: the binary's SHA-256 is known only after the tag is pushed and CI builds
it.

The workflow runs under EHOS's trust of the service's repository. A trust that names a workflow
refuses a run of a workflow called from another repository
([eh-os#1574](https://github.com/EmpoweredHouse/eh-os/issues/1574)), so this workflow runs only
under a trust that names none. That holds for every option below.

## Decision drivers

1. **One version.** The workflow a caller names installs the `ehosctl` that has the commands the
   workflow runs, such as `ehosctl verify` for a utility service.
2. **Only what the release published runs.** The binary a job runs is the one the release
   published, checked by its digest before it runs.
3. **One thing for a caller to move.** A service's repository moves to a later pipeline by changing
   one ref.
4. **No release machinery to build or keep for this alone.**

## Considered options

1. **`ehosctl`'s tag, its own release.** The workflow is released by `ehosctl`'s `vX.Y.Z` tag. At
   that tag it names version `X.Y.Z`, and installs that release's `ehosctl_linux_x64` only if its
   SHA-256 is the one the same release's `SHA256SUMS` gives.
2. **`ehosctl`'s tag, the release before it.** As an application's pipeline does: the workflow at
   `vX.Y.Z` pins the release before it by version and SHA-256, written into the file in the pull
   request after that release.
3. **A tag of its own.** The workflow is released by a tag of its own, such as
   `ehos-service-vX.Y.Z`, cut after an `ehosctl` release, with that release's version and SHA-256
   written into it.

## Decision outcome

Chosen option: **"`ehosctl`'s tag, its own release"**, because it alone keeps the pipeline and the
binary one version with nothing new to release (drivers 1, 3 and 4). It checks the binary against
the digest its release published, though not against a digest written in the workflow (driver 2,
in part).

- The workflow is `.github/workflows/ehos-service.yml`. A caller names it by the commit that the
  tag of an `ehosctl` release names, with the tag beside it:
  `EmpoweredHouse/ehos-tools/.github/workflows/ehos-service.yml@<commit> # vX.Y.Z`. A tag can be
  moved and a commit cannot, as this repository pins every dependency from GitHub. A released
  `ehosctl init --service` writes the commit it was built from, which is the one its tag names.
  A build between releases, whose commit no tag names yet, writes the tag of the release to come,
  `v` and its version without `-dev`.
- The workflow names the version it installs, `X.Y.Z`, as a literal. `Ehosctl.ServiceWorkflowTest`
  holds it equal to the version in `packages/ehosctl/mix.exs` without `-dev`, so a release's pull
  request moves both and `main` names the release to come.
- A job installs `ehosctl_linux_x64` of release `vX.Y.Z` with `gh release download`, downloads that
  release's `SHA256SUMS` the same way, and runs the binary only if `sha256sum --check` passes for
  it.
- While this repository is private, the caller passes `EHOS_CI_APP_ID` and
  `EHOS_CI_APP_PRIVATE_KEY` by name, for the token that reads its releases, as an application's
  pipeline does. They go when the repository is public.

### Consequences

- Good, because a caller moves its pipeline and its `ehosctl` with one ref, and a release of
  `ehosctl` is the release of the workflow: no new tag, release job or environment pattern.
- Good, because a moved tag changes no caller's pipeline: the caller names the commit. Renovate
  and Dependabot read a pin of the form `@<commit> # vX.Y.Z` and keep it current.
- Good, because a workflow and the commands it runs change in one pull request and are tested
  together, by the release's `e2e` run.
- Bad, because the digest a job checks comes from the release itself, not from the file the caller
  named: a person who could replace a release's assets could replace both. Mitigation: the
  repository's rule that an asset is never re-uploaded (`AGENTS.md`, "Safety"), and GitHub's
  immutable releases, once they are turned on for this repository, which stop it.
- Bad, because `main` names a release that does not exist yet. A caller that names `main`, or a
  branch, fails at the download. Mitigation: `ehosctl init --service` writes a release's commit,
  and the caller's header says to name a release, never a branch.
- Bad, because a release of `ehosctl` that changes the workflow in a way callers cannot take is a
  breaking release of `ehosctl` too, and its changelog says so.
- Neutral: an `ehosctl` built from a `-dev` version writes the tag of the release to come, which
  does not exist until that release. `ehosctl init --service` says so when it writes it.

### Confirmation

- `Ehosctl.ServiceWorkflowTest` fails when the workflow's version is not `mix.exs`'s without `-dev`,
  or when it installs a binary without checking it against the release's `SHA256SUMS`.
- `Ehosctl.InitTest` fails when `ehosctl init --service` writes a `uses:` line that names anything
  but `ehos-service.yml` at the commit of a released `ehosctl` with its tag beside it, or, for a
  build between releases, at `v` and its version without `-dev`.
- `Ehosctl.ServiceWorkflowTest` is written with the workflow, in the pull request that adds it
  under #917.

## Pros and cons of the options

### `ehosctl`'s tag, its own release

- Good, because one version, one tag, one release.
- Bad, because the digest is the release's own, not one the caller's ref fixes.

### `ehosctl`'s tag, the release before it

- Good, because the digest is written in the workflow, as an application's pipeline does.
- Bad, because the workflow at `vX.Y.Z` runs `ehosctl` of the release before: a command a release
  adds, such as `verify` for a utility service, reaches callers one release late, and the
  workflow and its binary are two versions, which #917 rules out.

### A tag of its own

- Good, because the digest is written in the workflow, and it is the version's own.
- Bad, because every `ehosctl` release needs a second release, with its own tag pattern in the
  `release` environment, its own release job and its own changelog, and a caller has two numbers to
  keep apart.

## More information

Decided under [#917](https://github.com/EmpoweredHouse/ehos-tools/issues/917), whose comments hold
the user's decisions of 13 November 2026. Accepted by the user on 14 November
2026, who then chose, before it merged, that the caller pins the workflow by commit, after the
review of the change that writes the caller found that a tag can be moved. Revisit when this repository is public, which removes the
secrets the caller passes, or when GitHub gives a called workflow the ref it was called at, which
would let it read its own version.

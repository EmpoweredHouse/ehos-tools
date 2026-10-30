---
name: release
description: Use when a pull request changes what a user of a package sees, when the user asks to release, tag or publish EHOS, ehosctl, ehos_app, ehos_design or eh_os_contract, when a release job or the Changelog check fails, and after a tag is pushed — the changelog line, the release and the move to the next -dev, the same in eh-os, ehos-tools and eh-os-contract (eh-os D-91).
---

# Releasing EHOS and the components around it

eh-os, ehos-tools and eh-os-contract release the same way, as eh-os's
[D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md)
decided and [docs/releases.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)
describes. This skill is how to apply it. When the two disagree, `docs/releases.md` is right and
this skill is fixed.

## The components

| Component | Repository | Changelog | Tag | Marked latest |
| --- | --- | --- | --- | --- |
| `ehos` | eh-os | `CHANGELOG.md` | `vX.Y.Z` | yes |
| `ehosctl` | ehos-tools | `packages/ehosctl/CHANGELOG.md` | `vX.Y.Z` | yes (mise installs the latest) |
| `ehos_app` | ehos-tools | `packages/ehos_app/CHANGELOG.md` | `ehos_app-vX.Y.Z` | no |
| `ehos_design` | ehos-tools | `packages/ehos_design/CHANGELOG.md` | `ehos_design-vX.Y.Z` | no |
| `eh_os_contract` and its packages | eh-os-contract | each `packages/*/CHANGELOG.md` | `vX.Y.Z`, following the engine's version; each package keeps its own version | yes |

## A changelog line, in every pull request that needs one

1. **Does a user of the package see the change?** A route, a field or a refusal of an API, a page,
   a command or its output, a chart value, a document's schema, a library's public function or
   module. If yes, it needs a line. Tests, docs, CI and a refactor nobody can observe do not.
2. **Write it under `## [Unreleased]`** of that package's `CHANGELOG.md`, in the pull request that
   makes the change, under one of `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
   `Security`. Create the subsection if it is missing; never add another kind.
3. **Say what changed for the reader, in their words**, with the issue or record it came from:
   "`ehosctl installation` prints where the installation runs (eh-os#349)", not "Add
   Ehosctl.Installation". Wrap at 100 columns.
4. **A breaking change starts with `**Breaking:**`**, and says what the reader has to do.
5. **No line?** Put `No changelog: <why>` on a line of the pull request's description. The
   Changelog check fails a pull request that changes a package's code with neither.

Never change a package's version in a feature's pull request.

## Releasing a version

The user decides when to release, and pushes every tag. Do not tag without being asked to.

1. **Branch** `release/<component>-X.Y.Z` from `main`.
2. **Pick the version.** Before 1.0, a breaking line makes it a minor release; otherwise a minor
   for anything added and a patch for fixes only. The version on `main` is the next minor's
   `-dev`; a patch release drops to `X.Y.Z` of the current minor.
3. **Set it**: `X.Y.Z` in the package's `mix.exs` (and in eh-os, `deploy/charts/ehos/Chart.yaml`'s
   `version` and `appVersion`; in eh-os-contract, each package whose changelog has lines under
   Unreleased gets its own next version; the tag follows the engine's).
4. **Move the lines**: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, today's date, and put
   a new empty `## [Unreleased]` above it. Read the section as release notes: whoever upgrades
   reads it, and nothing else, to decide.
5. **Repository specifics:**
   - eh-os: once merged, wait for CI on `main` to pass Publish index for the merge commit; the
     release names that image.
   - ehos-tools, `ehosctl`: once merged, ask the user before starting CI by hand on `main`
     (`gh workflow run CI --ref main`; its macOS runners cost ten times as much as Linux ones),
     and wait for `e2e` on all four platforms, and for the release job's summary of what the tag
     would publish, before the tag, as CONTRIBUTING.md says.
   - ehos-tools, `ehos_app`: releasing it is not enough for new applications. `ehosctl` pins it
     (`Ehosctl.Template`), so moving that pin is a release of `ehosctl`.
   - ehos-tools, `ehos_design`: `ehos_app` pins it for new applications, so moving that pin is a
     release of `ehos_app`.
   - eh-os-contract: each package whose changelog has lines under Unreleased gets its own next
     version; the tag follows the engine's. Each package's section is part of the notes.
6. **Open the pull request** with `No issue: release of <component> X.Y.Z` unless an issue asked
   for it, review it as any change, and let the user merge it.
7. **The user tags the merge commit and pushes the tag.** If asked to do it:
   `git tag <tag> <merge commit>` and push that tag alone.
8. **Watch the release job.** It stops, publishing nothing, when the tag is not of its form, its
   commit is not on `main`, `mix.exs` says another version, the changelog's section is missing or
   empty, or (eh-os) no image was published for the commit. If the tag came before CI on `main`
   published the commit's image, ask the user, then re-run the job once it has: a re-run of a
   tag's job publishes the release. Otherwise fix the cause in a new pull request; never move a
   pushed tag.
9. **Move to the next `-dev`** in a pull request right after: `X.(Y+1).0-dev` in the same files.

## Checking a release job before its first tag

Every release job can be started by hand on a commit of main. It then writes into its summary
what a release of that commit would publish, with `## [Unreleased]` as the notes, and publishes
nothing. How it is started depends on the repository:

- eh-os: `gh workflow run release.yml -f ref=main` (or another commit of main).
- ehos-tools, `ehosctl`: its release job is part of CI, which has no inputs and builds the
  binaries from the branch it runs on: `gh workflow run CI --ref main` previews a release of
  `main`'s head.
- ehos-tools, `ehos_app` and `ehos_design`:
  `gh workflow run release-package.yml -f package=<package> -f ref=main`.

In ehos-tools, where the commit's version has no `-dev` (a release's pull request merged and not
tagged yet), the notes are that version's section instead: exactly what the tag will publish.

## `release.json`

Every release carries it, schema `ehos.release/v1`: `component`, `version`, `commit`, the
interfaces it `produces` and `accepts` (`ehos.yaml/v2`, `ehos.api/v1`, …), what it `requires` of
other components, and per component `image` (EHOS), `pins` (`ehosctl`) or `packages`
(eh-os-contract). `docs/releases.md` lists the fields. When a change makes a component produce or
accept another interface version, the code the release job reads it from changes with it, in the
same pull request; never edit a `release.json` by hand.

# ehos_release

`ehos_release` releases a component of eh-os, ehos-tools or ehos_contract through one pull
request. A component is a part of a repository that has its own version, tags and changelog, such
as `ehosctl` or `ehos_design`. A shared workflow in ehos-tools runs this package. The workflow
collects the changelog fragments, computes the version, checks the pins into the three
repositories, and opens the release pull request. After an administrator merges that pull request,
the workflow checks the merge again and tags it.

This page is for a maintainer of one of the three repositories.

## How a release goes

A repository calls the workflow `.github/workflows/ehos-release.yml` of ehos-tools in three
stages. The repository runs its own costly checks, such as its tests, between the second stage and
the third.

1. **Open.** A maintainer starts the release of one component on `main`. A job with no key runs
   this package. The package reads the changie fragments, computes the version and writes the
   changelog and the version files. A second job checks that change with `git` and `jq`. Then it
   opens the pull request `release/<component>-X.Y.Z` with the token of the release App of the
   repository.
2. **Merged.** An administrator merges the pull request. On the push of the merge, the workflow
   finds the release pull request of the commit. This package checks the merge commit again: who
   merged it, what it changed, the fragments that are left, the pins and the workflows.
3. **Tag.** The repository gives the workflow the result of its own checks. If all checks passed,
   a job checks the pull request again through the GitHub API. Then it tags the merge commit with
   the token of the App. If a check failed, the workflow opens an issue that says why. It does not
   tag the commit.

The release adds no commit after the merge. `main` keeps the version of the last release, and the
next release raises it.

The kinds of the fragments give the lowest version that the release can take. The `auto` field of
each kind in `.changie.yaml` says which part of the version it raises. The release also refuses a
version that is not above the highest tag of the component. To release a higher version, give it
when you start the release.

## What a pin is

A pin is a reference from one repository to a commit or a tag of another. The three repositories
keep pins in these places:

- the git dependencies in a `mix.lock`;
- the `uses:` lines of the GitHub workflows;
- the marketplace `ref` in `.claude/settings.json`;
- a JSON file that a package reads, which maps a name to a repository, a path and a ref.

Between two releases, a pin can name any commit on the main branch of the repository that it pins.
A release accepts a pin only when a protected release tag names it. A release tag is protected
when a tag ruleset of its repository refuses an update and a deletion of it. Nobody can be on the
bypass list of that ruleset.

## Check the pins of a pull request

The workflow `.github/workflows/ehos-pins.yml` runs the check on a pull request. To run the same
check on your computer, run it in this package, with the checkout of the repository and the commit
of the base:

```sh
mix ehos_release.pins --repo ../../ 0123abc…
```

The check reads `.github/ehos-release.json` in the repository. It compares the pins of the checkout
with the pins of the base. For each pin that the pull request adds or moves, GitHub must show the
commit on the main branch of the pinned repository. If a pin fails, the check prints why and exits
with 1.

The check reads `GH_TOKEN` for GitHub, if it is set. eh-os is private, so a check of a pin into
eh-os needs a token that can read it. Without one, the check refuses the pin.

## Describe the components of a repository

`.github/ehos-release.json` lists the components that the repository releases. `EhosRelease.Config`
gives the fields, with an example. `.changie.yaml` must have one changie project for each
component, and the changelogs of the two files must agree. `EhosRelease.ChangieConfig` gives the
keys of `.changie.yaml` that a release accepts.

## Next steps

- [Set up a repository to release with ehos_release](docs/set-up-a-repository.md): the GitHub App,
  its environment, the rulesets and the files.
- [CHANGELOG.md](CHANGELOG.md): what changed, version by version.

## Background

- [eh-os D-205](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0205-a-release-is-one-pull-request-a-workflow-opens-from-changelog-fragments-and-tags-on-its-merge-main-keeps-the-last-released-version-and-a-component-pins-another-by-a-commit.md): a release is one pull request.
- [T-34](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0034-d-205-s-release-workflow-is-ehos-release-a-package-and-a-reusable-workflow-tagged-ehos-release-v-that-a-repository-calls-around-its-own-costly-checks.md): how the workflow and this package are built.

# ehos_release

`ehos_release` releases a component of eh-os, ehos-tools or ehos_contract through one pull
request. A shared workflow in ehos-tools runs it. The workflow collects the changelog fragments,
computes the version, checks the pins into the three repositories, and opens the release pull
request. After an administrator merges that pull request, the workflow checks the merge again and
tags it.

This page is for a maintainer of one of the three repositories.

## What a pin is

A pin is a reference from one repository to a commit or a tag of another. The three repositories
keep pins in these places:

- the git dependencies in a `mix.lock`;
- the `uses:` lines of the GitHub workflows;
- the marketplace `ref` in `.claude/settings.json`;
- a JSON file that a package reads, which maps a name to a repository, a path and a ref.

Between two releases, a pin can name any commit on the main branch of the repository that it pins.
A release accepts a pin only when a protected release tag names it.

## Check the pins of a pull request

Run the check in this package, with the checkout of the repository and the commit of the base:

```sh
mix ehos_release.pins --repo ../../ 0123abc…
```

The check reads `.github/ehos-release.json` in the repository. It compares the pins of the checkout
with the pins of the base. For each pin that the pull request adds or moves, GitHub must show the
commit on the main branch of the pinned repository. If a pin fails, the check prints why and exits
with 1.

The check reads `GH_TOKEN` for GitHub, if it is set. eh-os is private, so a check of a pin into
eh-os needs a token that can read it.

## Describe the components of a repository

`.github/ehos-release.json` lists the components that the repository releases. `EhosRelease.Config`
gives the fields, with an example.

## Next steps

- [CHANGELOG.md](CHANGELOG.md): what changed, version by version.

## Background

- [eh-os D-205](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0205-a-release-is-one-pull-request-a-workflow-opens-from-changelog-fragments-and-tags-on-its-merge-main-keeps-the-last-released-version-and-a-component-pins-another-by-a-commit.md): a release is one pull request.
- [T-34](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0034-d-205-s-release-workflow-is-ehos-release-a-package-and-a-reusable-workflow-tagged-ehos-release-v-that-a-repository-calls-around-its-own-costly-checks.md): how the workflow and this package are built.

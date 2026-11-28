# Changelog

All notable changes to `ehos_release` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that does starts with **Breaking:**.

## [Unreleased]

### Added

- `mix ehos_release.pins BASE` checks each pin that a pull request adds or moves into eh-os,
  ehos-tools or ehos_contract. A pin passes when it names a commit on the main branch of the
  repository that it pins.
- `mix ehos_release.open COMPONENT [VERSION]` prepares the release of a component. It collects
  the changelog fragments, checks the pins and the workflows, computes the version, and writes the
  release's patch and the description of its pull request.
- `mix ehos_release.merged COMMIT` checks the release pull request merged at a commit before the
  workflow tags it: who merged it, what it changed, the version files, the fragments that are
  left, and the pins.
- `.github/workflows/ehos-release.yml` is the reusable workflow that a repository calls in three
  stages: `open` opens the release pull request, `merged` checks its merge, and `tag` tags the
  merge commit after the repository's own checks, or opens an issue that says why it did not.
- `.github/workflows/ehos-pins.yml` checks the pins of each pull request.
- `.github/ehos-release.json` describes the components of a repository: the tag prefix, the
  changie projects, the changelogs, the files that hold the version, and the files that hold
  pins.

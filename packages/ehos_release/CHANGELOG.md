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
- `.github/ehos-release.json` describes the components of a repository: the tag prefix, the
  changie projects, the changelogs, the files that hold the version, and the files that hold
  pins.

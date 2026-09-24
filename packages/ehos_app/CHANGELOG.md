# Changelog

All notable changes to `ehos_app` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehos_app` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered.

The version is raised whenever what the installer writes changes: `mix igniter.upgrade` compares it
to decide which upgrade steps an existing project needs.

## [Unreleased]

### Added

- `mix ehos_app.install`, which turns a Phoenix project into an EHOS application:
  - it adds `eh_os_contract` v0.2.1 from git, pinned to a tag;
  - it installs Oban through Oban's own installer;
  - it wires the engine in: config, a migration after Oban's, and a supervision child after the repo
    and Oban;
  - it adds `eh_os_contract.check` to `mix precommit`;
  - it writes `ehos.yaml` and `.tool-versions`;
  - it puts the EHOS section at the top of `AGENTS.md` and writes `CLAUDE.md`;
  - it generates a release and a Dockerfile.
- `--example` also generates an example contract.
- Running the installer a second time changes nothing.

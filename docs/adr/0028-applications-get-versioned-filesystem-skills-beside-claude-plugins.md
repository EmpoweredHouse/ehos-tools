---
status: accepted
date: 2026-11-15
decision-makers: [Karol Wojtaszek]
consulted: []
---

# T-28 · Applications get versioned filesystem skills beside Claude plugins

## Context and problem statement

[T-15](0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md)
removed copied skills because they did not update with the installer. It also recorded that
agents other than Claude Code could no longer load them. [Issue #931](https://github.com/EmpoweredHouse/ehos-tools/issues/931)
reports that Codex reads the generated instructions but cannot invoke the skills they require.
The user requested the issue's filesystem support and authorized direct skill-file loading.

This supersedes T-15's plugin-only distribution. Its Claude integration and the separate
marketplace of [T-16](0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md)
remain. The platform's application contracts and review requirements do not change.

## Decision drivers

- A generated application works without Claude Code or its cache.
- Skills retain their source repository, release and commit.
- Upgrades preserve application-owned changes and deletions.
- Both harnesses follow the same review requirements.

## Considered options

1. Bundle the pinned plugin sources in `ehos_app` and install managed filesystem copies.
2. Download plugins during each installation and extract their skills.
3. Require developers to install and adapt skills themselves.

## Decision outcome

Chosen option: **bundle the pinned sources**. The package includes the application and contract
plugins' skill files, references and licenses at the commits of its configured plugin releases.
A Mix task refreshes a bundle from that commit in a source checkout, not from its working tree.
Installation adds no network fetch and reads no developer cache.

Codex skill directories and names use `ehos-app-<skill>` and `eh-os-contract-<skill>`.
The adapter translates cross-skill names and sibling links. A loading section permits reading
the exact file and its references when the harness has no skill loader. User-only skills remain
user-only. Reviewers receive the absolute paths of the skill and reference files they must read.

`.agents/ehos-skills.json` records the source and the installed files' hashes for each skill.
An upgrade replaces the whole skill only when every recorded file still matches. A changed or
removed file preserves the skill and its previous manifest entry, with a notice. Existing
unmanaged skills are not claimed. Invalid manifests leave all skills unchanged with a warning.
The earlier unnamespaced copies still follow the existing retirement procedure.

Claude continues to load its plugins. Custom Claude marketplace settings do not select a
separate Codex bundle: its provenance names the installer's pins. The generated guidance makes
this distinction explicit. Without Claude hooks, agents run the existing review `record` and
`check` commands before opening a pull request; no check is bypassed.

### Consequences

- Good, because an application carries everything needed to read its skills in either harness.
- Good, because updating untouched skills does not require remembering every historical hash.
- Bad, because bundles duplicate upstream text. Source hashes and pin tests expose drift, and
  `mix ehos_app.skills.bundle` refreshes the originals without manual edits.
- Bad, because changed skills need manual reconciliation. The notice and retained provenance
  identify those copies instead of silently overwriting them.
- Neutral: deleting the manifest loses update history. Developers must commit it with the skills.

### Confirmation

`EhosApp.SkillsTest` checks pins, source hashes, names, references and provenance.
`EhosApp.SkillInstallTest` checks upgrades, ownership, removals and invalid manifests.
The installer's harness and idempotency tests cover integration into generated projects.
A generated application's `mix precommit` remains the end-to-end gate.

## Pros and cons of the options

### Bundle the pinned sources

- Good: deterministic, offline installation, with source provenance.
- Bad: a pin update also requires refreshing and reviewing the bundle.

### Download at installation

- Good: no source copies in the installer package.
- Bad: additional credentials, network failure paths and mutable tag resolution during generation.

### Manual installation

- Good: no new installer code.
- Bad: a clean generated project still blocks Codex, and each team owns its adaptation.

## More information

Decided under [#931](https://github.com/EmpoweredHouse/ehos-tools/issues/931).
Revisit if both harnesses can consume the same versioned plugin distribution directly.

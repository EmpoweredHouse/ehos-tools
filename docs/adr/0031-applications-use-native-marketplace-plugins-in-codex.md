---
status: accepted
date: 2026-11-15
decision-makers: [Karol Wojtaszek]
consulted: []
---

# T-31 · Applications use native marketplace plugins in Codex

[T-32](0032-codex-takes-the-ehos-app-plugin-from-a-marketplace-of-its-own-name-declared-in-agents-plugins-marketplace-json.md) amends the marketplace name and the upgrade of existing application settings. The contract
library's repository is now `EmpoweredHouse/ehos_contract`, and from `ehos_app` 0.38.0 its plugin
is `ehos-contract`, from the marketplace of that name; the upgrade moves `eh-os-contract` to it.

## Context and problem statement

[T-15](0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md)
keeps skills in versioned plugins instead of application-owned copies. Its Claude-only setup
left Codex without the required skills in a generated application ([#931]).

Codex supports the existing Claude-compatible marketplaces and plugin manifests. A compatibility
check with Codex CLI 0.169.0 discovered all 9 application skills and all 6 contract skills under
their original names. Its native plugin installer can use the same source repositories.
The user chose this distribution after reviewing an alternative with bundled filesystem copies.

This extends T-15 to Codex. It keeps Claude's separate application marketplace from [T-16] and
the same application rules. No plugin is published or tagged by this change.

## Decision drivers

- Keep a single source for skill text and nested references.
- Preserve the marketplace model and both harnesses' review requirements.
- Pin the sources and verify what the local harness actually loads.
- Preserve the application's own configuration and skill files.

## Considered options

1. Configure and install the original plugins through Codex's native marketplaces.
2. Bundle, translate and copy the pinned skill files into each application.
3. Ask each developer to adapt and install skills by hand.

## Decision outcome

Chosen option: **native marketplace plugins**. The installer writes `.codex/config.toml` with
Git commit pins and enabled plugin identities. The application plugin uses Codex's `ehos-tools`
marketplace; the contract plugin uses `eh-os-contract`. Both retain their colon-qualified names.
`EhosApp.PluginPins` supplies the releases to both harnesses, including their source commits.

An existing Codex config stays unchanged. The installer prints the current settings to merge,
so an upgrade does not erase custom settings or reverse a disabled plugin. After trusting the
project, the developer runs `mix ehos_app.codex.setup` and restarts the session. Setup refreshes
only these marketplaces and installs their plugins with Codex's own commands. It requires Git
access to the private repositories and Codex CLI 0.169.0 or later.

The package carries no copied skill sources or translation layer. Generated guidance permits
native invocation or reading the exact installed file from the path the harness supplies.
It applies to nested skills and reviewers too. Missing Claude tooling does not block Codex.
The shared application plugin adds `agents/openai.yaml` to its user-only skills, because Claude's
frontmatter alone does not exclude them from Codex's automatic skill catalog.

Codex uses `mix ehos_app.review record --harness codex` after review and commit, and
`mix ehos_app.review check --harness codex` before opening a pull request. These explicit commands
verify installed versions, enabled state, source repositories and clean marketplace checkouts
at the pinned commits. Missing tools or unreadable answers refuse review. The check also requires
a clean application tree and the review mark for its current commit. Claude's default checks and
hook remain unchanged. Codex does not inherit that hook.

### Consequences

- Good: each harness installs the original versioned plugins, references and licenses.
- Good: applications carry configuration rather than a second maintained copy of the skills.
- Bad: setup needs network access and credentials for the private source repositories.
- Bad: Codex's cache is shared across projects; different pins can require setup and a restart.
- Bad: custom config changes and pin upgrades require a manual merge of the printed settings.
- Neutral: version checks trust Codex's installed-version report; they do not authenticate edits
  a developer makes inside the plugin cache.
- Neutral: existing project-owned skill copies are not removed. Developers reconcile duplicate
  skills themselves; the earlier unnamespaced-copy retirement remains unchanged.

### Confirmation

Installer tests cover new and existing projects, configuration ownership and repeat installation.
Hammox tests cover setup, verification, wrong versions and sources, disabled plugins, stale or
dirty checkouts, missing tools and malformed answers. Review tests cover mixed harnesses and
commit marks. End-to-end verification installs plugins through Codex, checks discovered skill
names and invocation policy, exercises the explicit review commands, and runs the generated
application's `mix precommit`.

## Pros and cons of the options

### Native marketplaces

- Good: one distribution and original names in both harnesses.
- Bad: requires a compatible Codex client and setup on each machine.

### Bundled filesystem copies

- Good: generation can install skills without a network fetch.
- Bad: duplicates source text, policy conversion, reference translation and upgrade ownership.

### Manual adaptation

- Good: adds no template behavior.
- Bad: every application must solve discovery and policy compatibility itself.

## More information

- [Codex plugin packaging](https://developers.openai.com/plugins/build/plugins)
- [Codex configuration](https://learn.chatgpt.com/docs/config-file/config-reference)

[#931]: https://github.com/EmpoweredHouse/ehos-tools/issues/931
[T-16]: 0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md

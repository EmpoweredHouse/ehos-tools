---
status: proposed
date: 2026-11-16
decision-makers: []
consulted: []
---

# T-29 · Codex takes the `ehos-app` plugin from a marketplace of its own name, `ehos-app`, which ehos-tools declares in `.agents/plugins/marketplace.json`

## Context and problem statement

[T-28](0028-applications-use-native-marketplace-plugins-in-codex.md) gives applications their
skills in Codex from the existing marketplaces. It enables `ehos-app@ehos-tools`, from the
marketplace `ehos-tools` at a commit of the `ehos-app` plugin: `EhosApp.CodexPlugins.pins/0`
renames the marketplace `ehos-app` to `ehos-tools` for Codex. T-28 keeps Claude's separate
marketplace from [T-16] but does not say why its reason does not apply to Codex.

That reason applies to Codex as well. T-16 found
([#172](https://github.com/EmpoweredHouse/ehos-tools/issues/172)) that a machine keeps one copy of
a marketplace per name. eh-os, ehos-tools and eh-os-contract pin `ehos-tools` at an
`ehos-dev-vX.Y.Z` tag, while an application pins it at an `ehos-app` release, so a developer who
works on both moves that one copy back and forth. Codex's plugin cache is also one per machine; T-28
says so among its consequences. Today no EHOS repository configures Codex, so nothing breaks yet.
When one does, `mix ehos_app.codex.setup` in an application moves the shared `ehos-tools` checkout,
and `mix ehos_app.review check --harness codex` fails in the other project until setup runs again.
Application developers also see the `ehos-dev` and `diagram-design` plugins in that marketplace.

T-16 solved this for Claude with `path: ".claude-plugin/ehos-app.json"` on the marketplace's
source. Codex has no such option. Its documentation
([building plugins](https://developers.openai.com/plugins/build/plugins)) names fixed places for a
repository's marketplace: `.agents/plugins/marketplace.json`, and
`.claude-plugin/marketplace.json` for compatibility with Claude. It documents no way to point a Git
marketplace at another file. Claude Code reads only `.claude-plugin/`.

## Decision drivers

- An application and an EHOS repository never move one copy of a marketplace between them, in
  either harness (T-16's driver, extended to Codex).
- One source for the skill text: `plugins/ehos-app/` stays the only copy (T-15, T-28).
- One release per plugin version: one `version`, one tag, read by every manifest that lists it.
- Nothing new to publish or keep running beside ehos-tools.

## Considered options

1. A Codex marketplace `ehos-app` in ehos-tools, declared by `.agents/plugins/marketplace.json`
2. A marketplace-only repository, `ehos-app` by name, whose entry names `plugins/ehos-app` of
   ehos-tools at a commit through a `git-subdir` source
3. A repository of its own for the `ehos-app` plugin, which leaves ehos-tools
4. No change: Codex keeps `ehos-app@ehos-tools`, as T-28 decides

## Decision outcome

Chosen option: **"A Codex marketplace `ehos-app` in ehos-tools"**, because it is the only option
that removes the collision without a second repository or a second copy, and it keeps T-16's model:
one repository, one tag, two marketplace names.

The decision holds only if Codex reads `.agents/plugins/marketplace.json` instead of
`.claude-plugin/marketplace.json` when a repository has both. The documentation lists both places
but does not say which one wins. This record stays `proposed` until the experiment in
"Confirmation" shows that it does.

- `.agents/plugins/marketplace.json` declares a marketplace named `ehos-app` that lists the
  `ehos-app` plugin alone, from `./plugins/ehos-app`, like `.claude-plugin/ehos-app.json`.
  `.claude-plugin/marketplace.json` (`ehos-tools`, with `ehos-dev`, `ehos-app` and
  `diagram-design`) and `.claude-plugin/ehos-app.json` stay as T-16 left them.
- The installer writes `[marketplaces.ehos-app]` from `EmpoweredHouse/ehos-tools` and enables
  `ehos-app@ehos-app`. `EhosApp.CodexPlugins.pins/0` loses its special case and uses
  `EhosApp.PluginPins`' `marketplace` as it is. Both harnesses then use the same names.
- The plugin's `version` moves once more, so that the pinned commit holds the new file.
- An application that T-28's release configured with `ehos-tools` is moved like T-16 moved
  Claude's settings: a `[marketplaces.ehos-tools]` entry at a pin of the installer's own becomes
  `ehos-app`, and `ehos-app@ehos-tools` becomes `ehos-app@ehos-app`. Settings of the developer's own
  stay.

### Consequences

- Good, because an application (`ehos-app`) and an EHOS repository (`ehos-tools`) keep two copies,
  one per name, each at its own commit, in Codex as in Claude.
- Good, because an application developer sees only the `ehos-app` plugin in the application's
  marketplace.
- Good, because the special case in `EhosApp.CodexPlugins.pins/0` goes away: one marketplace name
  per plugin in both harnesses.
- Bad, because in Codex the repository ehos-tools then offers only `ehos-app`. eh-os,
  ehos-tools and eh-os-contract cannot take `ehos-dev` from it in Codex. None of them uses Codex
  today. If one does later, `ehos-dev` needs a marketplace of its own that Codex can address, such
  as option 2's repository, and a record that decides it.
- Bad, because the plugin is listed in three manifests. A change to its entry must keep all three
  in step. A test holds them to each other (below).
- Bad, because the decision rests on Codex's precedence between two documented files, which its
  documentation does not state. A later Codex can change it. The review check would then fail
  closed, because it verifies the marketplace's name and source.
- Neutral: Claude Code ignores `.agents/`, so nothing changes for Claude.

### Confirmation

- An experiment with Codex CLI 0.169.0 or later, in an empty Codex home: add ehos-tools at the
  branch of this change as a Git marketplace. `codex plugin marketplace list --json` names it
  `ehos-app`, and `codex plugin list --marketplace ehos-app --json` lists `ehos-app` alone. Add
  ehos-tools again at an `ehos-dev-v*` tag under the name `ehos-tools`, through
  `.claude-plugin/marketplace.json` (a checkout without `.agents/`). Both stay, each at its own
  commit, after `codex plugin marketplace upgrade` of each. The result goes on
  [#931](https://github.com/EmpoweredHouse/ehos-tools/issues/931). If Codex reads
  `.claude-plugin/marketplace.json` first, this record is rejected and option 2 is decided in its
  place.
- `EhosApp.CodexPluginsTest` checks that `config/0` names `[marketplaces.ehos-app]` and
  `ehos-app@ehos-app`, and that `.agents/plugins/marketplace.json` declares the marketplace
  `ehos-app` with the same plugin entry as `.claude-plugin/ehos-app.json`.
- The installer's tests check that T-28's `ehos-tools` entries become `ehos-app`, that the
  developer's own entries stay, and that a second run changes nothing.

## Pros and cons of the options

### A Codex marketplace `ehos-app` in ehos-tools

- Good, because it is one file in the repository that already releases the plugin.
- Good, because the release does not change: one `version`, one tag.
- Bad, because it takes the repository's only Codex marketplace name, so ehos-tools cannot offer
  `ehos-dev` to Codex as well.
- Bad, because it depends on an undocumented precedence between two files.

### A marketplace-only repository

- Good, because it does not depend on Codex's precedence: the repository has one marketplace file.
- Good, because the skill text stays in ehos-tools. The new repository holds only the catalog.
- Bad, because each plugin release is also a commit in a second repository, and a pin has two
  levels: the catalog's commit, and the plugin commit it names.
- Bad, because it is not certain that Claude supports `git-subdir` the same way. Claude could then
  stay on T-16's marketplace, and the two harnesses would read the plugin from different catalogs.

### A repository of its own for the plugin

- Good, because the name and the source agree with no file convention to rely on.
- Bad, because the skills leave the repository of `ehos_app`, whose template and skills change
  together (#931 changed both).
- Bad, because it needs its own CI, release and tags.

### No change

- Good, because nothing is built.
- Bad, because the collision of #172 returns as soon as an EHOS repository configures Codex.
- Bad, because application developers see EHOS's development plugins in their marketplace.

## More information

Decided under [#931](https://github.com/EmpoweredHouse/ehos-tools/issues/931), from the review of
[#933](https://github.com/EmpoweredHouse/ehos-tools/pull/933). Amends one point of
[T-28](0028-applications-use-native-marketplace-plugins-in-codex.md), the Codex marketplace's
name, and leaves its decision, native marketplace plugins, as it is. It does the same for Codex
that [T-16] did for Claude.

Revisit if Codex comes to accept a path to a marketplace file on a Git source, or to keep a
marketplace per source and `ref` rather than per name: T-28's single name would then work.

[T-16]: 0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md

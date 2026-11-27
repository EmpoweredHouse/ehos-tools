---
status: accepted
date: 2026-10-12
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-16 · Applications take the `ehos-app` plugin from a marketplace of its own name, `ehos-app`, which ehos-tools publishes beside `ehos-tools`

Amended by [T-33](0033-one-way-of-working-for-ehos-s-repositories-and-its-applications-a-method-plugin-they-pull-plugins-by-domain-and-lessons-sent-to-their-owner.md): the `ehos-app` marketplace lists `ehos-core` beside `ehos-app`.

## Context and problem statement

[T-15](0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md)
gave every application its skills as the `ehos-app` plugin, enabled in its `.claude/settings.json`
from the marketplace `ehos-tools` at the tag `ehos-app-vX.Y.Z`. eh-os, ehos-tools and eh-os-contract
declare the same marketplace, `ehos-tools`, at the tag `ehos-dev-vX.Y.Z`, for the `ehos-dev`
plugin. The two kinds of tag are released apart, so the two pins are almost never equal: on
12 October 2026 applications named `ehos-app-v0.1.0`, and EHOS's repositories `ehos-dev-v0.4.0`,
a commit that predates the `ehos-app` plugin.

Claude Code keeps one marketplace per name for a user: "Each user registers one marketplace per
`name`, so a user can't have two marketplaces with the same name registered at once"
([marketplace reference](https://code.claude.com/docs/en/plugins/marketplace-reference)), cloned
into `~/.claude/plugins/marketplaces/<name>/`. When a project's settings declare a known
marketplace from another source, Claude Code fetches it again from that source
([how plugins load](https://code.claude.com/docs/en/plugins/loading)). A developer who works on an
application and on eh-os on one machine therefore moves that one copy between the two tags each
time they switch, and in the eh-os direction lands on a commit without the `ehos-app` plugin.
[#172](https://github.com/EmpoweredHouse/ehos-tools/issues/172) found this in review.

## Decision drivers

- An application and an EHOS repository never move one copy of a marketplace between them.
- A plugin is still released by its own tag, as `CONTRIBUTING.md` ("Versions and releases") says,
  and reaches an application through the next `ehos_app`, as T-15 decided.
- A project 0.9 generated moves along with no step of the developer's.

## Considered options

1. A second marketplace in ehos-tools, `ehos-app`, declared by `.claude-plugin/ehos-app.json`, which
   applications name with `path:` on the marketplace's source
2. One tag for both: EHOS's repositories and applications pin `ehos-tools` at the same tag, one
   that carries both plugins
3. No change

## Decision outcome

Chosen option: **"A second marketplace in ehos-tools"**, because it is the only one where the two
pins can differ without colliding, and it needs nothing new from the release process.

- `.claude-plugin/ehos-app.json` is a marketplace named `ehos-app` that lists the `ehos-app` plugin
  alone, from `./plugins/ehos-app`. `.claude-plugin/marketplace.json` keeps listing both plugins.
- The installer writes the marketplace `ehos-app` from `EmpoweredHouse/ehos-tools` at the plugin's
  tag, with `path: ".claude-plugin/ehos-app.json"`, and enables `ehos-app@ehos-app`.
- In a project 0.9 generated, the marketplace `ehos-tools` at an `ehos-app-v*` tag no later than
  the installer's is the template's: it becomes `ehos-app` in its place, with the new tag and the
  `path`, and `ehos-app@ehos-tools` becomes `ehos-app@ehos-app` with its value. Where another
  plugin is enabled from it, it stays for that plugin, and only the entry of `ehos-app` moves. An
  `ehos-tools` marketplace on any other repository or `ref` is the developer's, and stays: the
  installer adds `ehos-app` beside it with `ehos-app@ehos-app` turned off where the plugin is
  enabled from theirs, and says so, so that no skill is enabled twice. A `path` the developer gave
  the `ehos-app` marketplace is theirs too.
- The plugin's `version` moves to 0.1.1, so that a tag exists whose commit holds the new file.

### Consequences

- Good, because an application and an EHOS repository now keep two copies, one per name, each at
  its own tag. Tried on 12 October 2026 with Claude Code 2.1.296 in an empty `CLAUDE_CONFIG_DIR`:
  `ehos-tools` at `ehos-dev-v0.4.0` and `ehos-app` at a branch of this change, with `path`, were
  cloned into two directories at two commits, `ehos-dev@ehos-tools` and `ehos-app@ehos-app`
  installed into `cache/ehos-tools/` and `cache/ehos-app/`, and a second update of both left each
  at its own commit.
- Good, because the plugin's release does not change: one `version`, one tag, which both manifests
  read through the same `./plugins/ehos-app`.
- Bad, because `path` can be given only in settings; `claude plugin marketplace add` has no option
  for it ([hosting a marketplace](https://code.claude.com/docs/en/plugins/host-marketplace)). A
  developer who adds the application's marketplace by hand has to copy the entry the installer
  writes.
- Bad, because the plugin is listed in two manifests, which a change to it has to keep in step.
  `CONTRIBUTING.md` says so where it says how the plugin is released, and a test reads the second
  manifest.
- Neutral: the experiment registered the two marketplaces by writing `known_marketplaces.json`
  and running `claude plugin marketplace update`, since the command line does not register a
  project's declared marketplaces without a signed-in session. That a project's settings register
  `ehos-app` from `path` at the trust prompt is what the documentation says, not what was run.

### Confirmation

- `test/ehos_app_install_test.exs` checks that a new project's settings name the marketplace
  `ehos-app` with its `path`, that the file at that `path` declares a marketplace of that name with
  the plugin, that settings 0.9 wrote become a new project's, and that an `ehos-tools` marketplace
  of the developer's stays.
- The same file still holds the plugin's tag to the version `plugins/ehos-app/.claude-plugin/plugin.json`
  says.

## Pros and cons of the options

### A second marketplace in ehos-tools

- Good, because the two names never collide, whatever the two tags are.
- Good, because it stays one repository and one tag per release.
- Bad, because it rests on `path` in a settings source, which Claude Code documents but its
  command line does not offer.

### One tag for both

- Good, because nothing new is published.
- Bad, because an application takes a plugin only with the `ehos_app` it moves to, while EHOS's
  repositories move theirs by hand: the two tags would be equal on the day of a release and apart
  again until every application and every repository had moved.
- Bad, because a release of `ehos-dev` would have to be a release of `ehos_app` too, and the other
  way round.

### No change

- Good, because nothing is built.
- Bad, because every developer who works on both kinds of repository keeps moving one copy back
  and forth.

## More information

Decided under [#172](https://github.com/EmpoweredHouse/ehos-tools/issues/172). Amends one point of
[T-15](0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md),
the marketplace's name, and leaves its decision, the plugin, as it is. Revisit if Claude Code comes
to keep a marketplace per source and `ref` rather than per name.

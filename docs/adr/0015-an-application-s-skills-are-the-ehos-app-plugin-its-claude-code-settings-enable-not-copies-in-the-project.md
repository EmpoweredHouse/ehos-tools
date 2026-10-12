---
status: accepted
date: 2026-10-12
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-15 · An application's skills are the `ehos-app` plugin its Claude Code settings enable, not copies in the project

## Context and problem statement

`ehos_app` 0.3.0 gave every generated application four skills, `plan`, `ship`, `review` and
`elixir-anti-patterns-review`, copied from shugyo into `.agents/skills/` and linked from
`.claude/skills/` by `mix ehos_app.link_skills` ([`docs/spike.md`](../spike.md#open-decisions-this-spike-cannot-make),
point 4). A file the installer creates is the developer's from then on, and is never written
again, so a copied skill is frozen at the version that generated the project. The spike already
named the cost: "the copied skills … are never refreshed in an existing application". By
0.8.1 one of them had changed (`ship`), and the review of TaxVision, the second application
generated from the template, found the copies in its tree with nothing to say they were the
template's or how they would move.

Meanwhile this repository became a Claude Code marketplace: `ehos-dev`, the skills eh-os,
ehos-tools and eh-os-contract share, is a plugin in `.claude-plugin/marketplace.json`, enabled by
each repository's `.claude/settings.json` at a tag, and a new version reaches all three by moving
that tag. eh-os-contract keeps eight skills of its own for writing and changing a contract
(`change-contract`, `module-boundary-check`, `add-event`, …) that its `getting-started.md` says
work in an application too, and nothing gives them to one.

This record decides how an application gets its skills, and how a later version of them reaches
it.

## Decision drivers

- A fix to a skill reaches every application, through the upgrade that already exists: moving
  `ehos_app` and running its installer again ([T-02](0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)).
- One copy of each skill, owned by the repository that knows what it describes.
- A skill a team changed for its application stays theirs.
- Nothing new to install by hand: a new project works as generated.

## Considered options

1. A Claude Code plugin, `ehos-app`, in this repository's marketplace, which the project's
   `.claude/settings.json` enables at the plugin's tag
2. Copies the installer keeps current: rewrite each skill on every run while it is still byte for
   byte a version the installer wrote, as the CI workflow is
3. No change: copies, refreshed by hand

## Decision outcome

Chosen option: **"A Claude Code plugin"**, because it is the one where a skill has a single
copy and a version, and where an application moves to a later one by changing one line the
installer owns, with nothing in the project to drift.

- The skills move to `plugins/ehos-app/skills/`, and the plugin is released like `ehos-dev`: its
  `version` is raised in `plugins/ehos-app/.claude-plugin/plugin.json` in the pull request that
  changes it, and its merge commit is tagged `ehos-app-vX.Y.Z`.
- The installer writes `.claude/settings.json` with the marketplace `ehos-tools` at the tag
  `Mix.Tasks.EhosApp.Install.plugin/0` names, and `ehos-app@ehos-tools` enabled. In a file of the
  developer's own it adds those two entries and keeps everything else, in its order. A
  marketplace an earlier version pinned to an older `ehos-app-v*` tag moves to the new one. A
  marketplace pinned to anything else, and a plugin the developer turned off, are theirs, and the
  installer says so.
- The copies 0.3.0 to 0.8.1 wrote are removed when they are still as a release wrote them
  (the installer holds each file's SHA-256), and `mix ehos_app.unlink_skills` removes the links
  left pointing at them, which Igniter cannot. A copy the developer changed stays, with a notice.
- eh-os-contract's skills reach an application the same way, from a marketplace of eh-os-contract's
  own that the template enables beside this one, once eh-os-contract publishes it: the repository
  that writes the engine keeps the skills that describe it.

### Consequences

- Good, because a fix to a skill reaches an application with the next `ehos_app` it moves to, as
  `/ehos-app:<skill>`, and `ehosctl versions` already tells it when there is one.
- Good, because the generated tree loses `.agents/` and `.claude/skills/`, ten files and four
  links that were the template's and looked like the application's.
- Bad, because only Claude Code reads a plugin. Other agents, which read `.agents/skills/`, no
  longer get the skills. Every EHOS repository works with Claude Code, and the rules every agent
  must follow stay in `AGENTS.md`, which all of them read.
- Bad, because Claude Code installs a plugin only once the folder is trusted, from GitHub with
  the machine's own git credentials, and ehos-tools is private: a machine that reads GitHub only
  over HTTPS sets `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` and stores a credential with
  `gh auth setup-git`, as `CONTRIBUTING.md` already says for `ehos-dev`.
- Bad, because Claude Code's documentation says plugins from a project's settings do not load in a
  cloud session. A cloud session works on the application without its skills until that changes.
- Neutral: the marketplace's `ref` names a tag, not a commit, since a marketplace source in
  settings takes no SHA. That is [#134](https://github.com/EmpoweredHouse/ehos-tools/issues/134),
  already open for `ehos-dev`.
- Neutral: a plugin's skills are named `/ehos-app:plan`, not `/plan`, so a skill of the
  application's own in `.claude/skills/` never collides with one of the plugin's.

### Confirmation

- `test/ehos_app_install_test.exs` checks the settings a new project gets, that a developer's
  settings keep their keys and order, that an earlier tag moves and another `ref` stays, and that
  the plugin's tag is the version `plugins/ehos-app/.claude-plugin/plugin.json` says, so the two
  cannot drift apart.
- The same file checks that a project 0.8.1 generated loses the unchanged copies and keeps a
  changed one, and the installer's idempotency test that a second run changes nothing and
  schedules no task. `test/ehos_app_unlink_skills_test.exs` checks the links and directories.
- `claude plugin validate .` passes on the marketplace and the plugin.

## Pros and cons of the options

### A Claude Code plugin

- Good, because one copy, versioned and tagged, is what every application reads.
- Good, because it is how this repository already shares `ehos-dev`, so nothing new is learnt.
- Bad, because it ties the skills to Claude Code, and to its trust and credential rules above.

### Copies the installer keeps current

- Good, because every agent reads `.agents/skills/`, and a cloud session too.
- Bad, because an application still carries ten files it does not own, and the installer keeps a
  hash of every version of each forever, to tell its copy from the developer's.
- Bad, because a skill changed in one line is then never updated again, silently.

### No change

- Good, because nothing is built.
- Bad, because every application keeps the skills it was generated with, which is the problem.

## More information

No issue: decided while reviewing the template TaxVision was generated from, with the user, on
12 October 2026. Revisit if Claude Code's plugins stop being what the EHOS repositories use, or if
another agent the teams use reads plugins too, when the skills could be published in its format
from the same files.

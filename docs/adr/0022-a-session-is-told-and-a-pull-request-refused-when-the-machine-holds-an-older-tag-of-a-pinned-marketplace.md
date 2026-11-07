---
status: accepted
date: 2026-11-07
decision-makers: [emil]
consulted: []
---

# T-22 · A session is told, and a pull request refused, when the machine holds an older tag of a marketplace the repository pins

## Context and problem statement

eh-os, ehos-tools and eh-os-contract take the `ehos-dev` and `diagram-design` plugins from the
`ehos-tools` marketplace, pinned to a tag `ehos-dev-vX.Y.Z` by the `ref` in their
`.claude/settings.json` ([`CONTRIBUTING.md`](../../CONTRIBUTING.md), "Releasing the `ehos-dev`
plugin"). An application takes `ehos-app` the same way, from the `ehos-app` marketplace
([T-16](0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md)).

Claude Code applies that `ref` only when it adds the marketplace. A machine that already has the
marketplace keeps the tag it added it at: `claude plugin marketplace update` fetches that tag
again, and `/reload-plugins` loads the cached version. On 7 November 2026 eh-os pinned
`ehos-dev-v0.12.0`, the machine held `ehos-dev-v0.11.0`, and sessions loaded `ehos-dev` 0.10.0,
without the `pull-request` and `elixir-anti-patterns-review` skills that eh-os's `CONTRIBUTING.md`
requires. The reviews before a pull request ran without them, and said so only as for an optional
skill ([#845](https://github.com/EmpoweredHouse/ehos-tools/issues/845)). Nothing told the person
that the machine was behind, so every release of `ehos-dev` since 0.10.0 reached nobody who
already had the marketplace.

`CONTRIBUTING.md` now says how to move a machine to a new tag. A step that a person must remember
for each tag, on each machine, is missed: this decision is how the machine's state is detected.

## Decision drivers

- A session that lacks the pinned skills says so at its start, before it does work the skills
  govern.
- A review is not recorded, and its pull request not opened, with skills older than the pin.
- The repository keeps its pin: a plugin version changes only through a tag the repository moves
  to in a pull request (`.claude/review.md`, "Pins and releases").
- One implementation, shared as the review gate is
  ([T-17](0017-an-application-s-review-gate-is-ehos-app-s-tasks-a-hook-its-installer-writes-and-a-skill-an-assistant-runs.md)).
- Nothing changes the person's Claude Code configuration without them.

## Considered options

1. **Instructions alone**: `CONTRIBUTING.md`'s steps, and nothing that checks them.
2. **A check in the review gate, run at session start and before a pull request**:
   `EhosApp.Review` compares each marketplace the repository's `.claude/settings.json` pins by
   `ref` with what `claude plugin marketplace list --json` and `claude plugin list --json` report.
   A `SessionStart` hook prints what is behind and the steps that fix it; the gate refuses to open
   the pull request until they are done.
3. **Follow a branch**: the repositories name the marketplace's `main`, with Claude Code's
   automatic update of a marketplace at start.
4. **A hook that moves the machine itself**: the `SessionStart` hook removes and adds the
   marketplace at the pinned tag, and installs the plugins again.

## Decision outcome

Chosen option: **"A check in the review gate, run at session start and before a pull request"**,
because it is the only option that detects the state in every session and keeps the pin, without
changing the person's configuration.

The check reads `.claude/settings.json` at the top of the working tree the session runs in. For
each marketplace in `extraKnownMarketplaces` with a `ref`, from GitHub or a git URL:

- the marketplace that `claude plugin marketplace list --json` reports under that name has the
  same repository, and the same `ref` or a later version of the same tag (`ehos-dev-v0.13.0`
  against `ehos-dev-v0.12.0`);
- where the `ref` is `<plugin>-v<version>` and `enabledPlugins` enables `<plugin>@<marketplace>`,
  `claude plugin list --json` reports that plugin installed at `<version>` or later, for any
  checkout. A session in a checkout with no install of its own still loads the plugin, and the
  list does not say which install it loads: an install for this checkout alone would refuse every
  new worktree.

A machine ahead of a pin passes, with a note. The marketplace is one per machine, and each
repository moves its pin in a pull request of its own: a check that asked for the exact tag would
refuse every pull request in the repository that has not moved yet, and its fix would move the
machine back.

When the machine is behind, the message names the tag it holds, the tag the repository pins, and
the commands that move it. Every name, `ref` and repository in the message is first held to a
plain form, and the check refuses settings that have another: the message reaches an assistant
as the commands to run. `claude` is run through a behaviour
([T-20](0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)),
with a timeout. Where `claude` is not installed (CI), the check has nothing to compare and passes;
where it fails, does not answer or answers in another shape, the check refuses.

`EhosApp.Review` runs the check when a review is recorded and when the gate decides a pull
request. The gate reads the settings of the session's working tree, whose plugins the session
loaded, and not of a tree the command changes into, whose settings the session never trusted.
ehos-tools runs it through `packages/review`: `mix review record`, `mix review gate`, and
`mix review plugins` in its `SessionStart` hook, at the start of a session. eh-os ports it to
`Ehos.Dev.Review`, as it ported the gate; applications get it in the gate with the next release of
`ehos_app`, and at session start once its installer writes the hook.

### Consequences

- Good, because a session that is behind says so at its first turn, with the commands that fix it.
- Good, because a review cannot be recorded, nor its pull request opened, while the machine has
  older plugins installed than the pin, which is what the pull request that started this did. A
  session that loaded older skills before the machine moved is not caught (below).
- Good, because repositories pinned to different tags do not block each other: the machine at the
  latest tag passes in all of them.
- Bad, because the reviews can still run with older skills before `record` refuses them: the
  `SessionStart` hook says so at the start, but only to the assistant, which has to pass it on.
- Bad, because the check reads what the machine has installed, not what the session loaded. A
  session that started before the machine moved keeps its older skills, and the gate passes it.
  The check does not say which version a session runs.
- Bad, because each session starts a Mix task and two `claude` commands: about 2 to 3 seconds when
  the package is compiled, more after a change to it. The hook runs at startup only, has a
  timeout, and prints a failure to run instead of stopping the session.
- Bad, because it relies on the JSON of two `claude` commands, which Claude Code can change. The
  check refuses with "cannot read" rather than passing when the JSON has another shape, and its
  tests hold the shape it reads.
- Bad, because the person still runs the commands. Option 4 would do it for them, at the price of a
  hook that changes their configuration.
- Bad, because a machine ahead of the pin passes with skills the repository has not taken yet.
  The check does not hold a machine to an exact version: a repository that must not run a later
  one asks its developers to move their machines to the pinned tag.

### Confirmation

- `EhosApp.PluginsTest`: the pinned tag passes, and a later one passes with a note; an older tag,
  another repository, a branch, a missing marketplace, a plugin older than the tag, a value that
  is not plain, unreadable settings, a failing or silent
  `claude` and an answer of another shape each refuse; no `claude` passes.
- `EhosApp.ReviewTest`: `record/2` and `gate/2` refuse while the machine is behind, and the gate
  reads the session's tree.
- `.claude/settings.json` in ehos-tools has the `SessionStart` hook; `.claude/review.md` names it.

## Pros and cons of the options

### Instructions alone

- Good, because it adds no code and no hook.
- Bad, because the failure is silent: it ran for at least two releases before a person noticed.

### A check in the review gate, run at session start and before a pull request

- Good, because it detects the state where the work happens, and the gate makes it binding.
- Good, because it keeps the pin and changes nothing without the person.
- Bad, because of the start-up cost and the dependence on `claude`'s JSON (above).

### Follow a branch

- Good, because every machine is current without a step.
- Bad, because a change to a skill reaches every session the moment it merges, unreleased, and a
  branch moves on every merge: the pin, and the review of what the plugin tells an assistant to do,
  are gone.
- Bad, because the three repositories cannot move at different times.

### A hook that moves the machine itself

- Good, because nobody runs the commands.
- Bad, because a hook would remove and add a marketplace in the person's user settings, and
  uninstall and install plugins, at every start where it differs, from each repository in turn when
  two pin different tags.
- Bad, because `claude plugin marketplace remove` run in a checkout also deletes that checkout's
  entry from `.claude/settings.json`, as it did on 7 November 2026.

## More information

Decided under [#845](https://github.com/EmpoweredHouse/ehos-tools/issues/845).

Revisit when Claude Code applies a changed `ref` of a known marketplace by itself: the check then
has nothing to find, and can go.

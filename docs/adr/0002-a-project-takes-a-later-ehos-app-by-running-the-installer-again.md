---
status: accepted
date: 2026-10-03
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-02 · A project takes a later ehos_app by running its installer again, not through `mix igniter.upgrade`

## Context and problem statement

An application generated from `ehos_app` keeps it as a development dependency, so that it can take
what a later version of the template writes. The documentation promised that this happens through
`mix igniter.upgrade ehos_app`, Igniter's convention: it updates the dependency, compares the
package's version before and after, and runs the package's `ehos_app.upgrade` task for the steps in
between. `ehos_app` has no such task, so the command only moved the dependency
([#12](https://github.com/EmpoweredHouse/ehos-tools/issues/12)).

What did bring a project along, from 0.2 to 0.3.0 (`ehos-ledger`,
[ehos-ledger#5](https://github.com/EmpoweredHouse/ehos-ledger/pull/5)), was running
`mix ehos_app.install` again. The installer is idempotent, and since 0.3.0 it treats a project from
an earlier version as a case of its own: it adds the sign-in's runtime block, the verifier's
migration to version 3 and the design system, rewrites its managed doc sections, and leaves what the
developer wrote or declined.

## Decision drivers

- What the documentation says to run is what works.
- One place decides what a project should have: two (an installer and upgrade steps) can disagree.
- A project from any earlier version is brought along, not only from the one before.

## Considered options

1. Run the installer again; no upgrade task
2. An `ehos_app.upgrade` task with a step per version, Igniter's convention
3. An `ehos_app.upgrade` task that only calls the installer

## Decision outcome

Chosen option: **"Run the installer again"**, because the installer already decides from what a
project has, not from which version wrote it, so it brings along a project from any earlier version,
and it is the only path that has been tried on a real one. A project points its `ehos_app`
dependency at the later version, by the commit its `ehos_app-vX.Y.Z` tag names (`ref:`, since a
tag can be moved, as `ehos_app` pins its own dependencies), runs `mix deps.get`, then
`mix ehos_app.install`, and reads the diff of `mix.lock` and of what the installer changed.

### Consequences

- Good, because every change to the installer is written once, and tested once against a project
  from an earlier version.
- Bad, because `mix igniter.upgrade ehos_app`, the command an Igniter user tries first, runs no
  step of the template's: like `mix deps.update`, it resolves the dependency as `mix.exs` names
  it, which for a pinned commit changes nothing. Mitigated by saying so wherever upgrades are
  described.
- Bad, because the installer can rewrite only a form it recognises as an earlier version's (a
  managed section, the Dockerfile step 0.2 wrote, a root `AGENTS.md` that is the section alone);
  it cannot tell an earlier version's form from the same form a developer chose, and so leaves
  that one alone and says what to change (the CI workflow from 0.2). When a version has to
  rewrite such a form, it needs an upgrade step that knows which version wrote it, and this
  record is superseded.
- Neutral: `ehos_app`'s version is still raised whenever what the installer writes changes. Its
  tag names the commit a project moves to, and an upgrade task would read it.

### Confirmation

The installer's tests that start from a project as 0.2 wrote it fail if a second run stops
bringing such a project along: the verifier's migration to version 3, the Dockerfile step given
the second repository, the root `AGENTS.md` given the application's part, and the CI workflow
left as it is with a notice. The idempotency test fails if a second run changes a current
project.

## Pros and cons of the options

### Run the installer again

- Good, because it exists and has been tried on `ehos-ledger`.
- Bad, because it rewrites only what it recognises as an earlier version's.

### An upgrade task with a step per version

- Good, because it is Igniter's convention, and can rewrite what an earlier version wrote.
- Bad, because each step repeats a part of the installer, and the two drift.

### An upgrade task that only calls the installer

- Good, because `mix igniter.upgrade ehos_app` would then work.
- Bad, because it has not been tried: whether the installer's composition (Oban's installer,
  through `Igniter.Util.Install.install/2`) holds when Igniter runs it as an upgrade task is
  unknown. Worth trying before the first upgrade step is needed.

## More information

Revisit when a version of the template has to change what an earlier one wrote.

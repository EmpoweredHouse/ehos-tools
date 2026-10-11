---
status: proposed
date: 2026-10-11
decision-makers: []
consulted: []
---

# T-11 · A generated project pins eh-os-contract's release by the commit its tag names, and moves to a later one with a release of `ehos_app`

Supersedes [T-05](0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md).

## Context and problem statement

[T-05](0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md) made a
generated project follow eh-os-contract's `main`. eh-os-contract tagged no release at the time,
and a pinned commit had fallen hundreds of commits behind. T-05 asked to be revisited once
eh-os-contract releases 0.3.0. It released 0.3.0 on 11 October 2026: tag `v0.3.0` at `3304f35`,
with the engine at 0.3.0 and `eh_os_contract_auth` at 0.1.0.

eh-os's [D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md)
makes every component release the same way. Each release says in `release.json` what it
produces and accepts:
- eh-os-contract's says which manifest schemas the engine writes;
- `ehos_app`'s says what it writes into a new application's `mix.exs`.

`ehosctl versions` is to report each component of an application as a release, and say whether
the installation accepts it. A project on `main` has no release to report, only a commit, and
what that commit writes is known to nobody.

T-05 also traded away what this repository keeps elsewhere:
- every dependency from GitHub is pinned to a commit;
- one `ehos_app` release writes one project.

A project followed whatever was merged to eh-os-contract's `main`. That included the credential
verifier, which runs on every request of a deployed application. The release that T-05 waited
for now exists.

## Decision drivers

- What an application runs is a release that says what it writes and accepts (D-91), so its
  compatibility with an installation can be told.
- A project builds the same way on every machine, until its developer chooses to move.
- The code a generated project runs, its credential verifier included, is a reviewed release.
- Moving to a later release is one standard step, the installer run again, as for `ehos_app`
  itself ([T-02](0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)).
- Projects generated under T-05 are brought along, not left on `main`.

## Considered options

1. **Pin the release by the commit its tag names**, with `ref:`, as `ehos_app` pins `ehos_design`
   and `ehosctl` pins `ehos_app`.
2. **Pin the release by its tag**, with `tag:`.
3. **Keep following `main`** (T-05).

## Decision outcome

Chosen option: **"Pin the release by the commit its tag names"**. It is the only option where a
project runs a reviewed release that says what it is (driver 1) and stays reproducible (driver 2).
Its mechanics are the ones `ehos_app` already uses for its other git dependencies.

- **What the installer writes.** It writes `eh_os_contract` and `eh_os_contract_auth` with
  `ref:` set to the commit `v0.3.0` names, `3304f355eb5d73058fa8fcf61813f9c0547f9fc6`. The
  requirements are `~> 0.3.0` and `~> 0.1.0`, held in `EhosApp.requires/0`. The engine stays
  overridden to the same source, since `eh_os_contract_auth` names it by git.
- **How a later eh-os-contract reaches projects.** A release of `ehos_app` moves the pin to the
  commit the later tag names. New projects get it with a release of `ehosctl` that pins that
  `ehos_app`, and existing ones by running the installer again (T-02). A test holds the pinned
  commit to the tag, as `Ehosctl.TemplateTest` holds `ehosctl`'s pin of `ehos_app`.
- **Which projects the installer moves.** It moves a project from eh-os-contract's `main`, or from
  any commit an earlier `ehos_app` pinned, to the release. It asks first, unless `--yes`, and
  says that the next `mix deps.get` takes the release's commit into `mix.lock`. A project on
  another commit or branch chose it, and keeps it, with the warning T-05's installer gave.
- **The interval between releases.** eh-os-contract's `main` moves to the next patch's `-dev`
  after a release while projects follow it (eh-os-contract's `CONTRIBUTING.md`). Once no
  supported `ehos_app` follows `main`, it may move to the next minor's `-dev`, as eh-os's
  `docs/releases.md` gives everywhere else.

### Consequences

- Good, because a project runs a release that names its version and what it writes, so
  `ehosctl versions` reports `eh_os_contract` as a release, and its manifest schemas against the
  installation's.
- Good, because the credential verifier a deployed application runs is a reviewed release, not
  whatever was merged last.
- Good, because the template is one release again: one `ehos_app` writes one project.
- Bad, because a project gets a fix in eh-os-contract only after a release of eh-os-contract and
  then of `ehos_app`, as T-05 feared. Mitigated by releasing the two together when the engine
  changes. `ehosctl versions` says how far behind a project is.
- Bad, because projects generated by `ehosctl` 0.2.0 still follow `main` until its next release,
  which pins this `ehos_app`. That is step 15 of eh-os's Stage 7. Until then, they are moved by
  running the installer again.

### Confirmation

- An install test checks that a new project's `mix.exs` pins both packages to the commit `v0.3.0`
  names, with `~> 0.3.0` and `~> 0.1.0`.
- An install test checks that a project on `branch: "main"` is moved to that commit, asking first
  unless `--yes`, and that one on another commit keeps it.
- A test holds the pinned commit to eh-os-contract's tag, read from the repository the test
  fetches.

## Pros and cons of the options

### Pin the release by the commit its tag names

- Good, because a commit cannot move, and this repository already pins its other git dependencies
  this way.
- Bad, because the commit must be kept equal to its tag by a test, not by Mix.

### Pin the release by its tag

- Good, because `mix.exs` names the release a reader recognises.
- Bad, because a tag can move. eh-os-contract's release tags are protected by a ruleset now, but
  this repository does not depend on another repository's settings for what it builds.

### Keep following `main`

- Good, because a project gets the engine of the day without any release.
- Bad, because a project has no release to report, and runs unreleased code, the verifier
  included.

## More information

Decided under eh-os's Stage 7 step 13
([eh-os#358](https://github.com/EmpoweredHouse/eh-os/issues/358)), at the user's request (11
October 2026) that eh-os-contract release 0.3.0 and applications pin it.

Revisit when eh-os-contract publishes to Hex, when a version requirement replaces the git pin.

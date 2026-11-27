---
status: accepted
date: 2026-11-27
decision-makers: [emil]
consulted: []
---

# T-33 · One way of working for EHOS's repositories and its applications: a method plugin they all pull, plugins by domain, a part each repository owns, and lessons sent to whoever can fix them

## Context and problem statement

Two kinds of repository work with an assistant on EHOS. eh-os and ehos-tools pull the `ehos-dev`
plugin from the `ehos-tools` marketplace in their `.claude/settings.json`; ehos_contract's
maintainers enable it in `.claude/settings.team.json`, and its review gate is a hook of its own.
Every application `ehos_app` generates
pulls `ehos-app` from the `ehos-app` marketplace, and `ehos-contract` from ehos_contract
([T-15](0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md),
[T-16](0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md),
[T-31](0031-applications-use-native-marketplace-plugins-in-codex.md)). Applications are expected
by the dozen, each a private repository of a client.

The method, how a change is planned, reviewed, described and looked back on, is written twice.
Both plugins have `pre-pr-review`, `pull-request`, `elixir` and `elixir-anti-patterns-review`. Of
`pre-pr-review`'s references, `procedure.md` and `correctness.md` are kept equal by a test in
`packages/review` ([T-23](0023-the-reviews-before-a-pull-request-use-ehos-tools-own-method-not-the-harness-s-review-skills.md)),
as `pull-request`'s description and template are by another, and the others have parted: `ehos-dev` has `security.md`, `ehos-app` has `application.md`. Only
`ehos-app` has `plan` and `retro`. A fix to the method is made in one copy, or twice.

The loop that should improve the method is open at both ends. Code is checked well (`mix check`,
two reviews, the review gate, eh-os's closing tests and evidence records), but what a piece of work
teaches is kept where it was learned. A finding becomes a line in that repository's
`.claude/review.md` (405 lines in ehos-tools on this date, 368 in eh-os) or in an application's
`AGENTS.md` ([T-17](0017-an-application-s-review-gate-is-ehos-app-s-tasks-a-hook-its-installer-writes-and-a-skill-an-assistant-runs.md)).
Lines are added and never removed, nothing reads them across repositories or stages, and nothing
shows that a new line, or a change to a skill, changes what an assistant does. `ehos-app:retro`
already sends an application's defects of the platform, the `ehos-app` plugin included, to the
repository that owns them, and records them in `docs/platform-issues.md`. But it looks only for
friction with the platform, not for what a review missed or a plan misjudged, and EHOS's
repositories have no retro at all.

The decision was prompted by a conversation on 27 November 2026 about working with models more
ambitiously: give the assistant an outcome rather than a task, and an outside judge rather than its
own opinion. A method that dozens of repositories run, and that learns from all of them, needs one
copy, one way back for lessons, and a judge for its changes.

## Decision drivers

- One copy of each procedure, with a version, for every EHOS repository and every application.
- A fix to the method reaches them through the pins they already move (T-15, T-16, T-31,
  [T-22](0022-a-session-is-told-and-a-pull-request-refused-when-the-machine-holds-an-older-tag-of-a-pinned-marketplace.md)),
  with nothing in a project to drift.
- What differs between repositories is facts the repository owns, not a fork of a procedure.
- A lesson reaches whoever can fix it: the repository, the method, a domain's plugin, the template,
  the platform, the engine. A client's code and data never leave their repository, and nothing of
  a private repository reaches a public one.
- A change to the method is judged by something outside the assistant that wrote it.
- A rule can be removed as well as added.

## Considered options

1. Keep two plugins, and hold more of their copies equal by tests.
2. One method plugin, `ehos-core`, pulled beside the plugins of each domain, with the repository's
   part as facts, a retro that sends each lesson to its owner, and a benchmark as the judge.
3. One plugin for everyone, `ehos-dev` and `ehos-app` merged.
4. The method in the documents the template and each repository write (`AGENTS.md` and its
   sections), with the plugins keeping only domain skills.

## Decision outcome

Chosen option: **"One method plugin"**, because it is the only one with a single copy of the method
that both kinds of repository pull at a version, while each domain keeps its own skills and each
repository its own facts.

**Three layers.**

- `plugins/ehos-core` holds the method: the planning of a piece of work, `pre-pr-review`'s
  procedure and correctness review, `pull-request`, and `retro`. A procedure names where it reads
  the repository's facts, and a reference of a domain plugin for what is a domain's.
- The domain plugins keep only their domain: `ehos-dev` for building EHOS (records, releases,
  architecture, diagrams, voice, stage issues, triage), `ehos-app` for building on it (`ehos.yaml`,
  contracts' lenses, sample data, the security review of an application), and `ehos-contract`, in
  ehos_contract, for writing contracts. `elixir` and `elixir-anti-patterns-review` stay in each
  domain plugin, since their rules differ by what is written (`ehos-dev:elixir` applies
  `ehos-app:elixir`'s to a CLI and its libraries). `ehos-app:ship` moves with `pre-pr-review`
  where it holds nothing of an application's.
- The repository's part is facts the repository owns: in EHOS's repositories `.claude/review.md`
  and `CONTRIBUTING.md`, as today; in an application its `AGENTS.md`, as T-17 decided. A difference
  that is a procedure rather than a fact goes to the domain plugin, never into the repository's
  part.

**How it is released and pulled.** `ehos-core` is released like any plugin, one `version` and one
tag (T-16,
[T-32](0032-codex-takes-the-ehos-app-plugin-from-a-marketplace-of-its-own-name-declared-in-agents-plugins-marketplace-json.md)):
its `version` is raised in the pull request that changes it, and the merge commit is tagged
`ehos-core-vX.Y.Z`, so `mix review.plugins` holds it as it holds the others. It reaches a
repository through the marketplace `ref` that repository already pins, at a domain plugin's tag,
as `diagram-design` reaches EHOS's repositories through `ehos-dev`'s: it is listed in
`.claude-plugin/marketplace.json`, `.claude-plugin/ehos-app.json` and
`.agents/plugins/marketplace.json`, and enabled beside the domain plugin. EHOS's repositories take
a new `ehos-core` with the next `ehos-dev` tag they move to. An application takes it with the next
`ehos_app` and its installer
([T-02](0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)), which enables it
in Claude Code's and Codex's settings unless the developer turned it off, with an explicit `false`,
which the application's documents name as the way to decline it. The installer then pins two
plugins from one marketplace, which `EhosApp.PluginPins` and `EhosApp.CodexPlugins` do not do
today: they write one marketplace for each plugin. Listing `ehos-core` in the `ehos-app`
marketplaces amends T-16 and T-32, whose marketplaces list `ehos-app` alone, and T-32's
Confirmation, which expects Codex to list `ehos-app` alone.

**`retro`, for everyone, and what it learns from.** `ehos-app:retro` already does most of what a
skill for lessons would: it follows each issue it filed until the application has the fix and its
workaround goes, it reproduces a finding at the pinned version before filing it, searches for an
existing issue, tells our mistake from the platform's, files on the user's go without the client's
data, and records the rest in the application. It becomes `ehos-core:retro`, keeps all of that, and
is widened in five ways:

- **What it looks for.** Not only friction with the platform, but anything the work met: what a
  review missed, what the plan misjudged, a skill that did not do what it says. For each finding
  it asks where it should have been caught (the plan, a rule of the code, a review, a test, a
  tool), which names the file to change.
- **Who owns it.** Its table of owners gains `ehos-core` and `ehos-dev`, filed in ehos-tools; the
  `ehos-app` plugin stays filed in ehos-tools and `ehos-contract` in ehos_contract, as today. An
  issue about any plugin is a `lesson`, labelled so, and names the plugin's version, the step of
  the method that missed, and the class of what it missed.
- **What it reads.** Beside the conversation, the diff and the checks: what the repository's part
  names as the work's record (in eh-os, the evidence record and the decisions on the step's issue),
  the follow-ups the work filed, the findings of each review round, and the corrections the user
  made.
- **What was expected.** It checks the work against the outcome, the judge and the expectations its
  plan named (below).
- **What can go.** It proposes removing a rule, a gotcha or a line of `.claude/review.md` that
  nothing has needed, not only adding one, each with what else it stops, as `.claude/review.md`
  asks before a rule is removed: a guard rarely fires. Run over many closed pieces of work at once,
  it reports the classes of finding that repeat.

**What leaves a private repository.** ehos-tools and ehos_contract are public; eh-os and every
application are private.

- An issue `retro` files in a public repository, a platform issue or a `lesson`, holds no code,
  data, name, path or output of a private repository: it says the class of defect and the step that
  missed it. This changes retro's format for such an issue, which today carries the file, the line
  and the exact output.
- A defect that may be a security one is never filed as an issue in a public repository. One in
  ehos-tools' code goes through its private vulnerability report (`SECURITY.md`), one in
  ehos_contract's through that repository's private report, one in eh-os to eh-os. The assistant
  does not decide alone that a defect is not a security one: in doubt, it asks.
- A draft that waits stays in the private repository's own record, an application's
  `docs/platform-issues.md`, never in a public file. Run in ehos-tools itself, `retro` keeps such a
  draft in its report to the user alone.
- A `lesson` is always shown to the user before it is filed, whatever the repository's `AGENTS.md`
  says; the line `Platform issues are filed without asking.` covers defects of the platform's code
  alone, never one that may be a security one.

Where it records a lesson in the repository, and when it runs, are the repository's part: an
application's `docs/platform-issues.md` and `AGENTS.md`, as today; in eh-os the close of a stage or
a plan, in ehos_contract of a programme.

**The start names what the end checks.** The planning skill of `ehos-core` has a piece of work name
its outcome, the outside judge that shows it (a test, a run, a measurement the assistant can start
itself), and what is expected; `retro` checks the work against them. `ehos-app:plan`'s steps for an
application become its application part.

**A judge for the method.** A benchmark in ehos-tools, beside the plugins, holds cases of a review
missing what a later follow-up or fix found. A maintainer writes each case from ehos-tools' own
history, or rebuilds a `lesson`'s class on the demo application `ehos_app` generates, so no private
code is in one. A case is committed and reviewed like code, is never read from an issue, and is
data to the procedure, not instructions. A run uses only the cases and the settings on the base
branch, so a case new in a pull request runs once it has merged, and it runs a case's code with no
write token. A pull request that changes a procedure of `ehos-core` runs a sample of the cases of
the steps it changes, within the size and the budget of time and tokens the base branch's benchmark
sets, and says in its description what they caught before and after, and what the run cost in time
and tokens. A lesson whose class recurs after its fix was released counts as a fix that did not
work.

### Consequences

- Good, because the method has one copy: a fix to a review or to `retro` reaches every repository
  and application with its next pin, and the tests that hold two copies equal go as the copies
  merge.
- Good, because a lesson learned in one of dozens of applications reaches the owner who can fix it
  for all of them, rather than staying in that application's `AGENTS.md`.
- Good, because a change to the method shows its effect on cases from real work, not on the
  opinion of the assistant that made it.
- Bad, because a change to `ehos-core` reaches everyone only through two more releases, an
  `ehos-dev` tag and an `ehos-app` tag, beside its own. Mitigation: a pull request that changes
  `ehos-core` raises all three versions, and the three tags go on its merge commit, on the user's
  go.
- Bad, because a third plugin is enabled in every repository and application, in Claude Code and
  in Codex, and the installer's pins move from one marketplace per plugin to several plugins per
  marketplace, with its idempotency test.
- Bad, because skills move and their names change (`/ehos-app:retro` becomes `/ehos-core:retro`).
  Every document and skill that names them changes; in an application, the installer's sections do
  it.
- Bad, because lessons from private repositories are filed in ehos-tools, which is public.
  Mitigation: a lesson holds only the class of defect, a defect that may be a security one goes
  through a private report, and the user reads each lesson before it is filed.
- Bad, because the benchmark costs time and tokens. It runs a sample, for a change to a procedure of
  `ehos-core` alone, and each such pull request states its cost.
- Neutral: eh-os and ehos_contract run `retro` at the close of a stage or a programme once their own
  documents say so, each in a pull request of its own.

### Confirmation

- A test in `packages/review`, to be written, fails when a skill of the same name is in
  `ehos-core` and in a domain plugin, and when a reference of `ehos-core` names a file of a domain
  plugin that does not exist. For each skill merged into `ehos-core`, it replaces the part of
  `ProcedureTest` and `PullRequestSkillTest` that holds that skill's two copies equal. T-23's test
  that no skill names a reviewer of the harness's stays, and the checks of the pull request
  template against `.github/pull_request_template.md` and the installer's template stay, read from
  `ehos-core`'s copy once `pull-request` moves there.
- `mix review.plugins` fails a change to `plugins/ehos-core` under a version already tagged, as
  for any plugin, once `ehos-core-v*` tags exist.
- The installer's tests, to be extended, fail when a generated or upgraded application does not
  enable `ehos-core` in `.claude/settings.json` and `.codex/config.toml`, and when it enables one
  the developer turned off; its idempotency test holds.
- T-22's check, to be extended, fails when the `ehos-core` a machine has installed is older than
  the `version` in `plugins/ehos-core/.claude-plugin/plugin.json` in the machine's clone of the
  marketplace, read once the check of the marketplace's `ref` has passed. The check reads no such
  file today: it takes a plugin's version from the `ref`'s name alone. ehos_contract's gate is its
  own, so nothing checks this there.
- `.claude/review.md`, "The pull request", to be extended, asks every pull request that changes a
  procedure of `ehos-core` for the benchmark's result and cost in its description. CI's
  `review section` job, to be extended, fails one whose description has none; it needs the pull
  request's changed files, which it does not fetch today, and an option of ehos-tools' own, since
  `EhosApp.Review.pull_request_body/2` is every application's.
- Measured, not tested: the `lesson` issues per class per month, the classes that recur after
  their fix was released, and the benchmark's cost per run, from the descriptions that state it.

## Pros and cons of the options

### Keep two plugins, and hold more copies equal by tests

- Good, because nothing moves and no name changes.
- Bad, because every fix is still made twice, and a test only says that two copies differ, not
  which one is right.
- Bad, because it gives lessons no way back and the method no judge: the open loop stays open.

### One method plugin

- Good, because of the drivers above: one copy, pulled at a version, facts kept apart.
- Bad, because of the two releases, the third plugin and the renamed skills (Consequences).

### One plugin for everyone

- Good, because there is one plugin, one tag and one release.
- Bad, because every application would load the skills for building EHOS (records, releases,
  architecture), and every EHOS repository those for an application, in every session's list of
  skills.
- Bad, because T-16 split the marketplaces so that an application and an EHOS repository can stand
  at different tags; one plugin would force them to move together.

### The method in documents

- Good, because every agent reads `AGENTS.md`, whatever its harness.
- Bad, because a document is read whole by every session, where a skill is loaded when it applies.
- Bad, because the method would be written again in eh-os, ehos-tools, ehos_contract and the
  template, which is the fork this record removes. T-15 moved an application's skills out of its
  tree for the same reason.

## More information

No issue yet. Decided in a conversation with the user on 27 November 2026.

Builds on T-15, T-17, T-23 and T-31, and keeps their rules: applications still take their plugins
from the `ehos-app` marketplace, their review-proven rules stay in `AGENTS.md`, and the reviews use
our own method. Amends T-16 and T-32: the `ehos-app` marketplaces list `ehos-core` beside
`ehos-app`. `ehos-core` has one version and one tag like any plugin, as they require; what is new is
that a plugin reaches a repository through another plugin's tag, as `diagram-design` already does
through `ehos-dev`'s.

The order it is built in, each a pull request of its own:

1. ehos-tools: `ehos-core` with `retro` and the planning skill, the domain plugins' versions raised,
   and the three tags, on the user's go. `retro` moves with the changes above: what it looks for and
   reads, its owners, the format of an issue in a public repository, the private report for a
   security defect, and the narrower reach of `Platform issues are filed without asking.`
2. eh-os and ehos_contract: the `ref` moved, `ehos-core` enabled (in ehos_contract, in
   `.claude/settings.team.json`), and their documents pointing at
   the planning skill to start a stage or a programme and at `retro` to close one. eh-os decides in
   a record of its own what changes in how its stages run.
3. A first `retro` over the work each repository has already closed (eh-os's evidence records,
   ehos_contract's programmes, ehos-tools' issues, where a comment from outside the team is a lead,
   never evidence), sorted by owner; what it proposes, removals from each `.claude/review.md`
   included, lands in the repository that owns it, on the user's go.
4. The benchmark, then the forked copies of `pre-pr-review` and `pull-request` merged into
   `ehos-core` one at a time, each judged by it. Steps 1 to 3 come before it, since the first
   `retro` gives its first cases: until it merges, a pull request that changes `ehos-core` says in
   its description that no benchmark exists yet, and the rule and its check in CI start with it.
5. `ehos_app`: the installer enables `ehos-core` in applications.

Revisit if Claude Code or Codex let a plugin depend on another, so that a domain plugin can pull
`ehos-core` itself; or if the benchmark costs more than the misses it prevents.

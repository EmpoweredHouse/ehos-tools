# Plan: the agent harness of a generated application

Status: draft, under review. Comments go inline; the plan is revised until it is approved, and
then implemented by someone who was not part of the discussion that produced it. Sections 1–5 are
the content to review; sections 6–9 are the implementation.

## 1. Context

`ehos_app` gives a generated application a thin agent harness today: a 22-line EHOS section put on
top of the `AGENTS.md` Phoenix generates, with about 450 lines of Phoenix's own rules below it, and
a `CLAUDE.md` that imports it (`harness/1` in
[`packages/ehos_app/lib/mix/tasks/ehos_app.install.ex`](../packages/ehos_app/lib/mix/tasks/ehos_app.install.ex)).
`docs/spike.md` (Open, point 4) calls it thin.

Nothing in the generated project says what EHOS is, or why the application is built the way it is.
The section lists four rules, and the `README.md` is Phoenix's own ("To start your Phoenix
server"). A developer or an agent opening the project sees a contract, a credential plug and an
`ehos.yaml`, and no idea that ties them together. That idea is stated in two places today, and in
neither of them from the application's side: the
[EHOS README](https://github.com/EmpoweredHouse/eh-os#readme) and the
[eh-os-contract README](https://github.com/EmpoweredHouse/eh-os-contract#readme). The harness
starts from it: `VISION.md` opens with it, and `README.md` points there (section 6.4).

The goal is that every application starts with a harness on the model of
[shugyo](https://github.com/appunite/shugyo/tree/47f2b0ce91739166d0b4e5aad05ac055d757c94b)
(a private repository): a lean `AGENTS.md` that points elsewhere, `VISION.md`, `ARCHITECTURE.md`
and `TESTING.md`, topic docs as present-tense contracts, skills, a check that keeps the docs honest,
and CodeRabbit. A few things come from
[block/buzz](https://github.com/block/buzz/tree/639593bba97b4ed1386d5128bceecfab2072df31), whose
harness shugyo's largely derives from.

The EmpoweredHouse design system is out of scope: it comes later, on a branch of its own. The
harness already mentions it where it matters, with a placeholder path (section 6.6), so that
adding it later changes one value and no harness file.

Every file the harness adds is one of three kinds:

- **(a) static**: the same in every application, created once, then the developer's;
- **(b) seed**: an EEx template filled from the application (its name, domain, ports, paths),
  created once, then the developer's;
- **(c) managed**: a section between two markers, rewritten by a tool (the installer, or
  `mix usage_rules.sync` if section 3 is adopted), with the rest of the file left alone.

The installer's rules stay as they are: it is idempotent, and it never overwrites a file that
exists (`create_new_file(..., on_exists: :skip)`).

## 2. Decisions already made

Taken from the comparison of buzz and shugyo.

| Element | Decision | Why |
| --- | --- | --- |
| `AGENTS.md` | Lean, as in shugyo: at most 200 lines, pointing to the docs that hold the detail | buzz's is 794 lines in one file; Claude Code's own guidance is under 200 lines per instruction file |
| `CLAUDE.md` | Keeps `@AGENTS.md` (a file, not a symlink) | Claude Code reads `AGENTS.md` natively only when no `CLAUDE.md` or `CLAUDE.local.md` is on the path, and not before v2.1.277 ([docs](https://code.claude.com/docs/en/memory#agents-md)); a developer's `CLAUDE.local.md` would silently switch it off. A symlink is checked out as a one-line text file on Windows, and Claude's Edit and Write refuse to write through one |
| `README.md` | Phoenix's is replaced by a seed with a short managed section: what EHOS is in two sentences, a pointer to `VISION.md`, and where each part of the ecosystem documents itself (section 6.4, Appendix A.2) | It is the first thing a person or a reviewer on GitHub reads, and nothing in the project explains the ecosystem today. The parts and their links follow the pinned versions, so the section is managed |
| Product Contract | Yes: read the vision before changing anything, and name a conflict with it | Same in buzz and shugyo |
| Reviewing | A `review` skill, as in shugyo | |
| Before opening a PR | shugyo's `ship` skill. Two steps from buzz are proposed for it (section 5.3) | shugyo lets the agent mark the PR ready itself; buzz requires a human to test it first |
| Ecosystem | No section of its own. How the application learns about EHOS and its libraries, from the versions it pins, is section 3 | |
| Repo structure | Yes, in `AGENTS.md`, as in shugyo | |
| Quality gates | Unchanged: `mix precommit` and the generated CI. The one addition is the harness test (section 4) | shugyo's Elixir gates are the same as ours; its husky hook is a subset of `precommit` |
| Review-proven rules | Yes, as in shugyo: an empty heading and the method | The rules come from an application's own review history, which a new one has none of |
| Key patterns, gotchas | Yes, as in shugyo | |
| Nested `AGENTS.md` | At least one pair, `AGENTS.md` and `CLAUDE.md`, in `lib/<app>/contracts/`, holding the rules for writing contracts. Possibly more, the first candidate being `lib/<app>_web/` (section 4). None per contract | A contract is its own specification; a file per contract would repeat it |
| `VISION.md` | One, in shugyo's shape, with placeholders, opened by a managed section on what EHOS is, where the application sits in it, and the principles it inherits (section 6.4, Appendix A.1). A skill that writes the rest comes later | buzz's eight `VISION_*.md` files are for a product with many areas. The Product Contract makes `VISION.md` the first read of every change, so the platform's idea is read where the application's is |
| `ARCHITECTURE.md` | One, in shugyo's shape | |
| `TESTING.md` | One for the application | |
| `docs/` | Topic docs as in shugyo, ruled by its Docs rules | |
| Plans | Skills `plan` and `ship` write to `.plans/`, which the generated `.gitignore` ignores | As in shugyo; plans are history, not current truth |
| Skills | Copied from shugyo under the copy protocol (section 5), canonical in `.agents/skills/`, symlinked from `.claude/skills/` | Claude Code reads nothing under `.agents/`. What is copied must stay a copy until each change is approved |
| PR template | Yes | |
| AI review | CodeRabbit, configured as in shugyo | |
| Docs check | Yes: shugyo's rules, plus its automated check as an ExUnit test (section 4) | |
| Phoenix's rules | Out of the root `AGENTS.md`. Where they go depends on section 3: `docs/phoenix.md`, or links to the pinned Phoenix's own rules | They are about 450 of the file's lines today |
| Design | Out of scope; mentioned with a placeholder path (section 6.6) | A branch of its own |
| Left out | `VISION_*.md`, `CONTRIBUTING.md`, `CONTEXT.md`, a committed `PLANS/`, Sobelow, buzz's `buzz-review-completed` marker, git hooks | |

## 3. For discussion: the ecosystem's docs, from the versions the application pins

**The question.** Could the application's harness be fed from the pinned versions of the
ecosystem's repositories, rather than describing them itself or linking to GitHub, whose `main`
may be ahead of what the application runs?

**What the application has locally today.**

| Part of the ecosystem | Present in the generated project | What it carries for an agent |
| --- | --- | --- |
| `eh_os_contract` | `deps/eh_os_contract/packages/eh_os_contract/` (a `sparse:` git dep, pinned to one commit) | `README.md`, `docs/contract.md`, `docs/rules.md`, `docs/authorization.md`, `docs/dsl/*.md` |
| `eh_os_contract_auth` | `deps/eh_os_contract_auth/packages/eh_os_contract_auth/`, the same commit | `README.md` |
| `ehos_app` | `deps/ehos_app/packages/ehos_app/`, in `:dev` only | `README.md`, `CHANGELOG.md` |
| EHOS itself | Nothing but `.ehos/ehos.yaml.v1.json`, the copy of its schema | No description of the platform at all. The managed sections of `VISION.md` and `README.md` (6.4) fill this gap, whichever way section 3 goes |
| Phoenix | `deps/phoenix/usage-rules/*.md`, the pinned version's rules for agents | Its rules, the same text `phx.new` copies into `AGENTS.md` today |

**Recommendation: `usage_rules`, the community's tool for exactly this.**
[`usage_rules`](https://hexdocs.pm/usage_rules) (1.2.8; Ash's maintainers) is how Elixir packages
ship rules for agents, and the markers in the `AGENTS.md` Phoenix generates
(`<!-- usage-rules-start -->`, `<!-- phoenix:html-start -->`) are its format. AGENTS.md's
"compose, don't copy" points to it rather than to a mechanism of our own.

- A package ships `usage-rules.md`, optional sub-rules in `usage-rules/*.md`, and optional skills
  in `usage-rules/skills/<name>/SKILL.md`.
- The application lists, in `mix.exs`, which packages' rules it takes, and whether each is inlined
  or linked:
  `usage_rules: [file: "AGENTS.md", usage_rules: [{:eh_os_contract, link: :markdown}, ...]]`.
- `mix usage_rules.sync` rewrites the block between the markers from the versions in `deps/`, and
  builds the packages' skills into `.claude/skills/`. It is an Igniter task, so `--check` fails
  when the block is stale, which is what a gate needs.
- It ships an Igniter installer, so `ehos_app` composes it as it composes Oban's.

How it would fit:

- **EHOS's own rules** (the platform section of today's `AGENTS.md`) move into `ehos_app`'s
  `usage-rules.md`. `ehos_app` is already the package that encodes what EHOS requires, and the
  application pins it.
- **`eh_os_contract` and `eh_os_contract_auth`** each ship a `usage-rules.md` that points into
  their `docs/`. Writing contracts could become a skill they ship
  (`usage-rules/skills/`), versioned with the engine rather than copied into every application.
- **Phoenix's rules** are linked from the pinned `deps/phoenix/usage-rules/` instead of being
  copied in, so they follow a Phoenix upgrade. `phx.new` also writes about 45 lines of its own
  that are in no package (Phoenix 1.8's layouts and components, Tailwind v4's import syntax);
  those would go to `lib/<app>_web/AGENTS.md` (section 4), or to `docs/phoenix.md`.
- **A later version reaches existing applications** through `mix deps.update` and
  `mix usage_rules.sync`, with no rerun of the installer. That answers part of open decision 3.

What is missing, or has to be checked first:

1. **`usage-rules.md` in eh-os-contract and in `ehos_app`.** Neither exists; eh-os-contract's is a
   change in another repository.
2. **Sparse dependencies.** `usage_rules.sync` finds a dependency's directory with
   `Mix.Project.deps_paths/0`, which for a `sparse:` dependency is
   `deps/eh_os_contract/packages/eh_os_contract` (checked). It loads the files with globs one
   level deep (`deps/*/usage-rules.md`), though, which may miss them. This needs a spike, and
   perhaps a fix upstream.
3. **Environments.** `ehos_app` is `only: :dev`, `mix precommit` runs in `:test`, and CI fetches
   only `:test`'s dependencies. A `--check` in `precommit` or in CI would need `ehos_app` and
   `usage_rules` in `:test` too. The alternative is running the sync by hand after a dependency
   changes, with no check.
4. **What GitHub sees.** A link into `deps/` cannot be read by CodeRabbit, or by a cloud agent
   that has not run `mix deps.get`. EHOS's rules, which are short and matter most, could be
   inlined; Phoenix's, which are long, linked.
5. **`.claude/skills/`** would hold both the packages' skills, written by `usage_rules`, and the
   symlinks to `.agents/skills/`. The harness test has to accept both.

The fallback, if this is not adopted: the installer keeps a managed section of its own in
`AGENTS.md` (as today, with a "Platform" table of the paths above), and Phoenix's `AGENTS.md` is
moved to `docs/phoenix.md`.

## 4. What a generated project looks like

The recommended variant of section 3.

```text
shop/
├── AGENTS.md                         b + c   ≤200 lines: the usage_rules block, then the application's own
├── CLAUDE.md                         a       "@AGENTS.md"
├── README.md                         b + c   the application, then "Built on EHOS": a pointer and the parts' docs
├── VISION.md                         c + b   "EHOS, and where this application sits", then shugyo's shape
├── ARCHITECTURE.md                   b       shugyo's shape, filled with what the installer knows
├── TESTING.md                        b
├── .agents/skills/<name>/            a       plan, ship, review, elixir-anti-patterns-review
├── .claude/skills/<name>             link    → ../../.agents/skills/<name>; plus the packages' skills
├── .coderabbit.yaml                  b
├── .github/pull_request_template.md  b
├── .gitignore                        + `.plans/`
├── lib/shop/contracts/AGENTS.md      c (+ the application's own part)
├── lib/shop/contracts/CLAUDE.md      a       "@AGENTS.md"
├── lib/shop_web/AGENTS.md, CLAUDE.md candidate: the web layer, Phoenix's own lines, the design system
└── test/harness_test.exs             b
```

**Nested `AGENTS.md` files.** `lib/<app>/contracts/` is decided. The generated project also has a
web layer, `lib/<app>_web/` (the router, the controllers, `core_components.ex`, the layouts, the
health plug), which is where Phoenix's own lines and the design system belong. Whether it gets a
pair of its own, and whether any other directory does, is settled during implementation; the root
`AGENTS.md` names every nested one. Each needs its `CLAUDE.md` beside it, since with a `CLAUDE.md`
at the root, Claude Code reads a nested `AGENTS.md` only through one.

**`test/harness_test.exs`.** It is a test, not documentation: an ExUnit test that checks the
harness, so it lives in `test/` and ends in `.exs`, the extension of every Elixir test file
(`mix test` compiles them as scripts). It does what shugyo's
[`scripts/check-docs.sh`](https://github.com/appunite/shugyo/blob/47f2b0ce91739166d0b4e5aad05ac055d757c94b/scripts/check-docs.sh)
does, as a test rather than a shell script, because Mix is the application's only entry point and a
test runs in `mix precommit` and in CI with nothing else to wire. It checks that:

- relative links in the harness's markdown resolve, and so does every `docs/*.md` a file names;
- files stay within their line budgets: 200 for `AGENTS.md`, `README.md`, `VISION.md` and each
  `SKILL.md`; 400
  for `ARCHITECTURE.md` and `docs/*.md`; 300 for `TESTING.md`;
- nothing cites an ADR, since decisions live in the Decisions section of the doc they govern;
- every `.agents/skills/*` has its symlink in `.claude/skills/`.

## 5. What is copied from shugyo, and how

What is copied must stay recognisable as a copy until each change to it has been approved.

### 5.1 The protocol

1. **Copy.** The file goes in verbatim, in a commit of its own, whose message names its source path
   and shugyo's commit.
2. **Mechanical changes only.** A second commit makes the changes listed for that file in 5.3 as
   mechanical, such as a name. They change no step and no logic.
3. **Proposals.** Every other change is listed in 5.3 as a proposal, with its reason. None is made
   until it is approved. An approved one is a commit of its own, so each can be read, and reverted,
   alone.

### 5.2 What each file is

| File in the application | Kind | Source |
| --- | --- | --- |
| `.agents/skills/plan/` | copy | [`plan`](https://github.com/appunite/shugyo/tree/47f2b0ce91739166d0b4e5aad05ac055d757c94b/.agents/skills/plan) |
| `.agents/skills/ship/` | copy | [`ship`](https://github.com/appunite/shugyo/tree/47f2b0ce91739166d0b4e5aad05ac055d757c94b/.agents/skills/ship) |
| `.agents/skills/review/` | copy | [`review`](https://github.com/appunite/shugyo/tree/47f2b0ce91739166d0b4e5aad05ac055d757c94b/.agents/skills/review), with `references/checklist.md` |
| `.agents/skills/elixir-anti-patterns-review/` | copy | [`elixir-anti-patterns-review`](https://github.com/appunite/shugyo/tree/47f2b0ce91739166d0b4e5aad05ac055d757c94b/.agents/skills/elixir-anti-patterns-review), with `references/` |
| `.coderabbit.yaml` | copy | [`.coderabbit.yaml`](https://github.com/appunite/shugyo/blob/47f2b0ce91739166d0b4e5aad05ac055d757c94b/.coderabbit.yaml) |
| Docs rules, in `AGENTS.md` | copy | [`AGENTS.md`, Docs rules](https://github.com/appunite/shugyo/blob/47f2b0ce91739166d0b4e5aad05ac055d757c94b/AGENTS.md#L124) |
| `test/harness_test.exs` | port: the same checks, in Elixir | [`scripts/check-docs.sh`](https://github.com/appunite/shugyo/blob/47f2b0ce91739166d0b4e5aad05ac055d757c94b/scripts/check-docs.sh) |
| `VISION.md`, `ARCHITECTURE.md`, `TESTING.md` | shape only: shugyo's headings, new content | shugyo's [`VISION.md`](https://github.com/appunite/shugyo/blob/47f2b0ce91739166d0b4e5aad05ac055d757c94b/VISION.md), [`ARCHITECTURE.md`](https://github.com/appunite/shugyo/blob/47f2b0ce91739166d0b4e5aad05ac055d757c94b/ARCHITECTURE.md), [`TESTING.md`](https://github.com/appunite/shugyo/blob/47f2b0ce91739166d0b4e5aad05ac055d757c94b/TESTING.md) |
| `AGENTS.md`, the rest | new, in shugyo's shape | |
| PR template | new | |

### 5.3 Changes per copied file

Each one is marked **mechanical** (made in step 2) or **proposal** (made only once approved).

- **All copies**: "Shugyo" becomes the application or EHOS, as the sentence means (mechanical).
  Paths of shugyo's that do not exist in the application are listed, not changed (proposal).
- **`plan`**: still writes to `.plans/` (no change). Drop the Linear steps (proposal: EHOS
  applications have no Linear project of their own).
- **`ship`**:
  - `make check-<app> && make test-<app>` becomes `mix precommit` (proposal: the application has
    one app and no Makefile);
  - drop Linear and SHU ids (proposal);
  - in §8, run `review` before `gh pr ready` (proposal, from buzz);
  - in §8, give the human the steps of a manual test and wait for their confirmation, never
    marking it done itself (proposal, from buzz's
    [Before opening a PR](https://github.com/block/buzz/blob/639593bba97b4ed1386d5128bceecfab2072df31/AGENTS.md#L28));
  - drop "never add Co-Authored-By" (proposal: it is shugyo's policy, not EHOS's).
- **`review`**: replace shugyo's lenses (tenancy, frozen contracts and mirrors, the wiki's writers)
  with EHOS's: contracts, the credential plug, `ehos.yaml`, migrations before start, another
  application's data, docs in the same PR (proposal).
- **`elixir-anti-patterns-review`**: drop what is about shugyo's umbrella and tenancy (proposal).
- **`.coderabbit.yaml`**: drop the epic branches (proposal: an application branches from `main`);
  `path_instructions` names `contracts/AGENTS.md` for `lib/*/contracts/**` (proposal); empty the
  "do not flag" list, which is about shugyo's code (proposal).
- **Docs rules**: drop the line about `.plans/` only if section 3 or a review changes where plans
  live (no change otherwise).

## 6. Stage 1: the installer and the harness

In `packages/ehos_app/lib/mix/tasks/ehos_app.install.ex`, today's `harness/1` (`:474`) and
`with_agents_section/2` (`:487`) are replaced by small steps in the `install/2` pipeline (`:145`).
They reuse `render/2` (`:607`), `write_template/4` (`:594`) and `copy_file/3` (`:602`), and the
conditional `add_task` that `release/1` (`:464`) uses. Section 3 decides between two variants of
6.1; the rest holds for both.

### 6.1 `AGENTS.md`

**If section 3 is adopted:**

- `ehos_app` composes `usage_rules`'s installer (`installs:` in `info/2`, beside Oban's), and sets
  `usage_rules:` in `mix.exs`: `ehos_app` and `eh_os_contract` inlined, `eh_os_contract_auth` and
  `phoenix` linked, and `phoenix`'s sub-rules as the application uses them (elixir, phoenix, ecto,
  html, liveview).
- Phoenix's `AGENTS.md` is replaced by the seed `agents.md.eex` (b), keeping its
  `<!-- usage-rules-start -->`…`<!-- usage-rules-end -->` block, which the sync then fills.
  Phoenix's own ~45 lines go to `lib/<app>_web/AGENTS.md` or `docs/phoenix.md` (section 4).
- `packages/ehos_app/usage-rules.md` holds what today's section holds, and more (see the content
  below). eh-os-contract gets its own, in that repository.
- After a spike: whether `usage_rules.sync` reads the `sparse:` dependencies (section 3, point 2).

**If it is not:** the installer keeps a managed section between `<!-- ehos_app:agents -->`
markers, as today:

| The file | The installer |
| --- | --- |
| Has no marker, and has `<!-- usage-rules-start -->` (it is Phoenix's) | Moves it with `Igniter.move_file/3` to `docs/phoenix.md`, then writes the seed `agents.md.eex` (b), which holds the managed section |
| Has no marker and no Phoenix content (an existing project's own file) | Puts the managed section at the top, as today |
| Has both markers | Replaces the managed section alone. The marker keeps its name, so a project generated by 0.2.x gets the new section too |
| Has the start marker without the end one | Leaves the file alone, as today |

**The content, in either variant.** The platform part (in `ehos_app`'s `usage-rules.md`, or in
the managed section) holds:

- what EHOS is, in three lines: the question it answers, and that the contract is the agreement
  the application is checked against; then a pointer to the top of `VISION.md` for the rest;
- the Product Contract: read `VISION.md`, then `ARCHITECTURE.md`, then `TESTING.md`; name any
  conflict with the vision;
- EHOS's rules:
  - a business fact is an event declared in a contract;
  - every command arrives with a credential, verified by `EhOsContract.Auth.Plug`;
  - `ehos.yaml` states what is needed, never how it is provided;
  - never read another application's data;
  - no DDL while the application runs; a column is dropped in two deploys, since migrations run
    before the new release starts;
- where each part of the platform documents itself (section 3's table);
- shugyo's Docs rules (section 5);
- pull requests: opened as drafts, made ready by the `ship` skill;
- the gate: `mix precommit`;
- the skills, one line each;
- the design system, for work on the UI (6.6).

The application's own part holds: the repo structure (seeded with what the installer knows), an
"area → doc" table, the nested `AGENTS.md` files, key patterns and boundaries, gotchas, and
review-proven rules (an empty heading and shugyo's method).

### 6.2 Nested `AGENTS.md` files

`lib/<app>/contracts/AGENTS.md` (c, with markers of its own, for example `ehos_app:contracts`)
and `CLAUDE.md` (`@AGENTS.md`), written without `--example` as well. The managed part links to
`contract.md`, `rules.md`, `authorization.md`, `dsl/contract-dsl.md` and `dsl/domain-dsl.md` in
the directory `@contract_docs` (`:69`) is in, and states the rules:

- a business fact is an event;
- a command is a capability;
- how publications are named
  ([eh-os-contract#50](https://github.com/EmpoweredHouse/eh-os-contract/issues/50));
- every command has a test;
- `mix eh_os_contract.check`.

If eh-os-contract ships these rules itself (section 3), the managed part becomes a pointer to them.
Any further pair (first `lib/<app>_web/`) follows the same pattern.

### 6.3 `CLAUDE.md`

Unchanged: `create_new_file` with `@AGENTS.md`.

### 6.4 Seeds

All through `write_template/4`.

- **`VISION.md`**: a seed that opens with a managed section, between `<!-- ehos_app:vision -->`
  markers, then shugyo's sections.
  - The managed section, "EHOS, and where this application sits" (Appendix A.1), is the one place
    the harness explains the ecosystem. It says what EHOS is for, what an EHOS application is
    within it (one part of the company's operating system, owning its process, its rules and its
    data, and cooperating with the others only through contracts), and which of EHOS's principles
    this application inherits, so that its own may not contradict them.
  - It is in `VISION.md` because the Product Contract (6.1) already makes reading `VISION.md` the
    first step of every change, and "name a conflict with the vision" then covers EHOS's
    principles as well as the application's. Neither would hold in the README.
  - Then shugyo's sections, each with an HTML comment saying what goes in it:
    - the process this application owns, and who owns it: the person who approves its contracts;
    - the thesis, and a scenario in a blockquote;
    - who it is for;
    - principles, numbered, used to settle a design question;
    - what it will not do, including what belongs to another application;
    - where it is heading, and what is still open.
- **`README.md`**: a seed around a short managed section, between `<!-- ehos_app:readme -->`
  markers (Appendix A.2).
  - The seed: the application's name in the H1, one line saying what it does (an HTML comment
    until the developer writes it), getting started (`mix setup`, `mix phx.server`,
    `mix precommit`), and a pointer to `AGENTS.md` for agents.
  - The managed section, "Built on EHOS": two sentences on what EHOS is, a pointer to
    `VISION.md` for the idea, and a table of the parts of the ecosystem: what each is, and where
    its docs are at the version the application pins. It does not repeat `VISION.md`.
- **What both managed sections share.**
  - They are rewritten by the installer, whichever way section 3 goes, since `usage_rules` writes
    only `AGENTS.md`: the idea is stable, but the parts, the links and the principles follow the
    pinned versions.
  - They follow 6.1's fallback table. A missing file is written from the seed. Phoenix's README, recognised by its "To start your Phoenix
    server", is replaced by the seed; a file of the project's own gets the section at the top; a
    file with both markers has the section alone replaced; one with the start marker only is left
    alone.
  - Paths into `deps/` are inline code, not links: GitHub, CodeRabbit and the harness test before
    `mix deps.get` cannot resolve them (section 3, point 4). EHOS's own docs are linked on GitHub.
  - They say nothing that holds for one application only, so that rewriting them never loses the
    developer's words. They need no `--example`: they name `lib/<app>/contracts/`, not the example
    contract.
- **`ARCHITECTURE.md`**: shugyo's shape, starting from "where this document and the code disagree,
  the code is right". Filled with:
  - the supervision order: Repo → Oban → EhOsContract → EhOsContract.Auth → Health → Endpoint;
  - ports 4000 and 4001, and the health endpoints;
  - configuration from the variables EHOS gives an application;
  - `DATABASE_SCHEMA` as the search path and as Oban's prefix;
  - `domain.ex` and `contracts/`;
  - the web layer, styled by the design system (6.6);
  - the image and the manifest built by CI;
  - Decisions: EHOS's D-51, D-55 and D-56, each with what was chosen, why, and what was rejected;
  - Known limitations: `eh_os_contract`'s migrations assume the `public` schema; an application
    with a dash in its name publishes nothing.
- **`TESTING.md`**: how to run the tests; how to test a contract's command (the pattern of
  `entries_test.exs.eex`); `subscriptions: :manual` and `pin_keys`; the health, `ehos.yaml` and
  harness tests.
- **`.github/pull_request_template.md`**: What changed / How to test (automated and manual) /
  What to look at, then checkboxes:
  - `mix precommit` passes;
  - docs updated in this PR;
  - a contract or `ehos.yaml` changed;
  - tested by a human.
- **`.coderabbit.yaml`**: the copy (section 5).
- **`test/harness_test.exs`**: section 4. `ExUnit.Case, async: true`, no database.

### 6.5 Skills, symlinks, `.gitignore`

- **Skills**: kept in `packages/ehos_app/priv/templates/ehos_app.install/skills/<name>/`, as section
  5 produces them, and installed with `copy_file/3` into `.agents/skills/<name>/`.
- **Symlinks**: Igniter and Rewrite write files only; neither can make a symlink (checked in
  `deps/igniter` and `deps/rewrite`). A new task,
  `packages/ehos_app/lib/mix/tasks/ehos_app.link_skills.ex`, makes `.claude/skills/<name>` with
  `File.ln_s/2` for every `.agents/skills/*` that has none. The installer schedules it with
  `Igniter.add_task/3` only when a link is missing, as `release/1` does with `phx.gen.release`, so
  the idempotence test, which pins that a second run schedules nothing, stays green.
- **`.gitignore`**: `Igniter.create_or_update_file/4` adds `.plans/`, only when the line is not
  there.

### 6.6 The design system's placeholder

One module attribute in the installer, for example
`@design_system "path/to/design-system"`, is the only place its location is written. Only managed
content (6.1, 6.2) mentions it, so changing the attribute and rerunning the installer, or the sync,
updates every application without touching a seed. It is written as inline code, not as a link,
so the harness test does not fail on it; it becomes a link when the path is real. It is mentioned:

- in the platform part of `AGENTS.md`: build or change a view by the design system;
- in `lib/<app>_web/AGENTS.md`, if that pair is made;
- in `ARCHITECTURE.md`'s web layer, as a pointer to `AGENTS.md` rather than to the path, since a
  seed is never rewritten.

### 6.7 Tests and docs

Tests, in `packages/ehos_app/test/ehos_app_install_test.exs`: `describe "the agent harness"`
(`:339`) is rewritten. It pins that:

- Phoenix's `AGENTS.md` is replaced (or moved, in the fallback), and its content is kept;
- the seeded `AGENTS.md` has at most 200 lines;
- a 0.2.x project's section is replaced, and the rest of its file kept;
- a file without the end marker is left alone;
- every seed is written, and never overwritten;
- Phoenix's `README.md` is replaced; a project's own `README.md` or `VISION.md` gets its section
  on top; a file with both markers has the section alone replaced, and the rest kept;
- `contracts/AGENTS.md` is written without `--example` too;
- `ehos_app.link_skills` is scheduled only when a link is missing;
- `.plans/` is added once;
- the design system's path appears in managed content only.

The idempotence test (`:442`) covers the rest. The task gets a test of its own, on a temporary
directory.

Docs, in the same PR:

- `README.md`: the "What you get" tree;
- `AGENTS.md`: the diagram's `.tool-versions, AGENTS.md section, CLAUDE.md, CI workflow` line;
- `packages/ehos_app/README.md`: the table's `AGENTS.md` row, and rows for `VISION.md` and
  `README.md`;
- `docs/spike.md`: Open, point 4;
- `packages/ehos_app/CHANGELOG.md`, under `Unreleased`.

## 7. Stage 2: the release

`ehos_app` 0.3.0, in a PR of its own as #7 was: the tag `ehos_app-v0.3.0`, the pin in
`packages/ehosctl/lib/ehosctl/template.ex:21`, and `packages/ehosctl/CHANGELOG.md`.

## 8. Verification

1. `mix check` in `packages/ehos_app` and `packages/ehosctl`, from a checkout whose path has no dot
   directory (`AGENTS.md`, "Traps already found").
2. A fresh project:
   `mix igniter.new demo --with phx.new --install ehos_app@path:<absolute path to packages/ehos_app> --example --yes`.
   Check that:
   - its tree is section 4's;
   - `AGENTS.md` has at most 200 lines;
   - Phoenix's rules are where section 3's decision put them, and complete;
   - the symlinks resolve;
   - `.gitignore` has `.plans/`;
   - `VISION.md` and `README.md` are the seeds, their managed sections are Appendix A's, and
     every path they name into `deps/` exists;
   - `mix ecto.setup && mix precommit` passes, `harness_test.exs` included;
   - with section 3 adopted, `mix usage_rules.sync --check` passes.
3. A second `mix ehos_app.install` in it leaves `git status` clean.
4. A project generated from `ehos_app-v0.2.1` (`EHOSCTL_TEMPLATE_SOURCE=ref:ehos_app-v0.2.1`), then
   installed over with the new version: its section replaced, the new seeds added, nothing else
   changed.
5. Claude Code in `demo/`: `/memory` lists `CLAUDE.md` and `AGENTS.md`; the skills are listed;
   reading a file in `lib/demo/contracts/` loads `contracts/CLAUDE.md`.
6. The end-to-end path through the binary (`AGENTS.md`, "Trying a change end to end"), and CI's
   `e2e` job.

## 9. Open decisions

1. **Section 3.** `usage_rules`, or the installer's own managed section. Adopting it means a change
   in eh-os-contract, and settling points 2 and 3 there.
2. **Projects generated by 0.2.x.** Fresh projects get the new layout. In an existing one, only
   the managed section is replaced, since the developer may have changed what is below it, and the
   move of Phoenix's rules is documented as a manual step. The alternative is an automatic
   migration.
3. **Updating copies and seeds in existing applications.** Files of kinds (a) and (b) are never
   refreshed by the installer. Section 3 covers what packages ship; the copied skills stay
   `docs/spike.md`'s point 4 (`ehosctl harness update`, a Claude Code plugin, or Igniter upgrade
   steps), outside this plan.
4. **Access to shugyo.** This plan links to shugyo, a private repository of AppUnite's. Whoever
   implements it needs read access, or the files copied out of it first.

## Appendix A: the managed sections, as drafted

The managed sections of 6.4, for review of their wording. `shop` stands for the application's name,
which the installer fills in; nothing else in them varies between applications. Their sources are
the [EHOS README](https://github.com/EmpoweredHouse/eh-os#readme), EHOS's
[VISION.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/VISION.md) and the
[eh-os-contract README](https://github.com/EmpoweredHouse/eh-os-contract#readme); a sentence here
that contradicts them is wrong here.

### A.1 `VISION.md`

````markdown
<!-- ehos_app:vision -->
## EHOS, and where this application sits

This application is one part of a company's operating system built on
[EHOS](https://github.com/EmpoweredHouse/eh-os). EHOS turns business processes into production
applications with explicit rules, controlled access and a traceable history of every action, and
it is built around one question: **does the deployed software still do what the company agreed it
should do?** Tests say a module works, and monitoring says the server is up. Neither notices an
invoice that should have gone out and did not, because there is no error for code that never ran.

### What an EHOS application is

- **It owns one part of the business.** Its process, its words, its rules and its data are its
  own. Other applications do not read its data, and it does not read theirs.
- **Its process is an agreement, written as code.** A domain (the words, the contexts, who acts)
  and a contract per process, in `lib/shop/contracts/`: the commands, the events they may emit,
  the invariants, and the promises made to the person who owns the process, such as "within three
  days of a case being opened, it is filed or flagged for review". That person approves the
  contract, and it is versioned with the rest of the code.
- **What happens is recorded in the same words.** Every command goes through the contract, which
  refuses an actor it does not name and an event it does not declare, and appends what was decided
  to the application's event log.
- **The two are compared, for as long as it runs.** The contract engine reads the log against the
  contract: which declared steps never ran, what happened that nobody declared, which promises
  were broken, and which version of the contract was deployed at the time.
- **It cooperates through contracts.** Its commands are capabilities that people, other
  applications and AI agents use alike, each within the authority EHOS gave them, and the facts
  it shares leave it as events a contract publishes.
- **EHOS runs it from what it declares.** `ehos.yaml` states what it needs (a database, ports,
  health probes), the contracts state what it offers, and EHOS provides, deploys and governs the
  rest. It keeps serving while EHOS itself is stopped.

### Principles it inherits

From [EHOS's vision](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/VISION.md#platform-principles).
This application's own principles, below, may narrow them and never contradict them.

1. A business outcome, not a technical action, is what counts as done.
2. This application owns its meaning, its rules and its authoritative data.
3. It cooperates through explicit contracts, and a change to one accounts for whoever depends on it.
4. People, applications and agents use the same governed commands, within their authority.
5. Automation stays within explicit boundaries; a defined exception needs a human decision.
6. Actions, decisions and outcomes are traceable to who made them, and why.
<!-- /ehos_app:vision -->
````

### A.2 `README.md`

````markdown
<!-- ehos_app:readme -->
## Built on EHOS

This application runs on [EHOS](https://github.com/EmpoweredHouse/eh-os), a platform for software
a company owns that checks the deployed software still does what the business agreed. What that
means for this application, and the principles it follows, are at the top of
[VISION.md](VISION.md).

| Part | What it is | Its docs, at the version this application pins |
| --- | --- | --- |
| [EHOS](https://github.com/EmpoweredHouse/eh-os) | the platform: identity, deployment, governance | its [vision](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/VISION.md) and [architecture](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ARCHITECTURE.md); `.ehos/ehos.yaml.v1.json` is the schema of `ehos.yaml` |
| [`eh_os_contract`](https://github.com/EmpoweredHouse/eh-os-contract) | the contract engine: the domain and contract DSLs, dispatch, the event log, conformance | `deps/eh_os_contract/packages/eh_os_contract/docs/contract.md`, then `docs/dsl/` beside it |
| `eh_os_contract_auth` | verifies the credentials EHOS issues | `deps/eh_os_contract_auth/packages/eh_os_contract_auth/README.md` |
| [`ehos_app`](https://github.com/EmpoweredHouse/ehos-tools) | the template this application was generated from, kept as a dependency so it can be upgraded | `deps/ehos_app/packages/ehos_app/README.md` (in `:dev`) |

EHOS is early: what is built and what is still planned is in its
[roadmap](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ROADMAP.md).
<!-- /ehos_app:readme -->
````

### Open points on the drafts

- EHOS's own docs are linked on `main`, which may be ahead of what the application runs (section 3).
  EHOS has no version an application pins, so there is nothing better to link to yet.
- The invoice example is eh-os-contract's own. An example from the application's domain would read
  better, but a managed section cannot know it.
- A.1's principles are six of EHOS's eleven, restated for one application. The other five are
  about the platform (shared services, reuse across deployments, open contracts, the company's
  policies) and are left out. Restating them is a copy that can drift; the link above them is
  what keeps it honest, and a review should check the two against each other.

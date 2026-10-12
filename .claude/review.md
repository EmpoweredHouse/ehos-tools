# Reviewing a change to ehos-tools

This repository's half of the `ehos-dev:pre-pr-review` skill: the skill holds the procedure and
reads this file first. `CONTRIBUTING.md`, "Commits and pull requests", has the same rules for a
person.

## Recording the review

`cd packages/review && mix review record` marks `HEAD` as reviewed. It refuses while changes are
uncommitted. The mark is a file in the repository's common git directory, so every worktree sees
it; it is never committed.

A Claude Code hook (`.claude/settings.json`) runs `mix review gate` in `packages/review` before the
command that opens a pull request (`gh pr create` or `gh pr new`), from the checkout it runs in, and
refuses it while that checkout's `HEAD` has no mark. It also refuses one that names another branch
or repository (`--head`, `--repo`), or that commits, checks out or rebases before it opens the pull
request: commit, record, then open it on its own. While `HEAD` is unreviewed it refuses any other
Bash command that names the one that opens a pull request, a `grep` included, and, whatever `HEAD`
is, a `git commit` whose message names it; write such text through a file (`git commit -F <file>`).
It does not see a push to an open pull request, or one opened through the API.

## Documentation alone

Markdown, and images beside it, that no code reads: at the root, in `docs/`, in a package other
than as its code reads it, and in `.github/` (the pull-request template).

Not documentation alone, though some of it starts no package's `check` job in CI: anything that is
not Markdown (`.claude/settings.json` and its hook, `.tool-versions`, `.gitattributes`, every file
under `.github/workflows/`, `release-package.yml` included); everything under `plugins/` and
`.claude-plugin/`, since the `ehos-dev` plugin is what eh-os, ehos-tools and eh-os-contract run,
its skills included; a README a package reads (`ehos_app`'s installer reads its own `README.md`);
and this file, which changes what every review here does.

## Security and performance

Secrets and tokens (in CI, in a Dockerfile, in what a generated project commits), trust in fetched
code and pins (a tag can move, a commit cannot), what a generated application serves and which
cookies, authentication and sign-in, unbounded work, work repeated on every run of the installer.

## The checks

`mix check` in every package the change touches. Run `ehos_app`'s from a checkout whose path has no
dot directory (`AGENTS.md`, "Traps already found").

## Verifying for real

A change to `ehos_app` generates a project and runs its `mix precommit`; a change to `ehosctl`
builds the binary and runs `init` with it (`AGENTS.md`, "Trying a change end to end").

## A finding skipped

A GitHub issue labelled `follow-up`, naming the pull request that found it.

## The pull request

Open it from the reviewed checkout, with the body in a file (`--body-file <file>`): the gate reads
the command's arguments, and refuses a body written inline that happens to name `--head` or
`--repo`. Its first line names the issue (`CONTRIBUTING.md`, "From an issue to `main`"). Its
`## Review` section lists what each of the two reviews found and what happened to each finding, or
says the change is documentation alone: CI's `review section` check fails while the section is
missing or empty, and runs again when the description is edited. A change a user of `ehosctl`,
`ehos_app` or `ehos_design` can see has its changelog line; otherwise the description says
`No changelog: <why>`.

## Before a fix

Nothing beyond the procedure.

## What reviews of this repository keep finding

Look for these on purpose; each one has already happened here.

**The installer (`packages/ehos_app`)**

- A second run changes nothing. A file the developer owns is written once (`write_rendered/3`,
  never `Igniter.create_new_file/4` with `on_exists: :skip`, which overwrites a file Igniter has
  not read yet), and what the developer removed or declined is never brought back: a declined
  design system, a moved sign-in link, a tuned daisyUI theme.
- A change to `ci.yml.eex` adds the SHA-256 of the workflow it replaces to
  `@earlier_ci_workflows`, and that file to `test/fixtures/ci_workflows/`: a workflow an earlier
  version wrote, untouched, is replaced only when the installer knows its bytes.
- A project from an earlier version is a separate case from a new one, with its own test: what it
  already has (a migration that went to an earlier version, a workflow from 0.2, a package on a
  commit no version pinned) decides what the run adds. Test the project moved by hand before the
  run as well as the one left as it was.
- Code is read as code. A regular expression over source matched a call in a comment and missed
  one split over lines; parse it (`Code.string_to_quoted/2`) instead, and say what a file that
  does not parse means.
- Supervision order is what Igniter makes of it, not what the call suggests: it inserts after the
  child that follows the last `after:` match. Check the generated `application.ex`, and that the
  endpoint starts last.
- A literal the project wrote that defeats the change (`secure: false`) is replaced; an expression
  of its own stays.
- A notice says what the developer has to do, in words that match what the run did.

**Pins and releases**

- A dependency from GitHub is pinned to a commit, with the tag it carries in a comment: a tag can
  move. eh-os-contract too: a generated project pins its release by the commit its tag names, and
  moves to a later one with a release of `ehos_app`
  ([T-11](../docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md),
  which superseded T-05's `branch: "main"`). The toolchain, archives and installer version are pinned in
  `packages/ehosctl/lib/ehosctl/template.ex` alone.
- A change to what the installer writes reaches a project only through an `ehos_app` release; a
  release of `ehos_app` is a release of `ehosctl` once `template.ex` points at it. Unreleased fixes
  do not reach anyone who installs a binary.
- No version changes outside a release's pull request, or the one after its tag that moves to the
  next `-dev` (`ehos-dev:release`).
- Every repository a generated project reads that is private (`eh-os-contract`, this one) is
  readable in its CI workflow and through its Dockerfile's build secret.

**Docs and messages**

- Documentation says what the code does. A commit message that claims a fix the code makes only
  in part costs the next round; the review compares the two.
- A change a user of `ehosctl`, `ehos_app` or `ehos_design` can see has its changelog line under
  `## [Unreleased]`, in one of the six standard subsections, describing the change for a reader of
  the package and wrapped at 100 columns; or the description has `No changelog: <why>`. A
  breaking change's line starts with `**Breaking:**`, and a link in it is a GitHub URL, since the
  section becomes the release's notes.
- No local paths, and links to other repositories by their GitHub URL.

**Elixir and tooling**

- `Regex.replace/3` with a string replacement reads `\1` followed by digits as a larger group
  number: when the inserted text can start with a digit, replace with a function.
- A test that writes to the filesystem does it under its own `tmp_dir`; a test of the installer
  runs on `Igniter.Test.phx_test_project/1`, and a CLI test reads the steps a command would run.
- Burrito binaries reuse an unpacked payload for their version: an end-to-end check after a
  rebuild at the same `-dev` version runs `maintenance uninstall` first, or it tests the old code.

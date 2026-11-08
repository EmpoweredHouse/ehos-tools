---
name: pre-pr-review
description: Use before `gh pr create` or before pushing new commits to an open pull request in eh-os, ehos-tools or eh-os-contract, when the review gate refuses `gh pr create`, and when the user asks to review a change before it is sent — two parallel reviews, every finding settled, the repository's checks passed, the review recorded. Not for someone else's pull request.
---

# Reviewing a change before its pull request

Every pull request to eh-os, ehos-tools and eh-os-contract is reviewed by its author before it is
opened. Each repository has a Claude Code hook that refuses `gh pr create` until the review is
recorded for `HEAD`, and any new commit, amend or rebase leaves the new `HEAD` unrecorded.

Read [references/procedure.md](references/procedure.md) now, in full: it is the procedure, step by
step. This file fills in what it leaves to the skill.

## The repository's part

`.claude/review.md` at the root of the repository the change is in
(`git rev-parse --show-toplevel`). It wins where it and the procedure differ. Its sections, by
heading:

- **The base**, optional: the branch a change is reviewed against, where it is not `main`.
- **Recording the review**: the command that records it, what the hook refuses and what it cannot
  see.
- **Documentation alone**: exactly which changes count as documentation alone here.
- **Security and performance**: what the second review looks at in this repository.
- **The checks**: what must pass before the review is recorded.
- **Verifying for real**: what the tests cannot see here, and how to see it.
- **A finding skipped**: how a skipped finding is filed.
- **The pull request**: what its description must say, and the repository's rules for opening it.
- **Before a fix**: anything the repository asks before a finding is fixed. It may be empty.
- **What reviews of this repository keep finding**: the traps already paid for.

## Before step 1

A change that touches what eh-os's architecture names runs `ehos-dev:architecture` first. In eh-os
its pages are committed with the change, so the reviews read them together; from another
repository, the eh-os change is a pull request of its own there.

## The two reviews

At step 4. They were first run together on eh-os's Stage 4, step 8a (27 September 2026), and
neither found what the other did; there the second round also found that the first fix for plain
HTTP made every request loop behind a proxy that ends TLS in front of the Ingress.

- **correctness**: as [references/correctness.md](references/correctness.md) says: each line,
  what was removed, callers and callees, Elixir, the conventions of the repository's `AGENTS.md`,
  `CLAUDE.md` and `CONTRIBUTING.md`, depth, and reuse and cost. On the change where both reviews
  were first run, it found that `up` reported a cluster from before D-45 as serving HTTPS and that
  a kubectl warning broke the CA's base64.
- **security and performance**: as [references/security.md](references/security.md) says, with the
  list in "Security and performance" as its first item. On that change, it found plain HTTP still
  served with a session cookie not marked `Secure`, and a CA that could vouch for any name.

Give each subagent the absolute path of its reference file, and of `correctness.md`, which the
security review also reads: this skill's own directory (Claude Code shows it when the skill
loads), followed by `references/`. Give it the checkout's absolute path and the range too. Both
reviews read the change themselves; neither invokes a skill from outside this plugin, such as the
harness's `code-review` or `security-review`, which read the session's own directory and not the
change's checkout.

A change with Elixir has both reviews also invoke `ehos-dev:elixir` and check the change against
its numbered rules and the references they name, the repository's own winning where they differ,
and invoke `ehos-dev:elixir-anti-patterns-review` on the same range, adding its findings to their
report. Code a template writes into an application (ehos-tools'
`packages/ehos_app/priv/templates/`) is checked against `ehos-app:elixir` and
`ehos-app:elixir-anti-patterns-review` instead, read from `plugins/ehos-app/skills/`. Both
`ehos-dev` skills come with this plugin, so a review that could not invoke one is handled as step 5
says.

## Keeping the list

When a review finds a new kind of problem, add it to "What reviews of this repository keep finding"
in `.claude/review.md`, in the same pull request. A rule about the code itself belongs where the
repository keeps its code rules (`AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`); the list keeps what a
reviewer should look for.

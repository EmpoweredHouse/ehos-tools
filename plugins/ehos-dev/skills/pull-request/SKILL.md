---
name: pull-request
description: Use to open a pull request in eh-os, ehos-tools or ehos_contract once `ehos-dev:pre-pr-review` has recorded the review, to write or rewrite a pull request's description, and when the user asks for one — the one template all EHOS repositories and applications share, top-down from the problem in plain words to the review, in Simplified Technical English. Not for reviewing the change (`ehos-dev:pre-pr-review`).
---

# Opening a pull request

Read [references/description.md](references/description.md) now, in full: it says how each section
of the description is written and how the pull request is opened. The template is
[references/pull_request_template.md](references/pull_request_template.md). This file fills in what
they leave to the skill.

## The repository's part

The section "The pull request" of `.claude/review.md`, at the root of the repository the change is
in (`git rev-parse --show-toplevel`), the same file `ehos-dev:pre-pr-review` reads.

## The words

Load `ehos-dev:voice` before you write the description. It has the full sentence rules, and the
glossary that owns each word you use.

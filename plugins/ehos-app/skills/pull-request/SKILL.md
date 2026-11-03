---
name: pull-request
description: Use to open this application's pull request once `ehos-app:pre-pr-review` has recorded the review, to write or rewrite a pull request's description, and when the user asks for one — the one template all EHOS repositories and applications share, top-down from the problem in plain words to the review, in Simplified Technical English. Not for reviewing the change (`ehos-app:pre-pr-review`).
---

# Opening a pull request

Read [references/description.md](references/description.md) now, in full: it says how each section
of the description is written and how the pull request is opened. The template is
[references/pull_request_template.md](references/pull_request_template.md), and the application's
`.github/pull_request_template.md` is a copy of it, unless the developer changed it: then fill the
application's own. This file fills in what they leave to the skill.

## The repository's part

The section "The pull request" of `ehos-app:pre-pr-review`'s
[references/application.md](../pre-pr-review/references/application.md). Read it with your
file-reading tool: this skill's own directory, followed by `../pre-pr-review/references/application.md`.

## The words

Use the words of the application's domain, as its contracts name them, and the words of the people
who use the application. A command, an event or a capability that changes goes in "What", by name,
for the process owner.

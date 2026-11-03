# The application's part

What the procedure ([procedure.md](procedure.md)) leaves to an application built on EHOS, by the
headings it reads.

## The base

The branch the input or an approved plan names, where the change has no pull request yet;
otherwise `main`.

## Recording the review

`MIX_ENV=dev mix ehos_app.review record`; `ehos_app` is a dependency in `:dev` alone. The review
gate, a hook in `.claude/settings.json`, refuses `gh pr create` until it has marked `HEAD`. Where
the pull request lands, the `review` workflow fails it while its description has no `## Review`
section that says something.

## Documentation alone

A change to Markdown files alone (`*.md`: the docs, the nested `AGENTS.md`, `VISION.md`) and
nothing else: no code, config, migration, `ehos.yaml`, workflow, `.claude/` or dependency.

## Before a fix

A change to a command's name, fields or `by:`, to a publication or to a promise needs the process
owner's agreement: ask the user before making it, whatever a review says.

## The checks

`mix precommit`. It formats files, so it runs before every commit, a fix's included, and the
reviews read the code as it formats it; at step 8 it confirms. If it changes a file there all the
same, check with `git diff` that the change is formatting alone, commit it, and run it again: a
commit of formatting alone needs no review round. It runs for documentation alone too: the
harness test reads the docs.

## Verifying for real

A page in the browser, a request to `/api` with a credential, a migration against a database with
data.

## A finding skipped

An issue in the application's repository.

## The pull request

`ehos-app:pull-request` writes the description and opens the pull request; this section is what is
the application's.

- **The base** is the one "The base" names, and the pull request opens as a draft (`--draft`).
  Inside `ehos-app:ship`, its section 8 gives the human the test and makes the draft ready once
  they confirm. Outside it, give the user the steps of "By hand"; a human runs them and makes the
  draft ready (`gh pr ready <number>`). Do not make it ready yourself there.
- **The title** is a short sentence that says what changes for a person who uses the application.
- **The first line** names the issue, where the work has one; otherwise `No issue:` and why.
- **"What" says what the change does to a contract**, where it changes one: its commands, events,
  capabilities, publications and stored events, for the process owner.
- **"By hand"** gives the exact steps a human runs to test the change, and what working looks like.

## What reviews of this repository keep finding

The root `AGENTS.md`, its section **Review-proven rules**.

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

As a draft, from a checkout of its branch, without `--head`, `--repo` or `GH_REPO`, which the gate
refuses: `gh pr create --draft --base <base>`, its body in a file. Fill the repository's template
(`.github/pull_request_template.md`): "How to test" says what you ran, and `## Review` is its last
section. A human tests it and makes it ready (`ehos-app:ship`).

## What reviews of this repository keep finding

The root `AGENTS.md`, its section **Review-proven rules**.

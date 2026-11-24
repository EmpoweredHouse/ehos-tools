# Builds

A build lets EHOS know each version of an application before anyone deploys it. The pipeline of
the application registers the image, by its digest, with the bundle written beside it and the
commit that it came from. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/builds-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/builds-api.md) of
eh-os describes the API that these commands use.

```sh
mix ehos_contract.bundle --output-dir bundle
ehosctl builds register bundle --image ghcr.io/example/ledger@sha256:<digest>
ehosctl builds list ledger --ref refs/heads/main
ehosctl builds openapi invoice-pdf <build>
ehosctl deploy ledger --env try-42 --build latest --ref refs/heads/main
```

## Register a build

`ehosctl builds register <dir> --image <image>` reads the bundle in `<dir>`. It checks each file
against the size and SHA-256 that `bundle.json` gives, and reads no file that `bundle.json` does
not name. Then it sends the files with the image, as a build of the application that the
application manifest names. If the bundle changed after it was written, `ehosctl` sends nothing.

The command needs the credential of a pipeline, or `ehos.application.deploy` on the application.

If the bundle holds the OpenAPI file of a utility service, `register` sends it too, as it is.

If the same run attempt registers the same bundle again, EHOS gives back the build that it
registered before. EHOS refuses another bundle from the same run attempt. EHOS takes at most 60
registrations of an application in a minute, and says when to try again.

### What a GitHub Actions job states

In a GitHub Actions job, EHOS takes the repository, the ref, the commit and the run from the token
of the job. `register` also states what it reads of the checkout and of the event:

- the first line of the commit, its author and its time;
- the number, the head and the title of a pull request;
- up to 100 commits before it, along first parents, each with its first line.

On a pull request, the commit is the head of the pull request, not the test merge of GitHub.

`register` removes control characters, and the marks that set the direction of text, from a title or
a name. It cuts each to 256 characters. It leaves out a commit time that is later than the clock of
the runner. It also leaves out what it cannot read, for example from a shallow checkout. The details
of a commit never make a pipeline fail.

Give the checkout that history: `fetch-depth: 101` on a push, and `fetch-depth: 102` on a pull
request. The test merge of a pull request is one more commit.

### Register a build outside a job

Outside a GitHub Actions job, `register` states nothing, because the checkout of a person has no
tie to the image. You can deploy such a build only by its id.

## List the builds of an application

`ehosctl builds list <app>` lists the builds, newest first, with the ref, the commit and the title
of each. It shows 50 builds unless you give `--limit`, up to 200.

`--ref` shows only the builds of one full ref, as GitHub names it, such as `refs/heads/main`. A
build that a person registered has no such ref. For it, the list shows the ref that the person
stated, marked `(stated)`.

The command needs `ehos.application.deploy`, `ehos.application.register` or `ehos.release.approve`
in the application.

## Download the OpenAPI file of a utility service

`ehosctl builds openapi <service> <build>` downloads the OpenAPI file that the build of a utility
service holds, as it came. It writes the file into the current directory, with the name that EHOS
gives it, such as `invoice-pdf-openapi.yaml`. `--output <file>` gives another name. The command
writes over no file: if the file exists, it writes nothing, and exits with 2.

The command needs what `list` needs. If the build holds no OpenAPI file, EHOS says so, and the
command exits with 1.

## Deploy a build

`ehosctl deploy <app> --env <env> --build <build>` deploys a build by its id, by a commit, or as
`latest` of a full ref. EHOS finds a commit and `latest` only among the builds that a pipeline
registered. If builds of more than one repository match, give `--repository owner/name`.
[Deploying](deploy.md) tells more.

For an application that you build outside CI, use
`ehosctl deploy APPLICATION --env ENVIRONMENT --image IMAGE --bundle DIR`. It sends the
application manifest and the graph documents of a bundle, in place of `--manifest` and `--graph`.

## Next steps

- [Deploying](deploy.md): deploy a build and wait until it is active.
- [Checking an application](verify.md): write the bundle with the checks of CI.

## Background

- [eh-os D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md):
  a build is a record of its own.
- [ehos-tools T-19](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0019-ehosctl-builds-register-states-what-a-github-actions-job-s-checkout-and-event-say-of-its-commit-and-elsewhere-nothing.md):
  what `builds register` states in a GitHub Actions job.

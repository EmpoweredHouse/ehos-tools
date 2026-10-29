# Builds

A build is an image, by its digest, with the bundle written beside it, registered by the
application's CI with the commit it came from, so EHOS knows each version before anyone deploys
it ([eh-os D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md),
[`docs/builds-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/builds-api.md)).

```sh
mix eh_os_contract.bundle --output-dir bundle
ehosctl builds register bundle --image ghcr.io/example/ledger@sha256:<digest>
ehosctl builds list ledger --ref refs/heads/main
ehosctl deploy ledger --env try-42 --build latest --ref refs/heads/main
```

- **`builds register`** checks each file of the bundle against the size and SHA-256 its
  `bundle.json` gives, reads no file it does not name, and sends them with the image as a build
  of the application the manifest names. It needs a pipeline's credential, or
  `ehos.application.deploy` on the application.
- **In a GitHub Actions job** EHOS takes the repository, ref, commit and run from the job's token,
  and `register` states what it reads of the checkout and the event: the commit's first line, its
  author and its time; a pull request's number, head and title; and up to 100 commits before it,
  along first parents, each its first line. On a pull request the commit is its head, not GitHub's
  test merge. A title or a name loses its control characters and the marks that set the direction
  of text, and is cut to 256 characters; a commit time later than the runner's clock is left out;
  what cannot be read, as from a shallow checkout, is left out too: a commit's details never fail
  a pipeline. The checkout needs that history: `fetch-depth: 101` on a push, and `102` on a pull request, whose test merge is one commit more ([T-19](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0019-ehosctl-builds-register-states-what-a-github-actions-job-s-checkout-and-event-say-of-its-commit-and-elsewhere-nothing.md)).
- **Elsewhere** it states nothing: a person's checkout has no tie to the image they register. Such
  a build is deployed by its id alone.
- **The same run attempt** registering the same bundle again gets the build it registered; another
  bundle from it is refused. EHOS takes at most 60 registrations of an application a minute, and
  says when to try again.
- **`builds list`** needs `ehos.application.deploy`, `ehos.application.register` or
  `ehos.release.approve` in the application. `--ref` takes a ref in full, as GitHub's token names
  it; a person's build has none, and shows the ref they stated, marked so.
- **`deploy --build`** names a build by its id, by a commit, or as `latest` of a ref in full,
  with no body: the build holds its image, its manifest and its graph documents. A commit and
  `latest` find only builds a pipeline registered. `--repository owner/name` narrows them when
  builds of more than one repository match. The deployment is named as its build is, and waited
  for as any other.
- **`deploy --bundle <dir>`** sends a bundle's manifest and graph documents in place of
  `--manifest` and `--graph`, which stay, for an application built outside CI.

# Deploying

`ehosctl deploy` puts one version of an application into one environment, as Deploy in the console
does. It deploys a build that the pipeline registered, or an image with its application manifest.
With `--preview`, it shows what the deployment would do and deploys nothing. The [glossary of
eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md) defines the
words of this page, and
[`docs/manifest.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/manifest.md#deploying-with-one)
of eh-os describes the deployment.

```sh
ehosctl deploy ledger --env staging --build latest --ref refs/heads/main
ehosctl deploy ledger --env staging \
  --image ghcr.io/example/ledger@sha256:<digest> --manifest manifest.json
ehosctl deploy ledger --env staging --manifest manifest.json --preview
```

A deployment needs `ehos.application.deploy` in the environment. If the application manifest
changes the authority of the application, the deployment also needs `ehos.application.register`
there.

## Deploy a build

A build is an image and the bundle beside it, which the pipeline of the application registered
([Builds](builds.md)). The build holds its image, its application manifest and its graph
documents, so `ehosctl` sends no files.

- Give the build by its id, from `ehosctl builds list`.
- Or give a commit, 40 or 64 lowercase hexadecimal characters.
- Or give `latest` with `--ref` and the full ref, as GitHub names it, such as `refs/heads/main`.

EHOS finds a commit and `latest` only among the builds that a pipeline registered. A build that a
person registered can only be deployed by its id. If builds of more than one repository match, give
the repository with `--repository owner/name`.

`--build` does not accept `--image`, `--manifest`, `--bundle`, `--graph`, `--commit` or
`--preview`. `--ref` works only with `--build latest`, and `--repository` only with a commit or
`latest`. `--template` and `--no-role-bindings` work only with `--create-env`. `ehosctl` refuses
each of these before it sends anything.

### Create the environment with the deployment

Add `--create-env` to create the ephemeral environment first, if it does not exist. The deploy page
of the console does the same.

```sh
ehosctl deploy ledger --env ledger-try --build <id> --create-env --template small
```

1. `ehosctl` asks EHOS if the environment exists. If it exists, `ehosctl` deploys to it.
2. If it does not exist, `ehosctl` creates an ephemeral environment of the application, as
   `ehosctl env create --app` does. `--template` chooses its environment template. Without it, EHOS
   uses the default of the installation. `--no-role-bindings` creates it without the role entries
   and the people agreement that the environment template holds for the application.
3. `ehosctl` deploys the build.

`--template` and `--no-role-bindings` apply only when `ehosctl` creates the environment. If EHOS
made the environment with the role entries and the people agreement of its environment template,
`ehosctl` refuses `--no-role-bindings` and deploys nothing. Then do one of these:

- Deploy without `--no-role-bindings`.
- Create another environment with `ehosctl env create ENVIRONMENT --app APPLICATION
  --no-role-bindings`, and deploy to it.

EHOS decides and records the creation and the deployment separately. If the application has the
maximum number of ephemeral environments, EHOS refuses the creation. `ehosctl` then lists the
environments that count
([Environments](env.md#find-what-holds-the-maximum-number-of-ephemeral-environments)).

If EHOS refuses the deployment and deployed nothing, the new environment stays until it expires.
`ehosctl` then tells you how to remove it. Under `--json`, the answer or the error gives the new
environment as `created_environment`.

`--create-env` works only with `--build`. The credential of a GitHub Actions job cannot read an
environment, so EHOS refuses the first step in a job. `ehosctl` then tells you to run
`ehosctl env create` first.

### An environment of a pull request

If the environment is `<application>-pr-<n>`, `ehosctl deploy` writes a warning on stderr before it
creates the environment or deploys to it. This applies to every deployment but `--preview`. If the
repository previews pull requests, the pipeline of that pull request deploys to the environment.
That deployment replaces yours. It also withdraws a promotion that waits for a candidate there. When
the pull request closes, its pipeline can remove the environment. Under `--json`, `ehosctl` writes
no warning.

## Deploy an image and its application manifest

Give the image by digest with `--image`. EHOS refuses an image by tag.

- **`--manifest <file>`** gives the application manifest. `ehosctl` sends the file byte for byte,
  because EHOS keeps and digests the bytes that it gets. `--manifest -` reads the file from stdin.
  The application manifest must be the one of the application that the command names. If it is not,
  `ehosctl` sends nothing.
- **`--graph <file>`** gives one graph document, as `mix eh_os_contract.graph --output-dir` writes
  it. Give it once for each document. A deployment takes at most 512 documents, at most 1 MiB each
  and 32 MiB in all. Before it signs in, `ehosctl` writes on stderr how many documents it sends and
  their size. EHOS keeps what it reads of them for `ehosctl landscape`. EHOS refuses the deployment
  if a document is broken or names the facts of another application.
- **`--bundle <dir>`** replaces `--manifest` and `--graph`. A bundle is the directory that
  `mix eh_os_contract.bundle --output-dir` writes. `ehosctl` checks each file against the size and
  SHA-256 that `bundle.json` gives, and refuses a bundle that changed after it was written. Use a
  bundle for an application that you build outside CI. A deployment does not keep the OpenAPI file
  of a utility service's bundle: `ehosctl builds register` keeps it with a build.

## State where the image came from

`--commit` and `--ref` state the commit and the branch or tag of the image. `ehosctl` sends them
only when you give them, and never reads them from a checkout: a checkout has no tie to the image.
EHOS checks their form, but nobody checks that they are true. EHOS shows them beside the digest, as
your statement.

A deployment from a GitHub Actions job shows its run instead, as the token of GitHub names it.
EHOS ignores what the job states.

## What you see when EHOS accepts the deployment

EHOS answers when the cluster has the objects of the deployment, while the deployment is
`activating`. `ehosctl` prints the id of the deployment, the image, the build, where the image came
from, and both digests of the application manifest:

```text
Deployed ledger to staging: deployment 5f0c… is activating.
  image:            ghcr.io/example/ledger@sha256:…
  source:           from GitHub's token: example/ledger, branch main, commit …, run … (attempt 1)
  manifest digest:  sha256:…
  authority digest: sha256:…
```

`ehosctl apps show` shows the same for the deployment in force in each environment.

## Wait until the deployment is active

After EHOS accepts the deployment, `ehosctl` reads the deployments of the application in the
environment and prints each state that the deployment moves to. It reads after 2 seconds, then
less often, up to every 10 seconds:

```text
ehosctl waits until the deployment is active, for at most 10 minutes:
  activating
  active
Deployment 5f0c… is active in staging, at https://ledger.staging.example.com.
```

The wait ends in one of these ways:

| Outcome | Exit code |
| --- | --- |
| EHOS says that the deployment is `active`. If a deployment that EHOS decided after it is in force, `ehosctl` says so. | 0 |
| The deployment `failed`. `ehosctl` prints the failure. | 1 |
| Another deployment `superseded` it. | 1 |
| The deployment was `withdrawn`: EHOS removed its ephemeral environment while it rolled out. | 1 |
| 10 minutes passed. `ehosctl` prints the state, and tells you to run `ehosctl apps show <app>` later. | 5 |
| EHOS decided so many deployments after it that EHOS no longer lists it among the newest. | 5 |
| EHOS is older than the route that lists deployments. `ehosctl` says that it cannot follow the deployment. | 0 |

If EHOS does not answer a read, or answers that it cannot answer now, `ehosctl` reads again until
the 10 minutes pass. If EHOS refuses a read, the wait ends at once, because EHOS records each
refusal. Each error says that EHOS decided the deployment, and gives its id. To read the
deployments, you need `ehos.application.deploy` or `ehos.application.register` in the environment.

`--no-wait` returns when EHOS decides the deployment. Then open the page of the application in the
console to see if the deployment became active.

With `--json`, `ehosctl` prints one document at the end. It is the answer of EHOS, kept to the
fields that `ehosctl` reads. It adds the last `state` and `failure` of the deployment, the `outcome`
and the `addresses`. The `outcome` is `active`, `failed`, `superseded`, `withdrawn`, `waiting`,
`displaced`, or `not_followed` on an older EHOS.

## What occurs when EHOS refuses the deployment

`ehosctl` prints the sentence of the deploy page. For example, if the application manifest drops a
database that the environment keeps, EHOS refuses with `database_kept`, and `ehosctl` exits with 1.
If the cluster did not take the deployment, `ehosctl` exits with 5 and prints the failure. If a
later deployment came first, `ehosctl` exits with 1. Both errors give the id of the deployment.

## Preview a deployment

```sh
ehosctl deploy ledger --env staging --manifest manifest.json --preview
```

`--preview` deploys nothing. It shows what the deployment would do, as the deploy page shows it
before you confirm:

- both digests of the application manifest, and the version in force;
- that the deployment registers the application, if EHOS does not know it yet;
- what the authority adds and removes, in the words of `ehosctl apps review`, or that it changes the
  authority of no one;
- that the deployment also needs `ehos.application.register`, if you hold it;
- the resource that each need would bind to, or why it cannot bind;
- the hosts outside the installation that the application reaches;
- what the deployment changes in sign-in and in reading the people of the company;
- the mail that it asks to send through EHOS, compared with what the deployment in force asks;
- the CPU and memory that its containers ask for, and if the quota of the environment has room;
- each reason that EHOS would refuse the deployment.

The exit code is 0 if EHOS would accept the deployment. It is 1 if EHOS would refuse it. In both
cases, `ehosctl` prints the whole preview. `--json` prints the preview with its `refusals`, empty
or not.

The preview takes only the application manifest. It does not accept `--image`, `--graph`,
`--bundle`, `--commit` or `--ref`: EHOS checks the image when you deploy. The preview needs
`ehos.application.deploy` in the environment, as a deployment does.

### Mail

The application sends mail only as far as the mail agreement for the environment allows. A person
who holds `ehos.mail.manage` gives the mail agreement, on the Installation page of the console or
with `ehosctl mail agree` ([Agreements](agreements.md)). `--json` keeps `mail` and
`mail_in_force`, each `{"level", "reply_domains"}` or null. An EHOS older than mail gives neither,
and both are null.

### A host that is the mail server of the installation

The application manifest names the hosts that it reaches under `needs.egress`. If one of them is
the mail server of the installation, the preview says so. The mail server can admit the server of
the installation by its address. Then the application can send through it as anyone in the domain
of the company. That mail goes around its mail agreement and the audit record.

EHOS does not refuse the deployment for this. Approve it only if you intend it. This path closes
only when the mail server requires a user and no longer admits the server by its address. `--json`
keeps each `egress` entry as `{"host", "port", "mail_relay"}`. An EHOS older than this check did not
check, and its entries have no `mail_relay`.

## Next steps

- [Builds](builds.md): register a build in the pipeline.
- [Your roles and applications](apps.md): see the versions of an application and its deployments.
- [Checking an application](verify.md): run the checks of CI before you deploy.

## Background

- [eh-os
  D-129](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0129-a-deployment-shows-beside-its-digest-the-github-run-its-credential-was-exchanged-for-or-what-its-deployer-states.md):
  where a deployment came from.
- [eh-os
  D-140](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0140-an-application-sends-mail-through-ehos-as-itself-to-the-company-s-people-or-to-any-address-as-far-as-an-agreement-for-its-environment-allows.md):
  mail through EHOS.
- [eh-os
  D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md):
  builds.

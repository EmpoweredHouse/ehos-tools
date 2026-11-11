---
status: accepted
date: 2026-11-10
decision-makers: [emil]
consulted: []
---

# T-24 · acme-dns's image is kept current by Renovate, run in a workflow of ehos-tools under a GitHub App of its own, and a weekly scan of the pinned digest opens an issue

## Context and problem statement

An installation with public certificates runs acme-dns, a DNS server that answers on the internet
on port 53 ([eh-os D-158](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0158-an-installation-at-a-domain-of-the-company-s-own-serves-the-console-and-every-address-under-certificates-from-a-public-acme-issuer-and-one-on-sslip-io-moves-there-once.md)).
ehos-tools builds its image from `packaging/acme-dns/Dockerfile`, which pins acme-dns's commit, Go
on Alpine and Alpine by digest, and raises `golang.org/x/net` in a `go get` line.
`.github/workflows/acme-dns.yml` publishes it to `ghcr.io/empoweredhouse/acme-dns`, a private
package, and `EhosPlatform.PublicCertificates` pins the published index by digest.

Nothing tells anyone when that image needs a new build: a fix in Go, Alpine, one of acme-dns's
Go modules or acme-dns itself reaches no installation until a person happens to look
([#829](https://github.com/EmpoweredHouse/ehos-tools/issues/829)), and the image is scanned once,
before it is published, and never again
([#822](https://github.com/EmpoweredHouse/ehos-tools/issues/822)).

Something has to open pull requests in ehos-tools on its own. That needs write access to the
repository, and a pull request opened with a workflow's own `GITHUB_TOKEN` starts no workflow, so
CI would not run on it; this repository also does not let Actions open pull requests. eh-os has a
Renovate configuration (`.github/renovate.json5`) since September 2026, but the Renovate app is not
installed in the organisation, and it has never opened a pull request.

## Decision drivers

- Every pin of the image is moved: the two base images' digests, Go's version, acme-dns's tag and
  commit, `golang.org/x/net`, and the installer's digest of the published index, which is a private
  package.
- The pull request it opens runs CI like any other, and is reviewed and merged by a person.
- The credential that writes to the repository can do as little else as possible, and is held by
  as little third-party code as possible: ehos-tools is private, and so is the image.
- A standard, community-proven tool rather than a job written here (`AGENTS.md`, "Compose, don't
  copy").
- Whatever eh-os does later stays possible: its configuration is Renovate's.

## Considered options

1. **Dependabot**, with `.github/dependabot.yml`, and a job written here for what it cannot read.
2. **The hosted Renovate app** (Mend), installed on ehos-tools, with `renovate.json5` here.
3. **Renovate run by a workflow of ehos-tools**, weekly, under a GitHub App of its own.

## Decision outcome

Chosen option: **"Renovate run by a workflow of ehos-tools"**, because it is the only option that
moves every pin with one standard tool while the key that writes to the repository and the token
that reads the private image stay in ehos-tools' own secrets and runner.

- A GitHub App, *ehos-tools Renovate*, is installed on ehos-tools alone, with read and write access
  to contents, pull requests, issues (Renovate keeps a Dependency Dashboard issue) and workflows.
  Its Client ID and private key are the secrets `RENOVATE_APP_CLIENT_ID` and
  `RENOVATE_APP_PRIVATE_KEY` of a GitHub environment, `renovate`, whose deployment branches are
  `main` alone: a repository secret would reach a workflow pushed on any branch. It is not
  *ehos-tools CI*, whose key reads `eh-os-contract` and must not gain write access to anything.
- `.github/workflows/renovate.yml` runs Renovate's own action, pinned by commit, and its image,
  pinned by digest, every Monday and by hand, with a token the App mints for that job. The cron
  alone says when: `renovate.json5` has no schedule of its own. Renovate reads `ghcr.io` with the
  job's own `GITHUB_TOKEN` (`packages: read`). A run by hand after a publish opens the pull request
  that moves the pin at once; `workflow_run` would do that on its own, but would let a run started
  from another branch start this one with the App's key.
- `.github/renovate.json5` covers acme-dns alone for now: the Dockerfile's frontend and base
  images, its `ACME_DNS_COMMIT` and `ACME_DNS_VERSION` against acme-dns's tags, its
  `X_NET_VERSION`, BuildKit's image and the actions in the image's workflows, and the installer's
  pin against the `latest` tag that `acme-dns.yml` moves to an index once both architectures of
  it are scanned clean. The pin's pull request asks for `ehos_platform`'s changelog line; the
  others say `No changelog:`, since nothing else reaches a package's user.
  `acme-dns.yml` reads acme-dns's version from the Dockerfile, so the version has one source.
  Widening Renovate to Mix, the other workflows and `.tool-versions` is a change of that file,
  decided on its own.
- A scheduled workflow scans the digest the installer pins, for `linux/amd64` and `linux/arm64`,
  every week, and opens or updates one issue when Trivy finds a HIGH or CRITICAL advisory with a
  fix. The issue says how the pin moves.

### Consequences

- Good, because each pin moves by a pull request that runs CI and a person merges.
- Good, because the private image is read with a token that expires with the job, and nothing
  outside GitHub holds a credential of ehos-tools.
- Bad, because there is one more App and two more secrets for an organisation admin to keep, and a
  leaked key writes to ehos-tools' code. Mitigation: the App is installed on one repository, and its
  secrets belong to an environment that only a job on `main` can use.
- Bad, because the workflow and its action are code to keep current. Mitigation: Renovate moves its
  own action's pin.
- Bad, because a new image does not reach a running installation: it does when the installation is
  installed again with a newer `ehosctl`, as every pinned image does (#829, "Out").
- Neutral: eh-os's dormant configuration stays dormant. Running it the same way is eh-os's decision.

### Confirmation

- The `Renovate` workflow's weekly run on `main` succeeds, and its first pull request moves a pin in
  `packaging/acme-dns/Dockerfile`.
- The `acme-dns image` workflow fails a pull request whose image, for either architecture, has a
  HIGH or CRITICAL advisory with a fix, and scans the published index by digest after each publish.
- The weekly scan's run on `main` is green, or an issue titled "acme-dns's pinned image has
  advisories with a fix" is open.

## Pros and cons of the options

### Dependabot

- Good, because it is part of GitHub: no App, no key, no workflow to keep.
- Good, because its pull requests run CI, with Dependabot's own secrets.
- Bad, because it reads only `FROM` lines: not the `ARG`s that pin acme-dns's commit and tag, not
  the `go get` line (there is no `go.mod` here), not the digest in an Elixir module. Those would
  need a job written here, with a credential that writes, which is the problem it was meant to
  avoid.

### The hosted Renovate app

- Good, because nothing runs here: Mend runs Renovate, and its schedule.
- Good, because it is what eh-os's configuration was written for, so installing it would wake that
  too.
- Bad, because a third party holds write access to ehos-tools' private code, and reads it on its
  own servers.
- Bad, because it cannot read the private image without a GHCR token kept in Mend's own secrets,
  which outlives any job.
- Bad, because installing it is an organisation admin's step outside the repository, and its
  permissions are the app's, not ours.

### Renovate run by a workflow of ehos-tools

- Good, because the same configuration and managers as the hosted app: every pin is read.
- Good, because the write credential is an App installed on one repository, and the read of the
  image is the job's own token.
- Bad, because of the App, the secrets and the workflow to keep (above).

## More information

Decided under [#829](https://github.com/EmpoweredHouse/ehos-tools/issues/829); the scan by digest is
[#822](https://github.com/EmpoweredHouse/ehos-tools/issues/822).

Revisit when ehos-tools and the image are public (Dependabot or the hosted app then hold nothing
private), or when eh-os runs Renovate in a way ehos-tools could share. Once ehos-tools is public,
the weekly scan's issue lists, in public, advisories with a fix in an image on the internet's port
53; it moves to a private channel then.

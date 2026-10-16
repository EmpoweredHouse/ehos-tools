---
status: accepted
date: 2026-10-16
decision-makers: [Emil Wojtaszek]
consulted: [eh-os D-110, eh-os D-114, T-07, T-08, T-14]
---

# T-17 · In a GitHub Actions job, `ehosctl` talks to the installation `EHOSCTL_URL` names and exchanges the job's token for each credential, keeping nothing

## Context and problem statement

[eh-os D-110](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0110-a-pipeline-deploys-as-its-application-s-deployment-identity-trusted-per-github-repository-exchanging-github-actions-token-for-a-credential-that-reaches-only-ephemeral-environments.md)
lets a GitHub Actions job deploy an application's candidate with no stored secret: the job asks
GitHub for an OIDC token whose audience is EHOS's issuer, and exchanges it at EHOS's
`POST /oauth/token` (RFC 8693) for a ten-minute credential that reaches only the application's
ephemeral environments. There is no refresh token: a job that runs longer asks GitHub again.

Every governed command of `ehosctl` today talks to an installation named in `config.json`
([T-07](0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md))
with a credential renewed from the sign-in `ehosctl login` kept
([T-08](0008-ehosctl-keeps-a-sign-in-s-refresh-token-in-the-system-s-keychain-else-a-file-only-the-user-reads-and-renews-under-a-lock.md)).
A runner has neither, and has no person at a browser to make them. What has to be settled is how
a job names the installation, and when `ehosctl` exchanges the job's token instead of renewing a
sign-in ([#247](https://github.com/EmpoweredHouse/ehos-tools/issues/247)).

## Decision drivers

1. Nothing a job holds outlives it: no credential, and no file holding one, on the runner.
2. The workflow the template generates (eh-os Stage 8's step 6) is short, and every command in
   it is the one a developer types, `ehosctl env create` and `ehosctl deploy`.
3. A person's terminal behaves as before: nothing a developer has set up changes meaning.
4. A job that cannot get a credential says why in its log, without what EHOS keeps for its audit
   record.

## Considered options

1. **`EHOSCTL_URL` names the installation**, and in a GitHub Actions job `ehosctl` exchanges the
   job's token for each credential it needs.
2. **`ehosctl login --github-actions <url>`**, a step of its own that writes the installation to
   the runner's `config.json`, after which commands run as on a terminal.
3. **`--installation` and `EHOSCTL_INSTALLATION` also take an address**, given to each command.

## Decision outcome

Chosen option: **1, `EHOSCTL_URL`**, because it keeps nothing on the runner and adds no step: the
workflow sets one variable for the job, as `gh` reads `GH_HOST`, and the user chose it on
16 October 2026.

- **Which installation.** A governed command talks to the one `--installation` names, else
  `EHOSCTL_INSTALLATION`, else `EHOSCTL_URL`, else the current one. `EHOSCTL_URL` names an
  installation by its address, `https` only, known to no `config.json` and written to none. Its
  CA is the system's, with `EHOSCTL_CA_FILE` besides, as for any command
  ([T-14](0014-ehosctl-login-keeps-the-ca-it-was-told-to-trust-beside-the-installation-and-trusts-it-for-that-installation-alone.md)).
- **When it exchanges.** For an installation `EHOSCTL_URL` names, a credential for EHOS's API is
  had only by exchange, and only in a job GitHub gives a token to, which it shows by setting
  `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_ID_TOKEN_REQUEST_TOKEN` (`permissions: id-token:
  write`). Anywhere else the command is refused, saying so: a person signs in with `ehosctl login`.
  A sign-in is never used for it, and an installation named otherwise never exchanges.
- **How.** `ehosctl` reads EHOS's discovery document for its issuer and token endpoint, asks
  GitHub for a token whose audience is that issuer, and sends it with `client_id=github-actions`,
  `audience=ehos` and, when the command names its application (`deploy <application>`, `--app`),
  `resource=<issuer>/api/v1/applications/<application>`. The credential is kept in the command's
  own process until thirty seconds before it expires, as a cached one is (T-08), and a fresh
  GitHub token is exchanged after that. Nothing is written to disk.
- **A credential for an application** is refused before anything is sent: no application accepts
  a deployment identity's (D-110).
- **A refusal** is `invalid_grant` with no detail. `ehosctl` says EHOS refused the job's token,
  that the reason is in EHOS's audit record as a refused `deployment_identity.exchange`, and the
  causes a person can fix: the repository not trusted for the application (`ehosctl trust`), a ref,
  environment or event the trust does not accept, a GitHub account linked to nobody
  (`ehosctl github claim`).

### Consequences

- Good, because a job holds the credential only in memory, for as long as a command runs.
- Good, because the generated workflow is one variable and the developer's own commands.
- Good, because a terminal is unchanged: `EHOSCTL_URL` is read only where neither
  `--installation` nor `EHOSCTL_INSTALLATION` names one, and a sign-in never exchanges.
- Bad, because `EHOSCTL_URL` set in a developer's shell would take the place of their current
  installation, and refuse every command outside a job. Mitigation: the refusal names the
  variable, and the template sets it only in its workflow.
- Bad, because each command of a job reads the discovery document and asks GitHub for a token
  again. Mitigation: two requests per command, within GitHub's and EHOS's limits (60 exchanges a
  minute per repository).
- Neutral: CI providers other than GitHub Actions are not covered; D-110 trusts only GitHub's
  tokens.

### Confirmation

`Ehosctl.GitHubActionsTest` and `Ehosctl.CLITest`, against a fake EHOS and a fake GitHub token
service:

- a command with `EHOSCTL_URL` in a job exchanges the job's token, with GitHub's token's audience
  EHOS's issuer and the parameters above, and calls EHOS's API with the credential;
- a second call within the credential's life exchanges nothing, and one after it exchanges a fresh
  GitHub token;
- `EHOSCTL_URL` outside a job, an `http` address, and a credential for an application are refused
  before anything is sent;
- `invalid_grant` is said as above, and `--installation` and `EHOSCTL_INSTALLATION` win over
  `EHOSCTL_URL`;
- nothing is written under the configuration or state directories.

Stage 8's closing test runs the generated workflow against a deployed EHOS.

## Pros and cons of the options

### `EHOSCTL_URL`

- Good, because nothing is written and no step is added.
- Bad, because it is a third way to name an installation, beside a name and the current one.

### `ehosctl login --github-actions <url>`

- Good, because every later command runs as on a terminal, and the installation has a name.
- Bad, because a step must run first, and the runner keeps a `config.json`; a self-hosted runner
  keeps it after the job.

### An address for `--installation`

- Good, because it adds no variable.
- Bad, because every command in the workflow repeats the address, and a name and an address mean
  different things in one option.

## More information

Decided under [#247](https://github.com/EmpoweredHouse/ehos-tools/issues/247), for eh-os's
[#530](https://github.com/EmpoweredHouse/eh-os/issues/530). GitHub's description of the token and
how a job asks for it: <https://docs.github.com/en/actions/reference/security/oidc>.

Revisit when another CI provider's tokens are trusted, or if GitHub gives jobs a credential
helper that `ehosctl` could use instead.

# Deploying from GitHub Actions

The CI of an application deploys its candidates to the ephemeral environments of the application. It
uses the token that GitHub Actions gives each job, and no stored secret. The job deploys for the
person whose push started it, with what that person can do there. This page is for the administrator
of an application and its developers. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/deployment-identity-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/deployment-identity-api.md)
describes the API that these commands use.

## Trust the repository

The administrator of the application trusts the repository one time:

```sh
ehosctl trusts add --app ledger --repo acme/ledger --ref 'refs/pull/*/merge'
ehosctl trusts list --app ledger
ehosctl trusts remove <trust id> --app ledger
```

- **The repository**: EHOS knows it by the ids that GitHub gives the repository and its owner. `add`
  reads them from the API of GitHub. For a private repository, set `MISE_GITHUB_TOKEN` or
  `GITHUB_TOKEN`, or give `--owner-id` and `--repo-id`. A renamed repository keeps its ids. A new
  repository with the same name is a different repository to the trust.
- **What the trust accepts**: `--environment` limits it to a GitHub environment. `--protected`
  limits it to a protected ref. `--workflow` limits it to one workflow file, but only on a protected
  ref.
- **Who can set it**: to add or remove a trust, you need `ehos.role_binding.manage` and
  `ehos.application.deploy` on the application. To list, you need one of them.

### Read the warnings of add

EHOS warns, and `add` prints the warning, when a trust accepts:

- pull requests. Keep the setting "Send write tokens to workflows from fork pull requests" of the
  repository off.
- tags without `--protected`.
- pull requests and branches or tags, without `--protected`.

The run of a pull request reaches only its own preview. A push to a branch or tag that the trust
accepts reaches each preview of the application. A trust for `refs/pull/*/merge` only, as above and
as the `DEVELOPMENT.md` of the application template adds, accepts no branch or tag. EHOS then
refuses the runs of each other ref. Do not give `--protected` with it. GitHub protects no ref of a
pull request, so EHOS then refuses each run of a pull request.

## Link your GitHub account

Each developer links their GitHub account one time, with a person who manages people:

```sh
ehosctl github list                         # your accounts, and the runs you can claim one from,
                                            # each with its commit
ehosctl github claim [<run>]                # shows the run, asks if it is yours
ehosctl people github list                  # a people manager: the claims that wait
ehosctl people github confirm <account id>  # after a check with the person
```

1. EHOS refuses a job whose GitHub account is linked to nobody.
2. The person claims their account from that run. Nobody types an id or a login.
3. A person who manages people, and who is not that person, confirms the claim. EHOS warns them when
   another person claims the same account.

If only one person manages people, as on an installation of one person, they confirm their own
claim. EHOS records it as a self-confirmation. If several people manage people, a people manager
cannot confirm their own claim: EHOS lists it as theirs, and refuses the confirmation.

`github remove` and `people github remove` remove a link. EHOS refuses the next run of that account.

## Deploy from a job

The job needs no sign-in. Give it `permissions: id-token: write`, and the address of the
installation in `EHOSCTL_URL`. Then run the commands that a developer runs:

```yaml
jobs:
  preview:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    env:
      EHOSCTL_URL: ${{ vars.EHOS_URL }}
    steps:
      - run: ehosctl deploy ledger --env ledger-pr-${{ github.event.number }} --image "$IMAGE" --manifest manifest.json
```

- **Each credential**: `ehosctl` exchanges a token that GitHub gives the job, whose audience is the
  installation, for a credential of 10 minutes. It keeps the credential only in the memory of the
  command. A later command, or the same command after 10 minutes, exchanges a new token. Nothing is
  written on the runner.
- **What it reaches**: only the ephemeral environments of the application. EHOS lets the job make,
  extend, remove and read them, and deploy and preview there. EHOS refuses production, another
  application, and each other command. It records each refusal with the person that the job acts
  for.
- **What ehosctl does with it now**: `deploy`, `deploy --preview` and `env show`. `ehosctl` cannot
  make, extend or remove an ephemeral environment from an environment template in a job yet. Until
  then, a job deploys to an environment that a person made. The environments that a job makes have
  the name of its application, `ledger-…`.
- **A CA of the installation**: `ehosctl` trusts it through `EHOSCTL_CA_FILE`, a file that the job
  writes from a variable.
- **The token service of GitHub**: `ehosctl` trusts it only through the CAs of the system, never
  through `EHOSCTL_CA_FILE`, which is for the installation.

## When EHOS refuses the token

A refused exchange says only that EHOS refused it. The audit record of EHOS says why. The message of
`ehosctl` names the most frequent cause first: a GitHub account that is not linked yet, and how to
link it. Then it names a repository or a ref that the trust does not accept.

Outside a job, `EHOSCTL_URL` refuses each command that needs a credential. On a terminal, unset it
and sign in.

## Background

- [eh-os D-110: a pipeline deploys as the deployment identity of its application](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0110-a-pipeline-deploys-as-its-application-s-deployment-identity-trusted-per-github-repository-exchanging-github-actions-token-for-a-credential-that-reaches-only-ephemeral-environments.md)
- [T-18: in a GitHub Actions job, ehosctl exchanges the token of the job for each credential](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0018-in-a-github-actions-job-ehosctl-talks-to-the-installation-ehosctl-url-names-and-exchanges-the-job-s-token-for-each-credential-keeping-nothing.md)
- [ehos-tools#224: make, extend and remove an ephemeral environment from a job](https://github.com/EmpoweredHouse/ehos-tools/issues/224)

## Next steps

- [Deploy an application](deploy.md)
- [Ephemeral environments](env.md)

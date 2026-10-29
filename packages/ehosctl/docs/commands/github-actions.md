# Deploying from GitHub Actions

An application's CI deploys its candidates to the application's ephemeral environments with the
token GitHub Actions gives each job, and no stored secret
([eh-os D-110](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0110-a-pipeline-deploys-as-its-application-s-deployment-identity-trusted-per-github-repository-exchanging-github-actions-token-for-a-credential-that-reaches-only-ephemeral-environments.md),
[`docs/deployment-identity-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/deployment-identity-api.md)).
The job deploys on behalf of the person whose push started it, with what that person may do there.

**The application's administrator trusts the repository**, once:

```sh
ehosctl trust add --app ledger --repo acme/ledger --ref 'refs/pull/*/merge'
ehosctl trust list --app ledger
ehosctl trust remove <trust id> --app ledger
```

- **The repository** is named by the ids GitHub gives it and its owner, which `add` reads from
  GitHub's API: set `MISE_GITHUB_TOKEN` or `GITHUB_TOKEN` for a private one, or give
  `--owner-id` and `--repo-id`. A repository renamed keeps them; one made again under the same
  name is a stranger to the trust.
- **What it accepts** is narrowed by `--environment` (a GitHub environment), `--protected` (a
  protected ref only) and `--workflow` (one workflow file, which narrows only on a protected ref).
- **EHOS warns**, and `add` prints it, when a trust accepts pull requests (keep the repository's
  "Send write tokens to workflows from fork pull requests" off), tags without `--protected`, or
  pull requests beside branches or tags without `--protected`: a pull request's run reaches its
  own preview alone, but a push to a branch or tag the trust accepts reaches every preview of the
  application. A trust for `refs/pull/*/merge` alone, as above and as the template's
  `DEVELOPMENT.md` adds, gives no branch or tag that reach, and runs of any other ref are refused;
  `--protected` would refuse every pull request's run, since GitHub protects no pull request's ref.
- Setting and removing need `ehos.role_binding.manage` and `ehos.application.deploy` on the
  application; listing needs either.

**Each developer links their GitHub account**, once, with a people manager:

```sh
ehosctl github list                         # your accounts, and the runs you may claim one from
ehosctl github claim [<run>]                # shows the run, asks whether it is yours
ehosctl people github list                  # a people manager: the claims waiting
ehosctl people github confirm <account id>  # after checking with the person
```

A job whose GitHub account is linked to nobody is refused, and its run is what the person claims
their account from: nobody types an id or a login. A people manager who is not that person
confirms it, and is warned when someone else claims the same account. `github remove` and
`people github remove` unlink one; its next run is refused.

**The job deploys with no sign-in.** Give it `permissions: id-token: write` and the installation's
address in `EHOSCTL_URL`, and run the commands a developer runs
([T-18](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0018-in-a-github-actions-job-ehosctl-talks-to-the-installation-ehosctl-url-names-and-exchanges-the-job-s-token-for-each-credential-keeping-nothing.md)):

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

- **Each credential** is exchanged from a token GitHub gives the job, whose audience is the
  installation, for ten minutes, kept in the command's memory alone; a later command, or the same
  one after ten minutes, exchanges a fresh token. Nothing is written on the runner.
- **What it reaches** is the application's ephemeral environments alone: EHOS admits it to make,
  extend, remove and read them, and to deploy and preview there. Production, another application,
  and every other command are refused, and recorded with the person the job acts for.
- **What `ehosctl` does with it today** is `deploy`, `deploy --preview` and `env show`. Making,
  extending and removing an ephemeral environment from a template come with
  [#224](https://github.com/EmpoweredHouse/ehos-tools/issues/224); until then a job deploys to one
  a person made. The environments a job makes are named after its application, `ledger-…`.
- **A refused exchange** says only that it was refused; why is in EHOS's audit record. The usual
  causes are a repository or ref the trust does not accept, and a GitHub account not linked yet.
- **An installation with a CA of its own** is trusted through `EHOSCTL_CA_FILE`, a file the job
  writes from a variable.
- **Outside a job**, `EHOSCTL_URL` refuses every command that needs a credential: unset it on a
  terminal, and sign in.
- **GitHub's token service** is trusted through the system's CAs alone, never `EHOSCTL_CA_FILE`,
  which is for the installation.

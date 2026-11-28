# Your roles and applications

These commands show what you can do in the applications of an installation, and the versions and
deployments of each application. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

## See your roles

`ehosctl roles` lists the roles bound to you and to your agents, as My roles in the console does
([`docs/terminal-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/terminal-api.md)
of eh-os). `--app` and `--env` show only the roles that hold there.

- A role bound across each application or each environment shows `(all)`.
- A role that is `gone` grants nothing, because the version in force no longer has it.
- A role that is `beyond its owner` grants an agent only what you hold there yourself.
- A role binding of `ehos.data_reader` or `ehos.data_writer` in a production environment says when
  it ends. After its end, it says `ended: grants nothing` until EHOS removes it. `--json` gives the
  end as `expires_at`.

## See the applications that you can use

`ehosctl apps` lists each application and environment where one of your roles is bound. For each,
it shows the address, your roles, and the commands, queries and recordings that they grant you
there. It also lists an entry that grants nothing.

## See and review the versions of an application

```sh
ehosctl apps register manifest.json
ehosctl apps register ehos.yaml
ehosctl apps show ledger
ehosctl apps review ledger sha256:3f2a9c81d04e --env staging
```

A version is an application manifest that EHOS keeps
([`docs/versions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/versions-api.md)
of eh-os). Each of these commands needs `ehos.application.register`: on the application, on the
whole platform for a new application, and in the environment for a review there.

These commands put no version in force. Only a deployment does that: `ehosctl deploy`, and in
production a promotion.

- **`register`** sends the application manifest byte for byte, from a file or from stdin, as
  `deploy` does. EHOS keeps a version forever. The version is in force in no environment until a
  deployment puts it in force.
- **`register` with an `ehos.yaml`** registers a utility service. A utility service is a program
  with no contract, in any language. Its `ehos.yaml` says `kind: service`. A file whose name ends
  in `.yaml` or `.yml` is an `ehos.yaml`. `ehosctl` checks the file and writes the manifest from
  it, as `ehosctl verify` does ([Check a utility service](verify.md#check-a-utility-service)).
  Then it sends that manifest. If `ehosctl` refuses the file, it sends nothing and exits with 2.
- **A version** is named by its digest, or by its first 12 digits, as the console shows them.
- **`show`** lists the versions, newest first, and the version in force in each environment, with
  the state of its deployment. The state is the state of the deployment in force, such as `active`
  or `activating`, or `none`. It is `failed:` and the start of the failure when the newest
  deployment there, which EHOS decided after the one in force, failed. `show` reads the deployments
  of each environment, with one request for each. If it cannot read them, or EHOS is older than
  that route, the state is `unknown`, and `show` gives each reason in a warning on stderr, but
  not under `--json`. `--json` adds for each
  environment the `state`, the `deployment` in force, the newer one that `failed`, the `addresses`,
  and `why` a state is unknown.
- **`review`** shows what the version changes, compared with the version in force in the
  environment. It shows the capabilities and roles that it adds and removes, and the roles that
  grow. A role
  that grows gives each person bound to it more than before. A deployment of the version there
  makes these changes.

## See the deployments of an application in an environment

`ehosctl apps history <app> --env <env>` shows what the tab of that environment in the console
shows:

1. The deployment in force, with where it came from, the promotion that brought it to production,
   and its addresses.
2. The deployments and the refusals before it, the 20 newest of each, newest first.

Each deployment says how it ended and what came after it: "replaced by" the deployment that took
its place, or "followed by" the next deployment. It also says what that deployment changed: a new
image, a new application manifest, or new versions of secrets. `history` names a secret only to a
person who can list the secrets.

The command needs `ehos.application.deploy` or `ehos.application.register` in the environment. An
EHOS older than 0.14.0 does not say what came after a deployment.

## Put a version in force

Deploy the version with `ehosctl deploy` ([Deploying](deploy.md)). From EHOS 0.24.0, only a
deployment puts a version in force. No command puts a registered version in force by hand.

## Next steps

- [Deploying](deploy.md): put a version in force.
- [Role bindings](role-bindings.md): give a role to a person or an agent.

## Background

- [eh-os D-154](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0154-the-authority-in-force-in-an-environment-changes-only-with-a-deployment-and-nobody-puts-a-registered-version-in-force-by-hand.md):
  only a deployment changes the authority in force. Before EHOS 0.24.0, `ehosctl apps activate`
  put a registered version in force. EHOS 0.24.0 refused each call of its route, and EHOS 0.25.0
  removed the route.

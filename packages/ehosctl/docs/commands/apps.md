# Your roles and applications

`ehosctl roles` lists the roles bound to you and to your agents, as the console's My roles does
([eh-os `docs/terminal-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/terminal-api.md)).
A role bound across every application or environment shows `(all)`. One that is `gone` grants
nothing, since the version in force no longer has it, and one `beyond its owner` grants an agent
only what you hold there yourself. `--app` and `--env` keep the roles that hold there.

`ehosctl apps` lists each application and environment where one of your roles is bound: its
address, your roles, and the commands, queries and recordings they grant you there. An entry that
grants nothing is listed too.

## Versions of an application

```sh
ehosctl apps register manifest.json
ehosctl apps show ledger
ehosctl apps review ledger sha256:3f2a9c81d04e --env staging
```

These read and keep the versions of an application's manifest
([eh-os `docs/versions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/versions-api.md)).
Each needs `ehos.application.register`: for the application, at the whole platform for a new one,
and in the environment to review there. None of them puts a version in force. Only a deployment
does that: `ehosctl deploy`, and in production a promotion.

- **`register`** sends the manifest byte for byte, from a file or stdin, as `deploy` does. A
  version is kept forever, and is in force nowhere until a deployment puts it in force.
- **A version** is named by its digest, or by its first 12 digits as the console shows them.
- **`show`** lists the versions, newest first, and each environment's version in force with its
  deployment state (eh-os#413): the state of the deployment in force (`active`, `activating`), or
  `none`, or `failed:` and the start of its failure when the newest deployment there, decided
  after the one in force, failed. It reads each environment's deployments, one request for each.
  An environment whose deployments cannot be read, or every one against an EHOS older than that
  route, is `unknown`, and each reason is said once. `--json` adds each environment's `state`,
  its `deployment` in force, the newer one that `failed`, its `addresses` and `why` a state is
  unknown.
- **`review`** prints what the version changes against the version in force in the environment:
  capabilities and roles added and removed, and roles that grow, which give everyone bound to
  them more than they had. A deployment of the version there would make these changes.
- **`history <app> --env E`** prints what the console's tab for that environment shows
  ([eh-os#802](https://github.com/EmpoweredHouse/eh-os/issues/802)). It shows the deployment in force,
  with where it came from, the promotion that brought it to production and its addresses. Then come
  the deployments and refusals before it, the 20 newest of each, newest first. Each deployment says
  how it ended and what came after it: "replaced by" the one that took its place, or "followed by"
  the next one, and what that one changed: a new image, a new manifest, or new versions of
  secrets. A secret is named only to someone who may list them. It needs
  `ehos.application.deploy` or `ehos.application.register` there; an EHOS older than 0.14.0 says
  nothing of what came after.
- **Deploying** puts the manifest it deploys in force: `ehosctl deploy`. From EHOS 0.24.0 it is
  the only way, and the route `ehosctl apps activate` called answers `deployment_required`
  ([eh-os D-154](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0154-the-authority-in-force-in-an-environment-changes-only-with-a-deployment-and-nobody-puts-a-registered-version-in-force-by-hand.md)).

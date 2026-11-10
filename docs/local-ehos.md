# Try an application on a local EHOS

This page is for a developer of an application that `ehos_app` generated. It shows how to run the
application in a complete EHOS on your computer. There you can sign in to it and use its roles.
The [glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

`mix phx.server` runs the application without EHOS. There, `/auth/ehos/sign-in` answers 503. The
pages behind `:signed_in` and the commands do not work. eh-os runs a complete EHOS in a k3d
cluster on your computer, at `https://ehos.localhost`. It has a database of its own, sends no
mail, and only you use it.

The local EHOS runs the image that CI built from `main`. A change that is not on `main` does not
get there. To try a pull request, use its preview on an installation of EHOS: the
`DEVELOPMENT.md` of the application, "Previews of pull requests", says how.

In the commands below, `<app>` is the name of the application in EHOS: the `name:` of its domain.
`<actor>` is an actor of the domain.

## Prerequisites

- A checkout of [eh-os](https://github.com/EmpoweredHouse/eh-os), and the tools that its
  [DEVELOPMENT.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/DEVELOPMENT.md), "Once
  per machine", names: Docker, and the tools that asdf installs, k3d among them. Run `asdf install`
  and `mix setup` in the checkout one time.
- A GitHub token that can read packages (`read:packages`) and nothing else. The image of the
  application is a private package on `ghcr.io`, and the cluster uses the token to pull it.
- A run of CI on `main` of the application that succeeded.
- `ehosctl`, installed as the
  [golden path](golden-path.md#1--install-ehosctl) says.

## Start the local EHOS

Do these steps in the checkout of eh-os.

1. Start the cluster. The first time, this takes a few minutes.

   ```sh
   mix ehos.cluster up
   ```

   EHOS answers at `https://ehos.localhost`. The CA certificate of the cluster is in
   `_build/k3d/ca.crt`.

2. Give the cluster the token, then deploy EHOS again. EHOS gives the token to each of its
   environments, so that they can pull the image of the application.

   ```sh
   kubectl --context k3d-ehos -n ehos-system create secret docker-registry ehos-pull-credential --docker-server=ghcr.io --docker-username=<your GitHub user> --docker-password=<the token>
   mix ehos.cluster deploy
   ```

3. Make yourself the administrator of the local EHOS. The command prints a link that signs you in
   one time.

   ```sh
   kubectl --context k3d-ehos -n ehos-system exec deployment/ehos-governance -c governance -- bin/ehos eval 'Ehos.Release.invite("<your email>")'
   ```

4. Open the link. The browser warns about the certificate. Add an exception for this site only.

The administrator holds each capability of EHOS. The local EHOS thus refuses you nothing that a
role allows. On an installation of other people you get less: the `DEVELOPMENT.md` of the
application, "Who deploys, and joining the team", says what.

## Deploy the application

Do these steps in the folder of the application.

1. Sign in to the local EHOS with its CA.

   ```sh
   EHOSCTL_CA_FILE=<eh-os>/_build/k3d/ca.crt ehosctl login https://ehos.localhost
   ```

   The local EHOS becomes the current installation of `ehosctl`. Each later `ehosctl` command
   goes to it, until `ehosctl installations use <name>` makes another installation the current
   one.

2. Download the image name and the bundle of the newest run of CI on `main`.

   ```sh
   run=$(gh run list -w ci.yml -e push -b main -s success -L 1 --json databaseId -q '.[0].databaseId')
   rm -rf _build/deploy
   gh run download "$run" -n ehos-deployment -D _build/deploy
   ```

   `gh run download` does not write over an earlier download. The `rm` removes it.

3. Register the application, and make an ephemeral environment for it. Do this one time for each
   cluster.

   ```sh
   ehosctl apps register _build/deploy/ehos.bundle/ehos.manifest.json
   ehosctl env create <app>-try --app <app>
   ```

4. Deploy the image with the bundle.

   ```sh
   ehosctl deploy <app> --env <app>-try --image "$(cat _build/deploy/image)" --bundle _build/deploy/ehos.bundle
   ```

   `ehosctl deploy` waits until the deployment is active, or until it fails.

5. Bind yourself a role of the application in the environment. Nobody can use the application
   until a role is bound to them, the administrator included.

   ```sh
   ehosctl role-bindings bind <app>.<actor> --to <your email> --app <app> --env <app>-try
   ```

6. Open `https://<app>.<app>-try.ehos.localhost`, and sign in. The browser warns about the
   certificate of this address too.

## Deploy a newer build

Do steps 2 and 4 of "Deploy the application" again. The new version replaces the earlier one in
the same environment.

The environment expires 1 day after `env create`. To keep it longer, extend it:

```sh
ehosctl env extend <app>-try --ttl 3d
```

If the environment expired, do steps 3 to 5 again, without `apps register`.

## What can go wrong

- **`ehosctl login` refuses the certificate.** The cluster makes a new CA each time `mix
  ehos.cluster up` creates it. Sign in again with the new `_build/k3d/ca.crt`.
- **The deployment does not become active, and its pod cannot pull the image.** The cluster has no
  token, or the token cannot read the package. Delete the secret
  `ehos-pull-credential` in `ehos-system`. Then do step 2 of "Start the local EHOS" again.
- **Another message of the cluster.** The
  [DEVELOPMENT.md of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/DEVELOPMENT.md),
  "Troubleshooting", gives the messages of the local cluster and their fixes.

## Next steps

- The `DEVELOPMENT.md` of the application, "Previews of pull requests": try a pull request on an
  installation of EHOS.
- The `DEVELOPMENT.md` of the application, "Deploying": move a version to production.

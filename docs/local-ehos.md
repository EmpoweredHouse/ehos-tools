# Try an application on a local EHOS

This page is for a developer of an application that `ehos_app` generated. It shows how to run the
application in a complete EHOS on your computer. There you can sign in to it and use its roles.
The [glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

`mix phx.server` runs the application without EHOS. There, a person signs in at `/dev/sign-in` with
a key the application made, and nothing that EHOS gives is checked: the people, their grants and the
mail are stand-ins. eh-os runs a complete EHOS in a k3d cluster on your computer, at
`https://ehos.localhost`. It has a database of its own, sends no mail, and only you use it.

This page deploys the image and the bundle that CI built from `main`. To try a pull request, use
its preview on an installation of EHOS: the `DEVELOPMENT.md` of the application, "Previews of
pull requests", says how.

In the commands below, `<app>` is the name of the application in EHOS: the `name:` of its domain.
`<actor>` is an actor of the domain.

## Prerequisites

- A checkout of [eh-os](https://github.com/EmpoweredHouse/eh-os), and the tools that its
  [DEVELOPMENT.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/DEVELOPMENT.md), "Once
  per machine", names: Docker, and the tools that asdf installs, k3d among them. Run `asdf install`
  and `mix setup` in the checkout one time.
- Access to ehos-tools and eh-os-contract through `gh auth login`, or a `GITHUB_TOKEN` that can
  read them. `mix ehos.cluster up` builds the image of EHOS with it.
- A classic GitHub token with the scope `read:packages` alone, and a short expiry. The image of the
  application is a private package on `ghcr.io`, and the cluster uses the token to pull it. The
  token can read each package that you can see, and EHOS copies it into each environment of the
  cluster.
- A run of CI on `main` of the application that succeeded.
- `ehosctl`, installed as the [golden path](golden-path.md#1--install-ehosctl) says.

## Start the local EHOS

Do these steps in the checkout of eh-os. Each `kubectl` command names the context `k3d-ehos`, so
it acts only on the local cluster.

1. Start the cluster. The first time, this takes a few minutes.

   ```sh
   mix ehos.cluster up
   ```

   EHOS answers at `https://ehos.localhost`. The CA certificate of the cluster is in
   `_build/k3d/ca.crt`.

2. Give the cluster the token, then deploy EHOS again. `read -rs` waits for the token without
   showing it, and keeps it out of the history of your shell. EHOS gives the token to each of its
   environments, so that they can pull the image of the application.

   ```sh
   read -rs GHCR_TOKEN
   kubectl --context k3d-ehos -n ehos-system create secret docker-registry ehos-pull-credential --docker-server=ghcr.io --docker-username=<your GitHub user> --docker-password="$GHCR_TOKEN"
   mix ehos.cluster deploy
   ```

3. Make yourself the administrator of the local EHOS.

   ```sh
   kubectl --context k3d-ehos -n ehos-system exec deployment/ehos-governance -c governance -- bin/ehos eval 'Ehos.Release.invite("<your email>")'
   ```

   The command prints a link, and a line that says that you are `ehos.administrator` now. If that
   line is not there, the cluster has an administrator already. You can open the console, but you
   cannot register or deploy the application. Make a new cluster: `mix ehos.cluster down`, then do these steps again.

4. Open the link within 15 minutes. It signs you in one time. The browser warns about the
   certificate: add an exception for this site only.

5. Right after you open the link, set a password on **Account settings**,
   `https://ehos.localhost/people/settings`. `ehosctl login` asks for it, and the cluster sends no
   mail to reset it.

The administrator holds each capability of EHOS. The local EHOS thus refuses you nothing that a
role allows. On an installation of other people you get less: the `DEVELOPMENT.md` of the
application, "Who deploys, and joining the team", says what.

## Deploy the application

Do these steps in the folder of the application.

1. Name the local EHOS `local`, and sign in to it with its CA.

   ```sh
   export EHOSCTL_INSTALLATION=local
   EHOSCTL_CA_FILE=<eh-os>/_build/k3d/ca.crt ehosctl login https://ehos.localhost --installation local
   ```

   `EHOSCTL_INSTALLATION` sends each `ehosctl` command in this shell to the local EHOS. Set it
   before the other commands: an `EHOSCTL_INSTALLATION` that names another installation sends
   them there, also after this `login`.

2. Give EHOS a database for the ephemeral environments. Do this one time for each cluster.

   ```sh
   ehosctl resources classify trial non_production
   ehosctl env template create sandbox --default
   ehosctl env template bind sandbox trial
   ```

   Each new ephemeral environment gets the database `trial`. Without this step, `env create` is
   refused with `no_template`.

3. Download the image name and the bundle of the newest run of CI on `main`.

   ```sh
   run=$(gh run list -w ci.yml -e push -b main -s success -L 1 --json databaseId -q '.[0].databaseId')
   rm -rf _build/deploy
   gh run download "$run" -n ehos-deployment -D _build/deploy
   ```

   `gh run download` does not write over an earlier download. The `rm` removes it.

4. Register the application, and make an ephemeral environment for it. Do this one time for each
   cluster.

   ```sh
   ehosctl apps register _build/deploy/ehos.bundle/ehos.manifest.json
   ehosctl env create <app>-try --app <app>
   ```

5. Deploy the image with the bundle.

   ```sh
   ehosctl deploy <app> --env <app>-try --image "$(cat _build/deploy/image)" --bundle _build/deploy/ehos.bundle
   ```

   `ehosctl deploy` waits until the deployment is active, or until it fails, for 10 minutes at
   most.

6. Bind yourself a role of the application in the environment. Nobody can use the application
   until a role is bound to them, the administrator included.

   ```sh
   ehosctl role-bindings bind <app>.<actor> --to <your email> --app <app> --env <app>-try
   ```

7. Open `https://<app>.<app>-try.ehos.localhost`, and sign in. The browser warns about the
   certificate of this address too: add an exception for this site only.

## Deploy a newer version

In a shell where `EHOSCTL_INSTALLATION` is `local`, do steps 3 and 5 of "Deploy the application"
again. The new version replaces the earlier one in the same environment.

The environment expires 1 day after `env create`. To keep it longer, extend it:

```sh
ehosctl env extend <app>-try --ttl 3d
```

If the environment expired, do steps 4 to 6 again, without `apps register`.

## What can go wrong

- **`ehosctl login` refuses the certificate.** The cluster makes a new CA each time `mix
  ehos.cluster up` creates it. Sign in again with the new `_build/k3d/ca.crt`.
- **The log-in page asks for a password that you did not set.** Do step 3 of "Start the local
  EHOS" again. It prints a new link that signs you in one time.
- **`env create` is refused with `no_template`, or the deployment with `needs.database`.** Do
  step 2 of "Deploy the application". An environment made before that step has no database:
  remove it with `ehosctl env remove <app>-try --confirm <app>-try`, then make it again.
- **The deployment does not become active, and its pod cannot pull the image.** The cluster has no
  token, or the token cannot read the package. Delete the secret, do step 2 of "Start the local
  EHOS" again, then deploy again.

  ```sh
  kubectl --context k3d-ehos -n ehos-system delete secret ehos-pull-credential
  ```

- **Another message of the cluster.** The
  [DEVELOPMENT.md of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/DEVELOPMENT.md),
  "Troubleshooting", gives the messages of the local cluster and their fixes.

## Next steps

- The `DEVELOPMENT.md` of the application, "Previews of pull requests": try a pull request on an
  installation of EHOS.
- The `DEVELOPMENT.md` of the application, "Deploying": move a version to production.

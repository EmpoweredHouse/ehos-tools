# The golden path

From an empty machine to an application deployed on [EHOS](https://github.com/EmpoweredHouse/eh-os),
signed in to and used: one command per step, what it prints when it works, and what to do when it
does not. The examples make an application `shop` in a repository `EmpoweredHouse/shop`, deployed
to the environment `production` of an installation at `https://ehos.example.com`. The output
shown is `ehosctl` 0.6.0's.

A step marked **administrator** needs a role on the installation that a developer may not hold,
and one marked **organisation owner** needs EmpoweredHouse's GitHub organisation. If that is not
you, send them the command; if it is, run it yourself.

After the first deployment, the generated `DEVELOPMENT.md` is the guide: the development cycle,
contract first, running it locally, and deploying again.

## 0 · Before you start: an installation, and an account on it

You need the installation's address, an account there, and, when the installation has a
certificate authority of its own (a trial server's does), its CA file:
`~/.ehos/<installation>/ca.crt` on the machine that installed it. A CA certificate is not a secret,
but it must be the right one, since `ehosctl` trusts it from then on: compare its fingerprint,
`openssl x509 -noout -fingerprint -sha256 -in ca.crt`, with the one the operator who installed it
reads from their copy, sent over another channel than the one that brought you the file.

- **An account:** the **administrator** invites you in the console's *People*. The installation
  sends no mail yet, so the console shows a one-time sign-in link, valid for 15 minutes. The link
  is a password: it signs in whoever opens it first, as you. They send it to you alone, in a direct
  message, never in a channel, a ticket or a thread others read, and you open it at once and set a
  password in the console's settings. If anyone else may have seen it, or it expired, they invite
  you again. `ehosctl people invite` makes the account too, but never shows the link.
- **No installation yet:** the same `ehosctl` makes the server and installs EHOS on it.
  eh-os's [INSTALLING.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md)
  walks it, with what each step needs (a cloud account, an SSH key, a state passphrase, a token
  that reads EHOS's images, and how to keep them out of your shell's history), in about
  25 minutes:

  ```sh
  ehosctl doctor
  ehosctl server up
  ehosctl server tunnel
  ehosctl install
  ```

  `doctor` checks the tools and the cloud credentials, `server up` makes the server (on Oracle
  Cloud unless told otherwise), `server tunnel` brings its Kubernetes API to your machine, and
  `install`, with `GHCR_TOKEN` set as INSTALLING.md says, installs EHOS. It ends with the command
  that invites the first person, the platform's administrator.

## 1 · Install `ehosctl`

```sh
read -rs MISE_GITHUB_TOKEN
MISE_GITHUB_TOKEN="$MISE_GITHUB_TOKEN" mise use -g github:EmpoweredHouse/ehos-tools
ehosctl --version
```

`read -rs` waits for the token, pasted, without showing it or keeping it in your shell's history,
and the next line gives it to that one command rather than exporting it. The token is best a
fine-grained one that reads ehos-tools alone
([While the repository is private](../README.md#while-the-repository-is-private)).

It works when `ehosctl --version` prints the version, `ehosctl 0.6.0` or later. `ehosctl --help`
names the template `init` creates applications from.

- **mise answers 404, or that the tool does not exist:** it has no token that reads the private
  repository.
- **`command not found`:** mise is not active in your shell, or asdf's shims hide it
  ([With asdf](../README.md#with-asdf)).
- **An older version than the newest release:** mise hides a release for a while after it is
  published. Name the version: `mise use -g github:EmpoweredHouse/ehos-tools@0.6.0`
  ([Upgrading](../README.md#upgrading)).

## 2 · Generate the application

```sh
ehosctl init shop
cd shop
```

The name is the application's OTP name and its domain's: lowercase letters, digits and
underscores. EHOS names the application with dashes instead, since it becomes a DNS label:
`my_shop` is `my-shop` in every `ehosctl` command after this one, and in its address. The
repository may be named otherwise; the image takes the repository's name.

It works when, after about a minute and a half, it ends with `EHOS: the project is ready. Start a
database, then:` and the next steps, and `git log` shows one commit.

- **`shop already exists`:** `init` generates into a directory of its own and runs `git init`
  there; it does not generate into a repository you cloned
  ([#63](https://github.com/EmpoweredHouse/ehos-tools/issues/63)). Generate beside it, then push
  to the empty repository (step 4).
- **`mise does not trust it yet`:** `init` stopped before its first commit. Run the `mise trust`
  it names, then commit in `shop/` with `git init`, `git add -A` and `git commit`.
- **It used an older template than you expected:** each `ehosctl` generates the template it pins.
  `ehosctl versions` says whether a newer `ehosctl` is out.

## 3 · The database, and the gates

Without a PostgreSQL listening on port 5432, start one in Docker, reachable from this machine
alone, then set the project up:

```sh
docker run -d --name shop-postgres -p 127.0.0.1:5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18
mix ecto.setup
mix precommit
```

It works when `mix precommit` passes every test and ends with
`eh_os_contract.check: 0 errors, 0 warnings, 0 notices`. `docker rm -f shop-postgres` removes the
database when you are done with it.

- **The databases went somewhere unexpected:** any PostgreSQL on port 5432 that accepts
  `postgres:postgres` takes them, another project's included, without a word
  ([Ports and the database](../README.md#ports-and-the-database)).
- **mix asks "Shall I install Hex?", or names another Elixir:** asdf's `mix` ran, not mise's. Run
  `MISE_ACTIVATE_AGGRESSIVE=1 mise exec -- mix precommit` ([With asdf](../README.md#with-asdf)).

## 4 · The repository, and CI

```sh
gh repo create EmpoweredHouse/shop --private --source .
git branch -M main
```

For a repository that already exists and is empty, `git remote add origin
https://github.com/EmpoweredHouse/shop.git` instead of `gh repo create`. `git branch -M main`
changes nothing when the branch is `main` already, and renames it when `git init` called it
`master`, as git does on most Linux distributions
([#190](https://github.com/EmpoweredHouse/ehos-tools/issues/190)): CI publishes from `main` alone.

CI reads EmpoweredHouse's private libraries through a GitHub App, whose ID and private key the
repository needs as secrets ([The generated project's CI](../README.md#the-generated-projects-ci)).
An **organisation owner** sets them on the repository, so that the key stays with them:

```sh
gh secret set EHOS_CI_APP_ID -R EmpoweredHouse/shop --body <the App's ID>
gh secret set EHOS_CI_APP_PRIVATE_KEY -R EmpoweredHouse/shop < <the App's private key>.pem
```

Then push, and watch the run:

```sh
git push -u origin main
gh run watch
```

It works when the run on `main` passes every job (`check`, `image` for each architecture, and
`publish`) and has the artifact `ehos-deployment`: the image's name with its digest, and the
manifest. About five to seven minutes, most of it building the image.

- **The first job fails at once, naming `EHOS_CI_APP_ID` and `EHOS_CI_APP_PRIVATE_KEY`:** the
  secrets are not set. Once they are, `gh run rerun <the run> --failed`.
- **The run published no image and no `ehos-deployment`:** it ran on a pull request, or on a
  branch other than `main`. A pull request builds the image to check it, and only a push to
  `main` publishes it.

## 5 · Sign in

```sh
EHOSCTL_CA_FILE=<the installation's ca.crt> ehosctl login https://ehos.example.com
ehosctl whoami
```

Your browser opens EHOS's log-in page, where you type your password; `ehosctl` never sees it.
`EHOSCTL_CA_FILE` is needed once, at `login`, and only for an installation with a CA of its own:
`login` keeps the CA, and `ehosctl installations list` shows `own` in its CA column.

Your browser does not trust that CA either, and warns on the log-in page. Trust it in one browser
that keeps certificates of its own rather than in the whole system (Firefox: *Settings*, *Privacy &
Security*, *View Certificates*, *Authorities*, *Import*, for websites): whoever holds the CA's key
could pass for any site to whatever trusts it. Do not click
through the warning on a network you do not trust, since the page asks for your password.

It works when `whoami` prints `You are you@example.com, signed in to <the installation>
(https://ehos.example.com) until <a date>.` A sign-in lasts three days without a command and a
week at most; `ehosctl login` again then.

- **The handshake fails, or `ehosctl` asks for `EHOSCTL_CA_FILE`:** `ehosctl` does not trust the
  installation's CA. Sign in again with the variable. An installation added by an `ehosctl` older
  than 0.5.0 kept no CA: its column says `system`, and the same `login` fixes it.
- **A forgotten password:** the installation sends no mail, and someone who has joined cannot be
  invited again. The operator, once they know the request is yours, runs the release command of
  INSTALLING.md's
  [step 4](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#4--invite-the-first-person)
  with your email, which prints a new one-time link
  ([eh-os#441](https://github.com/EmpoweredHouse/eh-os/issues/441)), and sends it to you alone, as
  an invitation's. Open it in a private window,
  so it is not mixed up with a `login` you left unfinished, set a new password in the console's
  settings, then `ehosctl login` again.

## 6 · Have EHOS check the application

```sh
ehosctl verify
```

It runs CI's gates, then, signed in, asks the installation whether it accepts the application:

```text
Every gate passed.
EHOS at https://ehos.example.com:
  accepts ehos.yaml, as ehos.yaml/v3.
  accepts the manifest of shop, as ehos.manifest/v3.
```

- **A gate fails:** it is named, with its output; fix it and run `verify` again.
- **EHOS does not accept `ehos.yaml` or the manifest:** the installation runs an EHOS older than the
  template. `ehosctl versions` shows both versions; an EHOS older than 0.5.0 has no API for
  `ehosctl`, and every command meets a 404. Upgrading EHOS is the operator's: `ehosctl upgrade`
  ([INSTALLING.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#looking-after-it)).

## 7 · The environment and its database

```sh
ehosctl env show production
```

It works when the environment has a PostgreSQL bound as its default:

```text
production, production

 KIND      RESOURCE  FOR      SCHEMA  USED  ID
 postgres  shared    default          no    66d53e11-…
```

- **No environment `production`, or no row `postgres … default`:** the **administrator** creates
  the environment, says that the installation's PostgreSQL serves production (`ehosctl resources
  list` names it), and binds it:

  ```sh
  ehosctl env create production --type production
  ehosctl resources classify shared production
  ehosctl env bind production shared
  ```

  These need `ehos.environment.manage` and `ehos.resource.manage`, which `ehos.administrator` and
  `ehos.platform_operator` hold. A resource serves production environments or the others, never
  both, and is classified once.

## 8 · Deploy

```sh
rm -rf _build/deploy
gh run download "$(gh run list -b main -s success -L 1 --json databaseId --jq '.[0].databaseId')" \
  -n ehos-deployment -D _build/deploy
ehosctl deploy shop --env production --manifest _build/deploy/ehos.manifest.json --preview
ehosctl deploy shop --env production \
  --image "$(cat _build/deploy/image)" --manifest _build/deploy/ehos.manifest.json
```

`gh run download` refuses to write over an earlier download, hence the `rm`. `--preview` deploys
nothing. It shows what the deployment would do and every reason EHOS would
refuse it, and exits 1 when it would be refused:

```text
What deploying shop to production would do; nothing was deployed.
  …
 NEEDS     ASKS FOR        BOUND TO
 database  postgres >= 16  shared, PostgreSQL 18, schema ehos_shop_production

To deploy it, run the command again without --preview, naming the image with --image.
```

The first deployment of an application also registers it: the preview shows what its roles
grant, and it needs `ehos.application.register` besides `ehos.application.deploy`. `deploy` then
waits, for at most ten minutes, while EHOS makes the application's schema and roles, runs its
migrations and starts it. It works when it ends like this and exits 0:

```text
Waiting until it is active, for at most 10 minutes:
  activating
  active
Deployment 5f0c… is active in production, at https://shop.production.ehos.example.com.
```

- **`production has no resource bound for a postgres database`:** step 7.
- **A refusal for a capability you do not hold** (`ehos.application.deploy`, or
  `ehos.application.register` the first time): the **administrator** makes the first deployment,
  which registers the application. After it, they can bind you the application's administrator,
  in that application alone: `ehosctl role-bindings bind ehos.application_administrator --to
  you@example.com --app shop`. That role deploys the application and binds its roles to anyone.
- **`Deployment … failed in production: ProgressDeadlineExceeded: …`, exit 1, after about three
  minutes:** the application did not start. The version deployed before keeps serving, and a first
  deployment is stopped. Most often the cluster cannot pull the image, since the installation reads
  packages with one token whose account must see the repository's
  ([eh-os#219](https://github.com/EmpoweredHouse/eh-os/issues/219)), or the release stops at start.
  The application's logs are the operator's to read with `kubectl` until EHOS shows them; deploy
  again once it is fixed.
- **Exit 5 after ten minutes, with the state it is still in:** EHOS is still working on it.
  `ehosctl apps show shop` says the state later; a deployment that stays `activating` is the
  operator's to look into
  ([INSTALLING.md, Troubleshooting](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#troubleshooting)).

## 9 · Let people in

```sh
ehosctl role-bindings bind shop.clerk --to you@example.com --app shop --env production
ehosctl roles
```

Nobody can use the application until a role of it is bound to them, the platform's administrator
included. A role is the application's name and an actor of its domain (`lib/shop/domain.ex`); the
template's example has `clerk` and `auditor`. Binding a role to someone needs the right to manage
role bindings there, which the **administrator** has, and the application's administrator.

It works when `ehosctl roles` lists `shop.clerk` held by you in `shop`, `production`.

- **Refused for its scope:** an application's role is bound in one of its environments, so it
  takes both `--app` and `--env`.

## 10 · Use it

Open `https://shop.production.ehos.example.com`: it sends you to EHOS to sign in, and back. Then
from the terminal:

```sh
ehosctl apps
ehosctl call shop shop.record_entry entry_id="$(uuidgen)" amount:=100
```

`apps` lists what each application offers and what your roles let you do. `call` does one thing
as you; it works when it prints the receipt:

```text
Done: shop.record_entry, as 0192d3a4-….
  identity: {"entry_id":"…"}
  event: shop.entries.recorded at position 1
```

- **The browser warns that the connection is not private:** it does not trust the installation's
  CA (step 5).
- **The page says no role bound to you grants anything, or `call` exits 3 naming the capability:**
  step 9, with a role whose actor may do that. In the example, `flag_entry` is the `auditor`'s.
- **`call` names a field that is missing or does not fit:** the application says what its command
  takes. `entry_id` is the caller's to give.

## 11 · Later

```sh
ehosctl versions
```

It says, for `ehosctl`, EHOS, `ehos_app`, `eh_os_contract` and `ehos_design`, the version in use,
the newest, whether the installation accepts it, and the command that moves to it. `ehosctl` also
says so after a command, at most once a day.

- **A new `ehosctl`:** the `mise use -g …@<version>` it prints
  ([Upgrading](../README.md#upgrading)).
- **A new template:** move `ehos_app` in `mix.exs` as `versions` prints it, then `mix deps.get`,
  `mix ehos_app.install` and `mix precommit`
  ([packages/ehos_app](../packages/ehos_app/README.md)). Its changelog says what a project made
  before a release must change by hand.
- **A change to the application:** merged to `main`, it is built by CI, and deployed as in step 8,
  over the version before; its data is kept. The generated `DEVELOPMENT.md` has the rest: the
  contract first, migrations that take two deploys, building the image yourself.

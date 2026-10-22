# The golden path

From an empty machine to an application deployed on [EHOS](https://github.com/EmpoweredHouse/eh-os),
signed in to and used: one command per step, what it prints when it works, and what to do when it
does not. The examples make an application `shop` in a repository `EmpoweredHouse/shop`, deployed
to the environment `production` of an installation at `https://ehos.example.com`. The output
shown is `ehosctl` 0.8.0's, which creates applications from `ehos_app` 0.11.0.

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

- **An account:** the **administrator** invites you, with `ehosctl server invite <your email>
  --installation <installation>` on the operator's machine, or in the console's *People*. The
  installation sends no mail yet, so either shows a one-time sign-in link, valid for 15 minutes.
  The link is a password: it signs in whoever opens it first, as you. They send it to you alone,
  in a direct message, never in a channel, a ticket or a thread others read, and you open it at
  once and set a password in the console's settings. If anyone else may have seen it before you
  used it, they invite you again: from EHOS 0.8.0 a new link ends every earlier one (eh-os#446);
  before it, they disable you and enable you first. A link someone else already used is the
  administrator's to deal with, as eh-os's INSTALLING.md says.
  `ehosctl people invite` makes the account too, but never shows the link.
- **No installation yet:** the same `ehosctl` makes the server and installs EHOS on it.
  eh-os's [INSTALLING.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md)
  walks it, with what each step needs (a cloud account, an SSH key, a state passphrase, a token
  that reads EHOS's images, and how to keep them out of your shell's history), in about
  25 minutes:

  ```sh
  export EHOSCTL_INSTALLATION=shop
  ehosctl doctor
  ehosctl server up --provider oci
  ehosctl server tunnel
  ehosctl install
  ```

  An installation is one company's EHOS, with its own server, console, people and record: name it
  after the company or the application it is for (2 to 16 lowercase letters, digits and hyphens,
  starting with a letter and ending with a letter or digit), and give that name to every command,
  here through `EHOSCTL_INSTALLATION`, so that none falls back to another installation's
  ([#194](https://github.com/EmpoweredHouse/ehos-tools/issues/194)). `doctor` checks the tools and
  the cloud credentials, `server up` makes the server in the cloud `--provider` names (`oci`,
  `aws`, `gcp` or `ovh`; there is no default), `server tunnel` brings its Kubernetes API to your
  machine, and `install`, with `GHCR_TOKEN` set as INSTALLING.md says, installs EHOS. `server up`
  admits SSH only from this machine's public addresses, every one it sees when it asks several
  services, more than once. A network can still
  leave through one it did not see: `up` then waits at "Waiting for the server to answer SSH", and
  it, `tunnel` and `status` name the addresses admitted when SSH does not answer. Run `server up`
  again with `--ssh-from` for each address your network leaves through, or its provider's range
  ([#157](https://github.com/EmpoweredHouse/ehos-tools/issues/157)). Oracle's free tier is 2 OCPUs and 12 GB for the whole
  account: for two installations there, give each `server up --ocpus 1 --memory-gb 6`.

  `install` ends by naming the command that invites the first person, who becomes the platform's
  administrator: `ehosctl server invite <your email> --installation shop`. It prints the one-time
  link to open.

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

It works when `ehosctl --version` prints the version, `ehosctl 0.8.0` or later. `ehosctl --help`
names the template `init` creates applications from.

- **mise answers 404, or that the tool does not exist:** it has no token that reads the private
  repository.
- **`command not found`:** mise is not active in your shell, or asdf's shims hide it
  ([With asdf](../README.md#with-asdf)).
- **An older version than the newest release:** mise hides a release for a while after it is
  published. Name the version: `mise use -g github:EmpoweredHouse/ehos-tools@0.8.0`
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
```

For a repository that already exists and is empty, `git remote add origin
https://github.com/EmpoweredHouse/shop.git` instead of `gh repo create`. `init` made the first
commit on `main`, which CI publishes from; a project an `ehosctl` older than 0.8.0 generated on
Linux may be on `master`, and `git branch -M main` renames it.

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
- **The run published no image and no `ehos-deployment`:** it ran on a pull request from a fork,
  which builds the image to check it. A pull request of the repository publishes too, and is
  previewed once the repository names its installation (the generated `DEVELOPMENT.md`,
  "Previews of pull requests"). A push to another branch starts no run at all.

## 5 · Sign in

```sh
EHOSCTL_CA_FILE=<the installation's ca.crt> ehosctl login https://ehos.example.com
ehosctl whoami
```

Your browser opens EHOS's log-in page, where you type your password; `ehosctl` never sees it.
`EHOSCTL_CA_FILE` is needed once, at `login`, and only for an installation with a CA of its own:
`login` keeps the CA, and `ehosctl installations list` shows `own` in its CA column.

If you installed it yourself (step 0), `ehosctl login --installation shop` is enough: `install`
kept the installation's address and CA under its name, so both planes call it the same.

Your browser does not trust that CA either, and warns on the log-in page. Trust it in one browser
that keeps certificates of its own rather than in the whole system (Firefox: *Settings*, *Privacy &
Security*, *View Certificates*, *Authorities*, *Import*, for websites): whoever holds the CA's key
could pass for any site to whatever trusts it. `login` opens your default browser and prints the
address it opened, under `If it does not open, go to:`; when the default is another browser, open
that address in the one that trusts the CA. Do not click through the warning on a network you do
not trust, since the page asks for your password.

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
  accepts ehos.yaml, as ehos.yaml/v4.
  accepts the manifest of shop, as ehos.manifest/v4.
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

A version reaches production only by promotion, after it is tried as a candidate in an ephemeral
environment of its own ([eh-os D-105](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0105-production-is-reached-only-by-promoting-a-candidate-and-a-promotion-is-a-record-of-its-own-approved-by-the-application-s-process-owner.md)).
That environment gets its database from the installation's second PostgreSQL, `trial`, through
the installation's default template:

- **`ehosctl env create` refuses `no_template`, or the candidate `needs.database`:** the
  **administrator** says `trial` serves the other environments (`ehosctl resources classify trial
  non_production`), and, in the console's **Templates**, makes `sandbox` the default with `trial`
  as its postgres (console only until the template commands of
  [ehos-tools#224](https://github.com/EmpoweredHouse/ehos-tools/issues/224)).

## 8 · Deploy a candidate, and promote it

```sh
rm -rf _build/deploy
gh run download "$(gh run list -w ci.yml -e push -b main -s success -L 1 --json databaseId -q '.[0].databaseId')" \
  -n ehos-deployment -D _build/deploy
ehosctl apps register _build/deploy/ehos.manifest.json   # the first time
ehosctl env create shop-try --app shop                   # once, while it lives
ehosctl deploy shop --env shop-try --manifest _build/deploy/ehos.manifest.json --preview
ehosctl deploy shop --env shop-try \
  --image "$(cat _build/deploy/image)" --manifest _build/deploy/ehos.manifest.json \
  $(find _build/deploy/ehos.graph -name '*.json' -exec echo --graph {} \; 2> /dev/null)
```

`gh run download` refuses to write over an earlier download, hence the `rm`. Each `--graph` sends
one of shop's graph documents, which CI wrote into `ehos.graph/`: its domain's, which EHOS draws in
the environment's landscape of applications, and each contract's and process module's, which the
console shows inside shop. EHOS takes a domain's from 0.14.0 and a contract's or a process
module's from 0.18.0, and an older one refuses the deployment: before 0.18.0, `-name
'domain.*.json'` sends the domain's alone, and before 0.14.0, leave the line out. `apps register`
keeps the manifest as shop's first version, which EHOS needs before it makes shop an environment; it
needs `ehos.application.register`. `env create` makes an ephemeral environment of `shop` from the
installation's default template, once: a later version is deployed to the same environment while it
lives, and replaces the candidate there, withdrawing any promotion asked for it. It expires in a day
unless `ehosctl env extend shop-try --app shop` gives it longer, and an application has three by
default, its pull requests' previews among them, each of which makes one of its own (the generated
`DEVELOPMENT.md`, "Previews of pull requests"). `--preview` deploys nothing. It shows what the
deployment would do and every reason EHOS would refuse it, and exits 1 when it would be refused:

```text
What deploying shop to shop-try would do; nothing was deployed.
  …
 NEEDS     ASKS FOR        BOUND TO
 database  postgres >= 16  trial, PostgreSQL 18, schema ehos_shop_shop_try

To deploy it, run the command again without --preview, naming the image with --image.
```

The first deployment in each new environment also registers the application there: the preview
shows what its roles grant, and it needs `ehos.application.register` besides
`ehos.application.deploy`. `deploy` then
waits, for at most ten minutes, while EHOS makes the application's schema and roles, runs its
migrations and starts it, and seeds it (`priv/repo/seeds.exs`, since this environment is
ephemeral). It works when it ends like this and exits 0:

```text
Waiting until it is active, for at most 10 minutes:
  activating
  active
Deployment 5f0c… is active in shop-try, at https://shop.shop-try.ehos.example.com.
```

Try it there. Then promote it: in the console, on shop's page, **Candidates and promotions** lists
the candidate; choose **Promote to production**. Its **process owner**, someone the
**administrator** bound `ehos.process_owner` on shop, who neither deployed the candidate nor asked
for its promotion, finds it under **Promotions**, reviews what the approval binds to, and approves
it. This first promotion puts shop's roles and capabilities in force in production, as any later
one that changes them does, so its approver also holds `ehos.application.register` there
([eh-os D-119](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0119-approving-a-promotion-that-puts-another-authority-in-force-needs-the-right-to-register-it-and-it-waits-only-for-whoever-holds-both.md)).
So before it, the administrator binds the process owner `ehos.registrar` there too, a role EHOS has
from 0.11.0 that holds that capability alone: `ehosctl role-bindings bind ehos.registrar --to
owner@example.com --app shop --env production`. With it they may also activate in production,
alone, any version EHOS has recorded of shop, from any of its environments, which changes what
shop's roles may do there, as its administrator may; they register no new version and bind no one.
Without it **Promotions** does not list the promotion for them, though shop's own promotions page
still shows it and its review says what is missing. Keep `shop-try` alive until the promotion is
approved: a candidate whose environment expires is no longer one, and its promotion is withdrawn.
Production's deployment is then decided from the same image and manifest, against production's own
data and secrets, and
`ehosctl apps show shop` says when it is active. A new installation runs without four eyes unless
it turns them on (`ehosctl install --four-eyes`, eh-os D-128): an installation of one person
approves its own promotion, and each approval is recorded as a self-approval. `ehosctl promote`
and `approve` come with
[ehos-tools#246](https://github.com/EmpoweredHouse/ehos-tools/issues/246).

- **`promotion_required`:** a deployment straight to production, which EHOS refuses since 0.9.0;
  promote a candidate instead.
- **`needs.database: … has no resource bound for a postgres database`:** step 7.
- **A refusal for a capability you do not hold** (`ehos.application.register` at `apps register`
  or a first deployment, or `ehos.application.deploy`): the **administrator** registers the
  application. After it, they can bind you the application's administrator, in that application
  alone: `ehosctl role-bindings bind ehos.application_administrator --to you@example.com --app
  shop`. That role registers and deploys the application and binds its roles to anyone, but not
  `ehos.process_owner`, which the administrator binds.
- **`Deployment … failed in shop-try: ProgressDeadlineExceeded: …`, exit 1, after about three
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

Open `https://shop.production.ehos.example.com`: the application's home page, with a link to
**Your access**. That page, `/access`, needs a person: it sends you to EHOS to sign in (at once,
when your browser is signed in to the console already) and back, then shows who EHOS says you are,
each capability the contracts declare, and whether one of your roles grants it. A project made
before `ehos_app` 0.11.0 opens on Phoenix's welcome page instead, with the **Sign in** button at
the top; the next `mix ehos_app.install` replaces that page while nobody changed it. The commands
themselves are, for now, run from the terminal:

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
- **EHOS says no role bound to you there grants anything, at sign-in, or `call` exits 3 saying
  none of your roles is bound in the application:** step 9.
- **`call` exits 3, naming the capability:** your role does not grant it; step 9, with a role whose
  actor may do that. In the example, `flag_entry` is the `auditor`'s, and a `clerk` is refused it.
  The application decides and records that refusal.
- **`call` names a field that is missing or does not fit:** the application says what its command
  takes. `entry_id` is the caller's to give.

`ehosctl audit` lists what EHOS decided, newest first: the invitation, the environment, the
deployment with every capability and role it added, the role binding, and each credential it
issued, with whose it was and what it allowed. It needs `ehos.audit.read` and lists only the
scopes where you hold it: the platform's administrator and the administrator of an application
(step 8) hold it, at the whole platform and in that application. Without it the read is refused,
and the refusal is recorded; `ehosctl activity` lists what was done in your name, and needs no
capability.

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

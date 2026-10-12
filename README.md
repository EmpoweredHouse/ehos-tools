# ehos-tools

The tools for building, running and governing applications on
[EHOS](https://github.com/empoweredhouse/eh-os), EmpoweredHouse's platform for the software a
company runs its business on.

```sh
ehosctl init shop      # a new application, ready for EHOS
ehosctl verify         # check it as CI does, and have EHOS check what it declares
ehosctl deploy shop --env production --image … --manifest …
ehosctl call shop shop.record_entry amount:=100
```

> **Status: in use, early.** `ehosctl` creates, checks, deploys and calls applications, makes the
> server under an installation, and installs and upgrades EHOS on it; TaxVision and AppUnite's equipment were generated
> from the template and run on EHOS. Releases are internal while the repository is private: see
> [Installing `ehosctl`](#installing-ehosctl). What is still open is in
> [docs/spike.md](docs/spike.md).

## What is in it

| Part | What it is | Released as |
| --- | --- | --- |
| [`ehosctl`](packages/ehosctl/README.md) | The command-line tool for EHOS, for a developer and an operator alike: creates an application, checks and deploys it, calls it, manages environments, people and roles, and makes the server an installation runs on. One self-contained binary per platform | `vX.Y.Z`, installed with mise |
| [`ehos_app`](packages/ehos_app/README.md) | The application template: an [Igniter](https://hexdocs.pm/igniter/readme.html) installer that turns a fresh Phoenix project into an EHOS application, and that an application keeps as a dependency, so a later template reaches it by running the installer again | `ehos_app-vX.Y.Z` |
| [`ehos_design`](packages/ehos_design/README.md) | The EmpoweredHouse design system: tokens, fonts and component styles for Tailwind and daisyUI, and LiveView components. The default look of a generated application, and of EHOS's console | `ehos_design-vX.Y.Z` |
| [`ehos_platform`](packages/ehos_platform/README.md) | The code that makes the server under an installation with OpenTofu and installs EHOS on it, shared by `ehosctl`'s platform commands and eh-os's own tooling | `ehos_platform-vX.Y.Z` |
| [`plugins/ehos-app`](plugins/ehos-app) | The Claude Code plugin every generated application enables: skills that plan a change, ship it, and review it through the application's contracts | `ehos-app-vX.Y.Z` |
| [`plugins/ehos-dev`](plugins/ehos-dev) | The Claude Code plugin eh-os, ehos-tools and eh-os-contract share: releasing, running a piece of work through an issue, reviewing before a pull request, writing a decision record | `ehos-dev-vX.Y.Z` |

The two plugins are published from this repository's marketplace,
[`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json). Applications take `ehos-app`
from a marketplace of its own name, [`.claude-plugin/ehos-app.json`](.claude-plugin/ehos-app.json),
so that their pin and the pin of EHOS's own repositories never move one copy back and forth
([T-16](docs/adr/0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md)).

## `ehosctl` at a glance

Every command says what it does with `ehosctl help <command>`; the
[`ehosctl` README](packages/ehosctl/README.md#commands) has all of them. Each belongs to a plane
([eh-os D-87](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0087-ehosctl-is-one-tool-for-the-developer-and-the-operator-with-a-governed-plane-through-the-api-and-a-platform-plane-outside-it.md)):
**governed** commands act as you, through EHOS, which decides and records each request;
**platform** commands act with a cloud account or an SSH key; **local** ones need no EHOS.

| To | Commands |
| --- | --- |
| Create an application | `init` |
| Check it, as CI does | `verify` |
| Sign in to an installation | `login`, `whoami`, `logout`, `installations`, `terminals` |
| Deploy it | `deploy --preview`, `deploy`, `apps show`, `apps register`, `apps review`, `apps activate` |
| Use it | `apps`, `roles`, `call`, `credential` |
| Prepare environments | `env`, `resources` |
| Let people in | `people`, `role-bindings`, `apps sign-in`, `people agree` |
| Read what happened | `audit`, `activity`, `agents` |
| Stay current | `versions`, `changelog` |
| Run the installation's server, and EHOS on it | `doctor`, `server up`, `server tunnel`, `server status`, `server down`, `install`, `upgrade`, `installation` |

## Getting started

You need [mise](https://mise.jdx.dev) and PostgreSQL. You do not need Erlang or Elixir: `ehosctl`
carries its own runtime, and mise installs the project's.

```sh
mise use -g github:EmpoweredHouse/ehos-tools   # while the repository is private: see below
ehosctl init shop
cd shop
mix ecto.setup
mix precommit
```

`init` takes about a minute and a half. It generates the project under the Erlang and Elixir it
pins, makes the first commit, and ends with the next steps. The whole way from here to the
application deployed on EHOS and in use is [the golden path](#the-golden-path), command by command.
After the first deployment, the generated `DEVELOPMENT.md` is the guide: the development cycle,
contract first, running it locally, how CI builds the image, and deploying again. The generated
`README.md` lists the everyday commands.

### Installing `ehosctl`

```sh
mise use -g github:EmpoweredHouse/ehos-tools
```

`ehosctl` is then on your `PATH` if mise is active in your shell (`mise activate`, or its shims
directory on the `PATH`). `ehosctl --help` prints its version and what `init` creates an
application from: the template's version and commit, and the Erlang, Elixir and generators it pins.
The binaries are also attached to each
[release](https://github.com/empoweredhouse/ehos-tools/releases), with a `SHA256SUMS` file to check
them against; to build one from source, see
[packages/ehosctl](packages/ehosctl/README.md#building-the-binary).

#### While the repository is private

mise needs a GitHub token that can read it. It reads one from `GITHUB_TOKEN` or
`MISE_GITHUB_TOKEN`, or from `gh`'s `~/.config/gh/hosts.yml` (`github.gh_cli_tokens`, on by
default). `gh` keeps its token in the system's keyring instead, unless it was signed in with
`--insecure-storage`, and mise does not read the keyring. Without a token, GitHub answers mise with
a 404, as for a repository that does not exist. Prefer a fine-grained token that reads ehos-tools
alone, with *Contents: read* and *Attestations: read*, whose *Resource owner* is EmpoweredHouse:

```sh
MISE_GITHUB_TOKEN=<the fine-grained token> mise use -g github:EmpoweredHouse/ehos-tools
```

`MISE_GITHUB_TOKEN=$(gh auth token)` works too, for the one command. That token can usually write to
every repository you can, so do not export it in a shell profile, where every process you start, a
dependency's build script included, would read it.

There is no Homebrew tap yet: Homebrew downloads a formula's binary without credentials, so it
cannot install from a private repository's releases. The formula waits in
[`packaging/homebrew/`](packaging/homebrew/ehosctl.rb) until the repository is public.

#### Upgrading

After a command, at most once a day, `ehosctl` says when a newer one is released, with the command
that moves to it; `ehosctl versions` prints the same command, and says whether the installation you
use accepts that release:

```sh
mise use -g github:EmpoweredHouse/ehos-tools@<the new version>
```

It names the version on purpose. mise knows the tool as `github:EmpoweredHouse/ehos-tools`, not as
`ehosctl`, so `mise upgrade ehosctl` answers that all tools are up to date; and mise hides a release
younger than its `minimum_release_age` from `mise use` and `mise upgrade` without a version.
`mise ls-remote github:EmpoweredHouse/ehos-tools` then warns that newer releases are hidden.

#### With asdf

If you manage Erlang and Elixir with asdf and never set mise up in the shell, `mise use -g` installs
`ehosctl` and the shell still answers `command not found`. Add mise's shims to the end of the
`PATH`, once, so that asdf's come first for the tools both know. In zsh (`~/.zshrc`) or bash
(`~/.bashrc`, or `~/.bash_profile` on macOS):

```sh
export PATH="$PATH:$HOME/.local/share/mise/shims"
```

In fish: `fish_add_path --path --append ~/.local/share/mise/shims`. `mise doctor` prints the shims
directory yours uses and whether it is on the `PATH`.

With asdf's shims first, `init` still generates under the versions it pins. In the generated
project, though, `mix` and `elixir` are then asdf's, even under `mise exec`. Ask mise to put its
tools first, for one command (`MISE_ACTIVATE_AGGRESSIVE=1 mise exec -- mix ecto.setup`) or for
every `mise exec` in the shell (`export MISE_ACTIVATE_AGGRESSIVE=1`).

#### Ports and the database

A generated project listens on ports 4000 (the endpoint) and 4001 (health), set in
`config/config.exs` to match `ehos.yaml`, and in development uses the database `<name>_dev` at
`postgres:postgres@localhost:5432`. Nothing checks that these are free: another project's
PostgreSQL on 5432 takes the new databases without a word, and a port in use stops
`mix phx.server`. To run two applications side by side, give the second other ports in its
`config/dev.exs` alone; the ports in `ehos.yaml` and `config/config.exs` are what EHOS runs it on.

## The golden path

From an empty machine to an application deployed on EHOS, signed in to and used: one command per
step, what it prints when it works, and what to do when it does not. The examples make an
application `shop` in a repository `EmpoweredHouse/shop`, deployed to the environment
`production` of an installation at `https://ehos.example.com`. The output shown is `ehosctl`
0.6.0's.

A step marked **administrator** needs a role a developer may not hold. If you are not the
installation's administrator, send them the command; if you are, run it yourself.

### 0 · Before you start: an installation, and an account on it

You need the installation's address, an account there, and, when the installation has a
certificate authority of its own (a trial server's does), its CA file:
`~/.ehos/<installation>/ca.crt` on the machine that installed it. A CA certificate is not a secret; ask for it.

- **An account:** the **administrator** invites you in the console's *People*. The installation
  sends no mail yet, so the console shows a one-time sign-in link, valid for 15 minutes, which they
  pass on to you. Open it, and set a password in the console's settings. `ehosctl people invite`
  makes the account too, but never shows the link, since it would sign in whoever reads it.
- **No installation yet:** the same `ehosctl` makes the server and installs EHOS on it.
  eh-os's [INSTALLING.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md)
  walks it, with what each step needs (a cloud account, an SSH key, a state passphrase, a token
  that reads EHOS's images), in about 25 minutes:

  ```sh
  ehosctl doctor              # the tools and the cloud credentials
  ehosctl server up           # the server, on Oracle Cloud unless told otherwise
  ehosctl server tunnel       # its Kubernetes API, on your machine
  GHCR_TOKEN=… ehosctl install
  ```

  `install` ends with the command that invites the first person, the platform's administrator.

### 1 · Install `ehosctl`

```sh
MISE_GITHUB_TOKEN=<a token that reads ehos-tools> mise use -g github:EmpoweredHouse/ehos-tools
ehosctl --version
```

It works when `ehosctl --version` prints the version, `ehosctl 0.6.0` or later. `ehosctl --help`
names the template `init` creates applications from.

- **mise answers 404, or that the tool does not exist:** it has no token that reads the private
  repository. [While the repository is private](#while-the-repository-is-private) says which.
- **`command not found`:** mise is not active in your shell, or asdf's shims hide it.
  [With asdf](#with-asdf).
- **An older version than the newest release:** mise hides a release for a while after it is
  published. Name the version: `mise use -g github:EmpoweredHouse/ehos-tools@0.6.0`
  ([Upgrading](#upgrading)).

### 2 · Generate the application

```sh
ehosctl init shop
cd shop
```

The name is the application's name in EHOS, its domain and its OTP application: lowercase letters,
digits and underscores. The repository may be named otherwise; the image takes the repository's
name, EHOS the application's.

It works when, after about a minute and a half, it ends with `EHOS: the project is ready. Start a
database, then:` and the next steps, and `git log` shows one commit.

- **`shop already exists`:** `init` generates into a directory of its own and runs `git init`
  there; it does not generate into a repository you cloned
  ([#63](https://github.com/EmpoweredHouse/ehos-tools/issues/63)). Generate beside it, then push
  to the empty repository (step 4).
- **`mise does not trust it yet`:** run the `mise trust` it names.
- **It used an older template than you expected:** each `ehosctl` generates the template it pins.
  `ehosctl versions` says whether a newer `ehosctl` is out.

### 3 · The database, and the gates

```sh
# unless a PostgreSQL already listens on 5432:
docker run -d --name shop-postgres -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18
mix ecto.setup
mix precommit
```

It works when `mix precommit` passes every test and ends with
`eh_os_contract.check: 0 errors, 0 warnings, 0 notices`.

- **The databases went somewhere unexpected:** any PostgreSQL on port 5432 that accepts
  `postgres:postgres` takes them, another project's included, without a word
  ([Ports and the database](#ports-and-the-database)).
- **mix asks "Shall I install Hex?", or names another Elixir:** asdf's `mix` ran, not mise's. Run
  `MISE_ACTIVATE_AGGRESSIVE=1 mise exec -- mix precommit` ([With asdf](#with-asdf)).

### 4 · The repository, and CI

```sh
gh repo create EmpoweredHouse/shop --private --source .
gh secret set EHOS_CI_APP_ID --body <the App's ID>
gh secret set EHOS_CI_APP_PRIVATE_KEY < <the App's private key>.pem
git push -u origin main
gh run watch
```

For a repository that already exists and is empty, `git remote add origin
https://github.com/EmpoweredHouse/shop.git` instead of `gh repo create`. The App's ID and private
key are EmpoweredHouse's: an organisation owner has them
([The generated project's CI](#the-generated-projects-ci)).

It works when the run on `main` passes every job (`check`, `image` for each architecture, and
`publish`) and has the artifact `ehos-deployment`: the image's name with its digest, and the
manifest. About five to seven minutes, most of it building the image.

- **The first job fails at once, naming `EHOS_CI_APP_ID` and `EHOS_CI_APP_PRIVATE_KEY`:** the
  secrets are not set. Set them, then `gh run rerun <the run> --failed`.
- **The run built no image:** it ran on a pull request, or on a branch other than `main`. Only a
  push to `main` publishes the artifact; `git branch -M main` renames a first branch that
  `git init` called `master`, as git does on most Linux distributions
  ([#190](https://github.com/EmpoweredHouse/ehos-tools/issues/190)).

### 5 · Sign in

```sh
EHOSCTL_CA_FILE=<the installation's ca.crt> ehosctl login https://ehos.example.com
ehosctl whoami
```

Your browser opens EHOS's log-in page, where you type your password; `ehosctl` never sees it.
`EHOSCTL_CA_FILE` is needed once, at `login`, and only for an installation with a CA of its own:
`login` keeps the CA, and `ehosctl installations list` shows `own` in its CA column.

It works when `whoami` prints `You are you@example.com, signed in to <the installation>
(https://ehos.example.com) until <a week from now>.`

- **The handshake fails, or `ehosctl` asks for `EHOSCTL_CA_FILE`:** the installation's CA is not
  trusted. Sign in again with the variable. An installation added by an `ehosctl` older than 0.5.0
  kept no CA: its column says `system`, and the same `login` fixes it.
- **A forgotten password:** ask the **administrator** to invite you again (step 0). Open the link in
  a private window, so it is not mixed up with a `login` you left unfinished, set a new password in
  the console's settings, then `ehosctl login` again.

### 6 · Have EHOS check the application

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

### 7 · The environment and its database

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

### 8 · Deploy

```sh
gh run download "$(gh run list -b main -s success -L 1 --json databaseId --jq '.[0].databaseId')" \
  -n ehos-deployment -D _build/deploy
ehosctl deploy shop --env production --manifest _build/deploy/ehos.manifest.json --preview
ehosctl deploy shop --env production \
  --image "$(cat _build/deploy/image)" --manifest _build/deploy/ehos.manifest.json
```

`--preview` deploys nothing. It shows what the deployment would do and every reason EHOS would
refuse it, and exits 1 when it would be refused:

```text
What deploying shop to production would do; nothing was deployed.
  …
 NEEDS     ASKS FOR        BOUND TO
 database  postgres >= 16  shared, PostgreSQL 18, schema ehos_shop_production

To deploy it, run the command again without --preview, naming the image with --image.
```

The first deployment of an application also registers it: what its roles grant is shown, and it
needs `ehos.application.register` besides `ehos.application.deploy`. `deploy` then waits, for at
most ten minutes, while EHOS makes the application's schema and roles, runs its migrations and
starts it. It works when it ends like this and exits 0:

```text
Waiting until it is active, for at most 10 minutes:
  activating
  active
Deployment 5f0c… is active in production, at https://shop.production.ehos.example.com.
```

- **`production has no resource bound for a postgres database`:** step 7.
- **A refusal for a capability you do not hold** (`ehos.application.deploy`, or
  `ehos.application.register` the first time): the **administrator** deploys it, or binds you
  `ehos.application_administrator`, which holds both and lets you bind the application's roles.
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

### 9 · Let people in

```sh
ehosctl role-bindings bind shop.clerk --to you@example.com --app shop --env production
ehosctl roles
```

Nobody can use the application until a role of it is bound to them, the platform's administrator
included. A role is the application's name and an actor of its domain (`lib/shop/domain.ex`); the
template's example has `clerk` and `auditor`. Binding a role to someone needs the right to manage
role bindings there, which the **administrator** has.

It works when `ehosctl roles` lists `shop.clerk` held by you in `shop`, `production`.

- **Refused for its scope:** an application's role is bound in one of its environments, so it
  takes both `--app` and `--env`.

### 10 · Use it

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
  event: shop.entries.recorded at position 1
```

- **The browser warns that the connection is not private:** it does not trust the installation's
  CA. Add the CA file to your system's trusted certificates, or accept the warning.
- **The page says no role bound to you grants anything, or `call` exits 3 naming the capability:**
  step 9, with a role whose actor may do that. In the example, `flag_entry` is the `auditor`'s.
- **`call` names a field that is missing or does not fit:** the application says what its command
  takes. `entry_id` is the caller's to give.

### 11 · Later

```sh
ehosctl versions
```

It says, for `ehosctl`, EHOS, `ehos_app`, `eh_os_contract` and `ehos_design`, the version in use,
the newest, whether the installation accepts it, and the command that moves to it. `ehosctl` also
says so after a command, at most once a day.

- **A new `ehosctl`:** the `mise use -g …@<version>` it prints ([Upgrading](#upgrading)).
- **A new template:** move `ehos_app` in `mix.exs` as `versions` prints it, then `mix deps.get`,
  `mix ehos_app.install` and `mix precommit`
  ([packages/ehos_app](packages/ehos_app/README.md)). Its changelog says what a project made
  before a release must change by hand.
- **A change to the application:** merged to `main`, it is built by CI, and deployed as in step 8,
  over the version before; its data is kept. The generated `DEVELOPMENT.md` has the rest: the
  contract first, migrations that take two deploys, building the image yourself.

## What a generated application gets

`ehosctl init shop` creates `shop/`, a Phoenix 1.8 application with PostgreSQL, plus:

```text
shop/
├── ehos.yaml                         what the application needs from EHOS, as ehos.yaml/v3
├── lib/shop/domain.ex                the domain: its words, contexts and actors, named as EHOS names the application
├── lib/shop/contracts/               a contract per business process, beside the rules for writing one
├── lib/shop/application.ex           Repo → Oban → EhOsContract → EhOsContract.Auth → Health → SignIn → Endpoint
├── lib/shop_web/health.ex            /health/live and /health/ready, on port 4001, which EHOS probes
├── lib/shop_web/…                    sign-in through EHOS, and the routes to the contracts behind a credential check
├── config/runtime.exs                the variables EHOS gives the application at start, and nothing else
├── assets/                           Phoenix's assets, styled by the ehos_design dependency
├── README.md, DEVELOPMENT.md         the quick start and everyday commands; the cycle, contract first, and deploying
├── VISION.md, ARCHITECTURE.md, TESTING.md   what it is for, how it is built, how it is tested
├── AGENTS.md, CLAUDE.md              the rules for coding agents, with nested ones for the contracts and the web layer
├── .claude/settings.json             enables the ehos-app plugin: /ehos-app:plan, :ship, :review, …
├── .github/workflows/ci.yml          ehosctl verify, then the image by digest beside the manifest
├── Dockerfile, rel/                  a release, built with a GitHub token as a build secret
├── test/harness_test.exs             keeps the docs honest: links, line budgets, no ADRs
├── .tool-versions                    the Erlang and Elixir everything was built with
└── LICENSE                           Apache-2.0, the application's to change
```

The sections between `<!-- ehos_app:… -->` markers are the template's, and running a later
installer rewrites them; everything else is the application's
([packages/ehos_app](packages/ehos_app/README.md#what-the-installer-does)).

## Platforms

| Platform | Status |
| --- | --- |
| macOS, Apple silicon (arm64) | Supported. Tested end to end by hand; CI's end-to-end job runs on `macos-15` |
| macOS, Intel (x64) | Supported. CI's end-to-end job runs on `macos-15-intel`, the last Intel image GitHub offers, which it retires in August 2027 |
| Linux, x64 and arm64 | Supported. Tested end to end in an Ubuntu 24.04 arm64 container; CI's end-to-end jobs run on Ubuntu 24.04, x64 and arm64. Other distributions work, but Erlang may be compiled from source: see [Linux](packages/ehosctl/README.md#linux) |
| Windows | Not supported. [WSL 2](https://learn.microsoft.com/windows/wsl/) with the Linux binary is the route to try; it is not tested. Why, and what support would take: [Windows](packages/ehosctl/README.md#windows) |

## The generated project's CI

`.github/workflows/ci.yml` reads `eh_os_contract` and `ehos_design` from private repositories,
through the GitHub App *ehos-tools CI*, installed on eh-os-contract and ehos-tools with read access
to their contents and attestations. It checks the project with `ehosctl verify`, which mise
installs from ehos-tools' releases with a token of the same App, and runs only once its SHA-256 is
the one the workflow pins. Until a new repository has the App's ID and private key as the secrets
`EHOS_CI_APP_ID` and `EHOS_CI_APP_PRIVATE_KEY`, its first job fails at once and says so. The ID and
key are EmpoweredHouse's, from an organisation owner:

```sh
gh secret set EHOS_CI_APP_ID --body <the App's ID>
gh secret set EHOS_CI_APP_PRIVATE_KEY < <the App's private key>.pem
```

On `main`, the workflow builds the image for amd64 and arm64, pushes it to `ghcr.io` by digest, and
publishes it beside the manifest as the artifact `ehos-deployment`, which `ehosctl deploy` takes.
Once both repositories are public, the token step and the secrets go.

## How it works

```mermaid
flowchart LR
  A["ehosctl init shop"] --> B["mise exec<br/>pinned Erlang + Elixir"]
  B --> C["mix igniter.new<br/>--with phx.new"]
  C --> D["phx.new<br/>Phoenix + Postgres"]
  C --> E["mix ehos_app.install"]
  E --> F["oban.install"]
  E --> G["eh_os_contract, ehos_design<br/>config · migrations · children"]
  E --> H["ehos.yaml · docs · CI<br/>Dockerfile · plugin settings"]
```

Each `ehosctl` release pins one template, in
[`template.ex`](packages/ehosctl/lib/ehosctl/template.ex): the Erlang and Elixir versions, the
`phx_new` and `igniter_new` archives, and the `ehos_app` version. A given version of the tool
always generates the same project, whichever machine runs it, as `phx_new` does.

Four rules the design keeps:

- **Standard tools, composed.** Phoenix generates the application and Igniter patches it. Oban
  installs itself through its own installer. Burrito packages the CLI and mise provides the
  toolchain. The code in this repository is only what is specific to EHOS.
- **One toolchain from laptop to image.** The versions `init` runs under are the ones it writes into
  `.tool-versions`, and the ones the generated Dockerfile builds with.
- **Nothing global changes.** The generator's archives live in a directory owned by `ehosctl`, and
  the toolchain in mise's. Your own `~/.mix` and your version manager's defaults are left alone.
- **Idempotent and upgradable.** Running the installer twice changes nothing, and a test pins that.
  A later template reaches an existing project by moving its `ehos_app` dependency and running
  `mix ehos_app.install` again
  ([T-02](docs/adr/0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md)).

Why this stack and not another is in [docs/research.md](docs/research.md), and every decision since
in [docs/adr/](docs/adr/README.md).

## Repository layout

| Path | What |
| --- | --- |
| [`packages/ehosctl/`](packages/ehosctl/README.md) | The CLI, one self-contained binary per platform |
| [`packages/ehos_app/`](packages/ehos_app/README.md) | The template, as `mix ehos_app.install` |
| [`packages/ehos_design/`](packages/ehos_design/README.md) | The design system |
| [`packages/ehos_platform/`](packages/ehos_platform/README.md) | Making the server and installing EHOS on it |
| [`packages/review/`](packages/review/README.md) | The review gate for this repository's own pull requests; never released |
| [`plugins/`](plugins), [`.claude-plugin/`](.claude-plugin/marketplace.json) | The Claude Code plugins, and the marketplace that publishes them |
| [`packaging/homebrew/`](packaging/homebrew/ehosctl.rb) | The draft Homebrew formula, for a `homebrew-tap` repository |
| [`docs/adr/`](docs/adr/README.md) | This repository's decision records, `T-xx` |
| [`docs/research.md`](docs/research.md) | The options considered for building, installing and pinning, and the choice for each |
| [`docs/spike.md`](docs/spike.md) | What was built and measured, and what is still open |

Each package is its own Mix project, with its own version and changelog, released separately as a
GitHub release whose notes are its changelog's section; only `ehosctl`'s is marked latest, since
mise installs that one ([releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)).
A new `ehos_app` reaches new applications through a release of `ehosctl` that pins it, and existing
ones when they move their dependency to it.

## Development

```sh
cd packages/<package> && mix check
```

`mix check` is each package's gate: formatting, compilation with warnings as errors, and the tests.
CI runs it for every package a pull request touches and, for a release, cross-builds the four
binaries on Linux and generates a project with each of them on its own platform
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)). How code, tests, commits and releases are
expected to look is in [CONTRIBUTING.md](CONTRIBUTING.md); coding agents start at
[AGENTS.md](AGENTS.md).

## Related projects

- [EHOS](https://github.com/empoweredhouse/eh-os) is the platform, and holds the specification:
  what an application must be, `ehos.yaml`, and the API `ehosctl` speaks.
- [eh-os-contract](https://github.com/empoweredhouse/eh-os-contract) is the contract engine every
  generated application depends on.

## License

ehos-tools is licensed under the [Apache License 2.0](LICENSE), as eh-os-contract is. Two parts
keep the terms they came with: the fonts in `packages/ehos_design` are under the SIL Open Font
License 1.1, whose texts are beside them, and the `elixir-anti-patterns-review` skill keeps its
own Apache-2.0 license and the Elixir Team's notices. An application `ehosctl init` generates gets
a `LICENSE` of its own, Apache-2.0, which is the application's to change.

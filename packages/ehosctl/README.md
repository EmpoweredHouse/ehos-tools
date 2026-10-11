# ehosctl

The command-line tool for [EHOS](https://github.com/empoweredhouse/eh-os).

`ehosctl` will be to EHOS what `gcloud` is to a cloud: one way in from the terminal, through the
same API and the same authorization as the console. Its first command needs no EHOS at all. It
creates a new application:

```sh
ehosctl init shop
```

It signs you in to an installation of EHOS from the terminal (`login`, `whoami`, `logout`), says
which roles you hold and which applications you may use (`roles`, `apps`), and calls those
applications as you (`call`, `credential`), and checks an application as its CI does (`verify`).
The other commands that talk to EHOS arrive as EHOS defines the API behind them, in Stage 7 of its
[roadmap](https://github.com/empoweredhouse/eh-os/blob/main/docs/ROADMAP.md).

## Installing

`ehosctl` is a single binary that carries its own Erlang runtime, so it needs nothing installed to
run. It does need [mise](https://mise.jdx.dev/installing-mise.html), which `init` uses to provide
the generated project's toolchain, and `verify` to run an application under its own. It runs on
macOS and Linux, on arm64 and x64. Windows is not supported: see [Windows](#windows).

There are two ways to install it:

- **With mise**, on macOS and Linux. mise picks the binary for the machine from the release:

  ```sh
  mise use -g github:EmpoweredHouse/ehos-tools
  ```

  It is on your `PATH` if mise is active in your shell (`mise activate`, or its shims directory on
  the `PATH`). With asdf and no mise in the shell, `ehosctl` is installed and still not found: add
  mise's shims directory to the end of the `PATH`, after asdf's shims. `mise doctor` prints it
  (`shims:`, `~/.local/share/mise/shims` by default) and whether it is on the `PATH`
  (`shims_on_path`). The root README gives the line for zsh, bash and fish.

  While the repository is private, mise needs a token that can read it, in `GITHUB_TOKEN`,
  `MISE_GITHUB_TOKEN` or `gh`'s `hosts.yml`; without one, GitHub answers with a 404. `gh` keeps
  its token in the system's keyring unless signed in with `--insecure-storage`, and mise does not
  read the keyring. Prefer a fine-grained token that reads ehos-tools alone, with
  *Contents: read* and, since mise 2026.10 reads the release's attestations with it,
  *Attestations: read*, and EmpoweredHouse as its *Resource owner*.
  `MISE_GITHUB_TOKEN=$(gh auth token)` works for the one command, but that token can usually write
  to every repository you can: do not export it in a shell profile.

- **By hand.** Download `ehosctl_<target>` for your platform from the
  [release](https://github.com/empoweredhouse/ehos-tools/releases), check it against the release's
  `SHA256SUMS` (`sha256sum --check --ignore-missing SHA256SUMS`, or
  `shasum -a 256 --check --ignore-missing SHA256SUMS` on macOS), make it executable and put it on
  your `PATH` as `ehosctl`.

Homebrew is not one of them yet: it downloads a formula's binary without credentials, so it cannot
install from this private repository's releases. The formula, `packaging/homebrew/ehosctl.rb`,
waits until the repository is public.

| Target | Platform |
| --- | --- |
| `macos_arm64` | macOS on Apple silicon |
| `macos_x64` | macOS on Intel |
| `linux_arm64` | Linux on arm64 |
| `linux_x64` | Linux on x86_64 |

To run the code of a branch instead, [build it from source](#building-the-binary).

## Commands

| Command | Plane | What it does |
| --- | --- | --- |
| `ehosctl init <name>` | local | Creates the application `<name>` in the directory `./<name>` |
| `ehosctl installations list` | local | Lists the installations you know, marking the current one |
| `ehosctl installations use <name>` | local | Makes an installation the current one |
| `ehosctl installations remove <name>` | local | Forgets an installation, leaving its sign-in: run `logout` first |
| `ehosctl login [<url>]` | governed | Signs you in to an installation through your browser, adding it if it is new |
| `ehosctl whoami` | governed | Says who you are signed in as, to which installation, and until when |
| `ehosctl logout` | governed | Ends your sign-in at EHOS, and forgets it on this machine |
| `ehosctl terminals` | governed | Lists your terminals signed in with `login`: when each signed in, was last used and ends, marking this one |
| `ehosctl terminals sign-out <id>` | governed | Signs one of your terminals out, a lost laptop's for one |
| `ehosctl roles [--app A] [--env E]` | governed | Lists the roles you and your agents hold, where, and which grant nothing |
| `ehosctl apps` | governed | Lists the applications you may use, in each environment: their address and what your roles grant there |
| `ehosctl apps register \| show \| review \| activate` | governed | Registers an application's manifest as a version, lists its versions, and reviews and activates one in an environment |
| `ehosctl apps sign-in list \| agree \| withdraw` | governed | Lists the applications whose pages ask for credentials for an application in an environment, and agrees to or withdraws one |
| `ehosctl call <app> <capability> [fields]` | governed | Runs a command, records something or asks a query in an application, as you |
| `ehosctl credential <app>` | governed | Prints a credential for an application, for a script or `curl` |
| `ehosctl people list \| show \| invite \| rename \| disable \| enable \| sign-out` | governed | Lists the company's people, invites, renames, disables and enables them, and signs out every terminal of one |
| `ehosctl people agreements \| agree \| withdraw` | governed | Lists the applications that ask to read the people, and agrees to or withdraws one in an environment |
| `ehosctl deploy <app> --env E --image I --manifest F` | governed | Deploys an image, by digest, with its manifest, to an environment |
| `ehosctl deploy <app> --env E --manifest F --preview` | governed | Prints what deploying a manifest would do, and every reason it would be refused, and deploys nothing |
| `ehosctl env list \| show \| create \| remove \| bind \| unbind` | governed | Lists, creates and removes environments, and binds resources in them |
| `ehosctl resources list \| classify` | governed | Lists the resources environments may bind, and sets whether each serves production |
| `ehosctl role-bindings list \| bind \| unbind` | governed | Lists the role bindings where you manage them, and binds and removes roles |
| `ehosctl audit [--limit N]` | governed | Lists the audit record's newest decisions where you may read it |
| `ehosctl activity [--limit N]` | governed | Lists the decisions made in your name or your agents' |
| `ehosctl agents list \| create <name>` | governed | Lists your agents, and creates one |
| `ehosctl verify [--no-test]` | governed | Checks the application in this directory as its CI does, then asks EHOS to check its `ehos.yaml` and manifest when you are signed in |
| `ehosctl installation` | governed | Shows where the installation runs, and what its nodes, environments and applications use now |
| `ehosctl versions` | governed | Shows each EHOS component in use, the newest release, whether the installation accepts each, and the command that moves to it |
| `ehosctl changelog <component> [--since V] [--web]` | governed | Prints what changed in a component's releases newer than the version in use |
| `ehosctl --version` | | Prints the version, and for a build between releases the commit it was built from |
| `ehosctl --help` | | Prints the version, the commands, and what `init` creates an application from: the template (`ehos_app`'s version and commit), Erlang, Elixir, `phx_new` and `igniter_new`, and the contract engine's release that template pins |

Every command's help comes from its declaration ([T-06](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0006-ehosctl-reads-its-command-line-with-optimus-and-writes-to-the-terminal-with-owl.md)),
and is asked for in any of these ways: `ehosctl help init`, `ehosctl init --help`,
`ehosctl init -h`. It ends with the command's plane, as
[eh-os D-87](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0087-ehosctl-is-one-tool-for-the-developer-and-the-operator-with-a-governed-plane-through-the-api-and-a-platform-plane-outside-it.md)
requires of every command:

- **governed**: acts as you, through EHOS, which decides and records every request. These take
  `--installation` (below).
- **platform**: acts with an account EHOS does not issue: a cloud provider's, an SSH key, or a
  kubeconfig.
- **local**: works on this machine alone, and needs no EHOS.

### Output and exit codes

A command prints words for a person on stdout. One that takes `--json` prints one JSON document
there instead, for a script; a command without it refuses `--json` as an invalid command line.
Errors go to stderr: one line, `ehosctl: …`, or under `--json` one JSON object,
`{"error": {"kind": "invalid", "message": "…"}}`.

The exit code says what kind of error it was, and a kind keeps its code from one version to the
next:

| Code | Kind | Meaning |
| --- | --- | --- |
| 0 | | Done |
| 1 | `failed` | The command failed for a reason of its own, which it names. Also what the request names does not exist, conflicts with what is there now, or was erased, or the installation's EHOS is too old to have the command's route |
| 2 | `invalid` | The command line is not one `ehosctl` accepts: an unknown command, option or name, or fields an application says do not fit |
| 3 | `refused` | EHOS or the application refused the request: none of your roles grants it |
| 4 | `not_signed_in` | Not signed in, or the sign-in has expired or ended, or the credential was not accepted: run `ehosctl login`. Also when no installation is current, or the one named is unknown |
| 5 | `unreachable` | The installation or the application did not answer, or asked to be tried again later |

A refusal is said in the words the console uses, eh-os's
[`docs/refusals.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/refusals.md), and its
kind there gives the code: Refused is 3, Not signed in and Not accepted are 4, Invalid is 2,
Unavailable is 5, and Not found, Conflict and Gone are 1.

Every call to EHOS goes to its versioned API, `/api/v1` (eh-os
[D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md)).
When an installation answers that it has no such route, `ehosctl` reads the routes it lists at
`GET /api/v1` and says that its EHOS, at the version it names, is too old for the command, and
that the operator upgrades EHOS, instead of a bare 404; it exits 1. An installation without
`/api/v1` at all is said to be older than this `ehosctl`.

`init` is the exception: when one of its steps fails, it exits with that step's own exit code. It
also says what is left behind: a half-generated directory to remove before trying again, or, when
the project was already generated, the one setup step to finish by hand.

### Installations

The installations of EHOS you know are kept under names you give them, one of them current, as
kubectl keeps its contexts
([T-07](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md)).
A governed command talks to the one `--installation <name>` names, else the one
`EHOSCTL_INSTALLATION` names, else the current one.

They are kept in `config.json`, in `$EHOSCTL_CONFIG_DIR`, else `$XDG_CONFIG_HOME/ehosctl`, else
`~/.config/ehosctl`, on macOS too. The file holds no secret:

```json
{
  "version": 1,
  "current": "staging",
  "installations": {
    "local": {"url": "https://ehos.localhost"},
    "staging": {"url": "https://ehos.staging.example.com"}
  }
}
```

`ehosctl` writes it whole and renames it into place, creates its directory readable only by you,
and refuses a directory others can write to. A `config.json` that is a link, as a dotfiles manager
makes it, is rewritten through the link.

`ehosctl login <url>` adds an installation, and `ehosctl login` signs in to one again.

### Signing in

`ehosctl login https://ehos.example.com` opens your browser at EHOS's log-in page, where you type
your password; `ehosctl` never sees it
([eh-os D-89](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0089-ehosctl-signs-a-person-in-as-a-public-client-through-a-loopback-redirect-and-gets-each-credential-by-renewal.md)).
The browser comes back to `ehosctl` on `127.0.0.1`, on a port it picks. If the browser does not
open, `ehosctl` prints the address to open by hand. On a machine you reach over SSH, forward that
port, or sign in on your own machine.

- **The address** is an origin: `https://` and a host, with a port if it needs one, and nothing
  after it. EHOS signs no one in over plain HTTP, so neither does `ehosctl`.
- **A local EHOS** has a certificate from a CA of its own, which your system does not trust: for
  the k3d cluster at `https://ehos.localhost`, its `_build/k3d/ca.crt`. Name it in
  `EHOSCTL_CA_FILE`, a PEM file of CA certificates `ehosctl` trusts besides the system's, as
  `curl --cacert` does:

  ```sh
  EHOSCTL_CA_FILE=<path to eh-os>/_build/k3d/ca.crt ehosctl login https://ehos.localhost
  ```

  Every command that talks to EHOS needs it, so export it for as long as you use that
  installation.
- **The installation** is kept under `--installation <name>`, or under a name made from the host:
  `ehos.staging.example.com` is `staging`, and this machine is `local`. It becomes the current
  one. `ehosctl login` with no address signs in again to the current installation, or to the one
  `--installation` names.
- **How long it lasts.** Seven days from when you typed your password, or three days without a
  command that renews it, whichever comes first. EHOS can end it sooner: when you change your
  password, when someone disables your account, or when the terminal is signed out from the
  console, with `ehosctl terminals sign-out` or by a people manager. `ehosctl whoami` says until
  when.
- **Where it is kept**
  ([T-08](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0008-ehosctl-keeps-a-sign-in-s-refresh-token-in-the-system-s-keychain-else-a-file-only-the-user-reads-and-renews-under-a-lock.md)).
  The refresh token goes in the system's keychain: Keychain on macOS, the Secret Service on Linux
  (it needs `secret-tool`, from `libsecret-tools`). Without one, it goes in a file only you can
  read, and `login` says so. `EHOSCTL_TOKEN_STORE=file` chooses the file. Beside it, in
  `$EHOSCTL_STATE_DIR`, else `$XDG_STATE_HOME/ehosctl`, else `~/.local/state/ehosctl`, are the
  ten-minute credentials it renews, each kept until it expires, the two endpoints a renewal and
  `logout` post to, so they read EHOS's discovery document only when those move, and a lock that
  keeps two commands from renewing at once. Who you are and until when is in `config.json`,
  beside the installation.
- **`ehosctl logout`** ends the sign-in at EHOS, then forgets it here. When EHOS does not answer,
  it forgets the sign-in all the same, and says that EHOS was not told. It signs out neither your
  browser, a sign-in of its own, nor your other terminals.
- **`ehosctl terminals`** lists every terminal you are signed in on, newest first, as your
  settings in the console do: when each signed in, when it last renewed, and when it ends at the
  latest, in UTC, with its id in full. It does not say which is the one this `ehosctl` runs on:
  EHOS does not say which sign-in a credential belongs to. `--json` gives
  `{"terminals": [...]}`, each with EHOS's four fields.
- **`ehosctl terminals sign-out <id>`** signs one of them out, as the console does: it can no
  longer renew, so its commands stop within ten minutes. EHOS records it. A terminal that has ended
  or is not yours is "signed out already", exit 1, and not recorded. To sign out every one of your
  terminals, sign out each; `ehosctl logout` signs out only the one it runs on.

### Your roles and applications

`ehosctl roles` lists the roles bound to you and to your agents, as the console's My roles does
([eh-os `docs/terminal-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/terminal-api.md)).
A role bound across every application or environment shows `(all)`. One that is `gone` grants
nothing, since the version in force no longer has it, and one `beyond its owner` grants an agent
only what you hold there yourself. `--app` and `--env` keep the roles that hold there.

`ehosctl apps` lists each application and environment where one of your roles is bound: its
address, your roles, and the commands, queries and recordings they grant you there. An entry that
grants nothing is listed too.

### Calling an application

```sh
ehosctl call ledger ledger.record_entry amount:=100 note="Rent, October"
ehosctl call ledger ledger.balance account=a-1 --env production
curl -H "Authorization: Bearer $(ehosctl credential ledger)" \
  https://ledger.staging.example.com/api/queries/ledger.balance
```

`call` does one thing in an application, as you, through the routes every application built on
`eh_os_contract` serves
([T-10](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0010-ehosctl-call-reaches-an-application-through-eh-os-contract-s-routes-found-through-ehos-s-api.md)).
`ehosctl apps` says what each capability is: a command and a recording are sent as `POST` with the
fields as a JSON object, a query as `GET` with them in the URL.

- **Fields** are written as HTTPie writes them: `name=text` is text, and `name:=<JSON>` is a JSON
  value: `amount:=100`, `paid:=true`, `tags:='["a","b"]'`. `--data` gives a JSON object to start
  from, inline, as `@file.json`, or as `-` for stdin, and the fields go over it. A query takes a
  field given more than once as a list. `ehosctl` does not check the fields against the
  application's declaration: the application does, and says which field does not fit.
- **A capability of a kind** this version of `ehosctl` does not know (one a later EHOS adds) is
  listed by `apps` as needing a later `ehosctl`, and `call` refuses it with exit 1.
- **A capability none of your roles grants** there is still asked for, so that the refusal is
  decided and recorded where it belongs
  ([T-12](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0012-ehosctl-call-asks-for-a-capability-no-role-grants-so-its-refusal-is-decided-and-recorded.md)):
  EHOS refuses a credential where your roles grant nothing, and the application refuses one without
  the capability (exit 3 either way). Since `ehosctl` cannot know the kind of what it was not
  granted, it sends it as a command, then as a recording, each with your fields in its body, then
  as a query without them, until the application finds it; a kind your fields cannot make is left
  out. Only an application where none of your roles is bound is refused without asking, since its
  address is not known.
- **`--env`** may be left out when your roles are bound in only one environment of the
  application. Otherwise it is required, and `ehosctl` names the environments.
- **The idempotency key.** Every command and recording carries a new `idempotency-key`, which an
  application needs for a command that creates something. `--idempotency-key <key>` gives your
  own instead: sending the same call again with the same key has it done once. When a command
  may have been done without `ehosctl` hearing so (the connection broke after the request was
  sent, or a gateway answered 5xx for the application), `ehosctl` says so and names the key it
  sent. A key that is not printable ASCII of at most 255 bytes is refused before anything is sent.
- **The credential** is the application's own, renewed from your sign-in with the application's
  address as `resource`
  ([eh-os D-89](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0089-ehosctl-signs-a-person-in-as-a-public-client-through-a-loopback-redirect-and-gets-each-credential-by-renewal.md))
  and kept for its ten minutes. `ehosctl credential <app>` prints it, for a script or `curl`; it
  never prints the refresh token. Where none of your roles grants anything, EHOS issues none, and
  `ehosctl` exits 3.

With `--json`, `call` prints the application's answer as it came: a command's receipt, or a
query's `rows` or `row`.

### Managing people

```sh
ehosctl people list --state invited,joined,disabled --q ada
ehosctl people show ada@example.com
ehosctl people invite alan@example.com --name "Alan Turing"
ehosctl people rename ada@example.com "Ada Lovelace"
ehosctl people disable 6f1c…
ehosctl people sign-out ada@example.com
```

`people` does what the console's people page does, through EHOS's API
([eh-os `docs/people-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/people-api.md)).
`list` and `show` need `ehos.people.read`; `invite`, `rename`, `disable`, `enable` and `sign-out`
need `ehos.people.manage`. EHOS records every one of them, as it records the console's.

- **A person** is named by their id or their email; a word with an `@` is an email, looked up
  with `list`'s `--q`. `show` finds an email among the invited and the joined only, since listing
  the disabled needs `ehos.people.manage`: show a disabled person by their id.
- **`list`** follows every page EHOS gives, ordered by email. `--limit N` stops after `N` people
  and says when more match; under `--json`, `{"people": [...], "more": true}`. `--state` defaults
  to `invited,joined`.
- **`invite`** says whether the sign-in link was mailed. It never prints a link: the API never
  gives one, since it would sign in whoever reads it as that person
  ([eh-os D-80](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0080-ehos-s-api-lists-people-to-ehos-people-read-and-manages-them-for-ehos-people-manage.md)).
  Without mail, a people manager hands one over by inviting them again in the console.
- **`sign-out`** signs out every terminal of a person, without disabling them, as the people page
  does when a laptop is lost: their terminals can no longer renew, so their commands stop within
  ten minutes, and a sign-in they began a moment before cannot finish. It says how many were
  signed in, which may be none; under `--json`, `{"signed_out": <count>}`. It needs
  `ehos.people.manage` even for yourself: your own terminals you sign out with `ehosctl terminals
  sign-out`.
- **`rename`** with an empty name, `""`, removes it. An email is changed only by its owner, in the
  console.
- **No command sets or resets a password.**

### Agreements

```sh
ehosctl apps sign-in list tax --env production
ehosctl apps sign-in agree tax ledger --env production
ehosctl apps sign-in withdraw tax ledger --env production
ehosctl people agreements
ehosctl people agree ledger --env production
ehosctl people withdraw ledger --env production
```

Two things EHOS gives an application only once someone agrees, as the console agrees to them,
through EHOS's API
([eh-os `docs/agreements-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/agreements-api.md)).
EHOS records every agreement and withdrawal, and every refusal of one, as it records the
console's.

- **Sign-in** (eh-os D-70): another application's pages getting credentials for an application in
  an environment, as the application's environment tab agrees. `apps sign-in list <app>` lists the
  applications whose pages ask for credentials for it there, and those agreed to;
  `agree <app> <client>` lets the pages of `<client>` get them, and `withdraw` stops it at their
  next sign-in or renewal, while a credential already issued lives out its ten minutes. Agreeing
  and withdrawing need `ehos.application.deploy` for the application there; listing needs that or
  `ehos.application.register`.
- **The people** (eh-os D-81): an application's workload reading the company's people in an
  environment, as the people page agrees. `people agreements` lists every application that asks,
  and those agreed to; `people agree <app>` lets it read them there, and `people withdraw <app>`
  refuses its next reading. Each needs `ehos.people.manage`.
- **The state** is the console's: `asks`, `agreed`, or `agreed, no longer asked` for an agreement
  that outlasted the deployment that asked for it, and holds for a later one that asks again until
  it is withdrawn. Under `--json`, each request's `asks`, `agreed`, `agreed_at` and `by`, with
  `client` for sign-in and `application` and `environment` for the people.
- **Refusals** are EHOS's sentences: 403 when you may not (exit 3), and exit 1 when the
  application's deployment there no longer asks (`not_requested`), or when there is no agreement
  to withdraw. An application or environment that is none is exit 1 for the people. For sign-in it
  is exit 1 only for someone who may deploy across the platform; anyone else is refused as for one
  that exists, exit 3, so a name is not learnt by trying it.

### Deploying

```sh
ehosctl deploy ledger --env staging \
  --image ghcr.io/example/ledger@sha256:<digest> --manifest manifest.json
```

`deploy` does what the console's Deploy does: one decision that puts the manifest in force in the
environment and gives the cluster the image
([eh-os `docs/manifest.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/manifest.md#deploying-with-one)).
It needs `ehos.application.deploy` there, and `ehos.application.register` too when the manifest
changes the application's authority.

- **The manifest** is sent as its file holds it, byte for byte, since EHOS keeps and digests what
  it was sent; `--manifest -` reads it from stdin. It must be the manifest of the application the
  command names, or nothing is sent.
- **The image** is named by digest; a tag is refused.
- **The answer** comes once the cluster has the deployment's objects, while it is `activating`:
  the deployment's id, the image and both of the manifest's digests. Whether it became active is
  on the application's page in the console. A deployment the cluster did not take exits 5 with
  its failure; one a later deployment overtook exits 1. Both name the deployment.
- **A refusal** is the deploy page's sentence: a database the environment keeps that the manifest
  drops, for one, is `database_kept`, and exits 1.

```sh
ehosctl deploy ledger --env staging --manifest manifest.json --preview
```

`--preview` deploys nothing: it prints what the deployment would do, as the console's deploy page
shows it before it is confirmed. That is both of the manifest's digests and the version in force;
that EHOS does not know the application yet, when the deployment would register it; what its
authority adds and takes away, in `apps review`'s words, or that it changes no one's; that it
also needs `ehos.application.register`, when you hold it; what each need would be bound to, or
why it cannot be; what it changes in sign-in and in reading the company's people; and every
reason the deployment would be refused.

- **The exit code** is 0 when the deployment would be taken, and 1 when it would be refused, with
  the preview and its reasons printed all the same; `--json` prints the preview, its `refusals`
  empty or not.
- **No image** is taken: EHOS previews the manifest alone and checks the image when it is
  deployed, so `--image` with `--preview` is refused rather than left unchecked. Without
  `--preview`, `--image` is needed.
- **It needs** `ehos.application.deploy` there, as deploying does; a refusal of the preview is
  said as `deploy` says it.

### Environments and resources

```sh
ehosctl env create staging --type ephemeral
ehosctl resources classify shared-1 non_production
ehosctl env bind staging shared-1
ehosctl env bind staging shared-2 --application ledger
ehosctl env show staging
ehosctl env unbind staging <binding id>
ehosctl env remove staging
```

These do what the console's Environments, environment and Resources pages do
([eh-os `docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md)).
Listing and showing need one of the platform capabilities; `create` and `remove`
`ehos.environment.manage`; `bind`, `unbind` and `classify` `ehos.resource.manage`.

- **An environment and a resource** are named by their name; a binding by the id `env show` lists.
- **`--type`** is `production` or `ephemeral`: a production environment binds only resources
  serving production, any other only non-production ones (eh-os D-57), and a bind across that line
  is refused, `across_the_line`, exit 2.
- **A resource's class** is set once; setting it again exits 1, `already_set`.
- **Registering a resource** is not a command: it stays a platform operation.
- **A change that went unanswered** may have been done: the error says so, and `env show` tells.

### Role bindings

```sh
ehosctl role-bindings bind ledger.clerk --to ada@example.com --app ledger --env staging
ehosctl role-bindings bind ehos.people_reader --to ada@example.com --agent month-closer
ehosctl role-bindings list
ehosctl role-bindings unbind <binding id>
```

These do what the console's Bindings page does
([eh-os `docs/role-bindings-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/role-bindings-api.md)).
Each needs `ehos.role_binding.manage`: anywhere to list, over the binding's scope to bind or
unbind.

- **Who** is a person's email, an agent's owner's email with `--agent` and its name, or an id.
- **Where** is the whole platform without `--app`, an application with `--app`, and one of its
  environments with `--env` too. An application's role is bound in one environment.
- **A platform role** is bound only where you hold every capability it grants, or it is refused,
  `escalation`, exit 3; an agent is never bound more than its owner holds there.
- **The last `ehos.administrator`** of the whole platform is kept: removing it exits 1.

### The audit record, your activity and your agents

```sh
ehosctl audit --limit 500
ehosctl activity
ehosctl agents create month-closer
ehosctl agents list
```

These read what the console's Audit, My activity and My roles pages show
([eh-os `docs/audit-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/audit-api.md)).

- **`audit`** needs `ehos.audit.read`, and lists the decisions inside the scopes where you hold
  it: at the whole platform every one, for an application that application's. A refused read is
  recorded.
- **`activity`** lists what was done in your name or your agents', allowed and refused, and needs
  no capability.
- **Both** print the newest first, follow EHOS's pages up to `--limit` rows (100 unless given, at
  most 10,000), and say when older rows remain; `--json` gives each row whole, its details
  included.
- **An agent** holds nothing until a role is bound to it, with `ehosctl role-bindings bind
  … --agent <name>`, and never more than you hold there. You have at most 200; a name you have
  used already exits 2.

### Checking an application

```sh
cd shop
ehosctl verify
ehosctl verify --no-test
```

`verify` checks the application in the current directory as its CI does. It runs the gates the
template's CI runs, in that order, and stops at the first that fails:

1. `mix deps.get --only test --check-locked`, which fails when `mix.lock` is behind `mix.exs`, and
   fetches what is missing, as CI does: it needs the network and access to the application's git
   dependencies
2. `mix format --check-formatted`
3. `mix compile --warnings-as-errors`
4. `mix test`, left out with `--no-test` for a check without a database
5. `mix eh_os_contract.check`
6. `mix eh_os_contract.manifest`, into `_build/ehos.manifest.json`, out of the source tree

They run under the application's own `.tool-versions`, through `mise exec`, with `MIX_ENV=test`,
as in CI, and print to the terminal as they would there. They run the project's own code, as
`mix test` by hand does: run `verify` only in a checkout you trust.

Then, when an installation is chosen (`--installation`, `EHOSCTL_INSTALLATION`, or the current
one), EHOS checks the `ehos.yaml` and the manifest
([eh-os `docs/ehos-yaml.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ehos-yaml.md),
"Checking a file"), and `verify` prints what it refuses, with each error's path and line. With none
chosen, it says EHOS's check was left out, and still passes; CI has no sign-in. It submits nothing.

- A gate that fails, a manifest that was not written or is larger than EHOS takes, or a document
  EHOS refuses exits 1.
- A directory without `mix.exs`, `ehos.yaml` or `.tool-versions`, each a regular file, exits 2.
- An installation named and unknown, or a sign-in that has expired, exits 4, before anything runs
  for the first and after the gates for the second.

### Where the installation runs, and what it uses

```sh
ehosctl installation
ehosctl installation --json
```

This reads what the console's Installation page shows
([eh-os `docs/installation-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/installation-api.md)):

- the installation's name, provider, region and size, as its installer gave them, and the
  console's address;
- each node, with its capacity and its CPU and memory now;
- each environment, with its quota, what its pods request against it, and what it and each of its
  applications use now.

It needs one of the platform capabilities, as the Environments page does; a refused read is
recorded, and exits 3. What EHOS could not read it says, and prints the rest: a cluster without
metrics-server has no usage. `--json` gives EHOS's reading, CPU in millicores and memory in bytes.
`ehosctl installations` is another command: the installations this machine knows.

### What is in use, and what is newer

```sh
ehosctl versions
ehosctl versions --json
ehosctl changelog ehosctl
ehosctl changelog eh_os_contract --since 0.2.1
ehosctl changelog ehos_app --web
```

`versions` prints a row for each of EHOS's components: `ehosctl` itself, the installation's EHOS
(`ehos`), and in an application's directory, one with a `mix.exs` and a `mix.lock`, its
`ehos_app`, `eh_os_contract` and `ehos_design`, with a row for its `ehos.yaml` and, once
`verify` has written one, its manifest. Each row says:

- **in use**: `ehosctl`'s own version, and its commit for a build between releases; what the
  installation says it runs at `GET /api/v1`; what `mix.lock` locks. A locked commit is matched
  to the release whose `release.json` names it, and one that is no release's is said as a
  commit, with how far it is from the newest release (`main at 743e91d, 738 commits behind
  0.3.0`);
- **accepted**: whether the installation accepts it, as eh-os
  [D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md)
  says, from what the installation says it produces, accepts and requires, against the
  component's own `release.json`: `ehosctl` meets the installation's `requires.ehosctl` and reads
  the API it serves; the `ehos.yaml` an `ehos_app` writes is one the installation accepts; so is
  the manifest the application writes with `eh_os_contract`; `ehos_design` has no interface with
  EHOS. A release is judged the other way too, where its `release.json` says: what the
  installation produces must be what it reads, and what it requires of `ehos` must hold. A
  `release.json` is used only when it is its release's (schema, component and version). `yes`,
  `no` or `unknown`, and below the table why;
- **the newest release**, from GitHub, and whether the installation would accept it;
- **the command that moves to it**, when it is newer and not refused: `mise upgrade ehosctl`;
  for `ehos_app`, pointing its `ref:` at the commit the release names and running
  `mix ehos_app.install` again; for `eh_os_contract` on eh-os-contract's `main`, as `ehos_app`
  0.5.0 to 0.6.1 wrote it, moving `ehos_app` to a release that pins it, once one does, and running
  its installer again, which moves both of eh-os-contract's packages
  ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md));
  for one the installer keeps, a fork, another branch, a tag or a commit of the project's own,
  moving both `ref:`s and requirements by hand; for `ehos_design`, moving its `ref:`. A newer EHOS is the operator's to install: `ehosctl upgrade`, which will do
  it, does not exist yet.

The installation, GitHub and `mix.lock` can each fail alone. With no installation chosen, only
the releases are judged; without GitHub (offline, no token, refused), only the installation and
the application. What a source could not say is said, with why, and `versions` exits 0 whatever
its sources answered: only an installation named and unknown exits 4. GitHub is read up to its
newest 1000 releases in each repository; a repository with more is said to be listed in part, and
`--json` names it under `listed_in_part`, apart from what was not read at all, under `unread`.

`changelog <component>` prints the notes of each release of `ehosctl`, `ehos`, `ehos_app`,
`ehos_design` or `eh_os_contract` newer than the version in use, newest first, each under its
version: a release's section of its changelog, from the `notes.md` it attaches when there is one,
else its description. It prints the 50 newest at most, and says how many older ones it left out.
The version in use is `ehosctl`'s own, the one the installation runs for `ehos`, and the one
`mix.lock` locks for the others; when it cannot be found, `changelog` says why and asks for
`--since <version>` (exit 2). `--web` opens the newest release's page in the browser and prints
its address; `--json` gives the releases as data, and how many it left out as `left_out`.

The releases are read from GitHub's API with the token mise already uses,
`MISE_GITHUB_TOKEN`, else `GITHUB_TOKEN`: the repositories are private, and without one GitHub
does not show them, which is what `ehosctl` then says. `export GITHUB_TOKEN=$(gh auth token)` is
enough. The token is sent to `api.github.com` alone and never kept; downloading a release's file,
which GitHub redirects to another host, carries none.

#### The update notice

After a command, at most once a day, `ehosctl` says on stderr that a newer `ehosctl` is released,
or that the installation the command used no longer accepts this one, with `mise upgrade
ehosctl`. It is never printed in CI (`CI` set to anything), under `--json`, when stderr is not a
terminal, after `versions` and `changelog`, or when `EHOSCTL_NO_UPDATE_NOTICE` is set. It comes
after the command's own output and never changes it or its exit code. What it learned is kept in
`notice.json` in the cache directory below, and asked again once a day, within two seconds, of
GitHub and of the installation; the installation is asked only with the credential the command
left, never by renewing a sign-in. When that file cannot be written, nothing is asked or said.

### Versions of an application

```sh
ehosctl apps register manifest.json
ehosctl apps show ledger
ehosctl apps review ledger sha256:3f2a9c81d04e --env staging
ehosctl apps activate ledger sha256:3f2a9c81d04e --env staging
```

These do what the console's Applications and application pages do
([eh-os `docs/versions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/versions-api.md)).
Each needs `ehos.application.register`: for the application, at the whole platform for a new one,
and in the environment to review or activate there.

- **`register`** sends the manifest byte for byte, from a file or stdin, as `deploy` does. A
  version is kept forever, and is in force nowhere until it is activated.
- **A version** is named by its digest, or by its first 12 digits as the console shows them.
- **`review`** prints what activating would change: capabilities and roles added and removed, and
  roles that grow, which give everyone bound to them more than they had.
- **`activate`** reviews first, prints the same, and activates only if the version in force is
  still the one the review showed: one activated meanwhile is refused, `changed`, exit 1.
- **Deploying** activates the manifest it deploys too: `ehosctl deploy`.

### `ehosctl init <name>`

`<name>` becomes the OTP application's name. It is lowercase letters, digits and underscores,
starts with a letter and ends with a letter or a digit. A dash is written as an underscore, since
an OTP application's name allows none, and `init` says so: `ehosctl init my-shop` generates
`my_shop/`. In EHOS the application is named with dashes, as its domain is: `my-shop`. `init`
refuses a directory that already exists.

What it runs, in order. Each step gets the terminal's own stdin, stdout and stderr, so a step that
asks a question can be answered and errors stay on stderr. Each Mix step runs under
`mise exec erlang@<pin> elixir@<pin> --`, and `mise install` and every Mix step with
`MISE_ACTIVATE_AGGRESSIVE=1`, so that the pinned versions come first on the `PATH` even where
asdf's shims come before mise's (the root README, "Getting started", says what that means for
the generated project):

0. `mise install erlang@<pin> elixir@<pin>`, which does nothing once they are installed. Without
   it, `mise exec` would have to install a missing Elixir itself, and it runs the new Elixir's
   check without the Erlang named next to it on the path, so it fails with `erl: not found`.
1. `mix local.hex`, `mix archive.install hex phx_new <pin>` and
   `mix archive.install hex igniter_new <pin>`. These go into a directory that belongs to this
   `ehosctl` version, not your `~/.mix`, and are skipped when already there.
2. `mix igniter.new <name> --with phx.new --with-args "--database postgres" --yes --no-git`,
   which creates the Phoenix project.
3. In `<name>/`, `mix run --no-start -e '… Igniter.Util.Install.install([<ehos_app>], ["--example", "--yes"])'`,
   which adds [`ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/README.md) from `packages/ehos_app` of ehos-tools at the
   pinned commit and runs its installer, and Oban's with it. `mix igniter.new --install` would be
   simpler, but its spec cannot name a subdirectory.
4. `mix local.hex --if-missing`, for the pinned Elixir, so the project's own first `mix` command
   does not stop to ask for Hex.
5. `mise trust <name>/.tool-versions`, so `cd <name>` puts the pinned toolchain on the path.
6. `git init`, `git add --all` and `git commit` in `<name>/`: the project's first commit, of
   everything above.

On the machine it was measured on (macOS arm64, Hex packages already cached), `init` took 80–85
seconds, most of it fetching and compiling dependencies. The first `mise exec` of a toolchain adds
about 10 seconds, since mise installs precompiled builds.

### What it pins

All of it is in [`lib/ehosctl/template.ex`](lib/ehosctl/template.ex). One release of `ehosctl`
always generates the same project:

| Pin | Value |
| --- | --- |
| Erlang | 28.5.0.7 |
| Elixir | 1.20.4-otp-28 |
| `phx_new` | 1.8.14 |
| `igniter_new` | 0.5.34 |
| `ehos_app` | [`packages/ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/tree/main/packages/ehos_app) of ehos-tools at `7c6d527`, the commit the tag `ehos_app-v0.7.0` names |
| `eh_os_contract` | 0.3.0, which `ehos_app` 0.7.0 pins ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md)) |

### Where it writes

| What | macOS | Linux |
| --- | --- | --- |
| The new project | `./<name>` | `./<name>` |
| Installations (`config.json`) | `~/.config/ehosctl` | `$XDG_CONFIG_HOME/ehosctl`, by default `~/.config/ehosctl` |
| Sign-ins | the login keychain, and `~/.local/state/ehosctl` | the Secret Service, and `$XDG_STATE_HOME/ehosctl`, by default `~/.local/state/ehosctl` |
| Generator archives | `~/Library/Caches/ehosctl/<version>/mix_archives` | `$XDG_CACHE_HOME/ehosctl/<version>/mix_archives`, by default under `~/.cache` |
| The update notice's cache (`notice.json`) | `~/Library/Caches/ehosctl` | `$XDG_CACHE_HOME/ehosctl`, by default `~/.cache/ehosctl` |
| Erlang and Elixir | wherever mise installs tools (`~/.local/share/mise` by default) | the same |
| The unpacked `ehosctl` runtime | `~/Library/Application Support/.burrito/` | `$XDG_DATA_HOME/.burrito/`, by default under `~/.local/share` |

`ehosctl maintenance uninstall` removes the unpacked runtime. `EHOSCTL_INSTALL_DIR` moves it.

### Environment variables

| Variable | Effect |
| --- | --- |
| `EHOSCTL_TEMPLATE_SOURCE` | Replaces the pinned `ehos_app` source, for working on the template: `path:/abs/path/to/packages/ehos_app` for a local checkout, or `ref:<commit, branch or tag>` for another ref of ehos-tools |
| `MISE_GITHUB_TOKEN`, else `GITHUB_TOKEN` | The token `versions`, `changelog` and the update notice read GitHub's releases with |
| `EHOSCTL_NO_UPDATE_NOTICE` | Set to anything, turns the update notice off |
| `CI` | Set to anything but nothing, turns the update notice off |

## Linux

The binary runs on any x64 or arm64 Linux, since it carries its own runtime. The toolchain it
installs for the generated project comes from mise. Whether that is fast depends on the
distribution:

| Distribution | Erlang from mise |
| --- | --- |
| Ubuntu 22.04, 24.04 | precompiled, detected automatically. CI tests 24.04 |
| Ubuntu 20.04 | compiled from source: builds.hex.pm has no build of the pinned Erlang for it |
| Ubuntu 26.04 | precompiled once you set `MISE_ERLANG_PRECOMPILED_OS=ubuntu-26.04` |
| any other glibc distribution (Debian, Fedora, Arch, …) | compiled from source with kerl on first use: several minutes, and it needs a C toolchain, `make`, `autoconf`, and the ncurses and OpenSSL headers |
| musl (Alpine) | not available: mise refuses to install Erlang there |

Elixir is precompiled everywhere. A PostgreSQL has to be running for `mix ecto.setup`, as on macOS.

## Windows

Windows is not supported, and no Windows binary is built. The route to try is WSL 2 with the Linux
binary, which is not tested either. What stands in the way of a native build:

- **The terminal is not handed over.** `init` runs each step through an Erlang port with
  `:nouse_stdio`, so that a step can use the terminal directly. On Windows that option does
  nothing: the step's stdin and stdout are always pipes to the port
  ([`erts/emulator/sys/win32/sys.c`](https://github.com/erlang/otp/blob/OTP-28.5.0.7/erts/emulator/sys/win32/sys.c)),
  so `init` would show none of `mix`'s output. It would have to read the port and print what it
  gets instead.
- **x64 only.** Burrito has one Windows target, x64, and OTP publishes no Windows arm64 build.
- **Untested toolchain.** mise installs Erlang and Elixir on Windows from their official zips, and
  `mix` is `mix.bat` there. None of this has been run end to end, and the generated project
  (Phoenix with its asset tools, `phx.gen.release`) has not been tried on Windows either.

Supporting it means solving the first point, adding a `windows_x64` target and a `windows-2025` job
to `e2e` in CI, and building with `7z` installed, which Burrito needs for Windows targets.

## Building the binary

You need the toolchain in [`.tool-versions`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/.tool-versions) (for example, run `mise install` here),
plus [Zig](https://ziglang.org) 0.16.0 exactly and `xz`. With Homebrew: `brew install zig xz`.

```sh
mix deps.get
MIX_ENV=prod BURRITO_TARGET=macos_arm64 mix release
burrito_out/ehosctl_macos_arm64 --version
```

The targets are `macos_arm64`, `macos_x64`, `linux_arm64` and `linux_x64`. Without
`BURRITO_TARGET`, all four are built. Any of them builds from macOS or Linux: CI cross-builds each of
them on Linux. The names matter: mise chooses a release asset by the OS and architecture words in
it, and reads a bare `x86` as 32-bit and a bare `arm` as armv7.

Two things to know:

- **The build's OTP version.** Burrito bundles the ERTS of exactly the build host's OTP version,
  from its CDN. The CDN lags the newest patch release, so `.tool-versions` here pins a version that
  exists there. It is independent of the Erlang the template pins for generated projects.
- **Stale code after a rebuild.** A `prod` binary unpacks its payload once per version. After
  rebuilding without a version bump, run `burrito_out/ehosctl_<target> maintenance uninstall`, or
  the binary keeps running the previous build.

## Development

```sh
mix check
```

The gate checks the formatting, compiles with warnings as errors, runs the tests and builds the
documentation with warnings as errors. The tests never start mise, Mix or the network:
`Ehosctl.Init` builds its steps as data and runs them through an injected runner, and the
configuration is read from a temporary directory.
[`AGENTS.md`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/AGENTS.md#trying-a-change-end-to-end)
describes the end-to-end run, from the binary to a generated project passing `mix precommit`.

`mix docs` builds the reference into `doc/` with ExDoc. Every public module has a `@moduledoc`,
and every public function a `@doc` and a `@spec`; `Ehosctl.DocsTest` fails on one without.

| Module | Role |
| --- | --- |
| `Ehosctl.Application` | Runs the command in the binary and halts with its exit code, turning an unexpected exception into one line and exit code 1 |
| `Ehosctl.CLI` | Reads argv with Optimus, runs the command and returns its exit code |
| `Ehosctl.Command` | What every command declares: its name, its declaration for Optimus, its plane, and the function that runs it |
| `Ehosctl.Output` | Words or JSON on stdout, errors on stderr, and the exit code of each kind of error |
| `Ehosctl.Config` | The installations you know, and which one a governed command talks to |
| `Ehosctl.Init` | `init`: validates, builds its steps, runs them |
| `Ehosctl.Installations` | `installations list`, `use` and `remove` |
| `Ehosctl.Template` | Every pin `init` generates from |

A new command is a module implementing `Ehosctl.Command`, added to `Ehosctl.CLI`'s list and,
with its plane, to the list in `Ehosctl.CommandTest`, which fails until it is.

Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

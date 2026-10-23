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
It deploys an application, prepares environments, lets people in, and makes the server an
installation runs on; [Commands](#commands) lists them all. The way from an empty machine to an
application deployed and in use, step by step, is the
[golden path](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/golden-path.md).

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
| `ehosctl apps register \| show \| review \| activate` | governed | Registers an application's manifest as a version, lists its versions and each environment's deployment state, and reviews and activates one in an environment |
| `ehosctl apps history <app> --env E` | governed | Lists an application's deployments in an environment: the one in force, and each before it with how it ended and what came after it |
| `ehosctl apps sign-in list \| agree \| withdraw` | governed | Lists the applications whose pages ask for credentials for an application in an environment, and agrees to or withdraws one |
| `ehosctl call <app> <capability> [fields]` | governed | Runs a command, records something or asks a query in an application, as you |
| `ehosctl credential <app>` | governed | Prints a credential for an application, for a script or `curl` |
| `ehosctl people list \| show \| invite \| rename \| disable \| enable \| sign-out` | governed | Lists the company's people, invites, renames, disables and enables them, and signs out every terminal of one |
| `ehosctl people agreements \| agree \| withdraw` | governed | Lists the applications that ask to read the people, and agrees to or withdraws one in an environment |
| `ehosctl deploy <app> --env E --image I --manifest F [--graph G]… [--commit SHA] [--ref REF] [--no-wait]` | governed | Deploys an image, by digest, with its manifest, and with each `--graph` one of its graph documents (a domain's, a contract's or a process module's, at most 512), to an environment, and waits until it is active or has failed |
| `ehosctl deploy <app> --env E --manifest F --preview` | governed | Prints what deploying a manifest would do, and every reason it would be refused, and deploys nothing |
| `ehosctl landscape --env E` | governed | Shows the environment's applications as one system: who publishes each fact and who subscribes to it, what the picture leaves out, and the deployment each application is drawn from |
| `ehosctl graph <app> <deployment> [--domain M \| --contract ID \| --process ID]` | governed | Lists the graph documents a deployment carried, its domains', contracts' and process modules', or prints one as JSON |
| `ehosctl env list \| show \| create \| extend \| remove \| bind \| unbind` | governed | Lists, creates, extends and removes environments, and binds resources in them |
| `ehosctl secret list \| set \| rotate \| delete --app A (--env E \| --template T)` | governed | Lists an application's secrets, sets or rotates one from standard input or a file, and deletes one; never prints a value |
| `ehosctl resources list \| classify` | governed | Lists the resources environments may bind, and sets whether each serves production |
| `ehosctl role-bindings list \| bind \| unbind` | governed | Lists the role bindings where you manage them, with who granted one through an application and under which rule, and binds and removes roles |
| `ehosctl trust list \| add \| remove --app A` | governed | Lists, adds and removes the GitHub repositories whose Actions jobs may deploy to an application's ephemeral environments with no stored secret |
| `ehosctl github list \| claim \| remove` | governed | Lists your GitHub accounts and the refused runs you may claim one from, claims one, and removes one |
| `ehosctl people github list \| confirm \| remove` | governed | Lists the GitHub accounts people claim, confirms one, and removes one |
| `ehosctl logs <app> --env E \| --platform [--deployment ID] [--since S] [--grep T] [--limit N] [--follow]` | governed | Prints an application's logs in an environment, or EHOS's own, newest last, and with `--follow` new lines as they come |
| `ehosctl audit [--limit N]` | governed | Lists the audit record's newest decisions where you may read it |
| `ehosctl activity [--limit N]` | governed | Lists the decisions made in your name or your agents' |
| `ehosctl agents list \| create <name>` | governed | Lists your agents, and creates one |
| `ehosctl verify [--no-test]` | governed | Checks the application in this directory as its CI does, then asks EHOS to check its `ehos.yaml` and manifest when you are signed in |
| `ehosctl installation` | governed | Shows where the installation runs, and what its nodes, environments and applications use now |
| `ehosctl versions` | governed | Shows each EHOS component in use, the newest release, whether the installation accepts each, and the command that moves to it |
| `ehosctl changelog <component> [--since V] [--web]` | governed | Prints what changed in a component's releases newer than the version in use |
| `ehosctl doctor [--json]` | platform | Checks OpenTofu, Helm and kubectl at EHOS's versions, ssh and a cloud account, for the platform commands; installs nothing |
| `ehosctl server up \| tunnel [--close] \| status \| down` | platform | Makes, reaches, reads and removes the server under an installation, in Oracle Cloud, AWS, GCP or OVHcloud, from an EHOS release's OpenTofu modules |
| `ehosctl install [--installation N] [--version V] [--host H] [--sign-in-absolute D] [--sign-in-idle D] [--four-eyes \| --no-four-eyes] [--smtp-host H] [--smtp-port P] [--smtp-username U] [--mail-from A] [--no-mail] [--switch-traefik [--ssh-key PATH]]` | platform | Installs EHOS, by version, on the server under an installation, records what runs in the cluster, and keeps the installation for `login` |
| `ehosctl server invite <email> [--installation N]` | platform | Prints a link that signs a person in once, within 15 minutes, inviting them if they are new: the first person, who becomes the platform's administrator while nobody is, or one who forgot their password. The link is a password |
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
| 2 | `invalid` | The command line is not one `ehosctl` accepts: an unknown command, option or name, or fields an application says do not fit. Also a variable `ehosctl` cannot use, such as an `EHOSCTL_CA_FILE` with no certificate in it |
| 3 | `refused` | EHOS or the application refused the request: none of your roles grants it |
| 4 | `not_signed_in` | Not signed in, or the sign-in has expired or ended, or the credential was not accepted: run `ehosctl login`. Also when no installation is current, or the one named is unknown |
| 5 | `unreachable` | The installation or the application did not answer, or asked to be tried again later. Also what a command waited for that may still change when its wait ends, as a deployment still `activating` |

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
`EHOSCTL_INSTALLATION` names, else the address `EHOSCTL_URL` gives, from a GitHub Actions job
(see [Deploying from GitHub Actions](#deploying-from-github-actions)), else the current one.

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
- **An installation with a CA of its own**, which your system does not trust: a server's, whose
  CA is `~/.ehos/<name>/ca.crt` on the machine that made it, or the k3d cluster's at
  `https://ehos.localhost`, `_build/k3d/ca.crt`. Name it once, at `login`, in `EHOSCTL_CA_FILE`, a
  PEM file of CA certificates `ehosctl` trusts besides the system's, as `curl --cacert` does:

  ```sh
  EHOSCTL_CA_FILE=<path to eh-os>/_build/k3d/ca.crt ehosctl login https://ehos.localhost
  ```

  `login` keeps the certificates beside the installation in `config.json`, and every later
  command to that installation trusts them, with no variable set (T-14); `installations list`
  shows `own` in its CA column. Signing in again without the variable keeps them, and with it
  replaces them, as when the installation's CA changed; `installations remove`, then `login`,
  drops them. A `config.json` that holds a CA, and the directory it is in, must be yours and
  writable by no one else, as `ehosctl` makes them; one others can change is refused, and so is
  writing a CA through a link to one. Set for any other command, the variable
  is trusted too. `ehosctl` reads it before it connects: a file it cannot read, one larger than
  1 MiB, or one with a certificate in it that does not decode, is named and exits 2. Requests to
  GitHub, which `versions` and `changelog` make, trust the system's CAs alone.
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
  Without mail, a people manager hands one over by inviting them again in the console, and the
  operator by `ehosctl server invite` ([below](#inviting-a-person-as-the-operator)).
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
- **Where it came from** may be stated with `--commit`, 40 or 64 lowercase hexadecimal
  characters, and `--ref`, such as `refs/heads/main`. They are sent only when you give them, never
  read from a checkout, whose commit has no tie to the image deployed; their form is checked as
  EHOS checks it, their truth by no one, and EHOS shows them beside the digest as stated by you
  ([eh-os D-129](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0129-a-deployment-shows-beside-its-digest-the-github-run-its-credential-was-exchanged-for-or-what-its-deployer-states.md)).
  A deployment from a GitHub Actions job is named by its run instead, as GitHub's token says it,
  and what the job states is not taken.
- **The answer** comes once the cluster has the deployment's objects, while it is `activating`:
  the deployment's id, the image, where it came from when EHOS names it ("from GitHub's token: …"
  or "stated by …: …", told apart by the `kind` EHOS sets) and both of the manifest's digests.
  `ehosctl apps show` says the same of each environment's deployment in force. A deployment the
  cluster did not take exits 5 with its failure; one a later deployment overtook exits 1. Both
  name the deployment.
- **Then it waits** until the deployment is active (eh-os#413), reading the application's
  deployments in the environment, as the console's application page shows them, after two
  seconds and then further apart, up to every ten, and printing each state it moves to:

  ```text
  Waiting until it is active, for at most 10 minutes:
    activating
    active
  Deployment 5f0c… is active in staging, at https://ledger.staging.example.com.
  ```

  It exits 0 once EHOS says the deployment is `active`, and says so when another decided after it
  is in force by then; 1 when it `failed`, with its failure's words, or EHOS says it was
  `superseded`; and 5 when ten minutes pass first, saying the state it is still in and that
  `ehosctl apps show <app>` says it later, or when so many deployments were decided after it that
  EHOS no longer lists it among the newest. A read EHOS did not answer, or answered that it could
  not now, is tried again until then. Reading the deployments needs `ehos.application.deploy` or
  `ehos.application.register` there; a refusal of it ends the wait at once, since EHOS records
  each one, with its exit code, as does any other error, each saying that the deployment, by its
  id, was decided. Against an EHOS older than that route, it says it cannot follow the deployment
  there, and exits 0. `--json` prints one document at the end: EHOS's answer, kept to the fields
  `ehosctl` reads, with the deployment's last `state` and `failure`, the `outcome` (`active`,
  `failed`, `superseded`, `waiting`, `displaced`, or `not_followed` on an older EHOS) and the
  `addresses`.
- **`--no-wait`** returns once the deployment is decided, as `deploy` did before it waited, with
  the same words and `--json`; whether it became active is then on the application's page in the
  console.
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
ehosctl env create ledger-pr-12 --app ledger --template small --ttl 24h
ehosctl env extend ledger-pr-12 --ttl 72h
ehosctl env remove ledger-pr-12 --confirm ledger-pr-12
ehosctl env create staging --type production
ehosctl resources classify shared-1 non_production
ehosctl env bind staging shared-1
ehosctl env bind staging shared-2 --application ledger
ehosctl env show staging
ehosctl env unbind staging <binding id>
ehosctl env remove staging
```

These do what the console's Environments, environment and Resources pages do
([eh-os `docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md)).
Listing and showing need one of the platform capabilities; creating, extending and removing an
ephemeral environment `ehos.application.deploy` on its application (one made before eh-os D-98,
which belongs to none, is removed with `ehos.environment.manage`); creating a production one
`ehos.environment.manage`, and removing it `ehos.environment.remove_production`, which only the
administrator holds; `bind`, `unbind` and `classify` `ehos.resource.manage`.

- **An environment and a resource** are named by their name; a binding by the id `env show` lists.
- **An ephemeral environment** belongs to the application `--app` names, is made from
  `--template` (the installation's default without one) and expires after `--ttl` (`90m`, `24h`,
  `7d`; the installation's default without one, at most its maximum) unless `env extend` gives it
  longer, from now (eh-os D-98). `--ttl` is at least a minute. `env list` and `env show` print its
  application, template and expiry. A GitHub Actions job's credential reaches these and no other
  environment (eh-os D-110); in a job, `extend` and `remove` take `--app` too, which the job's
  exchange names where its repository is trusted by more than one application.
- **Removing** an ephemeral environment takes it down whole, its deployments withdrawn and its data
  dropped (eh-os D-100), and every removal gives the environment's name again: typed when
  `env remove` asks on a terminal, or as `--confirm <name>`. Without a terminal nothing is asked,
  so without `--confirm` nothing is sent, exit 2, as for a name given wrong.
- **`--type`** is `production` or `ephemeral`: a production environment binds only resources
  serving production, any other only non-production ones (eh-os D-57), and a bind across that line
  is refused, `across_the_line`, exit 2.
- **A resource's class** is set once; setting it again exits 1, `already_set`.
- **Registering a resource** is not a command: it stays a platform operation.
- **A change that went unanswered** may have been done: the error says so, and `env show` tells.

### Secrets

```sh
ehosctl secret list --app ledger --env ledger-try
pbpaste | ehosctl secret set smtp_password --app ledger --env ledger-try   # from the clipboard
ehosctl secret set smtp_password --app ledger --env production < password.txt
ehosctl secret rotate stripe_key --app ledger --env production --from-file stripe.key
ehosctl secret set smtp_password --app ledger --template small            # the template's default
ehosctl secret delete smtp_password --app ledger --env ledger-try
```

These do what the application's page in the console does with its secrets
([eh-os `docs/secrets-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/secrets-api.md)).
EHOS keeps the values in the installation, and nobody reads one back, an administrator included
(eh-os D-99). Setting and deleting need `ehos.secret.manage` there, which the application's
administrator holds; listing needs that or `ehos.application.deploy`.

- **Where** is `--env`, an environment of the application, or `--template`, the template's
  default for the application, which an ephemeral environment made from it gets when it has none
  of its own. Production has no template: it only ever gets its own.
- **A secret's name** is a lowercase word, and reaches every container of the workload as a
  variable of that name in upper case: `smtp_password` is `SMTP_PASSWORD`. A name the runtime or
  EHOS already sets there is refused, `invalid`, exit 2.
- **The value** is never an argument, which another process can read, and never typed at the
  terminal, which would show or keep it. `--from-file` takes the file as it is; otherwise it is
  read from standard input, a pipe or a file, to its end, less the one line break `echo` ends
  with: `pbpaste | ehosctl secret set …` on macOS, or `IFS= read -rs v && printf %s "$v" |
  ehosctl secret set …` in bash or zsh, where `IFS=` keeps leading and trailing spaces. It is
  UTF-8 text of at most 64 KiB, read no further than that, sent in the request's body alone, and
  never printed.
- **Each `set` is a new version**, and the deployments given the secret without a pin roll to it,
  which `set` counts; `rotate` is `set` under the name of what it does. A deployment that pins a
  version keeps it.
- **Deleting** removes a secret with every version. It asks first, unless `--yes`; without a
  terminal nothing is asked, so without `--yes` nothing is sent, exit 2. EHOS refuses it while a
  deployment that may be in force runs with it, `in_use`, exit 1, naming those deployments.
- **The secret store not answering** is `secrets_unavailable`, exit 5: nothing was set.

### Role bindings

```sh
ehosctl role-bindings bind ledger.clerk --to ada@example.com --app ledger --env staging
ehosctl role-bindings bind ehos.people_reader --to ada@example.com --agent month-closer
ehosctl role-bindings bind ledger.clerk ledger.auditor --to ada@example.com --app ledger --env staging
ehosctl role-bindings list
ehosctl role-bindings list --to ada@example.com
ehosctl role-bindings unbind <binding id>
```

These do what the console's Bindings page does
([eh-os `docs/role-bindings-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/role-bindings-api.md)).
Each needs `ehos.role_binding.manage`: anywhere to list, over the binding's scope to bind or
unbind.

- **Who** is a person's email, an agent's owner's email with `--agent` and its name, or an id.
- **Where** is the whole platform without `--app`, an application with `--app`, and one of its
  environments with `--env` too. An application's role is bound in one environment.
- **Several roles** in one place are one request each, in the order given. A role refused by EHOS
  does not stop the rest; not being signed in, or EHOS being unavailable, does, and the rest are
  not asked: the command then exits with that kind (4 or 5), to sign in or wait and run it again.
  Otherwise it exits with the first refusal's kind. What was bound is printed on stdout and each
  refusal on stderr, by its role. With `--json`, stdout holds `role_bindings`, each as one binding
  answers, `refused`, each with its `role`, `kind` and `refusal`, and `not_asked`. A role refused
  as `unreachable` after its request was sent may have been bound: `list` says.
- **`list --to`** shows one person's or agent's bindings. An id works for anyone who may list; an
  email is looked up as `bind` looks it up, which needs `ehos.role_binding.manage`.
- **A platform role** is bound only where you hold every capability it grants, or it is refused,
  `escalation`, exit 3; an agent is never bound more than its owner holds there.
- **The last `ehos.administrator`** of the whole platform is kept: removing it exits 1.

### Deploying from GitHub Actions

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
6. `mix eh_os_contract.schema --check`, when the application keeps an `eh_os_contract.lock`:
   every event still reads the rows the lock records
7. `mix eh_os_contract.manifest`, into `_build/ehos.manifest.json`, out of the source tree

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
- which version of EHOS runs, the commit it was built from, and when it was installed, from an
  EHOS that says so (eh-os 0.14.0 on; `ehos` under `--json`, `null` from an older one);
- whether four eyes holds on its promotions, and since when a change of it was recorded, from
  EHOS 0.14.0 (eh-os D-128, eh-os#749);
- each node, with its capacity and its CPU and memory now;
- each environment, with its quota, what its pods request against it, and what it and each of its
  applications use now.

It needs one of the platform capabilities, as the Environments page does; a refused read is
recorded, and exits 3. What EHOS could not read it says, and prints the rest: a cluster without
metrics-server has no usage. `--json` gives EHOS's reading, CPU in millicores and memory in bytes.
`ehosctl installations` is another command: the installations this machine knows.

### The server under an installation

```sh
export EHOS_STATE_PASSPHRASE=…        # encrypts OpenTofu's state; keep it with your passwords
ehosctl doctor                        # the tools and the cloud account these commands need
ehosctl server up --provider oci      # make the server; wait until k3s runs on it
ehosctl server tunnel                 # an SSH tunnel to its Kubernetes API, and a kubeconfig
ehosctl server status                 # its address, CPUs, memory and load, first boot and node
ehosctl server down                   # remove it and everything on it, once its name is typed
```

These are platform commands: they act with your cloud account and SSH key, never with a
sign-in, and they reach no application's data. The installation is the one `--installation`
names, else `EHOSCTL_INSTALLATION`, else the current one, else `trial`, and its server's files
are in `~/.ehos/<name>/`, where `mix ehos.server` kept them, so a server made with it is read as
it is. `status`, `tunnel`, `down`, `install` and `upgrade` refuse a name no server's state is kept
under, before anything runs, and name the installations that have one: a server made before
`ehosctl login` named installations after their host is under `trial`, while the current
installation has the host's name, so give it `--installation trial`. `up` makes a new server
under the name it is given; under a name it was not given, the current installation's or
`trial`, it makes one only when no other installation has a server, and otherwise asks for
`--installation`. A name the OpenTofu module refuses, longer than 16 characters, cannot name a
new server. Every command these commands suggest, such as opening the tunnel after `up`, names
the installation, so it reaches the same server whichever installation is current when you run
it.

The server is described by the OpenTofu modules of an EHOS release, kept beside the
installation in `~/.ehos/<name>/release/` with the release's `release.json`. `up` uses the release
it kept, or the one `--version` names, or, the first time, the newest: it downloads that
release's `release.json` and modules' archive from GitHub, checks the archive against the SHA-256
`release.json` names before it unpacks it, and keeps the release only once `up` has succeeded.
That checks the archive is the one the release names, not who published the release. To move a
server to a newer release's modules, run `up --version <version>`, and read the plan it shows.

Once a release is kept, `tunnel`, `status` and `down` use it with no network, and refuse another
`--version`. A server made with `mix ehos.server`, which kept none, takes the newest release the
first time one of them runs, or the one `--version` names, and keeps it. Reading eh-os's releases needs a GitHub token while it
is private, as `ehosctl versions` does.

`up` takes `mix ehos.server`'s options: `--provider` (`oci`, `aws`, `gcp` or `ovh`), which a server
not made yet needs and a made one keeps, `--region`, `--aws-profile`, `--gcp-project`, `--os-cloud`
(on OVHcloud, the entry of OpenStack's `clouds.yaml`, `OS_CLOUD`'s or `ovh` unless given),
`--ssh-key`, `--ssh-from` (repeated), `--availability-domain`, `--ocpus`, `--memory-gb`,
`--instance-type`, and `--replace`, without which a plan that would remove or replace the server is
refused. `tunnel` takes `--port`. `status` reads the node's CPUs, memory and load before it asks
Kubernetes, so it reports them with EHOS stopped.

`down` cannot be undone: it removes the server and its disk, with EHOS's database and every
application's on it, its network, and its public address, which the provider may give to anyone,
so take it out of whatever admits it, such as a mail relay's rule; EHOS makes no backups yet. It
says so, with the installation's provider, region and console, and removes nothing until the
installation's name is typed: a `y`, another name or no answer exits 1. `--yes` asks nothing, and
is taken only with `--installation` on the command line, so a script names in its own text the
server it removes. On AWS and GCP, EHOS's modules ask the provider to refuse deleting the server,
from the provider's console or a stray `tofu destroy` alike; `down`, and `up --replace` when the
plan replaces the server, lift that protection first. Oracle and OVHcloud have no such protection
on an instance.

### Installing EHOS on the server

```sh
export GHCR_TOKEN=…                         # a classic token with read:packages alone
ehosctl server tunnel --installation acme
ehosctl install --installation acme         # the newest release; --version 0.5.0 for another
ehosctl server invite you@example.com --installation acme   # the first person: the administrator
ehosctl login --installation acme           # signs in, trusting the installation's CA
```

`install` takes the release's image and chart from its `release.json`, each by digest, so nobody
copies a digest, and installs the prerequisites, the installation's CA and the chart through the
kubeconfig `tunnel` wrote. The console's host is `ehos.<address>.sslip.io`, from the server's
address, unless `--host` names another. A later `install` or `upgrade` keeps the host EHOS serves,
and refuses to keep one of sslip.io that names an address the server no longer has, as after a
server on Oracle moves to a reserved address (eh-os D-124): `install --host` moves the console, and
every application's address with it. `--sign-in-absolute` and `--sign-in-idle` set how long a
person's sign-in to an application lasts, in hours or days (`30d`, `14d`), from the sign-in at EHOS
and unused (eh-os D-113): 12 hours and 1 hour when not given, at most 366 days, the idle one at most
the absolute one; `install` and `upgrade` keep the ones EHOS runs with unless given others, and
refuse others before anything changes. Raise them only once every application runs
`eh_os_contract_auth` 0.4.0 or later. `--four-eyes` keeps whoever deployed a candidate or asked
for its promotion from approving that promotion, for an installation of several people (eh-os
D-105, from EHOS 0.9.0); `--no-four-eyes` lets them, each approval recorded as a self-approval.
A new installation of EHOS 0.14.0 or later runs without four eyes unless `--four-eyes` is given,
one before 0.14.0 with them, and from 0.14.0 a reinstall keeps what the installation had, with
four eyes on where the chart cannot tell (eh-os D-128). `install` and `upgrade` keep what EHOS
runs with unless one of them is given, a value set by hand with Helm included. Reading eh-os's
releases needs a GitHub token while it is private. `GHCR_TOKEN` is what the cluster pulls EHOS's
image with, kept there after the first install, and what Helm pulls the chart with while EHOS's
packages are private, so it is needed on every `install` until then.

`--smtp-host` and `--mail-from` give EHOS the SMTP server it sends mail through and the address it
sends from (eh-os D-36), so the console's invitations arrive by email instead of as a link passed on
by hand; `--smtp-port` is 587 for STARTTLS unless given (465 is TLS from the first byte), and
`--smtp-username` the user it authenticates as, `""` for none. TLS is always on and verified. The
host is a DNS name, and the sender and the user are printable ASCII. The user's password is read
from `SMTP_PASSWORD` alone, never an option, and written into the Secret `ehos-smtp` in
`ehos-system`, after which the governance plane restarts to use it; without it, the one the cluster
holds is kept, but only for the host and user it was given for. `install` and `upgrade` keep the
server EHOS runs with unless given other values, and `--no-mail` stops sending. The sender's domain
needs the SPF and DKIM records its provider gives, or the mail is taken for spam.

```sh
SMTP_PASSWORD=… ehosctl install --installation acme --smtp-host smtp.example.com \
  --smtp-username ehos --mail-from ehos@example.com
```

The version, the image and the chart are recorded in the Helm release, and read back first, from
its last deployed revision: the version that runs is installed again, and another is refused, since
moving to it is `upgrade`'s. So is the same version whose release now names other digests, and an
EHOS installed with `mix ehos.install`, whose version cannot be read. A later revision still pending
(an install or upgrade running, or one that was interrupted) is refused, and one that failed is
said. Once EHOS runs, the installation is kept in `config.json` under its name, with the console's
address and the installation's CA, so `ehosctl login --installation <name>` needs no
`EHOSCTL_CA_FILE`.

### Inviting a person as the operator

```sh
ehosctl server tunnel --installation acme
ehosctl server invite ada@example.com --installation acme
```

`server invite` runs EHOS's release command, `Ehos.Release.invite/1`, in the governance
container, with `kubectl exec` through the kubeconfig `tunnel` wrote and the kubectl EHOS pins
(T-13), so a `kubectl` of asdf's or of the directory you stand in never runs in its place. EHOS
invites the person, makes them the platform's administrator when nobody is yet, and prints the
link that signs them in once, within 15 minutes; `server invite` prints what EHOS said, the link
on a line of its own, and what to do with it. It needs no sign-in, no release and no passphrase.

- **The first person** of a new installation is invited this way: nobody can sign in yet, and
  `ehosctl people invite` never shows a link.
- **A person who has joined** is not refused, as the console and `people invite` refuse them:
  the link signs them in again. While the installation sends no mail, this is how one who forgot
  their password gets back in. Run it only once you know the request comes from them.
- **The link is a password**: whoever opens it is signed in as that person. Give it to them
  alone, in a direct message to an account you know is theirs, never in a channel, a ticket or a
  thread others read. It works once, until it is used or its 15 minutes pass, and a new one does
  not end it. If anyone else may have seen it, disable the person (`ehosctl people disable`, or
  the console's People), which ends every link they hold, then enable them and run the command
  again. The platform's only administrator cannot be disabled: they open their link at once,
  which uses it up.
- **The address** must be one EHOS takes, one `@` with something on each side and no space, comma
  or semicolon, at most 160 characters. It refuses more than EHOS does: invalid UTF-8, control
  and format characters, line and paragraph separators, and Unicode's spaces, such as U+00A0,
  which a terminal acts on or which hide in a pasted address; another exits 2 before anything
  runs. It reaches EHOS as
  an Elixir string, written by `inspect/2` and parsed back to check it is that one call with that
  very string, so an address that holds a quote, a backslash or `#{` is invited as it is and runs
  no code.
- A refusal of EHOS's, as for a disabled person, is said in its own words, and exits 1. Any other
  failure of `kubectl` is said as it printed it, with a sign-in link's token hidden, and asks
  whether the tunnel is open; one that does not finish within two minutes is stopped, though EHOS
  may still have invited the person, and running it again gives a link. A `kubectl` that fails
  after EHOS printed the link still prints it, and says that EHOS's administrator line may be
  missing.

### Upgrading EHOS on the server

```sh
export GHCR_TOKEN=…                                # as for install
ehosctl server tunnel --installation acme
ehosctl upgrade --installation acme                # to the newest release, after its notes
ehosctl upgrade --installation acme --to 0.6.0     # to the release --to names
```

`upgrade` reads what runs as `install` does, then prints the notes of every release after it up to
the target, as `changelog` prints them, and installs the target as `install` would, on the
console's host the running EHOS serves unless `--host` gives another (one of sslip.io that names an
address the server no longer has is refused, eh-os D-124), with the sign-in limits it runs with
unless `--sign-in-absolute` or `--sign-in-idle` give others (eh-os D-113, from EHOS 0.10.0), four
eyes on promotions as it runs them unless `--four-eyes` or `--no-four-eyes` say otherwise (eh-os
D-105), and the SMTP server it sends mail through unless `--smtp-*`, `--mail-from` or `--no-mail`
say otherwise. Before it changes anything:

- a lower version is refused unless `--allow-downgrade`: migrations do not run backwards, so the
  older code meets the database the newer one left;
- the version that runs changes nothing (`install` installs it again, and takes `--sign-in-*`,
  `--four-eyes`, `--no-four-eyes` and the mail options too);
- when a release on the way changes the governance database, as its `release.json` says with
  `migrates` (or by not saying), and before any downgrade, it asks first, since EHOS keeps no backup
  of that database; `--yes` answers, and a run with no answer changes nothing.

A server made from eh-os modules before 0.15.0 runs k3s's Traefik, and EHOS installs its own (eh-os
D-117). `install` and `upgrade` refuse such a server, changing nothing, unless `--switch-traefik`
is given: then, once what could still refuse has been decided, k3s is restarted over SSH without
its Traefik, which takes the console and its applications down for about a minute, and EHOS's
Traefik is installed before the chart (eh-os#823). It needs `EHOS_STATE_PASSPHRASE`, and
`--ssh-key` when the server was made with a key other than `~/.ssh/ehos_oci`.

An EHOS installed with `mix ehos.install` recorded no version. Its image's digest is matched against
the releases' images, and one that matches runs that release. One that matches none may be a build
of a later commit, so `upgrade` moves it only with `--allow-unrecorded`, after the question, and
records its version from then on.

### What is in use, and what is newer

```sh
ehosctl versions
ehosctl versions --json
ehosctl changelog ehosctl
ehosctl changelog eh_os_contract --since 0.2.1
ehosctl changelog ehos_app --web
```

`versions` prints a row for each of EHOS's components: `ehosctl` itself, the installation's EHOS
(`ehos`), and in an application's directory, one with a `mix.exs`, a `mix.lock`, and an
`ehos.yaml` or `ehos_app` among its dependencies, its `ehos_app`, `eh_os_contract` and
`ehos_design`, with a row for its `ehos.yaml` (`no ehos.yaml` when it has none) and, once `verify`
has written one, its manifest. Any other Mix project, such as an eh-os checkout, which depends on
`ehos_design`, is shown as outside any project. Each row says:

- **in use**: `ehosctl`'s own version, and its commit for a build between releases; what the
  installation says it runs at `GET /api/v1`; what `mix.lock` locks. A locked commit is matched
  to the release whose `release.json` names it, else to the component's tag that names it, as
  for `ehos_app`'s releases before 0.7.0, which are tags alone and are judged `unknown`; one that
  is neither is said as a commit, with how far it is from the newest release (`main at 743e91d,
  738 commits behind 0.3.0`);
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
- **the command that moves to it**, when it is newer and not refused: for `ehosctl`,
  `mise use -g github:EmpoweredHouse/ehos-tools@<version>`;
  for `ehos_app`, pointing its `ref:` at the commit the release names and running
  `mix ehos_app.install` again; for `eh_os_contract` on eh-os-contract's `main`, as `ehos_app`
  0.5.0 to 0.6.1 wrote it, moving `ehos_app` to the newest release whose `release.json` admits
  it, that the installation does not refuse and that is newer than the one in use, or once one
  does, and running its installer again (only that, when the one in use admits it), which moves
  both of eh-os-contract's packages
  ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md));
  for one the installer keeps, a fork, another branch, a tag or a commit of the project's own,
  moving both `ref:`s and requirements by hand; for `ehos_design`, moving its `ref:`; for EHOS,
  which is the operator's, `ehosctl upgrade --to <version>`.

The installation, GitHub and `mix.lock` can each fail alone. With no installation chosen, only
the releases are judged; without GitHub (offline, no token, refused), only the installation and
the application. What a source could not say is said, with why, and `versions` exits 0 whatever
its sources answered: only an installation named and unknown exits 4. GitHub is read up to its
newest 1000 releases in each repository; a repository with more is said to be listed in part, and
`--json` names it under `listed_in_part`, apart from what was not read at all, under `unread`.
A repository's tags are read only for a locked commit no `release.json` names, once for all its
components, up to 1000 and no further than the page that names every such commit; tags not read
are under `unread.github_tags`, and those read in part under `tags_listed_in_part`.

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
with `mise use -g github:EmpoweredHouse/ehos-tools@<version>`, the command that installs it
([Getting started](../../README.md#getting-started) says why it names the version), or that the
installation the command used no longer accepts this one, and that `ehosctl versions` says whether
it accepts the newest release. It is never printed in CI (`CI` set to anything), under `--json`, when stderr is not a
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
- **`show`** lists the versions, newest first, and each environment's version in force with its
  deployment state (eh-os#413): the state of the deployment in force (`active`, `activating`), or
  `none`, or `failed:` and the start of its failure when the newest deployment there, decided
  after the one in force, failed. It reads each environment's deployments, one request for each.
  An environment whose deployments cannot be read, or every one against an EHOS older than that
  route, is `unknown`, and each reason is said once. `--json` adds each environment's `state`,
  its `deployment` in force, the newer one that `failed`, its `addresses` and `why` a state is
  unknown.
- **`review`** prints what activating would change: capabilities and roles added and removed, and
  roles that grow, which give everyone bound to them more than they had.
- **`activate`** reviews first, prints the same, and activates only if the version in force is
  still the one the review showed: one activated meanwhile is refused, `changed`, exit 1.
- **`history <app> --env E`** prints what the console's tab for that environment shows
  ([eh-os#802](https://github.com/EmpoweredHouse/eh-os/issues/802)). It shows the deployment in force,
  with where it came from, the promotion that brought it to production and its addresses. Then come
  the deployments and refusals before it, the 20 newest of each, newest first. Each deployment says
  how it ended and what came after it: "replaced by" the one that took its place, or "followed by"
  the next one, and what that one changed: a new image, a new manifest, or new versions of
  secrets. A secret is named only to someone who may list them. It needs
  `ehos.application.deploy` or `ehos.application.register` there; an EHOS older than 0.14.0 says
  nothing of what came after.
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
6. `git init`, `git symbolic-ref HEAD refs/heads/main`, `git add --all` and `git commit` in
   `<name>/`: the project's first commit, of everything above, on `main`, the branch its CI
   publishes from, whatever git's own default branch is (`phx.new` has already run `git init`,
   which a second `git init --initial-branch=main` would not change).

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
| `ehos_app` | [`packages/ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/tree/1d706502f3598db819908f657cdba0552905636c/packages/ehos_app) of ehos-tools at `1d70650`, the commit the tag `ehos_app-v0.19.0` names |
| `eh_os_contract` | 0.9.0, which `ehos_app` 0.19.0 pins ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md)) |

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
| `EHOSCTL_URL` | An installation's address, `https://host[:port]`, for a GitHub Actions job: commands talk to it with the job's own token, exchanged for each credential, and keep nothing ([T-18](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0018-in-a-github-actions-job-ehosctl-talks-to-the-installation-ehosctl-url-names-and-exchanges-the-job-s-token-for-each-credential-keeping-nothing.md)) |

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

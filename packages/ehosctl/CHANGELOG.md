# Changelog

All notable changes to `ehosctl` are recorded here by hand, each in the pull request that makes
it, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehosctl` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that breaks something starts with
`**Breaking:**`. Between releases the version is the next minor's `-dev`. A release's section is
the notes of its GitHub release, tagged `vX.Y.Z`
([releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)).

A release pins one template (`lib/ehosctl/template.ex`), so every change to a pin is listed here:
it changes what `ehosctl init` generates.

## [Unreleased]

### Changed

- `ehosctl db connect` starts `psql` in the schema of the application, when EHOS 0.32 or later
  names it: it sets `search_path` to that schema. `ehosctl db tunnel` shows the schema on a line
  of its own, in the options, and as `currentSchema` in the JDBC line. With an older EHOS,
  `ehosctl` works as before (eh-os#1656).
- `ehosctl server admin remove` removes the line of the person in `authorized_keys` first, and
  their bindings after it. If it stops between the two, the person cannot log in over SSH.

### Fixed

- `ehosctl server admin add` and `remove` no longer stop when GCP's guest agent changes
  `authorized_keys` at the same time. They read the server again and try the write 3 times at most.
  They stop, and change nothing, when the line of an installation administrator changed.
- `ehosctl server admin add` and `remove` stop before they change a ClusterRoleBinding or a
  RoleBinding when `authorized_keys` changed right after they wrote it. Before, `remove` could
  report a person removed while GCP's guest agent had written their line back.
- `ehosctl doctor` reads the installation administrators of the installation that
  `EHOSCTL_INSTALLATION` names, else of the current installation if this computer keeps its
  server. Before, it read them only with `--installation`.
- `ehosctl server up` says "Updating the server" for a server that it made before, and
  "Making the server ... again" when it makes the server again. Before, it said "Making the
  server" each time.

## [0.50.0] - 2026-11-25

### Added

- `ehosctl server admin add NAME --public-key FILE`, `remove NAME` and `list` give each
  installation administrator an SSH key of their own on the server, and a ClusterRoleBinding of
  their own to `cluster-admin`. `remove` takes one person's access away and keeps the access of
  the others. It refuses to remove the last installation administrator. `list` also shows each key
  that names nobody, each other subject bound to `cluster-admin`, and the certificate signing
  requests. The commands work over SSH and need no cloud credential. `add` refuses a key that is
  on the server already without a name, such as the key that each administrator shares.
- `ehosctl server up` makes you the first installation administrator of a new server, by your user
  name on your workstation, or by `--administrator NAME`. `up --provisioning-key FILE` replaces
  the key that a new server takes on its first boot.
- `ehosctl doctor --installation NAME` also lists the installation administrators of that server.
- `ehosctl server tunnel` finds the installation administrator that you are by the line on the
  server that holds your key, and records the name. A folder copied from another workstation does
  not make you the administrator that it records. `tunnel --administrator NAME` checks that the
  line of NAME holds your key.

### Changed

- **Breaking:** `ehosctl init` makes an application from `ehos_app` 0.38.0, not from 0.37.1, at
  the commit that the tag
  [`ehos_app-v0.38.0`](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.38.0)
  names. The new application uses the contract library under its new name, `ehos_contract`
  0.16.0: the tasks `mix ehos_contract.*`, the modules `EhosContract.*`, the
  schema lock `ehos_contract.lock` and the Claude Code plugin `ehos-contract`. Its CI runs
  `ehosctl` 0.49.0. The notes of `ehos_app` 0.38.0 say how an application made before moves to
  the new name ([#449](https://github.com/EmpoweredHouse/ehos-tools/issues/449)).
- `ehosctl resources add-database`, `prepare-sql`, `mark-gone` and `remove-database`, and the
  reference pages of `ehosctl env start-without-data`, no longer say that they are for the
  development of EHOS only: a release of EHOS after 0.31.0 offers a database outside the
  installation without `dataResources.externalUnderDevelopment` (eh-os D-201). `add-database`
  says that EHOS 0.30.0 and 0.31.0 still need that value and offer the feature to develop EHOS
  only.
- **Breaking:** `ehosctl server tunnel` no longer copies the admin kubeconfig of k3s for an
  installation administrator. It writes a kubeconfig with a key of your own and a certificate for
  12 hours, which the cluster signs. It issues a new one when less than 1 hour is left. If your key
  is on the line of no person, and the server still has the key that each administrator shares,
  or no person with a key yet, it copies the admin kubeconfig of k3s as before, and warns.
  Otherwise it refuses. A kubeconfig that an earlier `tunnel` wrote keeps the admin certificate of
  k3s, which works for up to a year, and `admin remove` does not end it: delete it, and run
  `tunnel` again with your own key.
- **Breaking:** `ehosctl server tunnel` needs the public key of the key that you log in with, to
  find your line on the server. It reads the `.pub` file beside the key, else asks `ssh-keygen`.
  For a key with a passphrase and no `.pub`, it refuses, and gives the command that writes the
  `.pub`.
- **Breaking:** `ehosctl server tunnel` fails when it cannot read the installation administrators
  of the server, as while k3s restarts, unless your workstation records you, you log in with the
  key whose line named you, and your kubeconfig holds your own certificate with an hour left.
  Then it keeps that certificate, and warns. Run it again when the cluster answers.
- **Breaking:** `ehosctl server up` refuses to make a new server when it cannot make a name from
  `USER` or `LOGNAME`, as in a container with no `USER`. Give `--administrator NAME`. If `up`
  makes the server again, as after `down`, it refuses after the apply.
- **Breaking:** `ehosctl server up --administrator NAME` refuses on a server that an `up` with
  another user name made, as in a folder copied from another workstation. Ask an installation
  administrator to add you with `ehosctl server admin add`.
- `ehosctl server admin add` and `remove` say, when the server does not take your key after they
  change `authorized_keys`, that the server puts the previous file back within 60 seconds, with a
  line that the command removed. Run the command again after that.
- `ehosctl server tunnel` refuses a certificate that the cluster issues for longer than the
  12 hours that it asks for, and writes no kubeconfig.
- `ehosctl server handover` hands over no SSH key. It says how the person makes a key of their own,
  and gives the `ehosctl server admin add` and `remove` that you each run. On Oracle Cloud, it
  names the profile of `~/.oci/config` that the `up` of the person reads.
- The warnings of `ehosctl server up` and `tunnel` call the SSH key of each installation
  administrator their own, and say that the kubeconfig gives access until its certificate expires.
- **Breaking:** `ehosctl server up` keeps the SSH key that the server took on its first boot.
  `--ssh-key` now chooses only the key that you log in with. Before, `up --ssh-key` put a new key
  on the server: in place on GCP, and with a new server on AWS, Oracle and OVHcloud. Give
  `--provisioning-key` for that now. `up` refuses to make the server again with a key that you
  do not log in with.
- `ehosctl server up` and `tunnel` warn when the server has no installation administrator of their
  own, or only one. `tunnel` and `status` no longer warn before they connect when your key is not
  the key that `up` put on the server.

### Security

- `ehosctl` also removes the temporary directories that 0.48.0 or an earlier version left when it
  was killed while it wrote a Secret: those of the pull credential, the SMTP password, the
  Let's Encrypt account keys and the managing role of a database outside the installation. Each
  held its credential. As for the other leftovers, `ehosctl` removes such a directory only when
  it is yours, only you can open it, and nobody changed it for more than a day.

## [0.49.0] - 2026-11-24

### Added

- `ehosctl server handover [--installation N] [--email EMAIL]` prints what another installation
  administrator needs to take over the installation: if the person needs to be one, what goes in
  the shared password manager, what the person makes for themselves, the certificates, who owns
  the state, and the commands that each of you runs. OpenBao's key is not handed over. With the
  1Password CLI on the path, it prints the `op` commands. It contacts nothing, changes nothing and
  shows no secret.
- `ehosctl resources mark-gone NAME` and `ehosctl resources remove-database NAME` are for the
  development of EHOS only. `mark-gone` marks a database outside the installation gone for good, so
  that the removal of an ephemeral environment bound to it drops nothing there. `remove-database`
  takes a database out of the list, and deletes the Secret of its managing role that `ehosctl`
  made. EHOS refuses `mark-gone` while an environment that is not removed is bound to the database,
  and `remove-database` while a resource binding names it.
- `ehosctl install`, `upgrade` and `resources add-database` keep the mark of a database outside the
  installation that is gone for good, when they read the list back from the running EHOS.

### Changed

- **Breaking:** `ehosctl changelog` and `ehosctl versions` name the contract library
  `ehos_contract`. `ehosctl changelog eh_os_contract` is refused: run
  `ehosctl changelog ehos_contract`. A script that reads `ehosctl versions --json` finds the row
  under the name `ehos_contract`
  ([#449](https://github.com/EmpoweredHouse/ehos-tools/issues/449)).
- `ehosctl` reads the contract library under its new name, `ehos_contract`, and under its name
  before 0.16.0, `eh_os_contract`. `ehosctl verify` runs `mix ehos_contract.check` and the other
  tasks of the library under the name that the `mix.lock` of the application has, and reads the
  schema lock under that name. `ehosctl versions` shows one row `ehos_contract` for both names,
  from `EmpoweredHouse/ehos_contract`
  ([#449](https://github.com/EmpoweredHouse/ehos-tools/issues/449)).

### Fixed

- `ehosctl` no longer refuses a valid `ehos.yaml` when the machine is busy. The reader stops a
  parse after a fixed amount of work, not after 1 second. On an idle machine, this limit is about
  1 second of work.
- `ehosctl` checks each command that it offers in a sentence, also when a value from EHOS in the
  same sentence holds a backquote. If a value in the command starts with `-` or holds `\`, `ehosctl`
  gives the sentence without the command.
- The `ehos` row of `ehosctl versions`, and the refusal of `EHOSCTL_URL` on a terminal, quote each
  value in the command that they offer for a shell. An address in `EHOSCTL_URL` with `$(…)` no
  longer runs a command in the shell where you paste `ehosctl login`.

### Security

- If the VM of `ehosctl` fails, it writes no `erl_crash.dump` into the current directory. The
  dump held the memory of `ehosctl`, with the passphrase of the state and credentials. The
  programs that `ehosctl` starts, `mix` among them, write no dump either. Delete an
  `erl_crash.dump` that an earlier `ehosctl` left. If such a file was shared or synced, others
  may know the passphrase of the state and the credentials that it held.
- `ehosctl` removes the temporary directories that a killed `ehosctl` left, when nobody changed
  them for more than a day. Such a directory can hold a credential, for example a pull credential
  or a password for SMTP.
- `ehosctl` no longer gives `EHOS_STATE_PASSPHRASE` to the tools that it runs: `tofu`, `ssh`,
  `helm`, `kubectl`, `git`, `mise`, `psql` and their plugins. OpenTofu gets the passphrase only as
  `TF_VAR_state_passphrase`.

## [0.48.0] - 2026-11-23

### Changed

- A warning that belongs to the outcome of a command comes after the outcome, on stderr. Before,
  it came first. This applies to `login`, `trusts add`, `env create`, `env quota set`,
  `apps show`, `verify` of a utility service, `deploy --preview`, and the wait of `deploy` and
  `approve`.
- These warnings have a short head and an explanation under it: the DNS warnings of
  `ehosctl install` (a record of your own under the host, the certificates in the Certificate
  Transparency logs), the warning that kubectl failed after `ehosctl server invite` printed the
  link, and the warnings for databases outside the installation that `install` and `upgrade`
  leave out.
- When a wait of `ehosctl install` or `ehosctl upgrade` fails, what kubectl printed comes after
  the sentence, under its name, not inside the sentence. A failure of OpenTofu in
  `ehosctl server` names its subcommand, such as `tofu apply`.

### Fixed

- `ehosctl login --json` prints no warning on stderr. It gives each warning under `warnings` in
  the JSON instead, with its head and its explanation: the data CAs, a sign-in kept in a file,
  and a sign-in that it could not end.
- When `ehosctl login` keeps the sign-in in a file and a later step fails, the error says that
  the refresh token stays in the file. Before, the error did not say it.
- `ehosctl` cuts each warning, step and output of another program that it prints at 64 KiB, as
  it cuts an error. Before, what cloud-init or `kubectl get nodes` printed in `server status` and
  `server up` had no limit.
- After a move to public certificates, `ehosctl` stops the wait for the certificates of the
  addresses at once when kubectl is not installed. Before, it tried again for up to 15 minutes.

## [0.47.0] - 2026-11-22

### Changed

- **Breaking:** `ehosctl init` says each step on stderr, after `==>`, and what the step prints
  follows it there, indented. stdout holds the outcome: the directory, the Erlang and Elixir, the
  name in EHOS, a reminder to start Docker, and the next commands under `Next:`. A step that fails
  names the command and, when it leaves something behind, says what; after the project is
  generated, the commands that finish it are under `What to do:`. Its errors start with
  `ehosctl:`, not `ehosctl init:`, and a name that is not valid exits with 2, not 1. The note that
  a dash becomes an underscore is a warning on stderr, not a line on stdout.
- `ehosctl init --service` gives an outcome, each file as written or kept, the shared workflow its
  pipeline calls, what EHOS asks of the image as a list, and `ehosctl verify` under `Next:`.
- **Breaking:** A date in a table or a line is in one form, in UTC: `16 October 2026,
  14:02 UTC`. Before, `terminals` and `status` printed `2026-10-16 14:02 UTC`; `env`,
  `secrets list`, `builds list`, `apps show`, `github list` and `claim`, `people github confirm`,
  `audit`, `agents list`
  and `promotions --waiting` printed EHOS's ISO 8601; and the release notes of `changelog` and
  `upgrade` printed the date alone (`2026-10-09`). A value that is not there is `<none>`, as
  kubectl prints it. Before, it was `none`, `-`, `(none)`, `(not set)` or an empty cell, in
  `apps show`, `builds list`, `env`, `promotions`, `secrets list`, `resources`, `people show`,
  `audit`, `github list`, the agreements of `people` and `mail`, `services list`, `verify` and
  others. In `versions`, a column that does not apply to a row says `n/a`. `--json` and the
  lines of `logs` do not change.
- `ehosctl upgrade` gives what it keeps on aligned lines before its question: the console, the
  sign-in limits, the approval, the mail and the domains. The notes of each release come under a
  line that names the release, indented, and dim on a terminal.
- When `ehosctl approve` cannot follow the deployment, it says so as a warning with `!`, as
  `ehosctl deploy` does, and the console page on the line under it.
- The reason that an installation does not accept a version of `ehosctl` says "this version of
  ehosctl reads", not "it reads", in `ehosctl versions` and in the notice after a command.

### Fixed

- When `ehosctl login` reads the data CA and the gateway CA but cannot keep them in `config.json`,
  it says so. Before, it said that reading them failed.
- `ehosctl resources show` gives `<none>` in the LISTED column for a group that lists no member.
  Before, the cell was empty.
- When `ehosctl` leaves out each command of its advice, it also leaves out the advice that
  introduces them, which ends in a colon, such as "To keep them, run:".
- `ehosctl db tunnel` and `ehosctl db connect` now say why a data session ended when the database
  ends a connection first, as when a person ends the session or loses the right to it. Before,
  the client of the connection often saw only the database's error.
- When `ehosctl` cannot read what EHOS answered to a change and leaves out the command to look at
  it, it still says "See it." or "See what was done.". Before, it said nothing about where to look.
- The command that `ehosctl server up` gives to keep a release again says `--version VERSION`.
  Before, it said `--version <the release of the server>`, and a shell reads `<` as a redirection.
- `ehosctl domains` names the console page of a domain with the name encoded for an address.
  Before, a name with `/`, `?` or `#` named another page. When a terminal would act on a character
  of the name, it names the console page of all domains.
- `ehosctl agents create` does not accept an ID from EHOS that is not a UUID, and says to look at
  the agents.

### Security

- A command that `ehosctl` writes into a sentence, such as "Run `ehosctl promotions show ID`",
  quotes each name from EHOS or from the command line for a POSIX shell (sh, bash, zsh). Before,
  a name such as `x$(curl … | sh)` was printed as it was, and a person who pasted the command ran
  what the name held. When a name holds a character that a terminal acts on, `ehosctl` does not
  give the command.
- `ehosctl` does not give a command to paste when a value in it, from EHOS or from the command
  line, starts with `-` or holds `\`. The command reads a value that starts with `-` as an option.
  fish reads `\` inside single quotes, and sh, bash and zsh do not. This applies to the commands
  under `Next:` and `What to do:`, to a command in a sentence, and to `what_to_do` under `--json`,
  which `ehosctl` leaves out when no command is left.
- When `ehosctl deploy` refuses `--bundle` with `--preview`, the `--manifest` path that it gives
  is quoted for a shell.

## [0.46.0] - 2026-11-22

The tag of 0.45.0 names a commit that failed the checks of a release, so 0.45.0 was not published.
This version contains all the changes of 0.45.0. If you upgrade from 0.44.0, also read the
[notes of 0.45.0](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/CHANGELOG.md#0450---2026-11-20).

### Added

- `ehosctl verify --json` gives each gate with its result, exit status and time, the bundle, and
  what EHOS said of `ehos.yaml` and the manifest. When a gate fails, the error's object holds the
  gates. In the directory of a utility service, it gives the service, the schema, the OpenAPI
  file, the bundle and what EHOS said.

### Changed

- **Breaking:** `ehosctl verify` says each gate on stderr, as `==> Gate 3 of 7: mix format
  --check-formatted`, and what Mix prints follows it there, indented. stdout holds the result
  alone: an outcome, a table with the result and time of each gate, what EHOS said as labelled
  values, and the next commands under `Next:`. A gate that fails prints the table on stderr
  before the error. A script that read the gates or Mix's output from stdout reads them from
  stderr now.
- When Credo is not among the packages in `mix.lock`, `ehosctl verify` says that it skipped the
  lint as a warning on stderr, once the gates have run, and as a row of the table.

### Security

- `ehosctl` is built with `idna` 8.0.0, past the advisory
  [EEF-CVE-2026-117678](https://osv.dev/vulnerability/EEF-CVE-2026-117678). An application that
  `ehosctl init` made before this version can still have `idna` before 8 in `mix.lock`. The
  Security section of the notes of 0.45.0 gives the steps that fix it.

## [0.45.0] - 2026-11-20

### Added

- `ehosctl server down` gives the place of the encrypted state, which it keeps. A warning says
  that `server up` makes the server again from the folder of the installation, and how to remove
  the folder and the copies in the password manager when you do not. When `ehosctl` knows the
  installation, a second warning gives `logout` and `installations remove` for it.
- `ehosctl install` and `upgrade` give the place of each secret the installation keeps. When the
  cluster pulls with a new GitHub token, a warning says what a leak of it does. A warning about
  OpenBao's key comes once on each machine, and when the cluster makes the key or changes it.
  `config.json` marks the warning given by the name of the kind, never a value.
- `ehosctl resources add-database --password-file FILE` says that the cluster keeps a copy of the
  password, and that the file is yours to keep or remove.
- `ehosctl login` says where it keeps your sign-in: the system keychain, or its file. `--json`
  gives it as `secrets`, with the kind, the place, the keeper and if it is new. When the sign-in is
  kept in a file, the warning also says what a leak of the token does and that it is yours alone.
- `ehosctl server up` and `server tunnel` give the place of each secret they rely on: the state
  passphrase, the encrypted state, the SSH key and the kubeconfig. When `up` changes the server,
  or `tunnel` writes a kubeconfig with a new credential, a warning says what a leak or a loss does
  and where to keep the secret.
- `ehosctl env template service-entry list | set | remove TEMPLATE [SERVICE] --app APPLICATION`
  manages the utility services that the ephemeral environments of an application get a copy of,
  each from a production environment (`--source`). `service-entry agree … --host HOST:PORT` and
  `service-entry withdraw` give and withdraw the application's agreement to the hosts outside that
  the service names. They need an EHOS that answers
  `/api/v1/applications/:name/templates/:template/service-entries`. An EHOS that does not copy
  services yet keeps the entries and copies nothing. A person who may approve the releases of the
  application removes an entry too.
- `ehosctl resources show RESOURCE` prints where a resource is, what the last check of a database
  outside the installation found, line by line, its schemas' groups and the resource bindings
  that name it. `ehosctl resources check RESOURCE` prints the lines of that check, and exits 1
  when the database did not pass. Both need an EHOS that answers `GET /api/v1/resources/:name`.
- `ehosctl resources add-database NAME` is for the development of EHOS only. It adds a database
  outside the installation, and works only against an EHOS whose chart is given
  `dataResources.externalUnderDevelopment`. Without it, the chart refuses the database, and
  `ehosctl` changes nothing.
- `ehosctl resources prepare-sql --database D --username ROLE` is for the development of EHOS only.
  It prints the SQL that prepares a PostgreSQL server outside the installation: the managing role,
  its database, the managing role's right to give the roles of EHOS `CONNECT` there, and the rights
  that `PUBLIC` loses there, `CONNECT` included. It contacts nothing, and the SQL names no
  password.
- `ehosctl env start-without-data ENVIRONMENT APPLICATION` is for the development of EHOS only. After
  the administrator of a database outside the installation dropped the data of an application on
  purpose, it tells EHOS to forget that data. The next deployment makes the schema again, empty. It
  asks first, unless `--yes`, since you cannot undo it. It needs an EHOS that answers
  `DELETE /api/v1/environments/:name/bindings/:id/data-ready`.

### Changed

- `ehosctl init` creates from `ehos_app` 0.37.1, at the commit its tag names, instead of 0.36.0
  ([0.37.1](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.37.1)). A new
  application uses eh-os-contract 0.15.1, whose tables are at version 6. While nothing is
  appended, its subscriptions write no lines to the log of the development server. An append
  wakes them when its transaction commits. At commit, the notification takes one lock for the
  PostgreSQL instance, so the commits that notify wait for each other, also in other applications.
  An append that sends no notification waits for the poll, every 30 seconds. The notes of
  [`ehos_app` 0.37.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.37.0)
  say when an append sends no notification.
- **Breaking:** `ehosctl env create`, `env extend`, `env quota set` and `clear`, `trusts add` and
  `role-bindings bind` start with what they did after `✓`. What EHOS made comes on aligned lines
  under it. For an environment, these are its type, application, environment template, expiry,
  quota and limits. For a trust, they are its ID, refs, environments and workflow, and for a role
  binding, its ID. `env show` gives an environment's values under its name, and `env quota show`
  its quota and limits. `env create` gives `ehosctl env extend` or `ehosctl env bind` under
  `Next:`. `env show` of an environment with no resource binding gives `ehosctl env bind`. A
  script that reads a value from these sentences must read it from its labelled line. The
  documents of `--json` do not change.
- EHOS's warnings of a trust are warnings on stderr, each with a head and an explanation. So are
  an environment that EHOS did not confirm it made without the role entries of its environment
  template, and the applications that no longer fit a quota. None is printed under `--json`.
  `deploy --create-env` prints the outcome of the environment it creates on stderr, in the same
  shape, with no `Next:`.
- `Next:` and `What to do:` leave out a command with a character a terminal acts on, such as one
  in a name EHOS sends. Printed in quotes, such a command could run another command when pasted.
- **Breaking:** `ehosctl login`, `logout` and `agents create` start with what they did after a
  marker, `✓`, `!` when `logout` signed out on this computer alone, or `·` when there was nothing
  to do. The address, the end of the sign-in, the reason a sign-out did not reach EHOS or the
  agent's ID come on aligned lines under it. `whoami` says who you are, with the address and the
  end of the sign-in on aligned lines. `agents create` gives `ehosctl role-bindings bind` under
  `Next:`. A script that reads a value from these sentences must read it from its labelled line.
  The documents of `--json` do not change.
- **Breaking:** `ehosctl server invite` starts EHOS's line with `✓` on stdout. What to do with the
  link, which is a password, is a warning on stderr, said before the link; so is a kubectl that
  failed after EHOS printed it.
- `ehosctl login` says on stderr, after `==>`, that it opens the browser and that it waits for the
  sign-in, with the address to open by hand on a line of its own; under `--json`, the address
  alone. When the sign-in does not finish, the error gives the command that signs in again under
  `What to do:`, with the address when you gave one, and under `--json` `what_to_do`.
- **Breaking:** `ehosctl deploy` starts with what EHOS decided after `✓`, with the deployment,
  its state, the image, the build, the source and the digests on aligned lines under it, and ends
  with a deployment that is active after `✓`, with its addresses. `--no-wait` gives
  `ehosctl apps history` under `Next:`. A script that reads a value
  from these lines must read it from its labelled line.
- `ehosctl deploy --preview` starts with `·`, or `✗` when EHOS would refuse the deployment, with
  the digests on aligned lines, lists the reasons EHOS would refuse it, and gives the command that
  deploys under `Next:`, with `IMAGE` to replace. A host that is the mail server of the
  installation is a warning on stderr.
- `ehosctl apps register` says what it registered after `✓`, or after `·` when EHOS had the
  version, with the version on a line of its own and `ehosctl apps review` under `Next:`.
  `ehosctl apps show` says on stderr, as a warning, each environment whose state is unknown.
- The commands that `deploy` and `apps register` suggest name the installation with
  `--installation`. When the wait of `deploy` gets no answer from EHOS, and when `apps register`
  gets an answer it cannot read, the error says the command under `What to do:`, and under
  `--json` it has `what_to_do`. After `--no-wait`, and when the wait cannot say the state, `deploy`
  suggests `ehosctl apps history APP --env ENV`, which needs what the deployment needed.
- When `tofu`, `helm`, `kubectl` or `ssh` fails under `ehosctl server`, `install`, `upgrade` or
  `resources add-database`, the error shows what the program printed under its name, on indented
  lines, after what failed and its hint. Under `--json`, the message still holds it, on the lines
  after what failed.
- `ehosctl resources list` says whether each resource is in the installation or outside it, where
  a database outside is, and the state of its last check.
- When EHOS opens no data session because the database is outside the installation, `ehosctl db
  connect` and `db tunnel` link the guide that tells the installation administrator how to give a
  person a way to that data.
- Under `--json`, each binding that `env show` prints gives its `data_ready_at` when EHOS says it.
- `ehosctl env bind` and `env template bind` say that EHOS opens no data session on a database
  outside the installation, and that a role binding of a role that grants `ehos.data.read` or
  `ehos.data.write` gives no way to its data.
- Under `--json`, each binding that `env show`, `env bind`, `env template show`, `env template list`
  and `env template bind` print gives its resource's `provider`.
- On a terminal, `ehosctl` shows the `ehosctl:` before most errors in red, and the `==>` before
  each step of `server` and `install` dim. Set `NO_COLOR` to turn colour off. Output into a pipe
  or a file, and `--json`, have no colour.
- Some errors now show what to do under `What to do:`, each command on its own line, ready to
  copy. A command that talks to an installation names it with `--installation`. These errors are:
  - "You are not signed in" and "Your sign-in has expired", when `ehosctl` finds that it has no
    valid sign-in for the installation;
  - "No installation is current" and "No installation is named";
  - "did not answer", and a TLS handshake that failed;
  - most changes that `ehosctl` sends to EHOS, such as a setting, an approval or a data session,
    when they get no answer, or an answer `ehosctl` cannot read.

  Under `--json`, these errors have `what_to_do`, the list of commands. Their `message` is still
  one sentence. When EHOS refuses a sign-in itself, its words do not change.
- "You are not signed in" and "Your sign-in has expired" name the installation. The `ehosctl
  login` that they show signs in to that installation, not to the current one.
- "did not answer" tells you to check the network connection and run the command again. It does
  not tell you to run the command again when the request possibly changed something.
- Warnings start with `!` and a short line, yellow on a terminal, with the explanation indented
  under it. These are the warnings:
  - of `login`: a sign-in kept in a file, a replaced sign-in that `ehosctl` could not end, the
    data CA and the gateway CA that it could not read or that have another key;
  - of `deploy` and `env create`: an environment named as the preview of a pull request;
  - of `deploy`: an environment that EHOS did not say it made without the role entries;
  - of `install`, `upgrade` and `resources add-database`: a mail relay with no SMTP user;
  - the notice of a newer `ehosctl`, and of an installation that does not accept this one.
- **Breaking:** `deploy` and `approve` print the wait for the deployment on stderr, after `==>`,
  and only the outcome on stdout. The states read "State of the deployment: activating". A script
  that reads the states from stdout must read stderr, or use `--json`, which does not change.
- `logs --follow` says that a tail ended after its hour as a warning, not as an error. It still
  exits 0.
- **Breaking:** `ehosctl server up`, `tunnel`, `status` and `down` start with what they did
  after `✓`, or `·` when there was nothing to do. The values come on aligned lines under it: the
  address and the SSH host key of `up`; the address, the kubeconfig and the context of `tunnel`;
  the address, the CPUs and the memory of `status`. The commands to run next come under `Next:`,
  each on its own line. `status` shows what cloud-init and Kubernetes printed under the name of
  each command. A script that reads a value from these sentences must read it from its labelled
  line.
- While `ehosctl server up` waits for the server to answer SSH, it says so once, and then once a
  minute, not every 10 seconds. A changed address of the server, a first boot with recoverable
  errors, and an SSH key that is not the one `up` put on the server are warnings.
- **Breaking:** `ehosctl install`, `upgrade` and `resources add-database` end with what the
  install did, after `✓`. The image, the certificate and the CA come on aligned lines under it.
  The commands to run next come under `Next:`, each on its own line: `ehosctl login`, the command
  that invites a person, and after a move to public certificates the commands that change the
  variables of each repository. A word to replace in a command is in capitals, such as `EMAIL`. A
  script that reads a value from these sentences must read it from its labelled line. `upgrade` of
  the version that runs says that nothing changed after `·`, and gives the command that installs
  it again under `Next:`.
- `ehosctl install`, `upgrade` and `resources add-database` say on stderr, as warnings: a move to
  another host, the addresses still without a certificate, a revision before that failed, the
  settings that `upgrade` did not apply, and a warning of the cluster, such as too little CPU. A
  warning no longer starts with `Warning: `.
- `ehosctl secrets set` and `secrets rotate` refuse a `--from-file` path to a device, such as
  `/dev/tty`, as they refuse a terminal on standard input. A terminal shows what you type.

### Fixed

- `ehosctl init` finishes again. A new Phoenix project locks `idna` 8. With `ehos_app` 0.36.0,
  the new application's `mix deps.get` failed, and `init` stopped before the release files
  ([#1037](https://github.com/EmpoweredHouse/ehos-tools/issues/1037)).
- When `ehosctl server up` could not keep the release that it made the server from, after `up`
  failed, it stopped with an Elixir error. It now says what it could not keep, the command that
  keeps it, and why `up` failed.
- `ehosctl upgrade` and `ehosctl install` keep the databases outside the installation that the
  running EHOS lists, its `dataResources.external`. Before, an upgrade dropped them, and the chart
  refused the upgrade while a resource binding named one. An entry whose managing role is not in
  the Secret `ehos-external-<name>` is left out, with a warning. `ehosctl upgrade` refuses a move
  to an EHOS before 0.30.0 while the running EHOS lists a database outside the installation.

### Security

- An application that `ehosctl init` made before 0.45.0 can have `idna` before 8 in `mix.lock`,
  with the advisory [EEF-CVE-2026-117678](https://osv.dev/vulnerability/EEF-CVE-2026-117678). An
  update of `ehosctl` does not change the application. To fix it:
  1. Move the application's `ehos_app` to the commit and the version of
     [`ehos_app-v0.37.1`](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.37.1),
     as [its README](https://github.com/EmpoweredHouse/ehos-tools/tree/main/packages/ehos_app#on-an-existing-project-and-running-it-again)
     says.
  2. Run `mix ehos_app.install`.
  3. From `ehos_app` 0.36.0 or earlier, do the steps in the notes of
     [`ehos_app` 0.37.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.37.0)
     before step 4. They include a migration, and the old release must stop before it runs.
  4. Do the steps in the Fixed and the Security sections of the notes of `ehos_app` 0.37.1.
- `ehosctl db tunnel` does not show the password of the data session on the terminal. A shared
  screen or a recording showed it. The password is in the password file that `db tunnel` names.
- `ehosctl server tunnel` writes the kubeconfig to a new file that only its owner can read, and
  then puts it in the place of the old kubeconfig. Before, it wrote the cluster's administrator key
  into the old file first. A user who opened that file before could read the new key.
- `ehosctl install` and `upgrade` write `ca.crt`, `install.json` and `secrets-untold.json` so that
  only their owner can read them (mode 0600). A program that runs as another user needs a copy
  of `ca.crt`. `ehosctl server up` and `server tunnel` write `installation.json`, `tunnel.json`,
  `server.tfvars.json` and the previous address of the server in the same way.
- `ehosctl server down` removes the files that an interrupted write left in the directory of the
  installation, such as a copy of the kubeconfig.
- A command that writes a sign-in, the configuration or the files of a data session removes the
  files that an interrupted write left in the same directory more than 1 hour before, if no other
  user can write to that directory. Such a file can hold a copy of a token or of a password.
- `ehosctl` is built with idna 8.0.0, which fixes EEF-CVE-2026-117678, and with public_sufx
  0.8.20261106, which checks a domain against the Public Suffix List in linear time
  ([#1000](https://github.com/EmpoweredHouse/ehos-tools/issues/1000)).

## [0.44.0] - 2026-11-17

### Changed

- **Breaking:** `ehosctl secret` is now `ehosctl secrets`, as `apps`, `builds` and `domains` are.
  `ehosctl secret` is refused as an unknown command. Change it in your scripts.
- **Breaking:** `ehosctl trust` is now `ehosctl trusts`. `ehosctl trust` is refused as an unknown
  command. Change it in your scripts.
- **Breaking:** `ehosctl installation` is now `ehosctl status`, and `ehosctl installation domain`
  is `ehosctl status domain`. The old name differed from `ehosctl installations` by one letter.
  `ehosctl installation` is refused as an unknown command. Change it in your scripts.
- `ehosctl --help` lists the commands in five groups: start, sign in, applications, people and
  access, and the installation. Each command has one sentence there. `ehosctl help <command>`
  gives the detail.
- `ehosctl --version` prints what `ehosctl init` creates an application from, after the version.
  `ehosctl --help` does not print it now. The first line of `ehosctl --version` is the version, as
  before.

### Fixed

- `ehosctl db connect` starts `psql` on your terminal, on Linux and on macOS
  ([ehos-tools#976](https://github.com/EmpoweredHouse/ehos-tools/issues/976)). Before, `psql`
  could not open the terminal, and the data session ended at once. At a terminal,
  `ehosctl db tunnel` also ended the session at once, and now waits until you press Ctrl-C.
  Both need the program `/usr/bin/script`, which macOS and most Linux distributions install.

### Security

- `ehosctl` is built with Plug 1.20.4 in place of 1.20.3, which did not count the framing of a
  multipart part against the `:length` limit of `Plug.Parsers.MULTIPART` (EEF-CVE-2026-120287).

## [0.43.0] - 2026-11-17

### Changed

- `ehosctl init` creates from `ehos_app` 0.36.0, at the commit its tag names, instead of 0.35.0
  ([0.36.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.36.0)). The CI
  of a new application runs `ehosctl` 0.42.0, so its first run passes. With 0.40.0,
  `ehosctl verify` stopped the tests of the application
  ([ehos-tools#958](https://github.com/EmpoweredHouse/ehos-tools/issues/958)). A new project
  also says how the application calls a utility service.
- `ehosctl promotions show` and `ehosctl approve` show a review of its own for a utility service,
  which is a program with no contract
  ([eh-os#1645](https://github.com/EmpoweredHouse/eh-os/issues/1645)). The review says that you
  confirm that the service does what the applications that call it need. It no longer speaks of
  specifications, subscriptions or capabilities. While the promotion waits, it lists the
  applications that ask to call the service in that production environment or have a service
  agreement for it. Under production, it lists the hosts outside the installation that the
  service adds or removes.

## [0.42.0] - 2026-11-17

### Added

- `ehosctl login` keeps the data CA and the gateway CA of the installation from the first sign-in
  on a computer, beyond `ehosctl logout`. A data session needs them. At a later sign-in,
  `ehosctl` takes a CA only if it has the same key, and says so if the key changed.
  `ehosctl db trust-ca FINGERPRINT` takes a CA with a new key, with the fingerprint that the
  administrator of the installation gave you
  ([ehos-tools#924](https://github.com/EmpoweredHouse/ehos-tools/issues/924)).
- `ehosctl db sessions APP --env E` lists the open data sessions of an application in an
  environment, and `ehosctl db sessions --mine` lists your own. `ehosctl db end ID` ends a data
  session now ([ehos-tools#924](https://github.com/EmpoweredHouse/ehos-tools/issues/924)).
- `ehosctl db connect APP --env E` opens a data session and starts `psql` on it, through the data
  gateway of EHOS. The data session ends when `psql` exits. `ehosctl db tunnel APP --env E`
  opens one for another database client, and ends it at Ctrl-C. `ehosctl` makes the password of
  the data session, and sends EHOS only its verifier
  ([ehos-tools#924](https://github.com/EmpoweredHouse/ehos-tools/issues/924)). These commands
  need an installation that runs the data gateway of EHOS. No release of EHOS runs it yet:
  EHOS 0.29.0 does not.
- `ehosctl doctor` shows whether `psql` is there, and if it is version 16 or later, which
  `ehosctl db connect` needs. The exit code of `doctor` does not count it
  ([ehos-tools#924](https://github.com/EmpoweredHouse/ehos-tools/issues/924)).

### Fixed

- `ehosctl install` and `ehosctl upgrade` with public certificates keep the `restricted`
  pod-security labels of the namespace `ehos-acme-dns` while they write the pull credential of
  acme-dns. Before, a run removed them for a short time, or until the next run when it stopped
  there ([ehos-tools#949](https://github.com/EmpoweredHouse/ehos-tools/issues/949)).
- `ehosctl verify` no longer stops an application from starting under `mix test`. Before, each
  program that `ehosctl` started got the variables of the release of `ehosctl`, such as
  `RELEASE_ROOT`. The application took itself for a release and refused `pin_keys: true` in
  `config/test.exs`. A new application failed its first CI run for this reason
  ([ehos-tools#958](https://github.com/EmpoweredHouse/ehos-tools/issues/958)).

## [0.41.0] - 2026-11-16

### Changed

- `ehosctl init` creates from `ehos_app` 0.35.0, at the commit its tag names, instead of 0.34.0
  ([0.35.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.35.0)). A new
  project is pinned to eh-os-contract v0.14.3, so its `ehos.yaml` can be `ehos.yaml/v8` and name
  in `needs.services` the utility services that the application calls. EHOS 0.29.0 or later
  deploys such an application. Its CI runs `ehosctl` 0.40.0.

## [0.40.0] - 2026-11-16

### Added

- `ehosctl approve` and `ehosctl promotions show` list the applications that the approval of a
  utility service also agrees for, when the promotion adds a host, and the hosts that each
  application then reaches. For an application that starts to call a utility service, the review
  lists the hosts of that service. `--json` keeps `callers` and `services_hosts` as EHOS gives
  them. An EHOS that gives neither key shows the review as before. If EHOS refuses the approval
  because the callers changed or because you cannot approve each of them, `ehosctl approve` says
  what to do next.
- `ehosctl verify` checks the repository of a utility service: a program with no contract and no
  Elixir project, whose `ehos.yaml` says `kind: service`. It checks the file against
  `ehos.yaml/v8` without the network, and refuses each key that a utility service cannot give,
  with the reason of EHOS. It then writes the bundle into `_build/ehos.bundle/`, with the manifest
  that EHOS writes from the same file. If you are signed in, EHOS also checks the file, and
  `verify` says if EHOS knows the name already. It refuses the name of an application.
- `ehosctl apps register ehos.yaml` registers a utility service. It writes the manifest from the
  file as `ehosctl verify` does, and sends it. A file whose name ends in `.yaml` or `.yml` is an
  `ehos.yaml`.
- `ehosctl init --service NAME` writes the files of a utility service into the current directory:
  `ehos.yaml`, and `.github/workflows/ehos.yml`, which calls the shared workflow of ehos-tools at
  the commit that the tag of this release names, with the tag beside it. It asks for each value
  that you do not give as an option. It keeps each file that exists, and writes no `Dockerfile`.
- The pipeline of a utility service, `.github/workflows/ehos-service.yml` in ehos-tools, which the
  repository of a service calls. It builds the image from the service's `Dockerfile` for amd64
  and arm64, runs `ehosctl verify`, and registers the build with the installation that
  `EHOSCTL_URL` names: from a pull request, and from `main` once EHOS's trust accepts
  `refs/heads/main`. If the repository variable `EHOS_PREVIEWS` is `true`, it deploys the build of
  a pull request to an ephemeral environment of its own. A release of `ehosctl` releases this
  workflow too.
- `ehosctl verify` puts the OpenAPI file of a utility service into its bundle, as it is, when the
  directory holds `openapi.json`, `openapi.yaml` or `openapi.yml`. The bundle is then
  `ehos.bundle/v2`, and `ehosctl builds register` sends the file with the build.
- `ehosctl builds openapi SERVICE BUILD` downloads the OpenAPI file of a build of a utility service,
  as it came. It writes over no file.
- `ehosctl services list NAME --env ENVIRONMENT` lists the service agreements of a utility
  service, or of an application, in an environment. `ehosctl services agree SERVICE APPLICATION
  --env ENVIRONMENT` lets the application call the utility service there, and
  `ehosctl services withdraw` takes that back. They need EHOS 0.29.0 or later.
- `ehosctl services list` shows the hosts outside the installation that each utility service
  sends data to, as `host:port`, and the side of the application: `not needed`, `waits`, or
  `agreed` with the person who agreed. `--json` adds `hosts`, `application_side` and
  `application_by`. `ehosctl services agree-hosts APPLICATION SERVICE --env ENVIRONMENT --host
  HOST:PORT` agrees for the application to those hosts, and `ehosctl services withdraw-hosts`
  takes that back. If a utility service names a host, its service agreement holds only after
  this agreement. They need EHOS 0.29.0 or later.
- `ehosctl promotions APP` lists the candidates and promotions of an application, with the step
  that the newest attempt is at for each production environment. `ehosctl promotions --waiting`
  lists the promotions that wait for your approval. `ehosctl promotions show ID` shows the review
  of a promotion, as the console shows it before an approval.
- `ehosctl promote APP --candidate ID --env E` asks for the promotion of a candidate to a production
  environment. `--replace ID` withdraws another person's request that waits there, and `--break
  REASON` breaks, on purpose, the applications that read a name the candidate stops publishing.
  `ehosctl promote --withdraw ID` withdraws a promotion that waits.
- `ehosctl approve ID` prints the review of a promotion, asks, approves it, and waits until the
  deployment in production is active. It sends nothing when the review says that you cannot
  approve it. `--yes` approves without the question, and `--no-wait` returns when EHOS decides the
  deployment. `ehosctl refuse ID --reason TEXT` refuses a promotion.

### Changed

- `ehosctl init` creates from `ehos_app` 0.34.0, at the commit its tag names, instead of 0.33.0
  ([0.34.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.34.0)). A new
  project is pinned to eh-os-contract v0.14.2. A developer signs in to it on their own computer,
  with no EHOS, at `/dev/sign-in`. It runs its own PostgreSQL in Docker on port 5435, which
  `mix setup` starts. Its CI runs `ehosctl` 0.39.0.
- `ehosctl deploy` to a production environment, which EHOS refuses as `promotion_required`, now
  says how to deploy a candidate and promote it.

### Fixed

- `ehosctl install` and `ehosctl upgrade` install EHOS 0.29.0 and later, whose keeper runs in
  `ehos-data`: they copy the pull credential into `ehos-data` before the chart. Before, the
  keeper's image was not pulled, and the installation stopped (eh-os D-171).

## [0.39.0] - 2026-11-12

### Added

- `ehosctl upgrade` takes `--allowed-domain` and `--no-allowed-domains`, as `install` does. Before,
  you changed the allowed domains only with `install`, at the version that runs. The domains you
  give replace the list that EHOS has: give each domain that you keep.
- `ehosctl install --skip-port-53-check` continues with a warning when acme-dns on the server does
  not answer on port 53 from your machine. Use it on a network that answers DNS itself, when you
  know that port 53 of the server is open.

### Changed

- When acme-dns or the name servers of the zone do not answer, `install` asks whether your network
  answers DNS itself in about 1.5 seconds at most. Before, that question took about 8 seconds on
  most networks.

### Fixed

- At the end of a move to public certificates, `install` gives the `gh` commands for each
  repository of an application: set `EHOSCTL_URL` when the host changed, and delete
  `EHOSCTL_CA_PEM`. Before, it told each pipeline to take `ca.crt` as `EHOSCTL_CA_FILE`, which the
  generated CI does not read. If you moved with an earlier `ehosctl`, run these commands now: the
  CI of each repository that still has `EHOSCTL_CA_PEM` fails its TLS check.
- `ehosctl server up --public-certificates` refuses the modules of an EHOS release before 0.27.0,
  and changes nothing. Before, `up` succeeded and port 53 stayed closed. The refusal names
  `--version`, as the refusal of `install` for a port 53 that does not answer does now.
- When acme-dns does not answer on port 53, the refusal of `install --public-certificates` says
  if the network of your machine answers DNS itself. It names an old release and a firewall of the
  cloud as causes of a closed port. It and the warning of `--skip-port-53-check` give two `dig`
  commands that tell a closed port from a network that answers DNS itself.
- When no name server of the zone answers the record check of `install --public-certificates`,
  the refusal says if the network of your machine answers DNS itself. Before, it said only that
  each name server gave no answer, also when the records were correct.
- `install --public-certificates` no longer warns that a record of your own under the host sends
  that name away as if it found one. It says what such a record would do.
- `--installation` before the name of a subcommand works, as in
  `ehosctl env --installation staging list`. Before, a command with subcommands refused it there.

### Security

- **Breaking:** `ehosctl server up --ssh-from` refuses a block wider than `/16`, 65,536 addresses.
  Before, it refused only `0.0.0.0/0`, so a block such as `128.0.0.0/1` admitted SSH from half of
  the internet. If a server admits SSH from a wider block, run `ehosctl server up` with a narrower
  one, or with none, before `server tunnel`, `server status` or `server down`. Once the server
  modules refuse the block too, these commands stop at OpenTofu's refusal of the recorded block
  ([eh-os#1487](https://github.com/EmpoweredHouse/eh-os/issues/1487)).

## [0.38.1] - 2026-11-11

### Fixed

- `ehosctl install --public-certificates` no longer stops the DNS resolver of the server. acme-dns
  answers DNS on port 53 of the server's own address alone. Before, it also took port 53 of
  `127.0.0.53`, the DNS resolver of an Ubuntu server, and the server could pull no image. To fix a
  server where this occurred, run `ehosctl install` again: before it pulls an image, it removes
  the earlier Service of acme-dns. If the move to public certificates did not end, run it with
  the options of that move, `--public-certificates` and `--host`, to go on with the move
  ([#887](https://github.com/EmpoweredHouse/ehos-tools/issues/887)).
- If acme-dns's image cannot be pulled because the server cannot resolve the registry's name,
  `install` says that, and tells you to check the DNS resolver of the server. Before, it said
  that `GHCR_TOKEN` was wrong ([#887](https://github.com/EmpoweredHouse/ehos-tools/issues/887)).

## [0.38.0] - 2026-11-10

### Added

- `ehosctl domains`, `domains map`, `domains show` and `domains remove` list, map, show and remove
  the domains of your company that show a production application, as the Domains page of the
  console does. `map` prints the `CNAME` record to make. `domains` and `domains show` exit 1 while
  a domain is not active. They need EHOS 0.27.0 or later, and `ehos.domain.manage` at the whole
  platform ([#853](https://github.com/EmpoweredHouse/ehos-tools/issues/853)).
- `ehosctl installation domain` shows the DNS records that an installation with public
  certificates needs, their state at the last check, and what to change. `--check` makes EHOS
  check them now. It exits 1 while a record is not right. It needs EHOS 0.27.0 or later
  ([#853](https://github.com/EmpoweredHouse/ehos-tools/issues/853)).
- `ehosctl install --allowed-domain <domain>` sets the domains of your company that a person can
  map to an application, and `--no-allowed-domains` removes them all. `install` and `upgrade` keep
  the list that EHOS has. `install` refuses a domain on the Public Suffix List, such as `co.uk`,
  the console's host or a name under it, and allowed domains without public certificates. It
  needs EHOS 0.27.0 or later ([#853](https://github.com/EmpoweredHouse/ehos-tools/issues/853)).
- `ehosctl role-bindings list` and `ehosctl roles` say which role bindings an ephemeral
  environment got from its environment template, who set the role entry, and that such a role
  binding gives no right to grant roles. `ehosctl people agreements` has a column
  **FROM TEMPLATE** when a people agreement came from an environment template, and says that the
  application cannot read the people through it while a deployment by a pipeline is in force, or
  one failed after the active deployment. Each needs an EHOS that gives `from_template`
  ([eh-os D-161](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0161-an-ephemeral-environment-gets-role-bindings-and-a-people-agreement-from-what-its-environment-template-holds-for-its-application-each-set-by-whoever-could-give-it.md),
  [eh-os#1402](https://github.com/EmpoweredHouse/eh-os/issues/1402)).

### Fixed

- `ehosctl install --public-certificates` refuses, before it waits for a certificate, when
  acme-dns on the server does not answer on port 53 from your machine. A server that
  `ehosctl server up` made from an EHOS release before 0.27.0 keeps port 53 closed, also with
  `--public-certificates`. It says what to change when acme-dns cannot pull its image
  ([#827](https://github.com/EmpoweredHouse/ehos-tools/issues/827)).
- `ehosctl install` without `--public-certificates`, on an installation that runs under its own
  CA, removes the ACME issuers, their policy and the certificate of the console that an
  abandoned move left, and says how to remove acme-dns
  ([#840](https://github.com/EmpoweredHouse/ehos-tools/issues/840)).
- A move to public certificates (`ehosctl install --host <host> --public-certificates`) that stops
  while it waits for the certificates of the addresses no longer leaves
  `~/.ehos/<name>/install.json` naming the old host: it names the new host as soon as EHOS answers
  there ([#839](https://github.com/EmpoweredHouse/ehos-tools/issues/839)).
- The wait of a move for the certificates of the addresses names each address under the new
  host, and each of its reads ends after 10 seconds
  ([#841](https://github.com/EmpoweredHouse/ehos-tools/issues/841)).
- `ehosctl install --public-certificates` asks port 53 once more before it refuses, and says
  that acme-dns cannot pull its image after 3 minutes, not 6
  ([#874](https://github.com/EmpoweredHouse/ehos-tools/issues/874)).

### Security

- `ehosctl install --public-certificates` runs acme-dns from an image built with
  `golang.org/x/net` v0.62.0, which fixes CVE-2026-78661, a denial of service through crafted
  HTML, rated HIGH ([#829](https://github.com/EmpoweredHouse/ehos-tools/issues/829)). Run
  `ehosctl install` again on an installation with public certificates to get it.

## [0.37.0] - 2026-11-09

### Added

- `ehosctl people reset-password <person>` makes EHOS mail the person a link that sets a new
  password, as the people page of the console does. It needs an installation that sends mail, and
  EHOS that serves `POST /api/v1/people/:id/password-reset` (eh-os D-163).
- `ehosctl install --host <host> --public-certificates` moves an installation that runs under its
  own CA, at sslip.io or another host, to public certificates at `<host>`. The first run prints the
  DNS records, and EHOS still answers at its old host. The next run gets the console's certificate
  for the new host, and only then moves EHOS to it: each application rolls out once, and at
  another host than before each person signs in again. It refuses while a domain is mapped, and
  when the addresses need more certificates than Let's Encrypt issues in a week.
- `ehosctl env template role-entry list | set | remove TEMPLATE --app APPLICATION` lists, sets and
  removes the role entries of an environment template: a person and a role of the application, for
  its ephemeral environments made from the environment template. `set` takes the person as
  `--to EMAIL` or `--to ID`.
- `ehosctl env template people show | agree | withdraw TEMPLATE --app APPLICATION` shows, gives and
  withdraws a people agreement that an environment template holds for an application, given in
  advance.
- `ehosctl env create --no-role-bindings` and `ehosctl deploy --create-env --no-role-bindings`
  create the ephemeral environment without the role entries and the people agreement of the
  environment template. One flag leaves out both. `--json` of an environment now includes
  `template_entries`, when EHOS gives it.
- `ehosctl deploy --create-env --no-role-bindings` refuses an environment that exists if EHOS made
  it with the role entries and the people agreement of its environment template, and deploys
  nothing.
- `ehosctl env show` says when an environment has no role bindings and no people agreement from
  its environment template.
- `ehosctl install --public-certificates` gives EHOS the values that the seven DNS records hold:
  the server's address, acme-dns's name for the challenge and the two account URIs. An EHOS that
  has the page **Installation**, **DNS records** then shows each record with its state at your name
  servers, and checks them each day. An upgrade while acme-dns does not answer keeps the values the
  installation has.
- `ehosctl install --public-certificates` gets the certificates of the console and each
  application from Let's Encrypt, at a host of your company's own (`--host`). The first run
  installs acme-dns, makes the two Let's Encrypt accounts and prints the seven DNS records to make.
  The next run checks them at your name servers and installs EHOS. A later `install` or `upgrade`
  keeps the public certificates.
- `ehosctl server up --public-certificates` opens port 53 on the server, for acme-dns.

### Changed

- `ehosctl init` creates from `ehos_app` 0.33.0, at the commit its tag names, instead of 0.31.0
  ([0.33.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.33.0)). A new
  project is pinned to eh-os-contract v0.14.0. Its reviews use the `ehos-app` plugin 0.12.0, whose
  skills review a change by their own method, and its review gate refuses while the machine holds
  an older plugin than the project pins. The CI of a new project still runs `ehosctl` 0.36.0.
- `ehosctl install` no longer sends every name under the console's host to Traefik inside the
  cluster: a name with an underscore in a label, such as `_acme-challenge.<host>`, goes to the
  server's resolver. `ehosctl install` also sets cert-manager to check a DNS-01 record through the
  cluster's resolver alone, so cert-manager and Let's Encrypt read the same record, and pins
  cert-manager's HTTP-01 solver image by digest
  ([eh-os#1195](https://github.com/EmpoweredHouse/eh-os/issues/1195)).

### Security

- `ehosctl install` sets each image of cert-manager and trust-manager by the digest of its index,
  not by a tag that can move to a different image. On an existing installation, the next
  `ehosctl install` upgrades both releases once
  ([#805](https://github.com/EmpoweredHouse/ehos-tools/issues/805)).

## [0.36.0] - 2026-11-04

### Added

- `ehosctl deploy --build B --env E --create-env` creates the ephemeral environment `E` of the
  application first if it does not exist, as the deploy page of the console does. `--template`
  names its environment template. EHOS decides and records the creation and the deployment
  separately. If EHOS refuses the deployment, the new environment stays until it expires, and
  `ehosctl` says so. Under `--json`, the answer, or the error, gives the new environment as
  `created_environment`.
- Before `ehosctl deploy` or `ehosctl env create` acts on an environment named
  `<application>-pr-<n>`, it warns that the pipeline of a pull request can deploy to the
  environment and remove it. Under `--json`, there is no warning.
- Under `--json`, the error of a request that EHOS refused holds the code of the refusal as
  `code`, beside `kind` and `message`. A script can match the code, which stays the same when
  EHOS changes the sentence. The field is new: a script that reads `kind` and `message` reads
  them as before. `ehosctl role-bindings bind --json` gives the code of each refused
  role too
  ([refusals](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/refusals.md)).
- If EHOS refuses a new ephemeral environment because the application or the installation has the
  maximum number, `ehosctl` lists the ephemeral environments that count. Each row gives the name,
  the application, the expiry, and the build that runs there: the number and title of its pull
  request as its run stated them, else its ref. The list holds only the environments that you can
  read, at most 20, and says how many more count. Under `--json`, the error holds them as `cap`,
  `environments` and `more`. An EHOS that does not list them yet gives the sentence alone
  ([at the count](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md#at-the-count)).

### Changed

- `ehosctl init` creates from `ehos_app` 0.31.0, at the commit its tag names, instead of 0.30.0
  ([0.31.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.31.0)). The
  browser tab of a new project shows the EmpoweredHouse icon. The endpoint serves the files of the
  design system with `nosniff` and a Content-Security-Policy that runs no script. The CI of a new
  project still runs `ehosctl` 0.35.0.

## [0.35.0] - 2026-11-04

### Changed

- **Breaking:** `ehosctl init` creates from `ehos_app` 0.30.0, at the commit its tag names,
  instead of 0.29.0
  ([0.30.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.30.0)). The CI
  of a new project deploys a pull request to an ephemeral environment only when the repository
  variable `EHOS_PREVIEWS` is `true`. It still checks each pull request and builds its image. If
  the repository names its installation, it registers the build with EHOS, and a person deploys
  the build that they want to try from EHOS's console or with `ehosctl deploy --build`. To turn
  previews on, run `gh variable set EHOS_PREVIEWS --body true`. The CI still runs `ehosctl`
  0.33.0. A project made earlier keeps its previews until the installer replaces its workflow, as
  the notes of `ehos_app` 0.30.0 say.

## [0.34.0] - 2026-11-04

### Added

- `ehosctl login URL` keeps a new installation under the name that the installation gives itself,
  which its console also shows, when you give no `--installation` and the name is free. It needs
  an EHOS that gives the name. When you keep an installation under another name, each sign-in
  tells you its own name, and `--json` gives it as `names_itself`.
- Before a command that acts on an installation runs, `ehosctl` writes that installation to
  stderr, as `Installation: office (https://ehos.office.example)`. If `EHOSCTL_URL` gives the
  address, the line is `Installation: https://ehos.office.example (from EHOSCTL_URL)`. A person
  who works with several installations sees which one. `ehosctl` writes nothing under `--json`,
  when `CI` is set, or when stderr is not a terminal. `login`, `verify`, `versions` and
  `changelog` choose the installation themselves and write no such line.

### Changed

- `ehosctl init` creates from `ehos_app` 0.29.0, at the commit its tag names, instead of 0.28.0
  ([0.29.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.29.0)). The
  project enables the `ehos-app` plugin 0.10.0, which says how a background job that a person
  starts is authorized. Its CI runs `ehosctl` 0.33.0. With `--example`, the page at
  `/entries/new` answers a form that a client changed by hand, and keeps running. `DEVELOPMENT.md`
  says when four eyes holds for a promotion, and its example of `ehosctl env extend` gives `--ttl`
  instead of `--app`. To move a project made earlier, follow the notes of `ehos_app` 0.29.0.

## [0.33.0] - 2026-11-04

### Added

- When EHOS answers `no_route` for a route that it does not have, `ehosctl` says that the command
  needs a later EHOS, and names the version that the installation runs.
- `ehosctl role-bindings roles` shows each platform role in the words of EHOS: what it is for,
  the roles that it includes, where you can bind it, and the capabilities that it grants. It
  needs an EHOS that has `GET /api/v1/role-bindings/roles`.
- `ehosctl role-bindings list` says in its NOTE column when a role binding adds nothing, because
  another role binding of the same person or agent includes its role there.

### Changed

- `ehosctl init` creates from `ehos_app` 0.28.0, at the commit its tag names, instead of 0.27.0
  ([0.28.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.28.0)). The
  project has the Oban queue `events`, so the effects and the timers of the engine run. It enables
  the `ehos-app` plugin 0.9.0, with `/ehos-app:pull-request`, and has the pull request template of
  every EHOS repository. Its CI runs `ehosctl` 0.32.0. With `--example`, the page at
  `/entries/new` shows an error at its field before the person submits. To move a project made
  earlier, follow the notes of `ehos_app` 0.28.0.
- **Breaking:** The last old messages say what to do: a sign-in limit `install` or `upgrade`
  refuses, a release that `server up` cannot keep (by why it failed, and with the version to
  give), and a sign-in no store keeps (with why each store refused). Three refusals of EHOS read
  as eh-os now says them: `unknown_key`, `no_keys` and `no_console`. A script that matches these
  texts must change; the exit codes stay the same.
- **Breaking:** `ehosctl role-bindings`, `ehosctl env template` and `ehosctl env quota set` say
  their help, their results and their errors in shorter sentences, with the words of the console:
  "role binding" and "environment template". Each error says what to do next. A script that
  matches these texts must change; the exit codes and the JSON stay the same.
- **Breaking:** Each other command of `ehosctl` says its help, its results and its errors in short
  sentences, with the words of the console and of the glossary of EHOS. An error says what occurred
  and, where ehosctl knows it, what to do next. No help or message of these commands names a
  decision record or an issue. Each of their pages in `docs/commands/` starts with what it covers
  and ends with the next steps. A script that matches these texts must change, the `reason` of
  `logout --json` included. The exit codes, the options and the keys of the JSON stay the same.

## [0.32.0] - 2026-11-02

### Added

- `ehosctl doctor` checks what `ehosctl server up` needs beyond a cloud account: the GitHub token
  it reads EHOS's releases with (`MISE_GITHUB_TOKEN` or `GITHUB_TOKEN`), and on GCP whether the
  credentials still give an access token and whether the organisation policies
  `compute.requireOsLogin` or `compute.vmExternalIpAccess` would stop `up`. `--gcp-project` names
  the project, instead of `GOOGLE_CLOUD_PROJECT`. When gcloud is installed and GCP credentials
  are present, `doctor` contacts Google for these checks
  ([#657](https://github.com/EmpoweredHouse/ehos-tools/issues/657)).

### Changed

- **Breaking:** `ehosctl init` creates from `ehos_app` 0.27.0, at the commit its tag names,
  instead of 0.25.0
  ([0.26.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.26.0),
  [0.27.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.27.0)). The
  project pins eh-os-contract's release v0.13.1 and enables its plugin's 0.14.3. It enables the
  `ehos-app` plugin's 0.7.0, with `/ehos-app:retro`, and has `docs/platform-issues.md`. It has a
  page at `/entries/new` that records an entry as the person signed in. Its CI runs `ehosctl`
  0.31.0 and checks the binary's SHA-256. To move a project made earlier, follow the notes of
  `ehos_app` 0.26.0 and 0.27.0: 0.27.0's Security section lists the code that eh-os-contract
  0.13.0 asks a project to change.
- **Breaking:** `ehosctl doctor` exits 1 without a GitHub token for EHOS's releases, and does not
  count GCP as an account when its credentials are refused, an organisation policy stops
  `ehosctl server up`, or the project given is not a GCP project ID, which makes GCP incomplete.
  A machine that passed before can now fail
  ([#657](https://github.com/EmpoweredHouse/ehos-tools/issues/657)).

### Removed

- **Breaking:** `ehosctl apps activate` is gone. From EHOS 0.24.0 only a deployment puts a
  version of an application's roles in force, and in production a promotion's: run
  `ehosctl deploy`. `ehosctl apps review` still shows what a version changes against the one in
  force, and is headed by the version and what it is compared with, no longer "Activating".
  `ehosctl apps register` says a version is in force nowhere until a deployment puts it in force.
  The refusal `deployment_required` exits 1, as a refusal of the Gone kind does
  ([eh-os D-154](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0154-the-authority-in-force-in-an-environment-changes-only-with-a-deployment-and-nobody-puts-a-registered-version-in-force-by-hand.md), [#694](https://github.com/EmpoweredHouse/ehos-tools/issues/694)).

### Fixed

- `ehosctl server up` says which file it cannot write when it fails to carry a moved server's
  host key into `known_hosts`. Before, it gave the reason alone, without the file
  ([#535](https://github.com/EmpoweredHouse/ehos-tools/issues/535)).
- `ehosctl login` sends a pushed authorization request with the CA kept for the installation.
  It refuses an installation whose endpoint for these requests is on another host. Before, the
  request went without that CA when the discovery document named such an endpoint. A sign-in to
  an installation with a private CA then failed, and the request could go to another host
  ([#696](https://github.com/EmpoweredHouse/ehos-tools/pull/696)).
- `ehosctl login` follows no redirect when it reads the discovery document and the keys, pushes
  an authorization request, or exchanges the code. It says that the installation redirected the
  request. Before, a 307 or 308 answer sent a pushed request or the code on to the address it
  named, also over plain HTTP. Discovery and the keys followed every redirect. `ehosctl login`
  now fails at an installation that serves its discovery document or its keys through a redirect
  ([#696](https://github.com/EmpoweredHouse/ehos-tools/pull/696)).
- `ehosctl upgrade`, and `ehosctl install` over an earlier EHOS, restart each PostgreSQL cluster
  of EHOS whose pods do not run with the priority class the cluster gives, one at a time, and
  wait until each is healthy again. After an upgrade to EHOS 0.22.0 or later, the governance
  plane's database and each data instance ran without `ehos-platform` until each was restarted by
  hand. The command says first that the console and an instance's applications are down while
  their cluster restarts, usually 1 to 3 minutes each, and prints each restart. A cluster that is
  not healthy is left, and the command says so
  ([#680](https://github.com/EmpoweredHouse/ehos-tools/issues/680)).
- If two commands change `config.json` at the same time, `config.json` keeps the changes of
  both. Examples are two `ehosctl login`s to different installations, or `ehosctl login` and
  `ehosctl installations use`. Before, the second command could remove the installation that the
  first command added, and you had to sign in to it again. While `ehosctl` changes
  `config.json`, the file `config.json.lock` is beside it
  ([#538](https://github.com/EmpoweredHouse/ehos-tools/issues/538)).
- If `ehosctl install` keeps a CA for an installation at the same address while you sign in to
  it with `ehosctl login`, the login keeps that CA. Before, the login wrote back the CA that it
  read before the browser opened, or removed the new CA when there was none. If another command
  removes the installation, or moves it to another address, while you sign in, the login keeps
  the CA it signed in with. The login still replaces the CA when `EHOSCTL_CA_FILE` gives one
  ([#538](https://github.com/EmpoweredHouse/ehos-tools/issues/538)).
- `ehosctl` does not remove a lock that a running `ehosctl` of another user holds, for example
  one started with `sudo -E`. Before, `ehosctl` took that process for one that had ended, and
  both commands could change the same file. If a restart gives the id of a lock that a stopped
  `ehosctl` left to a process of another user, the command fails after 2 minutes and names the
  lock files to remove. A lock file that names the id 0 or a negative id is removed 10 seconds
  after it was written, as an empty one is
  ([#538](https://github.com/EmpoweredHouse/ehos-tools/issues/538)).

- `ehosctl server up` records the path of the key it logs in with, never the key, and
  `server tunnel`, `server status`, `install --switch-traefik`, `upgrade --switch-traefik` and a
  later `up` log in with it unless given another `--ssh-key`; they took `~/.ssh/ehos_oci`. An
  installation `up` has not run on since keeps `~/.ssh/ehos_oci`, and `up` refuses to put that key
  on the server in place of another. `tunnel` and `status` say before they connect when the key's
  `.pub` is not the one `up` put on the server. When the server refuses the key, the error names it
  and says to give the right one with `--ssh-key`, or says that the key `up` recorded is not on this
  machine, not that this machine's address changed
  ([#656](https://github.com/EmpoweredHouse/ehos-tools/issues/656)).

### Security

- A project that `ehosctl init` creates locks `jsv` 0.26.2 instead of 0.25.0, which has advisory
  EEF-CVE-2026-117680, so its first `mix precommit` passes the dependency audit
  ([eh-os-contract#543](https://github.com/EmpoweredHouse/eh-os-contract/issues/543)).

## [0.31.0] - 2026-10-30

### Changed

- **Breaking:** `ehosctl init` creates from `ehos_app` 0.25.0, at the commit its tag names,
  instead of 0.24.0
  ([0.25.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.25.0)): the
  project compiles with Boundary, its `mix precommit` runs `test --warnings-as-errors` and
  `test/callback_docs_test.exs`, its `hex_audit/1` needs Hex 2.6.0, its seed records sample data
  through the contracts' commands, and it enables the `ehos-app` plugin's 0.5.0, with
  `/ehos-app:sample-data` and the rules of
  [T-20](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md).
  Its CI runs `ehosctl` 0.30.0. A project made earlier moves to it as `ehos_app` 0.25.0's notes
  say.

## [0.30.0] - 2026-10-30

### Added

- `ehosctl people github list` says which claims are your own and confirmed by another people
  manager, and keeps `confirmable` in `--json`, where EHOS 0.24.0 and later say it;
  `ehosctl people github confirm` refuses such a claim before asking
  ([eh-os#1092](https://github.com/EmpoweredHouse/eh-os/issues/1092),
  [eh-os D-152](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0152-a-people-manager-confirms-their-own-github-account-only-when-nobody-else-may-and-it-is-recorded-as-a-self-confirmation.md)).
- `ehosctl github list` shows each run's commit, which tells several refused runs on one ref apart
  ([#608](https://github.com/EmpoweredHouse/ehos-tools/issues/608)).

### Changed

- **Breaking:** `ehosctl init` creates from `ehos_app` 0.24.0, at the commit its tag names,
  instead of 0.22.0
  ([0.23.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.23.0),
  [0.24.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.24.0)): the
  project takes `ehos_design` 0.5.0, with the outcome and badge components and `EhosDesign.Mail`,
  and the `ehos-app` plugin's 0.4.0. Its CI runs `ehosctl` 0.29.0, and when EHOS refuses a push's
  build, its warning and run summary name the likeliest cause first. A project made earlier moves
  to it as `ehos_app` 0.24.0's notes say.
- The README keeps installing, the table of commands and building; each command's description is
  a page of its own in `docs/commands/`, linked from the table and part of the reference that
  `mix docs` builds. `ehosctl upgrade` has its row in the table
  ([#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).
- `ehosctl github claim` and `ehosctl people github confirm` say that the only people manager of
  an installation confirms their own claim, as EHOS 0.24.0 and later let them, recorded as a
  self-confirmation; an EHOS before it still refuses it as `self`
  ([eh-os#1092](https://github.com/EmpoweredHouse/eh-os/issues/1092),
  [eh-os D-152](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0152-a-people-manager-confirms-their-own-github-account-only-when-nobody-else-may-and-it-is-recorded-as-a-self-confirmation.md)).
- When EHOS refuses a GitHub Actions job's token, `ehosctl` names the likeliest cause first: the
  GitHub account that started the run is not linked to a person yet. It says how to link it, with
  `ehosctl github list`, `ehosctl github claim <run>`, and another people manager's
  `ehosctl people github confirm` after checking with them that the run is theirs (the only
  people manager confirms their own); the trust's causes follow. The message's first sentence,
  its exit code and `--json` are as they were
  ([#608](https://github.com/EmpoweredHouse/ehos-tools/issues/608)).

### Fixed

- `ehosctl verify` refuses Hex before 2.6.0 before it runs `mix hex.audit`, as a project's
  `mix precommit` does from the `ehos_app` after 0.24.0: before 2.6, an audit whose registry fetch
  failed passed without checking the package, and before 2.5 Hex checked retirements alone
  ([#611](https://github.com/EmpoweredHouse/ehos-tools/issues/611),
  [#537](https://github.com/EmpoweredHouse/ehos-tools/issues/537)). Run `mix local.hex --force`
  in the application's directory.
- `ehosctl server --help` names OVHcloud among the clouds it makes a server in, as `ehosctl server
  up` already does ([#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).

## [0.29.0] - 2026-10-29

### Added

- `ehosctl landscape` without `--env` lists the environments whose landscape you may read, as
  EHOS's console offers them, and draws the one there is when there is only one (with `--json`, the
  list, however long); an EHOS without `GET /api/v1/landscape/environments` is said to need a later
  EHOS, and `--env` names the environment
  ([#546](https://github.com/EmpoweredHouse/ehos-tools/issues/546)).
- `ehosctl verify` runs `mix hex.audit` right after `mix deps.get`, and fails on a package in
  `mix.lock` that is retired or has a security advisory, which `mix deps.get` only prints. It says
  how to acknowledge one that does not reach the application, in `mix.exs`'s
  `hex: [ignore_advisories: [...]]`, which needs Hex 2.5.1 or later. It needs the network:
  `HEX_OFFLINE=1` audits against Hex's cache
  ([#507](https://github.com/EmpoweredHouse/ehos-tools/issues/507)).

### Changed

- **Breaking:** `ehosctl init` creates from `ehos_app` 0.22.0, at the commit its tag names,
  instead of 0.21.0 ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.22.0)):
  the project is on eh-os-contract 0.12.0 and `ehos.yaml/v7`, which EHOS 0.21.0 and later deploy,
  and its CI registers each build it publishes with EHOS 0.22.0 or later and deploys a pull
  request's preview from it (eh-os D-146). The artifact `ehos-deployment` holds `image` and
  `ehos.bundle/`, so the golden path deploys from the bundle, or from a build CI registered
  ([#564](https://github.com/EmpoweredHouse/ehos-tools/issues/564)).
- What `ehosctl install` and `upgrade` say of GHCR, when `GHCR_TOKEN` is missing, the cluster
  holds no pull credential, or GHCR refuses the chart, names the issue it cites with its
  repository, `eh-os#218`, as every issue `ehos_platform` names now is
  ([#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)).
- **Breaking:** the platform's commands run `kubectl` 1.37.1 in place of 1.36.4, and stop until
  it is installed: `ehosctl doctor` says so, and `mise install kubectl@1.37.1` installs it
  ([#528](https://github.com/EmpoweredHouse/ehos-tools/issues/528)).
- `ehosctl install` and `upgrade` warn when the cluster runs a Kubernetes older than 1.37, where
  EHOS's isolation policy, once made again, refuses every new environment's pods until the API
  server restarts. A server made by `ehosctl server up` is moved to 1.37 by hand once, as eh-os
  D-148 says
  ([eh-os#923](https://github.com/EmpoweredHouse/eh-os/issues/923),
  [eh-os D-148](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0148-ehos-runs-on-kubernetes-1-37-a-new-server-gets-it-from-the-modules-and-the-servers-made-before-are-moved-by-hand-once.md),
  [#528](https://github.com/EmpoweredHouse/ehos-tools/issues/528)).
- The `helm` commands `ehosctl install` and `upgrade` suggest when EHOS's release is still being
  changed name the kubeconfig by its full path, `$HOME/.ehos/<name>/kubeconfig`, quoted for the
  shell when it needs to be, not `~/.ehos/…`; and the `EHOSCTL_CA_FILE=` that `install` suggests
  when it cannot keep the installation is quoted the same way
  ([#556](https://github.com/EmpoweredHouse/ehos-tools/issues/556)).
- `ehosctl landscape` counts among what is drawn an application whose active deployment sent no
  graph documents EHOS reads, as EHOS's console draws it since
  [eh-os#1078](https://github.com/EmpoweredHouse/eh-os/issues/1078): "Drawn: ledger, nodocs (no
  graph described)", rather than saying it is not drawn, or that nothing is drawn when it is all
  there is. An answer from an earlier EHOS is shown as before
  ([#540](https://github.com/EmpoweredHouse/ehos-tools/issues/540)).
- `ehosctl` knows the refusals EHOS 0.21.0 and 0.22.0 added to eh-os's `docs/refusals.md`:
  `ephemeral` and `repository_required` (exit code 2), `build_not_found`, `no_room` and
  `already_registered` (1). EHOS's API answers each with a status of that kind already, so nothing
  changes there; an application's answer with one of them now takes its kind too, whatever its
  HTTP status, as the other codes refusals.md names do, all but EHOS's own `revoked`,
  `deployment_identity`, `presented` and `no_console`
  ([#501](https://github.com/EmpoweredHouse/ehos-tools/issues/501)).

### Fixed

- `ehosctl init` formats the new project before its first commit, so a project whose module name
  is 11 characters or longer, such as `OfficeClient`, passes CI's `mix format` gate as generated:
  `phx.new` left one test unformatted. A step of `init` that fails before that commit ends by
  saying how to finish it by hand, formatted and on `main`
  ([#574](https://github.com/EmpoweredHouse/ehos-tools/issues/574)).
- The commands `ehosctl server tunnel` and `server up` suggest hold under any home,
  `/Users/Jane Doe` or `/Users/Jane O'Brien` among them: their paths are quoted for the shell when
  they need to be; `server tunnel` suggests `kubectl --kubeconfig <path>`, which a `:` cannot split,
  and a `pkill -f` that matches the tunnel's ssh master alone, by how it was started, under a home
  with a `+`, `(` or `[` in it too; and when only `<key>.pub` is missing, `server up` suggests
  writing it from the private key with `ssh-keygen -y` rather than making a new one, also when it
  is empty, once `ssh-keygen` succeeded and with `>|`, which a shell under `noclobber` allows, and
  says why it cannot read one it cannot
  ([#566](https://github.com/EmpoweredHouse/ehos-tools/issues/566),
  [#568](https://github.com/EmpoweredHouse/ehos-tools/issues/568),
  [#571](https://github.com/EmpoweredHouse/ehos-tools/issues/571)).
- `ehosctl login` ends its wait for the browser at its timeout: nothing still waiting to be read
  then is answered, a callback included, and a local process that keeps connecting to its port no
  longer keeps it waiting ([#557](https://github.com/EmpoweredHouse/ehos-tools/issues/557)).
- `ehosctl server up` uses the public-address services that answered when another one's ask
  crashes, rather than stopping with an error that names none of them
  ([#544](https://github.com/EmpoweredHouse/ehos-tools/issues/544)).
- `ehosctl install` and `upgrade` run cert-manager, trust-manager and CloudNativePG's operator as
  `system-cluster-critical`, Traefik's class already, which the kubelet's eviction never
  picks. Running as none, they were the first pods the kubelet of a server short of memory
  evicted, before EHOS's own (`ehos-platform`, from EHOS 0.22.0), although EHOS depends on them.
  They also request CPU and memory, 70m and 336Mi among them, so the scheduler keeps room for them
  on the server. They set no limit, so should memory run out before the kubelet acts, the
  kernel's OOM killer still picks them nearly first
  ([#576](https://github.com/EmpoweredHouse/ehos-tools/issues/576)). An installation made with an
  earlier `ehosctl` gets it from its next `upgrade` to another EHOS, or from
  `ehosctl install --installation <name> --version <the version it runs>`; either rolls each of
  the three releases once, cert-manager's webhook among them
  ([#500](https://github.com/EmpoweredHouse/ehos-tools/issues/500),
  [eh-os#1039](https://github.com/EmpoweredHouse/eh-os/issues/1039)).

### Security

- The binary bundles `mint` 1.11.0 and `jose` 1.11.13, which fix every advisory published against
  the versions before them. In `mint`: HTTP response smuggling and unbounded memory over HTTP/2
  (EEF-CVE-2026-94194, EEF-CVE-2026-91043, EEF-CVE-2026-92103). In `jose`, eight, from
  EEF-CVE-2026-65625 to EEF-CVE-2026-65632: among them forged AES-GCM tags, an RSA padding oracle,
  a decompression bomb, a timing leak of an X25519 private key and malleable ECDSA signatures.

## [0.28.0] - 2026-10-27

### Added

- `ehosctl builds register <dir> --image <repository>@sha256:…` registers an image and the
  bundle beside it as a build of the application its manifest names, each file checked against
  its `bundle.json` first. In a GitHub Actions job it states what the checkout and the event say
  of the commit (its first line, author and time, a pull request's number, head and title, and up
  to 100 commits before it), made to fit what EHOS takes so a title never fails a pipeline, and
  elsewhere nothing
  ([T-19](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0019-ehosctl-builds-register-states-what-a-github-actions-job-s-checkout-and-event-say-of-its-commit-and-elsewhere-nothing.md)).
  The checkout needs that history: `fetch-depth: 101`, or `102` on a pull request.
  `ehosctl builds list <app> [--ref REF] [--limit N]` lists an application's builds, newest
  first. Both need EHOS 0.22.0 or later (eh-os D-146,
  [#498](https://github.com/EmpoweredHouse/ehos-tools/issues/498)).
- `ehosctl deploy --build <id | commit>` and `--build latest --ref refs/heads/main`, with
  `--repository owner/name` where builds of more than one repository match, deploy a build the
  application's CI registered, with its own image, manifest and graph documents, and wait for it
  as for any deployment; `deploy --bundle <dir>` deploys an image with a bundle's manifest and
  graph documents in place of `--manifest` and `--graph`, which stay. `--build` needs EHOS 0.22.0
  or later (eh-os D-146,
  [#498](https://github.com/EmpoweredHouse/ehos-tools/issues/498)).
- `ehosctl verify` writes the bundle, `mix eh_os_contract.bundle` into `_build/ehos.bundle/`, when
  the application's `eh_os_contract` has that task, and reads it back as `builds register` would;
  with an earlier one it writes the manifest alone, as before
  ([#498](https://github.com/EmpoweredHouse/ehos-tools/issues/498)).
- `ehosctl deploy --preview` says, in the deploy page's words, the CPU and memory the deployment's
  containers ask for (`needs.compute` of an `ehos.yaml/v7`), or that they take the environment's
  defaults, and whether the environment's quota has room for it with its rollout; `--json` keeps
  `compute` and `room` as EHOS gives them, null from an EHOS that does not say them (eh-os D-143,
  [#481](https://github.com/EmpoweredHouse/ehos-tools/issues/481)).
- `ehosctl env quota show | set | clear` show an environment's quota and limits, give one that is
  not ephemeral its own within the installation's ceiling (`--quota limits.memory=8Gi`,
  `--limits FILE`, `''` giving either back), and give it back the installation's, as the
  console's environment page does; EHOS records each change as `environment_quota.set`. `set`
  warns which applications' next deployment there no longer fits. `ehosctl env show` now prints
  a production environment's quota and limits too: its own, or the installation's (eh-os D-143,
  [#486](https://github.com/EmpoweredHouse/ehos-tools/issues/486)).
- `ehosctl verify` lints: it runs `mix credo` after the compile and before the tests, when Credo
  is among `mix.lock`'s packages, with no flags of its own, as the application's `.credo.exs`
  configures it. An application without Credo is told the lint was left out, and still passes. A
  CI step of an application's own that runs `mix credo` after `verify` can go, unless it passes
  flags `.credo.exs` does not set, such as `--strict`: move them there first. Credo in the lock
  but no task in the test environment, kept for `:dev` alone or removed from `mix.exs` and not
  unlocked, fails `verify`, which says to make it `only: [:dev, :test]` or run
  `mix deps.unlock --unused` ([#505](https://github.com/EmpoweredHouse/ehos-tools/issues/505)).
- `ehosctl env template show` says which applications keep secret defaults on a template: by
  name, with how many secrets, each one whose secrets you may list, and the others counted. `env
  template list` counts them, and `env template remove` refused because secrets hold a template
  says to look with `show`. Against an EHOS older than eh-os #988, `show` says it does not say them (eh-os
  [#988](https://github.com/EmpoweredHouse/eh-os/issues/988),
  [ehos-tools#470](https://github.com/EmpoweredHouse/ehos-tools/issues/470)).
- `ehosctl install` and `ehosctl upgrade` warn, and go on, when EHOS is to send mail through an
  SMTP server with no user: a relay that admits the server by its address admits every application
  on it, so one that names the relay's host under `needs.egress` can send as anyone in the
  company's domain, around its mail agreement. Where applications other than the company's own
  run, give EHOS a relay user (`--smtp-username` with `SMTP_PASSWORD`) and have the relay require
  it rather than admit the server by its address (eh-os D-141,
  [eh-os#984](https://github.com/EmpoweredHouse/eh-os/issues/984)).
- `ehosctl deploy --preview` says, in the deploy page's words, which hosts the deployment reaches
  are the installation's mail server, and keeps `mail_relay` on each `egress` entry under `--json`
  as EHOS gives it, absent from an EHOS that did not check (eh-os D-141,
  [eh-os#984](https://github.com/EmpoweredHouse/eh-os/issues/984)).
- `ehosctl env template list | show | create | update | remove | bind | unbind` manage the
  templates ephemeral environments are made from, as the console's Templates page does: each
  kind of need's resource, the seed profile, whether it is the installation's default, and a
  quota (`--quota pods=10,limits.memory=4Gi`) and limits (`--limits FILE`) of its own, `''` giving
  either back to the installation (eh-os D-98,
  [#224](https://github.com/EmpoweredHouse/ehos-tools/issues/224)).
- `ehosctl env show` prints the quota and limits an ephemeral environment was given when it was
  made, its template's over the installation's, and keeps `quota` and `limits` under `--json`
  ([#224](https://github.com/EmpoweredHouse/ehos-tools/issues/224)).

### Changed

- `ehosctl env list` says `<none>` for an environment's application or template that is not there,
  and for its expiry `never` when it has none and `when EHOS says` when EHOS has not said yet,
  where it left each cell empty, which read as not known
  ([#473](https://github.com/EmpoweredHouse/ehos-tools/issues/473)).
- `ehosctl env show` says `<none>` in its bindings' SCHEMA for a binding with no schema of its
  own, where it left the cell empty, and it and `env bind` read a binding's empty application or
  schema as one not given ([#483](https://github.com/EmpoweredHouse/ehos-tools/issues/483)).

### Security

- When a command fails on an error it did not expect, ehosctl names what failed and no longer prints
  the value the error was raised over: a missing key printed the whole list it searched, which could
  be the environment, a GitHub Actions job's request token in it, into the job's log. Only a missing
  key, with the key alone, a file that could not be read or written, and a `RuntimeError`'s words
  are printed; any other error is named without its value, and so is one in a task a command runs,
  which before ended in a crash report. Nothing printed a value yet. The requests a job's credential
  takes carry only `EHOSCTL_CA_FILE` of its environment in their options.

## [0.27.0] - 2026-10-24

### Added

- `ehosctl landscape` says how many applications running in the environment the reader may not
  see, naming none, from an EHOS that counts them (eh-os D-137, [eh-os#942](https://github.com/EmpoweredHouse/eh-os/issues/942)).
- `ehosctl deploy --preview` says the mail the deployment asks to send through EHOS, to people in
  EHOS's directory only or to any address and with replies to which domains, against what the
  deployment in force asks, in the deploy page's words, and keeps `mail` and `mail_in_force` under
  `--json`; EHOS sends it as far as the mail agreement for the environment allows (eh-os D-140,
  [#452](https://github.com/EmpoweredHouse/ehos-tools/issues/452)).
- `ehosctl mail agreements` lists the applications that ask to send mail through EHOS, in each
  environment, with what each asks and the agreement given, and `ehosctl mail agree <application>
  --env E --level internal|external [--reply-domain D]…` and `ehosctl mail withdraw <application>
  --env E` give, change and withdraw how far one may send there, as the console's Installation page
  does; each needs `ehos.mail.manage` (eh-os D-140,
  [#454](https://github.com/EmpoweredHouse/ehos-tools/issues/454)).

### Changed

- **Breaking:** `ehosctl init` creates from `ehos_app` 0.21.0, at the commit its tag names,
  instead of 0.20.0 ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.21.0)):
  the project is on eh-os-contract 0.10.0, with `eh_os_contract_auth` 0.7, so it can ask in
  `ehos.yaml/v6` to send mail through EHOS 0.20.0 and send it with `EhOsContract.Auth.Mail`; its
  ARCHITECTURE.md says how (eh-os D-140,
  [eh-os#979](https://github.com/EmpoweredHouse/eh-os/issues/979)).

### Fixed

- `ehosctl login` says the sign-in holds until the time `ehosctl whoami` says, not one a second
  or more later when keeping the sign-in takes that long
  ([#257](https://github.com/EmpoweredHouse/ehos-tools/issues/257)).

## [0.26.0] - 2026-10-23

### Changed

- **Breaking:** `ehosctl init` creates from `ehos_app` 0.20.0, at the commit its tag names,
  instead of 0.19.0 ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.20.0)):
  the project is on eh-os-contract 0.9.1, with `eh_os_contract_auth` 0.6, so it can name the hosts
  outside the installation it reaches in `ehos.yaml/v5` and call them through the proxy EHOS 0.19.0
  gives, with `EhOsContract.Auth.Egress`; its ARCHITECTURE.md says how (eh-os D-135,
  [#427](https://github.com/EmpoweredHouse/ehos-tools/issues/427)).

## [0.25.0] - 2026-10-23

### Changed

- **Breaking:** `ehosctl server down` says what is lost before it asks (the server and its disk
  with every database on it, its network, its public address, and that nothing can be brought
  back), with the installation's provider, region and console, and removes nothing until the
  installation's name is typed. A `y`, another name or no answer removes nothing and exits 1.
  `--yes` is taken only with `--installation` on the command line, never from
  `EHOSCTL_INSTALLATION` or the current installation
  ([#430](https://github.com/EmpoweredHouse/ehos-tools/issues/430)).
- `ehosctl server down`, and `up --replace` when it replaces the server, lift GCP's deletion
  protection from the server first, which EHOS's modules turn on from the release that brings them
  ([#430](https://github.com/EmpoweredHouse/ehos-tools/issues/430)).

### Fixed

- `ehosctl install` and `upgrade`, upgrading the releases they install, take back the fields anyone
  changed by hand, such as a `kubectl patch` on Traefik's Deployment, where the upgrade failed and
  the Traefik before it, reading every Secret in the cluster, ran on. They then refuse while
  Traefik may still list every namespace's Secrets or read EHOS's, whatever binding gives it that
  ([#429](https://github.com/EmpoweredHouse/ehos-tools/issues/429)).
- `ehosctl install` and `upgrade` warn when the cluster has less than two CPUs to allocate, where
  an application's deployment can wait for good
  ([eh-os#892](https://github.com/EmpoweredHouse/eh-os/issues/892)).

## [0.24.0] - 2026-10-22

### Added

- `ehosctl graph <application> <deployment>` lists the graph documents a deployment carried,
  its domains', contracts' and process modules', with which deployment it is, its environment and
  state, and whether a later one is active there; `--domain MODULE`, `--contract ID` or
  `--process ID` prints one `graph.v1` document as JSON, as EHOS's console draws it when a reader
  goes down from an application's box in the landscape. `ehosctl landscape` names the deployment
  each application is drawn from, and `--json` keeps EHOS's `deployments`, from EHOS 0.18.0
  ([#403](https://github.com/EmpoweredHouse/ehos-tools/issues/403),
  [eh-os D-134](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0134-a-deployment-also-carries-its-contracts-and-process-modules-graph-documents-and-the-console-opens-an-application-s-domain-from-the-landscape-drawn-from-that-deployment.md)).
- `ehosctl apps review`, `apps activate` and `deploy --preview` name the hosts outside the
  installation a version adds to what the application reaches and removes from it, each
  `host:port` ("hosts outside the installation added: api.example.com:443"), beside the
  capabilities and roles, from an EHOS that reads `ehos.yaml/v5`; before, a change to the hosts
  alone was not named. `--json` keeps `egress_added` and `egress_removed`, empty against an older
  EHOS
  ([#407](https://github.com/EmpoweredHouse/ehos-tools/issues/407),
  [eh-os D-135](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0135-an-application-reaches-a-host-outside-the-installation-only-by-naming-it-in-ehos-yaml-through-a-proxy-of-its-own-that-checks-the-name-in-the-tls-handshake.md)).
- `ehosctl deploy --preview` names, after the needs it binds, the hosts outside the installation
  the manifest reaches ("Hosts outside the installation it reaches: api.example.com:443"), and
  `ehosctl apps show` lists each version's in a column `HOSTS OUTSIDE` once a version names one,
  from an EHOS that says them; `--json` keeps the preview's `egress` and each version's, empty
  against an older EHOS
  ([#408](https://github.com/EmpoweredHouse/ehos-tools/issues/408), eh-os D-135).

### Changed

- **Breaking:** `ehosctl init` creates from `ehos_app` 0.19.0, at the commit its tag names,
  instead of 0.17.0 (notes of
  [0.18.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.18.0) and
  [0.19.0](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.19.0)): the
  project is on eh-os-contract 0.9.0, with `eh_os_contract_auth` 0.5 and the `eh-os-contract`
  plugin 0.9.2. Its CI writes every graph document of the application, its domain's and each
  contract's and process module's, into `ehos.graph/` of the `ehos-deployment` artifact, and a
  pull request's preview sends them with `ehosctl` 0.23.0, so a preview of a project with a
  contract needs EHOS 0.18.0 or later, as does the deployment by hand in `DEVELOPMENT.md`, which
  passes each document, unless it is narrowed to the domain's
  ([#402](https://github.com/EmpoweredHouse/ehos-tools/issues/402), eh-os D-134). A merged pull
  request's preview is kept until it expires, and the CI says so
  ([eh-os#672](https://github.com/EmpoweredHouse/eh-os/issues/672)).
- `ehosctl landscape` lists as drawn an application whose domain publishes and subscribes to
  nothing, as an EHOS that draws a box for every domain answers it (eh-os#900), and it reads that
  answer without `quiet_domains`. With nothing on the wire it says "On the wire: nothing.". When
  nothing is drawn, it now says that no application has an active deployment there that sent a
  domain's graph document EHOS reads; against an older EHOS that names quiet domains, it still
  says that none declares a fact it publishes or subscribes to.

### Fixed

- `ehosctl landscape --env` and `ehosctl trust list | add | remove --app` refuse an empty name,
  `.` or `..` before asking EHOS, as every other command refuses such a name: a proxy that
  resolves dot segments could send the request to another route
  ([#416](https://github.com/EmpoweredHouse/ehos-tools/issues/416)).

## [0.23.0] - 2026-10-22

### Changed

- `ehosctl deploy --graph` takes up to 512 graph documents, a domain's, a contract's or a process
  module's, as `mix eh_os_contract.graph --output-dir` writes them, 32 MiB in all and 1 MiB each,
  as EHOS takes them from eh-os#884 (eh-os D-134); before, it refused more than 16. Before it
  sends the request it says on stderr how many go with the manifest and how many bytes they are
  in all, unless under `--json`, and past a bound it refuses in the words EHOS would answer,
  sending nothing
  ([#402](https://github.com/EmpoweredHouse/ehos-tools/issues/402)).
- **Breaking:** `ehosctl install` and `upgrade` install a Traefik that reads only `ehos-ingress`
  and `ehos-addresses`, no longer every Secret in the cluster, the keys that sign EHOS's
  credentials among them. They install EHOS 0.17.0 or later, refusing an older release before
  anything changes: its console would not answer. Upgrade an installation to 0.17.0 with
  `ehosctl` 0.22 first: from an older EHOS, this one leaves the console and its applications with
  no route from the moment it installs Traefik until it has installed EHOS
  ([eh-os#846](https://github.com/EmpoweredHouse/eh-os/issues/846)).
- **Breaking:** the installation's CA no longer issues a certificate in an environment's
  namespace, where EHOS releases before 0.16.0 kept applications' addresses: such an address's
  certificate is not renewed. The upgrade above, to 0.17.0, moves them first
  ([eh-os#846](https://github.com/EmpoweredHouse/eh-os/issues/846)).
- `ehosctl login` shows EHOS's reason when EHOS refuses the sign-in, after the error's code: for
  a person who may not use EHOS's console, "EHOS did not sign you in (access_denied): this account
  may not use EHOS's console or terminal"
  ([eh-os#831](https://github.com/EmpoweredHouse/eh-os/issues/831)). The reason, here and when
  EHOS's token endpoint refuses, is shown on one line, without the characters a terminal acts on,
  and cut at 200 characters.
- `ehosctl` reads EHOS's refusal `no_console` as a refusal (exit code 3) whatever its HTTP status,
  and so is every refusal eh-os's `docs/refusals.md` names when EHOS's token endpoint or discovery
  answers with it, no longer a failure (1).

### Fixed

- `ehosctl` gives every refusal eh-os's `docs/refusals.md` names its kind's exit code when EHOS's
  API answers with it, no longer the HTTP status's: among them `revoked` (4),
  `deployment_identity`, `presented` and `beyond_rule` (3), a promotion's refusals and
  `readers_not_held` (1), `invalid_email` (2) and `too_many_invitations` (5). An application
  answering with one of them gets the same, except EHOS's own `revoked`, `deployment_identity`,
  `presented` and `no_console`: an application's code of that name is read as its own, of its
  HTTP status's kind. From EHOS's API, those four answered with no message are said in
  refusals.md's sentence (#394).

### Security

- `ehosctl` reads an answer from EHOS's API or an application to 16 MiB at most, and a refusal to
  1 MiB, and prints an error to 64 KiB at most: a broken installation, or something between
  ehosctl and it, could otherwise fill its memory or the terminal (#399).

## [0.22.0] - 2026-10-21

### Changed

- `ehosctl install` and `upgrade` let EHOS's Traefik follow an `ExternalName` Service from its own
  routes too (`IngressRoute`, `IngressRouteTCP`), by which an EHOS that keeps the console's route
  in `ehos-ingress` reaches the console. Such an EHOS needs this `ehosctl` or later: with an older
  one its console does not answer ([eh-os#846](https://github.com/EmpoweredHouse/eh-os/issues/846)).

## [0.21.0] - 2026-10-21

### Changed

- **Breaking:** `ehosctl install` and `upgrade` admit an `ExternalName` Service only in
  `ehos-addresses` and `ehos-ingress`, by an admission policy applied before Traefik, since EHOS's
  Traefik now follows one; and they install nothing while one is in another namespace, naming it.
  Remove it, or give it another type, and run again
  ([eh-os#828](https://github.com/EmpoweredHouse/eh-os/issues/828)).
- `ehosctl install` and `upgrade` let an EHOS that keeps applications' addresses in
  `ehos-addresses` have their certificates issued there, and EHOS's Traefik route to them. Such an
  EHOS needs this `ehosctl` or later: with an older one its applications keep their addresses
  where they were ([eh-os#828](https://github.com/EmpoweredHouse/eh-os/issues/828)).

## [0.20.0] - 2026-10-21

### Added

- `ehosctl apps review` and `deploy --preview` say who may give more when a role others may grant
  grows, or its own grant rule widens, under a rule that does not change: "ledger.clerk may grant
  ledger.auditor, which gains ledger.close_month", and keep it under `--json` as
  `described.grantable_grown`, from an EHOS that says it, none against an older one
  ([eh-os#722](https://github.com/EmpoweredHouse/eh-os/issues/722))
- `ehosctl apps history <app> --env E` lists an application's deployments in an environment, as
  the console's tab shows them: the one in force with where it came from and the promotion that
  brought it, and each before it with how it ended and what came after it, from eh-os 0.14.0 on;
  `--json` keeps `next` and `promotion`, as `apps show --json` now does in its deployments
  ([#366](https://github.com/EmpoweredHouse/ehos-tools/issues/366),
  [eh-os#802](https://github.com/EmpoweredHouse/eh-os/issues/802))

### Changed

- `ehosctl install` and `ehosctl upgrade` take `--switch-traefik`, which switches a server where
  k3s's Traefik runs, as one made from eh-os modules before 0.15.0 does, to EHOS's own Traefik,
  where 0.19.0 could only refuse it; without it they still refuse, and say so. k3s restarts without
  its Traefik, and the console and its applications are down for a few minutes. It needs
  `EHOS_STATE_PASSPHRASE`, and `--ssh-key` when the server was made with a key other than
  `~/.ssh/ehos_oci` ([eh-os#823](https://github.com/EmpoweredHouse/eh-os/issues/823)).
- `ehosctl deploy --json` keeps EHOS's answer to the fields it reads, as `apps history` and
  `deploy --preview` do, so a field a later EHOS adds no longer reaches a script unread
  ([#364](https://github.com/EmpoweredHouse/ehos-tools/issues/364))

## [0.19.0] - 2026-10-21

### Added

- `ehosctl deploy --graph FILE`, once for each of the application's domains, sends its graph
  document with the manifest, which EHOS keeps for the landscape of applications
  ([eh-os D-123](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0123-ehos-takes-each-application-s-domain-graph-documents-with-its-deployment-and-joins-them-into-a-landscape-when-someone-reads-it.md)):
  the body is then `multipart/form-data`, the manifest first. Without `--graph` it is the manifest
  alone, as before. `--graph` with `--preview` is refused, as `--image` is, and so are `--graph -`
  and more than 16 documents.
- `ehosctl landscape --env E` shows an environment's landscape: the applications drawn, each name
  a fact is published under with who publishes it and who subscribes to it, and what the picture
  leaves out; `--json` prints EHOS's answer. It needs an EHOS with
  `GET /api/v1/environments/:name/landscape`
  ([eh-os#791](https://github.com/EmpoweredHouse/eh-os/issues/791)).
- `ehosctl deploy --commit SHA --ref REF` states where the image came from, sent only when given
  and refused before anything is sent in a form EHOS would refuse; `deploy` and `apps show` print
  where a deployment came from beside its digest, from GitHub's token or as stated by its deployer,
  from eh-os 0.14.0 on; `--json` gives `source` with the fields of the kinds it knows, a later kind
  by its `kind` alone, and `null` for one of another shape
  ([#362](https://github.com/EmpoweredHouse/ehos-tools/issues/362),
  [eh-os D-129](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0129-a-deployment-shows-beside-its-digest-the-github-run-its-credential-was-exchanged-for-or-what-its-deployer-states.md))
- `ehosctl role-bindings list` says, of a binding a person made through their application under
  their role's rule, who granted it, through which application and under which rule ("granted by
  grace@example.com through ledger, under the rule of ledger.clerk"), and `--json` keeps
  `granted_by`, `rule` and `through`, absent from an EHOS before them
  ([eh-os#798](https://github.com/EmpoweredHouse/eh-os/issues/798), eh-os D-112); `ehosctl roles`
  says the same of a role someone gave you that way, and `--json` keeps its `grant`
- `ehosctl installation` says which version of EHOS runs, the commit it was built from and when
  it was installed, from an EHOS that says so (eh-os 0.14.0 on); `--json` gives it as `ehos`,
  `null` from an older one ([eh-os#756](https://github.com/EmpoweredHouse/eh-os/pull/756))
- `ehosctl installation` says whether four eyes holds on the installation's promotions, and since
  when, from EHOS 0.14.0, and `--json` keeps `four_eyes`, null from an older EHOS
  ([#354](https://github.com/EmpoweredHouse/ehos-tools/issues/354), eh-os#749).
- `ehosctl role-bindings bind` binds several roles in one place, one request each, and says each
  role's refusal while binding the rest; `role-bindings list --to WHO [--agent NAME]` lists one
  principal's bindings ([#326](https://github.com/EmpoweredHouse/ehos-tools/issues/326),
  [eh-os#703](https://github.com/EmpoweredHouse/eh-os/issues/703))
- `ehosctl apps review`, `deploy --preview` and the promotion's review name the roles whose grant
  rule widens or narrows, from an EHOS that reads `ehos.manifest/v5`, and `--json` keeps
  `grants_widened` and `grants_narrowed`, empty against an older EHOS
  ([eh-os D-112](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0112-a-role-may-grant-roles-of-its-own-application-that-its-contract-names-and-ehos-checks-it-on-the-person-s-credential.md),
  [eh-os#721](https://github.com/EmpoweredHouse/eh-os/issues/721)).
- `ehosctl apps show` lists beside a role the roles its holders may grant
  (`ledger.clerk (may grant ledger.auditor)`), as the console does, and `--json` keeps each role's
  `may_grant`, empty against an older EHOS
  ([eh-os#721](https://github.com/EmpoweredHouse/eh-os/issues/721)).
- `ehosctl server up --provider ovh` makes the server in OVHcloud's Public Cloud, from a release
  whose modules hold `deploy/tofu/ovh`: `--os-cloud` names the entry of OpenStack's `clouds.yaml`
  (`OS_CLOUD`'s, else `ovh`), `--region` the region (`GRA11`) and `--instance-type` the flavor
  (`d2-8`); the project is pinned once the server is made, and `ehosctl doctor` reports the
  entry. No OVHcloud account has run it yet ([eh-os D-127](https://github.com/EmpoweredHouse/eh-os/issues/742)).

### Changed

- **Breaking:** `ehosctl install` and `ehosctl upgrade` install Traefik themselves, in
  `ehos-ingress`, at a version EHOS pins, and refuse a cluster where k3s's bundled Traefik is
  installed ([eh-os#762](https://github.com/EmpoweredHouse/eh-os/issues/762)). <!-- Hold: no release
  until eh-os step 5 switches such a server and makes servers without it; reword this line then. -->
- **Breaking:** `ehosctl server up` makes no server without `--provider` (`oci`, `aws` or
  `gcp`), where it made one in Oracle Cloud: the cloud is the operator's to choose. A server already made keeps the
  provider it was made on, and no other command needs the option
  ([#343](https://github.com/EmpoweredHouse/ehos-tools/issues/343)).
- `--four-eyes` and the README say that a new EHOS 0.14.0 or later runs without four eyes on
  promotions unless it is given, and that an installation keeps what it runs with (eh-os D-128).
- `ehosctl upgrade` says that whoever deployed or asked for a promotion may approve it when the
  installation runs without four eyes and is given no flag, as the chart of EHOS 0.14.0 or later
  keeps it (eh-os D-128), where it said so only after `--no-four-eyes`
  ([#350](https://github.com/EmpoweredHouse/ehos-tools/issues/350)).

### Fixed

- `ehosctl server` no longer counts an installation whose `up` stopped before anything was made as
  a server: `status`, `tunnel` and `down` say it is not made, and `up` asks for `--provider` rather
  than to bring it in line; a damaged `installation.json` makes `up` fail (exit 1) rather than
  refuse the command line ([#345](https://github.com/EmpoweredHouse/ehos-tools/issues/345)).

## [0.18.0] - 2026-10-19

### Changed

- `ehosctl init` creates from `ehos_app` 0.17.0, at the commit its tag names, instead of 0.16.0
  ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.17.0)). The
  project's CI rewrites a pull request's preview comment when it closes, to say the preview was
  removed or expires by itself, and its `preview-remove` job is given `pull-requests: write` for
  it ([#295](https://github.com/EmpoweredHouse/ehos-tools/issues/295)). Its `DEVELOPMENT.md`, and
  the `preview` job when no installation is named, say that a person registers the application
  before its first preview ([#266](https://github.com/EmpoweredHouse/ehos-tools/issues/266)).
  `DEVELOPMENT.md` has the administrator bind the process owner `ehos.registrar` in production
  before the first promotion, a role EHOS has from 0.11.0
  ([#297](https://github.com/EmpoweredHouse/ehos-tools/issues/297)), and downloads the deployment
  artifact into `_build/deploy`, which git ignores, removing an earlier download first
  ([#295](https://github.com/EmpoweredHouse/ehos-tools/issues/295)).

## [0.17.0] - 2026-10-19

### Added

- **`server up` says when the server's address changed**, as a server on Oracle's does once when
  it moves to a reserved address (eh-os D-124). It says to take the old address out of whatever
  admits it, since it may be given to someone else, and names the `--host` the console takes at
  the new one. It requires the server's known host key at the new address, and stops at another.
- **`ehosctl secret list | set | rotate | delete`** (eh-os D-99, D-103,
  [#245](https://github.com/EmpoweredHouse/ehos-tools/issues/245)): an application's secrets, in
  one of its environments (`--env`) or as a template's default (`--template`), as the console's
  application page manages them. `set` reads the value from `--from-file` or from standard input,
  a pipe or a file, never from an argument or a terminal, sends it in the request's body
  alone, and says how many deployments roll to it; `rotate` is `set` under that name. `delete`
  asks first unless `--yes`, and names the deployments that keep a secret in use. No command
  prints a value.
- **`install` and `upgrade` take `--four-eyes` and `--no-four-eyes`** (eh-os D-105,
  [#296](https://github.com/EmpoweredHouse/ehos-tools/issues/296)): whether a promotion to
  production needs a second person. `--no-four-eyes` is for an installation of one person, who
  could otherwise never approve their own promotion. Both keep what EHOS runs with when neither is
  given, a value set by hand with Helm included, so an upgrade between releases from 0.9.0 on no
  longer turns four eyes back on without a word; `upgrade` says when they are off. Refused for an
  EHOS before 0.9.0, which has no promotions.

### Changed

- **`install` and `upgrade` refuse to keep a console's host of sslip.io that names another address
  than the server's** (eh-os D-124), rather than leave the console and every application at an
  address nobody answers. `install --host`, or `upgrade --host`, which `upgrade` now takes, moves
  them, and issues the installation's CA again for the new host, with the same key: replace any
  copy of its certificate you trusted, such as a pipeline's `EHOSCTL_CA_FILE`.

### Fixed

- **`trust add` says what EHOS's `branches` warning means** (eh-os D-121,
  [#307](https://github.com/EmpoweredHouse/ehos-tools/issues/307)): a trust that accepts pull
  requests beside a branch or tag without `--protected` lets anyone who can push such a ref reach
  every preview of the application, and the way to close it is a trust for pull requests alone. It
  printed only "EHOS warns: branches."

## [0.16.0] - 2026-10-18

### Added

- **`install` and `upgrade` give EHOS an SMTP server** (eh-os D-36, eh-os#250,
  [#298](https://github.com/EmpoweredHouse/ehos-tools/issues/298)), so the console's invitations
  arrive by email: `--smtp-host`, `--smtp-port` (587 unless given), `--smtp-username` and
  `--mail-from`, with the user's password from `SMTP_PASSWORD` alone, kept in the cluster's Secret
  `ehos-smtp` for the host and user it was given for; a new one restarts the governance plane. They
  are checked before anything changes, kept from the running EHOS as the sign-in limits are, and
  said by `upgrade`; `--no-mail` stops sending. Settings made by hand with Helm are not kept or
  dropped without a word: `--smtp-host` and `--mail-from` replace them, or `--no-mail` stops them.

## [0.15.0] - 2026-10-17

### Added

- **`verify` runs `mix eh_os_contract.schema --check`** after `mix eh_os_contract.check`, in an
  application that keeps an `eh_os_contract.lock`, as its `mix precommit` and CI do from
  `ehos_app` 0.16.0 ([#274](https://github.com/EmpoweredHouse/ehos-tools/issues/274)): every
  event still reads the rows the lock records. An application without the file is verified as
  before.

### Changed

- `ehosctl init` creates from `ehos_app` 0.16.0, at the commit its tag names, instead of 0.15.0
  ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.16.0)): the
  project is on eh-os-contract 0.7.0, where a duration longer than 100 years no longer compiles,
  with `eh_os_contract_auth` 0.4 and the `eh-os-contract` plugin 0.9.0; its first commit holds
  `eh_os_contract.lock`, which its `mix precommit` and CI check every event against; and its
  sessions end when EHOS ends the person's sign-in, `EHOS_SIGN_IN_ABSOLUTE` (eh-os D-113)
  ([#274](https://github.com/EmpoweredHouse/ehos-tools/issues/274)).

## [0.14.0] - 2026-10-17

### Added

- **`install` and `upgrade` take `--sign-in-absolute` and `--sign-in-idle`** (eh-os D-113): how long a person's
  sign-in to an application lasts, in hours or days, from the sign-in at EHOS and unused. They are checked as
  EHOS's chart checks them before anything changes, and kept from the running EHOS when not given; `upgrade`
  says which it installs with. EHOS has them from 0.10.0: given for an earlier release, they are refused, and
  kept ones are not sent to it. `upgrade` to the version that runs names them in the `install` command it
  suggests.

### Changed

- `ehosctl init` creates from `ehos_app` 0.15.0, at the commit its tag names, instead of 0.14.0
  ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.15.0)): a pull
  request of the new repository is previewed on EHOS with no stored secret, seeded, and promoted to
  production by its process owner; the project is on eh-os-contract 0.6.0 and `ehos.yaml/v4`,
  which EHOS 0.9 and later deploy (eh-os#594).

## [0.13.0] - 2026-10-17

### Added

- `ehosctl trust list | add | remove --app A`: an application's trusts of GitHub repositories,
  whose Actions jobs may deploy to its ephemeral environments with no stored secret (eh-os D-110).
  `add` reads the repository's ids from GitHub, or takes `--owner-id` and `--repo-id`, and prints
  EHOS's warnings about pull requests and tags (#247).
- `ehosctl github list | claim | remove` and `ehosctl people github list | confirm | remove`: a
  person claims their GitHub account from one of their own refused runs, shown with its page on
  GitHub, and a people manager confirms it, warned when someone else claims it too (#247).
- In a GitHub Actions job, `EHOSCTL_URL` names the installation, and a governed command that
  needs a credential exchanges the job's own token for it (`permissions: id-token: write`), with
  no sign-in and nothing kept on the runner (T-18, eh-os D-110); `ehosctl verify` leaves out
  EHOS's check there. A refused exchange says where its reason is recorded and what usually
  causes it (#247).

- `ehosctl env create <name> --app A [--template T] [--ttl 24h]` makes an ephemeral environment
  for an application from a template, and `ehosctl env extend <name> [--ttl 72h]` gives one
  longer; `env list` and `env show` print its application, template and expiry (eh-os D-98,
  #224). In a GitHub Actions job, `env extend` and `env remove` take `--app` too, which the job's
  exchange names where its repository is trusted by more than one application (T-18).

### Changed

- **Breaking:** `ehosctl env remove <name>` sends the environment's name again, as EHOS asks
  (eh-os D-100): typed when asked on a terminal, or given as `--confirm <name>`. Without a
  terminal it asks nothing, so a script that ran it without `--confirm` now exits 2 and removes
  nothing, as does a name typed wrong (#224).
- **Breaking:** `ehosctl env create` makes an ephemeral environment with `--app`, and refuses
  `--type ephemeral` without it, which EHOS now refuses too; `--type` is needed only for another
  type (#224).
- `ehosctl deploy` ends on a deployment EHOS says is `withdrawn` (eh-os D-100), exit 1 and
  `outcome` `withdrawn`, instead of waiting on it until its timeout (#224).

## [0.12.0] - 2026-10-15

### Changed

- `ehosctl init` creates an application from `ehos_app` 0.14.0, at the commit its tag names,
  instead of 0.13.0 ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.14.0)):
  the application serves HTTP/1.1 alone, and a crashed process's report carries less of what the
  process held (#239, #234).

## [0.11.0] - 2026-10-14

### Changed

- `ehosctl init` creates an application from `ehos_app` 0.13.0, at the commit its tag names,
  instead of 0.12.0 ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.13.0)):
  the application logs one JSON object a line in production, with `request_id`, the trace and
  span ids and `correlation_id`, which `ehosctl logs` shows, and sends its traces to the collector
  EHOS names (eh-os#485, #228).

## [0.10.0] - 2026-10-14

### Added

- `ehosctl logs <application> --env E` prints the lines an application wrote in an environment,
  oldest first, as EHOS keeps them, and `ehosctl logs --platform` prints EHOS's own, for whoever
  may read them (`ehos.telemetry.read`). `--deployment`, `--since`, `--grep` and `--limit` narrow
  them, and `--json` prints them as JSON. `--follow` then prints new lines as they come, for up
  to an hour, renewing its credential every ten minutes without losing or repeating a line, and
  says why it stopped (eh-os#478, #223). Needs an EHOS with the logs routes (eh-os#464).

### Fixed

- `ehosctl server up` admits SSH from every public address this machine was seen to leave from,
  asking three services twice each, rather than the one a single service saw. `up`, while it
  waits for SSH, and `up`, `tunnel` and `status`, when SSH does not answer, say which addresses
  are admitted and that a network can leave through more than one, to give each with
  `--ssh-from` (#157).

## [0.9.0] - 2026-10-13

### Changed

- `ehosctl init` creates an application from `ehos_app` 0.12.0, at the commit its tag names,
  instead of 0.11.0 ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.12.0)):
  its `DEVELOPMENT.md` says who deploys and how a developer joins, with no cloud key, through an
  EHOS account with `ehos.application_administrator` for the application (#215).

## [0.8.0] - 2026-10-13

### Added

- `ehosctl server invite <email> [--installation N]`: invites a person on an installation as the
  operator, through the tunnel's kubeconfig and the kubectl EHOS pins, and prints the link that
  signs them in once, within 15 minutes, with what to do with it: it is a password. The first
  person invited while nobody is the platform's administrator becomes it, and a person who has
  joined gets a link that signs them in again, which is how one who forgot their password gets
  back in while the installation sends no mail. The address reaches EHOS as an Elixir string
  literal, checked by parsing it back, so none can run code. Like `status`, it refuses an
  installation no server's state is kept under (#197).

### Changed

- `ehosctl init` creates an application from `ehos_app` 0.11.0, at the commit its tag names,
  instead of 0.10.0 ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.11.0)):
  it opens on a home page of its own instead of Phoenix's welcome page, with `/access` behind
  sign-in, which shows the signed-in person what EHOS gives them (#198).
- `ehosctl server up` makes no new server under a name it was not given, the current
  installation's or `trial`, while another installation has a server: it asks for
  `--installation`, rather than make a second server beside one that may be the one meant (#194).
- `ehosctl install` and `ehosctl upgrade` end by naming `ehosctl server invite <their email>
  --installation <name>` to invite a person, instead of a line of `kubectl` that a `kubectl` of
  asdf's shadowed (#197).

### Fixed

- `ehosctl init` makes the project's first commit on `main`, the branch its CI publishes from,
  instead of leaving the branch to git, which on most Linux distributions names it `master`, where
  CI built nothing to deploy (#190).
- `ehosctl versions` and `ehosctl changelog` take a directory for an application's only when it
  has an `ehos.yaml` or `ehos_app` among its dependencies, not for any Mix project that depends on
  one of EHOS's components, such as eh-os itself; `versions` there shows `ehosctl` and EHOS alone.
  An application without an `ehos.yaml` is said to have none, rather than one that names no
  schema (#195).
- `ehosctl server status | tunnel | down`, `install` and `upgrade` refuse an installation no
  server's state is kept under in `~/.ehos`, before anything runs, and name the installations
  that have one, instead of saying that the name breaks a naming rule or that the server is not
  made: a server made with `mix ehos.server` is often under `trial`, while the current installation
  is named after its host (#194).
- Every command `ehosctl server`, `install` and `upgrade` suggest, such as opening the tunnel after
  `up`, names the installation with `--installation`, so that, run as printed, it reaches the same
  server whichever installation is current by then (#194).

## [0.7.0] - 2026-10-12

### Changed

- `ehosctl init` creates an application from `ehos_app` 0.10.0, at the commit its tag names,
  instead of 0.9.0 ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.10.0)):
  its `.claude/settings.json` enables the `ehos-app` plugin from a marketplace of its own name,
  `ehos-app`, so working on the application no longer moves the copy of the `ehos-tools`
  marketplace that eh-os, ehos-tools and eh-os-contract pin at another tag (#172).

## [0.6.0] - 2026-10-12

### Added

- `ehosctl install [--installation N] [--version V] [--host H]`: installs EHOS, by version, on the
  server under an installation, from the release's image and chart, each by digest, with no checkout
  of eh-os and no digest to copy, pulling the chart with `GHCR_TOKEN`. What runs is recorded in the
  cluster and read from the release's last deployed revision; another version, or the same with
  other digests, is refused, and so is a change while Helm is still on one. The installation is kept
  in `config.json` with the console's address and its CA, so `ehosctl login --installation N` needs
  no `EHOSCTL_CA_FILE` (eh-os#421, #161, #164).
- `ehosctl upgrade [--installation N] [--to V] [--allow-downgrade] [--allow-unrecorded] [--yes]`:
  moves the EHOS on an installation's server to another release, the newest by default, after the
  notes of every release on the way. A downgrade is refused without `--allow-downgrade`, and it asks
  first when a release on the way changes the governance database, of which EHOS keeps no backup.
  An EHOS that `mix ehos.install` installed is matched to a release by its image's digest
  (eh-os#422, #164).
- `ehosctl` is licensed under the Apache License 2.0, as the rest of ehos-tools
  ([LICENSE](https://github.com/EmpoweredHouse/ehos-tools/blob/main/LICENSE)).

### Changed

- **Breaking:** `ehosctl init` creates an application from `ehos_app` 0.9.0, at the commit its tag
  names, instead of 0.8.1
  ([notes](https://github.com/EmpoweredHouse/ehos-tools/releases/tag/ehos_app-v0.9.0)): its skills
  come from the Claude Code plugins `ehos-app` and `eh-os-contract`, which `.claude/settings.json`
  enables, rather than copies in `.agents/skills/`; `ehos.yaml` is `ehos.yaml/v3`, with its schema
  in `deps/` rather than `.ehos/`; `DEVELOPMENT.md` and the rest of the docs describe the
  contract-first cycle and `ehosctl`; and it has a `LICENSE`.
- `ehosctl versions` names `ehosctl upgrade --to <version>` for a newer EHOS (#164).

### Fixed

- An error, a result's words and a platform command's progress are printed with each line that
  holds a character a terminal would act on quoted, that character escaped as `\u{…}`: a failing
  tool's output can hold text a cluster wrote, such as a Helm revision's description, and `server
  status` says what the node reports. Tabs are printed as spaces (#165).

## [0.5.0] - 2026-10-12

### Added

- `ehosctl doctor`: whether this machine can run the platform commands that make a server and
  install EHOS on it. It reports OpenTofu, Helm and kubectl at the versions EHOS is tested with,
  with the `mise install` command for each one missing, `ssh`, the cloud accounts it can see
  (Oracle Cloud, AWS, GCP), named but never printed, and whether `GHCR_TOKEN` is set. It exits 0
  when ready, 1 otherwise, and installs nothing (T-13, eh-os#406).
- `ehosctl login` keeps the CA `EHOSCTL_CA_FILE` names beside the installation, and every later
  command to that installation trusts it, so the variable is needed once, at `login`, and not on
  every command, `ehosctl call` to its applications included. `installations list` says which
  installation has a CA of its own. A `config.json` that holds a CA is refused when anyone but
  you can change it (T-14, #148).
- `ehosctl apps show <application>` says each environment's deployment state beside its
  version: that of the deployment in force (`active`, `activating`), `none`, or `failed:` with
  the start of its failure when the newest deployment there failed after it, read from EHOS's new
  route for an application's deployments in an environment (eh-os#413, #150). `--json` adds each
  environment's `state`, `deployment`, `failed`, `addresses` and `why`. An environment whose
  deployments cannot be read, or every one against an EHOS without that route, is `unknown`,
  with why.
- `ehosctl deploy --no-wait`: returns once the deployment is decided, as `deploy` did before
  (eh-os#413, #150).
- `ehosctl server up | tunnel [--close] | status | down`: makes, reaches, reads and removes the
  server under an installation, in Oracle Cloud, AWS or GCP, with the binary alone. The server is
  made from an EHOS release's OpenTofu modules: the newest the first time, then the release kept
  beside the installation, or the one `up --version` names. The archive is checked against the
  SHA-256 its `release.json` names, and kept once `up` succeeds, so later commands use the same
  modules with no network. `status` reports the node's CPUs, memory and load, with EHOS stopped
  too. A server made with `mix ehos.server` is read in place, and takes the newest release's
  modules (eh-os#415, #153).

### Changed

- **Breaking:** `ehosctl deploy` waits until the deployment is active (eh-os#413, #150). It reads
  its state after two seconds and then further apart, up to every ten, prints each state it
  moves to, and exits 0 once EHOS says it is `active`, 1 when it failed, with its failure, or
  was superseded, and 5 when ten minutes pass first, or when so many deployments were decided
  after it that EHOS no longer lists it, saying how to look later. A read EHOS did
  not answer is tried again; a refusal ends the wait. A script that relied on `deploy` returning as
  soon as EHOS decided the deployment, or on exit 0 for a deployment that then failed, passes
  `--no-wait`. `--json` prints one document at the end, EHOS's answer with the last `state` and
  `failure`, the `outcome` and the `addresses`. Against an EHOS without the route it says it
  cannot follow the deployment there, and exits 0, as before.
- A TLS handshake that fails says to sign in with `EHOSCTL_CA_FILE` set to the installation's CA,
  for a server as for a local EHOS, and names the CA kept for the installation when that one did
  not sign the certificate.

## [0.4.0] - 2026-10-12

### Added

- `ehosctl deploy <application> --env E --manifest F --preview`: what deploying the manifest
  would do, as the console's deploy page shows it before it is confirmed, and deploys nothing:
  both digests and the version in force, whether the deployment registers the application, what
  its authority adds and takes away (in `ehosctl apps review`'s words), whether it also needs
  `ehos.application.register`, each need's binding, what it changes in sign-in and in reading the
  people, and every reason it would be refused. It exits 0 when the deployment would be taken and
  1 when it would be refused (eh-os#373). `--image`, which only deploying needs, is refused with
  it. `--json` prints the preview.
- `ehosctl terminals`: your terminals signed in with `ehosctl login`, newest first, as your
  settings in the console list them: when each signed in, was last used and ends at the latest,
  and its id (ehos-tools#111).
- `ehosctl terminals sign-out <id>`: signs one of your terminals out, as the console does; its
  commands stop within ten minutes.
- `ehosctl people sign-out <email|id>`: a people manager signs out every terminal of a person,
  without disabling them, and is told how many there were.
- `ehosctl apps sign-in list | agree | withdraw <application> [<client>] --env <environment>`:
  the applications whose pages ask for credentials for an application in an environment, and
  those agreed to, and agreeing to or withdrawing one, through EHOS's API, as the application's
  environment tab does (eh-os#374, D-70, ehos-tools#110).
- `ehosctl people agreements` and `ehosctl people agree | withdraw <application> --env
  <environment>`: the applications that ask to read the company's people, and those agreed to,
  and agreeing to or withdrawing one, as the people page does (eh-os#374, D-81).
- EHOS's refusal `not_requested`, of an agreement no deployment in force asks for, exits 1, as a
  conflict does.

### Changed

- `ehosctl init` creates applications from `ehos_app` 0.8.1, at the commit its tag
  `ehos_app-v0.8.1` names, in place of 0.7.0: the generated CI checks the project with
  `ehosctl verify` (0.8.0), which needs the CI App's *Attestations: read*, and the example
  contract's check says 0 errors, 0 warnings, 0 notices (0.8.1).
- **Breaking:** an `EHOSCTL_CA_FILE` that cannot be read, holds no certificate, or holds a
  certificate that does not decode, which 0.3.0 accepted, is refused with exit 2 (`invalid`), as
  another variable `ehosctl` cannot use is; the first two exited 1 (ehos-tools#123).
- Requests to GitHub, which `ehosctl versions`, `ehosctl changelog` and the update notice make,
  no longer read `EHOSCTL_CA_FILE`, on purpose, since it names a local EHOS's CA: they trust the
  system's CAs alone, so behind a TLS-intercepting proxy, add the proxy's CA to the system's
  trust store (ehos-tools#123).

### Fixed

- The update notice and `ehosctl versions` name the command that moves to a newer `ehosctl`,
  `mise use -g github:EmpoweredHouse/ehos-tools@<version>`, in place of `mise upgrade ehosctl`,
  which matches no tool mise knows. A command that names the version also takes a release younger
  than mise's `minimum_release_age`, which `mise use` and `mise upgrade` without a version do not
  see (ehos-tools#124). When the installation does not
  accept this `ehosctl`, the notice points to `ehosctl versions`, which says whether it accepts the
  newest release.
- An `EHOSCTL_CA_FILE` with no certificate in it that decodes, such as a PEM block left empty, is
  named before any connection, `EHOSCTL_CA_FILE=<path> holds no certificate ehosctl can read`; so
  is one with any certificate that does not decode, and a path that is not a regular file of at
  most 1 MiB. OTP's `SSL WARNING` notices, one per connection, no longer reach the
  terminal. A handshake that fails with `unknown_ca` while `EHOSCTL_CA_FILE` is set says that the
  CA in that file did not sign the certificate, instead of telling you to set it (ehos-tools#123).
- `ehosctl versions` names a locked commit that a release's tag names as that release, though
  it has no GitHub release or no `release.json`, as `ehos_app`'s releases before 0.7.0 do: a
  project on `ehos_app` 0.6.0 reads `0.6.0 (9c97894)`, not `9c97894, 194 commits behind 0.8.0`,
  and is offered the move to the newest release. Whether the installation accepts it stays
  `unknown`, with what is known of its `release.json`. Tags GitHub did not list, or listed only
  in part, are said, as releases are. `ehosctl changelog` finds the version in use the same way
  (ehos-tools#122).
- `ehosctl versions`' line that moves an `eh_os_contract` on eh-os-contract's `main` names the
  `ehos_app` release to move to, the newest whose `release.json` admits that release, that the
  installation does not refuse and that is newer than the `ehos_app` in use, or says only to run
  `mix ehos_app.install` again when the one in use admits it, instead of waiting for one
  (ehos-tools#122).

## [0.3.0] - 2026-10-11

### Added

- `ehosctl versions`: for `ehosctl`, the installation's EHOS and, in an application's
  directory, its `ehos_app`, `eh_os_contract` and `ehos_design`, the version in use, whether the
  installation accepts it, the newest release, whether the installation would accept that, and
  the command that moves to it, with a row for the application's `ehos.yaml` and manifest
  (eh-os D-91, ehos-tools#97). What is accepted comes from the installation's `GET /api/v1`,
  what exists from GitHub's releases and their `release.json`, what is in use from `mix.lock`; a
  locked commit that is no release's is said as a commit, with how far it is from the newest
  release. A newer release the installation refuses is shown, with why, and no command moves to
  it. Each source can fail alone (no installation, no GitHub token, offline): what one could not
  say is said, and the command exits 0.
- `ehosctl changelog <component> [--since VERSION] [--web]`: the notes of each release of
  `ehosctl`, `ehos`, `ehos_app`, `ehos_design` or `eh_os_contract` newer than the version in use,
  or than `--since`, newest first; `--web` opens the newest release's page.
- After a command, at most once a day, a notice on stderr that a newer `ehosctl` is released, or
  that the installation the command used no longer accepts this one. Never in CI, under
  `--json`, when stderr is not a terminal, or with `EHOSCTL_NO_UPDATE_NOTICE` set; it never
  changes a command's output or exit code. Its cache is `notice.json` in the user's cache
  directory.
- GitHub's releases are read with `MISE_GITHUB_TOKEN`, else `GITHUB_TOKEN`, sent to
  `api.github.com` alone; without one, `ehosctl` says a token is what is missing.
- A command whose route the installation lacks says that the installation's EHOS, at the version
  it names, is too old for it, and that the operator upgrades EHOS, instead of a bare 404 (exit 1).
- `ehosctl --version` prints, for a build between releases, the commit it was built from on a
  second line.
- `ehosctl verify [--no-test]`: the application in the current directory checked as its CI checks
  it, then by EHOS (eh-os#355, ehos-tools#93). It runs the template's CI gates in order under the
  application's own `.tool-versions`, with `MIX_ENV=test`: the lock check, format, compile with
  warnings as errors, tests, `mix eh_os_contract.check`, and `mix eh_os_contract.manifest` into
  `_build/ehos.manifest.json`. It stops at the first that fails, with exit 1, and then, when an
  installation is chosen, sends `ehos.yaml` and the manifest to `POST /api/v1/ehos-yaml/check`. With
  none chosen, EHOS's check is said to be left out. It submits nothing.
- `Ehosctl.Mise` runs a command under a pinned toolchain with the terminal's own input and
  output, for `init` and `verify`.
- `ehosctl installation`: where the installation runs and what it uses, through EHOS's API, as the
  console's Installation page shows it (eh-os#349, `docs/installation-api.md`, D-90): the
  installation's description, each node's capacity and use, and each environment's and
  application's use against its quota. It needs a platform capability; what EHOS could not read it
  says, and prints the rest (ehos-tools#91).
- `ehosctl audit [--limit N]`, `ehosctl activity [--limit N]` and `ehosctl agents list | create`:
  the audit record inside the scopes where you may read it, what was done in your name or your
  agents', and your agents, through EHOS's API, as the console's Audit, My activity and My roles
  pages show them (eh-os#343, `docs/audit-api.md`). Both lists follow the API's pages up to
  `--limit`, 100 by default and at most 10,000, and say when older rows remain. An agent's name
  used already exits 2; one past a person's 200 agents, `too_many_agents`, exits 1 (eh-os#344).
- `Ehosctl.Pages` follows any of EHOS's lists given in pages, which `people list` used alone.
- `ehosctl role-bindings list | bind | unbind` and `ehosctl apps register | show | review |
  activate`: role bindings, and an application's versions, their review and activation, through
  EHOS's API, as the console's Bindings and application pages do (eh-os#340,
  `docs/role-bindings-api.md`, `docs/versions-api.md`). A person is bound by their email, an agent
  by its owner's email and `--agent`; a version is named by its digest or by the start the console
  shows. `apps activate` prints what it changes, and activates only if the version in force is the
  one its review showed; one activated meanwhile is refused, `changed`, exit 1. `ehosctl apps`
  alone still lists the applications you may use.
- The codes EHOS's role bindings refuse with (eh-os#340): `unknown_role`, `platform_only`,
  `needs_environment` and `wrong_application` exit 2, and `not_in_force` exits 1.
- `ehosctl env list | show | create | remove | bind | unbind` and `ehosctl resources list |
  classify`: an installation's environments and resources through EHOS's API, as the console's
  pages manage them (eh-os#337, `docs/environments-api.md`). A refused bind, create or
  classification is printed in the page's words; `across_the_line` and the `schema_*` codes exit 2,
  `already_set`, `not_classified` and `used` exit 1, and `being_removed` exits 5, since trying again
  works once the cluster has removed the old environment.
- `ehosctl people list | show | invite | rename | disable | enable`: the company's people through
  EHOS's API (eh-os `docs/people-api.md`, #83). A person is named by id or email; `list` follows
  every page, or stops at `--limit`; `invite` says whether the sign-in link was mailed and never
  prints one. No command sets or resets a password.
- `ehosctl deploy <app> --env E --image I --manifest F`: deploys an image, by digest, with its
  manifest sent byte for byte, as the console's Deploy does (#83). A manifest of another
  application, one over 1 MiB, or one that is not UTF-8, from a file or stdin, is refused before
  anything is sent. A refused manifest lists its reasons; a gateway's 5xx or an answer ehosctl
  cannot read says the deployment may have been decided.
- `people` prints a person as people-api.md defines one, under `--json` too, so nothing else an
  answer holds is printed. A list whose next page cannot be followed, or goes back to one already
  read, is an error rather than taken as complete.
- The codes EHOS's people and deployment routes refuse with (eh-os#335): `person_disabled` and a
  deployment's `unbound`, `database_kept`, `name_taken`, `name_too_long`, `host_too_long`,
  `object_taken`, `schema_taken` and `binding_moved` exit 1, and `too_large` exits 2.

- `ehosctl roles [--app A] [--env E]` and `ehosctl apps`: the roles you and your agents hold, and
  the applications you may use, each environment with its address and what your roles grant
  there, from EHOS's API (eh-os `docs/terminal-api.md`, #79).
- `ehosctl call <app> <capability> [fields]`: a command, a recording or a query in an application,
  through `EhOsContract.Plug`'s routes, with the application's own credential (T-10). Fields are
  typed as HTTPie types them (`name=text`, `name:=<JSON>`, `--data`), and every command and
  recording carries a new idempotency key, or the one `--idempotency-key` gives. A capability
  none of your roles grants is still asked for, as each kind in turn, so that EHOS or the
  application refuses it and records the refusal (T-12, eh-os FM-21, P-4).
- `ehosctl credential <app>`: the credential `call` presents, for a script or `curl`. One holding
  a terminal's control characters is not printed, and no header holding a line break or
  non-ASCII is sent.
- When a command may have been done without an answer `ehosctl` can read (the connection broke
  after sending, or a 5xx other than one saying nothing was written), `call` names the
  idempotency key it sent. `--idempotency-key` is checked before anything is sent, and a word
  that starts with `-` is refused as an unknown option rather than sent as a field.
- A refusal from EHOS or from an application is said in eh-os `docs/refusals.md`'s words, and
  exits with its kind's code: 1 also for Not found, Conflict and Gone, 2 for Invalid, 3 for
  Refused, 4 for Not accepted, 5 for Unavailable.

- A renewal and `logout` post to the token and revocation endpoints the sign-in kept when
  `login` read them, so each is one request rather than discovery, the JWKS and the request
  (#76). EHOS's discovery, its issuer included, is checked at `login` and when the kept endpoints
  will not do: when they no longer pass the checks, or answer that they are not there, with a
  redirect, or that the sign-in is over. Then discovery alone is read, without the JWKS, and the
  request is posted again only to another address.

- `ehosctl login [URL]`, `ehosctl whoami` and `ehosctl logout` (eh-os D-89). `login` signs you
  in through your browser, as EHOS's public client `ehosctl`: the code flow with PKCE and a
  redirect to `127.0.0.1` (T-09). It adds or updates the installation and makes it current.
  `whoami` says who you are, where, and until when. `logout` revokes the sign-in at EHOS and
  forgets it here, even when EHOS does not answer.
- The sign-in's refresh token is kept in the system's keychain (macOS's Keychain, or the Secret
  Service through `secret-tool`), or else in a file only you can read, with a warning. Ten-minute
  credentials are cached beside it, and one renewal runs at a time, under a lock (T-08).
  `EHOSCTL_TOKEN_STORE=file` chooses the file, and `EHOSCTL_STATE_DIR` moves the state directory.
- The page the browser comes back to after `login` is the design system's outcome, with its
  stylesheet, tokens and fonts taken from `packages/ehos_design` when `ehosctl` is built. It loads
  nothing.
- `EHOSCTL_CA_FILE`: CA certificates trusted besides the system's, for a local EHOS whose
  certificate comes from a CA of its own (T-09). An installation's address is `https` only.
- `ehosctl installations list | use NAME | remove NAME`: the installations of EHOS you know, under
  names you give them, one of them current, kept in `~/.config/ehosctl/config.json` (T-07). A
  governed command talks to the one `--installation`, `EHOSCTL_INSTALLATION` or the current one
  names.
- `--json` on the commands that can answer in JSON, and stable exit codes per kind of error:
  1 failed, 2 invalid, 3 refused, 4 not signed in, 5 unreachable.
- Every command's help names its plane: governed, platform or local (eh-os D-87).
- The reference documentation, built by `mix docs`.
- Each release carries `release.json`, schema `ehos.release/v1`: its version, the commit it was
  built from, the interfaces it reads (EHOS's API, `ehos.api/v1`, and an application's routes,
  `eh_os_contract.api/v1`) and the `ehos_app` version it creates applications from, written from
  the code by `mix ehosctl.release_file` (eh-os D-91,
  [releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)).

### Changed

- **Breaking:** every call to EHOS's API goes to `/api/v1/…`, its versioned path (eh-os D-91),
  instead of `/api/…`. It needs an EHOS that serves `/api/v1`, eh-os after
  [#362](https://github.com/EmpoweredHouse/eh-os/pull/362); an older one answers 404 to every
  command that calls it. `ehosctl call`'s routes of an application are unchanged.
- A release's notes on GitHub are its section of this changelog, in place of the list GitHub
  generated of every pull request in ehos-tools since the last tag. A tag whose section is missing
  or empty publishes nothing.
- `ehosctl init` creates applications from `ehos_app` 0.7.0, at the commit its tag
  `ehos_app-v0.7.0` names (`7c6d527`), in place of 0.6.0. A new application's contract engine is
  eh-os-contract's release 0.3.0, which `ehos_app` 0.7.0 pins, not the newest commit of its
  `main` (ehos-tools' T-11); `ehosctl --help` says so.
- The command line is read with Optimus (T-06): the help has a new layout, and
  `ehosctl help init`, `ehosctl init -h` and `ehosctl init shop --help` work as
  `ehosctl init --help` does. An unknown command or option now exits with 2, not 1, and so does
  `ehosctl init` with no name or with more than one, or with a name that starts with a dash,
  which is read as an option. A name `init` refuses still exits with 1.

### Fixed

- `ehosctl init` generates under the pinned Erlang and Elixir when another version manager's
  shims (asdf's) come before mise's on the `PATH`. It generated under that manager's versions
  instead, and wrote them into the project's `.tool-versions` and Dockerfile, without a word:
  `mise install` and each Mix step now run with `MISE_ACTIVATE_AGGRESSIVE=1`
  ([#64](https://github.com/EmpoweredHouse/ehos-tools/issues/64)).
- The binary writes UTF-8 whatever the locale. `erl` takes stdio's encoding from it, and where
  it names no UTF-8 (`LANG` unset, as under cron, in CI or over a bare SSH session) wrote
  latin1: an application's "Lista komputerów" printed as "komputer\xF3w". `--json` escapes a
  bidirectional override or a C1 control a server sent, as the words already did.

## [0.2.0] - 2026-10-09

`ehosctl init` creates applications from `ehos_app` 0.6.0 at `9c97894`, in place of 0.5.0 at
`9f3cfd2`.

### Changed

- The template is `ehos_app` 0.6.0. A new application:
  - takes `ehos_design` 0.2.0, with the design system's listbox, `EhosDesign.Components.picker/1`
    and `combobox/1`, and its hooks in the LiveSocket
    ([eh-os D-86](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0086-the-design-system-s-source-holds-component-stylesheets-and-ehos-design-ships-the-components-built-on-them.md));
  - compiles against eh-os-contract's `main`, whose contracts name their id, as `ehos_app` 0.5.1
    made its example contract do.

## [0.1.2] - 2026-10-06

`ehosctl --help` says which template a binary creates applications from. The template is the
same as 0.1.1's, `ehos_app` 0.5.0 at `9f3cfd2`, so what `init` generates is unchanged.

### Added

- `ehosctl --help`, and `ehosctl` alone, print the version and what `init` creates an
  application from: `ehos_app`'s version and commit, Erlang, Elixir, `phx_new` and
  `igniter_new`, and that `eh_os_contract` follows eh-os-contract's `main`. When
  `EHOSCTL_TEMPLATE_SOURCE` replaces the pinned template it says so, and when it holds a value
  `init` refuses it says that instead. `ehosctl --version` still prints the version alone, as CI
  compares it with the tag.

### Fixed

- The READMEs say what to do when `mise use -g` has installed `ehosctl` and the shell does not
  find it: mise is not active in a shell that uses asdf, so its shims go at the end of the `PATH`.
  The root README gives the line for zsh, bash and fish.

## [0.1.1] - 2026-10-06

`ehosctl init` creates an application from `ehos_app` 0.5.0, whose contract engine follows
eh-os-contract's `main` and whose sign-in sits on the root layout. `mise upgrade ehosctl`, or
`mise use -g github:EmpoweredHouse/ehos-tools@0.1.1`, takes it; a project already created moves to
0.5.0 as `ehos_app`'s CHANGELOG says.

### Changed

- The template is `packages/ehos_app` of ehos-tools at `9f3cfd2`, the commit the tag
  `ehos_app-v0.5.0` names, with `"== 0.5.0"` as its requirement, in place of 0.4.0's `9ba6f3e`.
  A new project takes `eh_os_contract` and `eh_os_contract_auth` from eh-os-contract's `main`,
  so two projects created by this release on different days can have different commits of them
  in `mix.lock`
  ([T-05](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)).

### Fixed

- The READMEs say that mise, from 2026.10, reads a release's attestations with the token it is
  given, so a fine-grained token needs *Attestations: read*. CI's `install` job, which failed on
  every platform for v0.1.0 with a 403 from that API, has the permission.
- The READMEs say where mise finds a token: in the environment, or in `gh`'s `hosts.yml`, which
  stays empty when `gh` keeps its token in the system's keyring, as it does by default. Without
  one, GitHub answers mise with a 404 for the private repository. They lead with a fine-grained
  token, and show how to pass `gh`'s for one command.
- The moduledoc of `Ehosctl.Template` says the contract engine is the one part of the template a
  release does not pin: `ehos_app` follows eh-os-contract's `main`
  ([T-05](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)).

## [0.1.0] - 2026-10-03

The first release of `ehosctl`: one binary for each of macOS and Linux, on arm64 and x86_64,
that creates an EHOS application from `ehos_app` 0.4.0. While ehos-tools is private, it is an
internal release: `mise use -g github:EmpoweredHouse/ehos-tools@0.1.0` installs it with a GitHub
token that can read the repository. There is no Homebrew tap yet.

### Added

- The template is `packages/ehos_app` of ehos-tools at `9ba6f3e`, the commit the tag
  `ehos_app-v0.4.0` names, not at the tag: a tag can be moved, and the template is code the new
  project runs as its installer, so a new project's `mix.exs` names that commit, with
  `"== 0.4.0"` as its requirement, so that the project does not compile against another
  release. `init` generates the Phoenix project first, then installs it there with a `sparse:`
  dependency through `Igniter.Util.Install.install/2`, since `igniter.new --install` cannot name
  a subdirectory, and makes the project's first commit last.
- `EHOSCTL_TEMPLATE_SOURCE` takes `path:<absolute path>` or `ref:<git ref of ehos-tools>`.
- `init` writes a dash in the name as an underscore, which an OTP application's name needs, and
  says so. A name ends with a letter or a digit, as the DNS label EHOS makes of it does.
- `ehosctl init <name>` creates an EHOS application from the pinned template:
  - it runs `mix igniter.new --with phx.new` and installs `ehos_app` in the new project, under the
    pinned toolchain through `mise exec`;
  - it keeps the generator's archives in a directory owned by this version;
  - it finishes with Hex installed and `.tool-versions` trusted by mise.
- When `init` fails, it says what is left behind: a half-generated directory to remove before
  trying again, or the one setup step to finish by hand in a project that was generated.
- `ehosctl --version` and `ehosctl --help`.
- `EHOSCTL_TEMPLATE_SOURCE` replaces the pinned `ehos_app` source, for working on the template.
- A Burrito release, one self-contained binary for each of macOS and Linux, on arm64 and x86_64.
- `ehosctl init --help` prints the usage of `init`.
- Linux support on x64 and arm64, next to macOS. CI has an end-to-end job for each of the four
  platforms.
- Releases carry the four binaries and a `SHA256SUMS` file, and install with
  `mise use -g github:EmpoweredHouse/ehos-tools`.

### Changed

- The targets, and so the binaries, are named `macos_arm64`, `macos_x64`, `linux_arm64` and
  `linux_x64`, which mise's `github:` backend recognises.
- The missing-mise message links to mise's installation page instead of suggesting Homebrew.
- `init` gives each step the terminal's own stdin, stdout and stderr, so a prompt can be answered
  and errors stay on stderr.
- The pins:
  - Erlang 28.5.0.7
  - Elixir 1.20.4-otp-28
  - `phx_new` 1.8.14
  - `igniter_new` 0.5.34
  - `ehos_app` `packages/ehos_app` of ehos-tools at `9ba6f3e`, the commit `ehos_app-v0.4.0`
    names, whose generated application signs people in through EHOS and preloads its fonts

### Fixed

- `init` installs the pinned Erlang and Elixir with `mise install --quiet` before its first
  `mise exec`, which cannot install a missing Elixir.
- A failed step is reported with the command that ran it (`mise …`), and a failed toolchain install
  says that mise builds Erlang from source where it has no precompiled build.
- An unexpected exception in the binary ends in one line on stderr and exit code 1, not a kernel
  crash report.
- An archive whose install was interrupted is installed again instead of being taken as present.
- `ehosctl --version x` and the other flags refuse extra arguments with a clear message.
- An empty `EHOSCTL_TEMPLATE_SOURCE` is taken as unset.

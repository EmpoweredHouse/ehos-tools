---
status: accepted
date: 2026-10-09
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-08 · `ehosctl` keeps a sign-in's refresh token in the system's keychain, else in a file only the user reads, and renews it under a lock

## Context and problem statement

`ehosctl login` (Stage 7, step 4, [eh-os#325](https://github.com/EmpoweredHouse/eh-os/issues/325))
signs a person in to an installation of EHOS as a public client, as
[eh-os D-89](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0089-ehosctl-signs-a-person-in-as-a-public-client-through-a-loopback-redirect-and-gets-each-credential-by-renewal.md)
decided. What it gets back is a refresh token that lives up to seven days, and three days unused.
Every governed command after it renews that token for a ten-minute credential of one audience
(EHOS's API, or one application in one environment), and each renewal rotates it: the old token is
spent, and a new one replaces it.

D-89 settles what is kept, and leaves how to ehos-tools: the token goes in the system's keychain
where there is one, else in a file only the person can read, with a warning, and never on a
process's command line. Three things follow that D-89 does not settle:

- **Where each piece lives.** That covers the refresh token, the ten-minute credentials, and what
  `whoami` says.
- **How a binary with no keychain library reaches the keychain.** Erlang has none, as T-06 noted.
- **How two commands are stopped from renewing at once.** A refresh token used twice ends the whole
  sign-in (RFC 9700 §4.14). Two shells each running a command would do exactly that.

[T-07](0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md)
keeps the installations in `config.json` with no secret in it, and leaves the token to this record.

## Decision drivers

1. **The refresh token is never readable by another user**, and never on a command line, which
   any user on the machine can read with `ps`.
2. **A refresh token is never spent twice**, whatever the person runs in parallel.
3. **The binary stays one file with its own runtime** ([T-06](0006-ehosctl-reads-its-command-line-with-optimus-and-writes-to-the-terminal-with-owl.md)):
   no compiled native code per target, no daemon.
4. **It works where there is no keychain**: a server over SSH, a container, a CI runner.
5. **A command does not renew more often than it needs to.** D-89 limits a sign-in to sixty
   renewals a minute, and each one is recorded.

## Considered options

1. **The system's keychain through its own command-line tool, else a file; credentials cached in a
   file; an exclusive-create lock file around each renewal**
2. **A file only**, `0600`, for the refresh token and the credentials alike
3. **A native keychain library**, such as Rust's `keyring` through a NIF
4. **A file encrypted with a key from a passphrase**

## Decision outcome

Chosen option: **"The system's keychain through its own command-line tool, else a file"**. The
token is kept where the person's other secrets are, and the binary stays one file (drivers 1
and 3). Where there is no keychain the file is the fallback, said aloud (driver 4).

- **The state directory.** It is `$EHOSCTL_STATE_DIR` if set, else `$XDG_STATE_HOME/ehosctl`, else
  `~/.local/state/ehosctl`, on macOS too, as T-07 places the configuration. `ehosctl` creates it
  `0700`, and refuses an existing one that is not the user's alone: owned by another user, or that
  others can read or write. A file is created before it is made `0600`, and another user who could
  open it in between would keep it open. For an installation
  named `<name>` (T-07) it holds:
  - `<name>.json`, `0600`: the sign-in. That is where its refresh token is kept, when it was last
    renewed, and the cached credentials, each with its audience and its expiry. It is written whole
    to a temporary file and renamed over the old one.
  - `<name>.token`, `0600`: the refresh token, when it is kept in a file.
  - `<name>.lock`: present only while a renewal runs.
- **The keychain.** One item per installation, its service `ehosctl:<url>`, its account `<name>`.
  - On macOS, `security`. The item is added with `add-generic-password -U … -X <hex>`. That line
    goes to `security -i` on its standard input, so the secret is never on a command line. It is
    read back with `find-generic-password -w`, which prints it to `ehosctl` alone.
  - On Linux, the Secret Service, through `secret-tool`. `store` reads the secret from its
    standard input, and `lookup` prints it.
  - An Erlang port cannot close a program's standard input and still read its exit status. So the
    secret is written by `/bin/sh`'s built-in `printf` into a pipe to the tool. It reaches that
    `sh` in an environment variable, which only the same user and root can read, unlike a command
    line.
- **Choosing the store.** `EHOSCTL_TOKEN_STORE=file` chooses the file. Otherwise `login` uses the
  keychain if there is one: always on macOS, and on Linux when `secret-tool` is on the `PATH` and
  stores the item. Failing that, it keeps the file and says so on stderr: no keychain was found,
  the sign-in is kept in this file, and only you can read it. The store used is written in
  `<name>.json`, so every later command reads the token from where `login` put it.
- **Credentials are cached** in `<name>.json`, one per audience, until thirty seconds before they
  expire. A command that needs one takes it from there, and renews only when there is none. So a
  burst of commands costs one renewal per audience every ten minutes (driver 5). A credential
  lives ten minutes and names one audience, so it gets the file's protection and not the
  keychain's: one keychain call per command would cost more than the credential is worth.
- **One renewal at a time.** A renewal creates `<name>.lock` with an exclusive create
  (`O_EXCL`), with the process's id in it. It holds the lock while it asks EHOS and stores the
  rotated token, then removes it. Another command that finds the lock waits for up to thirty
  seconds, then reads `<name>.json` again. If the first command cached a credential for the same
  audience, the second uses it and does not renew. `logout` takes the same lock.
  - A lock is removed only by the command that holds it: the file carries a random tag beside the
    process id, and is removed only while it still holds that command's own.
  - A lock whose process no longer runs is broken, one breaker at a time. A breaker creates
    `<name>.lock.break` exclusively, reads the lock again, and removes it only if it is still the
    dead one. Without that, two commands that both found the lock stale could each remove it and
    take it in turn, and spend one refresh token twice. The rotated token is stored before the credential is cached: a
  credential without its token would be a sign-in already lost.
- **What `whoami` says**, kept beside the URL in `config.json` as T-07 foresaw: who signed in (the
  ID token's `sub`, and its `email` if EHOS granted it), when, and until when. The limit is seven
  days from then. The three days idle are counted from `<name>.json`'s last renewal. These are
  D-89's limits, which EHOS does not publish. They are not secret, and `installations list` can
  show them without reading the token store.
- **Forgetting.** `logout` revokes the refresh token at EHOS, then deletes the keychain item or the
  token file, the sign-in file and the `sign_in` in `config.json`. It does all of that even when EHOS
  is unreachable, and says so. A renewal that EHOS answers with `invalid_grant` forgets the same
  way, since that sign-in is over.

### Consequences

- Good, because on a laptop the token is where the person's other secrets are: locked with their
  session, and shown and deletable in Keychain Access or Seahorse.
- Good, because no command line ever carries the token, and a second user on the machine can read
  neither the token nor the credentials.
- Good, because two shells cannot spend one refresh token twice, and a script that runs fifty
  commands renews once per audience every ten minutes, not fifty times.
- Bad, because `ehosctl` depends on two programs it does not ship. `security` is part of macOS,
  but `secret-tool` is a package (`libsecret-tools`) that a Linux machine may not have.
  Mitigation: without it, the file is used and the person is told.
- Bad, because the secret passes through `sh` in an environment variable. Mitigation: only the
  same user and root can read a process's environment, and both can already read the keychain or
  the file. The `sh` lives only as long as the write.
- Bad, because ten-minute credentials are in a file, not the keychain. Accepted: each lives ten
  minutes and opens one audience, and the file is `0600` in a `0700` directory.
- Bad, because a lock file outlives a process killed while it held it. Mitigation: a lock whose
  process is not running is removed, and the error names the file. A process id reused by
  another program keeps the lock for the thirty seconds a waiter gives up after.
- Bad, because a renewal that EHOS answered but whose answer was lost, to a dropped connection,
  leaves `ehosctl` holding a spent token. The next renewal ends the sign-in, and the person signs in
  again. Accepted: this is RFC 9700's rule working as meant, and the lock rules out the common case,
  two commands at once.
- Bad, because the keychain item is named by the installation's name and URL, so two
  configurations (`EHOSCTL_CONFIG_DIR`) that sign in to the same URL under the same name share
  one item. Mitigation: a second identity takes a second name (T-07), or
  `EHOSCTL_TOKEN_STORE=file` with its own `EHOSCTL_STATE_DIR`.
- Bad, because `ehosctl installations remove` is on the local plane and never reads the token
  store, so it leaves a sign-in where it is. Mitigation: its help says to run `ehosctl logout`
  first. The sign-in ends by its own limits, and a later `login` under that name replaces it.
- Neutral: `whoami`'s "until" is D-89's limits as `ehosctl` knows them. If EHOS changed them,
  EHOS would still decide each renewal.

### Confirmation

- Tests in `packages/ehosctl`, with the keychain behind `Ehosctl.TokenStore` and a fake in its
  place:
  - the store is chosen as above, and `EHOSCTL_TOKEN_STORE=file` writes `<name>.token` as `0600`
    in a `0700` directory, with the warning;
  - the commands handed to `security` and `secret-tool` carry no secret in their arguments;
  - a second renewal waits on the lock, then uses the credential the first cached, so EHOS sees one
    renewal;
  - a stale lock is removed;
  - `invalid_grant` forgets the sign-in, and `logout` forgets it with EHOS unreachable.
- `Ehosctl.CommandTest` fails when a command outside the governed plane reaches the token store.

## Pros and cons of the options

### The keychain through its own tool, else a file

- Good, because it is what D-89 asked for, with no native code in the binary.
- Good, because `gh` does the same: the keyring where there is one, a file otherwise.
- Bad, because it depends on programs outside the binary, and passes the secret through a shell's
  environment.

### A file only

- Good, because it is the simplest, and what kubectl's `~/.kube/config` and gcloud's credential
  files do.
- Bad, because D-89 chose the keychain where there is one (the user's choice, 9 October 2026), and a
  seven-day token in a file is readable by anything the person runs, a backup included.

### A native keychain library

- Good, because it calls the keychain's API directly, with no program and no shell in between.
- Bad, because no maintained Elixir package does this. A NIF over Rust's `keyring` would have to
  be compiled for each of the four Burrito targets and shipped in the binary, which is the build
  T-06 avoided.

### An encrypted file

- Good, because it works the same everywhere.
- Bad, because the key needs a passphrase typed for every command, or a place of its own, which
  is the keychain again.

## More information

- Decided under Stage 7's plan, step 4, and accepted by Emil on 9 October 2026, on
  [eh-os#325](https://github.com/EmpoweredHouse/eh-os/issues/325).
- Stage 7's plan, step 4: <https://github.com/EmpoweredHouse/eh-os/blob/main/docs/plans/stage-7-ehosctl.md>.
  The decisions as they were made are on [eh-os#325](https://github.com/EmpoweredHouse/eh-os/issues/325),
  and the pull requests are under [ehos-tools#75](https://github.com/EmpoweredHouse/ehos-tools/issues/75).
- gh: `gh auth login` keeps its token in the system's keyring, and in `hosts.yml` with
  `--insecure-storage` or where there is no keyring.
- RFC 9700 §4.14 (refresh token rotation and reuse), RFC 8252 (native applications).
- Revisit if a maintained Erlang or Elixir keychain library appears, if `ehosctl` is supported on
  Windows, or if EHOS publishes a sign-in's limits.

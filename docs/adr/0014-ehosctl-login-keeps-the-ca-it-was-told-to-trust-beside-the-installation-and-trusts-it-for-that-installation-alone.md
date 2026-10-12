---
status: proposed
date: 2026-10-12
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-14 · `ehosctl login` keeps the CA it was told to trust beside the installation, in `config.json`, and trusts it for that installation's commands alone

## Context and problem statement

An installation of EHOS on a server has a certificate from a CA of its own, the installation's
(eh-os D-79, [INSTALLING.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md)
§3), which no system trusts. [T-09](0009-ehosctl-signs-in-with-oidcc-and-answers-the-browser-on-a-loopback-socket-of-its-own.md)
gave `ehosctl` one way to trust such a CA: `EHOSCTL_CA_FILE`, a PEM file trusted besides the
system's CAs, read again by every command. It was written for a local EHOS, the k3d cluster, whose
developer exports the variable in the shell they work in.

Deploying TaxVision to Stage 10's server showed what that costs an operator of a server
([#148](https://github.com/EmpoweredHouse/ehos-tools/issues/148)): `login` with the variable
signs in, `whoami` works without it, and every command that talks to the installation (`env
list`, `versions`, `deploy`) then fails the handshake until the variable is set again, with an
error that speaks of "a local EHOS". A person who works with two installations, each with its own
CA, has to remember which file goes with which name.

[T-07](0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md)
keeps what `ehosctl` knows about an installation beside its URL in `config.json`, and carries what
it does not know through a rewrite untouched. This record decides what `login` keeps of the CA,
where, and which requests trust it. eh-os Stage 13's `ehosctl install` will write the same entry
for the installation it makes, so its operator signs in with no variable at all.

## Decision drivers

1. **The CA is given once**, when the installation is added, and never again for that
   installation.
2. **Trust stays narrow**: a CA one installation needs is trusted for that installation's commands,
   never for GitHub, and never for another installation.
3. **No secret in `config.json`** (T-07): a CA's certificate is public, but nothing that signs or
   authenticates goes there.
4. **Nothing else to keep in step**: the entry still works when the file it came from moves, is
   removed, or was a temporary copy.
5. **The variable keeps working as it does**, for scripts and for the k3d cluster.

## Considered options

1. **`login` keeps the certificates `EHOSCTL_CA_FILE` named, as PEM, in the installation's entry
   in `config.json`**
2. **`login` copies the file beside `config.json`** (`<config dir>/ca/<name>.pem`) and the entry
   names it
3. **`login` keeps the path `EHOSCTL_CA_FILE` named** in the entry
4. **`ehosctl` fetches the CA from the installation** the first time it connects and asks the person
   to confirm its fingerprint, as `ssh` does
5. **No change**: the README says to export the variable, or to keep it with direnv

## Decision outcome

Chosen option: **"`login` keeps the certificates as PEM in the entry"**, because the CA is given
once (driver 1), the entry stands on its own (driver 4), and a certificate is not a secret
(driver 3).

- **What is kept.** When `login` runs with `EHOSCTL_CA_FILE` set and signs in, the installation's
  entry gets `"ca"`: the certificates the file held, each decoded and encoded again as PEM, so
  nothing else in the file is copied. A `login` without the variable keeps the entry's `"ca"`, and
  trusts it for its own sign-in. A `login` that moves a name to another URL drops it, as it drops
  the sign-in.

  ```json
  "staging": {
    "url": "https://ehos.92-5-148-138.sslip.io",
    "ca": "-----BEGIN CERTIFICATE-----\nMIIB…\n-----END CERTIFICATE-----\n",
    "sign_in": {"subject": "…", "email": "…", "signed_in_at": "…", "expires_at": "…"}
  }
  ```

- **Which requests trust it.** Every request a command makes for the installation it talks to:
  the one `--installation`, `EHOSCTL_INSTALLATION` or the current one names, to EHOS and to that
  installation's applications, as the variable was trusted. It is added to the system's CAs and to
  the variable's, never in their place. Requests to GitHub trust the system's CAs alone, as they do
  now.
- **Seeing and removing it.** `installations list` has a column that says which installation has
  a CA of its own (`"ca": true` in `--json`). A CA that changed is replaced by signing in again
  with the variable set to the new one. Neither `logout` nor a `login` without the variable drops
  it: `installations remove`, then `login`, does.
- **When the handshake fails**, the error names the CA that was trusted: the variable's file, or
  the one `ehosctl` keeps for the installation, by name. With neither, it says to sign in with
  `EHOSCTL_CA_FILE` set, which `login` then keeps.
- **Reading it.** A `"ca"` that is not a string, or is larger than the 1 MiB `EHOSCTL_CA_FILE`
  may be, is a malformed `config.json`, refused as T-07 refuses one; one that holds no certificate
  `ehosctl` can decode stops the command that would trust it, saying to sign in again. A
  `config.json` with a CA in it that someone else could change is refused (see Consequences).
  Older `ehosctl` versions carry `"ca"` through a rewrite and do not use it, so the file's
  `version` stays 1.

### Consequences

- Good, because an operator gives the server's CA once, at `login`, and every later command to that
  installation works in any shell.
- Good, because two installations with two CAs each trust their own, and nothing else does.
- Good, because `ehosctl install` (eh-os Stage 13) can write the same entry for the installation it
  makes, and its operator then needs no variable at all.
- Bad, because a person who exports `EHOSCTL_CA_FILE` for the k3d cluster and signs in to another
  installation in the same shell keeps the k3d CA for it. Accepted: it only adds a CA the person
  already trusts, for that installation's requests; `installations list` shows it, and
  `installations remove` followed by a new `login` clears it.
- Bad, because whoever can write `config.json` could add a CA and so read every token sent to that
  installation's host from where they answer for it; before, changing the URL broke the sign-in
  instead. Mitigation: a `config.json` that holds a CA is read only when it, followed through any
  link, and the directory it is in are the user's and writable by no one else, checked on the file
  read; it is refused otherwise, saying so, and a CA is not written through a link to such a file.
- Bad, because a CA that rotates leaves the kept one stale, and the handshake fails until the
  person signs in again. Mitigation: the error names the kept CA and says to sign in with the new
  one.
- Bad, because a PEM block in JSON is one long line with `\n` in it, less pleasant to read than a
  `.pem` file. Accepted: `jq -r '.installations.staging.ca' config.json` gives the file back, and
  nobody needs to edit it.
- Neutral: the developer's k3d cluster is unchanged; its CA can be given once at `login` like any
  other, or through the variable as before.

### Confirmation

Tests in `packages/ehosctl`:

- `Ehosctl.LoginTest`: a `login` with `EHOSCTL_CA_FILE` keeps exactly its certificates in the
  entry; a `login` without it trusts and keeps the entry's CA; one that does not finish keeps
  none; a `login` that moves the name drops it, and ends the old sign-in trusting the old CA.
- `Ehosctl.GovernedTest`: a governed command, and one that chooses its installation, trusts the
  kept CA of the installation it talks to and not another's.
- `Ehosctl.SignInTest`: a certificate from the kept CA is trusted with no variable set; a kept CA
  that does not decode is refused by name; a failed handshake names the kept CA.
- `Ehosctl.GitHubTest`: a request to GitHub trusts neither the variable nor a kept CA.
- `Ehosctl.ConfigTest`: a `"ca"` that is not a string or is too large is refused, one is carried
  through a rewrite, a name moved to another URL loses it, and a file or directory others can
  write to is refused when it holds one.
- `Ehosctl.CallTest`: the request to the application carries the kept CA.
- `Ehosctl.InstallationsTest`: `installations list` says which installation has its own CA.

## Pros and cons of the options

### PEM in the entry

- Good, because the entry is whole on its own: copied, backed up or moved, it still works.
- Good, because `config.json` is written whole and renamed (T-07), so the CA and the URL it goes
  with can never disagree after a write.
- Bad, because the file grows by about a kilobyte for each installation with its own CA, and reads
  less easily.

### A copy beside `config.json`

- Good, because the copy is a `.pem` file `openssl` and `curl --cacert` read as they are.
- Bad, because it is a second file to write, rename with the installation and remove with it, and
  a crash between the two writes leaves an entry naming a file that is not there, or a file no
  entry names.

### The path `EHOSCTL_CA_FILE` named

- Good, because nothing is copied, and a CA rotated in place is picked up.
- Bad, because the path breaks when the file moves or was temporary, and a file anyone else can
  write to becomes a CA `ehosctl` trusts long after the person forgot it (driver 4).

### Fetched from the installation, confirmed by fingerprint

- Good, because no file is needed at all.
- Bad, because it asks a person to judge a fingerprint they cannot check against anything, which
  people confirm without reading, and an unauthenticated first connection is where an attacker in
  the middle would answer. The CA is already in the operator's hands (`~/.ehos/<name>/ca.crt`).

### No change

- Good, because there is nothing to build.
- Bad, because every operator of a server meets it on their second command (#148).

## More information

- Decided under [#148](https://github.com/EmpoweredHouse/ehos-tools/issues/148), found under eh-os
  Stage 6's step 3, and done during eh-os Stage 13, whose `ehosctl install` will write the same
  entry.
- Extends [T-07](0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md)
  with a field beside the URL, without changing its file, location or `version`, and
  [T-09](0009-ehosctl-signs-in-with-oidcc-and-answers-the-browser-on-a-loopback-socket-of-its-own.md)'s
  `EHOSCTL_CA_FILE`, which keeps its meaning.
- Revisit if an installation's CA starts to rotate on a schedule shorter than a sign-in's life, or
  if EHOS publishes its CA somewhere a client can authenticate it.

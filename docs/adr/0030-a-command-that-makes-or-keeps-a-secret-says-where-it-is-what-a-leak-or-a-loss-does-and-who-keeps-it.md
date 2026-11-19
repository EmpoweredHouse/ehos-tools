---
status: proposed
date: 2026-11-19
decision-makers: []
consulted: []
---

# T-30 · A command that makes or keeps a secret says where it is, what a leak or a loss does, and who keeps it, in the shapes of T-28 and from one list of kinds

## Context and problem statement

`ehosctl` and `ehos_platform` make and keep about twenty secrets: the state passphrase and the
encrypted state of a server, the kubeconfig that `server tunnel` writes, the pull credential made
from `GHCR_TOKEN`, the Let's Encrypt account keys, the refresh token of a sign-in, the password of a
data session, and others. The inventory on
[#1013](https://github.com/EmpoweredHouse/ehos-tools/issues/1013) lists each one from the code:
where it lives, what a leak or a loss does, who must keep it, and what the command says about it
today.

What the commands say is uneven:

- **Only `server invite` says all three things**: where the link is (on the screen only), what it
  is ("The link is a password"), and what to do ("Give it only to that person…", and how to end it
  if another person saw it).
- **Some say where and nothing more.** `server tunnel` gives the kubeconfig's path as a labelled
  value, but not that it is administrator access to the cluster. `resources add-database` names
  the Secret of the managing role. `login`, when it has no keychain, names the file of the refresh
  token.
- **Many say nothing.** `server up` does not say that without the state passphrase the server can
  no longer be changed or removed with `ehosctl`, nor where the encrypted state is. `install` does
  not say that the cluster now pulls images with the token of the person who ran it. No command
  names OpenBao's key, whose loss makes every secret value and every snapshot unreadable.

eh-os's installation guide already says what installation administrators keep in a password manager
they share, and what they never share
([Share an installation with another installation administrator](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#share-an-installation-with-another-installation-administrator),
[Backing up and restoring OpenBao](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#backing-up-and-restoring-openbao)).
A person who runs a command does not see that page at the moment it matters: when the secret is
made.

[T-28](0028-ehosctl-says-everything-in-a-few-shared-shapes-built-as-tagged-data-and-colours-them-only-on-a-terminal-without-no-color.md)
gives every command the same shapes, and step 4 of
[#979](https://github.com/EmpoweredHouse/ehos-tools/issues/979) moves the commands to them one
group at a time. A rule for secrets decided now goes in with that move. Decided later, it changes
the same commands a second time.

## Decision drivers

1. **A secret's value never reaches the output** unless printing it is what the command is for
   (`credential`, `server invite`). What a command says about a secret is its kind, its place and
   its weight, never its contents.
2. **A person who makes a secret learns, in the same output, what to do with it**, without a guide
   open beside the terminal.
3. **The same kind of secret is described with the same words in every command**, so that the
   words cannot drift between `server up`, `install` and `upgrade`.
4. **The output stays short.** A command that leaves a secret as it was does not repeat its
   warning on every run.
5. **The shapes of T-28 and nothing new**: a labelled value, a warning, `Next:`. `--json` and exit
   codes stay as T-28 keeps them.
6. **The guide stays the one place for the procedure** (how to copy the state, how to back up
   OpenBao). A command links it and does not repeat it.

## Considered options

1. **Each command reports the secrets it made or replaced, as data; `ehosctl` renders each as a
   labelled value and, when a person must act, a warning, from one list of kinds**
2. **Documentation only**: each command's page and the guide say it; the commands stay as they are
3. **One command that lists every secret of an installation** (in `doctor`, or
   `ehosctl installations secrets`), and the other commands say nothing
4. **Each command writes its own sentences**, in the shapes of T-28, with no shared list

## Decision outcome

Chosen option: **"Each command reports the secrets it made or replaced, from one list of kinds"**,
because it is the only option that tells the person at the moment the secret is made (driver 2)
with words that cannot drift (driver 3). It uses the shapes of T-28 (driver 5).

**What a command says.** For each secret that a run makes, replaces, or first writes on this
machine, the result says three things:

| What | Shape | Example (`server tunnel`) |
| --- | --- | --- |
| Where it is: a file and its path, a Secret and its namespace and name, the system keychain, or "on the screen only" | A labelled value; the label is the kind of the secret | `Kubeconfig   ~/.ehos/office/kubeconfig` |
| Its weight: what a leak or a loss does, in one sentence | The head of a warning | `! The kubeconfig gives administrator access to the cluster.` |
| Who keeps it, and what to do | The explanation of the warning, from one of four sentences below, and a link to the guide where it has the procedure | `Keep it to yourself. Do not copy it: ehosctl server tunnel writes it again.` |

A run that leaves a secret as it was gives the labelled value and no warning. A secret whose
weight needs nothing from the person (a key that stays in the cluster) gives the labelled value
only.

**Who keeps it.** Each kind of secret has one of four keepers. Each keeper has one sentence, the
same in every command:

| Keeper | What the warning tells the person | Kinds, from #1013 |
| --- | --- | --- |
| Shared | Keep it in the password manager that the installation administrators share, and link the guide's section | the state passphrase, a copy of the encrypted state, the SSH key `up` put on the server, OpenBao's key |
| Own | Keep it to yourself. Do not share it | the kubeconfig, the refresh token, the pull credential's token, a ten-minute credential |
| One person | Give it only to that person | the link of `server invite` |
| The cluster | No warning: the labelled value says where it is | the CA's key, the Let's Encrypt account keys, the acme-dns account, the SMTP password, the managing role of a database outside the installation |

**The list of kinds** is one module in `ehos_platform`, since most of the secrets are made there
and `ehosctl` depends on it: `EhosPlatform.Secret`, with one entry for each kind of secret on
#1013. An entry holds its label, its weight sentence and its keeper. A new kind of secret is a new
entry, with its weight and keeper decided in review.

**How it travels.** `EhosPlatform.Report` gets a `secrets` field: a list of
`{kind, place, :made | :replaced | :kept}`. A command of `ehosctl` that makes a secret itself
(`login`, `db tunnel`) builds the same list. `Ehosctl.Output` renders each item: the labelled
value always, and the warning only for `:made` and `:replaced` and only for the keepers "shared",
"own" and "one person". Under `--json`, the result gets the same list as a `secrets` field with
the kind, the place and the keeper. This adds a field and changes none.

**What this does not decide.** It does not change where a secret is kept (T-08 for the refresh
token, eh-os D-77 for the state), and it does not decide if `db tunnel` must print the password of
a data session on stderr. That and the mode of `ca.crt` are findings on #1013, each with its own
follow-up.

### Consequences

- Good, because a person sees, when a secret is made, what it gives and what to do with it, in the
  same words as the guide, with a link to the guide's procedure.
- Good, because the weight of each kind is decided once, in review of `EhosPlatform.Secret`, and
  not again in each command.
- Good, because the place is data, so `--json` gives a script the paths and Secrets that a run
  made, which a backup script can use.
- Bad, because the output of `server up`, `server tunnel` and `install` gets two to four lines
  more on the run that makes the secrets. Mitigation: a later run that keeps them gives only the
  labelled values.
- Bad, because `EhosPlatform.Report` changes again after T-28 changed it. Mitigation: the new field
  defaults to an empty list, so a command that makes no secret does not change.
- Bad, because the list must stay complete: a new secret that a command makes without an entry is
  silent, as today. Mitigation: the review checklist asks for an entry, and the Confirmation below
  checks the kinds that #1013 lists.
- Neutral: the sentences of each kind are words a person reads, so they follow `ehos-dev:voice`,
  and the keeper "shared" uses the guide's own words.

### Confirmation

- `EhosPlatform.SecretTest` asserts that each kind has a label, a weight sentence and a keeper, and
  that the kinds are those of #1013.
- `EhosPlatform.ServerTest` and `EhosPlatform.InstallTest` assert that `up`, `tunnel` and
  `install` return in `secrets` each secret the run made, with its place, as they assert the other
  parts of the report (T-28).
- `Ehosctl.OutputTest` asserts that a `:made` secret of each keeper renders the labelled value and
  the warning, a `:kept` one the labelled value only, and `--json` the `secrets` list. It also
  asserts that no rendered secret contains the secret's value.
- The tests of `login` and `db tunnel` assert their entries in the same way.

## Pros and cons of the options

### One list of kinds, rendered from the report

- Good, because the person learns it when the secret is made, and the words are the same for one
  kind in every command.
- Good, because it fits T-28: `ehos_platform` returns the parts, `ehosctl` renders them.
- Bad, because it is a new module and a new field to keep complete.

### Documentation only

- Good, because no code changes, and the guide already says most of it.
- Bad, because a person who runs `server up` or `server tunnel` does not read the guide at that
  moment, and nothing in the output sends them there.
- Bad, because the guide can drift from what the commands make: no command names OpenBao's key
  today, and the guide is the only place that does.

### One command that lists every secret

- Good, because one command answers "what must I back up?" for an installation at any time.
- Bad, because the person must know the command exists, and runs it after the moment that matters.
- Bad, because some secrets are not on the machine that runs it (a link already given, the
  kubeconfig of another administrator), so the list is partial. This command can come later, from
  the same `EhosPlatform.Secret` list, without a new decision.

### Each command writes its own sentences

- Good, because it needs no new module and no new field.
- Bad, because the same kind gets different words in `server up`, `install` and `upgrade`, as the
  four date formats in #979's audit show for other values.
- Bad, because nothing makes a new command say it.

## More information

- Decided under [#1013](https://github.com/EmpoweredHouse/ehos-tools/issues/1013), which holds the
  inventory. Found during [#979](https://github.com/EmpoweredHouse/ehos-tools/issues/979), step 4.
- Related: [T-08](0008-ehosctl-keeps-a-sign-in-s-refresh-token-in-the-system-s-keychain-else-a-file-only-the-user-reads-and-renews-under-a-lock.md)
  (where the refresh token is kept, and its warning when it is a file),
  [T-14](0014-ehosctl-login-keeps-the-ca-it-was-told-to-trust-beside-the-installation-and-trusts-it-for-that-installation-alone.md)
  (the CA that `login` keeps),
  [T-18](0018-in-a-github-actions-job-ehosctl-talks-to-the-installation-ehosctl-url-names-and-exchanges-the-job-s-token-for-each-credential-keeping-nothing.md)
  (a job keeps nothing), and
  [eh-os#1115](https://github.com/EmpoweredHouse/eh-os/issues/1115) (`ehosctl` cannot rotate the
  state passphrase or the credentials of the cluster yet).
- Revisit when the state is shared and locked
  ([eh-os#251](https://github.com/EmpoweredHouse/eh-os/issues/251)): a copy of the encrypted
  state may then no longer need the keeper "shared".

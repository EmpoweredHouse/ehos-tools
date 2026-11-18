---
status: proposed
date: 2026-11-18
decision-makers: []
consulted: []
---

# T-29 · `ehosctl` adds a database outside the installation with a command of its own, and `install` and `upgrade` keep the list from the running release

## Context and problem statement

An installation can list a company's own PostgreSQL database, on Cloud SQL or RDS for example, as
a resource
([eh-os D-170](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0170-a-postgresql-database-outside-the-installation-is-a-resource-the-chart-lists-provisioned-by-a-job-as-a-managing-role-that-is-no-superuser-and-reached-only-at-the-address-ranges-the-chart-names.md)).
The chart lists it under `dataResources.external`, with its host, port, database, CA, address
ranges, the name of a Secret in `ehos-data` that holds the managing role's name and password, and
an optional `administratorRole`. D-170 gives `ehosctl` a command that adds one: it writes the Secret
from a password read without echo or from standard input, never from an argument, adds the entry
to the installation's values, and upgrades.

`ehosctl install` and `upgrade` (`EhosPlatform.Install`) write the chart's values from their
options, and keep each setting a person gave earlier by reading it back from the Helm release's last
deployed revision (`EhosPlatform.Install.installed/1`): Helm does not reuse a release's values, so a
setting not given again is lost. They read back the host, the sign-in limits, mail, four eyes and the
allowed domains. They do not read back `dataResources`. So today an `ehosctl upgrade` of an
installation that lists a database outside writes no `dataResources.external`, and the chart's
check before the upgrade (eh-os D-187) refuses it when a resource binding names the database, or
EHOS marks the database not listed when none does. The command that adds a database must decide
where the list lives between two upgrades, and how `install` and `upgrade` keep it.

The development flag `dataResources.externalUnderDevelopment` stays until eh-os's plan, step 7,
removes it. The command is released only after that.

## Decision drivers

- An upgrade never drops or moves a database that the installation lists.
- No password passes through an argument, a values file on disk, or the Helm release's values.
- One place holds the list, so `install`, `upgrade` and the new command cannot disagree.
- A person can add a database without editing YAML, and sees what the command writes before it
  changes anything (eh-os's plan, step 6).

## Considered options

1. **A command of its own, `ehosctl resources add-database`, on the platform plane; `install` and
   `upgrade` keep the list from the running release.** The command writes the Secret in
   `ehos-data`, reads the running release's values, adds the entry, and runs `install/4` at the
   running version, as `upgrade` does. `install` and `upgrade` read `dataResources.external` back
   from the last deployed revision, as they read the allowed domains, and write it again.
2. **Options of `install` and `upgrade`**, such as `--external-database NAME=…` given once for each
   database, as `--allowed-domain` is, with the rest kept from the running release.
3. **A file the person keeps**, such as `ehos-values.yaml` beside `config.json`, which `install`,
   `upgrade` and the command read and write.

## Decision outcome

Chosen option, to be decided by the user: **"A command of its own"** is recommended, because one
database has eight fields and a password, which a repeated option cannot carry readably, and the
running release is already where `install` and `upgrade` keep every other setting.

### Consequences

- Good, because a person adds a database with one command, which can print what it will write and
  what the chart would refuse first (eh-os's plan, step 6).
- Good, because `install` and `upgrade` keep the list as they keep the other settings, so no upgrade
  drops it.
- Bad, because the list lives in the Helm release alone: a person who installs from scratch, without
  the release, gives each database again. The same holds for the allowed domains today.
- Bad, because a second command (remove, change) is needed later for a database that leaves the
  list; until then a person edits through `helm` or installs again.
- Neutral: the Secret is written by `kubectl` through the tunnel, as `install` writes the pull
  credential, never through EHOS's API.

### Confirmation

- A test of `EhosPlatform.Install` that an upgrade of a release whose values list a database outside
  writes the same `dataResources.external` again.
- A test of the command that the password reaches only `kubectl`'s standard input, never an
  argument or a file.

## Pros and cons of the options

### A command of its own

- Good, because one command says what it adds, and refuses before it writes.
- Bad, because it runs an upgrade at the running version, which restarts nothing but takes as long
  as a Helm upgrade.

### Options of `install` and `upgrade`

- Good, because no new command.
- Bad, because a database is eight fields and a CA in PEM: a repeated option is long and easy to get
  wrong, and the password still needs its own variable.
- Bad, because every later upgrade must keep what one install gave, which this option needs as much
  as option 1.

### A file the person keeps

- Good, because the list is in one file a person can read, review and keep in version control.
- Bad, because the file and the running release can disagree: an upgrade from another machine, or
  from a file that is out of date, moves or drops a database, which the check before an upgrade
  then refuses.

## More information

Decided under [EmpoweredHouse/ehos-tools#992](https://github.com/EmpoweredHouse/ehos-tools/issues/992),
for [EmpoweredHouse/eh-os#1712](https://github.com/EmpoweredHouse/eh-os/issues/1712) (a database
outside the installation as a resource, step 5). Nothing that depends on this record is built until
the user decides.

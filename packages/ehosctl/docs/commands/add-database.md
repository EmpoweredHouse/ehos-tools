# Adding a database outside the installation

`ehosctl resources add-database` adds a PostgreSQL database outside the installation, such as a
database on Cloud SQL or RDS, as a resource. Environments can then bind it as they bind an
instance in the installation. This page is for the installation administrator. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
export GHCR_TOKEN=…                                # as for install
ehosctl server tunnel --installation acme
ehosctl resources add-database ledger --installation acme \
  --host ledger-db.acme.example --database apps --version 17 \
  --ca-file server-ca.pem --address-range 10.20.0.0/24 \
  --username ehos_manager --password-file managing-role.txt
```

## Prerequisites

- The installation runs EHOS 0.30.0 or later, from its published release.
- The chart of that EHOS accepts a database outside the installation. EHOS 0.30.0 and 0.31.0
  accept one only when their Helm release sets `dataResources.externalUnderDevelopment`. Without
  it, the chart refuses the database, and `ehosctl` changes nothing. These two versions offer it
  to develop EHOS only: they lack fixes that a client's data needs. Keep a client's data on a
  database outside the installation only with a later EHOS, which needs no such value.
- The database server has a DNS name, and its certificate carries that name. Give `--host` as the
  certificate writes it. If the certificate writes the name with a trailing dot, give the dot too:
  Cloud SQL writes the name of an instance in this form.
- The managing role exists on the server. It is not a superuser.
  [Prepare the database](#prepare-the-database) tells how to make it.
- The tunnel to the server is open, and `GHCR_TOKEN` is set, as for `ehosctl upgrade`.
- This machine can reach GitHub, where `ehosctl` reads the release of the EHOS that runs.

## Prepare the database

`ehosctl resources prepare-sql` prints the SQL that makes the managing role and the database of
EHOS on the server. The managing role may give the roles that EHOS makes the right to connect to
that database. The SQL also takes from `PUBLIC` the right to create in that database, and the
right to connect to each database of the server, that one included. `ehosctl` contacts nothing, and the SQL
names no password.

1. Print the SQL with your own names, into a file:

   ```sh
   ehosctl resources prepare-sql --database apps --username ehos_manager > prepare.sql
   ```

2. Read the file. Its first lines are comments that tell how to run it.
3. Connect to the server with `psql` as your own role, and run the file: `\i prepare.sql`.
4. In the same `psql`, set the password of the managing role: `\password "ehos_manager"`.

`ehosctl` quotes each name as PostgreSQL does. It refuses a name that is empty, longer than 63
bytes, or that holds a control character, and a `--database` that holds `$$`. Then it prints
nothing. The guide for the installation
administrator gives the full procedure:
[Use a database outside the installation](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#use-a-database-outside-the-installation).

## Give the password

`ehosctl` reads the password of the managing role from a file, or from standard input. It never
reads the password from a terminal, and you never give it as an argument.

- `--password-file managing-role.txt` reads the file. `ehosctl` removes one line break at its end.
- `--password-file -` reads standard input from a pipe or a file, as in
  `--password-file - < managing-role.txt`. Standard input then holds the password, so `ehosctl`
  cannot ask before it writes: give `--yes` too.

Do not `echo` the password into the pipe: your shell can keep the command in its history. Use a
file that only you can read, or the command of your provider that prints the password.

## What the command does

1. `ehosctl` checks each value as the chart of EHOS checks it, and reads the password.
2. It reads what runs on the server, through the tunnel. It refuses when no EHOS runs, when the
   EHOS that runs is older than 0.30.0, or when the installation lists the name already.
3. It reads the release of that version from GitHub. If the image or the chart that runs is not
   the one that the release names, `ehosctl` refuses, as `ehosctl install` does.
4. It renders the chart of the EHOS that runs, with the new database in the list. If the chart
   refuses the database, `ehosctl` shows why and changes nothing.
5. It prints what it adds, and each warning. The output never shows the password.
6. It asks before it writes. `--yes` answers the question. With no answer, `ehosctl` changes
   nothing. Without `--yes`, standard input must be a terminal, or `ehosctl` refuses before it
   reads anything.
7. It reads the Helm release again. If another command installed or upgraded EHOS before this
   read, `ehosctl` refuses and writes nothing. Run the command again. A command that starts after
   this read and before the install is not caught: Helm cannot refuse a change that a release
   did not expect.
8. It writes the name and the password of the managing role into the Secret
   `ehos-external-<name>` in the namespace `ehos-data`.
9. It installs the EHOS that runs again, with the database in its list, as `ehosctl upgrade` does.
   It keeps every other setting of the EHOS that runs.

Step 4 renders the chart with the values of the running Helm release. The install in step 9
builds some values again from what runs. So the chart can refuse a value at step 9 that step 4
did not show, after `ehosctl` wrote the Secret. Fix the cause, and run the command again: it
replaces the Secret that it wrote.

When the command is done, the operator checks the database every hour. Run
`ehosctl resources check <name>` to see the last check.

## The Secret of the managing role

`ehosctl` names the Secret `ehos-external-<name>`. It gives the Secret the label
`app.kubernetes.io/managed-by: ehosctl` and an annotation with the name of the database.

- If no Secret has that name, `ehosctl` makes it.
- If `ehosctl` made the Secret before, for the same database, `ehosctl` replaces it.
- If another Secret has that name, `ehosctl` refuses and says what holds the name. It does not
  change that Secret.

If a step fails, `ehosctl` prints the output of `kubectl` with the password and its base64 replaced
by `[the password]`.

## Change or remove a database

`ehosctl` does not change the server, the port or the database of an entry. While a resource
binding names a database, EHOS refuses an upgrade that changes them, and one that takes the
database out of the list.

`ehosctl install` and `ehosctl upgrade` keep the list of the EHOS that runs. They leave out a
database whose managing role is in another Secret than `ehos-external-<name>`, and say so. Add it
again with this command to keep it.

### Mark a database that is gone for good

If the provider deleted a database, or it does not answer again, EHOS cannot drop the data of an
ephemeral environment bound to it. The removal of that environment waits. Mark the database gone:

```sh
ehosctl resources mark-gone ledger --installation acme
```

- `ehosctl` shows what it marks, asks, and installs the EHOS that runs again with the mark.
- EHOS then checks nothing on the database. The removal of each ephemeral environment bound to it
  drops nothing there, and deletes the passwords of its roles. The audit record names the schema
  and the roles that each removal leaves.
- EHOS refuses the mark while an environment that is not removed is bound to the database. Remove
  that environment, or its resource binding, first. EHOS keeps the data of a production
  environment.
- `install` and `upgrade` keep the mark.

### Take a database out of the list

When no resource binding names the database, take it out of the list:

```sh
ehosctl resources remove-database ledger --installation acme
```

`ehosctl` shows what it takes away, asks, and installs the EHOS that runs again without the
database. Then it deletes the Secret `ehos-external-ledger`, if `ehosctl` made it. EHOS refuses the
upgrade while a resource binding names the database, and `ehosctl` then deletes nothing. The data
on the database stays.

## Next steps

- [Bind a resource in an environment](env.md#bind-a-resource-in-an-environment)
- [Upgrade EHOS on the server](upgrade.md)

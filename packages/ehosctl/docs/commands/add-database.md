# Adding a database outside the installation

`ehosctl resources add-database` adds a PostgreSQL database outside the installation, such as a
database on Cloud SQL or RDS, as a resource. Environments can then bind it
as they bind an instance in the installation. This page is for the installation administrator. The
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

- The installation runs EHOS 0.30.0 or later.
- The chart of that EHOS accepts a database outside the installation. EHOS 0.30.0 accepts one for
  development only, when its Helm release sets `dataResources.externalUnderDevelopment`. Without
  it, the chart refuses the database, and `ehosctl` changes nothing.
- The database server has a DNS name that you control, and its certificate carries that name.
- The managing role exists on the server. It is not a superuser.
- The tunnel to the server is open, and `GHCR_TOKEN` is set, as for `ehosctl upgrade`.

## Give the password

`ehosctl` reads the password of the managing role from a file, or from standard input. It never
reads the password from a terminal, and you never give it as an argument.

- `--password-file managing-role.txt` reads the file. `ehosctl` removes one line break at its end.
- `--password-file -` reads standard input from a pipe or a file, as in
  `--password-file - < managing-role.txt`.

Do not `echo` the password into the pipe: your shell can keep the command in its history. Use a
file that only you can read, or the command of your provider that prints the password.

## What the command does

1. `ehosctl` checks each value as the chart of EHOS checks it, and reads the password.
2. It reads what runs on the server, through the tunnel. It refuses when no EHOS runs, when the
   EHOS that runs is older than 0.30.0, or when the installation lists the name already.
3. It renders the chart of the EHOS that runs, with the new database in the list. If the chart
   refuses the database, `ehosctl` shows why and changes nothing.
4. It prints what it adds. The output never shows the password.
5. It writes the name and the password of the managing role into the Secret
   `ehos-external-<name>` in the namespace `ehos-data`.
6. It installs the EHOS that runs again, with the database in its list, as `ehosctl upgrade` does.
   It keeps every other setting of the EHOS that runs.

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

This command only adds a database. To change or remove one, change the values of the Helm release
with `helm`, or install again. While a resource binding names a database, do not remove it. Do
not change its host, its port or its database then: the chart refuses the upgrade.

`ehosctl install` and `ehosctl upgrade` keep the list of the EHOS that runs. They leave out a
database whose managing role is in another Secret than `ehos-external-<name>`, and say so. Add it
again with this command to keep it.

## Next steps

- [Bind a resource in an environment](env.md#bind-a-resource-in-an-environment)
- [Upgrade EHOS on the server](upgrade.md)

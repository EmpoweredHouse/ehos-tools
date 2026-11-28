# Data sessions

A data session lets a person read or change the database of one application in one environment, for
a limited time. This page tells how `ehosctl` checks the database and the data gateway. It also
tells what to do when the installation changes a CA. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl db connect ledger --env staging                # psql on the data of ledger in staging
ehosctl db connect ledger --env staging --write --ttl 30m
ehosctl db tunnel ledger --env staging                 # for another database client
ehosctl db sessions ledger --env staging   # the open data sessions of ledger in staging
ehosctl db sessions --mine                 # your own open data sessions
ehosctl db end 6f1c2a9e-5b7d-4c1e-9a2f-3d4e5f6a7b8c
ehosctl db trust-ca qUiQTy8PR5uPgZdpSzAYSw0u0cHNKh7A+4XSmaGSpEc=
```

## Before you start

- Sign in with `ehosctl login`. The first sign-in on a computer keeps the CAs that a data session
  needs.
- Get a role binding for the application in the environment: `ehos.data_reader` to read, or
  `ehos.data_writer` to change the data. In production, the role binding must be for that
  environment, and it ends at a time that the person who binds it sets. See
  [Bind a role to the data of a production environment](role-bindings.md#bind-a-role-to-the-data-of-a-production-environment).
- For `ehosctl db connect`, install `psql`, version 16 or later. `ehosctl doctor` shows the version
  that it finds.

EHOS opens no data session on a database outside the installation. It refuses with
`outside_installation`, and names the group roles to ask the administrator of that database for.
`ehosctl` then links the part of the guide for the installation administrator that tells how to
give a person this way.

## Open a data session with psql

Run `ehosctl db connect <application> --env <environment>`.

1. `ehosctl` makes a password and a key for the data session. They stay on your computer. EHOS
   gets only values that it cannot sign in with.
2. EHOS opens the data session, and makes a database role for it. This can take up to 30
   seconds.
3. `ehosctl` starts `psql`, connected to the database through the data gateway. `psql` starts in
   the schema of the application, so a table name needs no schema. EHOS 0.31 and earlier do not
   name the schema: then write the schema before each table name.
4. When you exit `psql`, `ehosctl` ends the data session.

`ehosctl` exits with the exit code of `psql`. Ctrl-C in `psql` stops a query, as usual. It does
not stop `ehosctl`.

- `--write` opens a data session that can change the data. Without it, the data session can only
  read.
- `--ttl` sets how long the data session lasts, such as `30m` or `2h`. The default is 1 hour. The
  installation sets the limit, 8 hours or less.

Each connection of a data session has these limits:

- A statement stops after 5 minutes.
- A wait for a lock stops after 5 seconds.
- A transaction that is idle for 1 minute ends.

A data session has 3 connections or fewer at a time.

## When a data session ends in production

In a production environment, a data session ends no later than the role binding that gives it.
If the role binding ends before the time of `--ttl`, the data session ends 10 seconds before the
role binding. `ehosctl db connect` and `ehosctl db tunnel` then say that the role binding sets the
end of the data session. If a person who manages role bindings there extends the role binding, a new data
session can last longer. The data session that is open does not.

If the role binding ends in less than 1 minute, EHOS opens no data session. It refuses with
`binding_ends`, and says when the role binding ends. `ehosctl` exits with 1.

`--json` of `ehosctl db sessions` gives `ends_with_role_binding`: `true` when the end of the role
binding sets the end of the data session.

## What a data session cannot do

A data session cannot call a function in the schema of the application. If PostgreSQL must call
such a function for a statement, it refuses the statement with
`permission denied for function <name>`. A trigger function is an exception: PostgreSQL runs it.
The refusal occurs in these cases:

- An insert leaves a column to a default that calls the function. Give the column a value.
- An insert or an update meets a check, a check of a domain, a generated column or an index that
  calls the function.
- A trigger function that runs with the privileges of the data session calls another function in
  the schema.
- You read a view that calls the function. Read the tables under the view.
- You read a table with a row-level security policy that calls the function.

If you need such a statement, ask the developers of the application to run it.

## Connect another database client

Run `ehosctl db tunnel <application> --env <environment>`. It opens a data session as
`ehosctl db connect` does. Then it prints the values that a database client needs:

- the host, the local address and the port;
- the database, the user and the password file;
- the CA file and the options;
- the schema of the application, when EHOS names it. The options and the JDBC URL then set it as
  the `search_path`.

It also prints them as a libpq connection string and as a JDBC URL. In place of the password, it
prints the path of the password file, which only you can read. `ehosctl` does not show the
password, because the output can go to a file, a log, a shared screen or a recording.

If a client cannot read a password file, copy the password from the last field of the line in
that file.

The data session stays open until you press Ctrl-C, or until it expires. Then `ehosctl` ends it.

The client must verify the server against the CA file and require channel binding. libpq 13
and pgjdbc 42.7.12, and later versions, can do this. If the client cannot do it, do not use it.

`ehosctl` removes the password file and the CA file when the data session ends. If a person stops
`ehosctl` by force, the next `ehosctl db connect` or `ehosctl db tunnel` removes them.

## List the open data sessions

- Run `ehosctl db sessions --mine` to see your own data sessions, in each application and
  environment.
- Run `ehosctl db sessions <application> --env <environment>` to see the data sessions of an
  application in an environment.

Each row gives the ID of a data session, its application and its environment. It also gives the
level (`read` or `write`), the state, and when the data session opened and expires. `--json`
prints the same as JSON.

You see your own data sessions. You see the data sessions of other people only where you manage
role bindings.

## End a data session

Run `ehosctl db end <ID>`, with the ID that `ehosctl db sessions` shows.

EHOS ends the data session now. Its connections to the database close, and EHOS removes its
database role. You cannot open it again: open a new data session.

You can end your own data sessions. You can end the data sessions of other people only where you
manage role bindings. If the data session already ended, EHOS refuses with `already_ended`, and
`ehosctl` exits with 1.

## The two CAs that `ehosctl` keeps

A data session uses two connections, and each connection has a certificate from a CA of the
installation:

- The **data CA** signs the certificate of each database. Your database client checks the
  database against it.
- The **gateway CA** signs the certificate of the data gateway. `ehosctl` checks the data gateway
  against it.

`ehosctl login` gets the two CAs from the installation the first time that you sign in on a
computer. `ehosctl` keeps them in `config.json`, beside the installation. They stay when you sign
out. They go when you remove the installation, or when you sign in to it at another address.

At each later sign-in, `ehosctl` takes a CA again only if it has the same key. The installation
renews a certificate with the same key, so a renewal changes nothing for you. A CA with a new key
is not trusted. If a person takes control of the installation, that person cannot give you a false
CA.

An installation that has no data gateway gives no CAs. `ehosctl login` then keeps none, and
signs you in as usual.

## Trust a CA with a new key

If the administrator of the installation replaces the key of a CA, `ehosctl login` tells you:

```text
ehosctl: staging gives a gateway CA with another key than the one ehosctl keeps, so ehosctl does not trust it, and refuses data sessions that use it. …
```

1. Get the fingerprint of the new CA from the administrator of the installation. Get it in a way
   that does not go through EHOS, such as in person or by phone.
2. Run `ehosctl db trust-ca <fingerprint>`.

`ehosctl` asks the installation for its CAs. If one of them has the fingerprint that you typed,
`ehosctl` keeps that CA. It then prints:

```text
ehosctl now trusts the gateway CA of staging with this fingerprint.
```

If no CA has the fingerprint, `ehosctl` keeps the old CA and exits with 1.

A fingerprint is the SHA-256 of the key of the CA. Type it in base64, as EHOS gives it, or in
hexadecimal, with or without colons.

## Background

- [Why a data session goes through a data gateway, and why `ehosctl` keeps the data CA](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0149-a-person-s-database-session-reaches-its-instance-through-a-data-gateway-of-its-own-not-the-governance-plane.md)
- [Why the data gateway has a CA of its own](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0181-the-data-gateway-s-certificate-comes-from-a-ca-the-chart-makes-which-ehosctl-keeps-from-its-first-login-as-it-keeps-the-data-ca.md)
- [Why a data session cannot call a function of the application](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0191-a-data-session-calls-no-routine-of-its-schema-so-a-statement-that-makes-postgresql-call-one-for-it-is-refused.md)

## Next steps

- [Signing in](login.md)
- [Role bindings](role-bindings.md): a data session needs a role that holds the data capabilities
  of the application in the environment.

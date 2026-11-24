# Calling an application

`ehosctl call` runs a command, makes a recording or asks a query in an application, as you.
`ehosctl credential` prints a credential for an application, for a script or `curl`. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl call ledger ledger.record_entry amount:=100 note="Rent, October"
ehosctl call ledger ledger.balance account=a-1 --env production
ehosctl credential ledger | sed 's/^/Authorization: Bearer /' |
  curl -H @- https://ledger.staging.example.com/api/queries/ledger.balance
```

`call` uses the routes that each application built on `ehos_contract` serves. `ehosctl apps`
shows the kind of each capability. `ehosctl` sends a command or a recording as `POST`, with the
fields as a JSON object. It sends a query as `GET`, with the fields in the URL.

## Give the fields

Write the fields as HTTPie writes them:

- `name=text` is text.
- `name:=<JSON>` is a JSON value: `amount:=100`, `paid:=true`, `tags:='["a","b"]'`.

`--data` gives a JSON object to start from: inline, as `@file.json`, or as `-` for stdin. A field
on the command line replaces the field of the same name in this object.

In a query, a field that you give more than once is a list.

`ehosctl` does not check the fields against the declaration of the application. The application
checks them, and says which field does not fit.

## Choose the environment

If your roles are bound in only one environment of the application, you can leave out `--env`.
Otherwise `--env` is necessary, and `ehosctl` names the environments.

## Call a capability that your roles do not grant

`ehosctl` still sends the call, so that EHOS or the application refuses it and records the refusal.

- EHOS refuses a credential where your roles grant nothing.
- The application refuses a credential without the capability.
- In both cases, `ehosctl` exits with 3.

`ehosctl` does not know the kind of a capability that your roles do not grant. It sends the call
as a command, then as a recording, each with your fields in its body. Then it sends the call as a
query, without the fields. It stops when the application finds the capability. `ehosctl` does not
send a kind that your fields cannot make.

If none of your roles is bound in the application, `ehosctl` does not know its address. It refuses
the call without sending it.

## Call a capability of a new kind

A later EHOS can add a kind of capability that this version of `ehosctl` does not know. `apps`
shows that such a capability needs a later `ehosctl`, and `call` refuses it with exit 1.

## Send a command again safely

Each command and recording carries a new `idempotency-key`. An application needs the key for a
command that creates something.

`--idempotency-key <key>` gives your own key. If you send the same call again with the same key,
the application runs it only once.

`ehosctl` cannot always know if the application ran a command. For example, the connection broke
after `ehosctl` sent the request, or a gateway answered 5xx for the application. Then `ehosctl`
says so, and names the key that it sent.

`ehosctl` refuses a key that is not printable ASCII of 255 bytes or fewer. It sends nothing.

## Get a credential for a script

The credential belongs to the application. `ehosctl` renews it from your sign-in, with the address
of the application as `resource`, and keeps it for its 10 minutes.

`ehosctl credential <app>` prints the credential, for a script or `curl`. It never prints the
refresh token. If none of your roles grants anything there, EHOS issues no credential, and
`ehosctl` exits with 3.

Give the credential to `curl` on its standard input, with `-H @-`, as the example at the top of
this page does. Do not put it on the command line of `curl`. Other users of the machine can read
a command line with `ps` while the command runs.

## Read the answer as JSON

With `--json`, `call` prints the answer of the application as it came: the receipt of a command,
or the `rows` or `row` of a query.

## Next steps

- [Signing in](login.md): sign in before you call an application.
- [Output and exit codes](output.md): what each exit code means.

## Background

- [T-10](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0010-ehosctl-call-reaches-an-application-through-eh-os-contract-s-routes-found-through-ehos-s-api.md):
  why `call` uses the routes of `ehos_contract`, found through the API of EHOS.
- [T-12](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0012-ehosctl-call-asks-for-a-capability-no-role-grants-so-its-refusal-is-decided-and-recorded.md):
  why `call` sends a capability that no role grants.
- [eh-os D-89](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0089-ehosctl-signs-a-person-in-as-a-public-client-through-a-loopback-redirect-and-gets-each-credential-by-renewal.md):
  why each credential comes from a renewal of your sign-in.

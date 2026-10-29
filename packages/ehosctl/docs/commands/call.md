# Calling an application

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

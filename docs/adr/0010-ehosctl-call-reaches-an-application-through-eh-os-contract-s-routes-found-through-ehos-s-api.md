---
status: accepted
date: 2026-10-10
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-10 · `ehosctl call` reaches an application through `eh_os_contract`'s routes, found through EHOS's API

## Context and problem statement

Stage 7's step 6 ([eh-os#333](https://github.com/EmpoweredHouse/eh-os/issues/333),
[#79](https://github.com/EmpoweredHouse/ehos-tools/issues/79)) lets a person do something in an
application from their terminal: `ehosctl call ledger ledger.record_entry amount=100`. Every
application built on `eh_os_contract` serves its capabilities through `EhOsContract.Plug`:
a command as `POST /api/commands/<capability>`, a recording as `POST /api/records/<capability>`,
and a query as `GET /api/queries/<capability>?…`, behind a credential for its audience.

`ehosctl` knows none of an application's declarations. EHOS's API tells it, per person, where each
application is and what their roles grant there, with each capability's kind
([`GET /api/me/applications`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/terminal-api.md),
eh-os#330). A credential for the application comes by renewal with its address as `resource`
([eh-os D-89](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0089-ehosctl-signs-a-person-in-as-a-public-client-through-a-loopback-redirect-and-gets-each-credential-by-renewal.md)).

Three questions were left open on the issue. How does `call` know that a command creates its
aggregate, and so needs an `idempotency-key` (`EhOsContract.Plug` answers 422
`idempotency_key_required` without one)? How is a field's type read from the command line? And how
does `call` relate to the one generated client of
[eh-os D-12](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ADR.md#d-12)?

## Decision drivers

- The same authorization as every other caller: `call` gets no route, header or credential that a
  script with `ehosctl credential` and `curl` could not use (D-12: no surface is privileged).
- Nothing about an application compiled into `ehosctl`: one binary calls every application, of
  every version, that the person may use.
- A call that did not answer can be sent again without being done twice.
- No change to EHOS or `eh_os_contract` for something the client can decide alone.
- Typing fields the way people already type them in a terminal.

## Considered options

1. **A generic client of `EhOsContract.Plug`'s routes**, finding each capability's kind in
   `GET /api/me/applications`, typing fields as HTTPie does, and sending a new idempotency key with
   every command and recording.
2. **A client generated from each application's OpenAPI document** (`EhOsContract.OpenApi`), read
   at call time, which knows each command's fields and whether it creates its aggregate.
3. **`GET /api/me/applications` says which commands create their aggregate**, and `call` sends a
   key only to those.

## Decision outcome

Chosen option: **"A generic client of `EhOsContract.Plug`'s routes"**, because it needs nothing but
what EHOS already tells a terminal, and the application already checks everything a generated
client would.

- **The kind decides the route.** A command is `POST <address>/api/commands/<capability>` and a
  recording `POST <address>/api/records/<capability>`, each with the fields as a JSON object; a
  query is `GET <address>/api/queries/<capability>` with them in the query string. A capability
  that `apps` does not list for the person is refused before anything is sent: their credential
  would not carry it.
- **A new idempotency key on every command and recording**, a random UUID, or the one
  `--idempotency-key` gives. `EhOsContract.Dispatcher` requires a key for a command that creates
  its aggregate and honours one for any other: a key it has accepted for the same command returns
  that receipt, `duplicate: true`, and appends nothing. A fresh key therefore changes nothing for a
  command that does not need one. When an application does not answer, `ehosctl` says which key it
  sent, so the person can send the call again and have it done once. eh-os's
  [`docs/refusals.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/refusals.md) already
  promises this: "`ehosctl` makes one unless you give your own".
- **Fields are typed as HTTPie types them.** `name=value` is text, and `name:=<JSON>` a JSON value.
  `--data` gives a JSON object inline, from `@file` or from `-`, and the fields go over it. A query
  takes a field given twice, or a JSON list, as a repeated parameter, which `EhOsContract.Plug`
  reads as a list. The application decodes every field against its declaration and answers
  `invalid` with the field's name, which `ehosctl` prints in refusals.md's words.
- **D-12.** `call` is not the generated client. It calls the routes that client wraps, with the
  credential that client would carry. It is one more consumer of the same surface, with no back
  door. Once an application ships a generated client, that client is how its code is called from
  other code; `call` stays the way to call any application from a terminal without one.

### Consequences

- Good, because one `ehosctl` calls every application and every version, with nothing to
  regenerate when a contract changes.
- Good, because a call that went unanswered can be sent again safely, by the key `ehosctl` names.
- Good, because no change to EHOS's API or to `eh_os_contract` was needed.
- Bad, because a field's type is checked only by the application: `amount=100` sends the text
  `"100"`, and the application answers that `amount` is of the wrong type. The sentence names the
  field and `call --help` shows `name:=<JSON>`. If that proves too weak, eh-os#333 records it as a
  change to `eh_os_contract`'s manifest, so that `apps` can carry the fields.
- Bad, because every command and recording writes its key into the application's `_commands`,
  even where none was needed. The key `ehosctl` makes is 36 bytes, and the row is written for an accepted
  command either way.
- Neutral: a recording takes a key too. `EhOsContract.Plug` reads one for a recording as for a
  command, and the same reasoning holds.

### Confirmation

- `Ehosctl.CallTest`: the route for each kind, a new UUID key on each command, `--idempotency-key`
  passed through, typed fields, `--data`, the query's lists, and each refusal's sentence and exit
  code, against `Ehosctl.FakeApplication`, which plays `EhOsContract.Plug`'s answers.
- `Ehosctl.CommandTest`: `call` is governed, and names no tool of the platform plane.
- On the local k3d cluster, `ehosctl call` of a command and of a query in a deployed application
  (eh-os#333, "Done when").

## Pros and cons of the options

### A generic client of `EhOsContract.Plug`'s routes

- Good, because it needs only `GET /api/me/applications` and the application's own routes.
- Good, because the application's own checks, the same for every caller, decide what fits.
- Bad, because nothing is checked before the request is sent.

### A client generated from the application's OpenAPI document

- Good, because fields could be typed and checked before sending, and help could list them.
- Bad, because `ehosctl` would read and trust a document per application per call, a second
  request with its own failures, and depend on the OpenAPI shape `eh_os_contract` emits.
- Bad, because it duplicates what the application checks anyway, and would disagree with it
  whenever the two versions differ.

### `GET /api/me/applications` says which commands create their aggregate

- Good, because a key would be sent only where it is needed.
- Bad, because it changes EHOS's API and the manifest for a difference that a fresh key already
  makes harmless.
- Bad, because a command that does not create its aggregate also benefits from a key: it is what
  makes sending a call again safe.

## More information

- `EhOsContract.Plug` and `EhOsContract.Dispatcher`, in
  [eh-os-contract](https://github.com/EmpoweredHouse/eh-os-contract/tree/main/packages/eh_os_contract/lib/eh_os_contract):
  the routes, the answers, and what an idempotency key does.
- [HTTPie's request items](https://httpie.io/docs/cli/request-items), whose `=` and `:=` this
  follows.
- Revisit when `eh_os_contract`'s manifest carries a capability's fields, or when D-12's generated
  client exists and a person would rather call through it.

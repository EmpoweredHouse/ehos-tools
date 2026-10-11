---
status: proposed
date: 2026-10-11
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-12 · `ehosctl call` asks for a capability no role grants, so its refusal is decided and recorded where it belongs

Supersedes [T-10](0010-ehosctl-call-reaches-an-application-through-eh-os-contract-s-routes-found-through-ehos-s-api.md)
in one rule: what `call` does with a capability `apps` does not list. Everything else T-10 decided
holds, and is restated below so that this record reads alone.

## Context and problem statement

T-10 had `call` refuse a capability that `GET /api/v1/me/applications` does not list for the
person, before anything was sent: their credential would not carry it. That refusal decides
nothing, so it leaves no record. The console's same request does: EHOS refuses a credential where a
person's roles grant nothing, `credential.issue` / `no_capability`, and an application refuses a
credential without the capability, `missing_capability`, in its own decisions. eh-os's Stage 7
closes with every refusal recorded alike whichever way it comes (eh-os FM-21, P-4). Its closing test
found the gap on 11 October 2026 ([eh-os#371](https://github.com/EmpoweredHouse/eh-os/issues/371)):
a person without the capability was refused by `ehosctl`, and nothing was recorded.

`ehosctl` knows a capability's kind only from that listing. For one it was not granted, it does not
know whether to send a command, a recording or a query. `EhOsContract.Plug` routes by kind before it
asks anything: a kind that is not the capability's is answered 404 `not_found`, with nothing decided
or written; the right kind reaches the authorizer, which refuses and records.

## Decision drivers

- Every refusal is decided, and recorded, by whoever holds the authority: EHOS for a credential,
  the application for a capability (eh-os FM-21, P-4).
- The same authorization as every other caller (eh-os D-12): `call` does nothing a script with
  `ehosctl credential` and `curl` could not.
- Nothing about an application compiled into `ehosctl`.
- No change to EHOS or `eh_os_contract` for what the client can do alone.

## Considered options

1. **Ask for it, as each kind in turn**: the credential from EHOS, then the capability as a command,
   a recording and a query, until the application finds it.
2. **Ask for it as a command only**: the kind most capabilities are.
3. **Keep refusing it locally** (T-10), and leave such refusals unrecorded.

## Decision outcome

Chosen option: **"Ask for it, as each kind in turn"**, because it is the only one where every
refusal is the authority's, and recorded, whatever the capability's kind. The user chose to ask
EHOS and the application rather than refuse locally, before `ehosctl` 0.3.0 was tagged
([eh-os#371](https://github.com/EmpoweredHouse/eh-os/issues/371)); trying each kind is how `call`
does that without knowing the kind.

- **A listed capability** is sent as its kind says, as T-10 decided: a command
  `POST <address>/api/commands/<capability>`, a recording `POST <address>/api/records/<capability>`,
  each with the fields as a JSON object, a query `GET <address>/api/queries/<capability>` with them
  in the query string.
- **A capability not listed** is asked for. EHOS issues no credential where the person's roles grant
  nothing there, and records the refusal. With a credential, `call` sends the capability as a
  command, then as a recording, then as a query, the next only when the application answers
  `not_found`; a kind the fields cannot make (a field given twice, which only a query takes) is
  left out. The application refuses the credential without the capability, and records it. When
  every kind is not found, the person is told that none of their roles grants it there.
- **An application where none of the person's roles is bound** is still refused by `ehosctl`: EHOS's
  API gives no address for it, so there is nowhere to ask.
- **A name that would leave its place in the path** (`.`, `..`, empty) is refused before anything is
  sent, as `Ehosctl.Api` refuses one in EHOS's listing.
- T-10's other rules hold: a new idempotency key on every command and recording, fields typed as
  HTTPie types them, and `call` as one more consumer of `EhOsContract.Plug`'s routes (D-12).

### Consequences

- Good, because a person refused through `ehosctl` leaves the record the console and the API leave.
- Good, because nothing in EHOS or `eh_os_contract` changes.
- Bad, because a capability not granted costs up to three requests to the application, and sends the
  person's fields to it with each. They go only to the address EHOS listed for the person, with the
  credential EHOS issued them for it.
- Bad, because a capability whose grant was removed meanwhile is still carried by a credential
  issued before, for its ten minutes, and is done if it is a command. That was true of `curl` with
  `ehosctl credential` already (D-12); the application's check, not the listing, is the authority.
- Neutral: a refusal after a gateway's 5xx still says the call may have been done, which is true
  only in that window.

### Confirmation

`test/ehosctl/call_test.exs`: a capability not granted is sent and the application's
`missing_capability` is said, EHOS's `no_capability` is said with nothing sent to the application,
each kind is tried in turn until one is found, a query's repeated field goes only as a query, and a
dot segment is refused before anything is sent. eh-os's closing test of Stage 7
(`test/cluster/ehosctl_test.exs`) has the released binary refused by ehos-ledger, and compares
ledger's record with the one the same call through the API leaves.

## Pros and cons of the options

### Ask for it, as each kind in turn

- Good, because every refusal is recorded, whatever the kind.
- Bad, because up to three requests reach the application for a capability it was not granted.

### Ask for it as a command only

- Good, because one request.
- Bad, because a query or a recording not granted is answered `not_found` and recorded nowhere: the
  gap stays for two kinds of three.

### Keep refusing it locally

- Good, because nothing is sent that would be refused.
- Bad, because the refusal decides nothing and is recorded nowhere, which eh-os FM-21 and P-4 forbid
  for a person's request.

## More information

- `EhOsContract.Plug` and `EhOsContract.Dispatcher` (`route/3`, `call/3`), in
  [eh-os-contract](https://github.com/EmpoweredHouse/eh-os-contract/tree/main/packages/eh_os_contract/lib/eh_os_contract):
  routing by kind before the authorizer.
- Revisit when EHOS's API lists every capability of an application with its kind, granted or not,
  so that `call` sends one request.

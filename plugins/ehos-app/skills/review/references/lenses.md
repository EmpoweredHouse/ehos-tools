# The application's lenses

How a change is reviewed through this application's own lenses: which lenses a change triggers,
how each is applied, how a finding is written and how severe it is. `ehos-app:review` and
`ehos-app:pre-pr-review` both review this way. A reviewer reads this file and
[checklist.md](checklist.md) beside it with its file-reading tool, never by invoking
`ehos-app:review`, which only a user starts: the Skill tool refuses it to a model.

## Choosing the lenses

The changed paths trigger the lenses. Each is a section of [checklist.md](checklist.md).

| Lens | Triggered by | Catches |
|---|---|---|
| Contracts | `lib/<app>/domain.ex`, `lib/<app>/contracts/**`, their implementations, their tests | an event the contract does not declare, a command without a test, an invariant without its `rejected` scenario, a published event changed in place, a promise changed without the process owner |
| Credentials | the router, plugs, `by:` in a contract, `EhOsContract.Auth` config, a page, controller, context or background job that issues a command, a background job a person starts, any `EhOsContract.Actor.credential/3` | a command reachable without `EhOsContract.Auth.Plug`, what a person sends through a page, a controller or `/api` reaching `EhOsContract.dispatch/3`, or going as a `:system` actor, a page handing a context a struct, a job a person starts enqueued before a command of theirs is accepted or again for a duplicate, or acting as them, an actor built with `Actor.credential/3` outside tests, a widened `by:`, a test key trusted outside tests |
| `ehos.yaml` and runtime | `ehos.yaml`, `config/runtime.exs`, the endpoint's and the health plug's config | a host, a connection string or a secret in `ehos.yaml`; ports that disagree with it; a variable EHOS does not give |
| Migrations & rollout | `priv/repo/migrations/**`, removed or renamed fields | DDL at run time, a single-deploy drop, a table outside the application's schema, stale references |
| Other applications | Ecto queries, repos, HTTP clients, `publish` in a contract | reading another application's data, a fact shared other than as a published event |
| App conventions | any file | the rules in the nested `AGENTS.md` that governs it |
| How Elixir is written | `.ex` and `.exs` files, where the application has `docs/elixir.md` | code that breaks one of `ehos-app:elixir`'s numbered rules: a collaborator a test replaces that is not a behaviour, a `@callback` without a `@doc`, a controller that shapes the wire |
| Docs | any behaviour or contract change | topic doc not updated in this PR, ADR citations |

## Applying a lens

Read the lens's section of [checklist.md](checklist.md), read every changed file it covers in full
at `HEAD`, and mark every item of the section PASS, FAIL or N/A. Each FAIL becomes a finding. An
item is never left out: one that does not apply is N/A, with why.

The report shows it, one table per lens, every item of the section in the checklist's order:

```markdown
#### Lens: Credentials
| Item | Mark | Evidence |
|---|---|---|
| Every route to `EhOsContract.Plug` goes through a pipeline with `EhOsContract.Auth.Plug`; no command is reachable without the credential EHOS issued. | FAIL | `router.ex:41` drops it from `/api` (P0 below) |
| A page issues a command through a context function that calls `EhOsContract.call/3` with the actor `EhOsContract.Auth.Session.actor/2` gave for that event. Nothing a person sends through a page, a controller or `/api` (a form, an upload, an import they start there) reaches `EhOsContract.dispatch/3`, from a page, a controller or a context, nor goes as a `:system` actor, but for the job the next item allows; a scheduled job, the sample-data seed and a task run from a shell may. A page may build its changeset with `EhOsContract.Form.changeset` for the person's feedback, and hands the context the params, never a struct (`Form.to_struct/1`, `struct/2`). | N/A | no page issues a command |
| A background job a person starts through a page, a controller or `/api` is enqueued only once a command the request sent as the person with `call/3` is accepted, and is unique by the person's subject and that command's idempotency key with `period: :infinity`, so a duplicate enqueues nothing more; the job does nothing for a command it already processed, since Oban forgets a pruned job. The job then does only the work around the commands the request sent, or runs as a `:system` actor that the domain declares and the command's `by:` names for that job, agreed with the process owner, acting only on what the accepted command holds and recording the person by the subject of the actor `call/3` was given. | N/A | no job issues a command |
| `EhOsContract.Actor.credential/3` appears only in tests: in the application, an actor built with it comes from a credential nobody verified, and `eh_os_contract_auth` builds the actor of one it verified. | PASS | no `Actor.credential` in `lib/` |
| A command's `by:` names the actors the process allows, no wider: it becomes the capability EHOS grants. | N/A | no contract changed |
| `pin_keys: true` and test issuers stay in `config/test.exs`. | N/A | no config changed |
| No secrets in code; input validated at the edge (the contract's fields, Ecto changesets). | PASS | the router change adds no input and no secret |
```

A review whose report has no table for a lens the changed paths trigger has not applied it.

## Findings

```
**P# `file:line` — title**
Why: one sentence of impact.
Fix: the concrete change, not "consider".
Proof: snippet, hunk or call site.
```

Anti-drift: no redesign unless a P0/P1 needs one; no "add tests" without naming the case and what
it asserts; no security claim without an exploit path; no style or naming unless it causes a bug;
only the assigned files; only what this branch changed.

## Severity

When in doubt, downgrade; more than three P0s means inflation.

- **P0** — a real user hits it in normal use and it is serious: data loss or corruption, an
  exploitable hole (auth bypass, injection, XSS, a command reachable without a credential, another
  application's data read), a credential or a person's data written to a log, a 500 on a happy path,
  silently wrong data, a published event changed in place.
  *Not* P0: theoretical races, a user seeing their own data, missing rate limits, UUID-guarded IDOR,
  input the UI never sends.
- **P1** — real but survivable: a UX bug with a workaround, edge-case data bugs, confusing errors,
  perf that profiles but isn't felt, dead code, a new `eh_os_contract.check` finding, stale
  references after a rename, a doc not updated.
- **P2** — style, DRY, hardening, accessibility beyond keyboard, unlikely-path coverage.

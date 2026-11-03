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
| Credentials | the router, plugs, `by:` in a contract, `EhOsContract.Auth` config, a page, controller or context that issues a command | a command reachable without `EhOsContract.Auth.Plug`, a person's command sent to `EhOsContract.dispatch/3` from a page or a context, a widened `by:`, a test key trusted outside tests |
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
| A page issues a command through a context function that calls `EhOsContract.call/3` with the actor `EhOsContract.Auth.Session.actor/2` gave for that event; no page, controller or context sends a person's command to `EhOsContract.dispatch/3`. | N/A | no page issues a command |
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

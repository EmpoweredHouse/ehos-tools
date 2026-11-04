<!--
  SPDX-License-Identifier: Apache-2.0
  SPDX-FileCopyrightText: 2021 The Elixir Team
  Modified: condensed and adapted for the Shugyo backend, then for EHOS applications.
-->

# Design patterns

## Alternative return types and exceptions for control-flow

Check callers and `@spec`/`@doc` together. An option that switches between a row, list, boolean,
and tagged tuple makes callers guess. Prefer a stable contract or separate operations when those
outcomes represent different jobs. Tagged success/error unions are intentional. List
functions may return lists and idempotent side effects may return `:ok`.

Expected not-found, validation, conflict, and provider failures return reasons. Do not rescue
into HTTP 200 or report work queued when `Oban.insert` returns `conflict?: true`. Controllers
delegate to contexts and fallback handling; a new error reason needs its HTTP mapping. Fail-fast
boot configuration and rescue/catch at a runner boundary that records failure are legitimate.

## Boolean obsession and primitive obsession

Several overlapping flags can encode impossible states; prefer a named status when it matches
the domain. Independent booleans are fine. Prefer existing typed schemas/structs over positional
tuples when identity or invariants are otherwise lost. Ownership IDs come from the server, not
cast user input. A new enum must be handled in every consumer and any mirrored wire contract.

## Unrelated multi-clause functions and application configuration

Clauses should describe one operation's cases. Split a function when unrelated operations make
its contract ambiguous; don't split normal pattern-based dispatch by clause count.

Per-call behavior belongs in arguments. Application configuration is global, so never store
per-request state there. How a behaviour chooses its implementation, and how a test replaces it, is
`ehos-app:elixir`'s ([behaviours](../../elixir/references/behaviours.md)); where the application has
the template's test tools (Hammox, `test/support/mocks.ex`), code that departs from it is a finding
(under the "How Elixir is written" lens, in a review through the lenses). Without them, a client
looked up from configuration that tests swap is the application's way, and not a finding in code the
change does not touch.

## Context and persistence checks

Use `AGENTS.md`, the nested guides and topic docs as the contract; these are review prompts:

- A business fact is an event a contract declares, dispatched through `EhOsContract.dispatch/3`.
  A write that records one directly in a table, beside the event log, is a second source of truth.
  Read models are built from events, not written by hand.
- Check that writes sharing an outcome commit together, including dependent job inserts.
  `Ecto.Multi` is the usual shape; callback transactions are appropriate for row locks or
  branching. Show the read/check/write interleaving before recommending `FOR UPDATE`; network
  calls must stay outside locked transactions. Status transitions check the stored row.
- Soft deletion is explicit: confirm active-row filters and association preload filters. Do not
  replace soft deletion of product tables with `Repo.delete`. Changesets expose database unique,
  foreign-key, and check constraint failures as errors.
- Pages and controllers orchestrate (`ehos-app:elixir`, rule 7); channels delegate domain work too.
  Commands reach a contract through `EhOsContract.Plug`, behind `EhOsContract.Auth.Plug`, or, from a
  page, through a context function that calls `EhOsContract.call/3` with the person's actor; flag
  anything a person sends through a page, a controller or `/api` (a form, an upload, an import they
  start there) that reaches `EhOsContract.dispatch/3` from a page, a controller or a context, or
  goes as a `:system` actor, but for the job below, and a page that hands a context a struct. A
  scheduled job, the sample-data seed and a task run from a shell may dispatch. A page that builds
  its changeset with `EhOsContract.Form.changeset` for the person's feedback is not one. A
  background job a person starts is enqueued only once a command their request sent with `call/3` is
  accepted, unique by the person's subject and that command's idempotency key with
  `period: :infinity`, and, when it runs again, skipping the work already done and doing the rest
  (each `:system` command keyed from the person's subject, the request's key and the command's name,
  a mark written with other work, an outside call that passes a key the outside system honours); it
  then does only the work around the commands the request sent, or runs as a `:system` actor that
  the domain declares and the command's `by:` names for that job, agreed with the process owner,
  acting only on what the accepted command holds and recording the person by the subject of the
  actor `call/3` was given. Flag one enqueued before such a command, not unique in Oban by subject
  and key with `period: :infinity`, or doing its work again, or leaving it half done, on a second
  run, or one that issues commands as the person. Flag `EhOsContract.Actor.credential/3` outside
  tests: it builds an actor from a credential nobody verified. Preserve published events: another
  application consumes them.
- SQL fragments are sometimes necessary. Establish untrusted interpolation or incorrect scope
  before flagging them; use Ecto DSL when it can express the operation. Search input for
  `like`/`ilike` escapes `%`, `_` and `\`.
- Migrations run before the new release starts, in the schema EHOS gives the application. Check
  concurrent indexes, byte-limited identifiers, and two-deploy drops against `ARCHITECTURE.md`. A
  deployed migration is not a repair script.

Do not turn these checks into a redesign of a settled boundary. Read the relevant topic doc's
Decisions before proposing a different ownership or service structure.

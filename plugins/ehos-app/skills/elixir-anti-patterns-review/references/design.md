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
per-request state there. A way out of the application is a behaviour whose `current/0` reads
configuration, and a test replaces it with a Hammox mock that `config/test.exs` names, never with
`Application.put_env/3` (`ehos-app:elixir`, [behaviours](../../elixir/references/behaviours.md)).
`current/0` reads at each call only where `config/runtime.exs` chooses the implementation; a
module attribute there freezes the compile-time default into the release. A module that reads a
canned answer, a process to notify or a delay from configuration for a test's sake is a finding:
a test hook in production code.

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
- Controllers/channels delegate domain work. Commands reach a contract through
  `EhOsContract.Plug`, behind `EhOsContract.Auth.Plug`. Preserve published events: another
  application consumes them.
- SQL fragments are sometimes necessary. Establish untrusted interpolation or incorrect scope
  before flagging them; use Ecto DSL when it can express the operation. Search input for
  `like`/`ilike` escapes `%`, `_` and `\`.
- Migrations run before the new release starts, in the schema EHOS gives the application. Check
  concurrent indexes, byte-limited identifiers, and two-deploy drops against `ARCHITECTURE.md`. A
  deployed migration is not a repair script.

Do not turn these checks into a redesign of a settled boundary. Read the relevant topic doc's
Decisions before proposing a different ownership or service structure.

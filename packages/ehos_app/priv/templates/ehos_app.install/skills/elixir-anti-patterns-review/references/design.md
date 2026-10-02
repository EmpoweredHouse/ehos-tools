<!--
  SPDX-License-Identifier: Apache-2.0
  SPDX-FileCopyrightText: 2021 The Elixir Team
  Modified: condensed and adapted for the Shugyo backend.
-->

# Design patterns

## Alternative return types and exceptions for control-flow

Check callers and `@spec`/`@doc` together. An option that switches between a row, list, boolean,
and tagged tuple makes callers guess. Prefer a stable contract or separate operations when those
outcomes represent different jobs. Tagged success/error unions are intentional. Backend list
functions may return lists and idempotent side effects may return `:ok`.

Expected not-found, validation, conflict, and provider failures return reasons. Do not rescue
into HTTP 200 or report work queued when `Oban.insert` returns `conflict?: true`. Controllers
delegate to contexts and fallback handling; a new error reason needs its HTTP mapping. Fail-fast
boot configuration and rescue/catch at a runner boundary that records failure are legitimate.

## Boolean obsession and primitive obsession

Several overlapping flags can encode impossible states; prefer a named status when it matches
the domain. Independent booleans are fine. Organization `status` and `setup_state` are distinct
concepts, not competing flags to collapse. Prefer existing typed schemas/structs over positional
tuples when identity or invariants are otherwise lost. Ownership IDs come from the server, not
cast user input. A new enum must be handled in every consumer and any mirrored wire contract.

## Unrelated multi-clause functions and application configuration

Clauses should describe one operation's cases. Split a function when unrelated operations make
its contract ambiguous; don't split normal pattern-based dispatch by clause count.

Per-call and per-organization behavior belongs in arguments. Application configuration is global,
so never store a current organization or its prefix there. The configured behaviour seam used by
external clients and the Wiki publication callback is deliberate; retain runtime lookup so tests
can replace implementations. Moving it into a module attribute can freeze the wrong client.

## Shugyo context and persistence checks

Use the current backend guide and topic docs as the contract; these are review prompts:

- For business data, trace organization identity and explicit `prefix:` through queries, writes,
  preloads, bulk operations, and raw SQL. Claims/Wiki validate `organization_id:` plus `prefix:`
  or derive scope from a persisted run. Public identity/configuration schemas are intentional
  exceptions; a prefix-less `Repo` call is not automatically a tenant leak.
- Check that writes sharing an outcome commit together, including dependent job inserts.
  `Ecto.Multi` is the usual shape; callback transactions are appropriate for row locks or
  branching. Show the read/check/write interleaving before recommending `FOR UPDATE`; network
  calls must stay outside locked transactions. Status transitions check the stored row.
- Soft deletion is explicit: confirm active-row filters and association preload filters. Do not
  replace soft deletion of product tables with `Repo.delete`. Changesets expose database unique,
  foreign-key, and check constraint failures as errors.
- Controllers/channels delegate domain work. Respect the umbrella dependency direction and the
  Claims/Wiki facades. Prompts, output schemas, and model choices belong to AI; BigQuery access
  goes through its read-only service. Preserve wire mirrors and frozen surfaces.
- SQL fragments are sometimes necessary. Establish untrusted interpolation or incorrect scope
  before flagging them; use Ecto DSL when it can express the operation. Search input for
  `like`/`ilike` uses `Api.QueryHelpers.escape_like/1`.
- Migrations belong to the public or tenant chain, never the unused default migrations directory.
  Check concurrent indexes, byte-limited identifiers, and two-deploy drops against the deployment
  contract. A deployed baseline is not a repair script.

Do not turn these checks into a redesign of a settled boundary. Read the relevant topic doc's
Decisions before proposing a different ownership or service structure.

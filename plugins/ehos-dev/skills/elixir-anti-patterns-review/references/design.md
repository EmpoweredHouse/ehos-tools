<!--
  SPDX-License-Identifier: Apache-2.0
  SPDX-FileCopyrightText: 2021 The Elixir Team
  Modified: condensed and adapted for the Shugyo backend, then for EHOS applications, then for
  EHOS's own libraries, CLI and platform.
-->

# Design patterns

## Alternative return types and exceptions for control-flow

Check callers and `@spec`/`@doc` together. An option that switches between a row, list, boolean,
and tagged tuple makes callers guess. Prefer a stable contract or separate operations when those
outcomes represent different jobs. Tagged success/error unions are intentional. List
functions may return lists and idempotent side effects may return `:ok`.

Expected not-found, validation, conflict, and outside-system failures return reasons. Do not
rescue into a success, an HTTP 200 or an exit code of 0. Controllers delegate to contexts and to
their fallback; a new error reason needs its mapping to an answer in the same change. A Mix task
or a CLI command turns a reason into its message and a non-zero exit in one place. Fail-fast boot
configuration, and rescue/catch at a boundary that records the failure, are legitimate.

## Boolean obsession and primitive obsession

Several overlapping flags can encode impossible states; prefer a named status when it matches
the domain. Independent booleans are fine. Prefer existing typed schemas/structs over positional
tuples when identity or invariants are otherwise lost. Ownership IDs come from the server, not
cast user input. A new value of an enum must be handled in every consumer and in any wire format
that mirrors it: an API's answer, a CRD's schema, a JSON Schema in `priv/`.

## Unrelated multi-clause functions

Clauses should describe one operation's cases. Split a function when unrelated operations make
its contract ambiguous; don't split normal pattern-based dispatch by clause count.

## Application configuration

Per-call behaviour belongs in arguments. Application configuration is global: never store
per-request state there, and never change it from a test, which is then no longer `async`.

- **A library reads no `Application` env.** Its configuration is its consumer's: it takes options
  in the call, with their defaults in its `@doc`, and its implementation of a behaviour in `opts`
  (`ehos-dev:elixir`, rule 2). A library that reads its own app env makes two consumers in one VM
  share one value. This is Elixir's own anti-pattern, "Using application configuration for
  libraries".
- **A CLI chooses implementations at compile time**, and reads its settings from the process
  environment through a behaviour.
- **A Phoenix platform reads its settings at boot**, in `config/runtime.exs`, validated by one
  function per area that holds the defaults; later code fetches them with no default of its own
  (`ehos-dev:elixir`, [structure.md](../../elixir/references/structure.md), "Settings").
- **A test hook is a finding**: a value read from configuration that no production configuration
  sets, read for a test's sake (a canned answer, a delay, a flag, a function in place of DNS). So
  is a test that swaps an implementation or a setting with `Application.put_env/3` or
  `System.put_env/2`, in code the repository's rules already cover.

## Context and persistence checks

Use the repository's rules and `ehos-dev:elixir`'s [data.md](../../elixir/references/data.md)
as the contract; these are review prompts:

- A query over a table outside the context that owns it, or in the web layer, is a finding where
  the repository's rules cover that code. The one exception is the query over two contexts'
  tables that `data.md` allows: in one statement, with its measurement beside it, owned by the
  context whose question it answers, applying the other context's filters, with a test that
  compares its answer with the two contexts' own functions. One that lacks any of these is a
  finding. So is a function that returns an `Ecto.Query` for a
  caller to finish.
- Check that writes sharing an outcome commit together. `Ecto.Multi` is the usual shape; a
  function given to `Repo.transact/2` is appropriate for row locks or branching. Show the
  read/check/write interleaving before recommending `FOR UPDATE`; network calls stay outside a
  transaction. A status transition checks the stored row, with a `where` on the state it expects.
- An insert whose collision on a constraint is a refusal maps it with `unique_constraint/3` or
  its kin; a raised `Ecto.ConstraintError` where a refusal was due is a finding, and so is an
  `on_conflict` (`:nothing` or a replace) that hides a refusal, or one without a
  `conflict_target`, or a caller that reads a `nil` id after `insert/2` where Ecto generates the
  id, which is never `nil`. `on_conflict` is for a duplicate that is harmless. A check-then-insert
  is a race unless the constraint decides and its answer is mapped.
- A changeset that casts a field the code sets (the actor, an owner, a status) lets params set
  it. A form built from a map, where a changeset holds its rules, shows no error at its field.
- An `insert_all` or `update_all` that ignores its count, where the count says whether this
  request won a race, loses the refusal.
- SQL fragments are sometimes necessary. Establish untrusted interpolation or incorrect scope
  before flagging them; use the Ecto DSL when it can express the operation. Search input for
  `like`/`ilike` escapes `%`, `_` and `\`.
- A migration is applied before the code that needs it runs, and may run against a table that
  has rows. Check that an index on a large table is built concurrently, that a column is dropped
  only once no running code reads it, and that a migration's version is unique. A migration
  already applied somewhere is never edited.

## Clients of outside systems

- A client of an outside system (HTTP, a cluster's API, a program) is a behaviour with its
  implementation beside it (`ehos-dev:elixir`, rule 1). A module that is not that implementation
  and calls `Req`, `System.cmd/3` or `Port.open/2` is a finding in code the rule covers.
- Each call has a timeout, a bound on what it reads, and redirects it does not follow blindly. An
  option a caller gives is merged before those bounds, never after, so no caller lifts them.
- An error from the outside system names what failed, never a token or a header it was sent.

Do not turn these checks into a redesign of a settled boundary. Read the repository's records on
it (`docs/adr/`) before proposing a different ownership or structure.

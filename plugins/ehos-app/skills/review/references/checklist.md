# Review checklist

One section per lens in [lenses.md](lenses.md), which says which lenses a change triggers. Mark each item PASS / FAIL / N/A; a FAIL is a finding. Each
item names the file or check that is the source of truth; the reasoning lives in the doc named in
the heading, not here.

## Contracts — `lib/<app>/contracts/AGENTS.md`

- [ ] Every business fact the change records is an event its contract declares; the
      implementation emits nothing outside the command's `emits:`.
- [ ] Every new command has a test that dispatches it, and every new invariant a `rejected`
      scenario; `mix eh_os_contract.check` passes with no new finding.
- [ ] A published event (`publish ... as: "<domain>.<...>.v<n>"`) is not changed in place: a new
      shape is a new version, since another application consumes it.
- [ ] A changed `promise`, `deadline` or `cadence` is called out in the PR for the process owner,
      who approves the contract.
- [ ] A policy or an effect delivered `:at_least_once` names what makes a second delivery
      harmless, and nothing slow or outside the database runs `:in_transaction`.

## Credentials — `ARCHITECTURE.md`

- [ ] Every route to `EhOsContract.Plug` goes through a pipeline with `EhOsContract.Auth.Plug`;
      no command is reachable without the credential EHOS issued.
- [ ] A command's `by:` names the actors the process allows, no wider: it becomes the capability
      EHOS grants.
- [ ] `pin_keys: true` and test issuers stay in `config/test.exs`.
- [ ] No secrets in code; input validated at the edge (the contract's fields, Ecto changesets).

## `ehos.yaml` and runtime — `ARCHITECTURE.md`

- [ ] `ehos.yaml` states what the application needs and never how: no host, connection string,
      image or secret; it still validates against the schema its `schema:` names (`ehosctl verify`).
- [ ] The ports the endpoints listen on are the ones `ehos.yaml` declares.
- [ ] `config/runtime.exs` reads only the variables EHOS gives an application, and reads them
      with `System.fetch_env!/1` where a missing one must stop the boot.

## Migrations & rollout — `ARCHITECTURE.md`

- [ ] Reversible: `change` that Ecto can invert, or both `up` and `down`.
- [ ] New columns are nullable or defaulted; constraints land after the data is clean.
- [ ] Migrations run **before** the new release starts, so the old release must survive the new
      schema: a drop (`remove`, `drop`, `drop_if_exists`) ships in two deploys — code that stops
      reading it first, the drop in a later commit. A PR carrying both is the bug.
- [ ] No DDL outside a migration: the application's runtime role may read and write, never change
      a table.
- [ ] Tables go in the schema EHOS gives the application (`DATABASE_SCHEMA`, the connection's
      search path): a migration names no other schema, and creates none.
- [ ] After a rename or removal, `git grep <old_name>` hits only migration and schema files; any other
      hit (serializer, fixture, template, doc) is stale.

## Other applications — `VISION.md`

- [ ] Nothing reads another application's database, schema or tables.
- [ ] A fact another application needs leaves this one as an event a contract publishes, never
      through a table or an endpoint the other reads.
- [ ] A call that acts on an outside system as a step of a process is an `effect` that `calls:` an
      `external` the domain declares; the client it calls is a way out ("How Elixir is written").

## App conventions — the nested `AGENTS.md`

- [ ] The rules of the `AGENTS.md` that governs each changed file hold (the root one lists them).
- [ ] Public functions have a `@spec`; context functions return `{:ok, _}` / `{:error, _}`;
      controllers delegate to contexts.
- [ ] Test refactors preserve meaning and follow the project's `TESTING.md`. Style
      alone is P2.
- [ ] Moduledocs say what the module is and its contract; rationale lives in the doc, not restated.
      A platform decision or a contract's `source:` may be cited; a task id, ticket or plan not.

## How Elixir is written — `docs/elixir.md`

The application's part of `docs/elixir.md` wins where it differs; `ehos-app:elixir` explains each.
Only where the application has `docs/elixir.md` and the template's test tools (Hammox,
`test/support/mocks.ex`): without them, an item is N/A, and the report says so, naming the
release of `ehos_app` that brings them once its `CHANGELOG.md` names one. Code the change does not touch is not a finding.

- [ ] A way out of the application (an outside system, EHOS's APIs, mail, the clock) is a
      behaviour with `current/0`; a contract's part has none on top of the contract's.
- [ ] Tests replace a way out with the Hammox mock `config/test.exs` names: no
      `Application.put_env/3` in a test, and no test made non-async for it.
- [ ] No test hook in production code: no canned answer, pid or delay read from configuration.
- [ ] Only a table's owner uses `Ecto.Query`, and it answers rows (`test/conventions_test.exs`).
- [ ] A changeset is for a form or an outside answer; a projection writes with
      `insert_all`/`update_all`; an invariant lives in the contract, not in a changeset.
- [ ] A LiveView or controller makes one domain call and renders; it neither composes domain
      calls nor reshapes their data. Its test runs the real context or mocks the function it
      calls, never what lies beneath, and never the sign-in pipeline or `EhOsContract.Auth`.
- [ ] No `case` or `with` inside another.
- [ ] Tests build data with the factories, are named as scenarios, and compare whole answers with
      `==`.

## Docs — root `AGENTS.md`

- [ ] Behaviour, a contract or a decision changed → the owning doc (`docs/*.md`, a nested
      `AGENTS.md`, `ARCHITECTURE.md` or `TESTING.md`) is updated in this PR; a shipped plan's
      lasting content moved there.
- [ ] No `ADR NNN` citations; comments link a doc file, not a section number (the harness test).
- [ ] Tests came with the change, and `mix precommit` is green.

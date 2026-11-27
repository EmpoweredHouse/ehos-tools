# Review checklist

One section per lens in [lenses.md](lenses.md), which says which lenses a change triggers. Mark each
item PASS / FAIL / N/A; a FAIL is a finding. Each item names the file or check that is the source of
truth; the reasoning lives in the doc named in the heading, not here.

## Contracts — `lib/<app>/contracts/AGENTS.md`

- [ ] Every business fact the change records is an event its contract declares; the
      implementation emits nothing outside the command's `emits:`.
- [ ] Every new command has a test that dispatches it, and every new invariant a `rejected`
      scenario; `mix ehos_contract.check` passes with no new finding.
- [ ] A published event (`publish ... as: "<domain>.<...>.v<n>"`) is not changed in place: a new
      shape is a new version, since another application consumes it.
- [ ] A changed `promise`, `deadline` or `cadence` is called out in the PR for the process owner,
      who approves the contract.
- [ ] A policy or an effect delivered `:at_least_once` names what makes a second delivery
      harmless, and nothing slow or outside the database runs `:in_transaction`.

## Credentials — `ARCHITECTURE.md`

- [ ] Every route to `EhosContract.Plug` goes through a pipeline with `EhosContract.Auth.Plug`;
      no command is reachable without the credential EHOS issued.
- [ ] A page issues a command through a context function that calls `EhosContract.call/3` with the
      actor `EhosContract.Auth.Session.actor/2` gave for that event. Nothing a person sends through
      a page, a controller or `/api` (a form, an upload, an import they start there) reaches
      `EhosContract.dispatch/3`, from a page, a controller or a context, nor goes as a `:system`
      actor, but for the job the next item allows; a scheduled job, the sample-data seed and a task
      run from a shell may. No module in `lib/` but the seed acts as `:sample_data`. A
      form's params go to `call/3` as the form sent them, with `form: true` and the page's `data:`,
      never converted by hand. A page may build its changeset with `EhosContract.Form.changeset` for
      the person's feedback, and hands the context the params, never a struct (`Form.to_struct/1`,
      `struct/2`).
- [ ] A background job a person starts through a page, a controller or `/api` is enqueued only once
      a command the request sent as the person with `call/3` is accepted, and is unique in Oban by
      the person's subject and that command's idempotency key with `period: :infinity`, so a
      duplicate enqueues nothing more while a job with those keys is waiting, running, retrying or
      completed. A job that runs again skips the work already done and does the rest: each `:system`
      command carries its own key, made from the person's subject, the request's key, the command's
      name and, for a command sent once per item, the item's id; other work writes its mark in its
      own transaction; and an outside call passes a key the outside system honours, or is first
      claimed with a unique mark. The job then does only the work around the commands the request
      sent, or runs as a `:system` actor that the domain declares and the command's `by:` names for
      that job, agreed with the process owner, acting only on what the accepted command holds and
      recording the person by the subject of the actor `call/3` was given.
- [ ] `EhosContract.Actor.credential/3` appears only in tests: in the application, an actor built
      with it comes from a credential nobody verified, and `ehos_contract_auth` builds the actor of
      one it verified.
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
- [ ] A call that acts on an outside system as a step of a process is a contract's effect, as rule 1
      of `ehos-app:elixir` says.

## App conventions — the nested `AGENTS.md`

- [ ] The rules of the `AGENTS.md` that governs each changed file hold (the root one lists them).
- [ ] Test refactors preserve meaning and follow the project's `TESTING.md`. Style
      alone is P2.
- [ ] Moduledocs and comments follow rule 10 of `ehos-app:elixir`, with or without
      `docs/elixir.md`: no separator comments, no dead code.

## How Elixir is written — `ehos-app:elixir`

The rules are `ehos-app:elixir`'s, numbered in its [`SKILL.md`](../../elixir/SKILL.md), "The rules,
in one place", and its references say what each holds; the application's part of `docs/elixir.md`
wins where it differs. Mark each rule by its number. Only where the application has `docs/elixir.md`
and the template's test tools (Hammox, `test/support/mocks.ex`): without them, an item is N/A, and
the report says so, naming the release of `ehos_app` that brings them once its `CHANGELOG.md` names
one. Code the change does not touch is not a finding. Rule 10 is marked under "App conventions".

- [ ] Rule 1: a collaborator a caller's test replaces is a behaviour, and each of its `@callback`s
      has a `@doc`; an Oban worker calls its collaborators through their `current()`.
- [ ] Rule 2: a test replaces a behaviour with a Hammox mock.
- [ ] Rule 3: no test hook in production code.
- [ ] Rule 4: the clock, randomness, generated ids and the environment are ways out where a test
      says what they return; no `System.get_env` in `lib/`.
- [ ] Rule 5: a table is read only by the module that owns it (`test/conventions_test.exs`).
- [ ] Rule 6: a changeset is for a form or an outside system's answer.
- [ ] Rule 7: a page or controller orchestrates, and its `*HTML` or `*JSON` module shapes the wire.
- [ ] Rule 8: control flow stays flat.
- [ ] Rule 9: tests build data with factories, read as scenarios, and compare with `==`.
- [ ] Rule 11: public functions have a `@spec`; a context function that can fail returns
      `{:ok, _}` / `{:error, _}`.
- [ ] Rule 12: a new context declares its boundary, and the root exports only what is called.

## Docs — root `AGENTS.md`

- [ ] Behaviour, a contract or a decision changed → the owning doc (`docs/*.md`, a nested
      `AGENTS.md`, `ARCHITECTURE.md` or `TESTING.md`) is updated in this PR; a shipped plan's
      lasting content moved there.
- [ ] No `ADR NNN` citations; comments link a doc file, not a section number (the harness test).
- [ ] Tests came with the change, and `mix precommit` is green.

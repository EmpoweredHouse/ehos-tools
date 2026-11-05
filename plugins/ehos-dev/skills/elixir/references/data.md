# Data

How code that keeps data with Ecto is shaped: who queries a table, where input is checked, how the
writes of one decision commit together, and what a refusal looks like. It applies where the
repository has a `Repo`, as eh-os does; a library or a CLI without one has nothing here. An
application built on EHOS has its own rules, which add a contract engine to these
(`ehos-app:elixir`, its `references/data.md`).

The examples are illustrations, with names a Phoenix platform might use; check what the
repository has before calling a module by name.

## A table and its owner

Every table has one owning context. It is the only code that builds an `Ecto.Query` over the
table, but for the one exception below, and it answers rows (structs, maps or counts), never a
query for a caller to finish. A caller that needs another filter asks the owner for a function
that applies it.

```elixir
# The owner
@spec active(Ecto.UUID.t()) :: [Environment.t()]
def active(application_id) do
  Repo.all(
    from e in Environment, where: e.application_id == ^application_id and is_nil(e.removed_at)
  )
end

# Not: a query returned for a caller to pipe into Repo.all/1
def for_application(id), do: from(e in Environment, where: e.application_id == ^id)
```

- **A list over a table that grows** (events, deployments, history) takes a limit or a cursor
  from its caller, with a default and a maximum of its own, so no caller asks for every row. A
  read that must see every row pages by cursor (keyset on an indexed column), each page a short
  query; a `Repo.stream/2` holds its transaction, a connection of the pool and a snapshot for as
  long as it runs, and does no write or network call per row.
- **Input reaches a query only as a parameter**: a value goes into a `fragment` with `^`, and
  into SQL given to `Repo.query/3` in its list of parameters, never by interpolation into the
  string. Search input escapes `%`, `_` and `\` before `like` or `ilike`, so a person cannot
  widen the match; the limit above, or an index (`pg_trgm` for a search inside the text), bounds
  what the search costs.

A context that needs another's rows calls the other context's function; it does not join the
other's table on its own. The one exception is a query that must read two contexts' tables in
one statement for its speed, with the measurement in a comment beside it. The context whose
question it answers owns the query, and the other exports the schema it needs in its boundary
([structure.md](structure.md), "A context is a boundary"). The query applies the filters that
the other context's functions apply (removed rows, scope), and a test compares its answer with
the same rows read through the two contexts' own functions. The export lets every context that
depends on the other name the schema, so a review checks that only this query does.

## Changesets for input

A changeset casts and validates what arrives from outside: a form's params, an API's body, an
outside system's answer. The rest of the code then receives data of a known shape, and a wrong
value comes back as an error on its field.

- **A form is built from a changeset**, `to_form(changeset)`, so the page shows each error beside
  its field. Where no schema holds the form's fields, the changeset is schemaless:

  ```elixir
  @types %{name: :string, ttl_hours: :integer}

  @spec ephemeral_request(map()) :: Ecto.Changeset.t()
  def ephemeral_request(params) do
    {%{}, @types}
    |> Ecto.Changeset.cast(params, Map.keys(@types))
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_number(:ttl_hours, greater_than: 0, less_than_or_equal_to: 72)
  end
  ```

- **A field the code sets is never cast**: the actor, an owner's id, a status the code decides.
  Put it on the struct before the changeset, so no params can set it.
- **One place checks an input.** Where a parser or a JSON Schema already refuses a document (a
  manifest, a file a person uploads), the code that writes it does not validate it again in a
  changeset; the two would drift. That one check runs inside the context's write function, so
  every way in (the console, the API, `ehosctl`, a Mix task) goes through it.
- **A row the code builds for itself** from values it already holds (a token, an audit event, a
  status it computed) needs no changeset for its fields. Where the insert can collide on a
  constraint, it still needs a changeset that maps the collision to a refusal (below), or, where
  a duplicate is harmless, `on_conflict` (the idempotent insert under "When `insert_all` and
  `update_all` stay"). `on_conflict` gives no refusal: it skips or replaces the row, and the
  caller gets `{:ok, _}`.

## A constraint is a refusal

A unique index, a foreign key or a check constraint decides what a race between two requests
cannot. Check-then-insert is that race: two requests both read "no such name" and both insert.
Let the database decide, and map its answer to a refusal on the changeset:

```elixir
%Environment{application_id: application_id}
|> Ecto.Changeset.cast(params, [:name])
|> Ecto.Changeset.unique_constraint(:name, name: :environments_application_id_name_index)
|> Repo.insert()
# {:error, changeset} with "has already been taken" on :name, not an Ecto.ConstraintError
```

`foreign_key_constraint/3`, `assoc_constraint/3`, `no_assoc_constraint/3` and
`check_constraint/3` do the same for the other kinds. A constraint with no mapping raises, and a
person sees a crash where a sentence was due. The context turns the changeset's error into the
refusal its callers know (`{:error, :name_taken}`, or the changeset itself for a form).

## The writes of one decision

Writes that share one outcome commit together, or none of them does.

- **`Ecto.Multi`** names each step of a decision, so a failure says which step failed and the
  steps read as the decision does:

  ```elixir
  Ecto.Multi.new()
  |> Ecto.Multi.update(:promotion, Promotion.approve(promotion, approver))
  |> Ecto.Multi.insert(:deployment, fn %{promotion: p} -> Deployment.from_promotion(p) end)
  |> Ecto.Multi.insert(:audit, fn %{promotion: p} -> Audit.event(:promotion_approved, p) end)
  |> Repo.transact()
  ```

- **A function given to `Repo.transact/2`** where a step branches on what an earlier one read, or
  takes a row lock (`lock: "FOR UPDATE"`) first. It returns `{:ok, value}` or `{:error, reason}`,
  and an expected failure inside it returns `{:error, reason}`, which rolls back.
- **One write is not a transaction.** A single insert or update needs no `Multi`.
- **No call to the network inside a transaction.** A request that waits holds the transaction and
  its locks for as long; do it before, or after the commit, with what the commit returned.

## When `insert_all` and `update_all` stay

A bulk write skips the changeset on purpose where it decides something a changeset cannot. Each
says why in a comment, so a reader does not turn it into a changeset:

- **An idempotent insert**: `insert_all/3` or `insert/2` with `on_conflict: :nothing` and a
  `conflict_target` that lists the columns of the one unique index whose duplicate is harmless,
  so a second delivery of the same fact inserts nothing and is not an error. Without a target,
  PostgreSQL skips a collision on any unique index, a refusal included. A duplicate is harmless
  only when the same key always carries the same values. The call reports success with no row.
  To know whether this request inserted, the caller reads `insert_all`'s count; `insert/2`
  answers a `nil` id only where the database generates the id, so with an id the code generates
  (an autogenerated `:binary_id`), use `insert_all` and its count. Re-read the row where the
  caller needs it.
- **A conditional update against a race**: `update_all/3` with a `where` on the state it expects
  (`where: p.status == :pending`), whose count says whether this request won. A count of 0 is a
  refusal (`{:error, :already_decided}`), never ignored.
- **Rows the code builds in bulk**, from values it already checked: an import, a backfill. They
  go in chunks (`Stream.chunk_every/2`), one `insert_all` each, below PostgreSQL's limit of
  65,535 parameters in one statement.

## What a context answers

A context function that can fail returns `{:ok, value}` or `{:error, reason}`, and one that cannot
(a list of rows, a count) returns its value. A context's reason is an atom or a struct the callers
can match, never a string to parse; what a CLI or a library returns is
[behaviours.md](behaviours.md)'s `{:error, message}`. The web layer maps each reason to what a
person or a client sees, in one place (a controller's fallback, a LiveView's function for
refusals): a new reason needs its mapping in the same change.

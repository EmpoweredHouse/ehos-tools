# Data and pages

## A table and its owner

Every table outside the engine's own has one owning module. It is the only module that builds an
`Ecto.Query` over the table, and it answers rows (structs or maps), never a query for a caller to
finish. A caller that needs another filter asks the owner for a function that applies it.

```elixir
# The owner
def unpaid_orders(customer_id),
  do: Repo.all(from o in Order, where: o.customer_id == ^customer_id and is_nil(o.paid_at))

# Not: a query returned for a caller to pipe into Repo.all/1
def orders_query(customer_id), do: from(o in Order, where: o.customer_id == ^customer_id)
```

`test/conventions_test.exs` holds this: it fails when a module that is not a table's owner uses
`Ecto.Query`. Modules written before the rule are listed there, and the list only shrinks.

A read model the engine projects is a contract's part, and the contract says who reads it.

## Changesets

- **For input from outside**: a form's params, an outside system's answer. A changeset casts and
  validates what arrives, so the rest of the code receives data of a known shape.
- **Never for a projection.** A projection writes what an event already decided, with
  `Repo.insert_all/3` or `Repo.update_all/3`; there is nothing left to validate.
- **The contract keeps the invariants.** A changeset checks input; whether a command may happen is
  the decider's. A rule written in both drifts.
- A form for a contract's command casts with the changeset the contract gives, where it gives one
  ([eh-os-contract#474](https://github.com/EmpoweredHouse/eh-os-contract/issues/474)).

## A context

A context is the application's own API for one area: its functions are what pages, controllers,
jobs and other contexts call. It returns `{:ok, value}` or `{:error, reason}` where it can fail,
and composes its ways out and its tables. Normalise input at its boundary, once.

## A page or a controller

A LiveView or a controller orchestrates: it reads params, makes one call to a context, and
renders what comes back. It does not compose several domain calls, decide what a result means, or
reshape domain data for the template; each of those is a context function, or a function
component's job. A LiveView past a few hundred lines is doing a context's work.

Its test mocks the context function it calls ([testing.md](testing.md), "Mock what the caller
calls") and checks what it renders and where it navigates.

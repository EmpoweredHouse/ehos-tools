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

A read model the engine projects is a contract's part, and the contract says who reads it. Its
projection owns the read model's table, and is the module that queries it to write.

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
jobs and other contexts call. Each public function has a `@spec`. One that can fail returns
`{:ok, value}` or `{:error, reason}`; one that cannot (a list of rows, a count) returns its
value, since a caller would only unwrap an `{:ok, _}` that is never anything else. A context
composes its ways out and its tables, and normalises input at its boundary, once.

A context a page calls is a behaviour where the page's test should not run it
([behaviours.md](behaviours.md)): the page calls `Shop.Orders.current().unpaid(customer_id)`.

## A page or a controller

A LiveView or a controller orchestrates: it reads params, makes one call to a context, and
renders what comes back. It does not compose several domain calls, decide what a result means, or
reshape domain data for the template; each of those is a context function, or a function
component's job. A LiveView past a few hundred lines is doing a context's work.

What goes over the wire is shaped by the controller's `*HTML` or `*JSON` module (Phoenix's views
since 1.7), never by the controller: the names of a JSON answer's fields, a date as ISO 8601, a
URL built from a route. The controller hands `render/3` what the context answered, as it is.

```elixir
# The controller
def show(conn, %{"id" => id}) do
  case Shop.Orders.current().order(conn.assigns.actor, id) do
    {:ok, order} -> render(conn, :show, order: order)
    {:error, :not_found} -> send_resp(conn, 404, "")
  end
end

# OrderJSON
def show(%{order: order}) do
  %{id: order.id, total: order.total, paid_at: order.paid_at && DateTime.to_iso8601(order.paid_at)}
end
```

A contract's command reaches the application through `EhOsContract.Plug`, whose answer's shape is
the contract's: no `*JSON` module of the application's shapes it.

Checking who may see the page is not composing domain calls: the router's `:signed_in`
pipeline and `on_mount` do it before the page runs, and the context function it calls takes the
actor and refuses for itself. Its test is in [testing.md](testing.md), "Mock what the caller
calls": it checks what the page renders and where it navigates.

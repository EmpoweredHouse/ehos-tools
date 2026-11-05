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

## Boundaries

Where the application has [Boundary](https://hexdocs.pm/boundary) (`ehos_app`'s template gives a
new project it), the compiler holds the areas apart. The template declares four:

- **The root module**, `Shop`, whose `exports:` are what the web and the application call: a
  context, `LogRedaction`. What it does not export is private to it.
- **The web**, `ShopWeb`, which `deps:` on `Shop` alone, and so reaches its exports and never
  `Shop.Repo`.
- **`Shop.Application`**, a top-level boundary above both, since it starts them.
- **`Shop.Repo`** and the template's behaviours (`Shop.Clock`, `Shop.Access`), each a boundary of
  its own inside the root, so a context names what it uses.

A new context declares its boundary in its root module, listing the siblings it uses, and the
root exports it once the web or another top-level boundary calls it:

```elixir
defmodule Shop.Orders do
  @moduledoc "The orders a customer places and pays."
  use Boundary, deps: [Shop.Repo, Shop.Clock], exports: [Order]
end

defmodule Shop do
  use Boundary, deps: [], exports: [Access, LogRedaction, Orders, Orders.Order]
end
```

A context that needs another lists it in `deps:`; two that need each other are one context, or a
third that both use. `mix compile --warnings-as-errors` fails on a reference no boundary allows.
A contract's parts live in the root, private to it: the engine calls them, not the web.

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

## A page that issues a command

A page issues a command as the person signed in through the engine's other door,
`EhOsContract.call/3` (`calls.md`, "Call the contract from other code", in `eh_os_contract`'s docs):
the capability's name, the form's params, the person's actor. The engine asks its `Authorizer`
first, as `EhOsContract.Plug` does, so a person without the capability is refused whatever they
sent. A context function makes the call. `call/3` is the one way in for what a person sends, as for
a request to `/api`: it asks whether they may before it says what is wrong with the params, refuses
a field the host supplies, and checks the rest as the plug does. `EhOsContract.dispatch/3` asks the
`Authorizer` about a person's actor too, but takes a struct the application built, and asks no one
about a `:system` actor: it is for code that runs with no request through the application's doors,
such as a scheduled job, the sample-data seed as `:sample_data`, or a task run from a shell or a
release. So what a person sends through a page, a controller or `/api` (a form, an upload, an import
they start there) never goes to `dispatch/3`, from a page, a controller or a context, nor as a
`:system` actor but for one kind of job below. The one exception is a background job a person starts
there, such as an upload an Oban job processes after their credential has expired. The request that
starts it goes through `call/3` like any other: it sends a command as the person, such as one that
records the upload, and enqueues the job only once that command is accepted, so the `Authorizer` and
the person's scopes are asked first. A request sent again is accepted as a duplicate, and the job
does its work once. The job is unique in Oban by the person's subject and the command's idempotency
key (`unique: [period: :infinity, keys: [:subject, :idempotency_key]]`, both in its args, with
Oban's default `states:`): a duplicate enqueues nothing more while a job with those keys is waiting,
running, retrying or completed, and one sent again after an enqueue was lost still enqueues it. A
job that runs again, retried, or enqueued again once Oban pruned, discarded or cancelled its row,
skips the work already done and does the rest, which it does not learn from Oban: each `:system`
command it sends carries its own idempotency key, made from the person's subject, the request's key,
the command's name and, for a command sent once per item, the item's id, and hashed when it would
pass the engine's 255 bytes, so a second run gets a duplicate receipt; other work writes its mark in
the transaction of that work, and a call to an outside system passes the key to a system that
honours it, or else first claims the call with a unique mark in its own transaction, so two runs
that overlap cannot both make it. The job then either does only the work around the commands the
request sent, or runs as a `:system` actor that the domain declares and the command's `by:` names
for that job, agreed with the process owner. Such a job acts only on what the accepted command
holds, and records the person by the subject of the actor `call/3` was given, never by one from the
params. It never rebuilds the person's actor with `EhOsContract.Actor.credential/3`: the
`Authorizer` would be asked about capabilities from the past, or forged ones, so a capability
revoked since still works. In the application, only tests call that function; `eh_os_contract_auth`
builds the actor from a credential it verified.

A form goes to `call/3` as the form sent it, with `form: true` (`forms.md`, in `eh_os_contract`'s
docs): the engine reads each value as text, at every level, a blank as absent, and a list as the
rows `inputs_for` sends, as `EhOsContract.Form` reads them. So no page or context converts a form's
text by hand, nor builds the command's struct (`Form.to_struct/1`, `struct/2`). What the page
decided, such as the identity of the unit the form is for, goes in `data:`, the same for the
changeset and for `call/3`: the identity in `data:` replaces one the params carry, and each other
field in it is the value when the params leave the field out. The page may build its changeset
with `EhOsContract.Form.changeset`, by the capability's name the context sends and with that
`data:`, to show what is wrong as the person types, and puts the context's refusal on it with
`EhOsContract.Form.refused/3`, which leaves out an error the changeset already holds. The context
is handed the params, never a struct.

```elixir
# The context: the order's id is the page's, and, prefixed, the key. The form's params go as they
# came, read by the engine as `Form` reads them, after it asks whether the person may
@spec place(Actor.t(), String.t(), map()) :: {:ok, Receipt.t()} | {:error, term()}
def place(actor, order_id, params) when is_binary(order_id) do
  EhOsContract.call({:command, "shop.place_order"}, params,
    actor: actor,
    form: true,
    data: %{order_id: order_id},
    idempotency_key: "order:#{order_id}"
  )
end

# The LiveView: `mount/3` assigned the session map it was given, a fresh `order_id` and its form.
# The id travels in a hidden input beside the order, `name="order_id"`, so LiveView sends it again
# as a change after a reconnect, when `mount/3` made a new one, and a submit sent twice carries
# the first's id: take it back from each, a UUID alone.
def handle_event("change", %{"order" => params} = event, socket) when is_map(params) do
  socket = keep_id(socket, event["order_id"])
  {:noreply, assign(socket, :form, form(changeset(socket, params)))}
end

def handle_event("place", %{"order" => params} = event, socket) when is_map(params) do
  socket = keep_id(socket, event["order_id"])

  with {:ok, actor} <- Session.actor(socket.assigns.session),
       {:ok, _receipt} <- Shop.Orders.place(actor, socket.assigns.order_id, params) do
    {:noreply, push_navigate(socket, to: ~p"/orders")}
  else
    {:error, reason} ->
      changeset = socket |> changeset(params) |> EhOsContract.Form.refused(reason)
      {:noreply, socket |> assign(:form, form(changeset)) |> put_flash(:error, refusal(reason))}
  end
end

# No browser sends an order that is not a map, nor none, and `Form.changeset` raises on one. Such
# a change leaves the form as it was, its id included; such a submit is sent as an empty order,
# which the engine refuses after it asks about the person
def handle_event("change", _params, socket), do: {:noreply, socket}
def handle_event("place", event, socket),
  do: handle_event("place", %{"order" => %{}, "order_id" => event["order_id"]}, socket)

defp keep_id(socket, id) when is_binary(id) and byte_size(id) == 36 do
  case Ecto.UUID.cast(id) do
    {:ok, id} -> assign(socket, :order_id, id)
    :error -> socket
  end
end

defp keep_id(socket, _id), do: socket

defp changeset(socket, params) do
  data = %{order_id: socket.assigns.order_id}
  EhOsContract.Form.changeset({:command, "shop.place_order"}, params, data: data)
end

defp form(changeset), do: to_form(changeset, as: :order, action: :validate)

# A field as the form holds it, if it is text or the number read from it: the form keeps a map or
# a list a client sent in its place, which no input can show
defp shown(value) when is_binary(value) or is_integer(value), do: value
defp shown(_value), do: nil
```

- **The actor is asked for again on each event** that issues a command, with
  `EhOsContract.Auth.Session.actor/2`: a credential lives ten minutes, and `actor/2` renews it.
  One kept from `mount/3` expires under a page left open.
- **The idempotency key travels with the form**, in a hidden input, fresh when the form opens and
  new again once a submit is accepted. The engine compares the key of an accepted command, not
  the params: a second submit of the same form answers the first's receipt and records nothing.
  A refused one holds no key, so the person can correct the form and submit again. The key is
  the person's: the engine looks it up among the commands the same actor issued. Give the form
  `phx-change`, with a handler that keeps the params it gets and takes the key back, so LiveView
  recovers the form, key included, after a reconnect. A unit whose identity the caller gives
  needs a fresh id too, and the key can be it.
- **The identity of the unit is the page's**, in `data:`: an id the person sends in the form is
  not read. A key taken back from the browser is still the client's, so take back only what the
  page makes, a UUID. Neither guards a unit that exists: whoever has the capability can call
  `/api` with any id. Only the contract does, with a command that `creates:` it or a decision that
  reads its state.
- **What the page receives is the client's**, not only what its form renders: a field can come
  as a map or a list, and the form's params as text or not at all. Each event that reads them
  takes a map alone, with a clause for anything else that is not a crash, and an input shows a
  field's value only when it is text or a number (`value={shown(@form[:quantity].value)}`), since
  the form keeps a value it could not cast as it came.
- **A refusal is the person's sentence**, in the contract's words: `{:error, :missing_capability}`
  says they may not, a `%EhOsContract.Rejection{}` names the invariant. The page words it, a
  LiveView in a function of its own, a controller in its `*HTML` module; the log names its kind
  alone.
- **Its test signs in for real**: `EhOsContract.Auth.Testing.sign_in/3`, put in the test session
  under `EhOsContract.Auth.Session.session_key()`, and asserts the refusal for a person without
  the capability, and that nothing was recorded.

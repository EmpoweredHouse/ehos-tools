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
`EhOsContract.call/3` (`authorization.md`, "Another door", in `eh_os_contract`'s docs): the
capability's name, the form's params, the person's actor. The engine asks its
`Authorizer` first, as `EhOsContract.Plug` does, so a person without the capability is refused
whatever they sent. A context function makes the call. `call/3` is the one way in for what a
person sends, as for a request to `/api`: it asks whether they may before it says what is wrong
with the params, refuses a field the host supplies, and checks the rest as the plug does.
`EhOsContract.dispatch/3` asks the `Authorizer` about a person's actor too, but takes a struct the
application built, and asks no one about a `:system` actor: it is for code that runs with no
request through the application's doors, such as a scheduled job, the sample-data seed as
`:sample_data`, or a task run from a shell or a release. So what a person sends through a page, a
controller or `/api` (a form, an upload, an import they start there) never goes to `dispatch/3`,
from a page, a controller or a context, nor as a `:system` actor, even where `forms.md`, in
`eh_os_contract`'s docs, has its page dispatch the struct `EhOsContract.Form` builds. The page may
still build its changeset with `EhOsContract.Form.changeset`, by the capability's name the context
sends, to show what is wrong as the person types. Once that changeset has no errors of its own,
the page puts the context's refusal on it with `EhOsContract.Form.refused/3`; before, the refusal
would repeat each error. The context is handed the params, never a struct. A form sends
text, and the engine reads a command's integer or boolean only from JSON's number or boolean:
the context turns such a field's text into its type, and leaves text it cannot read for the
engine to refuse as invalid, after it asks whether the person may.

```elixir
# The context: the form's `"order_id"`, a fresh UUID, is the order's id and the key
@spec place(Actor.t(), map()) :: {:ok, Receipt.t()} | {:error, term()}
def place(actor, %{"order_id" => id} = params) when is_binary(id) do
  input = Map.replace_lazy(params, "quantity", &whole_number/1)
  EhOsContract.call({:command, "shop.place_order"}, input, actor: actor, idempotency_key: id)
end

# A whole number from text, and anything else as it came, for the engine to refuse
defp whole_number(text) when is_binary(text) do
  case Integer.parse(String.trim(text)) do
    {number, ""} -> number
    _other -> text
  end
end

defp whole_number(other), do: other

# The LiveView: `mount/3` assigned the session map it was given, and a form with a fresh id.
# A change checks what the form holds against the command, and keeps it, its id included, which
# LiveView sends again after a reconnect: a form built from anything but these params loses the key.
def handle_event("change", %{"order" => params}, socket) do
  changeset = EhOsContract.Form.changeset({:command, "shop.place_order"}, params)
  {:noreply, assign(socket, :form, to_form(changeset, as: :order, action: :validate))}
end

def handle_event("place", %{"order" => params}, socket) do
  with {:ok, actor} <- Session.actor(socket.assigns.session),
       {:ok, _receipt} <- Shop.Orders.place(actor, params) do
    {:noreply, push_navigate(socket, to: ~p"/orders")}
  else
    {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
  end
end
```

- **The actor is asked for again on each event** that issues a command, with
  `EhOsContract.Auth.Session.actor/2`: a credential lives ten minutes, and `actor/2` renews it.
  One kept from `mount/3` expires under a page left open.
- **The idempotency key travels with the form**, in a hidden field, fresh when the form opens and
  new again once a submit is accepted. The engine compares the key of an accepted command, not
  the params: a second submit of the same form answers the first's receipt and records nothing.
  A refused one holds no key, so the person can correct the form and submit again. The key is
  the person's: the engine looks it up among the commands the same actor issued. Give the form
  `phx-change`, with a handler that keeps the params it gets, so LiveView recovers the form, key
  included, after a reconnect. A unit whose identity the caller gives needs a fresh id too, and
  the key can be it.
- **An id from the form is the caller's**: the person can send any id, as a caller of `/api`
  can. Only the contract guards a unit that exists, with a command that `creates:` it or a
  decision that reads its state.
- **A refusal is the person's sentence**, in the contract's words: `{:error, :missing_capability}`
  says they may not, a `%EhOsContract.Rejection{}` names the invariant. The page words it, a
  LiveView in a function of its own, a controller in its `*HTML` module; the log names its kind
  alone.
- **Its test signs in for real**: `EhOsContract.Auth.Testing.sign_in/3`, put in the test session
  under `EhOsContract.Auth.Session.session_key()`, and asserts the refusal for a person without
  the capability, and that nothing was recorded.

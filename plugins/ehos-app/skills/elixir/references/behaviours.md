# Ways out

A way out is a call that leaves the application, or that a test cannot sequence on its own: an
outside system's API, EHOS's own APIs, mail, the clock, randomness and generated ids. Each is a
behaviour, so a test can replace it per process with a Hammox mock, and so the behaviour's
`@callback`s are the one description of what the application expects from it.

A context function whose callers' tests should not run it may be a behaviour too: a page whose
test should not reach the database behind it, say. Prefer that to mocking what the context calls
in turn ([testing.md](testing.md), "Mock what the caller calls").

## What gets none

A contract's part — a decider, a read model, a query, a policy, an effect — already implements a
behaviour the contract generates, and its test is the contract's scenarios. A second behaviour on
top of it adds a mock nothing should use. A plain module the application owns end to end (a
formatter, a calculation) needs none either: test it directly.

## The shape

The behaviour and its implementation in one file; any other implementation in a module of its own.

```elixir
defmodule Shop.Payments do
  @moduledoc "Charges a card through the payment provider."

  @doc "Charges `amount` in minor units; `{:error, reason}` when the provider refuses."
  @callback charge(card :: String.t(), amount :: pos_integer()) ::
              {:ok, charge_id :: String.t()} | {:error, term()}

  @doc "The implementation `config/*.exs` chose."
  @spec current() :: module()
  def current, do: Application.fetch_env!(:shop, __MODULE__)[:impl]
end

defmodule Shop.PaymentsImpl do
  @moduledoc false
  @behaviour Shop.Payments

  @impl true
  def charge(card, amount) do
    # the provider's HTTP call
  end
end
```

A caller reads `Shop.Payments.current().charge(card, amount)`, never `Shop.PaymentsImpl` by name.

## Where `current/0` reads

- **`config/config.exs` and `config/test.exs` choose it:** read it once, into a module attribute,
  with `Application.compile_env/3`. The choice is fixed at compile time, and a release refuses to
  boot when its configuration says otherwise.

  ```elixir
  @impl_module Application.compile_env(:shop, [__MODULE__, :impl], Shop.PaymentsImpl)
  def current, do: @impl_module
  ```

- **`config/runtime.exs` chooses it** (the release picks a provider from an environment variable):
  read it at each call, as in the shape above. A release is compiled before `runtime.exs` runs, so
  an attribute would hold the compile-time default for good.

`config/test.exs` names the mock in either case:

```elixir
config :shop, Shop.Payments, impl: Shop.PaymentsMock
```

## No test hook in production code

Production code never reads, for a test's sake, a canned answer, a process to notify, a delay or a
flag from configuration. Each is a second implementation hidden inside the first, and a test that
sets it changes global state, so it cannot be `async`. Make the thing it stands for a way out, and
have the test `expect` the call instead.

## The clock, randomness and ids

`DateTime.utc_now/0`, `Date.utc_today/0`, `:rand` and `Ecto.UUID.generate/0` called directly make
a test that depends on them either flaky or blind. When a test needs to say what time it is, or
which id comes next, put them behind a behaviour (`Shop.Clock` with `now/0` and `today/0`), stub
it with the real implementation by default in `setup_mocks/1`, and `expect` it only in the tests
that sequence it. Where no test cares, call them directly.

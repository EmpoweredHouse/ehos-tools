# Ways out

A way out is a call that leaves the application, or that a test cannot sequence on its own: an
outside system's API, EHOS's own APIs, mail, the clock, randomness and generated ids. Each is a
behaviour, so a test can replace it per process with a Hammox mock, and so the behaviour's
`@callback`s are the one description of what the application expects from it.

A call that acts on an outside system as a step of a process (charging a card, sending a
document) is a contract's effect, which `calls:` an `external` the domain declares
(`lib/<app>/contracts/AGENTS.md`): the effect decides when, and the client it calls is the way
out, in the shape below. A read of an outside system from a context or a page (EHOS's people
directory, a rate) calls the way out directly.

A context function whose callers' tests should not run it may be a behaviour too: a page whose
test should not reach what the context reaches, say. Prefer that to mocking what the context calls
in turn ([testing.md](testing.md), "Mock what the caller calls").

## What gets none

A contract's part — a decider, a read model, a query, a policy, an effect — already implements a
behaviour the contract generates, and its test is the contract's scenarios. A second behaviour on
top of it adds a mock nothing should use. A plain module the application owns end to end (a
formatter, a calculation) needs none either: test it directly.

## The shape

The behaviour and its implementation in one file. Only real implementations live in `lib/`; a mock
or a fake lives in `test/support/`, so a release cannot run one.

```elixir
defmodule Shop.Payments do
  @moduledoc "Charges a card through the payment provider."

  @doc "Charges `amount` in minor units; `{:error, reason}` when the provider refuses."
  @callback charge(card_token :: String.t(), amount :: pos_integer()) ::
              {:ok, charge_id :: String.t()} | {:error, term()}

  @doc "The implementation `config/*.exs` chose."
  @spec current() :: module()
  def current, do: Application.get_env(:shop, __MODULE__, [])[:impl] || Shop.PaymentsImpl
end

defmodule Shop.PaymentsImpl do
  @moduledoc false
  @behaviour Shop.Payments

  @impl true
  def charge(card_token, amount) do
    # the provider's HTTP call
  end
end
```

A caller reads `Shop.Payments.current().charge(card_token, amount)`, never `Shop.PaymentsImpl` by
name. Pass the provider's token for a card, never its number: arguments reach crash reports and
a mock's error messages.

## Where `current/0` reads

- **The compile-time files choose it** (`config.exs`, `dev.exs`, `test.exs`, `prod.exs`): read it
  once, into a module attribute, with `Application.compile_env/3`. The choice is fixed at compile
  time, and a release refuses to boot when its configuration says otherwise.

  ```elixir
  @impl_module Application.compile_env(:shop, [__MODULE__, :impl], Shop.PaymentsImpl)
  def current, do: @impl_module
  ```

- **`config/runtime.exs` chooses it** (the release picks a provider from an environment variable):
  read it at each call, as in the shape above. A release is compiled before `runtime.exs` runs, so
  an attribute would hold the compile-time default for good. Choose inside
  `if config_env() == :prod`, since `runtime.exs` also runs in tests, after `test.exs`, and would
  replace the mock; and map the variable to a fixed set of real implementations, refusing any
  other value, never with `String.to_atom/1`.

`config/test.exs` names the mock in either case:

```elixir
config :shop, Shop.Payments, impl: Shop.PaymentsMock
```

## No test hook in production code

Production code never reads, for a test's sake, a canned answer, a process to notify, a delay or a
flag from configuration. Each is a second implementation hidden inside the first, and a test that
sets it changes global state, so it cannot be `async`. Make the thing it stands for a way out, and
have the test `expect` the call instead. Configuration every reader sees differ by environment,
such as an endpoint's `server: false` in tests, is not such a hook.

## The clock, randomness and ids

`DateTime.utc_now/0`, `Date.utc_today/0`, `:rand` and `Ecto.UUID.generate/0` called directly make
a test that depends on them either flaky or blind. When a test needs to say what time it is, or
which id comes next, put them behind a behaviour (`Shop.Clock` with `now/0` and `today/0`), stub
it with the real implementation by default in `setup_mocks/1`, and `expect` it only in the tests
that sequence it. Where no test cares, call them directly.

# Behaviours

A collaborator whose callers' tests should replace it is a behaviour, so a test can replace it per
process with a Hammox mock, held to the real module's types, and stay `async`; and so the
behaviour's `@callback`s are the one description of what its callers expect from it
([ehos-tools T-20](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)).

## What gets one

- **Every way out of the application**: a call that leaves it, or that a test cannot sequence on
  its own. An outside system's API, EHOS's own APIs, mail; the clock, randomness, generated ids
  and the process environment where a test must say what they return.
- **Every module of the application's own whose callers' tests should not run it**: a context a
  page calls, when the page's test should not reach what the context reaches. The page's test
  mocks the context; the context's own test mocks what it calls in turn
  ([testing.md](testing.md), "Mock what the caller calls").

A call that acts on an outside system as a step of a process (charging a card, sending a
document) is a contract's effect, which `calls:` an `external` the domain declares
(`lib/<app>/contracts/AGENTS.md`): the effect decides when, and the client it calls is the way
out, in the shape below. A read of an outside system from a context or a page (EHOS's people
directory, a rate) calls the way out directly.

## What gets none

- **A contract's part**: a decider, a read model, a query, a policy, an effect. It already
  implements a behaviour the contract generates, and its test is the contract's scenarios. A
  second behaviour on top of it adds a mock nothing should use.
- **A pure module**: a calculation, a parser, a formatter, a validation. Nothing in it needs
  replacing; test it directly.
- **An Oban worker.** Its test performs it (`perform_job/2`), and it calls each collaborator
  through the collaborator's `current()`, so that test mocks those and nothing else:

  ```elixir
  defmodule Shop.Workers.SendReceipt do
    @moduledoc "Mails an order's receipt once the order is paid."
    use Oban.Worker, queue: :mail

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"order_id" => order_id}}) do
      with {:ok, order} <- Shop.Orders.current().paid_order(order_id) do
        Shop.Mailer.current().receipt(order)
      end
    end
  end
  ```

## The shape

The behaviour and its implementation in one file. Only real implementations live in `lib/`; a mock
or a fake lives in `test/support/`, so a release cannot run one.

```elixir
defmodule Shop.Payments do
  @moduledoc "Charges a card through the payment provider."

  @doc """
  Charges `amount`, in minor units, to the card the provider's `card_token` names. Answers the
  provider's id for the charge, or `{:error, :declined}` when the provider refuses the card and
  `{:error, :unavailable}` when it cannot be reached.
  """
  @callback charge(card_token :: String.t(), amount :: pos_integer()) ::
              {:ok, charge_id :: String.t()} | {:error, :declined | :unavailable}

  @impl_module Application.compile_env!(:shop, [__MODULE__, :impl])

  @doc "The implementation `config/*.exs` chose."
  @spec current() :: module()
  def current, do: @impl_module
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

- **Every `@callback` has a `@doc`**: what it does, what it answers and how it fails. It is the
  one description of the collaborator a caller reads, and a mock is held to its types but not to
  its words. The application's test of its behaviours fails on a `@callback` without one.
- **Callers name the behaviour**: `Shop.Payments.current().charge(card_token, amount)`, never
  `Shop.PaymentsImpl`.
- **A test module is named after the behaviour**, `Shop.PaymentsTest`, and no test's name says
  `impl`: the scenario is what the application does, not which module does it.
- Pass the provider's token for a card, never its number: arguments reach crash reports and a
  mock's error messages.

## Where `current/0` reads

- **The compile-time files choose it** (`config.exs`, `dev.exs`, `test.exs`, `prod.exs`): read it
  once, into a module attribute, with `Application.compile_env!/2`, as in the shape above. The
  choice is fixed at compile time, and a release refuses to boot when its configuration says
  otherwise.
- **`config/runtime.exs` chooses it** (the release picks a provider from an environment variable):
  read it at each call. A release is compiled before `runtime.exs` runs, so an attribute would
  hold the compile-time default for good.

  ```elixir
  def current, do: Application.fetch_env!(:shop, __MODULE__)[:impl]
  ```

  Choose inside `if config_env() == :prod`, since `runtime.exs` also runs in tests, after
  `test.exs`, and would replace the mock; and map the variable to a fixed set of real
  implementations, refusing any other value, never with `String.to_atom/1`.

`config/config.exs` names the real implementation and `config/test.exs` the mock, in either case.
Neither variant has a default in code: a behaviour whose test line is missing raises, rather than
reaching the real provider from a test.

```elixir
# config/config.exs
config :shop, Shop.Payments, impl: Shop.PaymentsImpl

# config/test.exs
config :shop, Shop.Payments, impl: Shop.PaymentsMock
```

## No test hook in production code

Production code never reads, for a test's sake, a canned answer, a process to notify, a delay or a
flag from configuration. Each is a second implementation hidden inside the first, and a test that
sets it changes global state, so it cannot be `async`. Make the thing it stands for a behaviour,
and have the test `expect` the call instead. Configuration every reader sees differ by
environment, such as an endpoint's `server: false` in tests, is not such a hook.

## The clock, randomness and ids

`DateTime.utc_now/0`, `Date.utc_today/0`, `:rand` and `Ecto.UUID.generate/0` called directly make
a test that depends on them either flaky or blind. When a test needs to say what time it is, or
which id comes next, put them behind a behaviour (`Shop.Clock` with `now/0` and `today/0`), stub
it with the real implementation by default in `setup_mocks/1`, and `expect` it only in the tests
that sequence it. Where no test cares, call them directly.

## The process environment

`config/runtime.exs` reads the environment variables EHOS gives the application, once, at boot,
and code reads what it put in the application's configuration. Code that must read a variable at
run time, after boot, reads it through a behaviour of the application's own, never
`System.get_env/1` or `System.fetch_env/1` in `lib/`, so its test says what the environment holds
without `System.put_env/2`, which changes it for every test running at the time:

```elixir
defmodule Shop.Env do
  @moduledoc "The process environment, read at run time."

  @doc "The value of the variable `name`, or `nil` when it is not set."
  @callback get(name :: String.t()) :: String.t() | nil

  @impl_module Application.compile_env!(:shop, [__MODULE__, :impl])

  @doc "The implementation `config/*.exs` chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Shop.EnvImpl do
  @moduledoc false
  @behaviour Shop.Env

  @impl true
  def get(name), do: System.get_env(name)
end
```

Each application writes its own, with the callbacks it needs; there is no shared module to
depend on. `mix.exs` and `config/*.exs` read the environment directly: they run before any of it.

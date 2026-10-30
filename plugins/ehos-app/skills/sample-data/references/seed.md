# A seed that records sample facts, and its test

A model for an application `Shop` with the template's example contract, `Shop.Contracts.Entries`:
a clerk records an entry under an `entry_id` the caller gives, and an auditor flags one. Read it
for its shape, then write the application's own from its contracts.

## The contract and the domain

```elixir
# lib/shop/domain.ex
actor :sample_data, :system, "Sample data"

# lib/shop/contracts/entries.ex
command :record_entry, "Record an entry", by: [:clerk, :sample_data], emits: :recorded do
  field :amount, :integer
end

command :flag_entry, "Flag an entry", by: [:auditor, :sample_data], emits: :flagged
```

## The configuration

```elixir
# config/config.exs: the environments the seed refuses to run in, whatever runs it.
config :shop, Shop.Seed, production_environments: ["production"]

# config/runtime.exs, outside `if config_env() == :prod`, so a development database has them too.
config :shop, Shop.Seed,
  profile: System.get_env("EHOS_SEED_PROFILE"),
  environment: System.get_env("EHOS_ENVIRONMENT")
```

`ehos.yaml` names the seed as the template wrote it, unchanged:
`seed: ["/app/bin/shop", "eval", "Shop.Seed.run()"]`.

## The seed

```elixir
defmodule Shop.Seed do
  @moduledoc """
  Fills an ephemeral environment of EHOS with sample entries to try the application on, never
  production (`needs.database.seed` in `ehos.yaml`, eh-os D-98).

  EHOS runs `run/0` after the migration, from the application's image, as the schema's owner,
  with nothing of the application running. An entry is a business fact, so the seed records it
  through the contract, as the system actor `:sample_data` the commands' `by:` names, with the
  repo and an Oban that runs no queue started for it. `priv/repo/seeds.exs` calls `add/1` for a
  development database.

  - **It runs at every start of the workload**, so each step is keyed `sample:<step>`, and a
    second run replays it: nothing is added twice.
  - **It ships in every image**, production's included, so it refuses the environments
    `:production_environments` names, `run/0` an environment EHOS did not name, and it holds no
    real data: every entry is made up.
  - **`EHOS_SEED_PROFILE` chooses what it adds**: `empty`, or `small`, the default.
  """

  alias EhOsContract.{Actor, Receipt, Rejection}
  alias Shop.Contracts.Entries
  alias Shop.Contracts.Entries.Commands.{FlagEntry, RecordEntry}

  @app :shop
  @profiles ["empty", "small"]

  # The commands a person may issue that no profile issues, with why.
  @not_seeded %{}

  # Refusals that mean a step's fact is already there, under a key of its own: the seed done.
  @already []

  @rent "6f1c2a52-5d1e-4c3b-9a7e-0e6b1f9c2d01"
  @fuel "6f1c2a52-5d1e-4c3b-9a7e-0e6b1f9c2d02"

  @doc """
  Adds the profile's sample facts, as EHOS runs it: the repo started, and Oban, which runs
  nothing here; both stop before it returns. Raises where `EHOS_ENVIRONMENT` names no
  environment, and where `add/1` does.
  """
  @spec run() :: :ok
  def run do
    Application.load(@app)
    named!(config()[:environment])

    # Isolated: nothing here listens for a notification, so it holds no connection of its own.
    oban =
      @app
      |> Application.fetch_env!(Oban)
      |> Keyword.merge(
        queues: false,
        plugins: false,
        peer: false,
        notifier: Oban.Notifiers.Isolated
      )

    {:ok, _added, _apps} =
      Ecto.Migrator.with_repo(Shop.Repo, fn _repo ->
        {:ok, _started} = Application.ensure_all_started(:oban)
        {:ok, pid} = Oban.start_link(oban)

        # Stopped before `with_repo` stops the repo, which its processes query.
        try do
          add(profile())
        after
          Supervisor.stop(pid)
        end
      end)

    :ok
  end

  @doc "The profile `EHOS_SEED_PROFILE` names, `small` when it names none."
  @spec profile() :: String.t()
  def profile, do: known(config()[:profile])

  @doc "The profiles the seed knows."
  @spec profiles() :: [String.t()]
  def profiles, do: @profiles

  @doc """
  Issues the profile's steps in order, and answers each step's key, its command and whether it
  was `:added` now or there `:already`. Raises in a production environment, whatever calls it,
  on an unknown profile, and on a step refused for any reason but its fact being there already.
  """
  @spec add(String.t()) :: [{String.t(), module(), :added | :already}]
  def add(profile) do
    refuse_production!(config())
    EhOsContract.Registry.load!()

    {added, _receipts} = Enum.map_reduce(steps(profile), %{}, &step/2)
    added
  end

  @doc "The commands a person may issue that the seed leaves out on purpose."
  @spec not_seeded() :: [module()]
  def not_seeded, do: Map.keys(@not_seeded)

  # A step's command is a struct, or a function of the receipts of the steps before it, keyed
  # by step, for an identity the engine generated: `fn %{"company" => r} -> ... end`.
  defp steps("empty"), do: []

  defp steps("small") do
    [
      {"entry-rent", Entries, %RecordEntry{entry_id: @rent, amount: 1200}},
      {"entry-fuel", Entries, %RecordEntry{entry_id: @fuel, amount: 340}},
      {"flag-fuel", Entries, %FlagEntry{entry_id: @fuel}}
    ]
  end

  defp step({key, contract, build}, receipts) do
    command = command(build, receipts)

    {outcome, receipt} =
      contract
      |> EhOsContract.dispatch(command,
        actor: Actor.system(:sample_data),
        idempotency_key: "sample:#{key}"
      )
      |> outcome(key)

    {{key, command.__struct__, outcome}, Map.put(receipts, key, receipt)}
  end

  defp command(build, receipts) when is_function(build, 1), do: build.(receipts)
  defp command(command, _receipts), do: command

  defp outcome({:ok, %Receipt{duplicate: false} = receipt}, _key), do: {:added, receipt}
  defp outcome({:ok, %Receipt{duplicate: true} = receipt}, _key), do: {:already, receipt}

  # Not `in`, which the compiler reads as always false while `@already` is empty.
  defp outcome({:error, %Rejection{invariant: invariant}}, key),
    do: refused(Enum.member?(@already, invariant), invariant, key)

  # An error by its kind alone: its detail can hold the command's values, which a log never does.
  defp outcome({:error, {kind, _detail}}, key) when is_atom(kind),
    do: raise("the sample step #{key} failed: #{kind}")

  defp outcome({:error, kind}, key) when is_atom(kind),
    do: raise("the sample step #{key} failed: #{kind}")

  defp outcome({:error, _reason}, key),
    do: raise("the sample step #{key} failed, for a reason this seed does not name")

  defp refused(true, _invariant, _key), do: {:already, nil}

  defp refused(false, invariant, key),
    do: raise("the sample step #{key} was refused #{invariant}")

  defp known(nil), do: "small"
  defp known(""), do: "small"
  defp known(profile) when profile in @profiles, do: profile

  defp known(profile),
    do: raise("no sample profile #{profile}: the seed knows #{Enum.join(@profiles, ", ")}")

  defp config, do: Application.fetch_env!(@app, __MODULE__)

  # EHOS names the environment it runs the seed in: one with no name was run some other way, and
  # could be pointed at any database.
  defp named!(environment) when environment in [nil, ""],
    do: raise("EHOS_ENVIRONMENT names no environment, so the seed does not run")

  defp named!(_environment), do: :ok

  defp refuse_production!(config),
    do: production!(config[:environment] in Keyword.fetch!(config, :production_environments))

  defp production!(false), do: :ok

  defp production!(true),
    do: raise("sample data is an ephemeral environment's, never production's")
end
```

A step refused as `:already` has no receipt, so a later step that needs its identity takes it
from a step that is keyed, never from one refused.

## A development database

```elixir
# priv/repo/seeds.exs, which `mix ecto.setup` runs with the application started.
Shop.Seed.add(Shop.Seed.profile())
```

## The test

```elixir
defmodule Shop.SeedTest do
  # Every append to the engine's log takes one lock, held for the sandbox's whole transaction.
  use Shop.DataCase, async: false

  alias EhOsContract.{Model, Registry}
  alias Shop.Contracts.Entries.Commands.{FlagEntry, RecordEntry}
  alias Shop.Seed

  describe "add/1" do
    test "adds the small profile's facts to a database with none" do
      assert Seed.add("small") == [
               {"entry-rent", RecordEntry, :added},
               {"entry-fuel", RecordEntry, :added},
               {"flag-fuel", FlagEntry, :added}
             ]
    end

    test "adds nothing the second time, in every profile" do
      for profile <- Seed.profiles() do
        added = Seed.add(profile)

        assert Seed.add(profile) ==
                 Enum.map(added, fn {key, command, _outcome} -> {key, command, :already} end)
      end
    end

    test "adds nothing for the empty profile" do
      assert Seed.add("empty") == []
    end

    test "issues every command a person may issue, or says why not" do
      seeded = for {_key, command, _outcome} <- Seed.add("small"), into: MapSet.new(), do: command

      issued_by_people =
        for contract <- Registry.contracts(),
            {_capability, %{kind: :command, name: name}} <- Model.capabilities(contract),
            command = Model.module_for(contract, :command, name),
            command not in Seed.not_seeded(),
            into: MapSet.new(),
            do: command

      assert MapSet.difference(issued_by_people, seeded) == MapSet.new()
    end
  end
end
```

When the last test fails, the contract has a command the seed does not issue: add a step for it,
or name it in `@not_seeded` with why.

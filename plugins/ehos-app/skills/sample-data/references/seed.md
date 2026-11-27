# Moving an earlier project's seed to the template's

ehos_app 0.25.0 and later write the seed that records sample facts, and its test, into a new
project. A project made before has the seed an earlier version wrote, which runs
`priv/repo/seeds.exs` with the repo alone and records no fact; the installer leaves it, since it is
the developer's. Move it once, by hand, before the first step. The template's files are the model:

- [`seed.ex.eex`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/priv/templates/ehos_app.install/seed.ex.eex),
  the module;
- [`seed_test.exs.eex`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/priv/templates/ehos_app.install/seed_test.exs.eex),
  its test.

Each `<%= ... %>` names the application (`:shop`, `Shop.Seed`, `Shop.Repo`, `Shop.DataCase`); keep
the branch without `@example`, whose profiles add nothing until the first step.

## The steps, for an application `Shop`

1. **The domain** declares the seed actor. No `by:` names it:

   ```elixir
   # lib/shop/domain.ex
   actor :sample_data, :seed, "Sample data", not_seeded: []
   ```

2. **The configuration** the seed reads:

   ```elixir
   # config/config.exs: the environments the seed refuses to run in, whatever runs it.
   config :shop, Shop.Seed, production_environments: ["production"]

   # config/runtime.exs, outside `if config_env() == :prod`, so a development database has them too.
   config :shop, Shop.Seed,
     profile: System.get_env("EHOS_SEED_PROFILE"),
     environment: System.get_env("EHOS_ENVIRONMENT")
   ```

3. **`lib/shop/seed.ex`** becomes the template's module. What the old `seeds.exs` wrote stays
   there: the new `run/0` runs the same script, with Oban started beside the repo.
4. **`priv/repo/seeds.exs`** calls the seed, after what it writes of its own:

   ```elixir
   Shop.Seed.add(Shop.Seed.profile())
   ```

5. **`test/shop/seed_test.exs`** is the template's test.

`ehos.yaml` names the seed as before, unchanged: `seed: [/app/bin/shop, eval, "Shop.Seed.run()"]`.
Then add the steps, as `SKILL.md` says, and check it as it says.

## Move the seed to the seed actor

ehos_app 0.39.0 and later write a seed that acts as the domain's seed actor, which ehos_contract
0.17.0 and later have. An earlier seed acts as a `:system` actor that each command's `by:` names,
and its module lists the commands that it leaves out in `@not_seeded`. It keeps working on
ehos_contract 0.17.0. Move it once, by hand, so that the contract stops naming the seed in each
command. The template's files are the model, as above.

1. **In the domain**, change the kind of `:sample_data` to `:seed`, and move the list of the seed
   module's `@not_seeded` into `not_seeded:`. Give each entry the name of the command, not its
   module:

   ```elixir
   # Before: lib/shop/seed.ex
   @not_seeded %{RefundOrder => "only undoes another command"}

   # After: lib/shop/domain.ex
   actor :sample_data, :seed, "Sample data",
     not_seeded: [refund_order: "only undoes another command"]
   ```

2. **Remove `:sample_data` from each `by:` and each `recorded_by:`.** Run
   `mix ehos_contract.check`: it names each one that is left (`seed-actor-in-by`).
3. **In `lib/shop/seed.ex`**, dispatch with `Actor.seed(:sample_data)`, not
   `Actor.system(:sample_data)`. Remove `@not_seeded` and `not_seeded/0`.
4. **Remove each step that issues a command with `actor_is:`.** The engine refuses the seed for
   such a command.
5. **Give each `EhosContract.Supplier` and `EhosContract.Entities` a clause for the seed**, as
   `SKILL.md` says in "The actor".
6. **In `test/shop/seed_test.exs`**, take the test "issues every command a person may issue, but
   those the domain's seed leaves out" from the template. It reads `not_seeded:` from the domain.
7. **Run the seed's test and `mix ehos_contract.check`.**

The engine labels the seed actor `system:sample_data` in the log, as it labels the `:system`
actor. So in an environment that the earlier seed filled, each step replays as a duplicate, and
the seed adds nothing again. Each contract that named the seed in a `by:` gets a new version.

## A step

```elixir
defp steps("small") do
  [
    # A unit the caller names: a fixed, made-up UUID, so every start names the same one.
    {"entry-rent", Entries, %RecordEntry{entry_id: @rent, amount: 1200}},
    {"flag-rent", Entries, %FlagEntry{entry_id: @rent}},
    # A unit the engine names: taken from the receipt of the step that created it.
    {"company-1", Companies, %AddCompany{name: "Example Foundry"}},
    {"invoice-1", Invoices, fn %{"company-1" => company} ->
       %IssueInvoice{company_id: company.identity.company_id, amount: 300}
     end}
  ]
end
```

A step refused as `:already` has no receipt, so a later step that needs its identity takes it
from a step that is keyed, never from one refused.

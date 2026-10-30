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

1. **The domain** declares the seed's actor, and each command the seed issues names it:

   ```elixir
   # lib/shop/domain.ex
   actor :sample_data, :system, "Sample data"

   # a contract
   command :record_entry, "Record an entry", by: [:clerk, :sample_data], emits: :recorded do
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
       %IssueInvoice{company_id: company.identity, amount: 300}
     end}
  ]
end
```

A step refused as `:already` has no receipt, so a later step that needs its identity takes it
from a step that is keyed, never from one refused.

defmodule Mix.Tasks.EhosApp.InstallTest.Seed do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  @call "Test.Seed.add(Test.Seed.profile())\n"

  @path "priv/repo/seeds.exs"

  # The script `phx.new` writes, comments alone, as the test project has it.
  defp phoenix_seeds, do: content(phx_test_project(), @path)

  defp with_seeds(content), do: phx_test_project() |> replace_file(@path, content)

  describe "the seed (ehos-tools#476)" do
    test "writes its test, which holds every profile, every command and the guard" do
      assert installed()
             |> content("test/test/seed_test.exs")
             |> lines_starting("    test ") == [
               ~s|    test "adds the small profile's facts to a database with none" do|,
               ~s|    test "adds nothing the second time, in every profile" do|,
               ~s|    test "issues every command a person may issue, or says why not" do|,
               ~s|    test "raises on an unknown profile, naming the ones it knows" do|,
               ~s|    test "refuses a production environment, whatever calls it" do|,
               ~s|    test "refuses where EHOS names no environment, before it starts anything" do|,
               ~s|    test "refuses a production environment, before it starts anything" do|
             ]
    end

    test "configures the production environments, and reads the profile and environment at runtime" do
      igniter = installed()

      assert lines_with(content(igniter, "config/config.exs"), "Test.Seed") == [
               ~s|config :test, Test.Seed, production_environments: ["production"]|
             ]

      # Outside `config_env() == :prod`, so a development or test database reads them too.
      assert content(igniter, "config/runtime.exs")
             |> lines(
               "config :test, Test.Seed,",
               ~s|  environment: System.get_env("EHOS_ENVIRONMENT")|
             ) ==
               """
               config :test, Test.Seed,
                 profile: System.get_env("EHOS_SEED_PROFILE"),
                 environment: System.get_env("EHOS_ENVIRONMENT")
               """
    end

    test "adds the call under the comments of phx.new's seeds.exs" do
      assert installed() |> content(@path) == phoenix_seeds() <> "\n" <> @call
    end

    test "has a project with no seeds.exs call the seed's add/2 from a new one" do
      igniter =
        phx_test_project()
        |> Igniter.rm(@path)
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(igniter, @path) == @call
    end

    test "leaves a seeds.exs with code of its own, and says what to add" do
      script = "Test.Repo.insert!(%Test.Thing{})\n"
      igniter = with_seeds(script) |> Igniter.compose_task("ehos_app.install", [])

      assert igniter |> apply_igniter!() |> content(@path) == script

      assert messages_starting(igniter.notices, "priv/repo/seeds.exs") == [
               """
               priv/repo/seeds.exs has code of its own, so it was left alone. For the seed to record the
               sample data of `EHOS_SEED_PROFILE`, add to it: Test.Seed.add(Test.Seed.profile())
               """
             ]
    end

    test "changes nothing on a second run" do
      first =
        installed()

      again = install_again(first)

      for path <- [
            "lib/test/seed.ex",
            "test/test/seed_test.exs",
            "priv/repo/seeds.exs",
            "config/config.exs",
            "config/runtime.exs"
          ] do
        assert content(again, path) == content(first, path)
      end
    end

    test "with the example, seeds its contract as :sample_data, which its domain and commands name" do
      igniter = installed(["--example"])

      assert lines_with(content(igniter, "lib/test/seed.ex"), ~s|{"entry-|) ++
               lines_with(content(igniter, "lib/test/seed.ex"), ~s|{"flag-|) == [
               ~s|      {"entry-rent", Entries, %RecordEntry{entry_id: @rent, amount: 1200}},|,
               ~s|      {"entry-fuel", Entries, %RecordEntry{entry_id: @fuel, amount: 340}},|,
               ~s|      {"flag-fuel", Entries, %FlagEntry{entry_id: @fuel}}|
             ]

      assert igniter |> content("lib/test/domain.ex") |> calls(:actor) == [
               [:clerk, :human, "Clerk"],
               [:auditor, :human, "Auditor"],
               [:sample_data, :system, "Sample data"]
             ]

      assert igniter
             |> content("lib/test/contracts/entries.ex")
             |> calls(:command)
             |> Enum.map(fn [name, _title, opts | _] -> {name, Keyword.fetch!(opts, :by)} end) ==
               [
                 {:record_entry, [:clerk, :sample_data]},
                 {:flag_entry, [:auditor, :sample_data]}
               ]
    end

    test "without the example, its profiles add nothing" do
      seed = installed() |> content("lib/test/seed.ex")

      assert lines_with(seed, "defp steps(") == [
               ~s|  defp steps("empty"), do: []|,
               ~s|  defp steps("small"), do: []|
             ]
    end

    # A contract of its own may have commands no step issues yet, which the test would fail on.
    test "writes the seed without its test into a project with a contract of its own" do
      contract = """
      defmodule Test.Contracts.Orders do
        use EhOsContract.Contract, domain: Test.Domain, context: :orders, id: "test.orders"
      end
      """

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("lib/test/contracts/orders.ex", contract)
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert Igniter.exists?(igniter, "lib/test/seed.ex")
      refute Igniter.exists?(igniter, "test/test/seed_test.exs")
    end

    # Only where the template puts them: reading every file under lib/ that early slows each run.
    test "writes the test into a project whose contract is outside lib/<app>/contracts/" do
      contract = """
      defmodule Test.Billing.Contract do
        use EhOsContract.Contract, domain: Test.Domain, context: :billing, id: "test.billing"
      end
      """

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("lib/test/billing/contract.ex", contract)
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert Igniter.exists?(igniter, "test/test/seed_test.exs")
    end

    test "writes the test into a project with a home page of its own and no contract" do
      igniter =
        phx_test_project()
        |> replace_file("lib/test_web/controllers/page_html/home.html.heex", "<h1>Mine</h1>\n")
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert Igniter.exists?(igniter, "test/test/seed_test.exs")
    end

    test "writes no second seed beside one the developer moved to a file of its own" do
      igniter =
        phx_test_project()
        |> with_file("lib/test/sample.ex", "defmodule Test.Seed do\nend\n")
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute Igniter.exists?(igniter, "lib/test/seed.ex")
      refute Igniter.exists?(igniter, "test/test/seed_test.exs")
    end

    # A seed the developer has is theirs: no test, configuration or call is written for it.
    test "writes nothing beside a seed the project already has" do
      igniter =
        phx_test_project()
        |> with_file("lib/test/seed.ex", "defmodule Test.Seed do\nend\n")
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(igniter, "lib/test/seed.ex") == "defmodule Test.Seed do\nend\n"
      refute Igniter.exists?(igniter, "test/test/seed_test.exs")
      assert content(igniter, @path) == phoenix_seeds()
      assert lines_with(content(igniter, "config/config.exs"), "Test.Seed") == []
    end
  end
end

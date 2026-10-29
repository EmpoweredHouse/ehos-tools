defmodule Mix.Tasks.EhosApp.InstallTest.SchemaLock do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # eh-os-contract 0.7.0's lock (ehos-tools#274): recorded by the engine once the files are written,
  # so a new project's first commit holds its events' fields, and checked by every precommit.
  describe "the schema lock" do
    test "has the engine record a new project's lock, and checks it in precommit" do
      igniter = install(["--example"])

      assert {"eh_os_contract.schema", []} in igniter.tasks

      assert igniter |> apply_igniter!() |> content("mix.exs") =~
               ~r/"eh_os_contract\.check",\s+"eh_os_contract\.schema --check"/
    end

    test "never records over a lock the project has, and still adds the check" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("ehos_app.install", ["--example"])
        |> apply_igniter!()
        |> Igniter.create_new_file("eh_os_contract.lock", "%{}\n")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      refute {"eh_os_contract.schema", []} in igniter.tasks
      assert content(igniter, "eh_os_contract.lock") == "%{}\n"
      assert content(igniter, "mix.exs") =~ "eh_os_contract.schema --check"
    end

    @orders_contract """
    defmodule Test.Contracts.Orders do
      use EhOsContract.Contract, domain: Test.Domain, context: :orders, id: "test.orders"
    end
    """

    test "has the engine record a new project's lock when the contract is its own" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("lib/test/contracts/orders.ex", @orders_contract)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert {"eh_os_contract.schema", []} in igniter.tasks
    end

    # The task compiles the project, which may not compile on this engine yet, and a task that
    # fails ends the run before Igniter prints the upgrade's notices.
    test "tells a project an earlier version made to record its lock, and checks it" do
      igniter =
        installed()
        |> Igniter.create_new_file("lib/test/contracts/orders.ex", @orders_contract)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      refute {"eh_os_contract.schema", []} in igniter.tasks
      assert Enum.any?(igniter.notices, &(&1 =~ "run `mix eh_os_contract.schema` and commit"))
      assert igniter |> apply_igniter!() |> content("mix.exs") =~ "eh_os_contract.schema --check"
    end

    # Every project with a contract before the run has the engine, so the task records only
    # contracts the run wrote.
    test "tells a project that added the engine by hand to record its lock" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep({:eh_os_contract, "~> 0.6.0"})
        |> Igniter.create_new_file("lib/test/contracts/orders.ex", @orders_contract)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      refute {"eh_os_contract.schema", []} in igniter.tasks
      assert Enum.any?(igniter.notices, &(&1 =~ "run `mix eh_os_contract.schema` and commit"))
    end

    test "checks a lock the project keeps, whatever its contracts' modules use" do
      igniter =
        installed()
        |> Igniter.create_new_file("lib/test/contracts/orders.ex", """
        defmodule Test.Contracts.Orders do
          use Test.Contract, context: :orders
        end
        """)
        |> Igniter.create_new_file("eh_os_contract.lock", "%{}\n")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      refute Enum.any?(igniter.notices, &(&1 =~ "No module under lib/"))
      assert igniter |> apply_igniter!() |> content("mix.exs") =~ "eh_os_contract.schema --check"
    end

    # The engine records the contracts of the application's own code, not a test's.
    test "counts no contract that only test/support holds" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "test/support/orders.ex",
          String.replace(@orders_contract, "Test.Contracts.Orders", "Test.Support.Orders")
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      refute {"eh_os_contract.schema", []} in igniter.tasks

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "No module under lib/ uses EhOsContract.Contract")
             )
    end

    # The engine refuses to record a project with no contract, and so would the check.
    test "leaves a project with no contract without either, and says when to run again" do
      igniter = install()

      refute {"eh_os_contract.schema", []} in igniter.tasks
      refute igniter |> apply_igniter!() |> content("mix.exs") =~ "eh_os_contract.schema"

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "No module under lib/ uses EhOsContract.Contract")
             )
    end
  end
end

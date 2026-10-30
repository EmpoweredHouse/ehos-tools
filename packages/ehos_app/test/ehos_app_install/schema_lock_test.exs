defmodule Mix.Tasks.EhosApp.InstallTest.SchemaLock do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  @orders_contract """
  defmodule Test.Contracts.Orders do
    use EhOsContract.Contract, domain: Test.Domain, context: :orders, id: "test.orders"
  end
  """

  # The tasks every run leaves for Igniter to run after it, from another area of the installer.
  @release_tasks [{"phx.gen.release", ["--docker"]}, {"ehos_app.dockerfile", ["--yes"]}]

  @record_lock_task {"eh_os_contract.schema", []}

  @record_lock_notice """
  eh_os_contract.lock records every event's fields, and `mix precommit` now runs
  `mix eh_os_contract.schema --check`, which fails until the project has one. Once the
  project compiles, run `mix eh_os_contract.schema` and commit eh_os_contract.lock,
  before any event changes.
  """

  # eh-os-contract 0.7.0's lock (ehos-tools#274): recorded by the engine once the files are written,
  # so a new project's first commit holds its events' fields, and checked by every precommit.
  describe "the schema lock" do
    test "has the engine record a new project's lock, and checks it in precommit" do
      igniter = install(["--example"])

      assert igniter.tasks == @release_tasks ++ [@record_lock_task]

      assert igniter |> apply_igniter!() |> precommit_steps() == """
             &hex_audit/1,
             "compile --warnings-as-errors",
             "deps.unlock --unused",
             "format",
             "test --warnings-as-errors",
             "eh_os_contract.check",
             "eh_os_contract.schema --check",
             "credo"
             """
    end

    test "has the engine record a new project's lock when the contract is its own" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("lib/test/contracts/orders.ex", @orders_contract)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert igniter.tasks == @release_tasks ++ [@record_lock_task]
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

      assert igniter.notices == [ready_notice()]

      assert igniter |> apply_igniter!() |> precommit_steps() == """
             &hex_audit/1,
             "compile --warnings-as-errors",
             "deps.unlock --unused",
             "format",
             "test --warnings-as-errors",
             "eh_os_contract.check",
             "credo",
             "eh_os_contract.schema --check"
             """
    end

    test "never records over a lock the project has, and still adds the check" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("ehos_app.install", ["--example"])
        |> apply_igniter!()
        |> Igniter.create_new_file("eh_os_contract.lock", "%{}\n")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert igniter.tasks == @release_tasks
      assert content(igniter, "eh_os_contract.lock") == "%{}\n"

      assert precommit_steps(igniter) == """
             &hex_audit/1,
             "compile --warnings-as-errors",
             "deps.unlock --unused",
             "format",
             "test --warnings-as-errors",
             "eh_os_contract.check",
             "eh_os_contract.schema --check",
             "credo"
             """
    end

    # The task compiles the project, which may not compile on this engine yet, and a task that
    # fails ends the run before Igniter prints the upgrade's notices.
    test "tells a project an earlier version made to record its lock, and checks it" do
      igniter =
        installed()
        |> Igniter.create_new_file("lib/test/contracts/orders.ex", @orders_contract)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert igniter.tasks == @release_tasks

      assert messages_starting(igniter.notices, "eh_os_contract.lock records") == [
               @record_lock_notice
             ]

      assert igniter |> apply_igniter!() |> precommit_steps() == """
             &hex_audit/1,
             "compile --warnings-as-errors",
             "deps.unlock --unused",
             "format",
             "test --warnings-as-errors",
             "eh_os_contract.check",
             "credo",
             "eh_os_contract.schema --check"
             """
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

      assert igniter.tasks == @release_tasks

      assert messages_starting(igniter.notices, "eh_os_contract.lock records") == [
               @record_lock_notice
             ]
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

      assert igniter.tasks == @release_tasks
      assert messages_starting(igniter.notices, "No module under lib/") == [no_contract_notice()]
    end

    # The engine refuses to record a project with no contract, and so would the check.
    test "leaves a project with no contract without either, and says when to run again" do
      igniter = install()

      assert igniter.tasks == @release_tasks
      assert messages_starting(igniter.notices, "No module under lib/") == [no_contract_notice()]

      assert igniter |> apply_igniter!() |> precommit_steps() == """
             &hex_audit/1,
             "compile --warnings-as-errors",
             "deps.unlock --unused",
             "format",
             "test --warnings-as-errors",
             "eh_os_contract.check",
             "credo"
             """
    end
  end

  # The steps of the project's `precommit` alias, one a line, as written but for their
  # indentation.
  defp precommit_steps(igniter) do
    [_, rest] = String.split(content(igniter, "mix.exs"), "precommit: [\n", parts: 2)
    [steps, _] = String.split(rest, "\n      ]", parts: 2)

    steps
    |> String.split("\n")
    |> Enum.map_join(&(String.trim(&1) <> "\n"))
  end
end

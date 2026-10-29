defmodule Mix.Tasks.EhosApp.InstallTest.Dependencies do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "dependencies" do
    # T-11: eh-os-contract's release, by the commit its tag names.
    test "adds the engine and the credential verifier from eh-os-contract's release" do
      mix = installed() |> content("mix.exs")

      assert mix =~
               ~r/\{:eh_os_contract, "~> 0\.12\.0",\s+github: "EmpoweredHouse\/eh-os-contract",\s+sparse: "packages\/eh_os_contract",\s+ref: "190105d1fe87a7418cd1b92eadd29dba27edb3b3",\s+override: true\}/

      assert mix =~
               ~r/\{:eh_os_contract_auth, "~> 0\.9\.0",\s+github: "EmpoweredHouse\/eh-os-contract",\s+sparse: "packages\/eh_os_contract_auth",\s+ref: "190105d1fe87a7418cd1b92eadd29dba27edb3b3"\}/

      refute mix =~ "branch:"
    end

    # A release says it requires `EhosApp.requires/0` (eh-os D-91): it has to be what the
    # installer writes.
    test "writes each requirement a release says this ehos_app has" do
      mix = installed() |> content("mix.exs")

      assert map_size(EhosApp.requires()) == 3

      for {name, requirement} <- EhosApp.requires() do
        assert mix =~ ~s({:#{name}, "#{requirement}"), "#{name} is not required as #{requirement}"
      end
    end

    test "moves both packages from the commit 0.4 pinned to the release" do
      mix =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:eh_os_contract, "~> 0.3.0-dev",
           github: "EmpoweredHouse/eh-os-contract",
           sparse: "packages/eh_os_contract",
           ref: "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb",
           override: true},
          yes?: true
        )
        |> Igniter.Project.Deps.add_dep(
          {:eh_os_contract_auth, "~> 0.1.0-dev",
           github: "EmpoweredHouse/eh-os-contract",
           sparse: "packages/eh_os_contract_auth",
           ref: "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb"},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()
        |> content("mix.exs")

      refute mix =~ "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb"
      assert length(Regex.scan(~r/ref: "190105d1fe87a7418cd1b92eadd29dba27edb3b3"/, mix)) == 2
    end

    test "moves both packages from main, which 0.5.0 to 0.6.1 followed, to the release" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:eh_os_contract, "~> 0.3.0-dev",
           github: "EmpoweredHouse/eh-os-contract",
           sparse: "packages/eh_os_contract",
           branch: "main",
           override: true},
          yes?: true
        )
        |> Igniter.Project.Deps.add_dep(
          {:eh_os_contract_auth, "~> 0.1.0-dev",
           github: "EmpoweredHouse/eh-os-contract",
           sparse: "packages/eh_os_contract_auth",
           branch: "main"},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "eh_os_contract and eh_os_contract_auth were moved" and &1 =~ "v0.12.0")
             )

      mix = igniter |> apply_igniter!() |> content("mix.exs")
      refute mix =~ "branch:"
      assert length(Regex.scan(~r/ref: "190105d1fe87a7418cd1b92eadd29dba27edb3b3"/, mix)) == 2
    end

    test "leaves a project on the release as it is, and says nothing of moving it" do
      igniter = installed() |> Igniter.compose_task("ehos_app.install", [])

      assert igniter.issues == []
      refute Enum.any?(igniter.notices, &(&1 =~ "was moved" or &1 =~ "were moved"))
      refute Enum.any?(igniter.warnings, &(&1 =~ "eh-os-contract"))
    end

    test "says that a package it moved to the release is still locked to the old commit" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:eh_os_contract_auth, "~> 0.1.0-dev",
           github: "EmpoweredHouse/eh-os-contract",
           sparse: "packages/eh_os_contract_auth",
           ref: "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb"},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "eh_os_contract_auth was moved" and &1 =~ "The next `mix deps.get` takes")
             )

      # Read before the run is applied: applying it clears what it said.
      refute install() |> then(& &1.notices) |> Enum.any?(&(&1 =~ "was moved"))
    end

    test "says both that it moved one package and kept the other" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:eh_os_contract, "~> 0.3.0-dev",
           git: "git@github.com:EmpoweredHouse/eh-os-contract.git",
           sparse: "packages/eh_os_contract",
           ref: "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb",
           override: true},
          yes?: true
        )
        |> Igniter.Project.Deps.add_dep(
          {:eh_os_contract_auth, "~> 0.1.0-dev",
           github: "EmpoweredHouse/eh-os-contract",
           sparse: "packages/eh_os_contract_auth",
           ref: "ffffffffffffffffffffffffffffffffffffffff"},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert Enum.any?(igniter.notices, &(&1 =~ "eh_os_contract was moved"))
      assert Enum.any?(igniter.warnings, &(&1 =~ "eh_os_contract_auth was on a source"))
    end

    test "keeps a fork on its own main, and does not take it for eh-os-contract" do
      fork =
        {:eh_os_contract_auth, "~> 0.1.0-dev",
         github: "EmpoweredHouse/eh-os-contract-fork",
         sparse: "packages/eh_os_contract_auth",
         branch: "main"}

      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(fork, yes?: true)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert content(igniter, "mix.exs") =~ "EmpoweredHouse/eh-os-contract-fork"
      assert Enum.any?(igniter.warnings, &(&1 =~ "eh_os_contract_auth was on a source"))
    end

    test "keeps itself out of the application: needed only for upgrades, in development" do
      mix =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_app, github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_app"}
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("mix.exs")

      assert mix =~
               ~r/\{:ehos_app,\s+\[?\s*github: "EmpoweredHouse\/ehos-tools",\s+sparse: "packages\/ehos_app",\s+only: :dev,\s+runtime: false\s*\]?\}/
    end

    test "keeps itself to development when ehosctl pinned it with a version requirement" do
      mix =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_app, "== 0.3.0",
           github: "EmpoweredHouse/ehos-tools",
           sparse: "packages/ehos_app",
           ref: "bc23245f0e07d49ad5a2969707727b9e650ccc28"}
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("mix.exs")

      assert mix =~ ~r/\{:ehos_app, "== 0\.3\.0",/

      assert mix =~
               ~r/ref: "bc23245f0e07d49ad5a2969707727b9e650ccc28",\s+only: :dev,\s+runtime: false/
    end

    test "runs the contract compiler after Elixir's" do
      assert installed() |> content("mix.exs") =~
               "compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:eh_os_contract],"
    end

    test "runs the contract check in precommit" do
      install()
      |> assert_has_patch("mix.exs", """
      + |        "eh_os_contract.check"
      """)
    end
  end
end

defmodule Mix.Tasks.EhosApp.InstallTest.Dependencies do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # ehos_contract's release this ehos_app pins, by the commit its tag names.
  @release_ref "a4bc6c9e4d519ec725dba34e3e8e25fc80010a55"

  # The commit an earlier ehos_app pinned.
  @earlier_ref "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb"

  # ehos_contract's release v0.12.0, which ehos_app 0.22.0 to 0.26.0 pinned.
  @previous_release_ref "190105d1fe87a7418cd1b92eadd29dba27edb3b3"

  @license_notice """
  LICENSE is the Apache License 2.0, in the name of Empowered House PSA. If the application
  belongs to someone else, or is to be licensed otherwise, change it before the first push.
  """

  # What the notice of a move says after the packages it names.
  @moved_to_release """
   from ehos_contract's main, or the commit an earlier ehos_app
  pinned, to its release v0.17.0, commit a4bc6c9e4d519ec725dba34e3e8e25fc80010a55
  (ehos-tools' T-11). The next `mix deps.get` takes that commit into mix.lock, which may be
  older than the one main had locked: read the diff of mix.lock before committing it.

  From 0.3.0, ehos_contract's 0.4.0 to 0.7.0 change what a project must do (their release
  notes say how): the engine's tables move to version 4, and the release before them must be
  stopped before they move, since it does not refuse the newer tables; every contract's
  version moves once, and read models are marked stale; a contract's own `process`, stage
  groups and `terminal:` no longer compile, and a run is a module of its own,
  `use EhosContract.Process`; a duration longer than 100 years no longer compiles; and
  ehos_contract.lock holds every event's fields, recorded before any event changes.

  ehos_contract's 0.14.0, 0.15.0 and 0.16.0 change what a project must do; their release
  notes list each change. Among them: the engine's tables move to version 7, through a
  migration this run adds where none goes there yet, and the engine does not start before it
  runs; a release on an earlier ehos_contract does not start on version 7
  either, so stop it before the migration runs, and to go back to it, roll the migration back
  with the new release first; an append wakes the subscriptions when it commits, through
  Oban's Postgres notifier on Oban's prefix, and otherwise waits for their poll, now every 30
  seconds, so a project that gave Oban another notifier or prefix, or whose schema's name is
  44 bytes or longer, gives the `EhosContract` child in application.ex a lower
  `subscription_poll:`;
  `EhosContract.Plug` refuses a command or a recorded event that is not JSON, so a test or a
  caller of `/api` sends `content-type: application/json`, which the example's test of `/api`
  that an earlier ehos_app wrote with --example does not; and a project with personal data
  reads the changes to the rewrap and to a data key that does not unwrap at boot. Nothing
  asks it, but `EhosContract.call/3` now reads a form's params with `form: true`, so a
  context need not convert a form's text by hand
  (deps/ehos_contract/packages/ehos_contract/docs/forms.md).
  """

  describe "dependencies" do
    # T-11: ehos_contract's release, by the commit its tag names.
    test "adds the engine and the credential verifier from ehos_contract's release" do
      igniter = installed()

      assert dep(igniter, :ehos_contract) ==
               {:ehos_contract, "~> 0.17.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract",
                ref: @release_ref,
                override: true}

      assert dep(igniter, :ehos_contract_auth) ==
               {:ehos_contract_auth, "~> 0.18.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract_auth",
                ref: @release_ref}
    end

    # A release says it requires `EhosApp.requires/0` (eh-os D-91): it has to be what the
    # installer writes.
    test "writes each requirement a release says this ehos_app has" do
      igniter = installed()

      written =
        Map.new(
          [:ehos_contract, :ehos_contract_auth, :ehos_design],
          &{Atom.to_string(&1), igniter |> dep(&1) |> elem(1)}
        )

      assert written == EhosApp.requires()
    end

    test "runs Boundary's compiler first, and the contract's after Elixir's" do
      assert installed() |> trimmed_lines_starting("mix.exs", "compilers:") == [
               "compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers() ++ [:ehos_contract],"
             ]
    end

    test "runs the contract check in precommit" do
      install()
      |> assert_has_patch("mix.exs", """
      + |        "ehos_contract.check"
      """)
    end

    test "keeps itself out of the application: needed only for upgrades, in development" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_app, github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_app"}
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert dep(igniter, :ehos_app) ==
               {:ehos_app,
                github: "EmpoweredHouse/ehos-tools",
                sparse: "packages/ehos_app",
                only: :dev,
                runtime: false}
    end

    test "keeps itself to development when ehosctl pinned it with a version requirement" do
      igniter =
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

      assert dep(igniter, :ehos_app) ==
               {:ehos_app, "== 0.3.0",
                github: "EmpoweredHouse/ehos-tools",
                sparse: "packages/ehos_app",
                ref: "bc23245f0e07d49ad5a2969707727b9e650ccc28",
                only: :dev,
                runtime: false}
    end

    test "moves both packages from the commit 0.4 pinned to the release" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_contract, "~> 0.3.0-dev",
           github: "EmpoweredHouse/ehos_contract",
           sparse: "packages/ehos_contract",
           ref: @earlier_ref,
           override: true},
          yes?: true
        )
        |> Igniter.Project.Deps.add_dep(
          {:ehos_contract_auth, "~> 0.1.0-dev",
           github: "EmpoweredHouse/ehos_contract",
           sparse: "packages/ehos_contract_auth",
           ref: @earlier_ref},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()

      assert dep(igniter, :ehos_contract) ==
               {:ehos_contract, "~> 0.17.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract",
                ref: @release_ref,
                override: true}

      assert dep(igniter, :ehos_contract_auth) ==
               {:ehos_contract_auth, "~> 0.18.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract_auth",
                ref: @release_ref}
    end

    test "moves both packages from v0.12.0, which 0.22.0 to 0.26.0 pinned, to the release" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_contract, "~> 0.12.0",
           github: "EmpoweredHouse/ehos_contract",
           sparse: "packages/ehos_contract",
           ref: @previous_release_ref,
           override: true},
          yes?: true
        )
        |> Igniter.Project.Deps.add_dep(
          {:ehos_contract_auth, "~> 0.9.0",
           github: "EmpoweredHouse/ehos_contract",
           sparse: "packages/ehos_contract_auth",
           ref: @previous_release_ref},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()

      assert dep(igniter, :ehos_contract) ==
               {:ehos_contract, "~> 0.17.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract",
                ref: @release_ref,
                override: true}

      assert dep(igniter, :ehos_contract_auth) ==
               {:ehos_contract_auth, "~> 0.18.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract_auth",
                ref: @release_ref}
    end

    test "moves both packages from main, which 0.5.0 to 0.6.1 followed, to the release" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_contract, "~> 0.3.0-dev",
           github: "EmpoweredHouse/ehos_contract",
           sparse: "packages/ehos_contract",
           branch: "main",
           override: true},
          yes?: true
        )
        |> Igniter.Project.Deps.add_dep(
          {:ehos_contract_auth, "~> 0.1.0-dev",
           github: "EmpoweredHouse/ehos_contract",
           sparse: "packages/ehos_contract_auth",
           branch: "main"},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert messages_starting(
               igniter.notices,
               "ehos_contract and ehos_contract_auth were moved"
             ) ==
               ["ehos_contract and ehos_contract_auth were moved" <> @moved_to_release]

      igniter = apply_igniter!(igniter)

      assert dep(igniter, :ehos_contract) ==
               {:ehos_contract, "~> 0.17.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract",
                ref: @release_ref,
                override: true}

      assert dep(igniter, :ehos_contract_auth) ==
               {:ehos_contract_auth, "~> 0.18.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract_auth",
                ref: @release_ref}
    end

    test "says that a package it moved to the release is still locked to the old commit" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_contract_auth, "~> 0.1.0-dev",
           github: "EmpoweredHouse/ehos_contract",
           sparse: "packages/ehos_contract_auth",
           ref: @earlier_ref},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert messages_starting(igniter.notices, "ehos_contract_auth was moved") ==
               ["ehos_contract_auth was moved" <> @moved_to_release]

      # Read before the run is applied: applying it clears what it said.
      assert install().notices == [ready_notice(), no_contract_notice(), @license_notice]
    end

    test "says both that it moved one package and kept the other" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_contract, "~> 0.3.0-dev",
           git: "git@github.com:EmpoweredHouse/ehos_contract.git",
           sparse: "packages/ehos_contract",
           ref: @earlier_ref,
           override: true},
          yes?: true
        )
        |> Igniter.Project.Deps.add_dep(
          {:ehos_contract_auth, "~> 0.1.0-dev",
           github: "EmpoweredHouse/ehos_contract",
           sparse: "packages/ehos_contract_auth",
           ref: "ffffffffffffffffffffffffffffffffffffffff"},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert messages_starting(igniter.notices, "ehos_contract was moved") ==
               ["ehos_contract was moved" <> @moved_to_release]

      assert igniter.warnings == [auth_left_warning()]
    end

    test "leaves a project on the release as it is, and says nothing of moving it" do
      igniter = installed() |> Igniter.compose_task("ehos_app.install", [])

      assert igniter.issues == []
      assert igniter.notices == [ready_notice(), no_contract_notice()]
      assert igniter.warnings == []
    end

    test "keeps a fork on its own main, and does not take it for ehos_contract" do
      fork =
        {:ehos_contract_auth, "~> 0.1.0-dev",
         github: "EmpoweredHouse/ehos_contract-fork",
         sparse: "packages/ehos_contract_auth",
         branch: "main"}

      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(fork, yes?: true)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert dep(igniter, :ehos_contract_auth) == fork
      assert igniter.warnings == [auth_left_warning()]
    end
  end
end

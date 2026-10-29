defmodule Mix.Tasks.EhosApp.InstallTest.Migrations do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # The verifier's migration as 0.2 wrote it, to the version current when it ran.
  @v02_verifier_migration """
  defmodule Test.Repo.Migrations.AddEhOsContractAuth do
    use Ecto.Migration

    def up, do: EhOsContract.Auth.Migrations.up()

    def down, do: EhOsContract.Auth.Migrations.down()
  end
  """

  describe "migrations" do
    test "migrates the engine and the verifier after a migration generated in the same second" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("priv/repo/migrations/29990101000000_add_oban.exs", "")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Igniter.exists?(
               igniter,
               "priv/repo/migrations/29990101000001_add_eh_os_contract.exs"
             )

      assert Igniter.exists?(
               igniter,
               "priv/repo/migrations/29990101000002_add_eh_os_contract_auth.exs"
             )
    end

    # eh-os-contract 0.5.0 moved the engine's tables to version 4, and the engine refuses to start
    # on 3: a project an earlier version made, whose migration called `up()`, gets one for 4.
    # eh-os-contract 0.4.0 removed a contract's own `process` and `terminal:`: a project moved
    # from 0.3.0 is told which of its files still declare them, which are its own to change.
    test "names a contract that still declares its own process, when the project moves from 0.3.0" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:eh_os_contract, "~> 0.3.0",
           github: "EmpoweredHouse/eh-os-contract",
           sparse: "packages/eh_os_contract",
           ref: "3304f355eb5d73058fa8fcf61813f9c0547f9fc6",
           override: true},
          yes?: true
        )
        |> Igniter.create_new_file("lib/test/contracts/old.ex", """
        defmodule Test.Contracts.Old do
          process :old, "Old" do
            correlate :id
          end
        end
        """)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert Enum.any?(
               igniter.warnings,
               &(&1 =~ "lib/test/contracts/old.ex declares a `process` of its own")
             )
    end

    test "migrates the engine's tables to version 4, in a project an earlier version made" do
      upgraded =
        phx_test_project()
        |> Igniter.create_new_file(
          "priv/repo/migrations/20260930000000_add_eh_os_contract.exs",
          """
          defmodule Test.Repo.Migrations.AddEhOsContract do
            use Ecto.Migration

            def up, do: EhOsContract.Migrations.up()

            def down, do: EhOsContract.Migrations.down()
          end
          """
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()

      [migration] = migrations(upgraded, "upgrade_eh_os_contract_to_v4")

      assert content(upgraded, migration) =~ "def up, do: EhOsContract.Migrations.up(version: 4)"
      # Rolled back, it takes version 4 alone, not the tables the first migration made.
      assert content(upgraded, migration) =~
               "def down, do: EhOsContract.Migrations.down(version: 4)"

      # A new project's engine migration names the version itself, and a second run adds none.
      new_project = installed()
      [first] = migrations(new_project, "add_eh_os_contract")
      assert content(new_project, first) =~ "def up, do: EhOsContract.Migrations.up(version: 4)"
      assert migrations(new_project, "upgrade_eh_os_contract_to_v4") == []

      upgraded
      |> Igniter.compose_task("ehos_app.install", ["--yes"])
      |> assert_unchanged()
    end

    test "migrates the verifier's tables to the version that holds signed-in people, in a project an earlier version made" do
      upgraded =
        phx_test_project()
        |> Igniter.create_new_file(
          "priv/repo/migrations/20260930000000_add_eh_os_contract_auth.exs",
          @v02_verifier_migration
        )
        |> Igniter.Project.Deps.add_dep(
          {:eh_os_contract_auth, "~> 0.1.0-dev",
           github: "EmpoweredHouse/eh-os-contract",
           sparse: "packages/eh_os_contract_auth",
           ref: "50eb7711c3235325834535d7d24239855c0e63d8"},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()

      [migration] = migrations(upgraded, "upgrade_eh_os_contract_auth_to_v3")

      assert content(upgraded, migration) =~
               "def up, do: EhOsContract.Auth.Migrations.up(version: 3)"

      # Rolled back, it takes version 3 alone, not the tables the first migration made.
      assert content(upgraded, migration) =~
               "def down, do: EhOsContract.Auth.Migrations.down(version: 3)"

      # A new project's verifier migration goes to the current version itself.
      assert migrations(installed(), "upgrade_eh_os_contract_auth_to_v3") == []
    end

    test "leaves a commit of eh-os-contract it does not know, which may be a later one" do
      dep =
        {:eh_os_contract_auth, "~> 0.1.0-dev",
         github: "EmpoweredHouse/eh-os-contract",
         sparse: "packages/eh_os_contract_auth",
         ref: "ffffffffffffffffffffffffffffffffffffffff"}

      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(dep, yes?: true)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert content(igniter, "mix.exs") =~ "ffffffffffffffffffffffffffffffffffffffff"
      assert content(igniter, "mix.exs") =~ ~s(ref: "190105d1fe87a7418cd1b92eadd29dba27edb3b3")
      assert igniter.issues == []
      assert Enum.any?(igniter.warnings, &(&1 =~ "eh_os_contract_auth was on a source"))

      # Its tables were never migrated here, so its first migration goes to the current version.
      assert migrations(igniter, "upgrade_eh_os_contract_auth_to_v3") == []
    end

    test "names the verifier's version in a new project's migration, and adds none to reach it" do
      igniter = installed()
      [migration] = migrations(igniter, "add_eh_os_contract_auth")

      assert content(igniter, migration) =~
               "def up, do: EhOsContract.Auth.Migrations.up(version: 3)"

      assert content(igniter, migration) =~ "def down, do: EhOsContract.Auth.Migrations.down()"
      assert migrations(igniter, "upgrade_eh_os_contract_auth_to_v3") == []
    end

    test "migrates the verifier's tables to version 3 on a project that followed main" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "priv/repo/migrations/20260930000000_add_eh_os_contract_auth.exs",
          @v02_verifier_migration
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
        |> apply_igniter!()

      assert [_] = migrations(igniter, "upgrade_eh_os_contract_auth_to_v3")
    end

    # Laid out as a developer may leave a file, unformatted: written to the test project's files
    # as they are, since Igniter formats what it creates.
    test "is not misled by a comment that names the call, on its own line or after code" do
      migration =
        String.replace(
          @v02_verifier_migration,
          "Migrations.up()",
          "Migrations.up() # later: EhOsContract.Auth.Migrations.up(version: 3)"
        ) <> "# later: EhOsContract.Auth.Migrations.up(version: 3)\n"

      igniter =
        phx_test_project()
        |> with_file("priv/repo/migrations/20260930000000_add_eh_os_contract_auth.exs", migration)
        |> Igniter.compose_task("ehos_app.install", [])

      assert [_] = migrations(igniter, "upgrade_eh_os_contract_auth_to_v3")
    end

    test "recognises the call to version 3 however it is laid out" do
      igniter =
        phx_test_project()
        |> with_file(
          "priv/repo/migrations/20260930000000_add_eh_os_contract_auth.exs",
          @v02_verifier_migration
        )
        |> with_file("priv/repo/migrations/20260930000001_to_v3_by_hand.exs", """
        defmodule Test.Repo.Migrations.ToV3ByHand do
          use Ecto.Migration

          def up do
            EhOsContract.Auth.Migrations.up(
              version: 3
            )
          end

          def down, do: EhOsContract.Auth.Migrations.down(version: 3)
        end
        """)
        |> Igniter.compose_task("ehos_app.install", [])

      assert migrations(igniter, "upgrade_eh_os_contract_auth_to_v3") == []
    end

    test "migrates the verifier's tables to version 3 on a commit it does not know, too" do
      dep =
        {:eh_os_contract_auth, "~> 0.1.0-dev",
         github: "EmpoweredHouse/eh-os-contract",
         sparse: "packages/eh_os_contract_auth",
         ref: "ffffffffffffffffffffffffffffffffffffffff"}

      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "priv/repo/migrations/20260930000000_add_eh_os_contract_auth.exs",
          @v02_verifier_migration
        )
        |> Igniter.Project.Deps.add_dep(dep, yes?: true)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert [_] = migrations(igniter, "upgrade_eh_os_contract_auth_to_v3")
    end

    test "puts Oban's tables in the application's schema" do
      migration =
        phx_test_project()
        |> Igniter.create_new_file("priv/repo/migrations/29990101000000_add_oban.exs", """
        defmodule Test.Repo.Migrations.AddOban do
          use Ecto.Migration

          def up, do: Oban.Migration.up()

          def down, do: Oban.Migration.down(version: 1)
        end
        """)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("priv/repo/migrations/29990101000000_add_oban.exs")

      assert migration =~ "Oban.Migration.up(prefix: oban_prefix(), create_schema: false)"
      assert migration =~ "Oban.Migration.down(prefix: oban_prefix(), version: 1)"
      assert migration =~ ~s|Application.fetch_env!(:test, Oban)[:prefix] \|\| "public"|
      assert {:ok, _} = Code.string_to_quoted(migration)
    end

    test "leaves an Oban migration it does not recognise alone, and says so" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "priv/repo/migrations/29990101000000_add_oban.exs",
          "# the developer's own\n"
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "priv/repo/migrations/29990101000000_add_oban.exs") ==
               "# the developer's own\n"

      assert Enum.any?(igniter.warnings, &(&1 =~ "create_schema: false"))
    end
  end

  defp migrations(igniter, name) do
    igniter.rewrite
    |> Enum.map(&Rewrite.Source.get(&1, :path))
    |> Enum.filter(&(&1 =~ ~r|\Apriv/repo/migrations/\d{14}_#{name}\.exs\z|))
  end
end

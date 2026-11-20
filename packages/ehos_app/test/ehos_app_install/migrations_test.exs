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

  # The migration that takes the verifier's tables of a project an earlier version made to the
  # version that holds signed-in people: rolled back, it takes version 3 alone, not the tables
  # the first migration made.
  @verifier_v3_upgrade """
  defmodule Test.Repo.Migrations.UpgradeEhOsContractAuthToV3 do
    use Ecto.Migration

    def up, do: EhOsContract.Auth.Migrations.up(version: 3)

    def down, do: EhOsContract.Auth.Migrations.down(version: 3)
  end
  """

  @unknown_ref "ffffffffffffffffffffffffffffffffffffffff"

  describe "migrations" do
    test "migrates the engine and the verifier after a migration generated in the same second" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("priv/repo/migrations/29990101000000_add_oban.exs", "")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert migrations(igniter, "add_eh_os_contract") == [
               "priv/repo/migrations/29990101000001_add_eh_os_contract.exs"
             ]

      assert migrations(igniter, "add_eh_os_contract_auth") == [
               "priv/repo/migrations/29990101000002_add_eh_os_contract_auth.exs"
             ]
    end

    # eh-os-contract 0.15.0 moved the engine's tables to version 6, and the engine refuses to
    # start on 5: a project an earlier version made gets a migration for 6, whether its migration
    # named version 5, as 0.33.0 to 0.36.0 wrote it, version 4, or called `up()`, as the earliest
    # versions wrote it.
    for call <- ["up(version: 5)", "up(version: 4)", "up()"] do
      test "migrates the engine's tables to version 6, from a project whose migration calls #{call}" do
        upgraded =
          phx_test_project()
          |> Igniter.create_new_file(
            "priv/repo/migrations/20260930000000_add_eh_os_contract.exs",
            """
            defmodule Test.Repo.Migrations.AddEhOsContract do
              use Ecto.Migration

              def up, do: EhOsContract.Migrations.#{unquote(call)}

              def down, do: EhOsContract.Migrations.down()
            end
            """
          )
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", ["--yes"])
          |> apply_igniter!()

        [migration] = migrations(upgraded, "upgrade_eh_os_contract_to_v6")

        # Rolled back, it takes version 6 alone, not the tables the first migration made.
        assert content(upgraded, migration) == """
               defmodule Test.Repo.Migrations.UpgradeEhOsContractToV6 do
                 use Ecto.Migration

                 def up, do: EhOsContract.Migrations.up(version: 6)

                 def down, do: EhOsContract.Migrations.down(version: 6)
               end
               """

        upgraded
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> assert_unchanged()
      end
    end

    # A commit of its own may be a later one, so the engine's tables still move; an earlier one
    # refuses version 6, and the warning that keeps the commit says so.
    test "migrates the engine's tables to version 6 on a commit it does not know, and says what that needs" do
      engine =
        {:eh_os_contract, "~> 0.14.0",
         github: "EmpoweredHouse/eh-os-contract",
         sparse: "packages/eh_os_contract",
         ref: @unknown_ref,
         override: true}

      upgraded =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(engine, yes?: true)
        |> Igniter.create_new_file(
          "priv/repo/migrations/20260930000000_add_eh_os_contract.exs",
          """
          defmodule Test.Repo.Migrations.AddEhOsContract do
            use Ecto.Migration

            def up, do: EhOsContract.Migrations.up(version: 5)

            def down, do: EhOsContract.Migrations.down()
          end
          """
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert dep(upgraded, :eh_os_contract) == engine
      assert [_migration] = migrations(upgraded, "upgrade_eh_os_contract_to_v6")

      assert upgraded.warnings == [
               """
               eh_os_contract was on a source or a commit of eh-os-contract that this version of ehos_app
               does not know, so it was left as it is. This ehos_app is written for eh-os-contract's
               release v0.15.1 (b4e5a82e17e19588bb6b312e5b154c24254632ea); signing people in through
               EHOS needs da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb or a later commit.
               The engine's migrations go to version 6 of its tables, which needs
               eh-os-contract v0.15.1 or a later commit: an earlier engine refuses it.
               """
             ]
    end

    test "names the engine's version in a new project's migration, and adds no upgrade" do
      new_project = installed()
      [first] = migrations(new_project, "add_eh_os_contract")

      assert content(new_project, first) == """
             defmodule Test.Repo.Migrations.AddEhOsContract do
               use Ecto.Migration

               def up, do: EhOsContract.Migrations.up(version: 6)

               def down, do: EhOsContract.Migrations.down()
             end
             """

      assert migrations(new_project, "upgrade_eh_os_contract_to_v6") == []
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

      assert content(upgraded, migration) == @verifier_v3_upgrade

      # A new project's verifier migration goes to the current version itself.
      assert migrations(installed(), "upgrade_eh_os_contract_auth_to_v3") == []
    end

    test "names the verifier's version in a new project's migration, and adds none to reach it" do
      igniter = installed()
      [migration] = migrations(igniter, "add_eh_os_contract_auth")

      assert content(igniter, migration) == """
             defmodule Test.Repo.Migrations.AddEhOsContractAuth do
               use Ecto.Migration

               def up, do: EhOsContract.Auth.Migrations.up(version: 3)

               def down, do: EhOsContract.Auth.Migrations.down()
             end
             """

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

      [migration] = migrations(igniter, "upgrade_eh_os_contract_auth_to_v3")

      assert content(igniter, migration) == @verifier_v3_upgrade
    end

    test "migrates the verifier's tables to version 3 on a commit it does not know, too" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "priv/repo/migrations/20260930000000_add_eh_os_contract_auth.exs",
          @v02_verifier_migration
        )
        |> Igniter.Project.Deps.add_dep(verifier_on_unknown_commit(), yes?: true)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      [migration] = migrations(igniter, "upgrade_eh_os_contract_auth_to_v3")

      assert content(igniter, migration) == @verifier_v3_upgrade
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

      [upgrade] = migrations(igniter, "upgrade_eh_os_contract_auth_to_v3")

      assert content(igniter, upgrade) == @verifier_v3_upgrade
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

      assert migration == """
             defmodule Test.Repo.Migrations.AddOban do
               use Ecto.Migration

               def up, do: Oban.Migration.up(prefix: oban_prefix(), create_schema: false)

               def down, do: Oban.Migration.down(prefix: oban_prefix(), version: 1)

               # Where Oban's configuration looks for its tables: the schema EHOS gives the
               # application, which exists already and which its owner may not create.
               defp oban_prefix, do: Application.fetch_env!(:test, Oban)[:prefix] || "public"
             end
             """
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

      assert igniter.warnings == [
               """
               priv/repo/migrations/29990101000000_add_oban.exs is not the migration Oban's installer writes, so it was left alone. Oban's
               tables must go in the schema EHOS gives the application: pass
               `prefix: Application.fetch_env!(:test, Oban)[:prefix] || "public"` and
               `create_schema: false` to `Oban.Migration.up/1` and `down/1`.
               """
             ]
    end

    test "leaves a commit of eh-os-contract it does not know, which may be a later one" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(verifier_on_unknown_commit(), yes?: true)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert dep(igniter, :eh_os_contract_auth) == verifier_on_unknown_commit()

      assert dep(igniter, :eh_os_contract) ==
               {:eh_os_contract, "~> 0.15.0",
                github: "EmpoweredHouse/eh-os-contract",
                sparse: "packages/eh_os_contract",
                ref: "b4e5a82e17e19588bb6b312e5b154c24254632ea",
                override: true}

      assert igniter.issues == []
      assert igniter.warnings == [auth_left_warning()]

      # Its tables were never migrated here, so its first migration goes to the current version.
      assert migrations(igniter, "upgrade_eh_os_contract_auth_to_v3") == []
    end

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

      assert igniter.warnings == [
               """
               lib/test/contracts/old.ex declares a `process` of its own or an event
               `terminal:`, which eh-os-contract v0.15.1 refuses to compile. Remove
               them, and write the run as a module of its own, `use EhOsContract.Process`, as
               deps/eh_os_contract/packages/eh_os_contract/docs/process.md says.
               """
             ]
    end
  end

  # The migrations named `name` the project has; their timestamps are the time they were
  # generated, which a test cannot know.
  defp migrations(igniter, name) do
    igniter.rewrite
    |> Enum.map(&Rewrite.Source.get(&1, :path))
    |> Enum.filter(&(&1 =~ ~r|\Apriv/repo/migrations/\d{14}_#{name}\.exs\z|))
  end

  # The verifier on a commit of eh-os-contract this ehos_app does not know, which may be a
  # later one.
  defp verifier_on_unknown_commit do
    {:eh_os_contract_auth, "~> 0.1.0-dev",
     github: "EmpoweredHouse/eh-os-contract",
     sparse: "packages/eh_os_contract_auth",
     ref: @unknown_ref}
  end
end

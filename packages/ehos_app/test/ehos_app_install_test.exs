defmodule Mix.Tasks.EhosApp.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Mix.Tasks.EhosApp.Install

  defp install(argv \\ []) do
    phx_test_project()
    |> Igniter.compose_task("ehos_app.install", argv)
  end

  # After `apply_igniter!/1`, the test project reads back only `**/*.*`, which leaves out
  # `Dockerfile` and every path under a dot directory; those are in its `test_files`.
  defp content(igniter, path) do
    case Rewrite.source(igniter.rewrite, path) do
      {:ok, source} -> Rewrite.Source.get(source, :content)
      {:error, _} -> Map.fetch!(igniter.assigns.test_files, path)
    end
  end

  defp installed(argv \\ []), do: install(argv) |> apply_igniter!()

  # The way in and out as 0.4 generated it, for `TestWeb`, formatted as Igniter writes it. Not
  # `.ex`, which `mix test` would warn matches no test file.
  @sign_in_components_04 File.read!("test/fixtures/sign_in_components_0.4.ex.txt")

  # The verifier's migration as 0.2 wrote it, to the version current when it ran.
  @v02_verifier_migration """
  defmodule Test.Repo.Migrations.AddEhOsContractAuth do
    use Ecto.Migration

    def up, do: EhOsContract.Auth.Migrations.up()

    def down, do: EhOsContract.Auth.Migrations.down()
  end
  """

  defp plugin(name), do: Enum.find(Install.plugins(), &(&1.name == name))

  # The three ways a developer is likely to decline the design system in app.css.
  defp decline(css, :import),
    do: String.replace(css, ~r/^@import "[^"]*ehos_design\.css";\n/m, "")

  defp decline(css, :import_and_comment),
    do:
      String.replace(
        css,
        ~r{/\* ehos_app:design-system:.*?\*/\n@import "[^"]*ehos_design\.css";\n}s,
        ""
      )

  defp decline(css, :comment_out),
    do: String.replace(css, ~r/^(@import "[^"]*ehos_design\.css";)$/m, "/* \\1 */")

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

  # `mix deps.get` prints a locked package's advisories and exits 0, so nothing failed on them
  # (#507). As a task of the alias, `hex.audit` is not found after `compile`, which prunes Hex
  # from the code path, and a finding sets the exit status without stopping later steps.
  describe "the dependency audit" do
    defp precommit(igniter) do
      {:ok, {:defmodule, _, [_, [{_, {:__block__, _, defs}}]]}} =
        igniter |> content("mix.exs") |> Code.string_to_quoted()

      [aliases] = for {:defp, _, [{:aliases, _, _}, [do: aliases]]} <- defs, do: aliases
      Keyword.fetch!(aliases, :precommit)
    end

    test "runs first in precommit, as a function of mix.exs" do
      igniter = installed()

      assert [{:&, _, [{:/, _, [{:hex_audit, _, _}, 1]}]}, "compile --warnings-as-errors" | _] =
               precommit(igniter)

      assert content(igniter, "mix.exs") =~ """
               defp hex_audit(_args) do
                 Application.load(:hex)
                 hex = to_string(Application.spec(:hex, :vsn) || "0.0.0")

                 if Version.match?(hex, "< 2.5.1") do
                   Mix.raise(
                     "mix hex.audit needs Hex 2.5.1 or later for advisories, and this is \#{hex}: run mix local.hex --force"
                   )
                 end

                 case Mix.shell().cmd("mix hex.audit", env: [{"MIX_ENV", to_string(Mix.env())}]) do
                   0 ->
                     :ok

                   status ->
                     Mix.raise("mix hex.audit exited with \#{status}: see TESTING.md, Dependency advisories",
                       exit_status: status
                     )
                 end
               end
             """
    end

    # The audit as a project might have written it: a task of the alias, first or after compile.
    test "replaces a plain hex.audit in precommit, wherever it is" do
      for alias <- [
            ~s(precommit: ["hex.audit", "compile --warnings-as-errors", "test"]),
            ~s(precommit: ["compile --warnings-as-errors", "hex.audit", "test"]),
            ~s(precommit: ["hex.audit", "compile --warnings-as-errors", "hex.audit", "test"]),
            ~s(precommit: [&hex_audit/1, "compile --warnings-as-errors", "hex.audit", "test"])
          ] do
        igniter =
          phx_test_project()
          |> Igniter.update_file("mix.exs", fn source ->
            Rewrite.Source.update(source, :content, fn mix_exs ->
              String.replace(mix_exs, ~r/precommit: \[[^\]]*\]/, alias)
            end)
          end)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])
          |> apply_igniter!()

        assert [{:&, _, _}, "compile --warnings-as-errors", "test" | _] = precommit(igniter)
        assert length(String.split(content(igniter, "mix.exs"), "hex_audit/1")) == 2
      end
    end

    test "leaves a hex_audit/1 the project defined as it is, private or public" do
      for own <- [
            "  defp hex_audit(_args), do: Mix.shell().cmd(\"mix hex.audit --policy\")\n",
            "  def hex_audit(_args), do: Mix.shell().cmd(\"mix hex.audit --policy\")\n"
          ] do
        leaves_own_hex_audit(own)
      end
    end

    defp leaves_own_hex_audit(own) do
      igniter =
        phx_test_project()
        |> Igniter.update_file("mix.exs", fn source ->
          Rewrite.Source.update(source, :content, fn mix_exs ->
            String.replace(mix_exs, ~r/\nend\s*\z/, "\n" <> own <> "end\n")
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      mix_exs = content(igniter, "mix.exs")

      assert mix_exs =~ own
      assert length(String.split(mix_exs, ~r/defp? hex_audit\(/)) == 2
      assert [{:&, _, _} | _] = precommit(igniter)
    end
  end

  # eh-os-contract 0.7.0's lock (#274): recorded by the engine once the files are written, so a
  # new project's first commit holds its events' fields, and checked by every precommit.
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

  describe "configuration" do
    test "configures the engine with the application, its repo and EHOS's verifier" do
      config = installed() |> content("config/config.exs")

      assert config =~ "applications: [:test]"
      assert config =~ "repo: Test.Repo"
      assert config =~ "authorizer: EhOsContract.Auth"
    end

    test "trusts a test key in tests, and runs no subscription or health listener there" do
      config = installed() |> content("config/test.exs")

      assert config =~
               ~r/config :eh_os_contract_auth,\s+issuer: "https:\/\/ehos.test",\s+audience: "test\/test",\s+pin_keys: true/

      assert config =~ "config :eh_os_contract, subscriptions: :manual"
      assert config =~ "config :test, TestWeb.Health, server: false"
    end

    test "expects a local EHOS in development" do
      assert installed() |> content("config/dev.exs") =~
               ~r/config :eh_os_contract_auth,\s+issuer: "https:\/\/ehos.localhost",\s+audience: "test\/dev"/
    end

    # `DATABASE_URL`, `PHX_HOST`, `PHX_SERVER` and `SECRET_KEY_BASE` are read by what
    # Phoenix itself generates, under the names EHOS gives them.
    test "reads what EHOS gives an application at start, in production" do
      runtime = installed() |> content("config/runtime.exs")
      [_, prod] = String.split(runtime, "if config_env() == :prod do", parts: 2)

      for variable <-
            ~w(EHOS_ISSUER EHOS_AUDIENCE EHOS_CA_FILE DATABASE_SCHEMA DATABASE_CA_CERT_FILE) do
        assert prod =~ ~s|"#{variable}"|, "#{variable} is not read"
      end

      assert prod =~ "parameters: [search_path: database_schema]"
      assert prod =~ "config :test, Oban, prefix: database_schema"
      assert prod =~ "config :test, EhOsContract.Auth, cacertfile: ehos_ca_file"
    end

    test "signs people in with the client EHOS gives, in production" do
      runtime = installed() |> content("config/runtime.exs")
      [_, prod] = String.split(runtime, "if config_env() == :prod do", parts: 2)

      for variable <-
            ~w(EHOS_CLIENT_ID EHOS_CLIENT_KEY_FILE PHX_HOST SECRET_KEY_BASE EHOS_SIGN_IN_APPLICATIONS) do
        assert prod =~ ~s|"#{variable}"|, "#{variable} is not read"
      end

      assert prod =~ ~s|address: "https://" <> System.fetch_env!("PHX_HOST")|
      assert prod =~ "config :test, EhOsContract.Auth.SignIn, cacertfile: ehos_ca_file"
    end

    # eh-os D-113: a session ends when EHOS ends the person's sign-in, at the installation's limit.
    test "ends a session when EHOS ends the sign-in" do
      igniter = install()

      assert igniter |> apply_igniter!() |> content("config/runtime.exs") =~
               ~s|absolute_limit: String.to_integer(System.get_env("EHOS_SIGN_IN_ABSOLUTE", "43200"))|

      refute Enum.any?(igniter.notices, &(&1 =~ "without `absolute_limit`"))
    end

    test "says the limit's line to a project whose sign-in an earlier version wrote" do
      igniter =
        installed()
        |> Igniter.update_file("config/runtime.exs", fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            String.replace(content, ~r/,\n\s+absolute_limit: [^\n]+/, "")
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      refute content(igniter, "config/runtime.exs") =~ "EHOS_SIGN_IN_ABSOLUTE"
      assert [notice] = Enum.filter(igniter.notices, &(&1 =~ "without `absolute_limit`"))
      assert notice =~ ~s|System.get_env("EHOS_SIGN_IN_ABSOLUTE", "43200")|
    end

    # EHOS gives `EHOS_CLIENT_ID` to a workload that reads the people (eh-os D-81) or sends mail
    # (eh-os D-140) too, and `EHOS_SIGN_IN_APPLICATIONS` only to one whose `ehos.yaml` declares
    # `sign_in` (#460).
    test "starts without the sign-in's variables, signing nobody in" do
      runtime = installed() |> content("config/runtime.exs")

      assert runtime =~
               ~s|if ehos_sign_in_applications = System.get_env("EHOS_SIGN_IN_APPLICATIONS") do|

      refute runtime =~ ~s|System.fetch_env!("EHOS_SIGN_IN_APPLICATIONS")|
    end

    test "signs nobody in with the key EHOS gives for the people or for mail alone" do
      block = installed() |> content("config/runtime.exs") |> sign_in_block()

      key_only = %{"EHOS_CLIENT_ID" => "ledger", "EHOS_CLIENT_KEY_FILE" => "/ehos/key.json"}

      signing_in =
        Map.merge(key_only, %{
          "EHOS_SIGN_IN_APPLICATIONS" => ~s|{"office":"https://office.example.org"}|,
          "PHX_HOST" => "ledger.example.org",
          "SECRET_KEY_BASE" => "base"
        })

      assert read_runtime(block, key_only) == []

      assert [eh_os_contract_auth: [sign_in: sign_in]] = read_runtime(block, signing_in)
      assert sign_in[:client_id] == "ledger"
      assert sign_in[:applications] == %{"office" => "https://office.example.org"}
    end

    test "says the condition to a project whose sign-in an earlier version keyed on the client" do
      igniter =
        installed()
        |> Igniter.update_file("config/runtime.exs", fn source ->
          Rewrite.Source.update(source, :content, &earlier_sign_in_condition/1)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      runtime = content(igniter, "config/runtime.exs")
      assert runtime =~ ~s|if ehos_client_id = System.get_env("EHOS_CLIENT_ID") do|
      assert runtime =~ ~s|System.get_env("EHOS_SIGN_IN_APPLICATIONS", "{}")|
      refute runtime =~ "ehos_sign_in_applications"
      assert length(String.split(runtime, "sign_in: [")) == 2

      assert [notice] =
               Enum.filter(igniter.notices, &(&1 =~ "wherever EHOS gives `EHOS_CLIENT_ID`"))

      assert notice =~ ~s|System.get_env("EHOS_SIGN_IN_APPLICATIONS")|
    end

    test "says no condition to a project that keys sign-in on its own variable" do
      igniter = install()

      refute Enum.any?(igniter.notices, &(&1 =~ "wherever EHOS gives `EHOS_CLIENT_ID`"))
    end

    test "says no condition to a project whose sign-in reads both variables" do
      igniter =
        installed()
        |> Igniter.update_file("config/runtime.exs", fn source ->
          Rewrite.Source.update(source, :content, fn runtime ->
            runtime
            |> earlier_sign_in_condition()
            |> String.replace(
              ~s|if ehos_client_id = System.get_env("EHOS_CLIENT_ID") do|,
              ~s|if (ehos_client_id = System.get_env("EHOS_CLIENT_ID")) && | <>
                ~s|System.get_env("EHOS_SIGN_IN_APPLICATIONS") do|
            )
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "config/runtime.exs") =~
               ~s|System.get_env("EHOS_SIGN_IN_APPLICATIONS") do|

      refute Enum.any?(igniter.notices, &(&1 =~ "wherever EHOS gives `EHOS_CLIENT_ID`"))
    end

    # The mail's block ARCHITECTURE.md gives reads the client too; a project that removed sign-in
    # and keeps it does not get sign-in back.
    test "does not add sign-in back beside a block of the project's that reads the client" do
      mail = """
        if System.get_env("EHOS_CLIENT_ID") do
          config :eh_os_contract_auth,
            workload: [
              client_id: System.fetch_env!("EHOS_CLIENT_ID"),
              client_key_file: System.fetch_env!("EHOS_CLIENT_KEY_FILE")
            ]
        end
      """

      runtime =
        installed()
        |> Igniter.update_elixir_file("config/runtime.exs", fn zipper ->
          {:ok, without_sign_in(zipper)}
        end)
        |> apply_igniter!()
        |> Igniter.update_file("config/runtime.exs", fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &(&1 <> "\nif config_env() == :prod do\n" <> mail <> "end\n")
          )
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("config/runtime.exs")

      assert runtime =~ "workload: ["
      refute runtime =~ "EHOS_SIGN_IN_APPLICATIONS"
      refute runtime =~ "sign_in: ["
    end

    test "adds signing people in to a runtime.exs an earlier version configured" do
      runtime =
        phx_test_project()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> Igniter.update_elixir_file("config/runtime.exs", fn zipper ->
          {:ok, without_sign_in(zipper)}
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("config/runtime.exs")

      assert runtime =~ ~s|System.get_env("EHOS_SIGN_IN_APPLICATIONS")|
      assert length(String.split(runtime, ~s|"EHOS_ISSUER"|)) == 2
      assert length(String.split(runtime, "EhOsContract.Auth.SignIn, cacertfile:")) == 2
    end

    test "does not read PORT, which EHOS never sets" do
      project = phx_test_project()

      assert project
             |> Igniter.include_existing_file("config/runtime.exs")
             |> content("config/runtime.exs") =~
               ~s|System.get_env("PORT", "4000")|

      refute project
             |> Igniter.compose_task("ehos_app.install", [])
             |> apply_igniter!()
             # The variable's name: `OTEL_EXPORTER_OTLP_ENDPOINT` holds the letters too.
             |> content("config/runtime.exs") =~ ~s|"PORT"|
    end

    test "listens on the ports ehos.yaml declares" do
      igniter = installed()
      %{"serves" => [%{"port" => web}], "health" => %{"port" => health}} = ehos_yaml(igniter)

      config = read_config(igniter, :prod)

      assert get_in(config, [:test, TestWeb.Endpoint, :http, :port]) == web
      assert get_in(config, [:test, TestWeb.Health, :port]) == health
      assert Install.ports() == %{web: web, health: health}
    end

    # eh-os#492, EEF-CVE-2026-105659: Bandit's HTTP/2 stack is not served, on either listener.
    test "serves HTTP/1.1 alone, on the endpoint and on the probes' listener" do
      igniter = installed()

      assert get_in(read_config(igniter, :prod), [:test, TestWeb.Endpoint, :http, :http_2_options]) ==
               [enabled: false]

      assert content(igniter, "lib/test_web/health.ex") =~ "http_2_options: [enabled: false]"
    end
  end

  describe "logs and traces" do
    # eh-os D-93, Stage 15's step 6 (eh-os#485).
    test "adds the JSON logger and the OpenTelemetry SDK, the exporter before the SDK" do
      mix = installed() |> content("mix.exs")

      for {name, requirement} <- Install.telemetry_deps() do
        assert mix =~ "{#{inspect(name)}, #{inspect(requirement)}}"
      end

      position = &(mix |> :binary.match("{#{inspect(&1)},") |> elem(0))
      assert position.(:opentelemetry_exporter) < position.(:opentelemetry)
    end

    test "logs one JSON object a line in production, with the request, its trace and the work's correlation, and no credential in its fields" do
      config = installed() |> read_config(:prod)

      assert {LoggerJSON.Formatters.Elastic, options} =
               get_in(config, [:logger, :default_handler, :formatter])

      assert options[:metadata] == [:request_id, :correlation_id]
      assert [{LoggerJSON.Redactors.RedactKeys, keys}] = options[:redactors]
      assert "token" in keys and "password" in keys
    end

    test "sends traces nowhere, unless EHOS names a collector in production" do
      igniter = installed()

      assert get_in(read_config(igniter, :dev), [:opentelemetry, :traces_exporter]) == :none
      assert get_in(read_config(igniter, :test), [:opentelemetry, :traces_exporter]) == :none

      [_, prod] =
        String.split(content(igniter, "config/runtime.exs"), "if config_env() == :prod do",
          parts: 2
        )

      assert prod =~
               ~r/if System.get_env\("OTEL_EXPORTER_OTLP_ENDPOINT"\) do\s+config :opentelemetry, traces_exporter: :otlp\s+end/

      # Inside the production block: indented, as its lines are.
      assert prod =~ ~r/\n  if System.get_env\("OTEL_EXPORTER_OTLP_ENDPOINT"\) do/
    end

    test "traces each request and query from the start of the application, before its children, taking no caller's trace as its own" do
      application = installed() |> content("lib/test/application.ex")
      [before_children, _] = String.split(application, "children = [", parts: 2)

      assert before_children =~ "OpentelemetryBandit.setup(public_endpoint: true)"
      assert before_children =~ "OpentelemetryPhoenix.setup(adapter: :bandit)"
      assert before_children =~ "OpentelemetryEcto.setup([:test, :repo])"
    end

    test "starts the SDK so that its stopping never stops the release" do
      assert installed() |> content("mix.exs") =~
               "releases: [test: [applications: [opentelemetry: :temporary]]]"
    end

    test "a second run adds nothing twice" do
      igniter =
        installed()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      application = content(igniter, "lib/test/application.ex")
      runtime = content(igniter, "config/runtime.exs")

      assert length(String.split(application, "OpentelemetryPhoenix.setup")) == 2
      assert length(String.split(runtime, "OTEL_EXPORTER_OTLP_ENDPOINT\")")) == 2
      assert length(String.split(content(igniter, "mix.exs"), "{:opentelemetry,")) == 2
    end

    test "gives a project an earlier version made what it lacks" do
      earlier =
        installed()
        |> Igniter.Project.Deps.remove_dep(:logger_json)
        |> then(fn igniter ->
          Enum.reduce(
            Install.telemetry_deps(),
            igniter,
            &Igniter.Project.Deps.remove_dep(&2, elem(&1, 0))
          )
        end)
        |> Igniter.update_file("lib/test/application.ex", fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            content
            |> String.replace(~r/ *# eh-os D-93.*\n/, "")
            |> String.replace(~r/ *Opentelemetry\w+\.setup\(.*\)\n/, "")
          end)
        end)
        |> apply_igniter!()

      refute content(earlier, "lib/test/application.ex") =~ "Opentelemetry"

      igniter = earlier |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      assert content(igniter, "mix.exs") =~ ~s|{:opentelemetry, "~> 1.7"}|
      assert content(igniter, "lib/test/application.ex") =~ "OpentelemetryEcto.setup"
    end

    test "leaves a project's own tracing whole, saying what EHOS gives" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep({:opentelemetry, "~> 1.5"})
        |> Igniter.update_file("lib/test/application.ex", fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            String.replace(
              content,
              "def start(_type, _args) do\n",
              "def start(_type, _args) do\n    OpentelemetryPhoenix.setup(adapter: :cowboy2)\n"
            )
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert [notice] = Enum.filter(igniter.notices, &(&1 =~ "its tracing was left as it is"))
      # What the developer should do, not what EHOS would have done.
      assert notice =~ "only when OTEL_EXPORTER_OTLP_ENDPOINT is set"
      assert notice =~ "public_endpoint: true"

      igniter = apply_igniter!(igniter)
      mix = content(igniter, "mix.exs")
      application = content(igniter, "lib/test/application.ex")

      assert mix =~ ~s|{:opentelemetry, "~> 1.5"}|
      refute mix =~ ":opentelemetry_bandit"
      refute mix =~ "releases:"
      assert application =~ "OpentelemetryPhoenix.setup(adapter: :cowboy2)"
      refute application =~ "OpentelemetryBandit"
      assert get_in(read_config(igniter, :prod), [:opentelemetry, :traces_exporter]) == nil
      refute content(igniter, "config/runtime.exs") =~ "OTEL_EXPORTER_OTLP_ENDPOINT"
      # Its logs are another choice, and get the JSON formatter.
      assert mix =~ ":logger_json"
    end

    test "leaves a formatter the project chose, in any config file" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Config.configure(
          "config.exs",
          :logger,
          [:default_handler, :formatter],
          {:code, Sourceror.parse_string!("{MyFormatter, []}")}
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(igniter, "mix.exs") =~ ":logger_json"
      refute content(igniter, "config/prod.exs") =~ "LoggerJSON"
    end

    test "names no release of its own beside one the project named otherwise" do
      mix =
        phx_test_project()
        |> Igniter.Project.MixProject.update(:project, [:releases], fn nil ->
          {:ok, {:code, Sourceror.parse_string!("[web: [include_executables_for: [:unix]]]")}}
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("mix.exs")

      assert mix =~ "releases: [web: [include_executables_for: [:unix]]]"
    end

    test "a second run takes the tracing and logging it set up for its own, and says nothing of them" do
      igniter = installed() |> Igniter.compose_task("ehos_app.install", [])

      refute Enum.any?(igniter.notices, &(&1 =~ "left as it is"))
    end

    test "leaves a formatter set in runtime.exs's production block, and says so" do
      igniter =
        phx_test_project()
        |> Igniter.update_file("config/runtime.exs", fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            String.replace(
              content,
              "if config_env() == :prod do\n",
              "if config_env() == :prod do\n  config :logger, :default_handler, formatter: {MyFormatter, []}\n",
              global: false
            )
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "its logging was left as it is"))

      igniter = apply_igniter!(igniter)
      refute content(igniter, "mix.exs") =~ ":logger_json"
      refute content(igniter, "config/prod.exs") =~ "LoggerJSON"
    end

    test "leaves a project with logger_json and no formatter as it is, saying how to log JSON" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep({:logger_json, "~> 6.0"})
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert [notice] = Enum.filter(igniter.notices, &(&1 =~ "its logging was left as it is"))
      assert notice =~ "LoggerJSON.Formatters.Elastic"

      igniter = apply_igniter!(igniter)
      assert content(igniter, "mix.exs") =~ ~s|{:logger_json, "~> 6.0"}|
      refute content(igniter, "config/prod.exs") =~ "LoggerJSON"
    end

    test "adds the block that sends traces when runtime.exs only mentions its variable in a comment" do
      runtime =
        phx_test_project()
        |> Igniter.update_file("config/runtime.exs", fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &("# OTEL_EXPORTER_OTLP_ENDPOINT: later.\n" <> &1)
          )
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("config/runtime.exs")

      assert runtime =~ ~s|if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do|
    end

    test "says which block sends traces when there is no runtime.exs" do
      warnings =
        phx_test_project()
        |> Igniter.rm("config/runtime.exs")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> Map.fetch!(:warnings)

      assert Enum.any?(
               warnings,
               &(&1 =~ "sends no traces" and &1 =~ "config :opentelemetry, traces_exporter: :otlp")
             )
    end

    test "leaves Bandit's tracing a project set up without the SDK as it is, saying what to set, on every run" do
      igniter =
        phx_test_project()
        |> Igniter.update_file("lib/test/application.ex", fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            String.replace(
              content,
              "def start(_type, _args) do\n",
              "def start(_type, _args) do\n    OpentelemetryBandit.setup()\n"
            )
          end)
        end)
        |> apply_igniter!()

      for _run <- 1..2 do
        igniter = Igniter.compose_task(igniter, "ehos_app.install", [])
        assert Enum.any?(igniter.notices, &(&1 =~ "its tracing was left as it is"))
        assert Enum.any?(igniter.notices, &(&1 =~ "public_endpoint: true"))

        igniter = apply_igniter!(igniter)
        application = content(igniter, "lib/test/application.ex")
        assert length(String.split(application, "OpentelemetryBandit.setup")) == 2
        refute application =~ "OpentelemetryPhoenix"
        refute content(igniter, "mix.exs") =~ ":opentelemetry_phoenix"
      end
    end

    test "leaves a formatter named in a way the installer cannot read, and logger options in a variable" do
      for prod <- [
            "config :logger, :default_handler, formatter: {__MODULE__.Formatter, []}\n",
            "options = [formatter: {MyFormatter, []}]\nconfig :logger, :default_handler, options\n"
          ] do
        igniter =
          phx_test_project()
          |> Igniter.update_file("config/prod.exs", fn source ->
            Rewrite.Source.update(source, :content, &(&1 <> prod))
          end)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])

        assert Enum.any?(igniter.notices, &(&1 =~ "its logging was left as it is"))
        refute igniter |> apply_igniter!() |> content("mix.exs") =~ ":logger_json"
      end
    end

    test "leaves release options the code computes as they are" do
      mix =
        phx_test_project()
        |> Igniter.Project.MixProject.update(:project, [:releases], fn nil ->
          {:ok, {:code, Sourceror.parse_string!("[test: release_options()]")}}
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("mix.exs")

      assert mix =~ "releases: [test: release_options()]"
    end

    test "keeps what the release already says of the SDK" do
      mix =
        phx_test_project()
        |> Igniter.Project.MixProject.update(
          :project,
          [:releases, :test, :applications, :opentelemetry],
          fn nil -> {:ok, {:code, :permanent}} end
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("mix.exs")

      assert mix =~ "opentelemetry: :permanent"
      refute mix =~ "opentelemetry: :temporary"
    end
  end

  describe "crash reports" do
    # #234: what a crashed process held stays out of the report whoever reads the logs reads.
    test "inspect a crashed process's state and last message as their shape alone" do
      assert get_in(read_config(installed(), :prod), [:logger, :translator_inspect_opts]) ==
               [limit: 0, printable_limit: 0]
    end

    test "put the filter first in start/2, before the tracing, once, with its module and test" do
      igniter =
        installed()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      application = content(igniter, "lib/test/application.ex")
      [before_tracing, _] = String.split(application, "OpentelemetryBandit.setup", parts: 2)

      assert before_tracing =~ "Test.LogRedaction.install()"
      assert length(String.split(application, "Test.LogRedaction.install()")) == 2
      assert content(igniter, "lib/test/log_redaction.ex") =~ "defmodule Test.LogRedaction do"

      assert content(igniter, "test/test/log_redaction_test.exs") =~
               "defmodule Test.LogRedactionTest do"
    end
  end

  describe "the supervision tree" do
    test "moves the endpoint last as it is written, comments and options included" do
      application =
        phx_test_project()
        |> Igniter.update_file("lib/test/application.ex", fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            content
            |> String.replace("TestWeb.Endpoint\n", "{TestWeb.Endpoint, []},\n      Test.Last\n")
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test/application.ex")

      children = children(application)

      assert children =~ ~r/Test.Last,\s+\{TestWeb.Endpoint, \[\]\}\s*\z/
      assert length(String.split(children, "TestWeb.Endpoint")) == 2
    end

    test "appends no endpoint where the children have none" do
      application =
        phx_test_project()
        |> Igniter.update_file("lib/test/application.ex", fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, "TestWeb.Endpoint\n", "Test.Last\n")
          )
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test/application.ex")

      refute children(application) =~ "TestWeb.Endpoint"
    end

    test "starts the engine, the key store and the health endpoints in order, before the endpoint" do
      # Oban's installer puts it where `phx.new`'s list has it, before PubSub, which is followed
      # by the endpoint: the layout that once left every EHOS child behind the endpoint.
      application =
        phx_test_project()
        |> Igniter.Project.Application.add_new_child(
          {Oban, {:code, quote(do: Application.fetch_env!(:test, Oban))}},
          after: [Test.Repo]
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test/application.ex")

      order =
        for child <- [
              "Test.Repo",
              "{Oban, Application.fetch_env!(:test, Oban)}",
              "EhOsContract,",
              "{EhOsContract.Auth, Application.get_env(:test, EhOsContract.Auth, [])}",
              "TestWeb.Health",
              "{Test.SignIn, Application.get_env(:test, EhOsContract.Auth.SignIn, [])}",
              "TestWeb.Endpoint"
            ] do
          {index, _} = :binary.match(application, child)
          index
        end

      assert order == Enum.sort(order)
    end
  end

  describe "signing people in through EHOS" do
    test "starts the client only where it is configured, so development and tests start none" do
      igniter = installed()
      sign_in = content(igniter, "lib/test/sign_in.ex")

      assert sign_in =~ "Application.get_env(:eh_os_contract_auth, :sign_in)"
      assert sign_in =~ "EhOsContract.Auth.SignIn.child_spec(opts)"

      # Unconfigured, as in ehos_app's own tests, the child starts nothing. The package is not a
      # dependency here, so the compiler's warning that its module is missing is kept quiet.
      {[{module, _}], _missing_package} =
        Code.with_diagnostics(fn -> Code.compile_string(sign_in) end)

      assert %{id: EhOsContract.Auth.SignIn, start: {^module, :start_link, [[]]}} =
               module.child_spec([])

      assert module.start_link([]) == :ignore
    end

    test "encrypts the cookie session, which holds the sign-in's state between redirect and callback" do
      endpoint = installed() |> content("lib/test_web/endpoint.ex")

      assert endpoint =~ ~r/@session_options \[[^\]]*encryption_salt: "[A-Za-z0-9+\/]{8}"/
    end

    test "marks the session cookie Secure in production, whatever scheme reaches the endpoint" do
      igniter = installed()

      assert content(igniter, "lib/test_web/endpoint.ex") =~
               "secure: Application.compile_env(:test, [__MODULE__, :secure_session], false)"

      assert get_in(read_config(igniter, :prod), [:test, TestWeb.Endpoint, :secure_session])
      refute get_in(read_config(igniter, :dev), [:test, TestWeb.Endpoint, :secure_session])
    end

    test "replaces a session cookie set never to be Secure, and keeps any other choice" do
      for {theirs, kept?} <- [
            {"false", false},
            {"true", true},
            {~s|System.get_env("X") == "1"|, true}
          ] do
        endpoint =
          phx_test_project()
          |> Igniter.update_file("lib/test_web/endpoint.ex", fn source ->
            Rewrite.Source.update(source, :content, fn content ->
              String.replace(
                content,
                ~s|same_site: "Lax"|,
                ~s|same_site: "Lax",\n    secure: #{theirs}|
              )
            end)
          end)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])
          |> apply_igniter!()
          |> content("lib/test_web/endpoint.ex")

        assert String.contains?(endpoint, "secure: #{theirs}") == kept?, "secure: #{theirs}"

        assert String.contains?(endpoint, "secure: Application.compile_env") != kept?,
               "secure: #{theirs}"
      end
    end

    test "keeps an encryption salt the project has" do
      endpoint =
        phx_test_project()
        |> Igniter.update_file("lib/test_web/endpoint.ex", fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            String.replace(
              content,
              ~s|same_site: "Lax"|,
              ~s|same_site: "Lax",\n    encryption_salt: "theirs00"|
            )
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test_web/endpoint.ex")

      assert endpoint =~ ~s|encryption_salt: "theirs00"|
      assert length(String.split(endpoint, "encryption_salt:")) == 2
    end

    test "serves signing in and out under /auth/ehos, behind the browser's session and CSRF protection" do
      router = installed() |> content("lib/test_web/router.ex")

      assert router =~
               ~r/scope "\/auth" do\s+pipe_through\(:browser\)\s+forward\("\/ehos", EhOsContract.Auth.SignIn.Router\)/

      assert router =~ ~r/pipeline :signed_in do\s+plug\(EhOsContract.Auth.Session\)/
    end

    test "offers a way in and out at the top of the root layout, which every page renders, and tests it" do
      igniter = installed()

      assert content(igniter, "lib/test_web/components/layouts/root.html.heex") =~
               "  <body>\n    <TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\n"

      refute content(igniter, "lib/test_web/controllers/page_html/home.html.heex") =~
               "sign_in_or_out"

      components = content(igniter, "lib/test_web/sign_in_components.ex")
      assert components =~ "defmodule TestWeb.SignInComponents do"
      assert components =~ ~s|href="/auth/ehos/sign-in"|
      assert components =~ ~s|action="/auth/ehos/sign-out" method="post"|
      refute components =~ "fixed"

      test = content(igniter, "test/test_web/sign_in_test.exs")
      assert test =~ "defmodule TestWeb.SignInTest do"
      assert test =~ "use TestWeb.ConnCase"
      assert test =~ "&TestWeb.Layouts.root/1"
      refute test =~ ~s|get(~p"/")|
    end

    test "puts the way in and out on the root layout once, and leaves it where the developer moves it" do
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\n"

      moved =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, call, ""))
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(moved, root) =~ call
      refute content(moved, "lib/test_web/controllers/page_html/home.html.heex") =~ call
    end

    test "moves the way in and out from the home page 0.4 put it on to the root layout" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      components = "lib/test_web/sign_in_components.ex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      # A project as 0.4 left it: the call under the home page's flash group, the control in
      # the corner, and the root layout without it.
      as_04 =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, "    " <> call <> "\n", ""))
        end)
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, flash, flash <> call <> "\n")
          )
        end)
        |> Igniter.update_file(components, fn source ->
          Rewrite.Source.update(source, :content, fn _ -> @sign_in_components_04 end)
        end)
        |> apply_igniter!()

      refute content(as_04, root) =~ call

      upgraded =
        as_04
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(upgraded, root) =~ "  <body>\n    #{call}\n"
      refute content(upgraded, home) =~ call
      assert content(upgraded, home) =~ flash
      # 0.4's component is given the new one's guard and its place in the page's flow; what
      # else it says is left as it was.
      component = content(upgraded, components)
      assert component =~ "session? = Map.has_key?(assigns.conn.private, :plug_session)"

      assert component =~
               "session? and Plug.Conn.get_session(assigns.conn, Session.session_key())"

      assert component =~ ~s|<div :if={@session?} id="sign-in-or-out" class="relative z-10|
      refute component =~ "fixed top-4 right-4"
      assert {:ok, _} = Code.string_to_quoted(component)

      upgraded
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    # A 0.4 project as the installer finds it: the call under the home page's flash group, the
    # root layout without it, and `component` as its sign-in component.
    defp as_04(component) do
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      installed()
      |> Igniter.update_file("lib/test_web/components/layouts/root.html.heex", fn source ->
        Rewrite.Source.update(source, :content, &String.replace(&1, "    " <> call <> "\n", ""))
      end)
      |> Igniter.update_file("lib/test_web/controllers/page_html/home.html.heex", fn source ->
        Rewrite.Source.update(source, :content, &String.replace(&1, flash, flash <> call <> "\n"))
      end)
      |> Igniter.update_file("lib/test_web/sign_in_components.ex", fn source ->
        Rewrite.Source.update(source, :content, fn _ -> component end)
      end)
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
    end

    test "leaves a 0.4 component the developer guarded their own way out of the corner alone" do
      own =
        String.replace(
          @sign_in_components_04,
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Map.has_key?(assigns.conn.private, :plug_session) and\n" <>
            "          Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil"
        )

      igniter = as_04(own)
      component = igniter |> apply_igniter!() |> content("lib/test_web/sign_in_components.ex")

      assert component =~ ~s|<div id="sign-in-or-out" class="relative z-10|
      refute component =~ "@session?"
      refute Enum.any?(igniter.notices, &(&1 =~ "guard it as a new project's"))
    end

    test "takes 0.4's line off the home page when the developer has put the call on the root too" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      upgraded =
        installed()
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, flash, flash <> call <> "\n")
          )
        end)
        |> Igniter.update_file("lib/test_web/sign_in_components.ex", fn source ->
          Rewrite.Source.update(source, :content, fn _ -> @sign_in_components_04 end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert [_once] = Regex.scan(~r/#{Regex.escape(call)}/, content(upgraded, root))
      refute content(upgraded, home) =~ call
      assert content(upgraded, home) =~ flash

      # 0.4's component, now on every page, gets the guard here too.
      component = content(upgraded, "lib/test_web/sign_in_components.ex")
      assert component =~ "session? = Map.has_key?(assigns.conn.private, :plug_session)"
      assert component =~ ~s|<div :if={@session?} id="sign-in-or-out" class="relative z-10|

      upgraded
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "keeps 0.4's line on the home page when the root holds the call in a comment alone" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      for commented <- ["<%!-- #{call} --%>", "<!-- #{call} -->", "<%# #{call} %>"] do
        igniter =
          installed()
          |> Igniter.update_file(root, fn source ->
            Rewrite.Source.update(source, :content, &String.replace(&1, call, commented))
          end)
          |> Igniter.update_file(home, fn source ->
            Rewrite.Source.update(
              source,
              :content,
              &String.replace(&1, flash, flash <> call <> "\n")
            )
          end)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])

        assert Enum.any?(igniter.notices, &(&1 =~ "commented out")), commented

        applied = apply_igniter!(igniter)
        assert [_once] = Regex.scan(~r/#{Regex.escape(call)}/, content(applied, home)), commented
        assert content(applied, root) =~ commented, commented
        assert [_once] = Regex.scan(~r/#{Regex.escape(call)}/, content(applied, root))
      end
    end

    test "does not take another function's session? for the one 0.4's component renders" do
      elsewhere =
        @sign_in_components_04
        |> String.replace(
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Plug.Conn.get_session(assigns.conn, :ehos) != nil"
        )
        |> String.replace(
          ~r/\nend\s*\z/,
          "\n\n  def other(assigns), do: assigns |> assign(:session?, true)\nend\n"
        )

      refute elsewhere =~ "Session.session_key()) != nil"
      assert elsewhere =~ "def other(assigns)"

      component =
        elsewhere |> as_04() |> apply_igniter!() |> content("lib/test_web/sign_in_components.ex")

      assert component =~ ~s|<div id="sign-in-or-out" class="relative z-10|
      refute component =~ ":if={@session?}"
    end

    test "does not take :session? given as a value for an assign of it" do
      as_value =
        String.replace(
          @sign_in_components_04,
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Plug.Conn.get_session(assigns.conn, :ehos) != nil) |> assign(:mode, :session?"
        )

      refute as_value == @sign_in_components_04

      component =
        as_value |> as_04() |> apply_igniter!() |> content("lib/test_web/sign_in_components.ex")

      refute component =~ ":if={@session?}"
    end

    test "conditions 0.4's div on the session? its own function assigns, in a pipe" do
      own =
        String.replace(
          @sign_in_components_04,
          ~r/assigns =\s*assign\(\s*assigns,\s*:signed_in\?,[^)]*\)\) != nil\s*\)/,
          """
          session? = Map.has_key?(assigns.conn.private, :plug_session)

              assigns =
                assigns
                |> assign(:session?, session?)
                |> assign(:signed_in?, session? and Plug.Conn.get_session(assigns.conn, :ehos) != nil)\
          """
        )

      refute own == @sign_in_components_04

      component =
        own |> as_04() |> apply_igniter!() |> content("lib/test_web/sign_in_components.ex")

      assert component =~ ~s|<div :if={@session?} id="sign-in-or-out"|
    end

    test "guards a CRLF 0.4 component in its own line endings" do
      component =
        @sign_in_components_04
        |> String.replace("\n", "\r\n")
        |> as_04()
        |> apply_igniter!()
        |> content("lib/test_web/sign_in_components.ex")

      assert component =~ ":plug_session"
      assert component =~ ":if={@session?}"
      refute component =~ ~r/[^\r]\n/
    end

    test "says what to guard in a 0.4 component the developer changed, when it moves it" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      components = "lib/test_web/sign_in_components.ex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      changed =
        String.replace(
          @sign_in_components_04,
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Plug.Conn.get_session(assigns.conn, :ehos) != nil"
        )

      igniter =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, "    " <> call <> "\n", ""))
        end)
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, flash, flash <> call <> "\n")
          )
        end)
        |> Igniter.update_file(components, fn source ->
          Rewrite.Source.update(source, :content, fn _ -> changed end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "guard it as a new project's"))

      component = igniter |> apply_igniter!() |> content(components)
      assert component =~ ":ehos) != nil"
      # Out of the corner, but reading no `@session?` that nothing assigns.
      assert component =~ ~s|<div id="sign-in-or-out" class="relative z-10|
      refute component =~ "@session?"
    end

    test "moves the line 0.4 wrote from a CRLF home page too" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />"

      upgraded =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, "    " <> call <> "\n", ""))
        end)
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            content
            |> String.replace(flash <> "\n", flash <> "\n" <> call <> "\n")
            |> String.replace("\n", "\r\n")
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(upgraded, root) =~ call
      refute content(upgraded, home) =~ call
      assert content(upgraded, home) =~ flash <> "\r\n"
    end

    test "says the way in and out is still on 0.4's home page when the root layout is not Phoenix's" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      igniter =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, fn _ -> "<html>{@inner_content}</html>\n" end)
        end)
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, flash, flash <> call <> "\n")
          )
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "is still on #{home}"))
      assert igniter |> apply_igniter!() |> content(home) =~ call
    end

    test "says where the way in and out goes when the root layout is not Phoenix's" do
      igniter =
        phx_test_project()
        |> Igniter.rm("lib/test_web/components/layouts/root.html.heex")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "at the top of the root layout's <body>"))
    end

    test "wires no pages into a project that serves none" do
      igniter =
        phx_test_project()
        |> Igniter.update_elixir_file("lib/test_web/router.ex", fn zipper ->
          with {:ok, pipeline} <-
                 Igniter.Code.Function.move_to_function_call(zipper, :pipeline, 2, fn call ->
                   Igniter.Code.Function.argument_equals?(call, 0, :browser)
                 end) do
            {:ok, Sourceror.Zipper.remove(pipeline)}
          end
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      refute content(igniter, "lib/test_web/router.ex") =~ "EhOsContract.Auth.SignIn.Router"
      refute Igniter.exists?(igniter, "lib/test_web/sign_in_components.ex")
      assert Enum.any?(igniter.warnings, &(&1 =~ "`:browser` pipeline"))
    end
  end

  describe "the home page and the access page" do
    @home "lib/test_web/controllers/page_html/home.html.heex"
    @page_test "test/test_web/controllers/page_controller_test.exs"
    @root "lib/test_web/components/layouts/root.html.heex"
    # Where Igniter puts the modules in its test project, which has its Phoenix extension; a
    # project `igniter.new` makes without one has them in `lib/<app>_web/` itself.
    @access_files [
      "lib/test_web/controllers/access_controller.ex",
      "lib/test_web/controllers/access_html.ex",
      "test/test_web/controllers/access_controller_test.exs"
    ]

    defp access_scopes(router),
      do:
        Regex.scan(
          ~r/scope "\/access", TestWeb do\s+pipe_through\(\[:browser, :signed_in\]\)\s+get\("\/", AccessController, :show\)\s+end/,
          router
        )

    defp edit(igniter, path, fun),
      do: Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, fun))

    test "replaces Phoenix's welcome page with the application's own, which leads to the access page" do
      home = installed() |> content(@home)

      refute home =~ "Peace of mind from prototype to production"
      assert home =~ ~s|<h1 class="eh-section-title">Test</h1>|
      assert home =~ ~s|known there as <span class="eh-record">test</span>|
      assert home =~ ~s|<.button id="home-access" href={~p"/access"} variant="primary">|
      # The way in and out stays where it is, at the top of the root layout, and only there.
      refute home =~ "sign_in_or_out"
      refute home =~ "/auth/ehos"
    end

    test "writes the access page behind :signed_in, in a scope of its own, with its test" do
      igniter = installed(["--example"])
      router = content(igniter, "lib/test_web/router.ex")

      assert [_one] = access_scopes(router)
      # The design system's page, appended to the scope for "/" later in the run, stays public.
      assert router =~
               ~r/pipe_through\(:browser\)\s+get\("\/", PageController, :home\)\s+live\("\/design-system", DesignSystemLive\)/

      controller = content(igniter, "lib/test_web/controllers/access_controller.ex")
      assert controller =~ "defmodule TestWeb.AccessController do"
      assert controller =~ "Session.actor(conn)"
      assert controller =~ ~s|put_resp_header("cache-control", "no-store")|

      # The page is inside the module, since no template file would follow it to where it is.
      html = content(igniter, "lib/test_web/controllers/access_html.ex")
      assert html =~ "def show(assigns) do"
      assert html =~ "What EHOS lets you do in Test"
      refute html =~ "embed_templates"

      test = content(igniter, "test/test_web/controllers/access_controller_test.exs")
      assert test =~ "defmodule TestWeb.AccessControllerTest do"
      assert test =~ ~s|"/auth/ehos/sign-in?return_to=%2Faccess"|
      assert test =~ ~s|"test.example"|
    end

    test "replaces Phoenix's test of its welcome page with one of the application's page" do
      test = installed() |> content(@page_test)

      assert test =~ "defmodule TestWeb.PageControllerTest do"
      refute test =~ "Peace of mind"
      assert test =~ ~s|a#home-access[href="/access"]|
    end

    test "names the application alone in the tab's title" do
      root = installed() |> content(@root)

      assert root =~ ~s|<.live_title default="Test" phx-no-format>|
      refute root =~ "Phoenix Framework"
    end

    test "keeps a title suffix of the application's own" do
      root =
        phx_test_project()
        |> edit(@root, &String.replace(&1, " · Phoenix Framework", " · Shop"))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content(@root)

      assert root =~ ~s|suffix=" · Shop"|
    end

    test "changes nothing on a second run, and brings back no access page the developer removed" do
      igniter = installed()

      igniter
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()

      removed =
        igniter
        |> then(
          &Enum.reduce(@access_files, &1, fn path, igniter -> Igniter.rm(igniter, path) end)
        )
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(&1, ~r/\n  scope "\/access".*?\n  end\n/s, "\n")
        )
        |> apply_igniter!()

      upgraded = removed |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      for path <- @access_files, do: refute(Igniter.exists?(upgraded, path), path)
      assert access_scopes(content(upgraded, "lib/test_web/router.ex")) == []
    end

    test "gives a project from an earlier version whose home page is still Phoenix's the new pages" do
      # Every earlier version wrote ehos.yaml; nothing else of theirs decides this.
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(igniter, @home) =~ "Peace of mind"
      assert [_one] = access_scopes(content(igniter, "lib/test_web/router.ex"))
    end

    test "leaves a home page the developer has changed, and adds no access page" do
      igniter =
        phx_test_project()
        |> edit(@home, &String.replace(&1, "Peace of mind", "Peace of mind, always,"))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(igniter, @home) =~ "Peace of mind, always,"
      assert content(igniter, @page_test) =~ "Peace of mind from prototype to production"
      for path <- @access_files, do: refute(Igniter.exists?(igniter, path), path)
      assert access_scopes(content(igniter, "lib/test_web/router.ex")) == []

      # The sections the installer keeps say nothing of a page the project does not have.
      for doc <- ["DEVELOPMENT.md", "ARCHITECTURE.md", "TESTING.md", "lib/test_web/AGENTS.md"],
          do: refute(content(igniter, doc) =~ "/access", doc)
    end

    test "says in the sections it keeps what the two pages are" do
      igniter = installed()

      assert content(igniter, "DEVELOPMENT.md") =~ "`/` is the application's home page"
      assert content(igniter, "ARCHITECTURE.md") =~ "pages that need a person, /access:"
      assert content(igniter, "TESTING.md") =~ "`TestWeb.AccessControllerTest`"

      assert content(igniter, "lib/test_web/AGENTS.md") =~
               "`AccessController`, which the template routed at `/access`"
    end

    test "keeps a test of the home page the developer has changed, and says what it looks for" do
      igniter =
        phx_test_project()
        |> edit(@page_test, &String.replace(&1, ~s|test "GET /"|, ~s|test "the home page"|))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "still looks for Phoenix's\nwelcome page"))
      assert igniter |> apply_igniter!() |> content(@page_test) =~ ~s|test "the home page"|
    end

    test "keeps a route the developer gave the access page" do
      router =
        installed()
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(
            &1,
            ~s|get("/", AccessController, :show)|,
            ~s|get("/me", AccessController, :show)|
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test_web/router.ex")

      assert [_one] = Regex.scan(~r/AccessController/, router)
    end

    # The new home page links to `~p"/access"`, which has to be the access page for the project
    # to compile with warnings as errors, and to lead anywhere.
    test "keeps Phoenix's page where the router serves /access already, read as code" do
      with_route = fn route ->
        phx_test_project()
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(
            &1,
            ~s|    get("/", PageController, :home)\n|,
            ~s|    get("/", PageController, :home)\n#{route}\n|
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
      end

      # A route split over lines counts; one at another path, or in a comment, does not.
      taken = with_route.(~s|    get "/access",\n      ReportController,\n      :index|)
      assert Enum.any?(taken.notices, &(&1 =~ "or a route at /access"))
      applied = apply_igniter!(taken)
      assert content(applied, @home) =~ "Peace of mind"
      assert access_scopes(content(applied, "lib/test_web/router.ex")) == []

      for route <- [~s|    get "/me", ReportController, :index|, ~s|    # get "/access", X, :y|] do
        applied = route |> with_route.() |> apply_igniter!()
        refute content(applied, @home) =~ "Peace of mind", route
        assert [_one] = access_scopes(content(applied, "lib/test_web/router.ex")), route
      end
    end

    # A project 0.5 to 0.10 made and nobody touched: the sign-in pipeline, the way in and out on
    # the root layout and Phoenix's welcome page, but no access page.
    test "gives a project an earlier version made, on Phoenix's page, both pages, once" do
      phoenix_home = phx_test_project() |> content(@home)
      phoenix_test = phx_test_project() |> content(@page_test)

      earlier =
        installed()
        |> then(
          &Enum.reduce(@access_files, &1, fn path, igniter -> Igniter.rm(igniter, path) end)
        )
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(&1, ~r/\n  scope "\/access".*?\n  end\n/s, "\n")
        )
        |> edit(@home, fn _ -> phoenix_home end)
        |> edit(@page_test, fn _ -> phoenix_test end)
        |> edit(
          @root,
          &String.replace(
            &1,
            ~s|default="Test"|,
            ~s|default="Test" suffix=" · Phoenix Framework"|
          )
        )
        |> apply_igniter!()

      assert content(earlier, "lib/test_web/router.ex") =~ "pipeline :signed_in"
      assert content(earlier, @root) =~ "sign_in_or_out"

      upgraded = earlier |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      refute content(upgraded, @home) =~ "Peace of mind"
      refute content(upgraded, @page_test) =~ "Peace of mind"
      refute content(upgraded, @root) =~ "Phoenix Framework"
      for path <- @access_files, do: assert(Igniter.exists?(upgraded, path), path)
      assert [_one] = access_scopes(content(upgraded, "lib/test_web/router.ex"))

      upgraded |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    test "replaces a CRLF copy of Phoenix's page, in its own line endings" do
      home =
        phx_test_project()
        |> edit(@home, &String.replace(&1, "\n", "\r\n"))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content(@home)

      refute home =~ "Peace of mind"
      assert home =~ ~s|id="home-access"|
      refute home =~ ~r/[^\r]\n/
    end

    test "says so when the home page has Phoenix's tagline but is not a page it knows" do
      igniter =
        phx_test_project()
        |> edit(@home, &(&1 <> "<p>Ours.</p>\n"))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "is not the Phoenix welcome page"))
      assert igniter |> apply_igniter!() |> content(@home) =~ "<p>Ours.</p>"
    end

    test "keeps Phoenix's page where the project has an AccessController of its own" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("lib/test_web/somewhere/access.ex", """
        defmodule TestWeb.AccessController do
        end
        """)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "already has TestWeb.AccessController")
             )

      applied = apply_igniter!(igniter)
      assert content(applied, @home) =~ "Peace of mind"
      # Igniter keeps the developer's module where it puts modules; it is still theirs.
      for path <- Enum.drop(@access_files, 1), do: refute(Igniter.exists?(applied, path), path)
      refute content(applied, hd(@access_files)) =~ "Session.actor"
    end

    test "routes the page where another module of the same last name is routed" do
      router =
        phx_test_project()
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(
            &1,
            ~s|    get("/", PageController, :home)\n|,
            ~s|    get("/", PageController, :home)\n    get "/admin/access", Admin.AccessController, :show\n|
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test_web/router.ex")

      assert [_one] = access_scopes(router)
    end

    test "leaves Phoenix's welcome page, with a notice, where the router has no :signed_in pipeline" do
      # The session's plug is in a pipeline of the developer's name, so none is added.
      igniter =
        phx_test_project()
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(
            &1,
            "  pipeline :api do",
            "  pipeline :person do\n    plug(EhOsContract.Auth.Session)\n  end\n\n  pipeline :api do"
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "still Phoenix's welcome page"))
      assert igniter |> apply_igniter!() |> content(@home) =~ "Peace of mind"
    end
  end

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

  describe "ehos.yaml" do
    test "is valid against the schema EHOS defines it by, and is D-51's example" do
      igniter = installed()

      assert {:ok, _} = JSV.validate(ehos_yaml(igniter), schema(igniter))

      assert ehos_yaml(igniter) == %{
               "schema" => "ehos.yaml/v7",
               "needs" => %{
                 "database" => %{
                   "engine" => "postgres",
                   "version" => ">= 16",
                   "migrate" => ["/app/bin/migrate"],
                   # The release itself, so it needs no overlay of its own (eh-os D-98).
                   "seed" => ["/app/bin/test", "eval", "Test.Seed.run()"]
                 }
               },
               "serves" => [%{"name" => "web", "port" => 4000, "public" => true}],
               "sign_in" => %{},
               "health" => %{"port" => 4001, "ready" => "/health/ready", "live" => "/health/live"}
             }
    end

    # A release says it produces `EhosApp.ehos_yaml_version/0` (eh-os D-91): EHOS judges from it
    # whether it accepts what this version writes, so it has to be what the installer writes.
    test "is the version a release says this ehos_app produces, as is its schema" do
      assert ehos_yaml(installed())["schema"] == EhosApp.ehos_yaml_version()
      assert schema_title() == EhosApp.ehos_yaml_version()
    end

    # An `ehos.yaml/v3` an earlier version wrote, with a key of the developer's own, moves to v7:
    # the seed beside `migrate:`, the schema comment's version, and nothing else.
    test "moves an ehos.yaml/v3 to v7, adding the seed beside migrate, and keeps the rest" do
      v3 = """
      # yaml-language-server: $schema=#{Install.ehos_yaml_schema("v3")}
      schema: ehos.yaml/v3
      needs:
        database:
          engine: postgres
          version: ">= 17"
          migrate: [/app/bin/migrate]
        people: read
      serves:
        - name: web
          port: 4000
          public: true
      sign_in: {}
      health:
        port: 4001
        ready: /health/ready
        live: /health/live
      """

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      moved = igniter |> apply_igniter!() |> content("ehos.yaml")

      assert moved ==
               v3
               |> String.replace("ehos.yaml/v3", "ehos.yaml/v7")
               |> String.replace("v3.json", "v7.json")
               |> String.replace(
                 "    migrate: [/app/bin/migrate]\n",
                 "    migrate: [/app/bin/migrate]\n" <>
                   ~s|    seed: [/app/bin/test, eval, "Test.Seed.run()"]\n|
               )

      assert {:ok, _} = JSV.validate(YamlElixir.read_from_string!(moved), schema(igniter))
      assert Enum.any?(igniter.notices, &(&1 =~ "ehos.yaml is ehos.yaml/v7 now"))

      # The module the seed names is written with it, and a second run changes nothing.
      applied = apply_igniter!(igniter)
      assert content(applied, "lib/test/seed.ex") =~ "defmodule Test.Seed do"

      applied
      |> Igniter.compose_task("ehos_app.install", ["--yes"])
      |> assert_unchanged()
    end

    # A v4, v5 or v6 an earlier version wrote, or the developer moved to, keeps every key it has,
    # egress and mail included, and only its version and its schema comment's change (eh-os
    # D-143): each later version only added keys. No seed is added to one that names none.
    test "moves an ehos.yaml/v4, v5 or v6 to v7, changing nothing but its version" do
      for {from, needs} <- [
            {"v4", ""},
            {"v5", "  egress:\n    - host: api.example.com\n"},
            {"v6", "  mail:\n    level: internal\n    reply_domains: [reply.example.org]\n"}
          ] do
        older = """
        # yaml-language-server: $schema=#{Install.ehos_yaml_schema(from)}
        # Our own note, which keeps its words: $schema=elsewhere/#{from}.json
        schema: ehos.yaml/#{from}
        needs:
          database:
            engine: postgres
            migrate: [/app/bin/migrate]
        #{needs}serves:
          - name: web
            port: 4000
            public: true
        sign_in: {}
        health:
          port: 4001
          ready: /health/ready
          live: /health/live
        """

        igniter =
          phx_test_project()
          |> Igniter.create_new_file("ehos.yaml", older)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", ["--yes"])

        applied = apply_igniter!(igniter)
        moved = content(applied, "ehos.yaml")

        assert moved ==
                 older
                 |> String.replace("schema: ehos.yaml/#{from}\n", "schema: ehos.yaml/v7\n")
                 |> String.replace(Install.ehos_yaml_schema(from), Install.ehos_yaml_schema("v7")),
               from

        assert {:ok, _} = JSV.validate(YamlElixir.read_from_string!(moved), schema(igniter))

        assert Enum.any?(
                 igniter.notices,
                 &(&1 =~
                     "ehos.yaml is ehos.yaml/v7 now, which EHOS 0.21 and later deploy; nothing else")
               )

        applied
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> assert_unchanged()
      end
    end

    # A `schema:` line with a comment after it, CRLF, and an editor comment pointing at a schema
    # of another name, which is the developer's and keeps its version.
    test "moves a v6 whose schema line carries a comment, with CRLF, and keeps another schema's comment" do
      v6 =
        "# yaml-language-server: $schema=https://example.org/schemas/mine-v6.json\r\n" <>
          "schema: ehos.yaml/v6 # mail since October\r\n" <>
          "sign_in: {}\r\nneeds:\r\n  database:\r\n    migrate: [/app/bin/migrate]\r\n"

      moved =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v6)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()
        |> content("ehos.yaml")

      assert moved == String.replace(v6, "schema: ehos.yaml/v6 #", "schema: ehos.yaml/v7 #")
    end

    # A v7 is what this version writes: a run says nothing of it.
    test "leaves an ehos.yaml/v7 as it is, and says nothing of it" do
      project = installed() |> apply_igniter!()
      igniter = Igniter.compose_task(project, "ehos_app.install", ["--yes"])

      assert content(apply_igniter!(igniter), "ehos.yaml") == content(project, "ehos.yaml")

      refute Enum.any?(igniter.notices ++ igniter.warnings, &(&1 =~ "ehos.yaml is ehos.yaml/v7"))
    end

    # eh_os_contract_auth on a commit the project chose may carry no v7 schema, and its manifest
    # task would then refuse the file: nothing is moved, and the developer is told.
    test "keeps an ehos.yaml/v6 while eh_os_contract_auth is on a commit it does not know" do
      dep =
        {:eh_os_contract_auth, "~> 0.8.0",
         github: "EmpoweredHouse/eh-os-contract",
         sparse: "packages/eh_os_contract_auth",
         ref: "ffffffffffffffffffffffffffffffffffffffff"}

      v6 =
        "schema: ehos.yaml/v6\nsign_in: {}\nneeds:\n  database:\n    migrate: [/app/bin/migrate]\n"

      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(dep, yes?: true)
        |> Igniter.create_new_file("ehos.yaml", v6)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert igniter |> apply_igniter!() |> content("ehos.yaml") == v6
      assert Enum.any?(igniter.warnings, &(&1 =~ "ehos.yaml stays ehos.yaml/v6"))
      assert Enum.any?(igniter.warnings, &(&1 =~ "make it `schema: ehos.yaml/v7` and point"))

      # A v3 still gets v4 and its seed, which every eh_os_contract_auth since the seed reads.
      v3 = String.replace(v6, "ehos.yaml/v6", "ehos.yaml/v3")

      applied =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(dep, yes?: true)
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()

      assert content(applied, "ehos.yaml") ==
               String.replace(v6, "ehos.yaml/v6", "ehos.yaml/v4") <>
                 ~s|    seed: [/app/bin/test, eval, "Test.Seed.run()"]\n|

      assert content(applied, "lib/test/seed.ex") =~ "defmodule Test.Seed do"
    end

    # The template names no compute, and says how to ask for it (eh-os D-143).
    test "names no compute, and its comment says how to ask for it" do
      igniter = installed()

      refute Map.has_key?(ehos_yaml(igniter)["needs"], "compute")
      assert content(igniter, "ehos.yaml") =~ "  # compute:\n  #   cpu: 250m\n  #   memory: 1Gi\n"
    end

    test "seeds an ehos.yaml/v3 whose migrate is its last line, with no newline after it" do
      v3 =
        "schema: ehos.yaml/v3\nsign_in: {}\nneeds:\n  database:\n    migrate: [/app/bin/migrate]"

      moved =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()
        |> content("ehos.yaml")

      assert moved ==
               String.replace(v3, "ehos.yaml/v3", "ehos.yaml/v7") <>
                 ~s|\n    seed: [/app/bin/test, eval, "Test.Seed.run()"]|
    end

    test "keeps the seed an ehos.yaml/v3 names when it moves it to v7" do
      v3 = """
      schema: ehos.yaml/v3
      needs:
        database:
          engine: postgres
          migrate: [/app/bin/migrate]
          seed: [/app/bin/my_seed]
      serves:
        - name: web
          port: 4000
      sign_in: {}
      """

      moved =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()
        |> content("ehos.yaml")

      assert moved == String.replace(v3, "ehos.yaml/v3", "ehos.yaml/v7")
    end

    test "writes the seed EHOS runs, which runs priv/repo/seeds.exs with the project's repo started" do
      seed = installed() |> content("lib/test/seed.ex")

      assert seed =~ "defmodule Test.Seed do"
      assert seed =~ "Ecto.Migrator.with_repo(Test.Repo, fn _repo ->"
      assert seed =~ ~s|Application.app_dir(@app, "priv/repo/seeds.exs")|
      assert seed =~ "EHOS_SEED_PROFILE"
      assert seed =~ "no real data, no\n    credentials and no secrets"
    end

    # Only a `migrate:` that is one flow sequence on its line, the form every version wrote, gets
    # the seed beside it: another form is said, and left valid YAML.
    test "moves an ehos.yaml/v3 whose migrate is a block sequence to v7, and says how to add the seed" do
      v3 = """
      schema: ehos.yaml/v3
      needs:
        database:
          engine: postgres
          migrate:
            - /app/bin/migrate
      serves:
        - name: web
          port: 4000
      sign_in: {}
      """

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      applied = apply_igniter!(igniter)

      assert content(applied, "ehos.yaml") == String.replace(v3, "ehos.yaml/v3", "ehos.yaml/v7")
      assert Enum.any?(igniter.warnings, &(&1 =~ "names no seed, since its `migrate:`"))
      # Nothing would run it, so no module is written for it.
      refute Igniter.exists?(applied, "lib/test/seed.ex")
    end

    # A module the developer removed from a project made with one is theirs to keep removed.
    test "brings back no seed module the developer removed" do
      project = installed()

      project
      |> Igniter.rm("lib/test/seed.ex")
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", ["--yes"])
      |> apply_igniter!()
      |> then(&refute(Igniter.exists?(&1, "lib/test/seed.ex")))
    end

    test "points editors at the schema eh_os_contract_auth carries, and copies none" do
      igniter = installed()

      assert Install.ehos_yaml_schema("v3") ==
               "deps/eh_os_contract_auth/packages/eh_os_contract_auth/priv/schemas/ehos.yaml/v3.json"

      assert content(igniter, "ehos.yaml") =~
               "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v7")}\n"

      refute Enum.any?(Map.keys(igniter.assigns.test_files), &String.starts_with?(&1, ".ehos/"))
    end

    # 0.2.0 to 0.8.1 copied EHOS's schema into .ehos/, beside the version the file was in.
    test "removes a copy of the schema an earlier version wrote, and points the comment past it" do
      v2 = File.read!("test/fixtures/schemas/ehos.yaml.v2.json")

      ehos_yaml =
        "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", ehos_yaml)
        |> apply_igniter!()
        |> with_file(".ehos/ehos.yaml.v2.json", v2)
        |> Igniter.compose_task("ehos_app.install", [])

      assert ".ehos/ehos.yaml.v2.json" in igniter.rms

      assert content(igniter, "ehos.yaml") ==
               "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\n" <>
                 "schema: ehos.yaml/v2\n"

      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "keeps a copy of the schema that was changed, and the comment that names it" do
      ehos_yaml =
        "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", ehos_yaml)
        |> apply_igniter!()
        |> with_file(".ehos/ehos.yaml.v2.json", "{}\n")
        |> Igniter.compose_task("ehos_app.install", [])

      refute ".ehos/ehos.yaml.v2.json" in igniter.rms
      assert content(igniter, "ehos.yaml") == ehos_yaml
    end

    # The comment on top of every ehos.yaml 0.2.0 to 0.8.1 wrote.
    @ehos_yaml_header_08 """
    # What this application needs from EHOS in order to run, and nothing about how EHOS provides
    # it. EHOS defines this format: the schema beside it, in .ehos/, is a copy of the one it
    # publishes, and https://github.com/empoweredhouse/eh-os/blob/main/docs/ehos-yaml.md explains
    # every field. The application's name is its contract domain's, so it is not written here.
    """

    test "points a CRLF ehos.yaml past the copy, and gives it the header this version writes" do
      v2 = File.read!("test/fixtures/schemas/ehos.yaml.v2.json")

      [header, _] =
        installed() |> content("ehos.yaml") |> String.split("# yaml-language-server:", parts: 2)

      crlf = &String.replace(&1, "\n", "\r\n")
      body = "schema: ehos.yaml/v2\n# the developer's own comment, in .ehos/ too\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "ehos.yaml",
          crlf.(
            @ehos_yaml_header_08 <>
              "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\n" <> body
          )
        )
        |> apply_igniter!()
        |> with_file(".ehos/ehos.yaml.v2.json", v2)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") ==
               crlf.(
                 header <>
                   "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\n" <> body
               )

      refute Enum.any?(igniter.warnings, &(&1 =~ "ehos.yaml names"))

      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "points a CRLF ehos.yaml past the copy 0.9 removed and left it naming" do
      [header, _] =
        installed() |> content("ehos.yaml") |> String.split("# yaml-language-server:", parts: 2)

      crlf = &String.replace(&1, "\n", "\r\n")

      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "ehos.yaml",
          crlf.(
            @ehos_yaml_header_08 <>
              "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") ==
               crlf.(
                 header <>
                   "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\n" <>
                   "schema: ehos.yaml/v2\n"
               )
    end

    test "gives an ehos.yaml 0.9 left without a copy the header this version writes" do
      [header, _] =
        installed() |> content("ehos.yaml") |> String.split("# yaml-language-server:", parts: 2)

      body =
        "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", @ehos_yaml_header_08 <> body)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") == header <> body
    end

    test "keeps saying so while ehos.yaml names a copy already gone" do
      ehos_yaml =
        "# yaml-language-server: $schema=./.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", ehos_yaml)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") == ehos_yaml
      assert_has_warning(igniter, &(&1 =~ "ehos.yaml names .ehos/ehos.yaml.v2.json"))
    end

    test "says so when ehos.yaml still names the copy it removed" do
      v2 = File.read!("test/fixtures/schemas/ehos.yaml.v2.json")

      ehos_yaml =
        "# yaml-language-server: $schema=./.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", ehos_yaml)
        |> apply_igniter!()
        |> with_file(".ehos/ehos.yaml.v2.json", v2)
        |> Igniter.compose_task("ehos_app.install", [])

      assert ".ehos/ehos.yaml.v2.json" in igniter.rms
      assert content(igniter, "ehos.yaml") == ehos_yaml

      assert_has_warning(
        igniter,
        &(&1 =~ "ehos.yaml names .ehos/ehos.yaml.v2.json" and
            &1 =~ Install.ehos_yaml_schema("v2"))
      )
    end

    test "leaves a file without sign_in alone, and says what signing people in needs of it" do
      v1 = "schema: ehos.yaml/v1\nhealth:\n  port: 4001\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v1)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") == v1
      assert Enum.any?(igniter.warnings, &(&1 =~ "add `sign_in: {}`"))
      refute Enum.any?(installed_with_warnings(), &(&1 =~ "sign_in"))
    end

    test "never serves the health port" do
      %{"serves" => serves, "health" => %{"port" => health}} = ehos_yaml(installed())
      refute health in Enum.map(serves, & &1["port"])
    end
  end

  describe "the health endpoints" do
    test "are a plug of their own, tested" do
      igniter = installed()

      assert content(igniter, "lib/test_web/health.ex") =~ "defmodule TestWeb.Health do"
      assert content(igniter, "lib/test_web/health.ex") =~ "EhOsContract.Auth.ready?()"

      assert content(igniter, "test/test_web/health_test.exs") =~
               "defmodule TestWeb.HealthTest do"
    end
  end

  # ehos-tools#504: the tools docs/elixir.md's rules assume.
  describe "the test tools and the lint" do
    defp made_before do
      phx_test_project()
      |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
    end

    test "adds Hammox, ExMachina and Credo, and runs Credo in mix precommit" do
      mix = installed() |> content("mix.exs")

      assert mix =~ ~s({:hammox, "~> 1.0", only: :test})
      assert mix =~ ~s({:ex_machina, "~> 2.8", only: :test})
      assert mix =~ ~s({:credo, "~> 1.7", only: [:dev, :test], runtime: false})
      assert mix =~ ~r/precommit: \[[^\]]*"credo"/s
    end

    test "has the cases set up the mocks for every test and import the factories" do
      igniter = installed()

      for path <- ["test/support/data_case.ex", "test/support/conn_case.ex"] do
        case_template = content(igniter, path)
        assert case_template =~ "setup {Test.Mocks, :setup_mocks}", path
        assert case_template =~ "import Test.Factories", path
      end

      mocks = content(igniter, "test/support/mocks.ex")
      assert mocks =~ "Hammox.defmock(Test.ClockMock, for: Test.Clock)"
      assert mocks =~ "Hammox.set_mox_from_context(tags)"
      assert mocks =~ "Hammox.stub_with(Test.ClockMock, Test.ClockImpl)"

      assert content(igniter, "test/support/factories.ex") =~
               "use ExMachina.Ecto, repo: Test.Repo"
    end

    test "gives a new project the clock as its first way out, mocked in tests" do
      igniter = installed()

      assert content(igniter, "lib/test/clock.ex") =~
               "@impl_module Application.compile_env!(:test, [__MODULE__, :impl])"

      assert content(igniter, "config/config.exs") =~
               "config :test, Test.Clock, impl: Test.ClockImpl"

      assert content(igniter, "config/test.exs") =~
               "config :test, Test.Clock, impl: Test.ClockMock"

      assert content(igniter, "test/test/clock_test.exs") =~ "use Hammox.Protect"

      # The docs show the shape on it, where the project has it.
      assert content(igniter, "docs/elixir.md") =~ "`lib/test/clock.ex`\n  is one, the clock."
      assert content(igniter, "TESTING.md") =~ "`Test.ClockMock` is one"
      refute made_before() |> apply_igniter!() |> content("docs/elixir.md") =~ "clock.ex"
    end

    test "holds a new project to its rules with Credo and the conventions test" do
      igniter = installed()

      assert Map.has_key?(igniter.assigns.test_files, ".credo.exs")
      assert content(igniter, "test/conventions_test.exs") =~ "@own_tables []"
    end

    test "asks nothing new of the code of a project made before, and says how to have it" do
      igniter = made_before() |> apply_igniter!()

      refute content(igniter, "mix.exs") =~ ":credo"
      refute Igniter.exists?(igniter, "test/conventions_test.exs")
      refute Igniter.exists?(igniter, "lib/test/clock.ex")
      refute content(igniter, "test/support/mocks.ex") =~ "ClockMock"
      assert content(igniter, "mix.exs") =~ ":hammox"
      assert content(igniter, "test/support/data_case.ex") =~ "setup {Test.Mocks, :setup_mocks}"

      assert Enum.any?(
               made_before().notices,
               &(&1 =~ "An upgrade adds neither to a project made before")
             )
    end

    test "leaves a project with a mocks module of its own to its way" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "test/support/mocks.ex",
          "Mox.defmock(Test.Mock, for: Test.B)\n"
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(igniter, "mix.exs") =~ ":hammox"
      # No `"credo"` in precommit without the dependency that runs it.
      refute content(igniter, "mix.exs") =~ ~s("credo")
      refute content(igniter, "test/support/data_case.ex") =~ "setup_mocks"
      assert content(igniter, "test/support/mocks.ex") == "Mox.defmock(Test.Mock, for: Test.B)\n"
    end

    test "gives a case that imports a factory module of its own no second one" do
      igniter =
        phx_test_project()
        |> Igniter.update_elixir_file("test/support/data_case.ex", fn zipper ->
          {:ok, zipper} = Igniter.Code.Function.move_to_function_call(zipper, :quote, 1)
          {:ok, body} = Igniter.Code.Common.move_to_do_block(zipper)
          {:ok, Igniter.Code.Common.add_code(body, "import Test.Factory")}
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      data_case = content(igniter, "test/support/data_case.ex")
      assert data_case =~ "import Test.Factory\n"
      refute data_case =~ "import Test.Factories"
      assert data_case =~ "setup {Test.Mocks, :setup_mocks}"
    end

    test "tells a project whose case it cannot place the hooks in what to add" do
      igniter =
        phx_test_project()
        |> Igniter.create_or_update_file(
          "test/support/data_case.ex",
          "defmodule Test.DataCase do\nend\n",
          &Rewrite.Source.update(&1, :content, fn _ -> "defmodule Test.DataCase do\nend\n" end)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "Test.DataCase is not as Phoenix wrote it" and
                   &1 =~ "setup {Test.Mocks, :setup_mocks}")
             )
    end

    # A real project's second run has read none of its files: the docs still name the clock.
    test "keeps naming the clock on a run that has not read the mocks module" do
      installed = installed()

      second =
        %{installed | rewrite: Rewrite.drop(installed.rewrite, ["test/support/mocks.ex"])}
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(second, "TESTING.md") =~ "`Test.ClockMock` is one"
      assert content(second, "docs/elixir.md") =~ "`lib/test/clock.ex`\n  is one, the clock."
    end

    test "brings back no hook the developer removed" do
      igniter = installed()

      removed =
        igniter
        |> content("test/support/data_case.ex")
        |> String.replace("setup {Test.Mocks, :setup_mocks}\n", "")

      igniter =
        igniter
        |> replace_file("test/support/data_case.ex", removed)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(igniter, "test/support/data_case.ex") =~ "setup_mocks"
    end

    test "says no check holds what a project made before does not run" do
      elixir = made_before() |> apply_igniter!() |> content("docs/elixir.md")

      assert elixir =~ "No test holds this here yet"
      assert elixir =~ "A review reads for them:\n  this project runs no Credo."
      refute elixir =~ "`test/conventions_test.exs` holds this"
    end

    test "places each hook once, and leaves a case that already calls setup_mocks/1 alone" do
      igniter = installed() |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      for path <- ["test/support/data_case.ex", "test/support/conn_case.ex"] do
        case_template = content(igniter, path)
        assert length(String.split(case_template, "setup {Test.Mocks, :setup_mocks}")) == 2, path
        assert length(String.split(case_template, "import Test.Factories")) == 2, path
      end
    end
  end

  describe "the release and the image" do
    test "generates the release and the Dockerfile through Phoenix, then gives it the build secret" do
      assert install().tasks == [
               {"phx.gen.release", ["--docker"]},
               {"ehos_app.dockerfile", ["--yes"]}
             ]
    end

    test "writes under /tmp alone, and starts no distribution" do
      env = installed() |> content("rel/env.sh.eex")

      assert env =~ ~s|export RELEASE_TMP="${RELEASE_TMP:-/tmp}"|
      assert env =~ "export RELEASE_DISTRIBUTION=none"
    end
  end

  describe "CI" do
    test "gates the project with ehosctl verify, then builds the image by digest beside the bundle" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      check = workflow["jobs"]["check"]["steps"]
      runs = Enum.map(check, &(&1["run"] || &1["uses"]))

      # The gates are `ehosctl verify`'s alone, not listed again here, where they could drift
      # from what a developer runs; the `ehosctl` it pins runs the schema check too.
      assert "mise exec -- ehosctl verify" in runs

      for gate <-
            ~w(format compile test eh_os_contract.check eh_os_contract.schema eh_os_contract.manifest
               eh_os_contract.graph eh_os_contract.bundle) do
        refute Enum.any?(runs, &(&1 =~ ~r/^(mise exec -- )?mix #{Regex.escape(gate)}\b/)),
               "the check job runs mix #{gate} besides ehosctl verify"
      end

      # The dependencies are fetched first, with the token, so `verify`'s own fetch needs none.
      assert Enum.find_index(runs, &(&1 == "mix deps.get --only test --check-locked")) <
               Enum.find_index(runs, &(&1 == "mise exec -- ehosctl verify"))

      # The bundle `verify` writes, the manifest and every graph document with `bundle.json`
      # (eh-os D-146), is the artifact, and nothing beside it. With an `eh_os_contract` before
      # its bundle task, `verify` writes the manifest alone, and the job stops there, saying why,
      # rather than uploading a manifest EHOS cannot register as a build (#520).
      wrote = Enum.find(check, &(&1["name"] == "Check ehosctl verify wrote the bundle"))

      assert wrote["run"] =~ "if [ ! -f _build/ehos.bundle/bundle.json ]; then"
      assert wrote["run"] =~ "::error::ehosctl verify wrote no bundle into _build/ehos.bundle/"
      assert wrote["run"] =~ "exit 1"

      upload = Enum.find(check, &(&1["uses"] == "actions/upload-artifact@v7"))

      assert upload["with"] == %{
               "name" => "ehos-bundle",
               "path" => "_build/ehos.bundle",
               "if-no-files-found" => "error"
             }

      at = fn step -> Enum.find_index(check, &(&1 == step)) end
      verify = Enum.find(check, &(&1["run"] == "mise exec -- ehosctl verify"))

      assert at.(verify) + 1 == at.(wrote)
      assert at.(wrote) + 1 == at.(upload)

      image = workflow["jobs"]["image"]
      build = Enum.find(image["steps"], &(&1["id"] == "build"))

      assert image["needs"] == "check"
      assert image["permissions"]["packages"] == "write"
      assert build["with"]["secrets"] =~ "github_token="
      assert build["with"]["outputs"] =~ "push-by-digest=true"

      publish = workflow["jobs"]["publish"]

      assert publish["needs"] == "image"
      assert publish["permissions"]["packages"] == "write"
      assert Enum.any?(publish["steps"], &((&1["run"] || "") =~ "imagetools create"))
      assert Enum.any?(publish["steps"], &((&1["run"] || "") =~ "@${DIGEST}"))
    end

    test "reads EHOS's two private repositories, and nothing else, with the App's token" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      for job <- ["check", "image"] do
        token = Enum.find(workflow["jobs"][job]["steps"], &(&1["id"] == "private-deps"))
        assert token["with"]["repositories"] == "eh-os-contract,ehos-tools"
        assert token["with"]["permission-contents"] == "read"
      end

      deps_get = Enum.find(workflow["jobs"]["check"]["steps"], &(&1["name"] == "mix deps.get"))

      assert deps_get["env"]["GIT_CONFIG_COUNT"] == "2"

      assert deps_get["env"]["GIT_CONFIG_VALUE_0"] ==
               "https://github.com/EmpoweredHouse/eh-os-contract"

      assert deps_get["env"]["GIT_CONFIG_VALUE_1"] ==
               "https://github.com/EmpoweredHouse/ehos-tools"
    end

    # mise installs `ehosctl` from a private repository's releases, asking for their
    # attestations first: the token reads ehos-tools alone, with both permissions, only the step
    # that installs sees it, and that step comes before any dependency's code runs. The binary
    # runs only once it is checked against the SHA-256 its release published, since a release's
    # asset can be replaced under the same tag.
    test "installs the released ehosctl with mise, with a token that step alone sees, and checks it" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      steps = workflow["jobs"]["check"]["steps"]
      token = Enum.find(steps, &(&1["id"] == "ehosctl-release"))

      assert token["with"]["repositories"] == "ehos-tools"
      assert token["with"]["permission-contents"] == "read"
      assert token["with"]["permission-attestations"] == "read"

      install = Enum.find(steps, &(&1["name"] == "Install ehosctl"))

      assert install["run"] == "mise use -g github:EmpoweredHouse/ehos-tools@0.28.0"

      assert install["env"] == %{
               "MISE_GITHUB_TOKEN" => "${{ steps.ehosctl-release.outputs.token }}"
             }

      seen_by =
        for step <- steps, inspect(step) =~ "steps.ehosctl-release.outputs.token", do: step

      assert seen_by == [install]
      refute Enum.any?(steps -- [install], &(&1["env"] || %{})["MISE_GITHUB_TOKEN"])

      check = Enum.find(steps, &(&1["name"] == "Check ehosctl is 0.28.0's binary"))

      # ehos-tools' release v0.28.0, SHA256SUMS: `ehosctl_linux_x64`, the runner's binary.
      assert check["run"] =~
               "ba806afa5eb8112523b51e715342db11d54d3715b06e7f62911ede22cf500bab  $(mise which ehosctl)"

      assert check["run"] =~ "sha256sum --check --strict -"

      at = fn step -> Enum.find_index(steps, &(&1 == step)) end
      deps_get = Enum.find(steps, &(&1["name"] == "mix deps.get"))
      verify = Enum.find(steps, &(&1["run"] == "mise exec -- ehosctl verify"))

      assert at.(install) < at.(deps_get)
      assert at.(deps_get) < at.(check)
      assert at.(check) + 1 == at.(verify)
    end

    # `mix deps.get` prints a package's advisories and exits 0 (#507). The `ehosctl` the job pins
    # does not audit, so the job does, as soon as the lock's packages are known.
    test "fails on a retired or vulnerable package right after fetching the dependencies" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      runs = Enum.map(workflow["jobs"]["check"]["steps"], &(&1["run"] || &1["uses"]))

      assert Enum.find_index(runs, &(&1 == "mix deps.get --only test --check-locked")) + 1 ==
               Enum.find_index(runs, &(&1 == "mix hex.audit"))
    end

    # Each as that version wrote it, copied from its tag: `ci.yml.eex` takes no assigns.
    for version <- ~w(0.2.0 0.2.1 0.3.0 0.5.0 0.6.1 0.8.0 0.15.0 0.16.0 0.17.0 0.18.0 0.19.0) do
      test "replaces the workflow #{version} wrote, untouched since, with this version's" do
        earlier = File.read!("test/fixtures/ci_workflows/#{unquote(version)}.yml")

        upgraded =
          phx_test_project()
          |> Igniter.create_new_file(".github/workflows/ci.yml", earlier)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])
          |> apply_igniter!()

        assert content(upgraded, ".github/workflows/ci.yml") ==
                 installed() |> content(".github/workflows/ci.yml")

        upgraded
        |> Igniter.compose_task("ehos_app.install", [])
        |> assert_unchanged()
      end
    end

    test "leaves a workflow the developer changed, with the diff to this version's" do
      earlier = File.read!("test/fixtures/ci_workflows/0.2.0.yml")
      changed = earlier <> "      - run: mix dialyzer\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file(".github/workflows/ci.yml", changed)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "is not what any version of ehos_app wrote" and
                   &1 =~ ~r/^ *- .*mix dialyzer/m and
                   &1 =~ ~r/^ *\+ .*repositories: eh-os-contract,ehos-tools/m)
             )

      assert igniter |> apply_igniter!() |> content(".github/workflows/ci.yml") == changed
    end

    # An image for amd64 alone does not start on Apple silicon, where Erlang/OTP fails under
    # x86-64 emulation, nor on an arm64 cluster.
    test "builds the image natively for amd64 and arm64, and deploys one index over both" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      builds =
        for %{"runner" => runner, "platform" => platform} <-
              workflow["jobs"]["image"]["strategy"]["matrix"]["include"],
            do: {platform, runner}

      assert Enum.sort(builds) == [
               {"linux/amd64", "ubuntu-24.04"},
               {"linux/arm64", "ubuntu-24.04-arm"}
             ]
    end

    # With the test environment's dependencies alone, `deps.unlock --check-unused` reports the
    # children of dev-only ones as unused, and fails every run.
    test "fetches the test environment's dependencies alone, and checks nothing that needs the rest" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      runs = Enum.map(workflow["jobs"]["check"]["steps"], &(&1["run"] || ""))

      assert "mix deps.get --only test --check-locked" in runs
      refute Enum.any?(runs, &(&1 =~ "deps.unlock"))
    end

    # A pull request of the repository gets a preview of its own on EHOS, with no stored secret
    # (eh-os D-110, ehos-tools T-18, #266); a fork's and a bot's get none, and the environment goes
    # when the pull request closes.
    test "deploys a pull request of the repository to an ephemeral environment of its own, links it, and removes it when it closes" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      jobs = workflow["jobs"]
      same_repository = "github.event.pull_request.head.repo.full_name == github.repository"

      assert "closed" in workflow["on"]["pull_request"]["types"]

      # One group per pull request, whose closing waits for its run rather than cancelling it: a
      # merged pull request's closing runs on the base branch's ref, which every one shares.
      assert workflow["concurrency"]["group"] ==
               "ci-${{ github.event.pull_request.number || github.ref }}"

      assert workflow["concurrency"]["cancel-in-progress"] ==
               "${{ github.event_name == 'pull_request' && github.event.action != 'closed' }}"

      assert jobs["check"]["if"] == "github.event.action != 'closed'"

      # A pull request of the repository pushes its image and publishes it, as `main` does.
      build = Enum.find(jobs["image"]["steps"], &(&1["id"] == "build"))
      assert build["with"]["outputs"] =~ same_repository
      assert jobs["publish"]["if"] =~ same_repository

      preview = jobs["preview"]

      assert preview["needs"] == "publish"
      assert preview["if"] =~ same_repository
      assert preview["if"] =~ "!endsWith(github.actor, '[bot]')"
      assert preview["if"] =~ "github.event.action != 'closed'"
      # Without an installation `publish` is skipped, and `preview` still runs to say so.
      assert preview["if"] =~ "needs.publish.result == 'success' || vars.EHOSCTL_URL == ''"
      assert jobs["publish"]["if"] =~ "vars.EHOSCTL_URL != ''"

      # The actions a job that may ask for a token EHOS accepts runs are pinned by commit.
      for job <- ["publish", "preview", "preview-remove"],
          step <- jobs[job]["steps"],
          step["uses"] do
        assert step["uses"] =~ ~r/@[0-9a-f]{40}$/, "#{job} runs #{step["uses"]} by a tag"
      end

      assert preview["permissions"] == %{
               "contents" => "read",
               "id-token" => "write",
               "pull-requests" => "write"
             }

      # The installation is two repository variables, not secrets.
      assert preview["env"]["EHOSCTL_URL"] == "${{ vars.EHOSCTL_URL }}"
      assert preview["env"]["EHOSCTL_CA_PEM"] == "${{ vars.EHOSCTL_CA_PEM }}"
      refute inspect(preview) =~ "secrets.EHOS_TOKEN"

      runs = Enum.map(preview["steps"], &(&1["run"] || ""))
      install = Enum.find(runs, &(&1 =~ "gh release download v0.28.0"))

      # The binary runs only once its SHA-256 is the release's: ehos-tools' release v0.28.0,
      # SHA256SUMS, `ehosctl_linux_x64`.
      assert install =~
               "ba806afa5eb8112523b51e715342db11d54d3715b06e7f62911ede22cf500bab  $RUNNER_TEMP/ehosctl_linux_x64"

      assert :binary.match(install, "sha256sum --check --strict") <
               :binary.match(install, "install -m 0755")

      assert Enum.any?(runs, &(&1 =~ ~s|env extend "$environment" --app "$APPLICATION" --ttl 8h|))
      assert Enum.any?(runs, &(&1 =~ ~s|env create "$environment" --app "$APPLICATION" --ttl 8h|))
      assert Enum.any?(runs, &(&1 =~ ~s|environment="$APPLICATION-pr-$PULL_REQUEST"|))
      assert Enum.any?(runs, &(&1 =~ "<!-- ehos-preview %s %s -->"))
      assert Enum.any?(runs, &(&1 =~ ~S|"$APPLICATION" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$|))
      # The job's credential cannot register the application, so naming no installation says a
      # person registers it there once.
      no_installation = Enum.find(runs, &(&1 =~ "ehosctl apps register <manifest>"))
      {register, _} = :binary.match(no_installation, "ehosctl apps register")
      {variable, _} = :binary.match(no_installation, "Then set the repository variable")
      assert register < variable

      remove = jobs["preview-remove"]

      assert remove["if"] =~ "github.event.action == 'closed'"
      assert remove["if"] =~ same_repository
      assert remove["permissions"]["id-token"] == "write"
      refute Map.has_key?(remove, "needs")

      remove_runs = Enum.map(remove["steps"], &(&1["run"] || ""))

      # Only the bot's own comment, naming this pull request's environment, says what to remove.
      assert Enum.any?(remove_runs, &(&1 =~ ~s|.user.login == "github-actions[bot]"|))
      assert Enum.any?(remove_runs, &(&1 =~ ~s|"$application-pr-$PULL_REQUEST"|))

      removal =
        Enum.find_index(
          remove_runs,
          &(&1 =~ ~s|env remove "$ENVIRONMENT" --app "$APPLICATION" --confirm "$ENVIRONMENT"|)
        )

      assert removal

      # Once the environment is removed, the preview's comment says so, and no longer links an
      # address nothing answers (#295). It keeps its marker, for a pull request opened again.
      assert remove["permissions"]["pull-requests"] == "write"
      assert Enum.any?(remove_runs, &(&1 =~ ~s|echo "comment=$comment" >> "$GITHUB_OUTPUT"|))
      said = Enum.find_index(remove_runs, &(&1 =~ "**Preview:** removed"))
      assert said > removal
      assert Enum.at(remove_runs, said) =~ "<!-- ehos-preview %s %s -->"
      assert Enum.at(remove_runs, said) =~ ~s|issues/comments/$ID|
      refute Enum.at(remove_runs, said) =~ "https://"
      # Also when the removal failed or never ran, as for a preview that expired first: it then
      # says it expires by itself.
      step = Enum.at(remove["steps"], said)
      assert step["if"] =~ "always()"
      assert step["env"]["REMOVED"] == "${{ steps.remove.outcome }}"
      script = Enum.at(remove_runs, said)

      # A merge's closing run is on the base branch's ref, for which EHOS gives no credential to
      # remove a preview (eh-os#672): it tries nothing that needs one, and says the preview was
      # kept, before anything about a removal.
      merge_skips = "steps.preview.outputs.environment != '' && !github.event.pull_request.merged"

      for id <- ["ehosctl-release", "remove"] do
        assert Enum.find(remove["steps"], &(&1["id"] == id))["if"] == merge_skips
      end

      assert Enum.find(remove["steps"], &(&1["name"] == "Install ehosctl 0.23.0"))["if"] ==
               merge_skips

      assert step["env"]["MERGED"] == "${{ github.event.pull_request.merged }}"
      {merged, _} = :binary.match(script, ~s|if [ "$MERGED" = true ]; then|)
      {kept, _} = :binary.match(script, "**Preview:** kept when this pull request was merged")
      {success, _} = :binary.match(script, ~s|elif [ "$REMOVED" = success ]; then|)
      assert merged < kept and kept < success

      {removed, _} = :binary.match(script, "**Preview:** removed")
      {otherwise, _} = :binary.match(script, "else")
      {not_removed, _} = :binary.match(script, "**Preview:** not removed")
      assert success < removed and removed < otherwise and otherwise < not_removed
      assert Enum.at(remove["steps"], removal)["id"] == "remove"
    end

    # Every build `publish` pushes, on `main` and on a pull request, is registered with EHOS with
    # the commit it came from, and a pull request's preview is that build (eh-os D-146, #554).
    test "registers each build it publishes, and deploys the pull request's preview from it" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      publish = workflow["jobs"]["publish"]
      steps = publish["steps"]
      at = fn step -> Enum.find_index(steps, &(&1 == step)) end

      assert workflow["on"]["push"]["branches"] == ["main"]

      assert publish["permissions"] == %{
               "contents" => "read",
               "packages" => "write",
               "id-token" => "write"
             }

      assert publish["env"]["EHOSCTL_URL"] == "${{ vars.EHOSCTL_URL }}"

      assert publish["outputs"] == %{
               "application" => "${{ steps.register.outputs.application }}",
               "build" => "${{ steps.register.outputs.build }}"
             }

      # `ehosctl builds register` reads 100 commits before the one built: a pull request's is
      # GitHub's test merge, one above its head (#498). The checkout comes first, since it
      # empties a workspace that is not a repository, and leaves no token behind.
      [checkout | _rest] = steps
      assert checkout["uses"] =~ ~r/^actions\/checkout@[0-9a-f]{40}$/

      assert checkout["with"] == %{
               "fetch-depth" => "${{ github.event_name == 'pull_request' && 102 || 101 }}",
               "persist-credentials" => false
             }

      bundle = Enum.find(steps, &(&1["with"]["name"] == "ehos-bundle"))
      assert bundle["with"]["path"] == "ehos-deployment/ehos.bundle"
      upload = Enum.find(steps, &(&1["with"]["name"] == "ehos-deployment"))
      index = Enum.find(steps, &(&1["id"] == "index"))
      install = Enum.find(steps, &(&1["name"] == "Install ehosctl 0.28.0"))
      register = Enum.find(steps, &(&1["id"] == "register"))

      assert install["run"] =~
               "ba806afa5eb8112523b51e715342db11d54d3715b06e7f62911ede22cf500bab  $RUNNER_TEMP/ehosctl_linux_x64"

      # Registered after the index is pushed and `ehos-deployment` published, so a refusal
      # leaves the artifact as it was, and only where the repository names its installation.
      assert at.(index) < at.(bundle) and at.(bundle) < at.(upload) and
               at.(upload) < at.(register)

      for step <- [install, register],
          do: assert(step["if"] == "vars.EHOSCTL_URL != ''")

      assert register["env"]["DIGEST"] == "${{ steps.index.outputs.digest }}"
      script = register["run"]

      assert script =~
               ~s|ehosctl builds register ehos-deployment/ehos.bundle --image "$IMAGE@$DIGEST" --json > "$RUNNER_TEMP/build.json" 2> "$RUNNER_TEMP/register.err" \|\| code=$?|

      assert script =~ ~S|"$application" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$|

      # The id reaches `$GITHUB_OUTPUT` and `preview` only in its form: `jq` prints `null` for a
      # missing one.
      {id, _} =
        :binary.match(script, ~S|build=$(jq -r '.build.id // empty' "$RUNNER_TEMP/build.json")|)

      {form, _} =
        :binary.match(script, ~S|if ! [[ "$build" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$ ]]; then|)

      {output, _} = :binary.match(script, ~s|echo "build=$build" >> "$GITHUB_OUTPUT"|)
      assert id < form and form < output

      # EHOS refusing the token on a push, as a trust made for previews alone does, leaves `main`
      # as it was before builds, and says how to add the ref, keeping the trust's others, once
      # the ref is protected. A refused registration, a pull request's refusal and any other
      # failure fail the job.
      {refused, _} =
        :binary.match(
          script,
          ~s|elif [ "$code" = 3 ] && [ "$GITHUB_EVENT_NAME" = push ] &&\n| <>
            ~S{     jq -e '.error.message | test("^\\S+ refused this job.s GitHub Actions token\\. ")' "$RUNNER_TEMP/register.err" > /dev/null 2>&1; then}
        )

      {protect, _} = :binary.match(script, "first protect the ref with a ruleset")

      {trust, _} =
        :binary.match(
          script,
          "--ref 'refs/pull/*/merge' --ref $GITHUB_REF\\`, with every other ref"
        )

      {otherwise, _} = :binary.match(script, ~s|exit "$code"|)
      assert refused < protect and protect < trust and trust < otherwise

      setup = Enum.find(steps, &((&1["uses"] || "") =~ ~r/^docker\/setup-buildx-action@/))
      assert setup["with"] == %{"driver" => "docker"}

      preview = workflow["jobs"]["preview"]

      assert preview["env"]["APPLICATION"] == "${{ needs.publish.outputs.application }}"
      assert preview["env"]["BUILD"] == "${{ needs.publish.outputs.build }}"
      refute Enum.any?(preview["steps"], &(&1["with"]["name"] == "ehos-deployment"))

      runs = Enum.map(preview["steps"], &(&1["run"] || ""))
      deploy = Enum.find(runs, &(&1 =~ "ehosctl deploy"))

      assert deploy ==
               ~s|code=0\nehosctl deploy "$APPLICATION" --env "$ENVIRONMENT" --json --build "$BUILD" > deployment.json \|\| code=$?\ncat deployment.json\n| <>
                 ~s|echo "address=$(jq -r '.addresses[0] // empty' deployment.json 2> /dev/null)" >> "$GITHUB_OUTPUT"\n| <>
                 ~s|echo "outcome=$(jq -r '.outcome // empty' deployment.json 2> /dev/null)" >> "$GITHUB_OUTPUT"\n| <>
                 ~s|exit "$code"\n|

      assert Enum.any?(runs, &(&1 =~ ~s|if [ -z "$BUILD" ]; then|))
    end

    # A workflow of its own, so that editing the description reruns this job alone (#229).
    test "checks in a workflow of its own, rerun when the description is edited, that the pull request records its review" do
      workflow =
        installed() |> content(".github/workflows/review.yml") |> YamlElixir.read_from_string!()

      assert workflow["on"]["pull_request"]["types"] == ~w(opened edited reopened synchronize)
      assert [job] = Map.values(workflow["jobs"])
      assert job["env"]["MIX_ENV"] == "dev"

      runs = Enum.map(job["steps"], &(&1["run"] || ""))
      check = Enum.find(job["steps"], &(&1["run"] == "mix ehos_app.review pull_request"))

      # `ehos_app` is a dependency in `:dev` alone.
      assert Enum.find_index(runs, &(&1 == "mix deps.get --only dev --check-locked")) <
               Enum.find_index(runs, &(&1 == "mix ehos_app.review pull_request"))

      # The description comes in through the environment, never the script's text.
      assert check["env"]["PULL_REQUEST_BODY"] == "${{ github.event.pull_request.body }}"
      refute Enum.any?(runs, &(&1 =~ "github.event.pull_request"))

      token = Enum.find(job["steps"], &(&1["id"] == "private-deps"))
      assert token["with"]["repositories"] == "eh-os-contract,ehos-tools"
      assert token["with"]["permission-contents"] == "read"

      # A run that fails on the description, as the first usually does, still keeps its build.
      save = Enum.find(job["steps"], &(&1["uses"] == "actions/cache/save@v6"))
      assert save["if"] =~ "!cancelled()"
      assert save["if"] =~ "steps.cache.outputs.cache-hit != 'true'"
      restore = Enum.find(job["steps"], &(&1["id"] == "cache"))
      assert restore["uses"] == "actions/cache/restore@v6"
      assert restore["with"]["key"] == save["with"]["key"]
    end
  end

  describe "the agent harness" do
    defp with_file(path, content) do
      phx_test_project()
      |> Igniter.create_or_update_file(path, content, fn source ->
        Rewrite.Source.update(source, :content, fn _ -> content end)
      end)
      |> apply_igniter!()
    end

    # Phoenix 1.8's AGENTS.md, as `phx.new` assembles it: its own lines, then the usage rules of
    # the packages it uses between markers.
    @phoenix_agents """
    This is a web application written using the Phoenix web framework.

    ## Project guidelines

    - Use `mix precommit` alias when you are done with all changes and fix any pending issues

    <!-- usage-rules-start -->
    <!-- phoenix:elixir-start -->
    ## Elixir guidelines
    <!-- phoenix:elixir-end -->
    <!-- usage-rules-end -->
    """

    # What the installer writes and never rewrites, and what it keeps a section of.
    @seeds [
      "CLAUDE.md",
      "lib/test/contracts/CLAUDE.md",
      "lib/test_web/CLAUDE.md",
      ".coderabbit.yaml",
      ".github/pull_request_template.md",
      ".github/workflows/review.yml",
      "test/harness_test.exs"
    ]
    @managed [
      {"AGENTS.md", "agents"},
      {"README.md", "readme"},
      {"VISION.md", "vision"},
      {"lib/test/contracts/AGENTS.md", "contracts"},
      {"lib/test_web/AGENTS.md", "web"},
      {"ARCHITECTURE.md", "architecture"},
      {"TESTING.md", "testing"},
      {"DEVELOPMENT.md", "development"},
      {"docs/elixir.md", "elixir"}
    ]

    # The line budgets `test/harness_test.exs` holds the managed files to.
    @budgets %{
      "ARCHITECTURE.md" => 400,
      "DEVELOPMENT.md" => 400,
      "TESTING.md" => 300,
      "docs/elixir.md" => 400
    }

    defp section(name), do: ~r/<!-- ehos_app:#{name} -->.*?<!-- \/ehos_app:#{name} -->\n?/s

    test "moves Phoenix's AGENTS.md to docs/phoenix.md, as Phoenix wrote it, and writes a lean one" do
      igniter =
        with_file("AGENTS.md", @phoenix_agents) |> Igniter.compose_task("ehos_app.install", [])

      agents = content(igniter, "AGENTS.md")

      assert content(igniter, "docs/phoenix.md") == @phoenix_agents
      assert agents =~ ~r/\A<!-- ehos_app:agents -->/
      refute agents =~ "usage-rules-start"
      assert agents =~ "[docs/phoenix.md](docs/phoenix.md)"
      assert content(igniter, "lib/test_web/AGENTS.md") =~ "(../../docs/phoenix.md)"
      assert agents |> String.split("\n") |> length() <= 200
    end

    test "puts the EHOS section on top of an AGENTS.md of the project's own" do
      igniter =
        with_file("AGENTS.md", "# Our rules\n") |> Igniter.compose_task("ehos_app.install", [])

      agents = content(igniter, "AGENTS.md")

      assert agents =~ ~r/\A<!-- ehos_app:agents -->/
      assert agents =~ ~r/<!-- \/ehos_app:agents -->\n\n# Our rules\n\z/
      refute Igniter.exists?(igniter, "docs/phoenix.md")
      refute content(igniter, "lib/test_web/AGENTS.md") =~ "docs/phoenix.md"
    end

    test "replaces the EHOS section an earlier version wrote, and keeps the rest" do
      igniter =
        with_file(
          "AGENTS.md",
          "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n\n# Phoenix rules\n"
        )
        |> Igniter.compose_task("ehos_app.install", [])

      content = content(igniter, "AGENTS.md")

      refute content =~ "Old rules"
      assert content =~ "# EHOS application"
      assert content =~ ~r/<!-- \/ehos_app:agents -->\n\n# Phoenix rules\n\z/
    end

    test "says how to move Phoenix's rules out of an AGENTS.md from ehos_app 0.2" do
      agents =
        "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n\n" <> @phoenix_agents

      igniter = with_file("AGENTS.md", agents) |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "AGENTS.md") =~ @phoenix_agents
      refute Igniter.exists?(igniter, "docs/phoenix.md")
      assert Enum.any?(igniter.notices, &(&1 =~ "into\ndocs/phoenix.md"))
      refute installed() |> Map.fetch!(:notices) |> Enum.any?(&(&1 =~ "docs/phoenix.md"))
    end

    test "gives an AGENTS.md that holds the EHOS section alone, as 0.2 wrote it, the application's part" do
      agents = "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n"
      igniter = with_file("AGENTS.md", agents) |> Igniter.compose_task("ehos_app.install", [])

      content = content(igniter, "AGENTS.md")

      refute content =~ "Old rules"
      assert content =~ ~r/\A<!-- ehos_app:agents -->/
      assert content =~ ~r/<!-- \/ehos_app:agents -->\n+# Test\n/
      assert content =~ "## Where to read"
      assert content =~ "## Nested AGENTS.md files"
      assert content == content(installed(), "AGENTS.md")
    end

    test "leaves a nested AGENTS.md the developer cut down to the EHOS section as it is" do
      igniter = installed()
      web = content(igniter, "lib/test_web/AGENTS.md")
      [section] = Regex.run(section("web"), web)

      again =
        igniter
        |> Igniter.update_file("lib/test_web/AGENTS.md", fn source ->
          Rewrite.Source.update(source, :content, fn _ -> section end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(again, "lib/test_web/AGENTS.md") == section
    end

    test "leaves an EHOS section alone when its end marker is gone" do
      agents = "<!-- ehos_app:agents -->\nRules the developer rewrote\n\n# Phoenix rules\n"
      igniter = with_file("AGENTS.md", agents) |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "AGENTS.md") == agents
    end

    # The README phx.new writes, rendered from the template of the phx_new this package tests
    # against, so that a change to it in a later Phoenix fails here rather than in a project.
    defp phoenix_readme do
      Mix.Project.deps_paths()
      |> Map.fetch!(:phx_new)
      |> Path.join("templates/phx_single/README.md.eex")
      |> File.read!()
      |> EEx.eval_string(assigns: [app_module: "Test"])
    end

    test "replaces the README Phoenix generates, and keeps one of the project's own" do
      for phoenix <- [
            phoenix_readme(),
            phoenix_readme() |> String.replace("\n", " \r\n"),
            phoenix_readme() |> String.replace("\n", "\t\n")
          ] do
        readme = with_file("README.md", phoenix) |> Igniter.compose_task("ehos_app.install", [])

        assert content(readme, "README.md") =~ ~r/\A# Test\n\n<!-- One sentence/
        assert content(readme, "README.md") =~ "## Quick start"
        refute content(readme, "README.md") =~ "To start your Phoenix server"
      end

      own = with_file("README.md", "# Ours\n") |> Igniter.compose_task("ehos_app.install", [])

      assert content(own, "README.md") =~ ~r/\A<!-- ehos_app:readme -->.*\n# Ours\n\z/s
    end

    test "keeps a README of the project's own that still quotes Phoenix's sentence" do
      for readme <- [
            "# Shop\n\nWhat it does.\n\n## Running it\n\nTo start your Phoenix server:\n\n* `mix setup`\n",
            "# Shop\n\nTo start your Phoenix server:\n\n" <> String.duplicate("Our notes.\n", 40),
            # Phoenix's own, with a few lines of the developer's at the end.
            String.replace(phoenix_readme(), "# Test", "# Shop") <>
              "\n## Deploying\n\nfly deploy\n"
          ] do
        igniter = with_file("README.md", readme) |> Igniter.compose_task("ehos_app.install", [])

        assert content(igniter, "README.md") =~
                 ~r/\A<!-- ehos_app:readme -->.*<!-- \/ehos_app:readme -->\n\n# Shop\n/s

        assert content(igniter, "README.md") =~ readme
      end
    end

    test "writes every seed, and never overwrites one" do
      igniter = installed()

      for path <- @seeds, do: assert(Igniter.exists?(igniter, path), "#{path} was not written")

      mine =
        Enum.reduce(@seeds, phx_test_project(), fn path, igniter ->
          Igniter.create_or_update_file(igniter, path, "# mine\n", fn source ->
            Rewrite.Source.update(source, :content, fn _ -> "# mine\n" end)
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      for path <- @seeds, do: assert(content(mine, path) == "# mine\n", "#{path} was overwritten")
    end

    test "keeps a section in each managed file, on top of what the developer wrote" do
      igniter =
        Enum.reduce(@managed, phx_test_project(), fn {path, _}, igniter ->
          Igniter.create_or_update_file(igniter, path, "# mine\n", fn source ->
            Rewrite.Source.update(source, :content, fn _ -> "# mine\n" end)
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      for {path, name} <- @managed do
        assert content(igniter, path) =~ ~r/\A<!-- ehos_app:#{name} -->.*\n# mine\n\z/s, path
      end
    end

    # ehos-tools#504: the rules for code that is not a contract's part, in a doc of the template's
    # and as rules in the section every agent reads first.
    test "says how Elixir is written, in docs/elixir.md and as rules in AGENTS.md" do
      igniter = installed(["--example"])
      elixir = content(igniter, "docs/elixir.md")
      agents = content(igniter, "AGENTS.md")

      for heading <- [
            "# How Elixir is written",
            "## Ways out",
            "## Data",
            "## Pages and controllers",
            "## Control flow and style",
            "## This application's rules"
          ],
          do: assert(elixir =~ heading, heading)

      # The example's decider shows a contract's part needs no behaviour of its own.
      assert elixir =~ "`lib/test/entries/entry.ex`"
      refute installed() |> content("docs/elixir.md") =~ "entries/entry.ex"

      [section] = Regex.run(section("agents"), agents)
      assert section =~ "## How Elixir is written"
      assert section =~ "Load `/ehos-app:elixir` and read [docs/elixir.md](docs/elixir.md)"
      assert section =~ "## Execution discipline"
      assert section =~ "read the `git log` of the files it lives in"
      assert agents =~ "| Writing Elixir and its tests | [docs/elixir.md](docs/elixir.md) |"

      # Where the platform documents itself moved to ARCHITECTURE.md, to keep AGENTS.md short.
      refute section =~ "## Where the platform documents itself"
      assert content(igniter, "ARCHITECTURE.md") =~ "## Where the platform documents itself"

      assert content(igniter, "lib/test_web/AGENTS.md") =~
               "**A LiveView or a controller orchestrates**"

      testing = content(igniter, "TESTING.md")
      assert testing =~ "## Doubles"
      assert testing =~ "`Hammox.defmock/2` in `test/support/mocks.ex`"
      refute testing =~ "`async` test never changes `Application` env"
    end

    test "tells a project whose own AGENTS.md has no row for docs/elixir.md to add one" do
      notice = &String.contains?(&1, "Add it to AGENTS.md's \"Where to read\"")

      refute install() |> Map.fetch!(:notices) |> Enum.any?(notice)

      igniter =
        with_file("AGENTS.md", "# Our rules\n") |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, notice)
    end

    test "explains EHOS at the top of VISION.md, and points to it from the README" do
      igniter = installed()
      vision = content(igniter, "VISION.md")

      assert vision =~ ~r/\A# Test\n/
      assert vision =~ "## Where this application sits"
      assert vision =~ "The principles it inherits"
      assert content(igniter, "README.md") =~ "[VISION.md](VISION.md) says what that means"
    end

    test "says how a change is made, contract first, and how it is run, built and deployed" do
      development = installed() |> content("DEVELOPMENT.md")

      for heading <- [
            "## The cycle: contract first",
            "### 2. Change the contract",
            "### 3. Check the contract before writing code",
            "## Running it locally",
            "## Building",
            "## Deploying",
            "## Who deploys, and joining the team",
            "## Keeping it current"
          ],
          do: assert(development =~ heading, heading)

      # A developer who deploys is given a role for this application alone, never the operator's keys.
      assert development =~
               "ehosctl role-bindings bind ehos.application_administrator --to <email> --app test"

      # A candidate in an ephemeral environment, promoted by the process owner: EHOS refuses a
      # deployment straight to production since 0.9.0 (eh-os D-105).
      assert development =~ "ehosctl env create test-try --app test"
      assert development =~ "ehosctl deploy test --env test-try"
      assert development =~ "**Promote to production**"
      refute development =~ "ehosctl deploy test --env production"
      # A first promotion puts the application's authority in force in production, so its approver
      # also registers it there (eh-os D-119).
      assert development =~
               "ehosctl role-bindings bind ehos.registrar --to <email> --app test --env production"

      # `ehosctl deploy --preview` refuses an `--image`.
      refute development =~ ~r/--image[^\n]*--preview/
      # A preview's credential cannot register the application, and EHOS refuses to trust a
      # repository for one it does not know: a person registers it once, first.
      [previews] = Regex.run(~r/## Previews of pull requests.*?(?=\n## )/s, development)

      {register, _} =
        :binary.match(
          previews,
          "ehosctl apps register _build/deploy/ehos.bundle/ehos.manifest.json"
        )

      {trust, _} = :binary.match(previews, "ehosctl trust add")
      assert register < trust

      # The trust a repository starts with accepts pull requests alone (eh-os D-121); `main` is
      # added only once a ruleset protects it, which the trust cannot require (eh-os#1056).
      assert previews =~
               "ehosctl trust add --app test --repo <owner>/<repository> --ref 'refs/pull/*/merge'\n"

      refute previews =~ "--ref refs/heads/main"
      assert previews =~ "first protect `main` with a ruleset"

      # By hand, a candidate is the newest build of `main`.
      assert development =~
               "ehosctl deploy test --env test-try --build latest --ref refs/heads/main"

      # Every download goes where git ignores it, so `git add .` commits no manifest (#295).
      downloads =
        Regex.scan(~r/-n ehos-deployment -D (\S+)/, development, capture: :all_but_first)

      assert downloads != [] and Enum.all?(downloads, &(&1 == ["_build/deploy"]))
      refute development =~ ~r/[ (]deploy\/(ehos\.manifest\.json|image)/
      assert installed() |> content(".gitignore") =~ ~r{^/_build/$}m

      assert development =~ "mix eh_os_contract.check"
      assert installed() |> content("README.md") =~ "ehosctl verify"
    end

    test "names the application in commands as EHOS does, with dashes" do
      igniter =
        phx_test_project(app_name: :my_shop)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "DEVELOPMENT.md") =~ "ehosctl deploy my-shop --env my-shop-try"
      assert content(igniter, "README.md") =~ "ehosctl deploy my-shop --env"
    end

    # Before 0.9.0, ARCHITECTURE.md and TESTING.md were written once and never again.
    test "puts its section on top of an ARCHITECTURE.md an earlier version wrote, and says so" do
      igniter =
        with_file("ARCHITECTURE.md", "# Architecture\n\nOurs.\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ARCHITECTURE.md") =~
               ~r/\A<!-- ehos_app:architecture -->.*<!-- \/ehos_app:architecture -->\n\n# Architecture\n\nOurs\.\n\z/s

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "ARCHITECTURE.md has a section of the template's")
             )

      refute Enum.any?(install().notices, &(&1 =~ "has a section of the template's"))
    end

    # The file as 0.3.0 to 0.8.1 wrote it for this project, from that version's template.
    defp earlier_seed(name, version, example) do
      EEx.eval_file("priv/templates/ehos_app.install/earlier/#{name}-#{version}.md.eex",
        assigns: [
          app: :test,
          module: "Test",
          web: "TestWeb",
          web_port: 4000,
          health_port: 4001,
          example: example
        ]
      )
    end

    test "replaces an ARCHITECTURE.md or a TESTING.md still as an earlier version wrote it with the seed" do
      new_project = installed()

      for {path, name, version, example, newline} <- [
            {"ARCHITECTURE.md", "architecture", "0.3.0", false, "\n"},
            {"ARCHITECTURE.md", "architecture", "0.7.0", true, "\r\n"},
            {"TESTING.md", "testing", "0.3.0", true, "\n"},
            {"TESTING.md", "testing", "0.8.0", false, "\r\n"}
          ] do
        earlier = name |> earlier_seed(version, example) |> String.replace("\n", newline)

        igniter =
          with_file(path, earlier)
          |> Igniter.compose_task("ehos_app.install", [])

        assert content(igniter, path) == content(new_project, path),
               "#{path} as #{version} wrote it was not replaced"

        refute Enum.any?(igniter.notices, &(&1 =~ "has a section of the template's"))
      end
    end

    # 0.9 put its section on top of the file, untouched below it.
    test "replaces an ARCHITECTURE.md 0.9 put its section on top of, still as before below it" do
      new_project = installed()
      [section] = Regex.run(section("architecture"), content(new_project, "ARCHITECTURE.md"))
      upgraded_by_09 = section <> "\n" <> earlier_seed("architecture", "0.5.0", false)

      igniter =
        with_file("ARCHITECTURE.md", upgraded_by_09)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ARCHITECTURE.md") == content(new_project, "ARCHITECTURE.md")
    end

    test "keeps an ARCHITECTURE.md an earlier version wrote once the developer changed a line" do
      changed = earlier_seed("architecture", "0.7.0", false) <> "\nOurs.\n"

      igniter =
        with_file("ARCHITECTURE.md", changed)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ARCHITECTURE.md") =~
               ~r/<!-- \/ehos_app:architecture -->\n\n#{Regex.escape(changed)}\z/

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "ARCHITECTURE.md has a section of the template's")
             )
    end

    # 0.2 wrote the root AGENTS.md as its section alone, which a later run makes the seed again.
    test "keeps the seed's sentence on the example when it writes the seed again without --example" do
      igniter = installed(["--example"])
      agents = content(igniter, "AGENTS.md")
      [alone] = Regex.run(section("agents"), agents)

      again =
        igniter
        |> replace_file("AGENTS.md", alone)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(again, "AGENTS.md") == agents
      assert agents =~ "The example is"
      refute content(installed(), "AGENTS.md") =~ "The example is"
    end

    test "writes the contract rules without --example too" do
      contracts = installed() |> content("lib/test/contracts/AGENTS.md")
      dir = Path.dirname(Install.contract_docs())

      for doc <- ["contract.md", "rules.md", "authorization.md", "dsl/contract-dsl.md"] do
        assert contracts =~ "#{dir}/#{doc}"
      end
    end

    test "points agents at the contract reference where the sparse dependency puts it" do
      docs = Install.contract_docs()
      assert docs == "deps/eh_os_contract/packages/eh_os_contract/docs/contract.md"

      igniter = installed(["--example"])

      for path <- [
            "AGENTS.md",
            "README.md",
            "lib/test/domain.ex",
            "lib/test/contracts/entries.ex"
          ] do
        assert content(igniter, path) =~ docs
      end
    end

    test "enables the ehos-app and eh-os-contract plugins in .claude/settings.json, at their tags, and the review gate" do
      %{ref: app} = plugin("ehos-app")
      %{ref: contract} = plugin("eh-os-contract")
      igniter = installed()
      written = content(igniter, ".claude/settings.json")

      # The hook's command is long; its parts are the next test's.
      [plugins, gate] = String.split(written, "\n  \"hooks\": ", parts: 2)

      assert JSON.decode!(~s({"hooks": ) <> gate)["hooks"] == %{
               "PreToolUse" => [
                 %{
                   "matcher" => "Bash",
                   "hooks" => [Install.review_gate_hook() |> Jason.encode!() |> JSON.decode!()]
                 }
               ]
             }

      assert plugins <> "\n" == """
             {
               "extraKnownMarketplaces": {
                 "ehos-app": {
                   "source": {
                     "source": "github",
                     "repo": "EmpoweredHouse/ehos-tools",
                     "ref": "#{app}",
                     "path": ".claude-plugin/ehos-app.json"
                   }
                 },
                 "eh-os-contract": {
                   "source": {
                     "source": "github",
                     "repo": "EmpoweredHouse/eh-os-contract",
                     "ref": "#{contract}"
                   }
                 }
               },
               "enabledPlugins": {
                 "ehos-app@ehos-app": true,
                 "eh-os-contract@eh-os-contract": true
               },
             """

      refute Enum.any?(Map.keys(igniter.assigns.test_files), &String.starts_with?(&1, ".agents/"))
    end

    # The gate's own behaviour is EhosApp.Review's, tested there; this is the hook that runs it.
    test "runs the review gate before gh opens a pull request, refusing whenever it cannot run" do
      %{"command" => command, "timeout" => timeout} =
        Install.review_gate_hook() |> Jason.encode!() |> JSON.decode!()

      assert command =~ ~s(case "$input" in *gh*pr*create*|*gh*pr*new*\) ;; *\) exit 0 ;; esac)

      assert command =~
               ~s(cd "$CLAUDE_PROJECT_DIR" && printf '%s' "$input" | MIX_ENV=dev mix ehos_app.review gate)

      # Exit status 2 is the gate's refusal; any other failure refuses as well.
      assert command =~ ~s(if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then exit "$rc"; fi)
      assert String.ends_with?(command, "exit 2")
      # Past it Claude Code runs the command, and a first gate compiles every dependency.
      assert timeout >= 600
    end

    test "adds the review gate beside the developer's own hooks, once" do
      settings = """
      {
        "hooks": {
          "PreToolUse": [
            {"matcher": "Edit", "hooks": [{"type": "command", "command": "mix format"}]}
          ],
          "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
        }
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      hooks = igniter |> content(".claude/settings.json") |> JSON.decode!() |> Map.fetch!("hooks")

      assert [%{"matcher" => "Edit"}, %{"matcher" => "Bash", "hooks" => [gate]}] =
               hooks["PreToolUse"]

      assert gate == Install.review_gate_hook() |> Jason.encode!() |> JSON.decode!()
      assert hooks["Stop"] == [%{"hooks" => [%{"type" => "command", "command" => "say done"}]}]

      igniter |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    # The section comes last and says nothing, so the review workflow fails a pull request
    # opened from the template until its author fills it in.
    test "ends the pull request template with a Review section the author has to fill in" do
      template = installed() |> content(".github/pull_request_template.md")

      assert template =~ ~r/\n## Review\n\n<!--[^#]*-->\n\z/
      assert {:error, message} = EhosApp.Review.pull_request_body(template)
      assert message =~ "section is empty"

      assert EhosApp.Review.pull_request_body(template <> "\nNothing found.\n") == :ok
    end

    test "replaces the pull request template an earlier version wrote, and leaves one the developer changed" do
      earlier = File.read!("test/fixtures/pull_request_template_0.14.0.md")
      path = ".github/pull_request_template.md"

      for version <- ["0.14.0", "0.21.0"] do
        upgraded =
          phx_test_project()
          |> with_file(path, File.read!("test/fixtures/pull_request_template_#{version}.md"))
          |> Igniter.compose_task("ehos_app.install", [])

        assert content(upgraded, path) == installed() |> content(path), "from #{version}"
      end

      edited =
        File.read!("test/fixtures/pull_request_template_0.21.0.md") <>
          "- [ ] Screenshots attached\n"

      assert phx_test_project()
             |> with_file(path, edited)
             |> Igniter.compose_task("ehos_app.install", [])
             |> content(path) == edited

      changed = earlier <> "- [ ] Screenshots attached\n"

      kept =
        phx_test_project()
        |> with_file(path, changed)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(kept, path) == changed

      assert Enum.any?(
               kept.notices,
               &(&1 =~ "#{path} is the project's own, and has no `## Review`")
             )
    end

    # The workflow reads a heading in a comment or in code as no section at all.
    test "reads the project's own pull request template as the review workflow reads a description" do
      path = ".github/pull_request_template.md"

      for {template, notice?} <- [
            {"## What\n\n<!--\n## Review\n-->\n", true},
            {"## What\n\n```md\n## Review\n```\n", true},
            {"## What\n\n## Review\n\n<!-- Fill this in. -->\n", false}
          ] do
        igniter =
          phx_test_project()
          |> with_file(path, template)
          |> Igniter.compose_task("ehos_app.install", [])

        assert Enum.any?(igniter.notices, &(&1 =~ "has no `## Review` section")) == notice?,
               template
      end
    end

    test "keeps a hook of the developer's that runs the review gate, without adding the template's" do
      settings = """
      {
        "hooks": {
          "PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "cd app && MIX_ENV=dev mix ehos_app.review gate"}]}
          ]
        }
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])

      hooks = igniter |> content(".claude/settings.json") |> JSON.decode!() |> Map.fetch!("hooks")

      assert [%{"hooks" => [%{"command" => "cd app && MIX_ENV=dev mix ehos_app.review gate"}]}] =
               hooks["PreToolUse"]
    end

    # The plugin is released by the tag the installer pins, so the two move together (T-15).
    test "pins the plugin by the tag of the version its plugin.json says" do
      %{name: name, ref: ref} = Install.plugin()

      version =
        "../../plugins/#{name}/.claude-plugin/plugin.json"
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("version")

      assert ref == "#{name}-v#{version}"
    end

    # Claude Code registers a marketplace under the name in its file, which has to be the key the
    # settings give it (T-16).
    test "names a marketplace file in ehos-tools that publishes the plugin under its marketplace's name" do
      %{name: name, marketplace: marketplace, path: path} = Install.plugin()
      manifest = "../../#{path}" |> File.read!() |> JSON.decode!()

      assert manifest["name"] == marketplace
      assert [%{"name" => ^name, "source" => source}] = manifest["plugins"]
      assert source == "./plugins/#{name}"
    end

    test "keeps the developer's settings in their order, and moves an earlier tag of the plugin" do
      settings = """
      {
        "permissions": {"allow": ["Bash(mix test:*)"]},
        "extraKnownMarketplaces": {
          "ehos-app": {
            "source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.0.1"}
          }
        }
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      written = content(igniter, ".claude/settings.json")
      decoded = JSON.decode!(written)

      assert written =~ ~r/\A\{\n  "permissions".*"extraKnownMarketplaces".*"enabledPlugins"/s
      assert decoded["permissions"] == %{"allow" => ["Bash(mix test:*)"]}

      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"] == %{
               "source" => "github",
               "repo" => "EmpoweredHouse/ehos-tools",
               "ref" => Install.plugin().ref,
               "path" => ".claude-plugin/ehos-app.json"
             }

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => true,
               "eh-os-contract@eh-os-contract" => true
             }

      igniter |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    # 0.9 named the plugin's marketplace ehos-tools, which EHOS's own repositories pin at another
    # tag (T-16).
    test "renames the marketplace 0.9 named ehos-tools to ehos-app, in its place" do
      written_by_09 =
        installed()
        |> content(".claude/settings.json")
        |> String.replace(~s|"ehos-app": {|, ~s|"ehos-tools": {|)
        |> String.replace(Install.plugin().ref, "ehos-app-v0.1.0")
        |> String.replace(~s|,\n        "path": ".claude-plugin/ehos-app.json"|, "")
        |> String.replace("ehos-app@ehos-app", "ehos-app@ehos-tools")

      assert written_by_09 =~ ~s|"ehos-tools": {|
      refute written_by_09 =~ "path"

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", written_by_09)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, ".claude/settings.json") ==
               installed() |> content(".claude/settings.json")

      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "keeps an ehos-tools marketplace of the developer's, and a plugin turned off there" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-dev-v0.4.0"}}
        },
        "enabledPlugins": {"ehos-dev@ehos-tools": true, "ehos-app@ehos-tools": false}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert decoded["extraKnownMarketplaces"]["ehos-tools"]["source"]["ref"] == "ehos-dev-v0.4.0"

      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["ref"] ==
               Install.plugin().ref

      assert decoded["enabledPlugins"] == %{
               "ehos-dev@ehos-tools" => true,
               "ehos-app@ehos-tools" => false,
               "ehos-app@ehos-app" => false,
               "eh-os-contract@eh-os-contract" => true
             }
    end

    test "turns the plugin off from ehos-app where the developer enables it from an ehos-tools of their own" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "MyOrg/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": true}
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])

      decoded = igniter |> content(".claude/settings.json") |> JSON.decode!()

      assert decoded["extraKnownMarketplaces"]["ehos-tools"]["source"]["repo"] ==
               "MyOrg/ehos-tools"

      assert decoded["enabledPlugins"]["ehos-app@ehos-tools"] == true
      assert decoded["enabledPlugins"]["ehos-app@ehos-app"] == false

      assert_has_notice(
        igniter,
        &(&1 =~ "MyOrg/ehos-tools" and &1 =~ "turn ehos-app@ehos-app on")
      )
    end

    test "keeps the marketplace 0.9 named ehos-tools for another plugin enabled from it" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": true, "ehos-dev@ehos-tools": true}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert decoded["extraKnownMarketplaces"]["ehos-tools"]["source"]["ref"] == "ehos-app-v0.1.0"

      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["ref"] ==
               Install.plugin().ref

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => true,
               "ehos-dev@ehos-tools" => true,
               "eh-os-contract@eh-os-contract" => true
             }
    end

    test "keeps a path the developer gave the ehos-app marketplace" do
      settings =
        ~s|{"extraKnownMarketplaces": {"ehos-app": {"source": {"source": "github", | <>
          ~s|"repo": "EmpoweredHouse/ehos-tools", "ref": "#{Install.plugin().ref}", | <>
          ~s|"path": ".claude-plugin/marketplace.json"}}}}\n|

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["path"] ==
               ".claude-plugin/marketplace.json"
    end

    test "drops the plugin's entry under ehos-tools where one under ehos-app is already there" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": false, "ehos-app@ehos-app": false}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert Map.keys(decoded["extraKnownMarketplaces"]) |> Enum.sort() == [
               "eh-os-contract",
               "ehos-app"
             ]

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => false,
               "eh-os-contract@eh-os-contract" => true
             }
    end

    test "renames the marketplace 0.9 named ehos-tools where a plugin turned off is the other one there" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": true, "ehos-dev@ehos-tools": false}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      refute Map.has_key?(decoded["extraKnownMarketplaces"], "ehos-tools")
      assert decoded["enabledPlugins"]["ehos-app@ehos-app"] == true
    end

    test "removes the marketplace 0.9 named ehos-tools where the template's ehos-app is there too" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}},
          "ehos-app": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "#{Install.plugin().ref}", "path": ".claude-plugin/ehos-app.json"}}
        }
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert Map.keys(decoded["extraKnownMarketplaces"]) |> Enum.sort() == [
               "eh-os-contract",
               "ehos-app"
             ]

      assert decoded["enabledPlugins"]["ehos-app@ehos-app"] == true
    end

    test "keeps the plugin on where it was on under ehos-tools and off under ehos-app" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": true, "ehos-app@ehos-app": false}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => true,
               "eh-os-contract@eh-os-contract" => true
             }
    end

    test "writes the developer's settings with their own indent and line ends" do
      settings = "{\r\n\t\"permissions\": {\r\n\t\t\"allow\": []\r\n\t}\r\n}\r\n"

      written =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content(".claude/settings.json")

      assert written =~
               ~r/\A\{\r\n\t"permissions": \{\r\n\t\t"allow": \[\]\r\n\t\},\r\n\t"extraKnownMarketplaces": \{\r\n\t\t"ehos-app"/

      refute written =~ ~r/[^\r]\n/
      assert String.ends_with?(written, "}\r\n")
    end

    test "leaves settings that already enable every plugin as they are, however they are laid out" do
      igniter = installed()

      compact =
        igniter
        |> content(".claude/settings.json")
        |> Jason.decode!(objects: :ordered_objects)
        |> Jason.encode!()

      again =
        igniter
        |> replace_file(".claude/settings.json", compact)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(again, ".claude/settings.json") == compact
    end

    # 0.9.0's settings name eh-os-contract's plugin at a tag a later version moves.
    test "moves an earlier tag of eh-os-contract's plugin, and keeps a later one" do
      for {ref, moved?} <- [
            {"eh-os-contract-plugin-v0.0.1", true},
            {"eh-os-contract-plugin-v99.0.0", false}
          ] do
        settings =
          ~s|{"extraKnownMarketplaces": {"eh-os-contract": {"source": | <>
            ~s|{"source": "github", "repo": "EmpoweredHouse/eh-os-contract", "ref": "#{ref}"}}}}\n|

        igniter =
          phx_test_project()
          |> with_file(".claude/settings.json", settings)
          |> Igniter.compose_task("ehos_app.install", [])

        decoded = igniter |> content(".claude/settings.json") |> JSON.decode!()
        kept? = Enum.any?(igniter.notices, &(&1 =~ "the marketplace eh-os-contract as"))
        assert kept? == not moved?

        %{ref: pinned} = plugin("eh-os-contract")
        expected = if moved?, do: pinned, else: ref
        assert decoded["extraKnownMarketplaces"]["eh-os-contract"]["source"]["ref"] == expected
      end
    end

    test "keeps a marketplace pinned to another ref, and a plugin the developer turned off" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-app": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "main"}}
        },
        "enabledPlugins": {"ehos-app@ehos-app": false}
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])

      decoded = igniter |> content(".claude/settings.json") |> JSON.decode!()
      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["ref"] == "main"

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => false,
               "eh-os-contract@eh-os-contract" => true
             }

      assert Enum.any?(igniter.notices, &(&1 =~ "EmpoweredHouse/ehos-tools at main"))
    end

    test "keeps a later release of the plugin, and a marketplace on another repository" do
      for {repo, ref} <- [
            {"EmpoweredHouse/ehos-tools", "ehos-app-v99.0.0"},
            {"someone/ehos-tools", "ehos-app-v0.0.1"}
          ] do
        settings =
          ~s|{"extraKnownMarketplaces": {"ehos-app": {"source": | <>
            ~s|{"source": "github", "repo": "#{repo}", "ref": "#{ref}"}}}}\n|

        igniter =
          phx_test_project()
          |> with_file(".claude/settings.json", settings)
          |> Igniter.compose_task("ehos_app.install", [])

        decoded = igniter |> content(".claude/settings.json") |> JSON.decode!()
        assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["ref"] == ref
        assert Enum.any?(igniter.notices, &(&1 =~ "so the\ninstaller kept it"))
      end
    end

    test "leaves settings of another shape alone, and says what to add" do
      for settings <- [
            ~s|{"extraKnownMarketplaces": false}\n|,
            ~s|{"extraKnownMarketplaces": {"ehos-app": {"source": {"ref": {"tag": "x"}}}}}\n|,
            ~s|{"extraKnownMarketplaces": []}\n|,
            ~s|{"extraKnownMarketplaces": {"ehos-app": "x"}}\n|,
            ~s|{"enabledPlugins": true}\n|,
            ~s|{"extraKnownMarketplaces": {"eh-os-contract": {"source": {"ref": 1}}}}\n|,
            ~s|{"hooks": []}\n|,
            ~s|{"hooks": {"PreToolUse": {}}}\n|,
            ~s|{"hooks": {"PreToolUse": ["x"]}}\n|
          ] do
        igniter =
          phx_test_project()
          |> with_file(".claude/settings.json", settings)
          |> Igniter.compose_task("ehos_app.install", [])

        assert content(igniter, ".claude/settings.json") == settings
        assert Enum.any?(igniter.warnings, &(&1 =~ ~s|"ehos-app@ehos-app": true|))
      end
    end

    test "leaves settings that are not a JSON object alone, and says what to add" do
      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", "[]\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, ".claude/settings.json") == "[]\n"
      assert Enum.any?(igniter.warnings, &(&1 =~ ~s|"ehos-app@ehos-app": true|))
    end

    # 0.3.0 to 0.8.1 copied the skills into .agents/skills and linked them from .claude/skills.
    test "removes the skills an earlier version copied, unless changed, and unlinks them" do
      fixtures = "test/fixtures/skills_0.8.1"

      project =
        fixtures
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&String.ends_with?(&1, "/plan/SKILL.md"))
        |> Enum.reduce(phx_test_project(), fn file, igniter ->
          path = Path.join(".agents/skills", Path.relative_to(file, fixtures))
          with_file(igniter, path, File.read!(file))
        end)
        |> with_file(".agents/skills/plan/SKILL.md", "# Our plan\n")
        |> with_file(".agents/skills/ship/notes.md", "# Ours\n")

      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      for file <- [
            "ship/SKILL.md",
            "review/references/checklist.md",
            "elixir-anti-patterns-review/LICENSE"
          ],
          do: assert(".agents/skills/#{file}" in igniter.rms)

      refute ".agents/skills/plan/SKILL.md" in igniter.rms
      refute ".agents/skills/ship/notes.md" in igniter.rms
      assert {"ehos_app.unlink_skills", []} in igniter.tasks
      assert Enum.any?(igniter.notices, &(&1 =~ "* .agents/skills/plan/SKILL.md"))

      again = igniter |> apply_igniter!() |> Igniter.compose_task("ehos_app.install", [])
      refute {"ehos_app.unlink_skills", []} in again.tasks
    end

    # The LICENSE was released with no newline at its end; a project has it with one.
    test "removes the skill's LICENSE as a project has it, with a newline at its end" do
      license = File.read!("test/fixtures/skills_0.8.1/elixir-anti-patterns-review/LICENSE")
      refute String.ends_with?(license, "\n")

      igniter =
        phx_test_project()
        |> with_file(".agents/skills/elixir-anti-patterns-review/LICENSE", license <> "\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert ".agents/skills/elixir-anti-patterns-review/LICENSE" in igniter.rms
    end

    test "writes an Apache-2.0 LICENSE in the company's name, and keeps one of the project's own" do
      igniter = install()
      license = content(igniter, "LICENSE")

      assert license =~ ~r/\A\s+Apache License\n\s+Version 2\.0, January 2004\n/
      assert license =~ "Copyright #{Date.utc_today().year} Empowered House PSA\n"
      assert Enum.any?(igniter.notices, &(&1 =~ "LICENSE is the Apache License 2.0"))
      assert content(igniter, "README.md") =~ "See [LICENSE](LICENSE)."

      own = with_file("LICENSE", "MIT\n") |> Igniter.compose_task("ehos_app.install", [])
      assert content(own, "LICENSE") == "MIT\n"
      refute Enum.any?(own.notices, &(&1 =~ "LICENSE is the Apache License 2.0"))
    end

    test "licenses no project an earlier version generated without a LICENSE" do
      igniter =
        with_file("ehos.yaml", "schema: ehos.yaml/v2\n")
        |> Igniter.compose_task("ehos_app.install", [])

      refute Igniter.exists?(igniter, "LICENSE")
      refute content(igniter, "README.md") =~ "LICENSE"
    end

    test "ignores .plans/, once" do
      igniter =
        with_file(".gitignore", "/_build/\n")
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, ".gitignore") =~
               ~r/\A\/_build\/\n\n# Working plans.*\n\/\.plans\/\n\z/
    end

    test "names the design system in managed sections alone" do
      igniter = installed(["--example"])

      paths =
        Enum.map(@managed, &elem(&1, 0)) ++
          ["ARCHITECTURE.md", "TESTING.md", ".github/pull_request_template.md"]

      named =
        for path <- paths,
            content = content(igniter, path),
            unmanaged =
              Enum.reduce(@managed, content, &String.replace(&2, section(elem(&1, 1)), "")),
            content =~ Install.design_system(),
            do: {path, unmanaged =~ Install.design_system()}

      assert {"AGENTS.md", false} in named
      assert {"lib/test_web/AGENTS.md", false} in named
      assert Enum.all?(named, &(elem(&1, 1) == false))
    end

    test "writes docs whose relative links resolve in the project" do
      igniter = installed(["--example"])
      files = Map.keys(igniter.assigns.test_files)

      dangling =
        for doc <- files,
            String.ends_with?(doc, ".md"),
            [_, target] <- Regex.scan(~r/\]\(([^)\s]+)\)/, content(igniter, doc)),
            not String.match?(target, ~r/\A(https?|mailto):|\A#/),
            path = target |> String.split("#") |> hd() |> Path.expand("/" <> Path.dirname(doc)),
            path = String.trim_leading(path, "/"),
            not Enum.any?(files, &(&1 == path or String.starts_with?(&1, path <> "/"))),
            do: "#{doc} -> #{target}"

      assert dangling == []
    end

    test "keeps each guide within the budget the harness test holds it to" do
      igniter = installed(["--example"])

      for {path, _} <- @managed do
        lines = igniter |> content(path) |> String.split("\n") |> length()
        budget = Map.get(@budgets, path, 200)
        assert lines <= budget, "#{path}: #{lines} lines (budget #{budget})"
      end
    end
  end

  describe "the design system" do
    test "adds ehos_design from ehos-tools, pinned to the commit of its release" do
      assert installed() |> content("mix.exs") =~
               ~r/\{:ehos_design, "~> 0\.2\.0",\s+github: "EmpoweredHouse\/ehos-tools",\s+sparse: "packages\/ehos_design",\s+ref: "[0-9a-f]{40}"\}/
    end

    test "imports its layer right after Tailwind, in place of Phoenix's two daisyUI themes" do
      css = installed() |> content("assets/css/app.css")

      assert css =~
               ~r/@import "tailwindcss" source\(none\);\n\n\/\* ehos_app:design-system: the EmpoweredHouse design system.*?\*\/\n@import "\.\.\/\.\.\/deps\/ehos_design\/packages\/ehos_design\/priv\/css\/ehos_design\.css";\n/s

      refute css =~ "daisyui-theme"
      refute css =~ "daisyUI theme plugin"
      assert css =~ ~r/@plugin "[^"]*daisyui" \{\s+themes: false;\s+\}/
      assert css =~ ~r/\/\* ehos_app:own-styles: this application's own styles\..*\*\/\n\z/s
    end

    # eh-os D-86: the components render utilities Tailwind finds only in their templates. After
    # Phoenix's own sources, since no rule may come before Phoenix's second `@import`.
    test "names the design system's components' templates as a source for Tailwind" do
      css = installed() |> content("assets/css/app.css")

      assert css =~
               ~r|@source "\.\./\.\./lib/test_web";\n@source "\.\./\.\./deps/ehos_design/packages/ehos_design/lib";\n|
    end

    # eh-os D-86: the components' keyboard is a colocated hook of the package's.
    test "gives the LiveSocket the design system's hooks beside the application's own" do
      js = installed() |> content("assets/js/app.js")

      assert js =~
               ~s|import {hooks as colocatedHooks} from "phoenix-colocated/test"\n| <>
                 ~s|import {hooks as designHooks} from "phoenix-colocated/ehos_design"\n|

      assert js =~ "hooks: {...colocatedHooks, ...designHooks}"
    end

    test "gives no hooks to a project that pinned the design system itself, at its own version" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep({:ehos_design, "~> 0.1.0", path: "../ehos_design"})
        |> Igniter.compose_task("ehos_app.install", [])

      refute content(igniter, "assets/js/app.js") =~ "phoenix-colocated/ehos_design"
    end

    test "says where to name the components' templates when Phoenix's source is not there" do
      igniter =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", fn source ->
          Rewrite.Source.update(source, :content, fn css ->
            String.replace(css, ~r/^@source "\.\.\/\.\.\/lib\/[a-z_]+";\n/m, "")
          end)
        end)
        |> Igniter.compose_task("ehos_app.install", [])

      refute content(igniter, "assets/css/app.css") =~ "packages/ehos_design/lib"
      assert Enum.any?(igniter.notices, &(&1 =~ "were not named as a source for Tailwind"))
    end

    test "leaves a script that is not Phoenix's alone, and says what to add" do
      igniter =
        phx_test_project()
        |> replace_file("assets/js/app.js", "console.log(\"mine\")\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "assets/js/app.js") == "console.log(\"mine\")\n"

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "design system's components' hooks were not added")
             )
    end

    # A project that has the design system keeps the version it pinned, which may have no hooks.
    test "gives a project that has the design system already no hooks" do
      installed = installed()

      js =
        installed
        |> content("assets/js/app.js")
        |> String.replace(
          ~s|import {hooks as designHooks} from "phoenix-colocated/ehos_design"\n|,
          ""
        )
        |> String.replace(", ...designHooks", "")

      again =
        phx_test_project()
        |> replace_file("assets/css/app.css", content(installed, "assets/css/app.css"))
        |> replace_file("assets/js/app.js", js)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(again, "assets/js/app.js") == js
    end

    @root_layout "lib/test_web/components/layouts/root.html.heex"

    test "preloads the two faces of Albert Sans the text is set in, before the stylesheet" do
      root = installed() |> content(@root_layout)

      # As Phoenix's HEEx formatter writes them, indented as the stylesheet's link is.
      preload = fn weight ->
        """
            <link
              rel="preload"
              href="/ehos_design/fonts/albert-sans-latin-#{weight}-normal.woff2"
              as="font"
              type="font/woff2"
              crossorigin
            />
        """
      end

      assert root =~
               preload.(400) <>
                 preload.(500) <>
                 ~s|    <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />|

      for file <- ["albert-sans-latin-400-normal.woff2", "albert-sans-latin-500-normal.woff2"] do
        assert File.exists?(Path.join(["../ehos_design/priv/static/ehos_design/fonts", file]))
      end
    end

    test "leaves the root layout alone once the design system is installed" do
      igniter = installed()
      root = content(igniter, @root_layout)
      without = String.replace(root, ~r{\n *<link\n *rel="preload".*?/>}s, "")

      again =
        igniter
        |> Igniter.update_file(
          @root_layout,
          &Rewrite.Source.update(&1, :content, fn _ -> without end)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert without != root
      assert content(again, @root_layout) == without
    end

    test "says how to preload the fonts when the root layout is not Phoenix's" do
      igniter =
        phx_test_project()
        |> Igniter.update_file(
          @root_layout,
          &Rewrite.Source.update(&1, :content, fn _ -> "<html><head></head></html>\n" end)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, @root_layout) == "<html><head></head></html>\n"
      assert Enum.any?(igniter.notices, &(&1 =~ "fonts are not preloaded"))
    end

    test "preloads nothing when the design system was not imported, on any run" do
      project =
        phx_test_project()
        |> Igniter.update_file(
          "assets/css/app.css",
          &Rewrite.Source.update(&1, :content, fn _ -> "body { margin: 0; }\n" end)
        )
        |> apply_igniter!()

      # What the run changes in the root layout besides the preloads: the way in and out, and
      # the title without Phoenix's suffix.
      root_before =
        project
        |> content(@root_layout)
        |> String.replace(
          "  <body>\n",
          "  <body>\n    <TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\n"
        )
        |> String.replace(~s| suffix=" · Phoenix Framework"|, "")

      roots =
        for run <- [1, 2] do
          installed =
            Enum.reduce(1..run, project, fn _run, igniter ->
              igniter |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()
            end)

          root = content(installed, @root_layout)
          refute root =~ "ehos_design/fonts/", "run #{run}"
          root
        end

      assert roots == [root_before, root_before]
    end

    test "writes the preloads in a CRLF layout's own line endings" do
      igniter =
        phx_test_project()
        |> Igniter.update_file(
          @root_layout,
          &Rewrite.Source.update(&1, :content, fn content ->
            String.replace(content, "\n", "\r\n")
          end)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      root = content(igniter, @root_layout)

      assert root =~ "albert-sans-latin-400-normal.woff2"
      assert root =~ "<body>\r\n    <TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\r\n"
      refute root =~ ~r/[^\r]\n/
    end

    test "points the import at the stylesheet where the sparse dependency puts it" do
      assert Path.join([Install.design_system(), "priv/css/ehos_design.css"]) ==
               "deps/ehos_design/packages/ehos_design/priv/css/ehos_design.css"
    end

    test "keeps a daisyUI theme of the developer's own" do
      own = """
      @plugin "daisyui/packages/bundle/daisyui-theme" {
        name: "brand";
        default: true;
      }
      """

      css =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", fn source ->
          Rewrite.Source.update(source, :content, &(&1 <> "\n" <> own))
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("assets/css/app.css")

      assert css =~ own
      refute css =~ ~s|name: "dark"|
    end

    test "leaves a stylesheet without Tailwind's import alone, and says what to add" do
      install =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", fn source ->
          Rewrite.Source.update(source, :content, fn _ -> "body { margin: 0; }\n" end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert_has_warning(install, &(&1 =~ "so the design system was not imported"))

      installed = apply_igniter!(install)
      assert content(installed, "assets/css/app.css") == "body { margin: 0; }\n"

      development = content(installed, "DEVELOPMENT.md")
      assert development =~ "which `assets/css/app.css` does not import yet"
      refute development =~ "only imports it"

      assert development =~
               "CI reads the private `eh_os_contract` and `ehos_design`, and installs"

      architecture = content(installed, "ARCHITECTURE.md")

      assert architecture =~
               ~s|the installer found no line there starting `@import "tailwindcss"`|

      assert architecture =~ "which hooks to register in `assets/js/app.js`"
      refute architecture =~ "registers its components' hooks"
      refute content(installed, "lib/test_web/AGENTS.md") =~ "`assets/css/app.css` imports it"
    end

    # eh-os D-135: Req reads none of the variables EHOS gives for a host outside the installation.
    test "says how a host outside the installation is named and reached" do
      architecture = content(installed(), "ARCHITECTURE.md")

      assert architecture =~ "| `EHOS_EGRESS_PROXY`, `HTTPS_PROXY`, `NO_PROXY` |"
      assert architecture =~ "A host is named under `needs.egress`"
      assert architecture =~ "|> EhOsContract.Auth.Egress.attach()"
    end

    # eh-os D-140: an application asks for mail, is agreed it, and sends it as itself.
    test "says how the application asks for mail, sends it, and reads the answers" do
      architecture = content(installed(), "ARCHITECTURE.md")

      assert architecture =~
               "under `needs.mail` in `ehos.yaml`, which takes it from `schema: ehos.yaml/v6`"

      assert architecture =~ "`ehos.mail.manage`"
      assert architecture =~ "EhOsContract.Auth.Mail.deliver("
      assert architecture =~ "EHOS receives no mail."
    end

    test "says the design system is imported where it is" do
      igniter = installed()

      assert content(igniter, "DEVELOPMENT.md") =~ "and `assets/css/app.css` only imports it"

      assert content(igniter, "ARCHITECTURE.md") =~
               "after Tailwind, and `assets/js/app.js` registers its components' hooks"

      refute content(igniter, "ARCHITECTURE.md") =~ "does not import it yet"
      assert content(igniter, "lib/test_web/AGENTS.md") =~ "`assets/css/app.css` imports it"
    end

    test "serves its fonts from the application's own origin, after Phoenix's static files" do
      endpoint = installed() |> content("lib/test_web/endpoint.ex")

      assert endpoint =~
               ~r/plug\(?Plug\.Static,\s+at: "\/",\s+from: :test,.*?only: TestWeb\.static_paths\(\),[^)]*\)?\n\n.*?plug\(?Plug\.Static,\s+at: "\/",\s+from: \{:ehos_design, "priv\/static"\},\s+gzip: false,\s+only: ~w\(ehos_design\),\s+cache_control_for_etags: "public, max-age=86400"\)?/s
    end

    test "with --example, shows itself on a page of its own, in the browser pipeline, tested" do
      igniter = installed(["--example"])

      assert content(igniter, "lib/test_web/live/design_system_live.ex") =~
               "use TestWeb, :live_view"

      assert content(igniter, "test/test_web/live/design_system_live_test.exs") =~
               "use TestWeb.ConnCase, async: true"

      assert content(igniter, "lib/test_web/router.ex") =~
               ~r/scope "\/", TestWeb do\s+pipe_through\(?:browser\)?\s+get\(?"\/", PageController, :home\)?\s+live\(?"\/design-system", DesignSystemLive\)?/
    end

    # Declined as the comment says, and as the comment is likely to go: with the import, with the
    # comment above it, or by commenting the import out. Each time the developer also removes the
    # dependency and the fonts' plug, and restores Phoenix's light theme.
    for {how, kind} <- [
          {"removing the import", :import},
          {"removing the import and the comment above it", :import_and_comment},
          {"commenting the import out", :comment_out}
        ] do
      test "never brings back a design system the developer declined by #{how}" do
        igniter = installed(["--example"])
        css = content(igniter, "assets/css/app.css")

        declined =
          decline(css, unquote(kind)) <>
            """

            @plugin "daisyui/packages/bundle/daisyui-theme" {
              name: "light";
              default: true;
              --color-base-100: oklch(98% 0 0);
            }
            """

        assert decline(css, unquote(kind)) != css, "the test's own edit did not apply"
        refute declined =~ ~r/^@import "[^"]*ehos_design\.css";$/m

        again =
          igniter
          |> Igniter.update_file(
            "assets/css/app.css",
            &Rewrite.Source.update(&1, :content, fn _ -> declined end)
          )
          |> Igniter.update_file("mix.exs", fn source ->
            Rewrite.Source.update(
              source,
              :content,
              &String.replace(&1, ~r/\{:ehos_design,.*?\},\n/s, "")
            )
          end)
          |> Igniter.update_file("lib/test_web/endpoint.ex", fn source ->
            Rewrite.Source.update(
              source,
              :content,
              &String.replace(&1, "{:ehos_design", "{:somewhere_else")
            )
          end)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", ["--example"])
          |> apply_igniter!()

        assert content(again, "assets/css/app.css") == declined
        refute content(again, "mix.exs") =~ ":ehos_design"
        refute content(again, "lib/test_web/endpoint.ex") =~ "{:ehos_design"

        assert content(again, "lib/test_web/AGENTS.md") =~
                 "declined the EmpoweredHouse design system"

        refute content(again, "lib/test_web/AGENTS.md") =~ "bg-surface-1"

        development = content(again, "DEVELOPMENT.md")
        assert development =~ "CI reads the private `eh_os_contract`, and installs `ehosctl`"
        assert development =~ "a fine-grained token that reads eh-os-contract alone"
      end
    end

    test "keeps a Phoenix theme the developer changed in one colour alone" do
      branded = fn css ->
        String.replace(
          css,
          "--color-primary: oklch(70% 0.213 47.604);",
          "--color-primary: oklch(55% 0.2 140);"
        )
      end

      css =
        phx_test_project()
        |> Igniter.update_file(
          "assets/css/app.css",
          &Rewrite.Source.update(&1, :content, branded)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("assets/css/app.css")

      assert css =~ "--color-primary: oklch(55% 0.2 140);"
      assert css =~ ~s|name: "light"|
      refute css =~ ~s|name: "dark"|
    end

    test "keeps a dark or light theme the developer has tuned, and says it covers the design system" do
      tuned = fn css ->
        String.replace(
          css,
          "--color-base-100: oklch(30.33% 0.016 252.42);",
          "--color-base-100: oklch(20% 0 0);"
        )
      end

      install =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", &Rewrite.Source.update(&1, :content, tuned))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      css = install |> apply_igniter!() |> content("assets/css/app.css")

      assert css =~ "--color-base-100: oklch(20% 0 0);"
      refute css =~ "--color-base-100: oklch(98% 0 0);"
      assert Enum.any?(install.notices, &(&1 =~ "keeps a daisyUI theme of the project's own"))
    end

    test "keeps the version of ehos_design the developer has moved to" do
      mix =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_design, "~> 0.2.0",
           github: "EmpoweredHouse/ehos-tools",
           sparse: "packages/ehos_design",
           tag: "ehos_design-v0.2.0"}
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("mix.exs")

      assert mix =~ ~s|tag: "ehos_design-v0.2.0"|
      refute mix =~ ~r/ehos_design.*ref:/s
    end

    test "writes the page once, and leaves one the developer has alone, wherever it is" do
      moved =
        phx_test_project()
        |> Igniter.create_new_file("lib/test_web/design_system_live.ex", """
        defmodule TestWeb.DesignSystemLive do
          use TestWeb, :live_view
        end
        """)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--example"])
        |> apply_igniter!()

      # Igniter's test project moves a module to its proper location, so it is found by name.
      defining =
        for {path, source} <- moved.assigns.test_files,
            String.ends_with?(path, ".ex"),
            source =~ "defmodule TestWeb.DesignSystemLive do",
            do: source

      assert [ours] = defining
      refute ours =~ "@moduledoc"
      assert content(moved, "lib/test_web/router.ex") =~ "DesignSystemLive"
    end

    test "routes the page although the router mentions it in a comment, and keeps a route of the developer's" do
      with_router = fn edit ->
        phx_test_project()
        |> Igniter.update_file(
          "lib/test_web/router.ex",
          &Rewrite.Source.update(&1, :content, edit)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--example"])
        |> apply_igniter!()
        |> content("lib/test_web/router.ex")
      end

      commented =
        with_router.(
          &String.replace(
            &1,
            "  pipeline :browser do",
            "  # DesignSystemLive goes here.\n  pipeline :browser do"
          )
        )

      assert commented =~ ~r/live\(?"\/design-system", DesignSystemLive\)?/

      # The in-memory project formats without Phoenix's `locals_without_parens`.
      moved =
        with_router.(
          &Regex.replace(
            ~r/^(\s*)get\(?"\/", PageController, :home\)?$/m,
            &1,
            ~s|\\0\n\\1live "/look", DesignSystemLive|
          )
        )

      assert moved =~ "/look", "the test's own edit did not apply"

      assert moved =~ ~r/live\(?"\/look", DesignSystemLive\)?/
      refute moved =~ "/design-system"
    end

    test "without --example, adds no page" do
      igniter = installed()

      refute Igniter.exists?(igniter, "lib/test_web/live/design_system_live.ex")
      refute content(igniter, "lib/test_web/router.ex") =~ "DesignSystemLive"
    end
  end

  describe "--example" do
    test "generates a domain named as the application is in EHOS, a contract and its implementation" do
      igniter = installed(["--example"])

      assert content(igniter, "lib/test/domain.ex") =~
               "use EhOsContract.Domain, name: :test, language: :en"

      assert content(igniter, "lib/test/contracts/entries.ex") =~
               "use EhOsContract.Contract, domain: Test.Domain, context: :entries"

      assert content(igniter, "lib/test/entries/entry.ex") =~
               "use Test.Contracts.Entries, aggregate: :entry"

      assert content(igniter, "test/test_web/entries_api_test.exs") =~
               "assert_every_entry_refuses([Test.Contracts.Entries]"
    end

    # eh_os_contract's `word-without-term` notes each word of a context's names of things that no
    # term of the context's glossary covers: without one, a new project's first check says
    # 1 notice (#125). eh_os_contract is not a dependency of ehos_app, so this models that one
    # rule as eh_os_contract 0.3.0 has it; the whole check, 0 errors, 0 warnings, 0 notices,
    # runs only in a generated project, as CI's `e2e` job makes one.
    test "gives the domain a term for every word the example contract names a thing with" do
      igniter = installed(["--example"])

      terms =
        igniter
        |> content("lib/test/domain.ex")
        |> calls(:term)
        |> Enum.map(fn [text | _] -> code_words(text) end)

      names =
        igniter
        |> content("lib/test/contracts/entries.ex")
        |> names_of_things()

      assert [:entry | _] = names
      assert :amount in names
      assert untermed(names, terms) == []

      # A term covers its words only where they stand in a name in a row.
      assert untermed([:amount], [["entry", "amount"]]) == ["amount"]
      assert untermed([:entry_amount], [["entry", "amount"]]) == []
    end

    test "says that the caller gives an entry's identity, a fresh one" do
      contract = installed(["--example"]) |> content("lib/test/contracts/entries.ex")

      assert contract =~ "The caller gives the entry's identity"
      assert contract =~ "Give each new entry a fresh id"
    end

    test "serves the contract under /api, behind the credential check" do
      router = installed(["--example"]) |> content("lib/test_web/router.ex")

      # The in-memory project formats without Phoenix's `locals_without_parens`.
      assert router =~
               ~r/pipeline :commands do\s+plug\(?:accepts, \["json"\]\)?\s+plug\(?EhOsContract.Auth.Plug\)?\s+end/

      assert router =~
               ~r/scope "\/api" do\s+pipe_through\(?:commands\)?\s+forward\(?"\/", EhOsContract.Plug, contracts: \[Test.Contracts.Entries\]/
    end

    test "writes nothing of it unless asked" do
      igniter = installed()

      refute Igniter.exists?(igniter, "lib/test/domain.ex")
      refute content(igniter, "lib/test_web/router.ex") =~ "EhOsContract.Plug"
    end

    test "publishes a recorded entry under the application's name" do
      assert installed(["--example"]) |> content("lib/test/contracts/entries.ex") =~
               ~s|as: "test.entry.recorded.v1"|
    end

    test "names the example contract's id under the application's name, as the engine requires" do
      assert installed(["--example"]) |> content("lib/test/contracts/entries.ex") =~
               ~s|context: :entries, id: "test.entries"|

      igniter =
        [app_name: :my_shop]
        |> phx_test_project()
        |> Igniter.compose_task("ehos_app.install", ["--example"])
        |> apply_igniter!()

      assert content(igniter, "lib/my_shop/contracts/entries.ex") =~ ~s|id: "my-shop.entries"|
    end

    test "publishes under the name EHOS gives the application, a dash included" do
      igniter =
        [app_name: :my_shop]
        |> phx_test_project()
        |> Igniter.compose_task("ehos_app.install", ["--example"])
        |> apply_igniter!()

      assert content(igniter, "lib/my_shop/contracts/entries.ex") =~
               ~s|as: "my-shop.entry.recorded.v1"|

      refute Enum.any?(igniter.warnings, &(&1 =~ "publishes nothing"))
    end

    test "names EHOS's application with dashes, which allow no underscore" do
      assert Install.ehos_name(:my_shop) == "my-shop"
      assert Install.ehos_name(:shop) == "shop"
    end
  end

  # `ehosctl init` runs the installer with `--example`, and an upgrade runs it without.
  test "an upgrade's run without --example changes nothing in a project made with it" do
    install(["--example"])
    |> apply_igniter!()
    |> Igniter.compose_task("ehos_app.install", [])
    |> assert_unchanged()
  end

  test "is idempotent: a second run changes nothing" do
    for argv <- [[], ["--example"]] do
      igniter =
        install(argv)
        |> apply_igniter!()
        |> Igniter.create_new_file("Dockerfile", "# changed by the developer\n")
        # What the first run's `eh_os_contract.schema` writes, which the test project does not run.
        |> then(fn igniter ->
          if argv == [],
            do: igniter,
            else: Igniter.create_new_file(igniter, "eh_os_contract.lock", "%{}\n")
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", argv)
        |> assert_unchanged()

      # `assert_unchanged/1` reads files only; a task would still rewrite the Dockerfile.
      assert igniter.tasks == []
    end
  end

  test "pins the toolchain it ran under" do
    {:ok, [erlang: erlang, elixir: elixir]} = EhosApp.Toolchain.current()

    install()
    |> assert_creates(".tool-versions", """
    erlang #{erlang}
    elixir #{elixir}
    """)
  end

  test "never overwrites a file the developer changed, even one Igniter has not read yet" do
    # `.tool-versions` is outside the test project's `**/*.*`, so Igniter has not read it, as
    # in a real project on a second run.
    igniter =
      installed()
      |> Igniter.create_or_update_file(".tool-versions", "erlang 99\n", fn source ->
        Rewrite.Source.update(source, :content, fn _ -> "erlang 99\n" end)
      end)
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])

    assert content(igniter, ".tool-versions") == "erlang 99\n"
  end

  test "uses the project's repo, whatever it is called" do
    igniter =
      test_project()
      |> Igniter.create_new_file("lib/test/store.ex", """
      defmodule Test.Store do
        use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres
      end
      """)
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> apply_igniter!()

    assert content(igniter, "config/config.exs") =~ "repo: Test.Store"

    assert igniter.rewrite
           |> Enum.map(&Rewrite.Source.get(&1, :path))
           |> Enum.any?(&(&1 =~ ~r|\Apriv/store/migrations/\d{14}_add_eh_os_contract\.exs\z|))
  end

  test "refuses a project without a repo, rather than guessing one" do
    igniter =
      test_project()
      |> Igniter.compose_task("ehos_app.install", [])

    assert [issue] = igniter.issues
    assert issue =~ "No Ecto repo found"
  end

  defp ehos_yaml(igniter), do: igniter |> content("ehos.yaml") |> YamlElixir.read_from_string!()

  defp installed_with_warnings, do: install() |> Map.fetch!(:warnings)

  # A file of the test project, as the developer has it before the installer runs.
  defp replace_file(igniter, path, content) do
    Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, fn _ -> content end))
  end

  # A file of the test project as it is, unformatted, read in as one already on disk.
  defp with_file(igniter, path, content) do
    igniter
    |> Igniter.assign(:test_files, Map.put(igniter.assigns.test_files, path, content))
    |> Igniter.include_existing_file(path)
  end

  # The children of an application module, as written.
  defp children(application) do
    [_, rest] = String.split(application, "children = [", parts: 2)
    [children, _] = String.split(rest, "\n    ]", parts: 2)
    children
  end

  defp migrations(igniter, name) do
    igniter.rewrite
    |> Enum.map(&Rewrite.Source.get(&1, :path))
    |> Enum.filter(&(&1 =~ ~r|\Apriv/repo/migrations/\d{14}_#{name}\.exs\z|))
  end

  # The runtime configuration an earlier version wrote: the sign-in block taken out.
  defp without_sign_in(zipper) do
    case Igniter.Code.Function.move_to_function_call(zipper, :if, 2, &sign_in_block?/1) do
      {:ok, call} ->
        call |> Sourceror.Zipper.remove() |> Sourceror.Zipper.root() |> Sourceror.Zipper.zip()

      :error ->
        zipper
    end
  end

  defp sign_in_block?(call) do
    Igniter.Code.Function.argument_matches_predicate?(call, 0, fn condition ->
      condition |> Sourceror.Zipper.node() |> Sourceror.to_string() =~ "EHOS_SIGN_IN_APPLICATIONS"
    end)
  end

  # The sign-in block of a runtime configuration, as written.
  defp sign_in_block(runtime) do
    {:ok, call} =
      runtime
      |> Sourceror.parse_string!()
      |> Sourceror.Zipper.zip()
      |> Igniter.Code.Function.move_to_function_call(:if, 2, fn call ->
        Igniter.Code.Function.argument_matches_predicate?(call, 0, fn condition ->
          condition |> Sourceror.Zipper.node() |> Sourceror.to_string() =~
            "EHOS_SIGN_IN_APPLICATIONS"
        end)
      end)

    call |> Sourceror.Zipper.node() |> Sourceror.to_string()
  end

  # The configuration `block` makes in production with exactly `env` of the variables it reads,
  # read from a map in place of the process's environment, which the other tests share.
  defp read_runtime(block, env) do
    script =
      block
      |> String.replace("System.get_env(", "Map.get(env, ")
      |> String.replace("System.fetch_env!(", "Map.fetch!(env, ")

    refute script =~ "System."

    Config.Reader.eval!("config/runtime.exs", "import Config\nenv = #{inspect(env)}\n" <> script,
      env: :prod
    )
  end

  # The sign-in block as ehos_app 0.21.0 and earlier wrote it, on whether EHOS gives a client.
  defp earlier_sign_in_condition(runtime) do
    runtime
    |> String.replace(
      ~s|if ehos_sign_in_applications = System.get_env("EHOS_SIGN_IN_APPLICATIONS") do|,
      ~s|if ehos_client_id = System.get_env("EHOS_CLIENT_ID") do|
    )
    |> String.replace(~s|System.fetch_env!("EHOS_CLIENT_ID")|, "ehos_client_id")
    |> String.replace(
      "Jason.decode!(ehos_sign_in_applications)",
      ~s|Jason.decode!(System.get_env("EHOS_SIGN_IN_APPLICATIONS", "{}"))|
    )
  end

  # What `word-without-term` reads of a contract, as eh_os_contract 0.3.0's `CodeWords.names/1`
  # does: the names of its units (aggregates and DCBs), its read models and its fields, but not
  # its commands and events, a unit's identity, or a field typed `{:id, entity}`.
  defp names_of_things(contract) do
    for [name | rest] <- calls(contract, [:aggregate, :dcb, :read_model, :field]),
        not match?([{:id, _} | _], rest),
        do: name
  end

  # Each word of more than two letters, of the `names`, that no term (as its words) covers
  # where it stands whole and in order in the name.
  defp untermed(names, terms) do
    for name <- names,
        words = code_words(name),
        covered = Enum.flat_map(terms, &covered_positions(words, &1)),
        {word, position} <- Enum.with_index(words),
        position not in covered,
        String.length(word) > 2,
        uniq: true,
        do: word
  end

  defp covered_positions(words, term) do
    size = length(term)

    for start <- 0..(length(words) - size)//1,
        Enum.slice(words, start, size) == term,
        position <- start..(start + size - 1),
        do: position
  end

  defp code_words(name) when is_atom(name), do: name |> Atom.to_string() |> code_words()

  defp code_words(text),
    do: text |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

  # The literal arguments of every call to one of `names` in a module's source, outermost first.
  defp calls(source, names) do
    names = List.wrap(names)

    {_, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          if name in names, do: {node, [args | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # EHOS's schema of the version the installer writes, as eh_os_contract_auth carries it, which
  # the project's comment names: eh-os-contract's release this version pins, `v0.12.0`.
  @schema "test/fixtures/schemas/ehos.yaml.v7.json"

  defp schema(_igniter), do: @schema |> File.read!() |> JSON.decode!() |> JSV.build!()

  defp schema_title, do: @schema |> File.read!() |> JSON.decode!() |> Map.fetch!("title")

  # The generated configuration as Mix reads it, from files written out of the in-memory
  # project: `config.exs` imports the environment's own file.
  defp read_config(igniter, env) do
    dir = Path.join(System.tmp_dir!(), "ehos_app_config_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    for source <- igniter.rewrite,
        path = Rewrite.Source.get(source, :path),
        String.starts_with?(path, "config/") do
      File.mkdir_p!(Path.join(dir, Path.dirname(path)))
      File.write!(Path.join(dir, path), Rewrite.Source.get(source, :content))
    end

    Config.Reader.read!(Path.join(dir, "config/config.exs"), env: env)
  end
end

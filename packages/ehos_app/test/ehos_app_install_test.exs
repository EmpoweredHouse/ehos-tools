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

  # The verifier's migration as 0.2 wrote it, to the version current when it ran.
  @v02_verifier_migration """
  defmodule Test.Repo.Migrations.AddEhOsContractAuth do
    use Ecto.Migration

    def up, do: EhOsContract.Auth.Migrations.up()

    def down, do: EhOsContract.Auth.Migrations.down()
  end
  """

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
    test "adds the engine and the credential verifier from one commit of eh-os-contract" do
      mix = installed() |> content("mix.exs")

      [ref] =
        Regex.run(~r/EmpoweredHouse\/eh-os-contract",.*?ref: "([0-9a-f]{40})"/s, mix,
          capture: :all_but_first
        )

      assert mix =~
               ~r/\{:eh_os_contract, "~> 0\.3\.0-dev",\s+github: "EmpoweredHouse\/eh-os-contract",\s+sparse: "packages\/eh_os_contract",\s+ref: "#{ref}",\s+override: true\}/

      assert mix =~
               ~r/\{:eh_os_contract_auth, "~> 0\.1\.0-dev",\s+github: "EmpoweredHouse\/eh-os-contract",\s+sparse: "packages\/eh_os_contract_auth",\s+ref: "#{ref}"\}/
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

    # EHOS gives a client only to a workload whose `ehos.yaml` declares `sign_in` (eh-os D-69).
    test "starts without the sign-in's variables, signing nobody in" do
      runtime = installed() |> content("config/runtime.exs")

      assert runtime =~ ~s|if ehos_client_id = System.get_env("EHOS_CLIENT_ID") do|
      refute runtime =~ ~s|System.fetch_env!("EHOS_CLIENT_ID")|
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

      assert runtime =~ ~s|System.get_env("EHOS_CLIENT_ID")|
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
             |> content("config/runtime.exs") =~ "PORT"
    end

    test "listens on the ports ehos.yaml declares" do
      igniter = installed()
      %{"serves" => [%{"port" => web}], "health" => %{"port" => health}} = ehos_yaml(igniter)

      config = read_config(igniter, :prod)

      assert get_in(config, [:test, TestWeb.Endpoint, :http, :port]) == web
      assert get_in(config, [:test, TestWeb.Health, :port]) == health
      assert Install.ports() == %{web: web, health: health}
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

    test "offers a way in and out on the root, where EHOS returns a sign-out, and tests it" do
      igniter = installed()

      assert content(igniter, "lib/test_web/controllers/page_html/home.html.heex") =~
               "<Layouts.flash_group flash={@flash} />\n<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\n"

      components = content(igniter, "lib/test_web/sign_in_components.ex")
      assert components =~ "defmodule TestWeb.SignInComponents do"
      assert components =~ ~s|href="/auth/ehos/sign-in"|
      assert components =~ ~s|action="/auth/ehos/sign-out" method="post"|

      test = content(igniter, "test/test_web/sign_in_test.exs")
      assert test =~ "defmodule TestWeb.SignInTest do"
      assert test =~ "use TestWeb.ConnCase"
    end

    test "puts the way in and out on the root once, and leaves it where the developer moves it" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\n"

      moved =
        installed()
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, call, ""))
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(moved, home) =~ call
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

    test "says where the way in and out goes on a root it does not know" do
      igniter =
        phx_test_project()
        |> Igniter.rm("lib/test_web/controllers/page_html/home.html.heex")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />")
             )
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
      assert content(igniter, "mix.exs") =~ "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb"
      assert igniter.issues == []
      assert Enum.any?(igniter.warnings, &(&1 =~ "eh_os_contract_auth was on a commit"))

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

    test "migrates the verifier's tables to version 3 on a project moved to this commit by hand" do
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
           ref: "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb"},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
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
               "schema" => "ehos.yaml/v2",
               "needs" => %{
                 "database" => %{
                   "engine" => "postgres",
                   "version" => ">= 16",
                   "migrate" => ["/app/bin/migrate"]
                 }
               },
               "serves" => [%{"name" => "web", "port" => 4000, "public" => true}],
               "sign_in" => %{},
               "health" => %{"port" => 4001, "ready" => "/health/ready", "live" => "/health/live"}
             }
    end

    test "points editors at the schema's copy, which is EHOS's unchanged" do
      igniter = installed()

      assert content(igniter, "ehos.yaml") =~
               "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\n"

      assert content(igniter, ".ehos/ehos.yaml.v2.json") ==
               File.read!(Application.app_dir(:ehos_app, "priv/schemas/ehos.yaml/v2.json"))

      assert Install.ehos_yaml_schema_source() =~
               ~r|\Ahttps://github.com/EmpoweredHouse/eh-os/blob/[0-9a-f]{40}/priv/schemas/ehos.yaml/v2.json\z|
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

  describe "the release and the image" do
    test "generates the release and the Dockerfile through Phoenix, then gives it the build secret" do
      assert install().tasks -- [{"ehos_app.link_skills", []}] == [
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
    test "gates the contracts, then builds the image by digest beside the manifest" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      check = Enum.map(workflow["jobs"]["check"]["steps"], &(&1["run"] || &1["uses"]))

      for step <- [
            "mix format --check-formatted",
            "mix compile --warnings-as-errors",
            "mix test",
            "mix eh_os_contract.check",
            "mix eh_os_contract.manifest --output ehos.manifest.json"
          ] do
        assert step in check, "the check job does not run #{step}"
      end

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

    test "says how a workflow from ehos_app 0.2 reaches ehos-tools, and leaves it as it is" do
      old = "steps:\n  - run: echo github.com/EmpoweredHouse/eh-os-contract\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file(".github/workflows/ci.yml", old)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "repositories: eh-os-contract,ehos-tools"))
      assert igniter |> apply_igniter!() |> content(".github/workflows/ci.yml") == old
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

      assert "mix deps.get --only test" in runs
      refute Enum.any?(runs, &(&1 =~ "deps.unlock"))
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
      "ARCHITECTURE.md",
      "TESTING.md",
      "CLAUDE.md",
      "lib/test/contracts/CLAUDE.md",
      "lib/test_web/CLAUDE.md",
      ".coderabbit.yaml",
      ".github/pull_request_template.md",
      "test/harness_test.exs"
    ]
    @managed [
      {"AGENTS.md", "agents"},
      {"README.md", "readme"},
      {"VISION.md", "vision"},
      {"lib/test/contracts/AGENTS.md", "contracts"},
      {"lib/test_web/AGENTS.md", "web"}
    ]

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

    test "replaces the README Phoenix generates, and keeps one of the project's own" do
      phoenix = "# Test\n\nTo start your Phoenix server:\n\n* Run `mix setup`\n"
      readme = with_file("README.md", phoenix) |> Igniter.compose_task("ehos_app.install", [])

      assert content(readme, "README.md") =~ ~r/\A# Test\n\n<!-- One line/
      assert content(readme, "README.md") =~ "## Built on EHOS"
      refute content(readme, "README.md") =~ "To start your Phoenix server"

      own = with_file("README.md", "# Ours\n") |> Igniter.compose_task("ehos_app.install", [])

      assert content(own, "README.md") =~ ~r/\A<!-- ehos_app:readme -->.*\n# Ours\n\z/s
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

    test "explains EHOS at the top of VISION.md, and points to it from the README" do
      igniter = installed()
      vision = content(igniter, "VISION.md")

      assert vision =~ ~r/\A# Test\n/
      assert vision =~ "## EHOS, and where this application sits"
      assert vision =~ "### Principles it inherits"
      assert content(igniter, "README.md") =~ "at the top of\n[VISION.md](VISION.md)"
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

    test "copies the skills unchanged, and links them through a task while a link is missing" do
      igniter = install()
      source = Application.app_dir(:ehos_app, "priv/templates/ehos_app.install/skills")

      for skill <- ["plan", "ship", "review", "elixir-anti-patterns-review"] do
        assert_creates(
          igniter,
          ".agents/skills/#{skill}/SKILL.md",
          File.read!(Path.join([source, skill, "SKILL.md"]))
        )
      end

      assert {"ehos_app.link_skills", []} in igniter.tasks

      linked =
        igniter
        |> apply_igniter!()
        |> link_skills()
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      refute {"ehos_app.link_skills", []} in linked.tasks
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
      igniter = installed(["--example"]) |> link_skills() |> apply_igniter!()
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

      for {path, _} <- @managed, path != "README.md" do
        lines = igniter |> content(path) |> String.split("\n") |> length()
        assert lines <= 200, "#{path}: #{lines} lines"
      end

      assert igniter |> content("ARCHITECTURE.md") |> String.split("\n") |> length() <= 400
      assert igniter |> content("TESTING.md") |> String.split("\n") |> length() <= 300
    end
  end

  # What `mix ehos_app.link_skills` does in a real project, in the in-memory one: Igniter cannot
  # write a symlink, and a file at its path makes the skill's link exist.
  defp link_skills(igniter) do
    igniter.assigns.test_files
    |> Map.keys()
    |> Enum.flat_map(fn path ->
      case Path.split(path) do
        [".agents", "skills", name | _] -> [name]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.reduce(igniter, &Igniter.create_new_file(&2, ".claude/skills/#{&1}/SKILL.md", ""))
  end

  describe "the design system" do
    test "adds ehos_design from ehos-tools, pinned to the commit of its release" do
      assert installed() |> content("mix.exs") =~
               ~r/\{:ehos_design, "~> 0\.1\.0",\s+github: "EmpoweredHouse\/ehos-tools",\s+sparse: "packages\/ehos_design",\s+ref: "[0-9a-f]{40}"\}/
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

      assert install |> apply_igniter!() |> content("assets/css/app.css") ==
               "body { margin: 0; }\n"
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

    test "names EHOS's application with dashes, which allow no underscore" do
      assert Install.ehos_name(:my_shop) == "my-shop"
      assert Install.ehos_name(:shop) == "shop"
    end
  end

  test "is idempotent: a second run changes nothing" do
    for argv <- [[], ["--example"]] do
      igniter =
        install(argv)
        |> apply_igniter!()
        |> Igniter.create_new_file("Dockerfile", "# changed by the developer\n")
        |> link_skills()
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
    case Igniter.Code.Function.move_to_function_call(zipper, :if, 2, fn call ->
           Igniter.Code.Function.argument_matches_predicate?(call, 0, fn condition ->
             condition |> Sourceror.Zipper.node() |> Sourceror.to_string() =~ "EHOS_CLIENT_ID"
           end)
         end) do
      {:ok, call} ->
        call |> Sourceror.Zipper.remove() |> Sourceror.Zipper.root() |> Sourceror.Zipper.zip()

      :error ->
        zipper
    end
  end

  defp schema(igniter) do
    igniter |> content(".ehos/ehos.yaml.v2.json") |> JSON.decode!() |> JSV.build!()
  end

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

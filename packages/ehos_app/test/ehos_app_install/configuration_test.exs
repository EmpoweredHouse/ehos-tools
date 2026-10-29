defmodule Mix.Tasks.EhosApp.InstallTest.Configuration do
  use Mix.Tasks.EhosApp.InstallCase, async: true

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
    # `sign_in` (ehos-tools#460).
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
end

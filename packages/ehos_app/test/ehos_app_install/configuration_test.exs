defmodule Mix.Tasks.EhosApp.InstallTest.Configuration do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # What EHOS gives every workload at start (eh-os D-56), with what Phoenix's own configuration
  # reads under the names EHOS gives them.
  @given %{
    "EHOS_ISSUER" => "https://ehos.example.org",
    "EHOS_AUDIENCE" => "ledger/production",
    "PHX_HOST" => "ledger.example.org",
    "SECRET_KEY_BASE" => "base"
  }

  # What EHOS gives a workload that reads the people or sends mail: its client and the key.
  @client %{"EHOS_CLIENT_ID" => "ledger", "EHOS_CLIENT_KEY_FILE" => "/ehos/key.json"}

  # What EHOS gives a workload whose `ehos.yaml` declares `sign_in`, beside the client.
  @sign_in_applications %{
    "EHOS_SIGN_IN_APPLICATIONS" => ~s|{"office":"https://office.example.org"}|
  }

  # The sign-in production configures with `@given`, `@client` and `@sign_in_applications`.
  @sign_in [
    client_id: "ledger",
    client_key_file: "/ehos/key.json",
    address: "https://ledger.example.org",
    secret_key_base: "base",
    applications: %{"office" => "https://office.example.org"},
    absolute_limit: 43_200
  ]

  describe "configuration" do
    test "configures the engine with the application, its repo and EHOS's verifier" do
      assert read_config(installed(), :prod)[:eh_os_contract] == [
               applications: [:test],
               repo: Test.Repo,
               authorizer: EhOsContract.Auth
             ]
    end

    test "trusts a test key in tests, and runs no subscription or health listener there" do
      config = read_config(installed(), :test)

      assert config[:eh_os_contract_auth] == [
               issuer: "https://ehos.test",
               audience: "test/test",
               pin_keys: true
             ]

      assert config[:eh_os_contract][:subscriptions] == :manual
      assert config[:test][TestWeb.Health] == [port: 4001, server: false]
    end

    test "expects a local EHOS in development" do
      assert read_config(installed(), :dev)[:eh_os_contract_auth] == [
               issuer: "https://ehos.localhost",
               audience: "test/dev"
             ]
    end

    # `DATABASE_URL`, `PHX_HOST`, `PHX_SERVER` and `SECRET_KEY_BASE` are read by what
    # Phoenix itself generates, under the names EHOS gives them.
    test "reads what EHOS gives an application at start, in production" do
      config =
        installed()
        |> content("config/runtime.exs")
        |> read_runtime(
          Map.merge(@given, %{
            "EHOS_CA_FILE" => "/ehos/ca.pem",
            "DATABASE_SCHEMA" => "ledger",
            "DATABASE_CA_CERT_FILE" => "/database/ca.pem"
          })
        )

      assert config[:eh_os_contract_auth] == [
               issuer: "https://ehos.example.org",
               audience: "ledger/production"
             ]

      assert config[:test][EhOsContract.Auth] == [cacertfile: "/ehos/ca.pem"]

      assert config[:test][Test.Repo] == [
               parameters: [search_path: "ledger"],
               ssl: [cacertfile: "/database/ca.pem"]
             ]

      assert config[:test][Oban] == [prefix: "ledger"]
    end

    test "signs people in with the client EHOS gives, in production" do
      config =
        installed()
        |> content("config/runtime.exs")
        |> read_runtime(
          @given
          |> Map.merge(@client)
          |> Map.merge(@sign_in_applications)
          |> Map.put("EHOS_CA_FILE", "/ehos/ca.pem")
        )

      assert config[:eh_os_contract_auth] == [
               issuer: "https://ehos.example.org",
               audience: "ledger/production",
               sign_in: @sign_in
             ]

      assert config[:test][EhOsContract.Auth.SignIn] == [cacertfile: "/ehos/ca.pem"]
    end

    # eh-os D-113: a session ends when EHOS ends the person's sign-in, at the installation's limit.
    test "ends a session when EHOS ends the sign-in" do
      igniter = install()
      runtime = igniter |> apply_igniter!() |> content("config/runtime.exs")
      env = @given |> Map.merge(@client) |> Map.merge(@sign_in_applications)

      assert get_in(read_runtime(runtime, env), [:eh_os_contract_auth, :sign_in, :absolute_limit]) ==
               43_200

      assert runtime
             |> read_runtime(Map.put(env, "EHOS_SIGN_IN_ABSOLUTE", "28800"))
             |> get_in([:eh_os_contract_auth, :sign_in, :absolute_limit]) == 28_800

      assert messages_starting(igniter.notices, "config/runtime.exs signs people in without") ==
               []
    end

    # EHOS gives `EHOS_CLIENT_ID` to a workload that reads the people (eh-os D-81) or sends mail
    # (eh-os D-140) too, and `EHOS_SIGN_IN_APPLICATIONS` only to one whose `ehos.yaml` declares
    # `sign_in` (ehos-tools#460).
    test "starts without the sign-in's variables, signing nobody in" do
      config = installed() |> content("config/runtime.exs") |> read_runtime(@given)

      assert config[:eh_os_contract_auth] == [
               issuer: "https://ehos.example.org",
               audience: "ledger/production"
             ]
    end

    test "signs nobody in with the key EHOS gives for the people or for mail alone" do
      block = installed() |> content("config/runtime.exs") |> sign_in_block()

      assert read_runtime(block, @client) == []

      assert read_runtime(block, @given |> Map.merge(@client) |> Map.merge(@sign_in_applications)) ==
               [eh_os_contract_auth: [sign_in: @sign_in]]
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

      assert igniter
             |> content("lib/test_web/health.ex")
             |> lines_from("      Bandit.child_spec(", "      )") == [
               "      Bandit.child_spec(",
               "        plug: __MODULE__,",
               "        port: Keyword.fetch!(config, :port),",
               "        startup_log: false,",
               "        http_2_options: [enabled: false]",
               "      )"
             ]
    end

    test "does not read PORT, which EHOS never sets" do
      project = phx_test_project()

      # The variable's name: `OTEL_EXPORTER_OTLP_ENDPOINT` holds the letters too.
      assert project
             |> Igniter.include_existing_file("config/runtime.exs")
             |> content("config/runtime.exs")
             |> lines_with(~s|"PORT"|) == [
               ~s|config :test, TestWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]|
             ]

      assert project
             |> Igniter.compose_task("ehos_app.install", [])
             |> apply_igniter!()
             |> content("config/runtime.exs")
             |> lines_with(~s|"PORT"|) == []
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

      assert sign_in_block(runtime) == """
             # Signing people in to the pages through EHOS, which gives these when `ehos.yaml` declares
             # `sign_in` (https://github.com/empoweredhouse/eh-os/blob/main/docs/adr/0068-a-workload-that-serves-pages-is-given-a-jwk-and-the-other-applications-addresses-and-signs-out-to-its-root.md):
             # the client EHOS made for this workload and its key, the application's own address, and the
             # other applications the pages call as the person, by name, and how long a session lasts from
             # the sign-in at EHOS, the installation's (eh-os D-113). The client and its key alone are no
             # sign-in: EHOS gives them as well to a workload that reads the people (eh-os D-81) or sends mail
             # (eh-os D-140). `EHOS_SIGN_IN_APPLICATIONS` it gives only with `sign_in`, so without it the
             # application starts signing nobody in.
             if ehos_sign_in_applications = System.get_env("EHOS_SIGN_IN_APPLICATIONS") do
               config :eh_os_contract_auth,
                 sign_in: [
                   client_id: System.fetch_env!("EHOS_CLIENT_ID"),
                   client_key_file: System.fetch_env!("EHOS_CLIENT_KEY_FILE"),
                   address: "https://" <> System.fetch_env!("PHX_HOST"),
                   secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
                   applications: Jason.decode!(ehos_sign_in_applications),
                   absolute_limit: String.to_integer(System.get_env("EHOS_SIGN_IN_ABSOLUTE", "43200"))
                 ]

               if ehos_ca_file = System.get_env("EHOS_CA_FILE") do
                 config :test, EhOsContract.Auth.SignIn, cacertfile: ehos_ca_file
               end
             end\
             """

      # Once each: what was there is not added again.
      assert lines_with(runtime, ~s|"EHOS_ISSUER"|) == [
               ~s|    issuer: System.fetch_env!("EHOS_ISSUER"),|
             ]

      assert lines_with(runtime, "EhOsContract.Auth.SignIn, cacertfile:") == [
               "      config :test, EhOsContract.Auth.SignIn, cacertfile: ehos_ca_file"
             ]
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

      assert_unchanged(igniter, "config/runtime.exs")

      assert messages_starting(igniter.notices, "config/runtime.exs signs people in without") == [
               """
               config/runtime.exs signs people in without `absolute_limit`, so a session lasts twelve hours
               whatever EHOS's installation sets (eh-os D-113). Add it to the `sign_in:` list there, as
               deps/eh_os_contract_auth/packages/eh_os_contract_auth/README.md says:

                   absolute_limit: String.to_integer(System.get_env("EHOS_SIGN_IN_ABSOLUTE", "43200"))
               """
             ]
    end

    test "says the condition to a project whose sign-in an earlier version keyed on the client" do
      igniter =
        installed()
        |> Igniter.update_file("config/runtime.exs", fn source ->
          Rewrite.Source.update(source, :content, &earlier_sign_in_condition/1)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert_unchanged(igniter, "config/runtime.exs")

      assert messages_starting(igniter.notices, "config/runtime.exs signs people in wherever") ==
               [
                 """
                 config/runtime.exs signs people in wherever EHOS gives `EHOS_CLIENT_ID`, which it gives as well to
                 an application that reads the people or sends mail without declaring `sign_in` in
                 ehos.yaml. Such an application would start signing people in. Make the block's condition
                 the variable EHOS gives only with `sign_in`:

                     if ehos_sign_in_applications = System.get_env("EHOS_SIGN_IN_APPLICATIONS") do

                 with `client_id: System.fetch_env!("EHOS_CLIENT_ID")` and
                 `applications: Jason.decode!(ehos_sign_in_applications)` in its `sign_in:` list.
                 """
               ]
    end

    test "says no condition to a project whose sign-in waits for EHOS_SIGN_IN_APPLICATIONS" do
      assert messages_starting(install().notices, "config/runtime.exs signs people in wherever") ==
               []
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
              # As the formatter writes it, which a run that formats the file keeps.
              ~s|if (ehos_client_id = System.get_env("EHOS_CLIENT_ID")) &&\n| <>
                ~s|       System.get_env("EHOS_SIGN_IN_APPLICATIONS") do|
            )
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert_unchanged(igniter, "config/runtime.exs")

      assert messages_starting(igniter.notices, "config/runtime.exs signs people in wherever") ==
               []
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

      igniter =
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

      assert_unchanged(igniter, "config/runtime.exs")
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
      |> Igniter.Code.Function.move_to_function_call(:if, 2, &sign_in_block?/1)

    call |> Sourceror.Zipper.node() |> Sourceror.to_string()
  end

  # The configuration `script` makes in production with exactly `env` of the variables it reads,
  # read from a map in place of the process's environment, which the other tests share.
  defp read_runtime(script, env) do
    script =
      script
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

  # The lines of `content` from the line `first` through the next line `last`.
  defp lines_from(content, first, last) do
    {lines, [^last | _]} =
      content
      |> String.split("\n")
      |> Enum.drop_while(&(&1 != first))
      |> Enum.split_while(&(&1 != last))

    lines ++ [last]
  end
end

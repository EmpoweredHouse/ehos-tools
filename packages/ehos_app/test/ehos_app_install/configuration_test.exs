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

  # What the installer says when it does not add the engine's queue to Oban's, after the
  # reason it gives.
  @events_queue_advice """
  If no configuration that applies runs the queue `:events`, the jobs of effects delivered
  `:at_least_once` and of process managers' timers never run: have Oban run it, as
  `events: 10` among its queues.
  """

  @no_queue_list """
                 The engine's queue `:events` was not added to Oban's configuration: the call
                 `config :test, Oban`
                 in config/config.exs has no list of queues each written `name: limit`.
                 """ <> @events_queue_advice

  @other_layout """
                The engine's queue `:events` was not added to Oban's configuration: config/config.exs
                configures Oban in more than one call, as a tuple or in a block, so the installer cannot
                tell which queues apply.
                """ <> @events_queue_advice

  @no_oban """
           The engine's queue `:events` was not added to Oban's configuration: config/config.exs does
           not configure Oban.
           """ <> @events_queue_advice

  describe "configuration" do
    @tag :tmp_dir
    test "configures the engine with the application, its repo and EHOS's verifier", %{
      tmp_dir: tmp_dir
    } do
      assert read_config(installed(), :prod, tmp_dir)[:eh_os_contract] == [
               applications: [:test],
               repo: Test.Repo,
               authorizer: EhOsContract.Auth
             ]
    end

    @tag :tmp_dir
    test "trusts a test key in tests, and runs no subscription or health listener there", %{
      tmp_dir: tmp_dir
    } do
      config = read_config(installed(), :test, tmp_dir)

      assert config[:eh_os_contract_auth] == [
               issuer: "https://ehos.test",
               audience: "test/test",
               pin_keys: true
             ]

      assert config[:eh_os_contract][:subscriptions] == :manual
      assert config[:test][TestWeb.Health] == [port: 4001, server: false]
    end

    @tag :tmp_dir
    test "expects a local EHOS in development, and signs people in there without it", %{
      tmp_dir: tmp_dir
    } do
      assert read_config(installed(), :dev, tmp_dir)[:eh_os_contract_auth] == [
               issuer: "https://ehos.localhost",
               audience: "test/dev",
               development: true,
               people_directory: EhOsContract.Auth.People.Directory.Static,
               granter: EhOsContract.Auth.Grants.Local,
               mail_sender: EhOsContract.Auth.Mail.Local
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

    @tag :tmp_dir
    test "listens on the ports ehos.yaml declares", %{tmp_dir: tmp_dir} do
      igniter = installed()
      %{"serves" => [%{"port" => web}], "health" => %{"port" => health}} = ehos_yaml(igniter)

      config = read_config(igniter, :prod, tmp_dir)

      assert get_in(config, [:test, TestWeb.Endpoint, :http, :port]) == web
      assert get_in(config, [:test, TestWeb.Health, :port]) == health
      assert Install.ports() == %{web: web, health: health}
    end

    # eh-os#492, EEF-CVE-2026-105659: Bandit's HTTP/2 stack is not served, on either listener.
    @tag :tmp_dir
    test "serves HTTP/1.1 alone, on the endpoint and on the probes' listener", %{tmp_dir: tmp_dir} do
      igniter = installed()

      assert get_in(read_config(igniter, :prod, tmp_dir), [
               :test,
               TestWeb.Endpoint,
               :http,
               :http_2_options
             ]) ==
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

  describe "Oban's queues" do
    @tag :tmp_dir
    test "adds the engine's queue :events to the queues Oban's installer writes", %{
      tmp_dir: tmp_dir
    } do
      igniter = with_oban("queues: [default: 10]") |> install_on()

      assert igniter.warnings == []

      assert read_config(apply_igniter!(igniter), :prod, tmp_dir)[:test][Oban][:queues] == [
               default: 10,
               events: 10
             ]
    end

    test "changes nothing on a second run" do
      first = with_oban("queues: [default: 10]") |> install_on() |> apply_igniter!()

      assert content(install_again(first), "config/config.exs") ==
               content(first, "config/config.exs")
    end

    test "keeps a limit the project gave :events, and says nothing of it" do
      project = with_oban("queues: [default: 10, events: 3]") |> apply_igniter!()
      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      assert oban_config(igniter) == oban_config(project)
      assert igniter.warnings == []
      assert Igniter.exists?(igniter, "test/events_queue_test.exs")
    end

    test "writes the test that holds the queue, which drain/1 hides from every other test" do
      igniter = with_oban("queues: [default: 10]") |> install_on()

      assert content(igniter, "test/events_queue_test.exs") =~
               "queues = Application.fetch_env!(:test, Oban)[:queues] || []"

      assert content(igniter, "TESTING.md") =~ "- `test/events_queue_test.exs`: Oban runs"
    end

    test "keeps a test of the queue the project has" do
      mine = "defmodule EventsQueueTest do\nend\n"

      igniter =
        with_oban("queues: [default: 10]")
        |> Igniter.create_new_file("test/events_queue_test.exs", mine)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "test/events_queue_test.exs") == mine
    end

    for {queues, what} <- [
          {"queues: false", "queues that are not a list"},
          {"queues: []", "no queues"},
          {nil, "no queues: at all"}
        ] do
      @tag queues: queues
      test "keeps #{what} as they are, and says what to add", %{queues: queues} do
        project = with_oban(queues) |> apply_igniter!()
        igniter = Igniter.compose_task(project, "ehos_app.install", [])

        assert oban_config(igniter) == oban_config(project)
        assert igniter.warnings == [@no_queue_list]
        refute Igniter.exists?(igniter, "test/events_queue_test.exs")
        refute content(igniter, "TESTING.md") =~ "events_queue_test"
      end
    end

    test "keeps the queues, and says what to add, when a second call configures Oban" do
      project =
        with_oban("queues: [default: 10]")
        |> edit_file("config/config.exs", &(&1 <> "\nconfig :test, Oban, queues: false\n"))
        |> apply_igniter!()

      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      assert lines_with(content(igniter, "config/config.exs"), "queues:") ==
               ["  queues: [default: 10],", "config :test, Oban, queues: false"]

      assert igniter.warnings == [@other_layout]
    end

    test "keeps the queues, and says what to add, when Oban is configured as a tuple" do
      project =
        phx_test_project()
        |> edit_file(
          "config/config.exs",
          &(&1 <> "\nconfig :test, [{Oban, [repo: Test.Repo, queues: false]}]\n")
        )
        |> apply_igniter!()

      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      assert lines_with(content(igniter, "config/config.exs"), "queues:") ==
               ["config :test, [{Oban, [repo: Test.Repo, queues: false]}]"]

      assert igniter.warnings == [@other_layout]
    end

    test "says it cannot tell when a second call names :events, which a later call may undo" do
      project =
        with_oban("queues: [default: 10]")
        |> edit_file(
          "config/config.exs",
          &(&1 <> "\nconfig :test, Oban, queues: [default: 10, events: 5]\n")
        )
        |> apply_igniter!()

      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      assert lines_with(content(igniter, "config/config.exs"), "queues:") ==
               [
                 "  queues: [default: 10],",
                 "config :test, Oban, queues: [default: 10, events: 5]"
               ]

      assert igniter.warnings == [@other_layout]
      refute Igniter.exists?(igniter, "test/events_queue_test.exs")
    end

    test "keeps the queues, and says it cannot tell, when Oban is also configured in a block" do
      project =
        with_oban("queues: [default: 10]")
        |> edit_file(
          "config/config.exs",
          &(&1 <>
              "\nif config_env() == :prod do\n  config :test, Oban, queues: [default: 10, events: 5]\nend\n")
        )
        |> apply_igniter!()

      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      assert oban_config(igniter) == oban_config(project)
      assert igniter.warnings == [@other_layout]
    end

    test "keeps the queues, and says it cannot tell, when Oban is configured only in a block" do
      project =
        phx_test_project()
        |> edit_file(
          "config/config.exs",
          &(&1 <>
              "\nif config_env() == :prod do\n  config :test, Oban, queues: [default: 10]\nend\n")
        )
        |> apply_igniter!()

      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      assert lines_with(content(igniter, "config/config.exs"), "queues:") ==
               ["  config :test, Oban, queues: [default: 10]"]

      assert igniter.warnings == [@other_layout]
    end

    test "counts a call that names Oban as an atom" do
      project =
        with_oban("queues: [default: 10]")
        |> edit_file(
          "config/config.exs",
          &(&1 <> ~s|\nconfig :test, :"Elixir.Oban", queues: false\n|)
        )
        |> apply_igniter!()

      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      assert oban_config(igniter) == oban_config(project)
      assert igniter.warnings == [@other_layout]
    end

    test "counts Oban named as an atom in the tuple form" do
      project =
        with_oban("queues: [default: 10]")
        |> edit_file(
          "config/config.exs",
          &(&1 <> ~s|\nconfig :test, "Elixir.Oban": [queues: false]\n|)
        )
        |> apply_igniter!()

      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      assert lines_with(content(igniter, "config/config.exs"), "queues:") ==
               ["  queues: [default: 10],", ~s|config :test, "Elixir.Oban": [queues: false]|]

      assert igniter.warnings == [@other_layout]
    end

    test "keeps a list with a queue named by an expression, and says what to add" do
      project = with_oban(~s|queues: [{String.to_atom("mail"), 10}]|) |> apply_igniter!()
      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      assert oban_config(igniter) == oban_config(project)
      assert igniter.warnings == [@no_queue_list]
    end

    test "says what to add when Oban is a dependency but config.exs configures none" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep({:oban, "~> 2.20"}, yes?: true)
        |> install_on()

      assert igniter.warnings == [@no_oban]
      assert lines_with(content(igniter, "config/config.exs"), "Oban") == []
    end

    @tag :tmp_dir
    test "configures no Oban, and says nothing of it, in a project without Oban", %{
      tmp_dir: tmp_dir
    } do
      igniter = install()

      assert Enum.filter(igniter.warnings, &(&1 =~ "Oban")) == []
      assert read_config(apply_igniter!(igniter), :prod, tmp_dir)[:test][Oban] == nil
    end
  end

  # The test project with Oban configured as its installer writes it, its `queues` as given, or
  # none with `nil`.
  defp with_oban(queues) do
    oban =
      Enum.join(
        ["  engine: Oban.Engines.Basic" | List.wrap(queues && "  " <> queues)] ++
          ["  repo: Test.Repo"],
        ",\n"
      )

    edit_file(phx_test_project(), "config/config.exs", fn config ->
      String.replace(config, "import Config\n", "import Config\n\nconfig :test, Oban,\n#{oban}\n",
        global: false
      )
    end)
  end

  # The lines of config.exs that configure Oban.
  defp oban_config(igniter) do
    igniter |> content("config/config.exs") |> lines(~s|config :test, Oban,|, "  repo: Test.Repo")
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

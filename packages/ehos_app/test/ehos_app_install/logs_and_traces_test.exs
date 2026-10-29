defmodule Mix.Tasks.EhosApp.InstallTest.LogsAndTraces do
  use Mix.Tasks.EhosApp.InstallCase, async: true

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
end

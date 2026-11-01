defmodule Mix.Tasks.EhosApp.InstallTest.LogsAndTraces do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # The marker of the installer's tracing in `start/2`, and the line its children begin on.
  @tracing_marker "    # eh-os D-93: a trace of each request and query, sent where EHOS says, if it says."
  @children_start "    children = ["

  # The block of runtime.exs's production section that sends traces where EHOS says.
  @otlp_block_start ~s|  if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do|

  # What a project that chose how it traces is told: what to do, not what EHOS would have done.
  @tracing_left_notice """
  EHOS: the project already has `opentelemetry`, so its tracing was left as it is. For EHOS
  to take its traces:

  - export them over OTLP only when OTEL_EXPORTER_OTLP_ENDPOINT is set, which EHOS sets to
    its collector's address: `traces_exporter: :none` in config/config.exs, and
    `config :opentelemetry, traces_exporter: :otlp` in config/runtime.exs when it is set;
  - take no caller's trace as a request's parent: OpentelemetryBandit.setup(public_endpoint: true),
    or the same option of the instrumentation the project serves through.
  """

  @logging_left_notice """
  EHOS: the project already chose how it logs, so its logging was left as it is. For EHOS's
  console and `ehosctl logs` to show a line's level and fields, log one JSON object a line in
  production, for instance with logger_json's formatter in config/prod.exs:

      config :logger, :default_handler,
        formatter:
          {LoggerJSON.Formatters.Elastic,
           metadata: [:request_id, :correlation_id],
           redactors: [{LoggerJSON.Redactors.RedactKeys, ["password", "secret", "token", "authorization", "cookie"]}]}
  """

  describe "logs and traces" do
    # eh-os D-93, Stage 15's step 6 (eh-os#485).
    test "adds the JSON logger and the OpenTelemetry SDK, the exporter before the SDK" do
      igniter = installed()

      assert Enum.map(Install.telemetry_deps(), &dep(igniter, elem(&1, 0))) ==
               Install.telemetry_deps()

      assert Enum.filter(dep_names(igniter), &(&1 in [:opentelemetry_exporter, :opentelemetry])) ==
               [:opentelemetry_exporter, :opentelemetry]
    end

    @tag :tmp_dir
    test "logs one JSON object a line in production, with the request, its trace and the work's correlation, and no credential in its fields",
         %{tmp_dir: tmp_dir} do
      config = installed() |> read_config(:prod, tmp_dir)

      assert get_in(config, [:logger, :default_handler]) == [
               formatter:
                 {LoggerJSON.Formatters.Elastic,
                  metadata: [:request_id, :correlation_id],
                  redactors: [
                    {LoggerJSON.Redactors.RedactKeys,
                     ["password", "secret", "token", "authorization", "cookie"]}
                  ]}
             ]
    end

    @tag :tmp_dir
    test "sends traces nowhere, unless EHOS names a collector in production", %{tmp_dir: tmp_dir} do
      igniter = installed()

      assert get_in(read_config(igniter, :dev, tmp_dir), [:opentelemetry, :traces_exporter]) ==
               :none

      assert get_in(read_config(igniter, :test, tmp_dir), [:opentelemetry, :traces_exporter]) ==
               :none

      [_, prod] =
        String.split(content(igniter, "config/runtime.exs"), "if config_env() == :prod do",
          parts: 2
        )

      # Inside the production block: indented, as its lines are.
      assert lines_between(prod, @otlp_block_start, "  end") == """
               if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
                 config :opentelemetry, traces_exporter: :otlp
               end
             """
    end

    test "traces each request and query from the start of the application, before its children, taking no caller's trace as its own" do
      application = installed() |> content("lib/test/application.ex")

      assert lines_between(application, @tracing_marker, @children_start) == """
                 # eh-os D-93: a trace of each request and query, sent where EHOS says, if it says.
                 OpentelemetryBandit.setup(public_endpoint: true)
                 OpentelemetryPhoenix.setup(adapter: :bandit)
                 OpentelemetryEcto.setup([:test, :repo])

                 children = [
             """
    end

    test "starts the SDK so that its stopping never stops the release" do
      assert installed() |> trimmed_lines_starting("mix.exs", "releases:") == [
               "releases: [test: [applications: [opentelemetry: :temporary]]]"
             ]
    end

    test "a second run adds nothing twice" do
      igniter =
        installed()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert trimmed_lines_starting(igniter, "lib/test/application.ex", "Opentelemetry") == [
               "OpentelemetryBandit.setup(public_endpoint: true)",
               "OpentelemetryPhoenix.setup(adapter: :bandit)",
               "OpentelemetryEcto.setup([:test, :repo])"
             ]

      assert trimmed_lines_starting(igniter, "config/runtime.exs", String.trim(@otlp_block_start)) ==
               [
                 String.trim(@otlp_block_start)
               ]

      assert trimmed_lines_starting(igniter, "mix.exs", "{:opentelemetry,") == [
               ~s|{:opentelemetry, "~> 1.7"},|
             ]
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
        |> edit_file("lib/test/application.ex", fn content ->
          content
          |> String.replace(~r/ *# eh-os D-93.*\n/, "")
          |> String.replace(~r/ *Opentelemetry\w+\.setup\(.*\)\n/, "")
        end)
        |> apply_igniter!()

      assert trimmed_lines_starting(earlier, "lib/test/application.ex", "Opentelemetry") == []

      igniter = earlier |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      assert Enum.map(Install.telemetry_deps(), &dep(igniter, elem(&1, 0))) ==
               Install.telemetry_deps()

      # The calls go first in `start/2`, before what the project starts there since.
      assert igniter
             |> content("lib/test/application.ex")
             |> lines_between(@tracing_marker, "    OpentelemetryEcto.setup([:test, :repo])") ==
               """
                   # eh-os D-93: a trace of each request and query, sent where EHOS says, if it says.
                   OpentelemetryBandit.setup(public_endpoint: true)
                   OpentelemetryPhoenix.setup(adapter: :bandit)
                   OpentelemetryEcto.setup([:test, :repo])
               """
    end

    test "adds the block that sends traces when runtime.exs only mentions its variable in a comment" do
      runtime =
        phx_test_project()
        |> edit_file("config/runtime.exs", &("# OTEL_EXPORTER_OTLP_ENDPOINT: later.\n" <> &1))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("config/runtime.exs")

      assert lines_between(runtime, @otlp_block_start, "  end") == """
               if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
                 config :opentelemetry, traces_exporter: :otlp
               end
             """
    end

    test "a second run takes the tracing and logging it set up for its own, and says nothing of them" do
      igniter = installed() |> Igniter.compose_task("ehos_app.install", [])

      assert igniter.notices == [ready_notice(), no_contract_notice()]
    end

    @tag :tmp_dir
    test "leaves a project's own tracing whole, saying what EHOS gives", %{tmp_dir: tmp_dir} do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep({:opentelemetry, "~> 1.5"})
        |> edit_file(
          "lib/test/application.ex",
          &String.replace(
            &1,
            "def start(_type, _args) do\n",
            "def start(_type, _args) do\n    OpentelemetryPhoenix.setup(adapter: :cowboy2)\n"
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert messages_starting(igniter.notices, "EHOS: the project already has `opentelemetry`") ==
               [@tracing_left_notice]

      igniter = apply_igniter!(igniter)

      assert dep(igniter, :opentelemetry) == {:opentelemetry, "~> 1.5"}
      assert dep(igniter, :opentelemetry_bandit) == nil
      assert trimmed_lines_starting(igniter, "mix.exs", "releases:") == []

      assert trimmed_lines_starting(igniter, "lib/test/application.ex", "Opentelemetry") == [
               "OpentelemetryPhoenix.setup(adapter: :cowboy2)"
             ]

      assert get_in(read_config(igniter, :prod, tmp_dir), [:opentelemetry, :traces_exporter]) ==
               nil

      refute content(igniter, "config/runtime.exs") =~ "OTEL_EXPORTER_OTLP_ENDPOINT"
      # Its logs are another choice, and get the JSON formatter.
      assert dep(igniter, :logger_json) == {:logger_json, "~> 7.0"}
    end

    test "leaves Bandit's tracing a project set up without the SDK as it is, saying what to set, on every run" do
      igniter =
        phx_test_project()
        |> edit_file(
          "lib/test/application.ex",
          &String.replace(
            &1,
            "def start(_type, _args) do\n",
            "def start(_type, _args) do\n    OpentelemetryBandit.setup()\n"
          )
        )

      # Each run installs on the one before's result.
      Enum.reduce(1..2, igniter, fn _run, igniter ->
        igniter = install_on(igniter)

        assert messages_starting(igniter.notices, "EHOS: the project already has `opentelemetry`") ==
                 [@tracing_left_notice]

        igniter = apply_igniter!(igniter)

        assert trimmed_lines_starting(igniter, "lib/test/application.ex", "Opentelemetry") == [
                 "OpentelemetryBandit.setup()"
               ]

        assert dep(igniter, :opentelemetry_phoenix) == nil
        igniter
      end)
    end

    @tag :tmp_dir
    test "leaves a formatter the project chose, in any config file", %{tmp_dir: tmp_dir} do
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

      assert dep(igniter, :logger_json) == nil

      assert get_in(read_config(igniter, :prod, tmp_dir), [:logger, :default_handler]) == [
               formatter: {MyFormatter, []}
             ]
    end

    @tag :tmp_dir
    test "leaves a formatter set in runtime.exs's production block, and says so", %{
      tmp_dir: tmp_dir
    } do
      igniter =
        phx_test_project()
        |> edit_file(
          "config/runtime.exs",
          &String.replace(
            &1,
            "if config_env() == :prod do\n",
            "if config_env() == :prod do\n  config :logger, :default_handler, formatter: {MyFormatter, []}\n",
            global: false
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert messages_starting(igniter.notices, "EHOS: the project already chose how it logs") ==
               [@logging_left_notice]

      igniter = apply_igniter!(igniter)

      assert dep(igniter, :logger_json) == nil
      assert get_in(read_config(igniter, :prod, tmp_dir), [:logger, :default_handler]) == nil
    end

    @tag :tmp_dir
    test "leaves a project with logger_json and no formatter as it is, saying how to log JSON", %{
      tmp_dir: tmp_dir
    } do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep({:logger_json, "~> 6.0"})
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert messages_starting(igniter.notices, "EHOS: the project already chose how it logs") ==
               [@logging_left_notice]

      igniter = apply_igniter!(igniter)

      assert dep(igniter, :logger_json) == {:logger_json, "~> 6.0"}
      assert get_in(read_config(igniter, :prod, tmp_dir), [:logger, :default_handler]) == nil
    end

    # One test per case, so each runs the installer once within ExUnit's timeout for a test.
    for {what, prod} <- [
          {"a formatter named in a way the installer cannot read",
           "config :logger, :default_handler, formatter: {__MODULE__.Formatter, []}\n"},
          {"logger options in a variable",
           "options = [formatter: {MyFormatter, []}]\nconfig :logger, :default_handler, options\n"}
        ] do
      test "leaves #{what}" do
        igniter =
          phx_test_project()
          |> edit_file("config/prod.exs", &(&1 <> unquote(prod)))
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])

        assert messages_starting(igniter.notices, "EHOS: the project already chose how it logs") ==
                 [@logging_left_notice]

        assert igniter |> apply_igniter!() |> dep(:logger_json) == nil
      end
    end

    test "names no release of its own beside one the project named otherwise" do
      igniter =
        phx_test_project()
        |> Igniter.Project.MixProject.update(:project, [:releases], fn nil ->
          {:ok, {:code, Sourceror.parse_string!("[web: [include_executables_for: [:unix]]]")}}
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert trimmed_lines_starting(igniter, "mix.exs", "releases:") == [
               "releases: [web: [include_executables_for: [:unix]]]"
             ]
    end

    test "leaves release options the code computes as they are" do
      igniter =
        phx_test_project()
        |> Igniter.Project.MixProject.update(:project, [:releases], fn nil ->
          {:ok, {:code, Sourceror.parse_string!("[test: release_options()]")}}
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert trimmed_lines_starting(igniter, "mix.exs", "releases:") == [
               "releases: [test: release_options()]"
             ]
    end

    test "keeps what the release already says of the SDK" do
      igniter =
        phx_test_project()
        |> Igniter.Project.MixProject.update(
          :project,
          [:releases, :test, :applications, :opentelemetry],
          fn nil -> {:ok, {:code, :permanent}} end
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert trimmed_lines_starting(igniter, "mix.exs", "releases:") == [
               "releases: [test: [applications: [opentelemetry: :permanent]]]"
             ]
    end

    test "says which block sends traces when there is no runtime.exs" do
      warnings =
        phx_test_project()
        |> Igniter.rm("config/runtime.exs")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> Map.fetch!(:warnings)

      assert messages_starting(
               warnings,
               "config/runtime.exs was not found, so the application sends no traces"
             ) ==
               [
                 """
                 config/runtime.exs was not found, so the application sends no traces, even where EHOS
                 names a collector. Add this block to its `config_env() == :prod` section:

                 # Where to send the application's traces, which EHOS gives when its collector takes them (eh-os
                 # D-93). Without it they go nowhere, as `config/config.exs` sets, and the operator's
                 # `OTEL_TRACES_EXPORTER=none`, for an installation that keeps no traces, wins over this.
                 if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
                   config :opentelemetry, traces_exporter: :otlp
                 end

                 """
               ]
    end
  end

  # The names of the project's dependencies, in the order its `mix.exs` lists them.
  defp dep_names(igniter) do
    [[_, [do: deps]]] =
      igniter
      |> content("mix.exs")
      |> calls(:defp)
      |> Enum.filter(&match?([{:deps, _, _} | _], &1))

    Enum.map(deps, fn
      {:{}, _, [name | _]} -> name
      {name, _} -> name
    end)
  end

  # The lines of `text` from the first that is `first` through the next that is `last`, as
  # written, or nil when no line is `first`.
  defp lines_between(text, first, last) do
    case text |> String.split("\n") |> Enum.drop_while(&(&1 != first)) do
      [] ->
        nil

      from_first ->
        {block, rest} = Enum.split_while(from_first, &(&1 != last))
        Enum.join(block ++ Enum.take(rest, 1), "\n") <> "\n"
    end
  end
end

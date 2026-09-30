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

  describe "dependencies" do
    test "adds the engine and the credential verifier from one commit of eh-os-contract" do
      mix = installed() |> content("mix.exs")
      [ref] = Regex.run(~r/ref: "([0-9a-f]{40})"/, mix, capture: :all_but_first)

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
    test "starts the engine, the key store and the health endpoints in order, before the endpoint" do
      application = installed() |> content("lib/test/application.ex")

      order =
        for child <- [
              "Test.Repo",
              "EhOsContract,",
              "{EhOsContract.Auth, Application.get_env(:test, EhOsContract.Auth, [])}",
              "TestWeb.Health",
              "TestWeb.Endpoint"
            ] do
          {index, _} = :binary.match(application, child)
          index
        end

      assert order == Enum.sort(order)
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
               "schema" => "ehos.yaml/v1",
               "needs" => %{
                 "database" => %{
                   "engine" => "postgres",
                   "version" => ">= 16",
                   "migrate" => ["/app/bin/migrate"]
                 }
               },
               "serves" => [%{"name" => "web", "port" => 4000, "public" => true}],
               "health" => %{"port" => 4001, "ready" => "/health/ready", "live" => "/health/live"}
             }
    end

    test "points editors at the schema's copy, which is EHOS's unchanged" do
      igniter = installed()

      assert content(igniter, "ehos.yaml") =~
               "# yaml-language-server: $schema=.ehos/ehos.yaml.v1.json\n"

      assert content(igniter, ".ehos/ehos.yaml.v1.json") ==
               File.read!(Application.app_dir(:ehos_app, "priv/schemas/ehos.yaml/v1.json"))

      assert Install.ehos_yaml_schema_source() =~
               ~r|\Ahttps://github.com/EmpoweredHouse/eh-os/blob/[0-9a-f]{40}/priv/schemas/ehos.yaml/v1.json\z|
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
    test "puts the EHOS section in front of the AGENTS.md Phoenix generates" do
      igniter =
        phx_test_project()
        |> Igniter.create_or_update_file("AGENTS.md", "# Phoenix rules\n", & &1)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      content = content(igniter, "AGENTS.md")

      assert content =~ ~r/\A<!-- ehos_app:agents -->/
      assert content =~ "# Phoenix rules"
      assert_creates(igniter, "CLAUDE.md", "@AGENTS.md\n")
    end

    test "replaces the EHOS section an earlier version wrote, and keeps the rest" do
      igniter =
        phx_test_project()
        |> Igniter.create_or_update_file(
          "AGENTS.md",
          "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n\n# Phoenix rules\n",
          & &1
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      content = content(igniter, "AGENTS.md")

      refute content =~ "Old rules"
      assert content =~ "# EHOS application"
      assert content =~ ~r/<!-- \/ehos_app:agents -->\n\n# Phoenix rules\n\z/
    end

    test "leaves an EHOS section alone when its end marker is gone" do
      agents = "<!-- ehos_app:agents -->\nRules the developer rewrote\n\n# Phoenix rules\n"

      igniter =
        phx_test_project()
        |> Igniter.create_or_update_file("AGENTS.md", agents, & &1)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "AGENTS.md") == agents
    end

    test "points agents at the contract reference where the sparse dependency puts it" do
      docs = Install.contract_docs()
      assert docs == "deps/eh_os_contract/packages/eh_os_contract/docs/contract.md"

      igniter = installed(["--example"])

      for path <- ["AGENTS.md", "lib/test/domain.ex", "lib/test/contracts/entries.ex"] do
        assert content(igniter, path) =~ docs
      end
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

  defp schema(igniter) do
    igniter |> content(".ehos/ehos.yaml.v1.json") |> JSON.decode!() |> JSV.build!()
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

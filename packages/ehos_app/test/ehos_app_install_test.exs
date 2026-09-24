defmodule Mix.Tasks.EhosApp.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp install(argv \\ []) do
    phx_test_project()
    |> Igniter.compose_task("ehos_app.install", argv)
  end

  test "adds the engine from git, pinned to a tag" do
    install()
    |> assert_has_patch("mix.exs", """
    + |      {:eh_os_contract, "~> 0.2.1",
    + |       github: "EmpoweredHouse/eh-os-contract", sparse: "packages/eh_os_contract", tag: "v0.2.1"},
    """)
  end

  test "configures the engine with the application and its repo" do
    install()
    |> assert_has_patch("config/config.exs", """
    + |config :eh_os_contract, applications: [:test], repo: Test.Repo
    """)
  end

  test "starts the engine after the repo and before the endpoint" do
    source =
      install()
      |> apply_igniter!()
      |> Map.fetch!(:rewrite)
      |> Rewrite.source!("lib/test/application.ex")
      |> Rewrite.Source.get(:content)

    [before_engine, after_engine] = String.split(source, "EhOsContract", parts: 2)
    assert before_engine =~ "Test.Repo"
    assert after_engine =~ "TestWeb.Endpoint"
  end

  test "migrates after a migration generated in the same second, such as Oban's" do
    igniter =
      phx_test_project()
      |> Igniter.create_new_file("priv/repo/migrations/29990101000000_add_oban.exs", "")
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])

    assert Igniter.exists?(igniter, "priv/repo/migrations/29990101000001_add_eh_os_contract.exs")
  end

  test "runs the contract check in precommit" do
    install()
    |> assert_has_patch("mix.exs", """
    + |        "eh_os_contract.check"
    """)
  end

  test "declares intent in ehos.yaml" do
    install()
    |> assert_creates("ehos.yaml")
  end

  test "pins the toolchain it ran under" do
    {:ok, [erlang: erlang, elixir: elixir]} = EhosApp.Toolchain.current()

    install()
    |> assert_creates(".tool-versions", """
    erlang #{erlang}
    elixir #{elixir}
    """)
  end

  test "puts the EHOS section in front of the AGENTS.md Phoenix generates" do
    igniter =
      phx_test_project()
      |> Igniter.create_or_update_file("AGENTS.md", "# Phoenix rules\n", & &1)
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])

    content =
      igniter.rewrite |> Rewrite.source!("AGENTS.md") |> Rewrite.Source.get(:content)

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

    content =
      igniter.rewrite |> Rewrite.source!("AGENTS.md") |> Rewrite.Source.get(:content)

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

    content =
      igniter.rewrite |> Rewrite.source!("AGENTS.md") |> Rewrite.Source.get(:content)

    assert content == agents
  end

  test "is idempotent: a second run changes nothing" do
    igniter =
      install()
      |> apply_igniter!()
      |> Igniter.create_new_file("Dockerfile", "# changed by the developer\n")
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()

    # `assert_unchanged/1` reads files only; a task would still rewrite the Dockerfile.
    assert igniter.tasks == []
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

    config =
      igniter.rewrite |> Rewrite.source!("config/config.exs") |> Rewrite.Source.get(:content)

    assert config =~ "config :eh_os_contract, applications: [:test], repo: Test.Store"

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

  test "points agents at the contract reference where the sparse dependency puts it" do
    docs = Mix.Tasks.EhosApp.Install.contract_docs()
    assert docs == "deps/eh_os_contract/packages/eh_os_contract/docs/contract.md"

    igniter = install(["--example"]) |> apply_igniter!()

    for path <- ["AGENTS.md", "lib/test/contracts/case_handling.ex"] do
      content = igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
      assert content =~ docs
    end
  end

  test "generates the example contract only when asked" do
    install(["--example"])
    |> assert_creates("lib/test/contracts/case_handling.ex")

    refute install() |> Igniter.exists?("lib/test/contracts/case_handling.ex")
  end

  test "generates the release and the Dockerfile through Phoenix" do
    igniter = install()
    assert {"phx.gen.release", ["--docker"]} in igniter.tasks
  end
end

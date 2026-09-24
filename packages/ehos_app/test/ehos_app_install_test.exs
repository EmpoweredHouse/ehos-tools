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
    [erlang: erlang, elixir: elixir] = EhosApp.Toolchain.current()

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

  test "is idempotent: a second run changes nothing" do
    install()
    |> apply_igniter!()
    |> Igniter.compose_task("ehos_app.install", [])
    |> assert_unchanged()
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

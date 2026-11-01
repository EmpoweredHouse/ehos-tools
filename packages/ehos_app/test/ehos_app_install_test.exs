defmodule Mix.Tasks.EhosApp.InstallTest do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  doctest Mix.Tasks.EhosApp.Install

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

  @tag :tmp_dir
  test "uses the project's repo, whatever it is called", %{tmp_dir: tmp_dir} do
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

    assert read_config(igniter, :dev, tmp_dir)[:eh_os_contract][:repo] == Test.Store

    # A migration's name starts with when it was written, which the test cannot know. Oban's
    # is its own installer's, which `compose_task/3` does not run.
    assert igniter.rewrite
           |> Enum.map(&Rewrite.Source.get(&1, :path))
           |> Enum.filter(&String.starts_with?(&1, "priv/store/migrations/"))
           |> Enum.map(&String.replace(&1, ~r|/\d{14}_|, "/<timestamp>_"))
           |> Enum.sort() == [
             "priv/store/migrations/<timestamp>_add_eh_os_contract.exs",
             "priv/store/migrations/<timestamp>_add_eh_os_contract_auth.exs"
           ]
  end

  test "refuses a project without a repo, rather than guessing one" do
    igniter =
      test_project()
      |> Igniter.compose_task("ehos_app.install", [])

    assert igniter.issues == [
             """
             No Ecto repo found. ehos_app needs one: the contract engine keeps its event log
             in the application's database. Generate the project with a database, or add a repo,
             and run the installer again.
             """
           ]
  end
end

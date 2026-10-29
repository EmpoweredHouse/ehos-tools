defmodule Mix.Tasks.EhosApp.InstallTest.SupervisionTree do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "the supervision tree" do
    # Oban's installer puts it where `phx.new`'s list has it, before PubSub, which is followed
    # by the endpoint: the layout that once left every EHOS child behind the endpoint.
    test "starts the engine, the key store and the health endpoints in order, before the endpoint" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Application.add_new_child(
          {Oban, {:code, quote(do: Application.fetch_env!(:test, Oban))}},
          after: [Test.Repo]
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert children_of(igniter) == """
             TestWeb.Telemetry,
             Test.Repo,
             {DNSCluster, query: Application.get_env(:test, :dns_cluster_query) || :ignore},
             {Oban, Application.fetch_env!(:test, Oban)},
             {Phoenix.PubSub, name: Test.PubSub},
             EhOsContract,
             {EhOsContract.Auth, Application.get_env(:test, EhOsContract.Auth, [])},
             TestWeb.Health,
             # Start a worker by calling: Test.Worker.start_link(arg)
             # {Test.Worker, arg},
             # Start to serve requests, typically the last entry
             {Test.SignIn, Application.get_env(:test, EhOsContract.Auth.SignIn, [])},
             TestWeb.Endpoint
             """
    end

    test "moves the endpoint last as it is written, comments and options included" do
      igniter =
        phx_test_project()
        |> edit_file(
          "lib/test/application.ex",
          &String.replace(&1, "TestWeb.Endpoint\n", "{TestWeb.Endpoint, []},\n      Test.Last\n")
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert children_of(igniter) == """
             TestWeb.Telemetry,
             Test.Repo,
             {DNSCluster, query: Application.get_env(:test, :dns_cluster_query) || :ignore},
             EhOsContract,
             {Phoenix.PubSub, name: Test.PubSub},
             {EhOsContract.Auth, Application.get_env(:test, EhOsContract.Auth, [])},
             TestWeb.Health,
             {Test.SignIn, Application.get_env(:test, EhOsContract.Auth.SignIn, [])},
             # Start a worker by calling: Test.Worker.start_link(arg)
             # {Test.Worker, arg},
             # Start to serve requests, typically the last entry
             Test.Last,
             {TestWeb.Endpoint, []}
             """
    end

    test "appends no endpoint where the children have none" do
      igniter =
        phx_test_project()
        |> edit_file(
          "lib/test/application.ex",
          &String.replace(&1, "TestWeb.Endpoint\n", "Test.Last\n")
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert children_of(igniter) == """
             TestWeb.Telemetry,
             Test.Repo,
             {DNSCluster, query: Application.get_env(:test, :dns_cluster_query) || :ignore},
             EhOsContract,
             {Phoenix.PubSub, name: Test.PubSub},
             {EhOsContract.Auth, Application.get_env(:test, EhOsContract.Auth, [])},
             TestWeb.Health,
             {Test.SignIn, Application.get_env(:test, EhOsContract.Auth.SignIn, [])},
             # Start a worker by calling: Test.Worker.start_link(arg)
             # {Test.Worker, arg},
             # Start to serve requests, typically the last entry
             Test.Last
             """
    end
  end

  # The application's children, one a line, as written, without their indentation.
  defp children_of(igniter) do
    igniter
    |> content("lib/test/application.ex")
    |> children()
    |> String.split("\n", trim: true)
    |> Enum.map_join(&(String.trim(&1) <> "\n"))
  end
end

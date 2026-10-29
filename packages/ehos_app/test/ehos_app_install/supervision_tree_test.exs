defmodule Mix.Tasks.EhosApp.InstallTest.SupervisionTree do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "the supervision tree" do
    test "moves the endpoint last as it is written, comments and options included" do
      application =
        phx_test_project()
        |> Igniter.update_file("lib/test/application.ex", fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            content
            |> String.replace("TestWeb.Endpoint\n", "{TestWeb.Endpoint, []},\n      Test.Last\n")
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test/application.ex")

      children = children(application)

      assert children =~ ~r/Test.Last,\s+\{TestWeb.Endpoint, \[\]\}\s*\z/
      assert length(String.split(children, "TestWeb.Endpoint")) == 2
    end

    test "appends no endpoint where the children have none" do
      application =
        phx_test_project()
        |> Igniter.update_file("lib/test/application.ex", fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, "TestWeb.Endpoint\n", "Test.Last\n")
          )
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test/application.ex")

      refute children(application) =~ "TestWeb.Endpoint"
    end

    test "starts the engine, the key store and the health endpoints in order, before the endpoint" do
      # Oban's installer puts it where `phx.new`'s list has it, before PubSub, which is followed
      # by the endpoint: the layout that once left every EHOS child behind the endpoint.
      application =
        phx_test_project()
        |> Igniter.Project.Application.add_new_child(
          {Oban, {:code, quote(do: Application.fetch_env!(:test, Oban))}},
          after: [Test.Repo]
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test/application.ex")

      order =
        for child <- [
              "Test.Repo",
              "{Oban, Application.fetch_env!(:test, Oban)}",
              "EhOsContract,",
              "{EhOsContract.Auth, Application.get_env(:test, EhOsContract.Auth, [])}",
              "TestWeb.Health",
              "{Test.SignIn, Application.get_env(:test, EhOsContract.Auth.SignIn, [])}",
              "TestWeb.Endpoint"
            ] do
          {index, _} = :binary.match(application, child)
          index
        end

      assert order == Enum.sort(order)
    end
  end
end

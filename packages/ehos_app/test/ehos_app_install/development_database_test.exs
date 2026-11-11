defmodule Mix.Tasks.EhosApp.InstallTest.DevelopmentDatabase do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # The port both configurations give the repo in a new project.
  @port_line ~S'  port: String.to_integer(System.get_env("PGPORT", "5435"))'

  describe "development database" do
    test "gives a new project PostgreSQL from compose.yaml, on the port PGPORT names" do
      igniter = installed()

      compose = content(igniter, "compose.yaml")
      assert lines_with(compose, "image:") == ["    image: postgres:18-alpine"]
      assert lines_with(compose, "5432\"") == [~S'      - "127.0.0.1:${PGPORT:-5435}:5432"']

      assert lines_with(content(igniter, "config/dev.exs"), "port: String") == [@port_line]
      # The test project's `config/test.exs` configures no repo, as phx.new's does: here the port
      # is the repo's whole configuration.
      assert lines_with(content(igniter, "config/test.exs"), "PGPORT") ==
               ["config :test, Test.Repo, " <> String.trim_leading(@port_line)]

      assert setup_alias(igniter) == [
               "deps.get",
               "cmd docker compose up --detach --wait",
               "ecto.setup",
               "assets.setup",
               "assets.build"
             ]
    end

    test "says in the guides that mix setup starts PostgreSQL in Docker" do
      igniter = installed()

      assert lines_with(content(igniter, "DEVELOPMENT.md"), "PostgreSQL") == [
               "`mix setup` fetches the dependencies, starts PostgreSQL, creates and migrates the database `test_dev`,",
               "- **PostgreSQL runs in Docker**, from `compose.yaml`, on port 5435 or the one `PGPORT` names. Start",
               "  own PostgreSQL, export its `PGPORT`, and run the steps of `setup` in `mix.exs` after Docker's."
             ]

      assert lines_with(content(igniter, "README.md"), "PostgreSQL") == [
               "You need [mise](https://mise.jdx.dev), Docker, which runs PostgreSQL from `compose.yaml`, and"
             ]

      assert install().notices |> messages_starting("EHOS: the project is ready.") ==
               [ready_notice()]
    end

    test "leaves a project made before with its own database, and says so" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
        |> install_again()

      refute Igniter.exists?(igniter, "compose.yaml")
      assert lines_with(content(igniter, "config/dev.exs"), "PGPORT") == []
      assert lines_with(content(igniter, "config/test.exs"), "PGPORT") == []
      assert setup_alias(igniter) == phx_test_project() |> setup_alias()

      assert lines_with(content(igniter, "DEVELOPMENT.md"), "PostgreSQL") == [
               "- **PostgreSQL** runs on `localhost:5432` with the user and password `postgres`, as `config/dev.exs`"
             ]

      assert lines_with(content(igniter, "README.md"), "PostgreSQL") == [
               "You need [mise](https://mise.jdx.dev), PostgreSQL 16 or later on `localhost:5432` with the user"
             ]
    end

    test "says to start a database where the project's setup does not start one" do
      notices =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
        |> install_on()
        |> Map.fetch!(:notices)

      assert messages_starting(notices, "EHOS: the project is ready.") ==
               [ready_notice(:own_database)]
    end

    test "names no database setup starts once the developer comments its step out" do
      igniter =
        installed()
        |> edit_file(
          "mix.exs",
          &String.replace(
            &1,
            ~s("cmd docker compose up --detach --wait",),
            ~s(# "cmd docker compose up --detach --wait",)
          )
        )
        |> install_again()

      assert lines_with(content(igniter, "DEVELOPMENT.md"), "PostgreSQL") == [
               "- **PostgreSQL** runs on `localhost:5432` with the user and password `postgres`, as `config/dev.exs`"
             ]
    end

    test "leaves a new project with a Compose file of its own to it" do
      mine = "services: {}\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("docker-compose.yml", mine)
        |> install_again()

      assert content(igniter, "docker-compose.yml") == mine
      refute Igniter.exists?(igniter, "compose.yaml")
      assert lines_with(content(igniter, "config/dev.exs"), "PGPORT") == []
      assert setup_alias(igniter) == phx_test_project() |> setup_alias()
    end
  end

  # The steps of the project's `setup` alias, as Mix reads them.
  defp setup_alias(igniter) do
    [_, rest] = igniter |> content("mix.exs") |> String.split("      setup: ", parts: 2)
    [steps | _] = String.split(rest, "],", parts: 2)
    {steps, []} = Code.eval_string(steps <> "]")
    steps
  end
end

defmodule Mix.Tasks.EhosApp.InstallTest.DevelopmentSignIn do
  # eh-os D-166: on a developer's computer, eh_os_contract_auth's development mode signs a person
  # in with a key it makes at start. What each check of its page and endpoint refuses, and the
  # refusal to start where EHOS could run the application, are eh-os-contract's tests; these hold
  # what the installer writes for it.
  use Mix.Tasks.EhosApp.InstallCase, async: true

  @router "lib/test_web/router.ex"
  @application "lib/test/application.ex"
  @dev_routes "  if Application.compile_env(:test, :dev_routes) do"
  @child ~s|{EhOsContract.Auth.Development, [url: "http://localhost:4000"]}|

  describe "signing a person in on a developer's computer" do
    test "turns the mode on in config/dev.exs, with the stand-ins for people, grants and mail" do
      igniter = installed()

      assert dev_config(igniter) == %{
               development: true,
               people_directory: EhOsContract.Auth.People.Directory.Static,
               granter: EhOsContract.Auth.Grants.Local,
               mail_sender: EhOsContract.Auth.Mail.Local
             }

      for path <- ~w(config/config.exs config/test.exs config/prod.exs config/runtime.exs) do
        refute content(igniter, path) =~ "development:", path
        refute content(igniter, path) =~ "EhOsContract.Auth.Development", path
      end
    end

    test "starts the mode's child after the key store and the sign-in, in every environment" do
      children =
        installed()
        |> content(@application)
        |> children()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)

      at = &Enum.find_index(children, fn child -> String.starts_with?(child, &1) end)

      assert Enum.count(children, &(&1 == @child <> ",")) == 1
      assert at.("{EhOsContract.Auth,") < at.(@child)
      assert at.("{Test.SignIn,") < at.(@child)
      assert at.(@child) < at.("TestWeb.Endpoint")
    end

    test "forwards /dev to the mode's page and endpoint, last in the block compiled in development" do
      router = installed() |> content(@router)
      [dev_routes] = sections(router, @dev_routes, "  end")

      assert String.ends_with?(dev_routes, """
                 scope "/dev" do
                   pipe_through(:browser)

                   live_dashboard("/dashboard", metrics: TestWeb.Telemetry)
                   forward("/mailbox", Plug.Swoosh.MailboxPreview)
                 end

                 forward("/dev", EhOsContract.Auth.Development.Router)
               end
             """)

      assert router |> String.split("EhOsContract.Auth.Development.Router") |> length() == 2
    end

    test "gives a project an earlier version made the mode, its child and its route" do
      igniter = installed()

      earlier =
        igniter
        |> edit_file(@router, &String.replace(&1, ~r/\n *forward\("\/dev".*\n/, "\n"))
        |> edit_file(@application, &String.replace(&1, ",\n      " <> @child, ""))
        |> edit_file("config/dev.exs", &without_development/1)
        |> apply_igniter!()

      refute content(earlier, @router) =~ "Development.Router"
      assert dev_config(earlier) == %{}

      upgraded = earlier |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      for path <- [@router, @application] do
        assert content(upgraded, path) == content(igniter, path), path
      end

      assert dev_config(upgraded) == dev_config(igniter)
    end

    test "says what to add where the router has no block compiled in development alone" do
      igniter =
        phx_test_project()
        |> edit_file(@router, &String.replace(&1, ":dev_routes", ":routes_of_mine"))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert messages_starting(igniter.warnings, "TestWeb.Router has no") == [
               "TestWeb.Router has no `if Application.compile_env(_, :dev_routes)` block, so " <>
                 "the development sign-in was not added. Add it last in the block Phoenix " <>
                 "compiles in development alone, outside any pipeline:\n\n    " <>
                 ~s|forward "/dev", EhOsContract.Auth.Development.Router|
             ]
    end
  end

  # What config/dev.exs sets for the development mode.
  defp dev_config(igniter) do
    "config/dev.exs"
    |> Config.Reader.eval!(content(igniter, "config/dev.exs"), env: :dev)
    |> Keyword.get(:eh_os_contract_auth, [])
    |> Keyword.take([:development, :people_directory, :granter, :mail_sender])
    |> Map.new()
  end

  # config/dev.exs as an earlier version wrote it, with no line for the development mode.
  defp without_development(dev) do
    String.replace(dev, ~r/,\n *development: true(,\n *\w+: [\w.]+)*/, "")
  end
end

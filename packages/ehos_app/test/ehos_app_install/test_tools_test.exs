defmodule Mix.Tasks.EhosApp.InstallTest.TestTools do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # ehos-tools#504: the tools docs/elixir.md's rules assume.
  describe "the test tools and the lint" do
    defp made_before do
      phx_test_project()
      |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
    end

    test "adds Hammox, ExMachina and Credo, and runs Credo in mix precommit" do
      mix = installed() |> content("mix.exs")

      assert mix =~ ~s({:hammox, "~> 1.0", only: :test})
      assert mix =~ ~s({:ex_machina, "~> 2.8", only: :test})
      assert mix =~ ~s({:credo, "~> 1.7", only: [:dev, :test], runtime: false})
      assert mix =~ ~r/precommit: \[[^\]]*"credo"/s
    end

    test "has the cases set up the mocks for every test and import the factories" do
      igniter = installed()

      for path <- ["test/support/data_case.ex", "test/support/conn_case.ex"] do
        case_template = content(igniter, path)
        assert case_template =~ "setup {Test.Mocks, :setup_mocks}", path
        assert case_template =~ "import Test.Factories", path
      end

      mocks = content(igniter, "test/support/mocks.ex")
      assert mocks =~ "Hammox.defmock(Test.ClockMock, for: Test.Clock)"
      assert mocks =~ "Hammox.set_mox_from_context(tags)"
      assert mocks =~ "Hammox.stub_with(Test.ClockMock, Test.ClockImpl)"

      assert content(igniter, "test/support/factories.ex") =~
               "use ExMachina.Ecto, repo: Test.Repo"
    end

    test "gives a new project the clock as its first way out, mocked in tests" do
      igniter = installed()

      assert content(igniter, "lib/test/clock.ex") =~
               "@impl_module Application.compile_env!(:test, [__MODULE__, :impl])"

      assert content(igniter, "config/config.exs") =~
               "config :test, Test.Clock, impl: Test.ClockImpl"

      assert content(igniter, "config/test.exs") =~
               "config :test, Test.Clock, impl: Test.ClockMock"

      assert content(igniter, "test/test/clock_test.exs") =~ "use Hammox.Protect"

      # The docs show the shape on it, where the project has it.
      assert content(igniter, "docs/elixir.md") =~ "`lib/test/clock.ex`\n  is one, the clock."
      assert content(igniter, "TESTING.md") =~ "`Test.ClockMock` is one"
      refute made_before() |> apply_igniter!() |> content("docs/elixir.md") =~ "clock.ex"
    end

    test "holds a new project to its rules with Credo and the conventions test" do
      igniter = installed()

      assert Map.has_key?(igniter.assigns.test_files, ".credo.exs")
      assert content(igniter, "test/conventions_test.exs") =~ "@own_tables []"
    end

    test "asks nothing new of the code of a project made before, and says how to have it" do
      igniter = made_before() |> apply_igniter!()

      refute content(igniter, "mix.exs") =~ ":credo"
      refute Igniter.exists?(igniter, "test/conventions_test.exs")
      refute Igniter.exists?(igniter, "lib/test/clock.ex")
      refute content(igniter, "test/support/mocks.ex") =~ "ClockMock"
      assert content(igniter, "mix.exs") =~ ":hammox"
      assert content(igniter, "test/support/data_case.ex") =~ "setup {Test.Mocks, :setup_mocks}"

      assert Enum.any?(
               made_before().notices,
               &(&1 =~ "An upgrade adds neither to a project made before")
             )
    end

    test "leaves a project with a mocks module of its own to its way" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "test/support/mocks.ex",
          "Mox.defmock(Test.Mock, for: Test.B)\n"
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(igniter, "mix.exs") =~ ":hammox"
      # No `"credo"` in precommit without the dependency that runs it.
      refute content(igniter, "mix.exs") =~ ~s("credo")
      refute content(igniter, "test/support/data_case.ex") =~ "setup_mocks"
      assert content(igniter, "test/support/mocks.ex") == "Mox.defmock(Test.Mock, for: Test.B)\n"
    end

    test "gives a case that imports a factory module of its own no second one" do
      igniter =
        phx_test_project()
        |> Igniter.update_elixir_file("test/support/data_case.ex", fn zipper ->
          {:ok, zipper} = Igniter.Code.Function.move_to_function_call(zipper, :quote, 1)
          {:ok, body} = Igniter.Code.Common.move_to_do_block(zipper)
          {:ok, Igniter.Code.Common.add_code(body, "import Test.Factory")}
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      data_case = content(igniter, "test/support/data_case.ex")
      assert data_case =~ "import Test.Factory\n"
      refute data_case =~ "import Test.Factories"
      assert data_case =~ "setup {Test.Mocks, :setup_mocks}"
    end

    test "tells a project whose case it cannot place the hooks in what to add" do
      igniter =
        phx_test_project()
        |> Igniter.create_or_update_file(
          "test/support/data_case.ex",
          "defmodule Test.DataCase do\nend\n",
          &Rewrite.Source.update(&1, :content, fn _ -> "defmodule Test.DataCase do\nend\n" end)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "Test.DataCase is not as Phoenix wrote it" and
                   &1 =~ "setup {Test.Mocks, :setup_mocks}")
             )
    end

    # A real project's second run has read none of its files: the docs still name the clock.
    test "keeps naming the clock on a run that has not read the mocks module" do
      installed = installed()

      second =
        %{installed | rewrite: Rewrite.drop(installed.rewrite, ["test/support/mocks.ex"])}
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(second, "TESTING.md") =~ "`Test.ClockMock` is one"
      assert content(second, "docs/elixir.md") =~ "`lib/test/clock.ex`\n  is one, the clock."
    end

    test "brings back no hook the developer removed" do
      igniter = installed()

      removed =
        igniter
        |> content("test/support/data_case.ex")
        |> String.replace("setup {Test.Mocks, :setup_mocks}\n", "")

      igniter =
        igniter
        |> replace_file("test/support/data_case.ex", removed)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(igniter, "test/support/data_case.ex") =~ "setup_mocks"
    end

    test "says no check holds what a project made before does not run" do
      elixir = made_before() |> apply_igniter!() |> content("docs/elixir.md")

      assert elixir =~ "No test holds this here yet"
      assert elixir =~ "A review reads for them:\n  this project runs no Credo."
      refute elixir =~ "`test/conventions_test.exs` holds this"
    end

    test "places each hook once, and leaves a case that already calls setup_mocks/1 alone" do
      igniter = installed() |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      for path <- ["test/support/data_case.ex", "test/support/conn_case.ex"] do
        case_template = content(igniter, path)
        assert length(String.split(case_template, "setup {Test.Mocks, :setup_mocks}")) == 2, path
        assert length(String.split(case_template, "import Test.Factories")) == 2, path
      end
    end
  end
end

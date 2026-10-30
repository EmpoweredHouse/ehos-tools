defmodule Mix.Tasks.EhosApp.InstallTest.Boundary do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # The areas Boundary holds apart in a new project (ehos-tools#506), as the modules declare them.
  @declarations %{
    "lib/test.ex" => "  use Boundary, deps: [], exports: [Access, LogRedaction]",
    "lib/test_web.ex" => "  use Boundary, deps: [Test], exports: [Endpoint]",
    "lib/test/application.ex" => "  use Boundary, top_level?: true, deps: [Test, TestWeb]",
    "lib/test/repo.ex" => "  use Boundary",
    "lib/test/clock.ex" => "  use Boundary",
    "lib/test/access.ex" => "  use Boundary",
    "test/support/conn_case.ex" =>
      "  use Boundary, top_level?: true, check: [in: false, out: false]"
  }

  describe "the areas' boundaries" do
    test "give a new project Boundary, its compiler first" do
      igniter = installed()

      assert Igniter.Project.Deps.get_dep(igniter, :boundary) ==
               {:ok, ~s({:boundary, "~> 0.12", runtime: false})}

      assert trimmed_lines_starting(igniter, "mix.exs", "compilers:") == [
               "compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers() ++ [:eh_os_contract],"
             ]
    end

    test "declare the root, the web, the application, the repo and the template's behaviours" do
      igniter = installed()

      assert Map.new(@declarations, fn {path, _} -> {path, declarations(igniter, path)} end) ==
               Map.new(@declarations, fn {path, line} -> {path, [line]} end)
    end

    test "put the repo's after its use of Ecto.Repo, where Igniter finds a repo" do
      assert installed() |> content("lib/test/repo.ex") == """
             defmodule Test.Repo do
               use Ecto.Repo,
                 otp_app: :test,
                 adapter: Ecto.Adapters.Postgres

               use Boundary
             end
             """
    end

    test "put the test case's before its own use, outside every boundary" do
      assert installed() |> content("test/support/conn_case.ex") |> lines_with("  use ") ==
               [
                 "  use Boundary, top_level?: true, check: [in: false, out: false]",
                 "  use ExUnit.CaseTemplate",
                 "      use TestWeb, :verified_routes"
               ]
    end

    test "say how a new context declares its own, in docs/elixir.md" do
      assert installed()
             |> content("docs/elixir.md")
             |> lines_with("**Each area is a boundary.**") ==
               [
                 "- **Each area is a boundary.** `lib/test.ex` exports what the web and the application"
               ]
    end

    test "change nothing on a second run" do
      installed() |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    test "export no Access from a new project that was not given the access page" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("lib/test/access.ex", "defmodule Test.Access do\nend\n")
        |> install_on()
        |> apply_igniter!()

      assert declarations(igniter, "lib/test.ex") == [
               "  use Boundary, deps: [], exports: [LogRedaction]"
             ]

      assert declarations(igniter, "lib/test/access.ex") == []
    end

    test "leave a module that already declares its boundary as it is" do
      root = """
      defmodule Test do
        use Boundary, deps: [], exports: [Mine]
      end
      """

      igniter =
        phx_test_project()
        |> replace_file("lib/test.ex", root)
        |> install_on()
        |> apply_igniter!()

      assert content(igniter, "lib/test.ex") == root
    end

    test "are not added to a project made before, which is told how to adopt them" do
      run =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
        |> install_on()

      igniter = apply_igniter!(run)

      assert Igniter.Project.Deps.get_dep(igniter, :boundary) == {:ok, nil}
      refute igniter |> content("mix.exs") =~ ":boundary"

      for {path, _} <- @declarations,
          Igniter.exists?(igniter, path),
          do: assert(declarations(igniter, path) == [], path)

      refute igniter |> content("docs/elixir.md") =~ "**Each area is a boundary.**"

      assert [notice] = notices_about(run, "docs/elixir.md's areas are held by Boundary")
      assert notice =~ ~s({:boundary, "~> 0.12", runtime: false})
    end
  end

  # Each `use Boundary` in the file, on one line however Igniter wrapped its options.
  defp declarations(igniter, path) do
    igniter
    |> content(path)
    |> String.split("\n")
    |> Enum.chunk_while(
      nil,
      fn
        line, nil -> if line =~ "use Boundary", do: continued(line, ""), else: {:cont, nil}
        line, acc -> continued(String.trim(line), acc <> " ")
      end,
      fn acc -> {:cont, acc, nil} end
    )
    |> Enum.reject(&is_nil/1)
  end

  defp continued(line, acc) do
    if String.ends_with?(line, ","), do: {:cont, acc <> line}, else: {:cont, acc <> line, nil}
  end
end

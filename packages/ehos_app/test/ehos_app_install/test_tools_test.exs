defmodule Mix.Tasks.EhosApp.InstallTest.TestTools do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # Each test case from `use ExUnit.CaseTemplate` to the end of `using`, with the hooks placed.
  @data_case_hooks ~S'''
    use ExUnit.CaseTemplate

    setup {Test.Mocks, :setup_mocks}

    using do
      quote do
        alias Test.Repo

        import Ecto
        import Ecto.Changeset
        import Ecto.Query
        import Test.DataCase
        import Test.Factories
      end
    end
  '''

  @conn_case_hooks ~S'''
    use ExUnit.CaseTemplate

    setup {Test.Mocks, :setup_mocks}

    using do
      quote do
        # The default endpoint for testing
        @endpoint TestWeb.Endpoint

        use TestWeb, :verified_routes

        # Import conveniences for testing with connections
        import Plug.Conn
        import Phoenix.ConnTest
        import TestWeb.ConnCase
        import Test.Factories
      end
    end
  '''

  @precommit ~S'''
        precommit: [
          &hex_audit/1,
          "compile --warnings-as-errors",
          "deps.unlock --unused",
          "format",
          "test --warnings-as-errors",
          "ehos_contract.check",
          "credo"
        ]
  '''

  # docs/elixir.md's first rule of "Behaviours", in a new project.
  @behaviour_rule ~S'''
  - **A collaborator a caller's test replaces is a behaviour**: every way out of the application (an
    outside system, EHOS's APIs, mail), and every module of its own whose callers' tests should not
    run it, such as a context a page calls. `Test.<Name>` declares its `@callback`s and
    `current/0`, which reads the implementation from configuration; `Test.<Name>Impl` is
    the real one, in the same file. Callers call `<Name>.current().fun(...)`.
    `lib/test/clock.ex` is one, the clock.
  '''

  # TESTING.md's first rule of "Doubles", in a new project.
  @mock_rule ~S'''
  - **A mock per behaviour**, declared with `Hammox.defmock/2` in `test/support/mocks.ex` and named in
    `config/test.exs`. Hammox checks each `expect` and `stub` against the behaviour's types; a
    default from `stub_with/2` is not checked.
    `Test.ClockMock` is one, and `test/test/clock_test.exs` holds the real clock to its
    behaviour with `Hammox.Protect`. A test
    never swaps an implementation with `Application.put_env/3` or `System.put_env/2`, and is never
    made non-async for it.
  '''

  # ehos-tools#504: the tools docs/elixir.md's rules assume.
  describe "the test tools and the lint" do
    test "adds Hammox, ExMachina and Credo, and runs Credo in mix precommit" do
      igniter = installed()

      assert Igniter.Project.Deps.get_dep(igniter, :hammox) ==
               {:ok, ~s({:hammox, "~> 1.0", only: :test})}

      assert Igniter.Project.Deps.get_dep(igniter, :ex_machina) ==
               {:ok, ~s({:ex_machina, "~> 2.8", only: :test})}

      assert Igniter.Project.Deps.get_dep(igniter, :credo) ==
               {:ok, ~s({:credo, "~> 1.7", only: [:dev, :test], runtime: false})}

      assert precommit(igniter) == @precommit
    end

    test "has the cases set up the mocks for every test and import the factories" do
      igniter = installed()

      assert hooks(igniter, "test/support/data_case.ex") == @data_case_hooks
      assert hooks(igniter, "test/support/conn_case.ex") == @conn_case_hooks

      assert content(igniter, "test/support/mocks.ex") == ~S'''
             defmodule Test.Mocks do
               @moduledoc """
               The mocks of the application's behaviours, each named in `config/test.exs` where its behaviour's
               `current/0` reads, and what the test cases stub them with (docs/elixir.md, TESTING.md).

               A test expects the calls it is about in `mock_<function>` helpers of its own file.
               """

               Hammox.defmock(Test.ClockMock, for: Test.Clock)

               Hammox.defmock(Test.AccessMock, for: Test.Access)

               @doc """
               Sets Mox's mode from the test, private when it is `async` and global otherwise, so that a page's
               or a task's process sees the mocks; checks at its end that every call it expected was made; and
               stubs each mock with its default.
               """
               @spec setup_mocks(map()) :: :ok
               def setup_mocks(tags) do
                 Hammox.set_mox_from_context(tags)
                 Hammox.verify_on_exit!(tags)
                 Hammox.stub_with(Test.ClockMock, Test.ClockImpl)
                 :ok
               end
             end
             '''

      assert content(igniter, "test/support/factories.ex") == ~S'''
             defmodule Test.Factories do
               @moduledoc """
               The tests' data, with ExMachina: `build(:name)` or `insert(:name)`, with any field given in its
               place. A struct more than one test builds gets a factory here, rather than a helper in a test
               file (TESTING.md, "Doubles"). The test cases import it.
               """

               use ExMachina.Ecto, repo: Test.Repo
             end
             '''
    end

    @tag :tmp_dir
    test "gives a new project the clock as its first way out, mocked in tests", %{
      tmp_dir: tmp_dir
    } do
      igniter = installed()

      assert content(igniter, "lib/test/clock.ex") == ~S'''
             defmodule Test.Clock do
               @moduledoc """
               The time, as a way out of the application (docs/elixir.md, "Behaviours"). In tests it is
               `Test.ClockMock`: a test that must say what time it is expects it there, a test on
               `DataCase` or `ConnCase` otherwise gets the real clock from `setup_mocks/1`, and any other test
               that reaches it, or a process that test did not start, stubs or allows it first.
               """

               use Boundary

               @doc "Now, in UTC."
               @callback now() :: DateTime.t()

               @doc "Today, in UTC."
               @callback today() :: Date.t()

               @impl_module Application.compile_env!(:test, [__MODULE__, :impl])

               @doc "The implementation `config/*.exs` chose."
               @spec current() :: module()
               def current, do: @impl_module
             end

             defmodule Test.ClockImpl do
               @moduledoc false
               @behaviour Test.Clock

               @impl true
               def now, do: DateTime.utc_now()

               @impl true
               def today, do: Date.utc_today()
             end
             '''

      assert read_config(igniter, :dev, tmp_dir)[:test][Test.Clock] == [impl: Test.ClockImpl]
      assert read_config(igniter, :test, tmp_dir)[:test][Test.Clock] == [impl: Test.ClockMock]

      assert content(igniter, "test/test/clock_test.exs") == ~S'''
             defmodule Test.ClockTest do
               # The real clock, held to its behaviour's types by Hammox.
               use ExUnit.Case, async: true
               use Hammox.Protect, module: Test.ClockImpl, behaviour: Test.Clock

               test "tells the time and the date in UTC" do
                 assert %DateTime{time_zone: "Etc/UTC"} = now()
                 assert %Date{} = today()
               end
             end
             '''

      # The docs show the shape on it, where the project has it.
      assert rule(igniter, "docs/elixir.md", "- **A collaborator") == @behaviour_rule
      assert rule(igniter, "TESTING.md", "- **A mock per behaviour**") == @mock_rule

      assert rule(apply_igniter!(made_before()), "docs/elixir.md", "- **A collaborator") == ~S'''
             - **A collaborator a caller's test replaces is a behaviour**: every way out of the application (an
               outside system, EHOS's APIs, mail), and every module of its own whose callers' tests should not
               run it, such as a context a page calls. `Test.<Name>` declares its `@callback`s and
               `current/0`, which reads the implementation from configuration; `Test.<Name>Impl` is
               the real one, in the same file. Callers call `<Name>.current().fun(...)`.
             '''
    end

    test "holds a new project to its rules with Credo and the conventions test" do
      igniter = installed()

      assert content(igniter, ".credo.exs") == ~S'''
             # Credo, as `mix precommit` runs it, and `ehosctl verify` from 0.28.0: its default checks, and
             # the opt-in ones that hold a rule of docs/elixir.md. Change it here; neither passes flags of
             # its own.
             %{
               configs: [
                 %{
                   name: "default",
                   files: %{
                     included: ["lib/", "test/", "config/", "priv/repo/"],
                     excluded: [~r"/_build/", ~r"/deps/"]
                   },
                   checks: %{
                     extra: [
                       {Credo.Check.Refactor.AppendSingleItem, []}
                     ]
                   }
                 }
               ]
             }
             '''

      assert content(igniter, "test/conventions_test.exs") == ~S'''
             defmodule ConventionsTest do
               @moduledoc """
               The rules of docs/elixir.md a test can hold: a table is queried only by the module that owns it,
               so nothing else imports, requires, aliases or calls `Ecto.Query`.
               """

               use ExUnit.Case, async: true

               # Modules that own a table outside the engine's log, and so build queries of it. A read
               # model's projection and a contract's query read their table as their contract says, and are
               # found without being listed.
               @own_tables []

               # Modules written before the rule. Remove one once its queries are its table owner's functions;
               # the second test fails when one here no longer uses Ecto.Query, so the list only shrinks.
               @older []

               test "only a module that owns a table uses Ecto.Query" do
                 strays =
                   for module <- using_ecto_query(),
                       not contract_part?(module),
                       module not in @own_tables,
                       module not in @older,
                       do: module

                 assert strays == [],
                        "These use Ecto.Query but own no table; ask the owner's functions instead " <>
                          "(docs/elixir.md): #{inspect(strays)}"
               end

               test "every module the lists above name still uses Ecto.Query" do
                 using = using_ecto_query()
                 stale = Enum.reject(@own_tables ++ @older, &(&1 in using))

                 assert stale == [], "No longer uses Ecto.Query; remove it from the list: #{inspect(stale)}"
               end

               # Read as code, so a comment or a string that names it does not count: each module, a nested
               # one by its full name and apart from the module around it, that imports, requires or aliases
               # `Ecto.Query` (`alias Ecto.{Changeset, Query}` too), or calls one of its functions by name.
               defp using_ecto_query do
                 for path <- Path.wildcard("lib/**/*.ex"),
                     {module, body} <- path |> File.read!() |> Code.string_to_quoted!() |> modules([]),
                     uses_ecto_query?(body),
                     do: module
               end

               defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, outer) do
                 if Enum.all?(parts, &is_atom/1) do
                   name = outer ++ parts
                   {nested, own} = nested(body)
                   [{Module.concat(name), own} | Enum.flat_map(nested, &modules(&1, name))]
                 else
                   []
                 end
               end

               defp modules({:__block__, _, nodes}, outer), do: Enum.flat_map(nodes, &modules(&1, outer))
               defp modules(_other, _outer), do: []

               defp nested({:__block__, meta, nodes}) do
                 {nested, own} = Enum.split_with(nodes, &match?({:defmodule, _, _}, &1))
                 {nested, {:__block__, meta, own}}
               end

               defp nested({:defmodule, _, _} = node), do: {[node], nil}
               defp nested(node), do: {[], node}

               defp uses_ecto_query?(body) do
                 {_ast, found?} =
                   Macro.prewalk(body, false, fn
                     {directive, _, [{:__aliases__, _, [:Ecto, :Query]} | _]} = node, _found?
                     when directive in [:import, :require, :alias] ->
                       {node, true}

                     {directive, _, [{{:., _, [{:__aliases__, _, [:Ecto]}, :{}]}, _, inner} | _]} = node,
                     found?
                     when directive in [:import, :require, :alias] ->
                       {node, found? or Enum.any?(inner, &match?({:__aliases__, _, [:Query]}, &1))}

                     {{:., _, [{:__aliases__, _, [:Ecto, :Query]}, function]}, _, _} = node, _found?
                     when function != :t ->
                       {node, true}

                     node, found? ->
                       {node, found?}
                   end)

                 found?
               end

               # A read model's projection and a query read their read model's table, as their contract says;
               # a decider, a policy or an effect that queries a table is a stray like any other module.
               defp contract_part?(module) do
                 Code.ensure_loaded?(module) and function_exported?(module, :__eh_os_implementation__, 0) and
                   module.__eh_os_implementation__().kind in [:read_model, :query]
               end
             end
             '''
    end

    # A real project's second run has read none of its files: the docs still name the clock.
    test "keeps naming the clock on a run that has not read the mocks module" do
      installed = installed()

      second =
        %{installed | rewrite: Rewrite.drop(installed.rewrite, ["test/support/mocks.ex"])}
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert rule(second, "TESTING.md", "- **A mock per behaviour**") == @mock_rule
      assert rule(second, "docs/elixir.md", "- **A collaborator") == @behaviour_rule
    end

    test "places each hook once, and leaves a case that already calls setup_mocks/1 alone" do
      igniter = installed() |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      assert hooks(igniter, "test/support/data_case.ex") == @data_case_hooks
      assert hooks(igniter, "test/support/conn_case.ex") == @conn_case_hooks
    end

    test "asks nothing new of the code of a project made before, and says how to have it" do
      igniter = made_before()

      assert notices(igniter, "docs/elixir.md's rules are held") == [
               """
               docs/elixir.md's rules are held by Credo and test/conventions_test.exs in a new project.
               Neither was added here: the installer adds them only where it finds Phoenix's welcome
               page untouched and no ehos.yaml, since other code may already break them. To adopt
               them, add {:credo, "~> 1.7", only: [:dev, :test], runtime: false}, append "credo" to the
               precommit alias, and fix what `mix credo` finds. ehosctl verify runs Credo, from 0.28.0,
               once mix.lock has it. The two files are in ehos_app's priv/templates/ehos_app.install/
               (credo.exs and conventions_test.exs.eex, as test/conventions_test.exs): list in the test
               the modules that already use Ecto.Query outside a table's owner.
               """
             ]

      igniter = apply_igniter!(igniter)

      assert Igniter.Project.Deps.get_dep(igniter, :credo) == {:ok, nil}
      refute Igniter.exists?(igniter, "test/conventions_test.exs")
      refute Igniter.exists?(igniter, "lib/test/clock.ex")

      assert content(igniter, "test/support/mocks.ex") == ~S'''
             defmodule Test.Mocks do
               @moduledoc """
               The mocks of the application's behaviours, each named in `config/test.exs` where its behaviour's
               `current/0` reads, and what the test cases stub them with (docs/elixir.md, TESTING.md).

               A test expects the calls it is about in `mock_<function>` helpers of its own file.
               """

               Hammox.defmock(Test.AccessMock, for: Test.Access)

               @doc """
               Sets Mox's mode from the test, private when it is `async` and global otherwise, so that a page's
               or a task's process sees the mocks; checks at its end that every call it expected was made; and
               stubs each mock with its default.
               """
               @spec setup_mocks(map()) :: :ok
               def setup_mocks(tags) do
                 Hammox.set_mox_from_context(tags)
                 Hammox.verify_on_exit!(tags)
                 :ok
               end
             end
             '''

      assert Igniter.Project.Deps.get_dep(igniter, :hammox) ==
               {:ok, ~s({:hammox, "~> 1.0", only: :test})}

      assert hooks(igniter, "test/support/data_case.ex") == @data_case_hooks
    end

    test "asks nothing new of the code of a Phoenix project with a home page of its own" do
      igniter =
        phx_test_project()
        |> replace_file("lib/test_web/controllers/page_html/home.html.heex", "<h1>Mine</h1>\n")
        |> install_on()

      assert [_notice] = notices(igniter, "docs/elixir.md's rules are held")

      igniter = apply_igniter!(igniter)

      assert Igniter.Project.Deps.get_dep(igniter, :credo) == {:ok, nil}
      refute Igniter.exists?(igniter, ".credo.exs")
      refute Igniter.exists?(igniter, "test/conventions_test.exs")
      refute Igniter.exists?(igniter, "lib/test/clock.ex")

      assert precommit(igniter) == """
                   precommit: [
                     &hex_audit/1,
                     "compile --warnings-as-errors",
                     "deps.unlock --unused",
                     "format",
                     "test --warnings-as-errors",
                     "ehos_contract.check"
                   ]
             """

      igniter |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    test "says no check holds what a project made before does not run" do
      igniter = apply_igniter!(made_before())

      assert rule(igniter, "docs/elixir.md", "- **A table is read only") == ~S'''
             - **A table is read only by the module that owns it.** It answers rows, never a query for the
               caller to finish, and is the only module that uses `Ecto.Query`. No test holds this here yet: a review reads for it. A contract's
               part, a projection or a query, owns or reads its read model's table as its contract says.
             '''

      assert rule(igniter, "docs/elixir.md", "- **No `acc ++ [item]` in a loop") == ~S'''
             - **No `acc ++ [item]` in a loop, no `length/1` to test a list's shape**, a predicate ends in `?`
               and never starts with `is_`. A review reads for them:
               this project runs no Credo.
             '''
    end

    test "leaves a project with a mocks module of its own to its way" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "test/support/mocks.ex",
          "Mox.defmock(Test.Mock, for: Test.B)\n"
        )
        |> install_again()

      # Hammox alone, for the access page this run gave it, whose test holds Access to its
      # behaviour. This file defines no Test.Mocks to declare the mock in, so it is left as it
      # is, and the run says what to add.
      assert Igniter.Project.Deps.get_dep(igniter, :hammox) ==
               {:ok, ~s({:hammox, "~> 1.0", only: :test})}

      assert Igniter.Project.Deps.get_dep(igniter, :ex_machina) == {:ok, nil}

      assert content(igniter, "test/support/mocks.ex") == "Mox.defmock(Test.Mock, for: Test.B)\n"

      # No `"credo"` in precommit without the dependency that runs it.
      assert precommit(igniter) == """
                   precommit: [
                     &hex_audit/1,
                     "compile --warnings-as-errors",
                     "deps.unlock --unused",
                     "format",
                     "test --warnings-as-errors",
                     "ehos_contract.check"
                   ]
             """

      assert hooks(igniter, "test/support/data_case.ex") == """
               use ExUnit.CaseTemplate

               using do
                 quote do
                   alias Test.Repo

                   import Ecto
                   import Ecto.Changeset
                   import Ecto.Query
                   import Test.DataCase
                 end
               end
             """

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
        |> install_again()

      assert hooks(igniter, "test/support/data_case.ex") == """
               use ExUnit.CaseTemplate

               setup {Test.Mocks, :setup_mocks}

               using do
                 quote do
                   alias Test.Repo

                   import Ecto
                   import Ecto.Changeset
                   import Ecto.Query
                   import Test.DataCase
                   import Test.Factory
                 end
               end
             """
    end

    test "brings back no hook the developer removed" do
      igniter = installed()

      removed =
        igniter
        |> content("test/support/data_case.ex")
        |> String.replace("  setup {Test.Mocks, :setup_mocks}\n\n", "")

      igniter =
        igniter
        |> replace_file("test/support/data_case.ex", removed)
        |> install_again()

      assert hooks(igniter, "test/support/data_case.ex") == """
               use ExUnit.CaseTemplate

               using do
                 quote do
                   alias Test.Repo

                   import Ecto
                   import Ecto.Changeset
                   import Ecto.Query
                   import Test.DataCase
                   import Test.Factories
                 end
               end
             """
    end

    test "tells a project whose case it cannot place the hooks in what to add" do
      igniter =
        phx_test_project()
        |> replace_file("test/support/data_case.ex", "defmodule Test.DataCase do\nend\n")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert notices(igniter, "Test.DataCase is not as Phoenix wrote it") == [
               """
               Test.DataCase is not as Phoenix wrote it, so the installer placed none of the lines below.
               For the mocks and factories TESTING.md describes, a test case carries each once:

                   # after `use ExUnit.CaseTemplate`
                   setup {Test.Mocks, :setup_mocks}

                   # inside the quote of `using`
                   import Test.Factories
               """
             ]
    end
  end

  describe "the test of every callback's @doc" do
    test "gives a new project the test that holds every callback of its behaviours to a @doc" do
      test = content(installed(), "test/callback_docs_test.exs")

      assert lines_with(test, "defmodule") == ["defmodule CallbackDocsTest do"]

      assert lines_with(test, ":application.get_key") == [
               "    {:ok, modules} = :application.get_key(:test, :modules)"
             ]
    end

    test "gives a project made before the test too, and says what its failures ask" do
      igniter = made_before()

      assert Igniter.exists?(igniter, "test/callback_docs_test.exs")

      assert notices(igniter, "test/callback_docs_test.exs now holds") == [
               """
               test/callback_docs_test.exs now holds docs/elixir.md's rule that every @callback of the
               application's behaviours has a @doc: run mix test, and give each callback it lists one
               saying what it does, what it answers and how it fails.
               """
             ]

      assert igniter |> content("docs/elixir.md") |> lines_with("callback_docs_test") == [
               "  `test/callback_docs_test.exs` holds this."
             ]

      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "says what its failures ask to a Phoenix project with code of its own" do
      run =
        phx_test_project()
        |> replace_file("lib/test_web/controllers/page_html/home.html.heex", "<h1>Mine</h1>\n")
        |> install_on()

      assert notices(run, "test/callback_docs_test.exs now holds") != []
      assert notices(install(), "test/callback_docs_test.exs now holds") == []
    end

    test "leaves a test of that name the project has as it is" do
      mine = "defmodule CallbackDocsTest do\nend\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("test/callback_docs_test.exs", mine)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "test/callback_docs_test.exs") == mine
      assert notices(igniter, "test/callback_docs_test.exs now holds") == []
    end
  end

  # A project an earlier version made, which it shows by its `ehos.yaml`, installed again.
  defp made_before do
    phx_test_project()
    |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
    |> apply_igniter!()
    |> Igniter.compose_task("ehos_app.install", [])
  end

  defp notices(igniter, start), do: Enum.filter(igniter.notices, &String.starts_with?(&1, start))

  defp hooks(igniter, path),
    do: igniter |> content(path) |> lines("  use ExUnit.CaseTemplate", "  end")

  # The rule of the Markdown file at `path` whose item starts with `start`, to the next item.
  defp rule(igniter, path, start) do
    [first | rest] =
      igniter
      |> content(path)
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, start)))

    rest = Enum.take_while(rest, &(&1 != "" and not String.starts_with?(&1, "- ")))
    Enum.join([first | rest], "\n") <> "\n"
  end
end

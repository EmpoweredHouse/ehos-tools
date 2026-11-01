defmodule EhosTools.ConventionsCase do
  @moduledoc """
  The rule of T-20 a test can hold, for every package of ehos-tools: only a behaviour's
  implementation, `XImpl` beside its `X`, runs a program, calls the network, reads the process
  environment, the home directory, the terminal or the clock, or waits, so every caller reaches
  them through a behaviour a test replaces.

  A package's conventions test uses it with its application and the modules of its `lib/` allowed
  a way out anyway, each with its reason beside it; a behaviour's `XImpl`, which may reach one
  already, is never on that list:

      defmodule Ehosctl.ConventionsTest do
        use EhosTools.ConventionsCase,
          async: true,
          app: :ehosctl,
          # Runs while Mix compiles ehosctl, before any configuration chooses an implementation.
          allowed: [Ehosctl.Build]
      end

  Each module is read as the compiler expanded it, from its `debug_info`: an alias, an import or
  a capture already names the module it calls there, so `alias DateTime, as: DT` or
  `import System` hides nothing (ehos-tools#571), and a comment or a string that names a function
  is not code. The case also tests that reading, under the package's own build.

  It lives in the repository's `test/support/`, which each package compiles in `test` alone
  through its `elixirc_paths(:test)`: one copy for every package, and no package depends on
  another for its tests (ehos-tools#690).
  """

  use ExUnit.CaseTemplate

  using opts do
    app = Keyword.fetch!(opts, :app)
    allowed = Keyword.get(opts, :allowed, [])

    quote do
      test "only a behaviour's implementation runs a program, calls the network, reads the " <>
             "environment, the home directory, the terminal or the clock, or waits" do
        EhosTools.ConventionsCase.assert_held(unquote(app), unquote(allowed))
      end

      test "sees a way out called through an alias, an import or a capture" do
        # Nested in the package's test module by a one-part name: `EhosTools.…` here would make
        # `EhosTools` an alias of the test module's own `EhosTools`, hiding this case.
        {:module, _module, beam, _} =
          defmodule Hidden do
            @moduledoc false
            @compile :debug_info
            alias DateTime, as: DT
            import System, only: [get_env: 1]

            def now, do: DT.utc_now()
            def home, do: get_env("HOME")
            def run, do: Enum.map(["true"], &System.cmd(&1, []))
          end

        assert EhosTools.ConventionsCase.ways_out(beam) == [
                 {DateTime, :utc_now},
                 {System, :cmd},
                 {System, :get_env}
               ]
      end

      test "fails on an allowed module that is a behaviour's implementation" do
        defmodule Clock do
          @moduledoc false
          @callback now() :: DateTime.t()
        end

        defmodule ClockImpl do
          @moduledoc false
          @behaviour Clock

          @impl Clock
          def now, do: DateTime.utc_now()
        end

        error =
          assert_raise ExUnit.AssertionError, fn ->
            EhosTools.ConventionsCase.assert_held(unquote(app), unquote(allowed) ++ [ClockImpl])
          end

        assert error.message ==
                 "These are allowed a way out, and are a behaviour's implementation, which " <>
                   "may reach one anyway; take them off the list: #{inspect([ClockImpl])}"
      end

      test "fails on an allowed module that is no longer compiled" do
        gone = Module.concat(__MODULE__, GoneImpl)
        lib = Path.join(Path.dirname(Mix.Project.project_file()), "lib") <> "/"

        error =
          assert_raise ExUnit.AssertionError, fn ->
            EhosTools.ConventionsCase.assert_held(unquote(app), unquote(allowed) ++ [gone])
          end

        assert error.message ==
                 "These are allowed a way out, and reach none from #{lib}; take them off the " <>
                   "list: #{inspect([gone])}"
      end

      test "sees no way out in a call that only names one" do
        {:module, _module, beam, _} =
          defmodule Named do
            @moduledoc false
            @compile :debug_info
            # System.cmd/3 runs a program; this says so, and runs none.
            def said, do: "System.cmd(\"git\", [])"
            def options, do: :httpc.ssl_verify_host_options(true)
          end

        assert EhosTools.ConventionsCase.ways_out(beam) == []
      end
    end
  end

  @doc """
  Fails unless every module of `app` compiled from its package's `lib/` that reaches a way out is
  a behaviour's implementation or in `allowed`, and every module in `allowed` is no behaviour's
  implementation and still reaches one, so the list never outlives its reasons.
  """
  @spec assert_held(atom(), [module()]) :: true
  def assert_held(app, allowed) do
    # This package's `lib/`, from where its `mix.exs` is, whatever directory the test runs in.
    lib = Path.join(Path.dirname(Mix.Project.project_file()), "lib") <> "/"
    {:ok, modules} = :application.get_key(app, :modules)
    in_lib = Enum.filter(modules, &in_lib?(&1, lib))

    # None when the beams were compiled at another path (a `_build` copied or restored from a
    # cache): then this test would check nothing.
    assert in_lib != [], "no module of #{app} is compiled from #{lib}"

    reaching = for module <- in_lib, ways_out(object_code(module)) != [], do: module

    strays =
      for module <- reaching,
          module not in allowed,
          not implementation?(module),
          do: module

    assert strays == [],
           "These reach a program, the network, the environment, the home directory, the " <>
             "terminal, the clock or a wait directly; call them " <>
             "through a behaviour instead (T-20, CONTRIBUTING.md): #{inspect(strays)}"

    exempt = Enum.filter(allowed, &implementation?/1)

    assert exempt == [],
           "These are allowed a way out, and are a behaviour's implementation, which may reach " <>
             "one anyway; take them off the list: #{inspect(exempt)}"

    stale = Enum.reject(allowed, &(&1 in reaching))

    assert stale == [],
           "These are allowed a way out, and reach none from #{lib}; take them off the " <>
             "list: #{inspect(stale)}"
  end

  @doc """
  The ways out the compiled module in `beam` calls, each once and sorted, as
  `{module, function}`, from the code Elixir expanded.
  """
  @spec ways_out(binary()) :: [{module(), atom()}]
  def ways_out(beam) do
    {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(beam, [:debug_info])

    {:ok, %{definitions: definitions}} = backend.debug_info(:elixir_v1, module, data, [])

    # A definition and its clauses are tuples of four, which `Macro.prewalk/3` would not enter.
    clauses =
      for {_name_arity, _kind, _meta, clauses} <- definitions,
          {_clause_meta, args, guards, body} <- clauses,
          do: [args, guards, body]

    {_ast, found} =
      Macro.prewalk(clauses, MapSet.new(), fn
        {{:., _, [callee, function]}, _, _} = node, found
        when is_atom(callee) and is_atom(function) ->
          if way_out?(callee, function),
            do: {node, MapSet.put(found, {callee, function})},
            else: {node, found}

        node, found ->
          {node, found}
      end)

    Enum.sort(found)
  end

  # The module's beam as compiled, read from the code path: under `mix test --cover` the loaded
  # module is cover's, which `:code.which/1` names `:cover_compiled`, with no file to read.
  defp object_code(module) do
    {^module, beam, _path} = :code.get_object_code(module)
    beam
  end

  # Under the package's `lib/`, wherever the checkout is: a `lib` above it (`/var/lib/…`) would
  # take in `test/support/` too.
  defp in_lib?(module, lib),
    do: module.module_info(:compile)[:source] |> to_string() |> String.starts_with?(lib)

  # `XImpl` that declares `@behaviour X`, the shape T-20 gives an implementation. A module that
  # is not compiled is none: one left on the `allowed:` list after a rename is reported as stale.
  defp implementation?(module) do
    Code.ensure_loaded?(module) and implements_its_behaviour?(module)
  end

  defp implements_its_behaviour?(module) do
    behaviour =
      module |> inspect() |> String.replace_suffix("Impl", "") |> then(&Module.concat([&1]))

    behaviours = List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
    String.ends_with?(inspect(module), "Impl") and behaviour in behaviours
  end

  defp way_out?(System, function),
    do:
      function in [
        :cmd,
        :shell,
        :get_env,
        :fetch_env,
        :fetch_env!,
        :user_home,
        :user_home!,
        # The clock; a time a caller gives, or one in a file, is not read here.
        :monotonic_time,
        :os_time,
        :system_time
      ]

  defp way_out?(DateTime, function), do: function in [:utc_now, :now, :now!]
  defp way_out?(NaiveDateTime, function), do: function in [:utc_now, :local_now]
  defp way_out?(Time, :utc_now), do: true
  defp way_out?(Date, :utc_today), do: true
  defp way_out?(:calendar, function), do: function in [:universal_time, :local_time]

  defp way_out?(:erlang, function),
    do:
      function in [
        :monotonic_time,
        :system_time,
        :now,
        :timestamp,
        :universaltime,
        :localtime,
        :date,
        :time
      ]

  defp way_out?(:os, function),
    do: function in [:system_time, :timestamp, :perf_counter, :cmd, :getenv]

  defp way_out?(Port, :open), do: true
  defp way_out?(Process, :sleep), do: true
  defp way_out?(:timer, :sleep), do: true
  # `:httpc.ssl_verify_host_options/1` builds options, and sends nothing.
  defp way_out?(:httpc, function), do: function != :ssl_verify_host_options
  # The terminal's input; a file opened by path is read as a path, which stays a parameter.
  defp way_out?(IO, function), do: function in [:gets, :getn]

  # Req, and oidcc, a provider's client, by its Elixir and its Erlang modules: every call into
  # them counts, even one that only builds something, since a call that builds a URL may send
  # first (a pushed authorization request) and a later version may add requests a list of them
  # would miss. Whatever calls them is the implementation that uses them.
  defp way_out?(callee, _function) do
    name = Atom.to_string(callee)

    callee in [Req, Oidcc, :oidcc] or String.starts_with?(name, ["Elixir.Req.", "Elixir.Oidcc."]) or
      String.starts_with?(name, "oidcc_")
  end
end

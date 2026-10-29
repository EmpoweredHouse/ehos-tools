defmodule Ehosctl.ConventionsTest do
  @moduledoc """
  The rule of T-20 a test can hold: only a behaviour's implementation, `XImpl` beside its `X`,
  runs a program, calls the network, reads the process environment, the home directory, the
  terminal or the clock, or waits, so every caller reaches them through a behaviour a test
  replaces.

  Each module is read as the compiler expanded it, from its `debug_info`: an alias, an import or
  a capture already names the module it calls there, so `alias DateTime, as: DT` or
  `import System` hides nothing (ehos-tools#571), and a comment or a string that names a function
  is not code.
  """

  use ExUnit.Case, async: true

  # Runs while Mix compiles ehosctl, before any configuration chooses an implementation: it reads
  # the commit and the build's variables to stamp the version (`Ehosctl.Build`).
  @at_compile_time [Ehosctl.Build]

  # This package's `lib/`, from where its `mix.exs` is, whatever directory the test runs in.
  @lib Path.join(Path.dirname(Mix.Project.project_file()), "lib") <> "/"

  test "only a behaviour's implementation runs a program, calls the network, reads the " <>
         "environment, the home directory, the terminal or the clock, or waits" do
    {:ok, modules} = :application.get_key(:ehosctl, :modules)
    in_lib = Enum.filter(modules, &in_lib?/1)

    # None when the beams were compiled at another path (a `_build` copied or restored from a
    # cache): then this test would check nothing.
    assert in_lib != [], "no module of ehosctl is compiled from #{@lib}"

    strays =
      for module <- in_lib,
          module not in @at_compile_time,
          not implementation?(module),
          ways_out(object_code(module)) != [],
          do: module

    assert strays == [],
           "These reach a program, the network, the environment, the home directory, the " <>
             "terminal, the clock or a wait directly; call them " <>
             "through a behaviour instead (T-20, CONTRIBUTING.md): #{inspect(strays)}"
  end

  test "sees a way out called through an alias, an import or a capture" do
    {:module, _module, beam, _} =
      defmodule Ehosctl.ConventionsTest.Hidden do
        @moduledoc false
        @compile :debug_info
        alias DateTime, as: DT
        import System, only: [get_env: 1]

        def now, do: DT.utc_now()
        def home, do: get_env("HOME")
        def run, do: Enum.map(["true"], &System.cmd(&1, []))
      end

    assert ways_out(beam) == [
             {DateTime, :utc_now},
             {System, :cmd},
             {System, :get_env}
           ]
  end

  test "sees no way out in a call that only names one" do
    {:module, _module, beam, _} =
      defmodule Ehosctl.ConventionsTest.Named do
        @moduledoc false
        @compile :debug_info
        # System.cmd/3 runs a program; this says so, and runs none.
        def said, do: "System.cmd(\"git\", [])"
        def options, do: :httpc.ssl_verify_host_options(true)
      end

    assert ways_out(beam) == []
  end

  # The module's beam as compiled, read from the code path: under `mix test --cover` the loaded
  # module is cover's, which `:code.which/1` names `:cover_compiled`, with no file to read.
  defp object_code(module) do
    {^module, beam, _path} = :code.get_object_code(module)
    beam
  end

  # Under this package's `lib/`, wherever the checkout is: a `lib` above it (`/var/lib/…`) would
  # take in `test/support/` too.
  defp in_lib?(module),
    do: module.module_info(:compile)[:source] |> to_string() |> String.starts_with?(@lib)

  # `XImpl` that declares `@behaviour X`, the shape T-20 gives an implementation.
  defp implementation?(module) do
    behaviour =
      module |> inspect() |> String.replace_suffix("Impl", "") |> then(&Module.concat([&1]))

    behaviours = List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
    String.ends_with?(inspect(module), "Impl") and behaviour in behaviours
  end

  # The ways out a compiled module calls, each once, from the code Elixir expanded.
  defp ways_out(beam) do
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
        # The clock, `Ehosctl.Clock`'s; a time a caller gives, or one in a file, is not read here.
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
  # oidcc's own requests; building a URL or a context from what it read is not one.
  defp way_out?(Oidcc.ProviderConfiguration, function),
    do: function in [:load_configuration, :load_jwks]

  defp way_out?(Oidcc.Token, function), do: function in [:retrieve, :refresh]
  # The terminal's input; a file opened by path is read as a path, which stays a parameter.
  defp way_out?(IO, function), do: function in [:gets, :getn]

  defp way_out?(callee, _function),
    do: callee == Req or String.starts_with?(Atom.to_string(callee), "Elixir.Req.")
end

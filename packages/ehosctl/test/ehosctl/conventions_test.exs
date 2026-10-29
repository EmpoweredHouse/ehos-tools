defmodule Ehosctl.ConventionsTest do
  @moduledoc """
  The rule of T-20 a test can hold: only a behaviour's implementation, `XImpl` beside its `X`,
  runs a program, calls the network, reads the process environment, the home directory, the
  terminal or the clock, or waits, so every caller reaches them through a behaviour a test
  replaces.
  """

  use ExUnit.Case, async: true

  # Runs while Mix compiles ehosctl, before any configuration chooses an implementation: it reads
  # the commit and the build's variables to stamp the version (`Ehosctl.Build`).
  @at_compile_time [Ehosctl.Build]

  test "only a behaviour's implementation runs a program, calls the network, reads the " <>
         "environment, the home directory, the terminal or the clock, or waits" do
    strays =
      for {module, body} <- modules(),
          module not in @at_compile_time,
          not implementation?(module, body),
          way_out?(body),
          do: module

    assert strays == [],
           "These reach a program, the network, the environment, the home directory, the " <>
             "terminal, the clock or a wait directly; call them " <>
             "through a behaviour instead (T-20, CONTRIBUTING.md): #{inspect(strays)}"
  end

  # Read as code, so a comment or a string that names a function does not count: each module, a
  # nested one by its full name and apart from the module around it.
  defp modules do
    for path <- Path.wildcard("lib/**/*.ex"),
        module <- path |> File.read!() |> Code.string_to_quoted!() |> modules([]),
        do: module
  end

  defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, outer) do
    name = outer ++ parts
    {nested, own} = nested(body)
    [{Module.concat(name), own} | Enum.flat_map(nested, &modules(&1, name))]
  end

  defp modules({:__block__, _, nodes}, outer), do: Enum.flat_map(nodes, &modules(&1, outer))
  defp modules(_other, _outer), do: []

  defp nested({:__block__, meta, nodes}) do
    {nested, own} = Enum.split_with(nodes, &match?({:defmodule, _, _}, &1))
    {nested, {:__block__, meta, own}}
  end

  defp nested({:defmodule, _, _} = node), do: {[node], nil}
  defp nested(node), do: {[], node}

  # `XImpl` that declares `@behaviour X`, the shape T-20 gives an implementation.
  defp implementation?(module, body) do
    behaviour = module |> inspect() |> String.replace_suffix("Impl", "")

    {_ast, declared?} =
      Macro.prewalk(body, false, fn
        {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} = node, declared? ->
          {node, declared? or inspect(Module.concat(parts)) == behaviour}

        node, declared? ->
          {node, declared?}
      end)

    String.ends_with?(inspect(module), "Impl") and declared?
  end

  defp way_out?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        {{:., _, [{:__aliases__, _, [:System]}, function]}, _, _} = node, _found?
        when function in [
               :cmd,
               :shell,
               :get_env,
               :fetch_env,
               :fetch_env!,
               :user_home,
               :user_home!
             ] ->
          {node, true}

        # The clock, `Ehosctl.Clock`'s; a time a caller gives, or one in a file, is not read here.
        {{:., _, [{:__aliases__, _, [:System]}, function]}, _, _} = node, _found?
        when function in [:monotonic_time, :os_time, :system_time] ->
          {node, true}

        {{:., _, [{:__aliases__, _, [module]}, function]}, _, _} = node, _found?
        when module in [:DateTime, :NaiveDateTime, :Time] and function == :utc_now ->
          {node, true}

        {{:., _, [{:__aliases__, _, [:Date]}, :utc_today]}, _, _} = node, _found? ->
          {node, true}

        {{:., _, [:erlang, function]}, _, _} = node, _found?
        when function in [:monotonic_time, :system_time, :now] ->
          {node, true}

        {{:., _, [:os, function]}, _, _} = node, _found?
        when function in [:system_time, :timestamp] ->
          {node, true}

        {{:., _, [{:__aliases__, _, [:Port]}, :open]}, _, _} = node, _found? ->
          {node, true}

        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, _, _} = node, _found? ->
          {node, true}

        {{:., _, [:os, function]}, _, _} = node, _found? when function in [:cmd, :getenv] ->
          {node, true}

        {{:., _, [:timer, :sleep]}, _, _} = node, _found? ->
          {node, true}

        # `:httpc.ssl_verify_host_options/1` builds options, and sends nothing.
        {{:., _, [:httpc, function]}, _, _} = node, _found?
        when function != :ssl_verify_host_options ->
          {node, true}

        {:__aliases__, _, [:Req | _]} = node, _found? ->
          {node, true}

        # oidcc's own requests; building a URL or a context from what it read is not one.
        {{:., _, [{:__aliases__, _, [:Oidcc | _] = name}, function]}, _, _} = node, _found?
        when {name, function} in [
               {[:Oidcc, :ProviderConfiguration], :load_configuration},
               {[:Oidcc, :ProviderConfiguration], :load_jwks},
               {[:Oidcc, :Token], :retrieve},
               {[:Oidcc, :Token], :refresh}
             ] ->
          {node, true}

        # The terminal's input; a file opened by path is read as a path, which stays a parameter.
        {{:., _, [{:__aliases__, _, [:IO]}, function]}, _, _} = node, _found?
        when function in [:gets, :getn] ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end
end

defmodule ConventionsTest do
  @moduledoc """
  The rule of T-20 a test can hold: only a behaviour's implementation, `XImpl` beside its `X`,
  runs a program, calls the network or reads the process environment, so every caller reaches
  them through a behaviour a test replaces.
  """

  use ExUnit.Case, async: true

  test "only a behaviour's implementation runs a program, calls the network or reads the environment" do
    strays =
      for {module, body} <- modules(),
          not implementation?(module, body),
          way_out?(body),
          do: module

    assert strays == [],
           "These reach a program, the network or the environment directly; call them through " <>
             "a behaviour instead (T-20, CONTRIBUTING.md): #{inspect(strays)}"
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
        when function in [:cmd, :shell, :get_env, :fetch_env, :fetch_env!] ->
          {node, true}

        {{:., _, [{:__aliases__, _, [:Port]}, :open]}, _, _} = node, _found? ->
          {node, true}

        {{:., _, [:httpc, _function]}, _, _} = node, _found? ->
          {node, true}

        {:__aliases__, _, [:Req | _]} = node, _found? ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end
end

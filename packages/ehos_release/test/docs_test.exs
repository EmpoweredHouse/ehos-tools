defmodule DocsTest do
  # CONTRIBUTING.md, "Docs": every public module has a @moduledoc, and every public function
  # a @doc and a @spec. `@moduledoc false` and `@doc false` are choices made on purpose, and so
  # is a callback's implementation, which `@impl` hides and its behaviour documents. A copy of
  # `ehosctl`'s (packages/ehosctl/test/ehosctl/docs_test.exs), with callbacks checked too and a
  # function with defaults specified at its full arity alone, since sharing one would make a
  # package depend on another for its tests alone.
  use ExUnit.Case, async: true

  setup_all do
    {:ok, modules} = :application.get_key(:ehos_release, :modules)
    %{modules: modules}
  end

  test "every module says what it is for, or that it is internal", %{modules: modules} do
    for module <- modules do
      {:docs_v1, _, _, _, moduledoc, _, _} = Code.fetch_docs(module)
      assert moduledoc != :none, "#{inspect(module)} has no @moduledoc"
    end
  end

  test "every public function has a @doc and a @spec", %{modules: modules} do
    for module <- modules,
        {:docs_v1, _, _, _, moduledoc, _, docs} = Code.fetch_docs(module),
        moduledoc != :hidden do
      {:ok, specs} = Code.Typespec.fetch_specs(module)
      # A callback's implementation is specified by its behaviour's @callback.
      callbacks =
        for behaviour <-
              List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour)),
            {:ok, callbacks} = Code.Typespec.fetch_callbacks(behaviour),
            {name_arity, _} <- callbacks,
            do: name_arity

      specced =
        MapSet.new(specs, fn {name_arity, _} -> name_arity end)
        |> MapSet.union(MapSet.new(callbacks))

      for {{:function, name, arity}, _, _, doc, _metadata} <- docs, doc != :hidden do
        assert doc != :none, "#{inspect(module)}.#{name}/#{arity} has no @doc"

        # A function with default arguments is documented, and specified, at its full arity.
        assert {name, arity} in specced, "#{inspect(module)}.#{name}/#{arity} has no @spec"
      end
    end
  end

  test "every callback says what it does", %{modules: modules} do
    for module <- modules,
        {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module),
        {{:callback, name, arity}, _, _, doc, _} <- docs do
      assert doc != :none, "#{inspect(module)}.#{name}/#{arity}, a callback, has no @doc"
    end
  end
end

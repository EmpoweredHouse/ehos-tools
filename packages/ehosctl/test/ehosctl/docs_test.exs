defmodule Ehosctl.DocsTest do
  # CONTRIBUTING.md, "Docs": every public module has a @moduledoc, and every public function
  # a @doc and a @spec. `@moduledoc false` and `@doc false` are choices made on purpose, and so
  # is a callback's implementation, which `@impl` hides and its behaviour documents. Every
  # callback has a @doc too, and every module the reference shows is in one of its groups.
  # `ehos_platform`, `review`, `ehos_design`, `ehos_diagrams` and `ehos_app` keep copies of this
  # test, since sharing one would make a package depend on another for its tests alone.
  use Ehosctl.Case, async: true

  setup_all do
    {:ok, modules} = :application.get_key(:ehosctl, :modules)
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

      for {{:function, name, arity}, _, _, doc, metadata} <- docs, doc != :hidden do
        assert doc != :none, "#{inspect(module)}.#{name}/#{arity} has no @doc"

        # A function with default arguments has one spec, for its full arity.
        arities = arity..(arity + Map.get(metadata, :defaults, 0))

        assert Enum.any?(arities, &({name, &1} in specced)),
               "#{inspect(module)}.#{name}/#{arity} has no @spec"
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

  # A module left out of `groups_for_modules` lands in a list of its own at the reference's end.
  test "every module the reference shows is in one of its groups", %{modules: modules} do
    docs = Mix.Project.config()[:docs]
    grouped = docs[:groups_for_modules] |> Keyword.values() |> List.flatten()

    ungrouped =
      for module <- modules,
          {:docs_v1, _, _, _, moduledoc, metadata, _} = Code.fetch_docs(module),
          moduledoc != :hidden,
          docs[:filter_modules].(module, metadata),
          module not in grouped,
          do: module

    assert ungrouped == []
  end

  test "every page of docs/commands/ is in the reference" do
    assert Enum.sort(Path.wildcard("docs/commands/*.md")) ==
             Enum.sort(
               Enum.filter(Mix.Project.config()[:docs][:extras], &(&1 =~ "docs/commands/"))
             )
  end

  # `upgrade` was once a command the table left out.
  test "every command has a row in the README's table of commands" do
    readme = File.read!("README.md")

    missing =
      for command <- Ehosctl.CLI.commands(),
          # The name whole: `install`'s row is not `installation`'s.
          not Regex.match?(
            ~r/^\| `ehosctl #{Regex.escape(to_string(command.name()))}[ `]/m,
            readme
          ),
          do: command.name()

    assert missing == []
  end
end

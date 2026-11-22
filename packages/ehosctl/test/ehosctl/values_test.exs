defmodule Ehosctl.ValuesTest do
  @moduledoc """
  ehosctl held to T-28's one form of each value: a date through `Ehosctl.Output.date/1`, an empty
  value as `Ehosctl.Output.none/0`. Every module of `lib/` is read as the compiler expanded it, as
  `Ehosctl.ConventionsTest` reads it, so only `Ehosctl.Output` formats a moment or writes another
  empty form; and `Ehosctl.Case.ehosctl/2` fails every command test whose output holds a raw date.
  """

  use ExUnit.Case, async: true

  alias Ehosctl.Case

  # Each a second form of a moment for a person.
  @formats [
    {Calendar, :strftime},
    {DateTime, :to_string},
    {NaiveDateTime, :to_string},
    {Date, :to_string}
  ]

  @empty_forms ["(none)", "(not set)", "<none>"]

  test "only Ehosctl.Output formats a moment for a person" do
    assert for(
             module <- lib_modules(),
             module != Ehosctl.Output,
             call <- calls(object_code(module)),
             call in @formats,
             do: {module, call}
           ) == []
  end

  test "only Ehosctl.Output writes an empty value, as <none>" do
    assert for(
             module <- lib_modules(),
             module != Ehosctl.Output,
             text <- texts(object_code(module)),
             form <- @empty_forms,
             String.contains?(text, form),
             do: {module, text}
           ) == []
  end

  test "sees a format and an empty form inside a function's body" do
    {:module, _module, beam, _} =
      defmodule Shows do
        @moduledoc false
        @compile :debug_info

        def at(at), do: "set at #{Calendar.strftime(at, "%Y")}"
        def name(nil), do: "(none)"
      end

    assert {Calendar, :strftime} in calls(beam)
    assert "(none)" in texts(beam)
  end

  describe "a command's output" do
    test "passes with dates through Output.date/1, and none or a name none as a value" do
      stdout = """
       NAME     SEED PROFILE  SET AT
       sandbox  none          16 October 2026, 14:02 UTC
       free     <none>        <none>
      """

      assert Case.refute_raw_values(["env", "template", "list"], stdout, "") == :ok
    end

    test "fails with a raw ISO 8601 date, or one as the console's settings wrote it" do
      for line <- [" ada  2026-10-16T14:02:09Z", " ada  2026-10-16 14:02 UTC"] do
        error =
          assert_raise ExUnit.AssertionError, fn ->
            Case.refute_raw_values(["secrets", "list"], "", line <> "\n")
          end

        assert error.message ==
                 "ehosctl secrets list printed a date not through Output.date/1, or an empty " <>
                   "value not as Output.none/0:\n" <> line
      end
    end

    test "fails with another empty form" do
      for line <- ["name:  (none)", "Serves  (not set)"] do
        assert_raise ExUnit.AssertionError, fn ->
          Case.refute_raw_values(["people", "show"], line, "")
        end
      end
    end

    test "keeps --json's values and the time of each line of logs" do
      assert Case.refute_raw_values(
               ["secrets", "list", "--json"],
               ~s({"at":"2026-10-16T14:02:09Z"}),
               ""
             ) ==
               :ok

      assert Case.refute_raw_values(
               ["logs", "ledger"],
               "2026-10-13T10:00:01.000000001Z ledger-7d9f-x2 Starting\n",
               ""
             ) == :ok
    end
  end

  defp lib_modules do
    lib = Path.join(Path.dirname(Mix.Project.project_file()), "lib") <> "/"
    {:ok, modules} = :application.get_key(:ehosctl, :modules)
    in_lib = Enum.filter(modules, &String.starts_with?(source(&1), lib))
    assert in_lib != [], "no module of ehosctl is compiled from #{lib}"
    in_lib
  end

  defp source(module), do: to_string(module.module_info(:compile)[:source])

  defp calls(beam) do
    {_ast, found} =
      Macro.prewalk(clauses(beam), [], fn
        {{:., _, [callee, function]}, _, _} = node, found when is_atom(callee) ->
          {node, [{callee, function} | found]}

        node, found ->
          {node, found}
      end)

    found
  end

  defp texts(beam) do
    {_ast, found} =
      Macro.prewalk(clauses(beam), [], fn
        text, found when is_binary(text) -> {text, [text | found]}
        node, found -> {node, found}
      end)

    found
  end

  # A definition and its clauses are tuples of four, which `Macro.prewalk/3` would not enter.
  defp clauses(beam) do
    {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(beam, [:debug_info])

    {:ok, %{definitions: definitions}} = backend.debug_info(:elixir_v1, module, data, [])

    for {_name_arity, _kind, _meta, clauses} <- definitions,
        {_clause_meta, args, guards, body} <- clauses,
        do: [args, guards, body]
  end

  defp object_code(module) do
    {^module, beam, _path} = :code.get_object_code(module)
    beam
  end
end

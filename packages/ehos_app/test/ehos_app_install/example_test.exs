defmodule Mix.Tasks.EhosApp.InstallTest.Example do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "--example" do
    test "generates a domain named as the application is in EHOS, a contract and its implementation" do
      igniter = installed(["--example"])

      assert lines_starting(content(igniter, "lib/test/domain.ex"), "  use ") == [
               "  use EhOsContract.Domain, name: :test, language: :en"
             ]

      assert lines_starting(content(igniter, "lib/test/contracts/entries.ex"), "  use ") == [
               ~s|  use EhOsContract.Contract, domain: Test.Domain, context: :entries, id: "test.entries"|
             ]

      assert lines_starting(content(igniter, "lib/test/entries/entry.ex"), "  use ") == [
               "  use Test.Contracts.Entries, aggregate: :entry"
             ]

      assert igniter
             |> content("test/test_web/entries_api_test.exs")
             |> lines("    assert_every_entry_refuses([Test.Contracts.Entries], %{", "    })") ==
               """
                   assert_every_entry_refuses([Test.Contracts.Entries], %{
                     "test.record_entry" =>
                       &command(conn, &1, "test.record_entry", %{entry_id: "e-1", amount: 10}),
                     "test.flag_entry" => &command(conn, &1, "test.flag_entry", %{entry_id: "e-1"})
                   })
               """
    end

    # eh_os_contract's `word-without-term` notes each word of a context's names of things that no
    # term of the context's glossary covers: without one, a new project's first check says
    # 1 notice (ehos-tools#125). eh_os_contract is not a dependency of ehos_app, so this models that
    # one rule as eh_os_contract 0.3.0 has it; the whole check, 0 errors, 0 warnings, 0 notices,
    # runs only in a generated project, as CI's `e2e` job makes one.
    test "gives the domain a term for every word the example contract names a thing with" do
      igniter = installed(["--example"])

      terms =
        igniter
        |> content("lib/test/domain.ex")
        |> calls(:term)
        |> Enum.map(fn [text | _] -> code_words(text) end)

      names =
        igniter
        |> content("lib/test/contracts/entries.ex")
        |> names_of_things()

      assert names == [:entry, :amount, :amount]
      assert untermed(names, terms) == []

      # A term covers its words only where they stand in a name in a row.
      assert untermed([:amount], [["entry", "amount"]]) == ["amount"]
      assert untermed([:entry_amount], [["entry", "amount"]]) == []
    end

    test "says that the caller gives an entry's identity, a fresh one" do
      contract = installed(["--example"]) |> content("lib/test/contracts/entries.ex")

      assert lines(
               contract,
               "    # The caller gives the entry's identity: it is not `generated: :uuid` with a `creates:`",
               "    identity(:entry_id)"
             ) ==
               """
                   # The caller gives the entry's identity: it is not `generated: :uuid` with a `creates:`
                   # command, which together would have the engine generate it. So a call without `entry_id` is
                   # refused as invalid. Give each new entry a fresh id, a UUID: an id in use records onto that
                   # entry, and `Entry` does not read its state, so even onto a flagged one. A UUID only avoids
                   # collisions; it does not guard an entry, since whoever may `record_entry` may name any id.
                   identity(:entry_id)
               """
    end

    test "serves the contract under /api, behind the credential check" do
      router = installed(["--example"]) |> content("lib/test_web/router.ex")

      # The in-memory project formats without Phoenix's `locals_without_parens`.
      assert lines(router, "  pipeline :commands do", "  end") == """
               pipeline :commands do
                 plug(:accepts, ["json"])
                 plug(EhOsContract.Auth.Plug)
               end
             """

      assert lines(router, ~s|  scope "/api" do|, "  end") == """
               scope "/api" do
                 pipe_through(:commands)

                 forward("/", EhOsContract.Plug, contracts: [Test.Contracts.Entries])
               end
             """
    end

    test "publishes a recorded entry under the application's name" do
      assert installed(["--example"])
             |> content("lib/test/contracts/entries.ex")
             |> lines("  publish(:entry_recorded,", "  )") == """
               publish(:entry_recorded,
                 as: "test.entry.recorded.v1",
                 from: :recorded,
                 fields: [:entry_id, :amount]
               )
             """
    end

    test "names the example contract's id under the application's name, as the engine requires" do
      assert installed(["--example"])
             |> content("lib/test/contracts/entries.ex")
             |> lines_starting("  use ") == [
               ~s|  use EhOsContract.Contract, domain: Test.Domain, context: :entries, id: "test.entries"|
             ]

      assert my_shop_example()
             |> content("lib/my_shop/contracts/entries.ex")
             |> lines_starting("  use ") == [
               ~s|  use EhOsContract.Contract, domain: MyShop.Domain, context: :entries, id: "my-shop.entries"|
             ]
    end

    test "publishes under the name EHOS gives the application, a dash included" do
      igniter = my_shop_example()

      assert content(igniter, "lib/my_shop/contracts/entries.ex")
             |> lines("  publish(:entry_recorded,", "  )") == """
               publish(:entry_recorded,
                 as: "my-shop.entry.recorded.v1",
                 from: :recorded,
                 fields: [:entry_id, :amount]
               )
             """

      assert igniter.warnings == []
    end

    test "names EHOS's application with dashes, which allow no underscore" do
      assert Install.ehos_name(:my_shop) == "my-shop"
      assert Install.ehos_name(:shop) == "shop"
    end

    test "writes nothing of it unless asked" do
      igniter = installed()

      refute Igniter.exists?(igniter, "lib/test/domain.ex")
      refute content(igniter, "lib/test_web/router.ex") =~ "EhOsContract.Plug"
    end
  end

  # The example, installed in a project whose application is `:my_shop`.
  defp my_shop_example do
    [app_name: :my_shop]
    |> phx_test_project()
    |> Igniter.compose_task("ehos_app.install", ["--example"])
    |> apply_igniter!()
  end

  # What `word-without-term` reads of a contract, as eh_os_contract 0.3.0's `CodeWords.names/1`
  # does: the names of its units (aggregates and DCBs), its read models and its fields, but not
  # its commands and events, a unit's identity, or a field typed `{:id, entity}`.
  defp names_of_things(contract) do
    for [name | rest] <- calls(contract, [:aggregate, :dcb, :read_model, :field]),
        not match?([{:id, _} | _], rest),
        do: name
  end

  # Each word of more than two letters, of the `names`, that no term (as its words) covers
  # where it stands whole and in order in the name.
  defp untermed(names, terms) do
    for name <- names,
        words = code_words(name),
        covered = Enum.flat_map(terms, &covered_positions(words, &1)),
        {word, position} <- Enum.with_index(words),
        position not in covered,
        String.length(word) > 2,
        uniq: true,
        do: word
  end

  defp covered_positions(words, term) do
    size = length(term)

    for start <- 0..(length(words) - size)//1,
        Enum.slice(words, start, size) == term,
        position <- start..(start + size - 1),
        do: position
  end

  defp code_words(name) when is_atom(name), do: name |> Atom.to_string() |> code_words()

  defp code_words(text),
    do: text |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
end

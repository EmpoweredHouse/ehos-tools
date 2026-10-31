# Measures the prose of hand-written pages against the sentence rules of `ehos-dev:voice`:
# an instruction has 20 words or fewer, a description 25 or fewer, and an internal code
# (`D-105`, `T-16`, `D11`, `L3`, `§6`, `#517`, "stage 5") does not carry a sentence.
# Front matter, fenced code, HTML comments, tables, headings and images are left out, and the
# markers of a quote. Indented code blocks are not: they read as prose.
#
#     elixir measure-prose.exs docs/contract.md docs/refusals.md
#     elixir measure-prose.exs --long docs/contract.md
#
# "Codes" counts every code in running text; "Sentences a code carries" counts the sentences
# with a code outside the parenthesis that closes them. `--long` lists each long sentence and
# each sentence a code carries. The counts are estimates:
# a sentence ends at `.`, `?` or `!`, and any closing bold or quote, before a space and a capital
# or a backquote, and an
# instruction is a sentence whose first word is an imperative verb of the list below. A
# number in a how-to's steps is not a code: read each hit.

defmodule MeasureProse do
  @imperatives ~w(add ask build call change check choose configure copy create declare define
                  delete deploy do draw edit find follow generate get give install keep leave let
                  link list load look make mark move name number obey open put read record
                  register remove replace run say see select send set show start stop take tell
                  try type update use write)

  # The same pattern as the codes grep of `ehos-dev:voice`, "Before you publish".
  @code ~r/\b[A-Z]{1,2}-?[0-9]{1,3}\b|§|#[0-9]+|[Ss](?:tage|tep) [0-9]/u

  # A fence, also in a quote or a list item: its marker, and what follows it.
  @fence ~r/^[ \t]*(?:(?:>|[-*+]|\d+[.)])[ \t]*)*(`{3,}|~{3,})(.*)$/u

  # The pattern of `EhosDiagrams.Pages`, so the count is what `mix ehos_diagrams.gen --check`
  # refuses.
  @mermaid ~r/^[ \t]*(?:(?:>|[-*+]|\d+[.)])[ \t]*)*(?:`{3,}|~{3,})[ \t]*mermaid[ \t]*$/im

  @doc "Prints the table for the pages in `args`, and with `--long` each sentence it counts."
  @spec main([String.t()]) :: :ok
  def main(args) do
    # Erlang keeps stdout in latin1 when it is not a terminal.
    :io.setopts(:standard_io, encoding: :unicode)
    {opts, pages} = OptionParser.parse!(args, strict: [long: :boolean])

    rows = Enum.map(pages, &measure/1)

    IO.puts("| Page | Sentences | Long | Codes | Sentences a code carries | Mermaid |")
    IO.puts("| --- | --- | --- | --- | --- | --- |")

    for {page, m} <- rows do
      share = if m.sentences == 0, do: 0, else: round(100 * length(m.long) / m.sentences)

      IO.puts(
        "| `#{page}` | #{m.sentences} | #{length(m.long)} (#{share}%) | #{m.mentions} | " <>
          "#{length(m.codes)} | #{m.mermaid} |"
      )
    end

    if opts[:long], do: print_long(rows)
    :ok
  end

  defp print_long(rows) do
    for {page, m} <- rows do
      IO.puts("\n## #{page}")
      for {kind, words, s} <- m.long, do: IO.puts("- long #{kind}, #{words} words: #{s}")
      for s <- m.codes, do: IO.puts("- code: #{s}")
    end
  end

  defp measure(page) do
    text = File.read!(page)
    sentences = text |> prose() |> Enum.flat_map(&sentences/1)

    long =
      for s <- sentences,
          words = words(s),
          kind = if(instruction?(s), do: :instruction, else: :description),
          words > if(kind == :instruction, do: 20, else: 25),
          do: {kind, words, s}

    codes = for s <- sentences, carried?(s), do: s
    mentions = sentences |> Enum.flat_map(&Regex.scan(@code, &1)) |> length()
    mermaid = length(Regex.scan(@mermaid, text))

    {page,
     %{
       sentences: length(sentences),
       long: long,
       codes: codes,
       mentions: mentions,
       mermaid: mermaid
     }}
  end

  # The page as units of prose: paragraphs and list items, each joined into one line.
  defp prose(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/\A---\n(?:.*?\n)?---\n/su, "")
    |> String.replace(~r/<!--.*?-->/su, "")
    |> String.split("\n")
    |> outside_fences()
    |> Enum.map(&String.replace(&1, ~r/^\s*(?:>\s?)+/u, ""))
    |> Enum.reject(&Regex.match?(~r/^\s*(\||\#{1,6}\s|!\[|<a id=)/u, &1))
    |> Enum.chunk_while([], &chunk/2, fn acc -> {:cont, Enum.reverse(acc), []} end)
    |> Enum.map(&(&1 |> Enum.map(fn l -> String.trim(l) end) |> Enum.join(" ")))
    |> Enum.map(&String.replace(&1, ~r/^([-*+]|[0-9]+[.)])\s+/u, ""))
    |> Enum.reject(&(&1 == ""))
  end

  # Each line outside a fence, a fence's lines replaced by blank ones. A fence closes on a
  # bare marker of its own character, at least as long. A fence left open hides the rest of the
  # page, as it does when the page is rendered.
  defp outside_fences(lines) do
    {kept, _open} = Enum.map_reduce(lines, nil, &fence_state/2)
    kept
  end

  defp fence_state(line, nil) do
    case Regex.run(@fence, line, capture: :all_but_first) do
      [marker, _rest] -> {"", marker}
      nil -> {line, nil}
    end
  end

  defp fence_state(line, open) do
    {"", if(closes?(line, open), do: nil, else: open)}
  end

  defp closes?(line, open) do
    case Regex.run(@fence, line, capture: :all_but_first) do
      [marker, rest] ->
        String.first(marker) == String.first(open) and
          String.length(marker) >= String.length(open) and
          String.trim(rest) == ""

      nil ->
        false
    end
  end

  # A blank line ends a unit, and so does a new list item.
  defp chunk(line, acc) do
    cond do
      String.trim(line) == "" -> {:cont, Enum.reverse(acc), []}
      list_item?(line) and acc != [] -> {:cont, Enum.reverse(acc), [line]}
      true -> {:cont, [line | acc]}
    end
  end

  defp list_item?(line), do: Regex.match?(~r/^\s*([-*+]|[0-9]+[.)])\s/u, line)

  defp sentences(unit) do
    unit
    |> String.replace(~r/\[([^\]]*)\]\([^)\s\/.#]*+[\/.#][^)\s]*+(?:\s+"[^"]*")?\)/u, "\\1")
    |> String.replace(~r/([.?!])[*_"'”’]+(?=\s)/u, "\\1")
    |> String.split(~r/(?<=[.?!])\s+(?=[A-Z`*_"“\[(])/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(words(&1) < 3 and not code_with_words?(&1)))
  end

  # A short sentence is kept when it holds a code and a word: "Use D-105.", not a bare code
  # after a refusal, a link to a record, or "**Step 1.**".
  defp code_with_words?(s) do
    Regex.match?(@code, s) and Regex.match?(~r/\p{L}{2,}/u, Regex.replace(@code, s, ""))
  end

  defp words(s), do: s |> String.split(~r/\s+/u, trim: true) |> length()

  defp instruction?(s) do
    first = s |> String.replace(~r/[*_`"“]/u, "") |> String.split(~r/[\s,:.]/u) |> hd()
    String.downcase(first) in @imperatives
  end

  # A code carries a sentence unless it stands in the parenthesis that closes it.
  defp carried?(s) do
    s = Regex.replace(~r/\([^()]*\)[.?!]?\s*$/u, s, "")
    Regex.match?(@code, s)
  end
end

MeasureProse.main(System.argv())

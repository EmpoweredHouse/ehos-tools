# Measures the prose of hand-written pages against the sentence rules of `ehos-dev:voice`:
# an instruction has 20 words or fewer, a description 25 or fewer, and an internal code
# (`D-105`, `T-16`, `D11`, `L3`, `§6`, `#517`, "stage 5") does not carry a sentence.
# Fenced code, HTML comments, tables, headings and images are left out.
#
#     elixir measure-prose.exs docs/contract.md docs/refusals.md
#     elixir measure-prose.exs --long docs/contract.md
#
# "Codes" counts every code in running text; "Sentences a code carries" counts the sentences
# with a code outside the parenthesis that closes them. `--long` lists each long sentence and
# each sentence a code carries. The counts are estimates:
# a sentence ends at `.`, `?` or `!` before a space and a capital or a backquote, and an
# instruction is a sentence whose first word is an imperative verb of the list below. A
# number in a how-to's steps is not a code: read each hit.

defmodule MeasureProse do
  @imperatives ~w(add ask call change check choose configure copy declare define delete deploy
                  do find give install keep let link list look make mark move name open put read
                  record register remove run see select send set show start stop take tell type
                  use write)

  # The same pattern as the codes grep of `ehos-dev:voice`, "Before you publish".
  @code ~r/\b[A-Z]{1,2}-?[0-9]{1,3}\b|§|#[0-9]+|\b[Ss](?:tage|tep) [0-9]/u

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
    mermaid = length(Regex.scan(~r/^```mermaid/mu, text))

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
    |> String.replace(~r/^[ ]*```.*?^[ ]*```[ \t]*$/msu, "\n")
    |> String.replace(~r/<!--.*?-->/su, "")
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*(\||#|!\[|<a id=)/u, &1))
    |> Enum.chunk_while([], &chunk/2, fn acc -> {:cont, Enum.reverse(acc), []} end)
    |> Enum.map(&(&1 |> Enum.map(fn l -> String.trim(l) end) |> Enum.join(" ")))
    |> Enum.map(&String.replace(&1, ~r/^([-*+]|[0-9]+\.)\s+/u, ""))
    |> Enum.reject(&(&1 == ""))
  end

  # A blank line ends a unit, and so does a new list item.
  defp chunk(line, acc) do
    cond do
      String.trim(line) == "" -> {:cont, Enum.reverse(acc), []}
      list_item?(line) and acc != [] -> {:cont, Enum.reverse(acc), [line]}
      true -> {:cont, [line | acc]}
    end
  end

  defp list_item?(line), do: Regex.match?(~r/^\s*([-*+]|[0-9]+\.)\s/u, line)

  defp sentences(unit) do
    unit
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.split(~r/(?<=[.?!])\s+(?=[A-Z`*\[(])/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(words(&1) < 3))
  end

  defp words(s), do: s |> String.split(~r/\s+/u, trim: true) |> length()

  defp instruction?(s) do
    first = s |> String.replace(~r/^[*_`]+/u, "") |> String.split(~r/[\s,:]/u) |> hd()
    String.downcase(first) in @imperatives
  end

  # A code carries a sentence unless it stands in the parenthesis that closes it.
  defp carried?(s) do
    s = Regex.replace(~r/\([^()]*\)[.?!]?\s*$/u, s, "")
    Regex.match?(@code, s)
  end
end

MeasureProse.main(System.argv())

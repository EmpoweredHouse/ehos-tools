defmodule EhosDiagrams.Pages do
  @moduledoc """
  What a host's pages get wrong about its diagrams (eh-os D-107): an image a page links that does
  not exist, an output no page links, and a Mermaid block, which EHOS does not draw with. Which
  pages and documents are read is the host's to say.
  """

  # A fence opening a Mermaid block, however indented, in a blockquote or on a list item's line.
  @mermaid ~r/^[ \t]*(?:(?:>|[-*+]|\d+[.)])[ \t]*)*(?:`{3,}|~{3,})[ \t]*mermaid[ \t]*$/im

  @doc """
  An image one of `pages` links that does not exist, and an output that no page links, each as a
  sentence. `outputs` is the outputs' directory, whose every SVG file is one, or the outputs' paths.
  A link is read from the page's directory, or, when it starts with `/`, from the current
  directory, which GitHub's reading matches when the check runs at the repository's root.
  """
  @spec problems([Path.t()], Path.t() | [Path.t()]) :: [String.t()]
  def problems(pages, outputs) do
    linked =
      for page <- pages,
          target <- images(File.read!(page)),
          not (target =~ ~r/^[a-z][a-z0-9+.-]*:/i),
          do: {page, target(target, page)}

    missing =
      for {page, target} <- linked,
          not File.exists?(target),
          do: "#{page} links #{Path.relative_to_cwd(target)}, which does not exist"

    linked_targets = MapSet.new(linked, &elem(&1, 1))

    unlinked =
      for output <- outputs(outputs),
          not MapSet.member?(linked_targets, Path.expand(output)),
          do: "#{output} is linked from no page"

    missing ++ unlinked
  end

  # An image's alt text: escapes, and brackets one level deep, as CommonMark reads them.
  @alt ~S"(?:[^\[\]\\]|\\.|\[(?:[^\]\\]|\\.)*\])*"

  # A reference's definition counts only when an image names its label, which matches in any
  # case and with its whitespace collapsed, as CommonMark matches it.
  defp references(page) do
    used =
      ~r/!\[(#{@alt})\](?:\[([^\]]*)\])?(?![(\[:])/
      |> Regex.scan(page, capture: :all_but_first)
      |> MapSet.new(fn
        [text] -> label(text)
        [text, ""] -> label(text)
        [_text, label] -> label(label)
      end)

    # The first definition of a label is the one CommonMark uses.
    ~r/^[ ]{0,3}\[([^\]]+)\]:[ \t]*<?([^\s>]+)>?/m
    |> Regex.scan(page, capture: :all_but_first)
    |> Enum.uniq_by(fn [label, _target] -> label(label) end)
    |> Enum.filter(fn [label, _target] -> label(label) in used end)
    |> Enum.map(fn [_label, target] -> target end)
  end

  defp label(text), do: text |> String.split() |> Enum.join(" ") |> String.downcase()

  defp target("/" <> target, _page), do: Path.expand(target)
  defp target(target, page), do: Path.expand(target, Path.dirname(page))

  defp outputs(outputs) when is_list(outputs), do: Enum.sort(outputs)
  defp outputs(dir), do: dir |> Path.join("*.svg") |> Path.wildcard() |> Enum.sort()

  @doc "The documents that hold a Mermaid block, each as a sentence."
  @spec mermaid([Path.t()]) :: [String.t()]
  def mermaid(documents) do
    for document <- documents,
        File.read!(document) =~ @mermaid,
        do: "#{document} holds a Mermaid block (eh-os D-107)"
  end

  # The SVG images a page shows, as Markdown (with or without a title), through a reference an
  # image uses (`![x][ref]`, `![ref][]`, `![ref]` and `[ref]: img/x.svg`) or as <img>, without the
  # fragment GitHub reads for a theme (#gh-dark-mode-only).
  defp images(page) do
    markdown =
      Regex.scan(~r/!\[#{@alt}\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/, page,
        capture: :all_but_first
      )

    html = Regex.scan(~r/<img\b[^>]*\ssrc=["']([^"']+)["']/i, page, capture: :all_but_first)

    for target <- List.flatten(markdown ++ html) ++ references(page),
        path = target |> String.split(["#", "?"]) |> hd(),
        String.ends_with?(path, ".svg"),
        do: path
  end
end

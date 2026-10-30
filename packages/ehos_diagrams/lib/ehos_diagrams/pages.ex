defmodule EhosDiagrams.Pages do
  @moduledoc """
  What a host's pages get wrong about its diagrams (eh-os D-107): an image a page links that does
  not exist, an output no page links, and a Mermaid block, which EHOS does not draw with. Which
  pages and documents are read is the host's to say.
  """

  # A fence opening a Mermaid block, however indented, in a blockquote or on a list item's line.
  @mermaid ~r/^[ \t]*(?:(?:>|[-*+]|\d+[.)])[ \t]*)*(?:`{3,}|~{3,})[ \t]*mermaid[ \t]*$/im

  @doc """
  An image one of `pages` links that does not exist, and an output in `outputs` that no page
  links, each as a sentence.
  """
  @spec problems([Path.t()], Path.t()) :: [String.t()]
  def problems(pages, outputs) do
    linked =
      for page <- pages,
          target <- images(File.read!(page)),
          not (target =~ ~r/^[a-z][a-z0-9+.-]*:/i),
          do: {page, Path.expand(target, Path.dirname(page))}

    missing =
      for {page, target} <- linked,
          not File.exists?(target),
          do: "#{page} links #{Path.relative_to_cwd(target)}, which does not exist"

    linked_targets = MapSet.new(linked, &elem(&1, 1))

    unlinked =
      for output <- outputs |> Path.join("*.svg") |> Path.wildcard() |> Enum.sort(),
          not MapSet.member?(linked_targets, Path.expand(output)),
          do: "#{output} is linked from no page"

    missing ++ unlinked
  end

  @doc "The documents that hold a Mermaid block, each as a sentence."
  @spec mermaid([Path.t()]) :: [String.t()]
  def mermaid(documents) do
    for document <- documents,
        File.read!(document) =~ @mermaid,
        do: "#{document} holds a Mermaid block (eh-os D-107)"
  end

  # The SVG images a page shows, as Markdown (with or without a title) or as <img>, without the
  # fragment GitHub reads for a theme (#gh-dark-mode-only).
  defp images(page) do
    markdown = Regex.scan(~r/!\[(?:[^\]\\]|\\.)*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/, page)
    html = Regex.scan(~r/<img\b[^>]*\bsrc=["']([^"']+)["']/i, page)

    for [_, target] <- markdown ++ html,
        path = target |> String.split(["#", "?"]) |> hd(),
        String.ends_with?(path, ".svg"),
        do: path
  end
end

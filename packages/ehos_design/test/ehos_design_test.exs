defmodule EhosDesignTest do
  # eh-os D-72: the tokens are a copy of the design system, refreshed from Claude Design and never
  # edited by hand, and nothing in the package loads from another origin.
  use ExUnit.Case, async: true

  @package Path.expand("..", __DIR__)
  @repository Path.expand("../..", @package)
  @tokens Path.join(@package, "priv/css/colors_and_type.css")
  @source Path.join(@package, "priv/css/SOURCE.md")
  @layer Path.join(@package, "priv/css/ehos_design.css")
  @static Path.join(@package, "priv/static")

  # The custom properties a stylesheet defines: `--name:` at the start of a declaration.
  defp defined_properties(css) do
    ~r/(?:^|[;{\s])(--[a-z0-9-]+)\s*:/
    |> Regex.scan(css, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  test "the tokens are the file SOURCE.md records, so they have not been edited by hand" do
    [recorded] =
      Regex.run(~r/SHA-256 as committed \| `([0-9a-f]{64})`/, File.read!(@source),
        capture: :all_but_first
      )

    actual = :crypto.hash(:sha256, File.read!(@tokens)) |> Base.encode16(case: :lower)

    assert actual == recorded,
           "priv/css/colors_and_type.css differs from what SOURCE.md records. Refresh it from " <>
             "Claude Design and update SOURCE.md (README, \"Refreshing the tokens\"), rather " <>
             "than editing it."
  end

  test "git keeps the tokens' bytes as they are, so their hash holds on every checkout" do
    attributes = @repository |> Path.join(".gitattributes") |> File.read!() |> String.split("\n")

    assert "packages/ehos_design/priv/css/colors_and_type.css -text" in attributes
  end

  test "neither the tokens nor the layer for Tailwind name another origin" do
    for path <- [@tokens, @layer], css = File.read!(path) do
      refute css =~ ~r/url\(\s*["']?(?:[a-z]+:)?\/\//i, "#{path} loads a url from another origin"

      refute css =~ ~r/@import\s+(?:url\()?\s*["']?(?:[a-z]+:)?\/\//i,
             "#{path} imports from another origin"
    end
  end

  test "the layer for Tailwind imports the tokens beside it" do
    assert File.read!(@layer) =~ ~s|@import "./colors_and_type.css" layer(base);|
  end

  test "the layer for Tailwind refers to the tokens and never redefines one" do
    tokens = @tokens |> File.read!() |> defined_properties()
    layer = @layer |> File.read!() |> defined_properties()

    assert MapSet.size(tokens) > 50
    assert MapSet.intersection(tokens, layer) |> Enum.sort() == []
  end

  test "every font the layer names is in the package, under the path a host serves it at" do
    urls =
      ~r/url\("(\/ehos_design\/fonts\/[^"]+)"\)/
      |> Regex.scan(File.read!(@layer), capture: :all_but_first)
      |> List.flatten()

    assert length(urls) == 8
    assert length(Enum.uniq(urls)) == 8

    for url <- urls do
      assert File.regular?(Path.join(@static, url)), "#{url} is not in priv/static"
    end

    fonts = Path.join(@static, "ehos_design/fonts")
    assert File.regular?(Path.join(fonts, "OFL-albert-sans.txt"))
    assert File.regular?(Path.join(fonts, "OFL-jetbrains-mono.txt"))
  end

  test "the fonts are the ones the design system allows, Albert Sans and JetBrains Mono" do
    families =
      ~r/font-family:\s*"([^"]+)"/
      |> Regex.scan(File.read!(@layer), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert families == ["Albert Sans", "JetBrains Mono"]

    weights =
      ~r/font-weight:\s*(\d+)/
      |> Regex.scan(File.read!(@layer), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert weights == ["400", "500"]
  end
end

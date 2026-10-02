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

  # What a stylesheet could load from outside a host whose policy is `default-src 'self'`: a
  # scheme (`https:`, `data:`) or `//` in a `url(`, an `image-set(` or any quoted string, which
  # `@import` and `image-set` accept bare. Comments go first: an apostrophe in one would pair
  # with the next quote and hide what follows. A backslash is refused outright: a CSS escape can
  # spell any of these, and neither file has one.
  defp foreign_references(css) do
    css = String.replace(css, ~r{/\*.*?\*/}s, "")

    targets =
      ~r/url\(\s*([^)"'\s]+)|["']([^"']*)["']/
      |> Regex.scan(css, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&(&1 == ""))

    escapes = if String.contains?(css, "\\"), do: ["a backslash escape"], else: []
    Enum.filter(targets, &(&1 =~ ~r/\A\s*(?:[a-z][a-z0-9+.-]*:|\/\/)/i)) ++ escapes
  end

  test "the check for another origin finds every form a stylesheet could load one in" do
    for css <- [
          ~s|a { background: url(https://cdn.example/a.png); }|,
          ~s|a { background: url("//cdn.example/a.png"); }|,
          ~s|@import "https://fonts.example/css";|,
          ~s|a { background: image-set("https://cdn.example/a.png" 1x); }|,
          ~s|a { background: url("data:image/svg+xml,<svg/>"); }|,
          ~s|a { background: url("https:\\2f\\2f cdn.example/a.png"); }|,
          ~s|a { background: u\\72l(https://cdn.example/a.png); }|,
          ~s|/* the brand's fonts */\n@import url("https://fonts.example/css");|
        ] do
      assert foreign_references(css) != [], "missed: #{css}"
    end

    assert foreign_references(
             ~s|a { src: url("/ehos_design/fonts/a.woff2"); font: "Albert Sans"; }|
           ) ==
             []
  end

  test "neither the tokens nor the layer for Tailwind name another origin" do
    for path <- [@tokens, @layer] do
      assert path |> File.read!() |> foreign_references() == [],
             "#{path} refers to something outside the host's origin"
    end
  end

  test "the layer for Tailwind imports the tokens beside it" do
    assert File.read!(@layer) =~ ~s|@import "./colors_and_type.css" layer(base);|
  end

  test "every token the layer for Tailwind refers to is defined, so a refresh cannot drop one" do
    defined =
      MapSet.union(
        @tokens |> File.read!() |> defined_properties(),
        @layer |> File.read!() |> defined_properties()
      )

    used =
      ~r/var\(\s*(--[a-z0-9-]+)/
      |> Regex.scan(File.read!(@layer), capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.size(used) > 20
    assert MapSet.difference(used, defined) |> Enum.sort() == []
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

  test "every font is the file SOURCE.md records, so a changed one shows in review" do
    recorded =
      ~r/\| `([a-z0-9-]+\.woff2)` \| `([0-9a-f]{64})` \|/
      |> Regex.scan(File.read!(@source), capture: :all_but_first)
      |> Map.new(fn [file, hash] -> {file, hash} end)

    fonts = Path.join(@static, "ehos_design/fonts")
    files = fonts |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".woff2")) |> Enum.sort()

    assert files == recorded |> Map.keys() |> Enum.sort()

    for file <- files do
      actual = :crypto.hash(:sha256, File.read!(Path.join(fonts, file)))
      assert Base.encode16(actual, case: :lower) == recorded[file], "#{file} is not as recorded"
    end
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

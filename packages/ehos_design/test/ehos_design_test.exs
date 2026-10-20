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
  @components @package |> Path.join("priv/css/components/*.css") |> Path.wildcard() |> Enum.sort()

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
             "Claude Design and update SOURCE.md (README, \"Refreshing the design system\"), rather " <>
             "than editing it."
  end

  test "git keeps the tokens' bytes as they are, so their hash holds on every checkout" do
    attributes = @repository |> Path.join(".gitattributes") |> File.read!() |> String.split("\n")

    assert "packages/ehos_design/priv/css/colors_and_type.css -text" in attributes
  end

  # What a stylesheet could load from outside a host whose policy is `default-src 'self'`: a
  # scheme (`https:`, `data:`) or `//` in a `url(`, an `image-set(` or any quoted string, which
  # `@import` and `image-set` accept bare. Comments and strings are read in one pass, as
  # alternatives, so that neither an apostrophe nor a `/*` in one hides what follows it; a
  # function name is matched in any case, as CSS reads it; and tabs and newlines are dropped from
  # a target, as a browser's URL parser drops them. Any string that starts like a scheme counts,
  # `"Note: …"` included: a browser reads `https:cdn.example` as `https://cdn.example`, so the
  # check cannot ask for the slashes. A backslash is refused outright: a CSS escape
  # can spell any of these, and neither file has one.
  defp foreign_references(css) do
    targets =
      ~r{/\*.*?\*/|"([^"]*)"|'([^']*)'|url\(\s*([^)"'\s]+)}si
      |> Regex.scan(css, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.replace(&1, ~r/[\t\n\r]/, ""))
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
          ~s|/* the brand's fonts */\n@import url("https://fonts.example/css");|,
          ~s|a { src: URL(https://cdn.example/a.woff2); }|,
          ~s|a { font-family: "Brand's Sans"; } @import 'https://fonts.example/css';|,
          ~s|a { content: "/*"; } b { background: url(https://cdn.example/a.png); } c { content: "*/"; }|,
          ~s|a { src: url("/\t/cdn.example/a.woff2"); }|,
          ~s|a { src: url("ht\ttps://cdn.example/a.woff2"); }|
        ] do
      assert foreign_references(css) != [], "missed: #{css}"
    end

    assert foreign_references(
             ~s|a { src: url("/ehos_design/fonts/a.woff2"); font: "Albert Sans"; }|
           ) ==
             []
  end

  test "neither the tokens, the components nor the layer for Tailwind name another origin" do
    for path <- [@tokens, @layer | @components] do
      assert path |> File.read!() |> foreign_references() == [],
             "#{path} refers to something outside the host's origin"
    end
  end

  # A rule for :hover and one for :focus-visible have the same specificity, so the later one wins
  # when a keyboard-focused button is also under the pointer. The rules are read in order, each
  # selector of a list on its own.
  test "a button that changes its shadow on hover keeps its focus ring while hovered" do
    rules =
      ~r/([^{}]+)\{([^{}]*)\}/
      |> Regex.scan(@layer |> File.read!() |> String.replace(~r{/\*.*?\*/}s, ""),
        capture: :all_but_first
      )
      |> Enum.with_index()
      |> Enum.flat_map(fn {[selectors, body], index} ->
        for selector <- String.split(selectors, ","),
            do: {String.trim(selector), body =~ ~r/(?:^|[;{\s])box-shadow\s*:/, index}
      end)

    hovers =
      for {selector, true, index} <- rules,
          [button] <- [Regex.run(~r/\A(\.btn[a-z-]*):hover/, selector, capture: :all_but_first)],
          do: {button, index}

    assert hovers != [], "no button sets a shadow on hover, so this test checks nothing"

    for {button, hover} <- hovers do
      assert Enum.any?(rules, fn {selector, shadow?, index} ->
               shadow? and index > hover and
                 selector in [".btn:focus-visible", button <> ":focus-visible"]
             end),
             "#{button}:hover sets a shadow, and no focus ring follows it"
    end
  end

  # daisyUI fills .badge-success with --color-success, a solid olive slab the design system never
  # draws: each of daisyUI's badges shares its rule with the design system's badge it stands for.
  test "daisyUI's badges look like the design system's" do
    layer = File.read!(@layer)

    for selectors <- [
          ".eh-badge, .badge",
          ".eh-badge-neutral, .badge-neutral",
          ".eh-badge-live, .badge-success",
          ".eh-badge-error, .badge-error"
        ] do
      assert layer =~ selectors <> " {", selectors
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

    # A host serves everything under priv/static/ehos_design from its own origin, so nothing but
    # the fonts and their licences may be there: an SVG or an HTML file would run as the host.
    served =
      @static
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)

    licences = ["OFL-albert-sans.txt", "OFL-jetbrains-mono.txt"]

    assert Enum.map(served, &Path.relative_to(&1, fonts)) |> Enum.sort() ==
             Enum.sort(files ++ licences)

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

  # eh-os D-86: a component's look is a stylesheet from the design system's source, copied as the
  # tokens are.
  describe "the components' stylesheets" do
    defp recorded_components do
      ~r/\| `(components\/[a-z0-9-]+\.css)` \| `\d+` \| [^|]+ \| [^|]+ \| `([0-9a-f]{64})` \|/
      |> Regex.scan(File.read!(@source), capture: :all_but_first)
      |> Map.new(fn [file, hash] -> {file, hash} end)
    end

    test "are the files SOURCE.md records, so none has been edited by hand" do
      recorded = recorded_components()
      files = Enum.map(@components, &Path.relative_to(&1, Path.dirname(@tokens)))

      assert files != []
      assert files == recorded |> Map.keys() |> Enum.sort()

      for file <- files do
        actual =
          :crypto.hash(:sha256, File.read!(Path.join(Path.dirname(@tokens), file)))
          |> Base.encode16(case: :lower)

        assert actual == recorded[file],
               "priv/css/#{file} differs from what SOURCE.md records. Refresh it from Claude " <>
                 "Design (README, \"Refreshing the design system\"), rather than editing it."
      end
    end

    test "keep their bytes in git, so their hashes hold on every checkout" do
      attributes =
        @repository |> Path.join(".gitattributes") |> File.read!() |> String.split("\n")

      assert "packages/ehos_design/priv/css/components/*.css -text" in attributes
    end

    test "are each imported by the layer for Tailwind, in its components layer" do
      layer = File.read!(@layer)

      for path <- @components do
        assert layer =~ ~s|@import "./components/#{Path.basename(path)}" layer(components);|
      end
    end

    test "are written on the tokens alone, and define none of their own" do
      tokens = @tokens |> File.read!() |> defined_properties()

      for path <- @components do
        css = File.read!(path)

        used =
          ~r/var\(\s*(--[a-z0-9-]+)/
          |> Regex.scan(css, capture: :all_but_first)
          |> List.flatten()
          |> MapSet.new()

        assert MapSet.size(used) > 5
        assert MapSet.difference(used, tokens) |> Enum.sort() == [], "in #{path}"
        assert defined_properties(css) |> Enum.sort() == [], "in #{path}"
      end
    end
  end
end

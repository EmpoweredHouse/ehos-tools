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

  test "the check for another origin finds every form a stylesheet could load one in" do
    for {css, found} <- [
          {~s|a { background: url(https://cdn.example/a.png); }|, ["https://cdn.example/a.png"]},
          {~s|a { background: url("//cdn.example/a.png"); }|, ["//cdn.example/a.png"]},
          {~s|@import "https://fonts.example/css";|, ["https://fonts.example/css"]},
          {~s|a { background: image-set("https://cdn.example/a.png" 1x); }|,
           ["https://cdn.example/a.png"]},
          {~s|a { background: url("data:image/svg+xml,<svg/>"); }|,
           ["data:image/svg+xml,<svg/>"]},
          {~s|a { background: url("https:\\2f\\2f cdn.example/a.png"); }|,
           ["https:\\2f\\2f cdn.example/a.png", "a backslash escape"]},
          {~s|a { background: u\\72l(https://cdn.example/a.png); }|, ["a backslash escape"]},
          {~s|/* the brand's fonts */\n@import url("https://fonts.example/css");|,
           ["https://fonts.example/css"]},
          {~s|a { src: URL(https://cdn.example/a.woff2); }|, ["https://cdn.example/a.woff2"]},
          {~s|a { font-family: "Brand's Sans"; } @import 'https://fonts.example/css';|,
           ["https://fonts.example/css"]},
          {~s|a { content: "/*"; } b { background: url(https://cdn.example/a.png); } c { content: "*/"; }|,
           ["https://cdn.example/a.png"]},
          {~s|a { src: url("/\t/cdn.example/a.woff2"); }|, ["//cdn.example/a.woff2"]},
          {~s|a { src: url("ht\ttps://cdn.example/a.woff2"); }|, ["https://cdn.example/a.woff2"]}
        ] do
      assert foreign_references(css) == found, "in: #{css}"
    end

    assert foreign_references(
             ~s|a { src: url("/ehos_design/fonts/a.woff2"); font: "Albert Sans"; }|
           ) == []
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

  # The badges set a size and spacing, which the rules beside them leave to the page: in a layer
  # nested in the utilities one, they lose to the utilities a page adds (px-3, text-xs, ml-2),
  # and still win over daisyUI's badges, which daisyUI nests in a layer declared before it.
  test "the badges' rules sit in a layer of their own, so a page's utilities override them" do
    css = @layer |> File.read!() |> String.replace(~r{/\*.*?\*/}s, "")

    nested =
      for {"@layer utilities", utilities} <- blocks(css),
          {"@layer ehos-design", nested} <- blocks(utilities),
          do: nested

    assert [nested] = nested, "no one @layer ehos-design inside a top-level @layer utilities"

    for selector <- [
          ".eh-badge, .badge",
          ".eh-badge-neutral, .badge-neutral",
          ".eh-badge-live, .badge-success",
          ".eh-badge-error, .badge-error",
          ".eh-badge-dot"
        ] do
      assert selector in Enum.map(blocks(nested), &elem(&1, 0)), selector

      # Nowhere else, where it would be in another layer.
      assert css |> String.split(selector <> " {") |> length() == 2, selector
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

    assert urls ==
             Enum.map(
               ~w(albert-sans-latin-400 albert-sans-latin-ext-400 albert-sans-latin-500
                  albert-sans-latin-ext-500 jetbrains-mono-latin-400 jetbrains-mono-latin-ext-400
                  jetbrains-mono-latin-500 jetbrains-mono-latin-ext-500),
               &"/ehos_design/fonts/#{&1}-normal.woff2"
             )

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

  test "nothing but the fonts, their licences and the icons is where a host serves them from" do
    fonts = Path.join(@static, "ehos_design/fonts")
    files = fonts |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".woff2")) |> Enum.sort()

    # A host serves everything under priv/static/ehos_design from its own origin, so nothing but
    # the fonts, their licences and the icons may be there: an SVG or an HTML file would run as
    # the host, so the one SVG there is the file SOURCE.md records.
    served =
      @static
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, @static))
      |> Enum.sort()

    licences = ["OFL-albert-sans.txt", "OFL-jetbrains-mono.txt"]

    assert served ==
             Enum.sort(
               Enum.map(files ++ licences, &"ehos_design/fonts/#{&1}") ++
                 Enum.map(Map.keys(recorded_icons()), &"ehos_design/icons/#{&1}")
             )
  end

  test "every icon is the file SOURCE.md records, the EmpoweredHouse icon as its website serves it" do
    icons = Path.join(@static, "ehos_design/icons")

    assert icons |> File.ls!() |> Enum.sort() == recorded_icons() |> Map.keys() |> Enum.sort()

    for {file, hash} <- recorded_icons() do
      actual = :crypto.hash(:sha256, File.read!(Path.join(icons, file)))
      assert Base.encode16(actual, case: :lower) == hash, "#{file} is not as recorded"
    end

    # An SVG served from the host's origin could run a script as the host, or load from another
    # origin. So a new one may hold only shapes and their attributes, and no declaration.
    svg = File.read!(Path.join(icons, "favicon.svg"))
    refute svg =~ "<!"

    elements = ~r/<\/?\s*([A-Za-z][\w:.-]*)/ |> Regex.scan(svg, capture: :all_but_first)
    assert elements |> List.flatten() |> Enum.uniq() |> Enum.sort() == ~w(rect svg)

    attributes = ~r/([A-Za-z][\w:.-]*)\s*=/ |> Regex.scan(svg, capture: :all_but_first)

    assert attributes |> List.flatten() |> Enum.uniq() |> Enum.sort() ==
             ~w(aria-label fill height role rx stroke stroke-width viewBox width x xmlns y)

    # No value but the namespace names an address: a fill or a stroke could load from another
    # origin.
    refute String.replace(svg, ~s(xmlns="http://www.w3.org/2000/svg"), "") =~ ~r{url\(|://}i
    # A character reference could spell what the checks above look for.
    refute svg =~ "&"
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

  # The custom properties a stylesheet defines: `--name:` at the start of a declaration.
  defp defined_properties(css) do
    ~r/(?:^|[;{\s])(--[a-z0-9-]+)\s*:/
    |> Regex.scan(css, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
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

  # The blocks at the top level of a stylesheet without comments: each `{head, body}`, found by
  # counting braces, since a body holds blocks of its own.
  defp blocks(css), do: blocks(css, [])

  defp blocks(css, found) do
    case :binary.match(css, "{") do
      :nomatch ->
        Enum.reverse(found)

      {open, 1} ->
        head =
          css |> binary_part(0, open) |> String.split(~r/[;}]/) |> List.last() |> String.trim()

        rest = binary_part(css, open + 1, byte_size(css) - open - 1)
        {body, after_block} = take_body(rest, 1, [])
        blocks(after_block, [{head, body} | found])
    end
  end

  defp take_body(<<"}", rest::binary>>, 1, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_body(<<"}", rest::binary>>, depth, acc), do: take_body(rest, depth - 1, ["}" | acc])
  defp take_body(<<"{", rest::binary>>, depth, acc), do: take_body(rest, depth + 1, ["{" | acc])

  defp take_body(<<char::utf8, rest::binary>>, depth, acc),
    do: take_body(rest, depth, [<<char::utf8>> | acc])

  # The components' stylesheets SOURCE.md records, each with its SHA-256.
  defp recorded_components do
    ~r/\| `(components\/[a-z0-9-]+\.css)` \| `\d+` \| [^|]+ \| [^|]+ \| `([0-9a-f]{64})` \|/
    |> Regex.scan(File.read!(@source), capture: :all_but_first)
    |> Map.new(fn [file, hash] -> {file, hash} end)
  end

  # The icons SOURCE.md records, by file, with their SHA-256.
  defp recorded_icons do
    ~r/\| `([a-z0-9-]+\.(?:svg|ico|png))` \| `([0-9a-f]{64})` \|/
    |> Regex.scan(File.read!(@source), capture: :all_but_first)
    |> Map.new(fn [file, hash] -> {file, hash} end)
  end
end

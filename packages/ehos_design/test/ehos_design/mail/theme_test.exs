defmodule EhosDesign.Mail.ThemeTest do
  # eh-os D-122: the mail is styled from the package's own tokens, read when it compiles.
  use ExUnit.Case, async: true

  alias EhosDesign.Mail.{Stylesheet, Theme}

  @package Path.expand("../../../priv/css/colors_and_type.css", __DIR__)

  test "the tokens are the package's light theme, with the brand's constants" do
    css = File.read!(@package)
    root = Stylesheet.declarations(css, ":root")
    light = Stylesheet.declarations(css, ~s([data-theme="light"]))
    tokens = Theme.tokens()

    assert tokens.canvas == light["canvas"]
    assert tokens.surface == light["surface-3"]
    assert tokens.text_primary == light["text-primary"]
    assert tokens.text_secondary == light["text-secondary"]
    assert tokens.text_tertiary == light["text-tertiary"]
    # Lime read as text deepens on the light theme; lime as a fill keeps its colour.
    assert light["accent-ink"] == "var(--lime-deep)"
    assert tokens.accent_ink == root["lime-deep"]
    assert tokens.lime == root["lime"]
    assert tokens.on_accent == root["on-accent"]
    assert tokens.sans == root["sans"]
    assert tokens.mono == root["mono"]
    assert tokens.radius_lg == root["radius-lg"]
  end

  # The layout writes the tokens into its <style> as they are, unescaped.
  test "every token is a value a mail program reads, and cannot end a rule or the stylesheet" do
    for {key, value} <- Theme.tokens() do
      refute value =~ "var(", "#{key} is #{value}"
      refute value =~ "rgba(", "#{key} is #{value}"
      refute value =~ ~r/[<>{};]/, "#{key} is #{value}"
    end
  end

  test "a translucent hairline is the solid colour it shows over what is under it" do
    assert Stylesheet.solid("rgba(0, 0, 0, 0.5)", "#FFFFFF") == "#808080"
    assert Stylesheet.solid("rgba(255, 255, 255, .25)", "#000000") == "#404040"
    assert Stylesheet.solid("#1B1813", "#FFFFFF") == "#1B1813"

    tokens = Theme.tokens()
    # The panel's border lies on the canvas; the divider inside it, on the panel's surface.
    assert tokens.border == Stylesheet.solid(light_value("border-soft"), tokens.canvas)
    assert tokens.divider == Stylesheet.solid(light_value("border-soft"), tokens.surface)
    assert tokens.border != tokens.divider
  end

  test "a stylesheet without the light theme, or without a token the mail uses, is refused" do
    css = File.read!(@package)

    assert_raise ArgumentError, ~r/no block \[data-theme="light"\]/, fn ->
      css
      |> String.replace(~s([data-theme="light"] {), "[data-theme=light] {")
      |> Stylesheet.tokens()
    end

    assert_raise ArgumentError, ~r/does not define --lime-deep/, fn ->
      css |> String.replace("--lime-deep:", "--lime-darker:") |> Stylesheet.tokens()
    end

    assert_raise ArgumentError, ~r/does not define --surface-3/, fn ->
      css |> String.replace("--surface-3:", "--surface-4:") |> Stylesheet.tokens()
    end

    assert_raise ArgumentError, ~r/more than 8 var/, fn ->
      css
      |> String.replace("--lime-deep:  #4A7314;", "--lime-deep: var(--accent-ink);")
      |> Stylesheet.tokens()
    end
  end

  test "a token the mail does not use cannot fail it" do
    css =
      @package
      |> File.read!()
      |> String.replace("--scrim: rgba(240, 238, 233, 0.94);", "--scrim: var(--nowhere, #fff);")

    assert Stylesheet.tokens(css) == Theme.tokens()
  end

  defp light_value(name) do
    @package
    |> File.read!()
    |> Stylesheet.declarations(~s([data-theme="light"]))
    |> Map.fetch!(name)
  end
end

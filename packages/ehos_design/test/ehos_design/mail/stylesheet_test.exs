defmodule EhosDesign.Mail.StylesheetTest do
  # eh-os D-122: the design system's stylesheet, read for the mail.
  use ExUnit.Case, async: true

  alias EhosDesign.Mail.{Stylesheet, Theme}

  doctest Stylesheet

  @package Path.expand("../../../priv/css/colors_and_type.css", __DIR__)

  describe "tokens/1" do
    test "a token the mail does not use cannot fail it" do
      css =
        @package
        |> File.read!()
        |> String.replace("--scrim: rgba(240, 238, 233, 0.94);", "--scrim: var(--nowhere, #fff);")

      assert Stylesheet.tokens(css) == Theme.tokens()
    end

    test "a stylesheet without the light theme, or without a token the mail uses, is refused" do
      css = File.read!(@package)

      assert_raise ArgumentError,
                   ~s(the stylesheet has no block [data-theme="light"] at the start of a line),
                   fn ->
                     css
                     |> String.replace(~s([data-theme="light"] {), "[data-theme=light] {")
                     |> Stylesheet.tokens()
                   end

      assert_raise ArgumentError, "the stylesheet does not define --lime-deep", fn ->
        css |> String.replace("--lime-deep:", "--lime-darker:") |> Stylesheet.tokens()
      end

      assert_raise ArgumentError, "the stylesheet does not define --surface-3", fn ->
        css |> String.replace("--surface-3:", "--surface-4:") |> Stylesheet.tokens()
      end

      assert_raise ArgumentError, "--accent-ink is reached through more than 8 var()s", fn ->
        css
        |> String.replace("--lime-deep:  #4A7314;", "--lime-deep: var(--accent-ink);")
        |> Stylesheet.tokens()
      end
    end
  end

  describe "solid/2" do
    test "a translucent colour is the solid colour it shows over what is under it" do
      assert Stylesheet.solid("rgba(0, 0, 0, 0.5)", "#FFFFFF") == "#808080"
      assert Stylesheet.solid("rgba(255, 255, 255, .25)", "#000000") == "#404040"
      assert Stylesheet.solid("#1B1813", "#FFFFFF") == "#1B1813"
    end
  end
end

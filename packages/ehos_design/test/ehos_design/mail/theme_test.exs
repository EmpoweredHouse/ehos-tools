defmodule EhosDesign.Mail.ThemeTest do
  # eh-os D-122: the mail is styled from the package's own tokens, read when it compiles.
  use ExUnit.Case, async: true

  alias EhosDesign.Mail.{Stylesheet, Theme}

  @package Path.expand("../../../priv/css/colors_and_type.css", __DIR__)

  test "the tokens are the package's light theme, with the brand's constants" do
    css = File.read!(@package)
    light_block = Stylesheet.declarations(css, ~s([data-theme="light"]))
    light = Map.merge(Stylesheet.declarations(css, ":root"), light_block)

    # Lime read as text deepens on the light theme; lime as a fill keeps its colour.
    assert light_block["accent-ink"] == "var(--lime-deep)"

    assert Theme.tokens() == %{
             canvas: light["canvas"],
             surface: light["surface-3"],
             text_primary: light["text-primary"],
             text_secondary: light["text-secondary"],
             text_tertiary: light["text-tertiary"],
             accent_ink: light["lime-deep"],
             lime: light["lime"],
             on_accent: light["on-accent"],
             sans: light["sans"],
             mono: light["mono"],
             h3_size: light["h3-size"],
             h3_track: light["h3-track"],
             h3_lh: light["h3-lh"],
             body_size: light["body-size"],
             body_track: light["body-track"],
             body_lh: light["body-lh"],
             caption_size: light["caption-size"],
             caption_lh: light["caption-lh"],
             eyebrow_size: light["eyebrow-size"],
             eyebrow_track: light["eyebrow-track"],
             record_size: light["record-size"],
             radius_sm: light["radius-sm"],
             radius_lg: light["radius-lg"],
             # The translucent hairline as the solid colour it shows: the panel's border over the
             # canvas, the divider inside it over the panel's surface.
             border: Stylesheet.solid(light["border-soft"], light["canvas"]),
             divider: Stylesheet.solid(light["border-soft"], light["surface-3"])
           }

    assert Theme.tokens().border != Theme.tokens().divider
  end

  # The layout writes the tokens into its <style> as they are, unescaped.
  test "every token is a value a mail program reads, and cannot end a rule or the stylesheet" do
    for {key, value} <- Theme.tokens() do
      refute value =~ "var(", "#{key} is #{value}"
      refute value =~ "rgba(", "#{key} is #{value}"
      refute value =~ ~r/[<>{};]/, "#{key} is #{value}"
    end
  end
end

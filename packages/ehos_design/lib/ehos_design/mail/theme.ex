defmodule EhosDesign.Mail.Theme do
  @moduledoc """
  The design system's tokens as the mail uses them (eh-os D-122): the light theme's values, resolved
  by `EhosDesign.Mail.Stylesheet` when the package compiles, from its own
  `priv/css/colors_and_type.css`. A refreshed token changes the mail with the next release.

  A hairline is translucent in the design system, so it has two values here, each the solid colour
  it shows over what is under it: `:border` around the panel, over the canvas, and `:divider`
  inside it, over the panel's surface.
  """

  alias EhosDesign.Mail.Stylesheet

  @source Path.expand("../../../priv/css/colors_and_type.css", __DIR__)
  @external_resource @source

  @tokens @source |> File.read!() |> Stylesheet.tokens()

  @doc "The tokens the mail's layout uses, resolved when the package compiled."
  @spec tokens() :: %{atom() => Stylesheet.value()}
  def tokens, do: @tokens
end

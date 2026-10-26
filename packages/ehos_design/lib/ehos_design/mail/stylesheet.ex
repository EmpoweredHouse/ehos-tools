defmodule EhosDesign.Mail.Stylesheet do
  @moduledoc """
  Reads the package's `colors_and_type.css` for the mail (eh-os D-122): the light theme's custom
  properties, each resolved to the value a mail program reads, since mail programs ignore custom
  properties and Outlook ignores transparency. `EhosDesign.Mail.Theme` calls it when the package
  compiles, so a stylesheet it cannot read fails the build, not a message.

  It reads the file as the design system writes it, not any CSS: a block's selector at the start of
  a line and its closing brace alone on one, `var(--name)` without a fallback, and
  `rgba(r, g, b, a)` with comma-separated channels. What it cannot read among the tokens the mail
  uses raises `ArgumentError`.
  """

  @typedoc "A token's value, as CSS a mail program reads: `#1B1813`, `16px`, a font stack."
  @type value :: String.t()

  # The token each key is read from, as the design system names it.
  @names %{
    canvas: "canvas",
    surface: "surface-3",
    text_primary: "text-primary",
    text_secondary: "text-secondary",
    text_tertiary: "text-tertiary",
    accent_ink: "accent-ink",
    lime: "lime",
    on_accent: "on-accent",
    sans: "sans",
    mono: "mono",
    h3_size: "h3-size",
    h3_track: "h3-track",
    h3_lh: "h3-lh",
    body_size: "body-size",
    body_track: "body-track",
    body_lh: "body-lh",
    caption_size: "caption-size",
    caption_lh: "caption-lh",
    eyebrow_size: "eyebrow-size",
    eyebrow_track: "eyebrow-track",
    record_size: "record-size",
    radius_sm: "radius-sm",
    radius_lg: "radius-lg"
  }

  @doc """
  The tokens the mail uses, from the stylesheet `css`'s light theme, keyed as the layout reads
  them: `:canvas`, `:surface`, the three text colours, `:accent_ink`, `:lime`, `:on_accent`, the two
  font stacks, the type's sizes, tracking and line heights, the two radii, and the hairline as
  `:border` and `:divider`. Only these are resolved, so a token the mail does not use cannot fail
  it. The package's own are `EhosDesign.Mail.Theme.tokens/0`.
  """
  @spec tokens(String.t()) :: %{atom() => value()}
  def tokens(css) do
    light = light(css)
    tokens = Map.new(@names, fn {key, name} -> {key, resolve(light, name)} end)
    hairline = resolve(light, "border-soft")

    Map.merge(tokens, %{
      border: solid(hairline, tokens.canvas),
      divider: solid(hairline, tokens.surface)
    })
  end

  @doc """
  The declarations of the block whose selector is `selector`, exactly as written (`:root`,
  `[data-theme="light"]`), by name without the leading `--`; comments are dropped. Raises when the
  stylesheet has no such block.
  """
  @spec declarations(String.t(), String.t()) :: %{String.t() => String.t()}
  def declarations(css, selector) do
    css = Regex.replace(~r{/\*.*?\*/}s, css, "")

    case String.split(css, "\n" <> selector <> " {", parts: 2) do
      [_before, block] ->
        [body | _] = String.split(block, "\n}", parts: 2)

        ~r/--([a-z0-9-]+)\s*:\s*([^;]+);/
        |> Regex.scan(body, capture: :all_but_first)
        |> Map.new(fn [name, value] -> {name, String.trim(value)} end)

      [_no_block] ->
        raise ArgumentError, "the stylesheet has no block #{selector} at the start of a line"
    end
  end

  # The light theme: `[data-theme="light"]`'s declarations over `:root`'s, as written.
  defp light(css),
    do: Map.merge(declarations(css, ":root"), declarations(css, ~s([data-theme="light"])))

  # The value `name` has, following each `var(…)` it names, at most @max_depth deep, so a loop
  # fails the build instead of hanging it.
  @max_depth 8

  defp resolve(tokens, name, depth \\ 0)

  defp resolve(_tokens, name, @max_depth),
    do: raise(ArgumentError, "--#{name} is reached through more than #{@max_depth} var()s")

  defp resolve(tokens, name, depth) do
    case Map.fetch(tokens, name) do
      {:ok, "var(--" <> rest} -> resolve(tokens, String.trim_trailing(rest, ")"), depth + 1)
      {:ok, value} -> value
      :error -> raise ArgumentError, "the stylesheet does not define --#{name}"
    end
  end

  @doc """
  The solid colour `colour` shows over `background`, a `#RRGGBB`: an `rgba(r, g, b, a)` laid over
  it, and any other value as it is.
  """
  @spec solid(String.t(), String.t()) :: String.t()
  def solid("rgba(" <> rest, "#" <> background) do
    [r, g, b, a] =
      rest |> String.trim_trailing(")") |> String.split(",") |> Enum.map(&String.trim/1)

    alpha = number(a)
    {:ok, <<br, bg, bb>>} = Base.decode16(background, case: :mixed)

    [{r, br}, {g, bg}, {b, bb}]
    |> Enum.map(fn {top, under} ->
      round(String.to_integer(top) * alpha + under * (1 - alpha))
    end)
    |> then(&("#" <> Base.encode16(:binary.list_to_bin(&1))))
  end

  def solid(colour, _background), do: colour

  # `0.14`, or `.14` as CSS also writes it.
  defp number("." <> _ = text), do: number("0" <> text)

  defp number(text) do
    {number, ""} = Float.parse(text)
    number
  end
end

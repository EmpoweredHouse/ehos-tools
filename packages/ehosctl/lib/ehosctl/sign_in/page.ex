defmodule Ehosctl.SignIn.Page do
  @moduledoc """
  The page the browser shows when it comes back to `ehosctl` (`Ehosctl.SignIn.Loopback`): one
  line on what happened, in the EmpoweredHouse design system, as EHOS's log-in page the browser
  just left is.

  It is the design system's outcome (`components/outcome.css`, `EhosDesign.Components.outcome/1`),
  on an `.eh-outcome-page`, with the markup the component renders, except that its title is an
  `<h1>`, the page's only heading. The page loads nothing: the tokens (`colors_and_type.css`), the
  outcome's stylesheet and the fonts' `@font-face` rules are those of `packages/ehos_design` in
  this repository, read when `ehosctl` is compiled, with each font inlined as a `data:` URI. So a
  refresh of the design system reaches this page with the next build, and `ehosctl` keeps no look
  of its own, only the markup the outcome's stylesheet styles. Its theme follows the system's, as
  the tokens' own `prefers-color-scheme` rule says.

  So `ehosctl` is built from a checkout of the whole repository, as CI builds it: without
  `packages/ehos_design` beside it, it does not compile.
  """

  @priv Path.expand("../../../../ehos_design/priv", __DIR__)
  @tokens_file Path.join(@priv, "css/colors_and_type.css")
  @outcome_file Path.join(@priv, "css/components/outcome.css")
  @layer_file Path.join(@priv, "css/ehos_design.css")
  @fonts_dir Path.join(@priv, "static/ehos_design/fonts")

  @external_resource @tokens_file
  @external_resource @outcome_file
  @external_resource @layer_file

  @tokens File.read!(@tokens_file)
  @outcome File.read!(@outcome_file)

  # The faces the page sets its text in: Albert Sans for the card, JetBrains Mono for the
  # header, in the Latin its English and an address need. Any other character falls back to the
  # system's fonts, as the tokens' stacks say; the other faces would add 80 KB to every answer.
  @faces ~w(albert-sans-latin-400-normal albert-sans-latin-500-normal
            jetbrains-mono-latin-400-normal)

  # The layer's @font-face rules for those faces.
  @rules ~r/@font-face\s*\{[^}]*\}/
         |> Regex.scan(File.read!(@layer_file))
         |> Enum.map(&hd/1)
         |> Enum.filter(fn rule -> Enum.any?(@faces, &String.contains?(rule, "/#{&1}.woff2")) end)

  # Each with its font's URL replaced by the font itself.
  @fonts Enum.map_join(@rules, "\n", fn rule ->
           Regex.replace(~r{url\("/ehos_design/fonts/([a-z0-9-]+\.woff2)"\)}, rule, fn _, name ->
             data = @fonts_dir |> Path.join(name) |> File.read!() |> Base.encode64()
             ~s{url("data:font/woff2;base64,#{data}")}
           end)
         end)

  for face <- @faces, do: @external_resource(Path.join(@fonts_dir, face <> ".woff2"))

  missing =
    Enum.reject(@faces, fn face -> Enum.any?(@rules, &String.contains?(&1, "/#{face}.woff2")) end)

  if missing != [] do
    raise "the design system's layer no longer declares #{Enum.join(missing, ", ")}, " <>
            "which the sign-in page sets its text in"
  end

  # The page loads nothing, so the build fails rather than the page on a `url(` that is not a
  # `data:` URI (a font path the replacement above did not recognise, say), an `@import`, or a
  # `</style` that would end the inlined styles.
  for {name, css} <- [tokens: @tokens, outcome: @outcome, fonts: @fonts],
      Regex.match?(~r/url\((?!"data:)|@import|<\/style/i, css) do
    raise "the design system's #{name} would load something from elsewhere: #{@priv}"
  end

  # Everything up to the title, built once: the styles are most of the page's 77 KB.
  @head """
  <!doctype html>
  <html lang="en">
  <head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <style>
  #{@tokens}
  #{@fonts}
  #{@outcome}
  </style>
  """

  @typedoc "What happened, as the page says it: an outcome, a title, a sentence and a hint."
  @type t :: %{
          required(:tone) => :ok | :error,
          required(:title) => String.t(),
          required(:text) => String.t(),
          optional(:hint) => String.t()
        }

  @doc """
  The `Content-Security-Policy` the page is served with: nothing loaded, its own inline styles
  and fonts alone.
  """
  @spec content_security_policy() :: String.t()
  def content_security_policy,
    do:
      "default-src 'none'; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; " <>
        "form-action 'none'"

  @doc """
  The page, as HTML in iodata: its head is one binary built when `ehosctl` is compiled, not copied
  for each request. Every text in `page` is escaped.

      iex> page = Ehosctl.SignIn.Page.render(%{tone: :ok, title: "Signed in", text: "<b>"})
      iex> html = IO.iodata_to_binary(page)
      iex> html =~ "Signed in" and html =~ "&lt;b&gt;" and not (html =~ "<b>")
      true
  """
  @spec render(t()) :: iodata()
  def render(%{tone: tone, title: title, text: text} = page) do
    hint =
      case page[:hint] do
        nil -> ""
        hint -> ~s(<p class="eh-outcome-hint">#{escape(hint)}</p>)
      end

    [
      @head,
      """
      <title>#{escape(title)} · ehosctl</title>
      </head>
      <body class="eh-outcome-page eh-ambient">
      <header class="eh-outcome-header">EHOS · ehosctl</header>
      <main>
      <div class="eh-outcome"#{kind(tone)} role="status">
      <span class="eh-outcome-mark" aria-hidden="true"></span>
      <h1 class="eh-outcome-title">#{escape(title)}</h1>
      <p class="eh-outcome-text">#{escape(text)}</p>
      #{hint}
      </div>
      </main>
      </body>
      </html>
      """
    ]
  end

  defp kind(:ok), do: ""
  defp kind(:error), do: ~s( data-kind="error")

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

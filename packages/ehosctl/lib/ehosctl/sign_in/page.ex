defmodule Ehosctl.SignIn.Page do
  @moduledoc """
  The page the browser shows when it comes back to `ehosctl` (`Ehosctl.SignIn.Loopback`): one
  line on what happened, in the EmpoweredHouse design system, as EHOS's log-in page the browser
  just left is.

  It is the design system's outcome (`components/outcome.css`, `EhosDesign.Components.outcome/1`),
  on an `.eh-outcome-page`. The page loads nothing: the tokens (`colors_and_type.css`), the
  outcome's stylesheet and the fonts' `@font-face` rules are those of `packages/ehos_design` in
  this repository, read when `ehosctl` is compiled, with each font inlined as a `data:` URI. So a
  refresh of the design system reaches this page with the next build, and `ehosctl` keeps no look
  of its own, only the markup the outcome's stylesheet styles. Its theme follows the system's, as
  the tokens' own `prefers-color-scheme` rule says.
  """

  @priv Path.expand("../../../../ehos_design/priv", __DIR__)
  @tokens_file Path.join(@priv, "css/colors_and_type.css")
  @outcome_file Path.join(@priv, "css/components/outcome.css")
  @layer_file Path.join(@priv, "css/ehos_design.css")
  @fonts_dir Path.join(@priv, "static/ehos_design/fonts")

  @external_resource @tokens_file
  @external_resource @outcome_file
  @external_resource @layer_file
  for font <- Path.wildcard(Path.join(@fonts_dir, "*.woff2")), do: @external_resource(font)

  @tokens File.read!(@tokens_file)
  @outcome File.read!(@outcome_file)

  # The layer's @font-face rules, each font's URL replaced by the font itself.
  @fonts ~r/@font-face\s*\{[^}]*\}/
         |> Regex.scan(File.read!(@layer_file))
         |> Enum.map_join("\n", fn [rule] ->
           Regex.replace(~r{url\("/ehos_design/fonts/([a-z0-9-]+\.woff2)"\)}, rule, fn _, name ->
             data = @fonts_dir |> Path.join(name) |> File.read!() |> Base.encode64()
             ~s{url("data:font/woff2;base64,#{data}")}
           end)
         end)

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
      "default-src 'none'; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'"

  @doc """
  The page, as HTML. Every text in `page` is escaped.

      iex> html = Ehosctl.SignIn.Page.render(%{tone: :ok, title: "Signed in", text: "<b>"})
      iex> html =~ "Signed in" and html =~ "&lt;b&gt;" and not (html =~ "<b>")
      true
  """
  @spec render(t()) :: String.t()
  def render(%{tone: tone, title: title, text: text} = page) do
    hint =
      case page[:hint] do
        nil -> ""
        hint -> ~s(<p class="eh-outcome-hint">#{escape(hint)}</p>)
      end

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <title>#{escape(title)} · ehosctl</title>
    <style>
    #{@tokens}
    #{@fonts}
    #{@outcome}
    </style>
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

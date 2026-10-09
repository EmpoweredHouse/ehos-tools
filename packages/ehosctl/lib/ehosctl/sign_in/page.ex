defmodule Ehosctl.SignIn.Page do
  @moduledoc """
  The page the browser shows when it comes back to `ehosctl` (`Ehosctl.SignIn.Loopback`): one
  line on what happened, in the EmpoweredHouse design system, as EHOS's log-in page the browser
  just left is.

  The page loads nothing. The design system's tokens (`colors_and_type.css`) and its fonts'
  `@font-face` rules are those of `packages/ehos_design` in this repository, read when `ehosctl`
  is compiled, with each font inlined as a `data:` URI, so a refresh of the design system reaches
  this page with the next build and the page needs no server but the loopback one. Its theme
  follows the system's, as the tokens' own `prefers-color-scheme` rule says.
  """

  @priv Path.expand("../../../../ehos_design/priv", __DIR__)
  @tokens_file Path.join(@priv, "css/colors_and_type.css")
  @layer_file Path.join(@priv, "css/ehos_design.css")
  @fonts_dir Path.join(@priv, "static/ehos_design/fonts")

  @external_resource @tokens_file
  @external_resource @layer_file
  for font <- Path.wildcard(Path.join(@fonts_dir, "*.woff2")), do: @external_resource(font)

  @tokens File.read!(@tokens_file)

  # The layer's @font-face rules, each font's URL replaced by the font itself.
  @fonts ~r/@font-face\s*\{[^}]*\}/
         |> Regex.scan(File.read!(@layer_file))
         |> Enum.map_join("\n", fn [rule] ->
           Regex.replace(~r{url\("/ehos_design/fonts/([a-z0-9-]+\.woff2)"\)}, rule, fn _, name ->
             data = @fonts_dir |> Path.join(name) |> File.read!() |> Base.encode64()
             ~s{url("data:font/woff2;base64,#{data}")}
           end)
         end)

  # What this page adds: its layout, on the tokens alone. Hairlines, no shadows, weights 400
  # and 500, one accent, as the design system's rules say.
  @layout """
  html, body { margin: 0; min-height: 100vh; background: var(--canvas); }
  body { font-family: var(--sans); -webkit-font-smoothing: antialiased; }
  header {
    position: relative; z-index: 1;
    padding: 18px var(--gutter-mobile);
    border-bottom: 1px solid var(--border-faint);
  }
  main {
    position: relative; z-index: 1;
    max-width: 440px; margin: 14vh auto 0; padding: 0 var(--gutter-mobile);
  }
  .card {
    background: var(--surface-1);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius-lg);
    padding: 28px;
  }
  .mark {
    width: 36px; height: 36px; margin-bottom: 20px;
    display: flex; align-items: center; justify-content: center;
    border-radius: 50%;
    background: var(--accent-soft); border: 1px solid var(--accent-border);
    color: var(--accent-ink);
  }
  .error .mark {
    background: var(--error-soft); border-color: var(--error-border); color: var(--error-ink);
  }
  h1 { margin: 0 0 8px; }
  p { margin: 0; }
  .eh-caption { margin-top: 20px; }
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
        hint -> ~s(<p class="eh-caption">#{escape(hint)}</p>)
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
    #{@layout}
    </style>
    </head>
    <body class="eh-ambient">
    <header><span class="eh-eyebrow">EHOS · ehosctl</span></header>
    <main class="#{tone}">
    <div class="card">
    <div class="mark" aria-hidden="true">#{mark(tone)}</div>
    <h1 class="eh-h3">#{escape(title)}</h1>
    <p class="eh-body">#{escape(text)}</p>
    #{hint}
    </div>
    </main>
    </body>
    </html>
    """
  end

  defp mark(:ok),
    do:
      ~s(<svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8.5l3.2 3L13 4.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>)

  defp mark(:error),
    do:
      ~s(<svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>)

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

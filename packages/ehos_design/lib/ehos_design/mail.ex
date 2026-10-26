defmodule EhosDesign.Mail do
  @moduledoc """
  The one layout a message is mailed in (eh-os D-122): an HTML part written in HEEx as tables,
  styled from the design system's light tokens (`EhosDesign.Mail.Theme`) through a stylesheet that
  `premailex` moves into each element's `style`, and a plain-text part with the same words and the
  same links. EHOS renders its own messages in it, and an application the ones it sends through
  EHOS's mail API.

  A message (`t:t/0`) is its words, and its body is a list of blocks (`t:block/0`) given as data, not
  slots of HEEx: both parts are rendered from the same blocks, so they cannot say different things,
  and each block is checked in mail programs once, whatever it is combined with. The frame around
  them, the wordmark, the panel and the footer, is the same for every message.

  Every value is plain text. HEEx escapes it, and Floki, which reads the HTML for `premailex` and
  writes it out again, keeps it escaped whatever the host configures for Floki, so a name or an
  address cannot change the markup. Nothing
  in the HTML names another origin but an action's link: no image, font or stylesheet is fetched
  when the message is opened, so the fonts are the stacks' fallbacks wherever Albert Sans and
  JetBrains Mono are not installed.

      iex> message = %{
      ...>   brand: "Office",
      ...>   subject: "Documents for November",
      ...>   preview: "Two documents, by 10 November.",
      ...>   heading: "Documents for November",
      ...>   body: [{:paragraph, "Please send us:"}, {:rows, [{"Bank statements", "by 10.11.2026"}]}],
      ...>   footer: ["Office, accounting"]
      ...> }
      iex> EhosDesign.Mail.text(message)
      "Office\\n\\nDocuments for November\\n\\nPlease send us:\\n\\n- Bank statements: by 10.11.2026\\n\\n--\\nOffice, accounting\\n"
      iex> EhosDesign.Mail.html(message) =~ "Bank statements"
      true
  """

  use Phoenix.Component

  alias EhosDesign.Mail.Theme
  alias Phoenix.HTML.Safe

  @typedoc """
  A part of a message's body:

    * `{:paragraph, text}` — a paragraph;
    * `{:rows, [{item, detail}]}` — items, each with its detail on the right: a task and its due
      date. The text part writes each as `- item: detail`;
    * `{:action, %{label: label, url: url, hint: hint}}` — a button leading to `url`, an absolute
      `http`, `https` or `mailto` link, with the link written out under it and `hint`, which is
      optional, above that. The text part writes `label:` and the link. Any other link raises
      `ArgumentError`;
    * `{:notice, text | [text]}` — what the reader must know, in small type after a divider: how
      long a link works, not to forward it.

  Any other block raises `ArgumentError`. A block a sender needs that is not here is added to the
  package, as a minor version, rather than written around it.
  """
  @type block ::
          {:paragraph, String.t()}
          | {:rows, [{String.t(), String.t()}]}
          | {:action,
             %{
               required(:label) => String.t(),
               required(:url) => String.t(),
               optional(:hint) => String.t()
             }}
          | {:notice, String.t() | [String.t()]}

  @typedoc """
  A message's words, each plain text:

    * `:lang` — the language of its words, `"en"` when not given
    * `:brand` — the wordmark, as text, at the top of the HTML and the first line of the text
    * `:context` — optional, beside the brand in small uppercase: an installation, a department
    * `:subject` — the subject, which the HTML's title repeats
    * `:preview` — the line a mail program shows beside the subject, in the HTML part only
    * `:label` — optional, the small uppercase label above the heading, in the HTML part only
    * `:heading` — the message's heading
    * `:body` — its blocks, in order
    * `:footer` — who sent the message, and why, a line each
  """
  @type t :: %{
          optional(:lang) => String.t(),
          optional(:context) => String.t() | nil,
          optional(:label) => String.t() | nil,
          required(:brand) => String.t(),
          required(:subject) => String.t(),
          required(:preview) => String.t(),
          required(:heading) => String.t(),
          required(:body) => [block()],
          required(:footer) => [String.t()]
        }

  @t Theme.tokens()

  # The layout's stylesheet, made from the tokens when the package compiles. premailex writes each
  # rule into the elements it selects; mail programs that keep <style> also get the narrow
  # screen's. The panel's table keeps its borders separate: a collapsed border is drawn square
  # around a rounded background.
  @css """
  body { margin: 0; padding: 0; background-color: #{@t.canvas}; -webkit-text-size-adjust: 100%; }
  table { border-collapse: collapse; }
  .canvas { width: 100%; background-color: #{@t.canvas}; }
  .outer { padding: 40px 12px; }
  .container { width: 100%; max-width: 560px; border-collapse: separate; border-spacing: 0; }
  .wordmark { padding: 0 12px 20px; font-family: #{@t.sans}; font-size: 17px; font-weight: 500; letter-spacing: -0.012em; line-height: 1.3; color: #{@t.text_primary}; }
  .context { font-family: #{@t.mono}; font-size: #{@t.eyebrow_size}; font-weight: 400; letter-spacing: #{@t.eyebrow_track}; text-transform: uppercase; color: #{@t.text_tertiary}; }
  .panel { padding: 36px 32px 32px; background-color: #{@t.surface}; border: 1px solid #{@t.border}; border-radius: #{@t.radius_lg}; }
  .label { margin: 0 0 12px; font-family: #{@t.mono}; font-size: #{@t.eyebrow_size}; font-weight: 400; letter-spacing: #{@t.eyebrow_track}; line-height: 1.5; text-transform: uppercase; color: #{@t.text_tertiary}; }
  .heading { margin: 0 0 16px; font-family: #{@t.sans}; font-size: #{@t.h3_size}; font-weight: 500; letter-spacing: #{@t.h3_track}; line-height: #{@t.h3_lh}; color: #{@t.text_primary}; }
  .text { margin: 0 0 14px; font-family: #{@t.sans}; font-size: #{@t.body_size}; font-weight: 400; letter-spacing: #{@t.body_track}; line-height: #{@t.body_lh}; color: #{@t.text_secondary}; }
  .rows { padding: 4px 0 18px; }
  .row-item { padding: 10px 16px 10px 0; border-top: 1px solid #{@t.divider}; font-family: #{@t.sans}; font-size: #{@t.body_size}; font-weight: 400; letter-spacing: #{@t.body_track}; line-height: #{@t.body_lh}; color: #{@t.text_primary}; }
  .row-detail { padding: 10px 0; border-top: 1px solid #{@t.divider}; font-family: #{@t.mono}; font-size: #{@t.record_size}; line-height: #{@t.body_lh}; color: #{@t.text_secondary}; white-space: nowrap; }
  .row-last { border-bottom: 1px solid #{@t.divider}; }
  .action { padding: 10px 0 24px; }
  .button-cell { border-radius: #{@t.radius_sm}; background-color: #{@t.lime}; mso-padding-alt: 12px 22px; }
  .button { display: inline-block; padding: 12px 22px; font-family: #{@t.sans}; font-size: 15px; font-weight: 500; line-height: 1.2; color: #{@t.on_accent}; text-decoration: none; border-radius: #{@t.radius_sm}; }
  .hint { margin: 0 0 4px; font-family: #{@t.sans}; font-size: #{@t.caption_size}; line-height: #{@t.caption_lh}; color: #{@t.text_tertiary}; }
  .link { margin: 0 0 24px; font-family: #{@t.mono}; font-size: #{@t.record_size}; line-height: 1.6; word-break: break-all; }
  .link-anchor { color: #{@t.accent_ink}; text-decoration: underline; }
  .divider { padding: 0 0 20px; }
  .rule { height: 1px; line-height: 1px; font-size: 1px; background-color: #{@t.divider}; }
  .notice { margin: 0 0 8px; font-family: #{@t.sans}; font-size: #{@t.caption_size}; line-height: #{@t.caption_lh}; color: #{@t.text_secondary}; }
  .footer { padding: 20px 12px 0; }
  .footer-line { margin: 0 0 6px; font-family: #{@t.sans}; font-size: #{@t.caption_size}; line-height: #{@t.caption_lh}; color: #{@t.text_tertiary}; }
  .preview { display: none; mso-hide: all; max-height: 0; overflow: hidden; opacity: 0; font-size: 1px; line-height: 1px; color: #{@t.canvas}; }
  @media only screen and (max-width: 600px) {
    .outer { padding: 24px 8px !important; }
    .panel { padding: 28px 20px 24px !important; }
  }
  """

  # premailex reads only <style>, never a <link> it would fetch, and parses with Floki, not with
  # whichever parser is loaded: a host's LazyHTML would otherwise write the HTML out differently.
  # The package's parser writes it out escaped whatever the host configures for Floki.
  @premailex [html_parser: EhosDesign.Mail.HTMLParser, css_selector: "style"]

  @doc """
  The message's HTML part, every rule of its stylesheet written into the elements it styles, the
  narrow screen's rules kept in `<style>` too. Raises `ArgumentError` on a block it does not know.
  """
  @spec html(t()) :: String.t()
  def html(message) do
    html =
      %{message: message!(message), css: @css, t: @t}
      |> layout()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    "<!DOCTYPE html>\n" <> Premailex.to_inline_css(html, @premailex)
  end

  @doc """
  The message's plain-text part: the brand, the heading and each block, apart by a blank line,
  then the footer under `--`. The preview, the label and an action's hint are the HTML's alone.
  Raises `ArgumentError` on a block it does not know.
  """
  @spec text(t()) :: String.t()
  def text(message) do
    message = message!(message)
    brand = Enum.join([message.brand | List.wrap(message.context)], " · ")
    parts = [brand, message.heading | Enum.map(message.body, &text_block/1)]

    footer =
      case message.footer do
        [] -> ""
        lines -> "\n\n--\n" <> Enum.join(lines, "\n")
      end

    Enum.join(parts, "\n\n") <> footer <> "\n"
  end

  defp text_block({:paragraph, text}), do: text

  defp text_block({:rows, rows}),
    do: Enum.map_join(rows, "\n", fn {item, detail} -> "- #{item}: #{detail}" end)

  defp text_block({:action, action}), do: "#{action.label}:\n#{action.url}"
  defp text_block({:notice, lines}), do: Enum.join(lines, "\n")

  # The message both parts render: its language, `"en"` when not given; a context or label that is
  # nil or empty as none; and its blocks checked.
  defp message!(message) do
    Map.merge(message, %{
      lang: Map.get(message, :lang) || "en",
      context: present(Map.get(message, :context)),
      label: present(Map.get(message, :label)),
      body: blocks!(message.body)
    })
  end

  defp present(""), do: nil
  defp present(value), do: value

  # Every block in the shape `t:block/0` gives it, a notice's text as a list of lines; anything
  # else raises, in both parts alike.
  defp blocks!(blocks) when is_list(blocks), do: Enum.map(blocks, &block!/1)

  defp block!({:paragraph, text} = block) when is_binary(text), do: block

  defp block!({:rows, rows} = block) when is_list(rows) do
    if Enum.all?(rows, &match?({item, detail} when is_binary(item) and is_binary(detail), &1)),
      do: block,
      else: unknown!(block)
  end

  defp block!({:action, %{label: label, url: url} = action} = block)
       when is_binary(label) and is_binary(url) do
    cond do
      not link?(url) ->
        raise ArgumentError,
              "EhosDesign.Mail leads an action only to an absolute http, https or mailto link, " <>
                "not #{inspect(url)}"

      is_binary(Map.get(action, :hint)) ->
        block

      Map.get(action, :hint) == nil ->
        {:action, Map.put(action, :hint, nil)}

      true ->
        unknown!(block)
    end
  end

  defp block!({:notice, text}) when is_binary(text), do: {:notice, [text]}

  defp block!({:notice, lines} = block) when is_list(lines) do
    if Enum.all?(lines, &is_binary/1), do: block, else: unknown!(block)
  end

  defp block!(block), do: unknown!(block)

  # What a button may lead to: a page on a host, or an address. The HTML is sent as written (eh-os
  # D-140, amended by #1023), so a `javascript:` or `data:` link would reach the reader's mail
  # program as it is.
  defp link?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      {:ok, %URI{scheme: "mailto", path: path}} ->
        is_binary(path) and path != ""

      _other ->
        false
    end
  end

  defp unknown!(block) do
    raise ArgumentError,
          "EhosDesign.Mail does not know the block #{inspect(block, limit: 5)}: " <>
            "a block is {:paragraph, text}, {:rows, [{item, detail}]}, " <>
            "{:action, %{label: label, url: url}} or {:notice, text | [text]}"
  end

  # Tables, `bgcolor` beside `background-color`, and Outlook's own fixed width, since Outlook for
  # Windows lays out with Word's engine and ignores `max-width`.
  defp layout(assigns) do
    ~H"""
    <html lang={@message.lang} xmlns="http://www.w3.org/1999/xhtml">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="x-apple-disable-message-reformatting" />
        <meta name="color-scheme" content="light" />
        <meta name="supported-color-schemes" content="light" />
        <title>{@message.subject}</title>
        <%!-- The tokens are the design system's, read when the package compiled: no sender's words. --%>
        <style>
          <%= Phoenix.HTML.raw(@css) %>
        </style>
      </head>
      <body>
        <div class="preview">{@message.preview}</div>
        <table
          class="canvas"
          role="presentation"
          width="100%"
          cellpadding="0"
          cellspacing="0"
          border="0"
          bgcolor={@t.canvas}
        >
          <tr>
            <td class="outer" align="center">
              <!--[if mso]><table role="presentation" width="560" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
              <table class="container" role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <%!-- The brand as text: the marks are not in this package. --%>
                  <td class="wordmark">
                    {@message.brand}
                    <%= if @message.context do %>
                      &nbsp;&nbsp;<span class="context">{@message.context}</span>
                    <% end %>
                  </td>
                </tr>
                <tr>
                  <td class="panel" bgcolor={@t.surface}>
                    <p :if={@message.label} class="label">{@message.label}</p>
                    <h1 class="heading">{@message.heading}</h1>
                    <.block :for={block <- @message.body} block={block} t={@t} />
                  </td>
                </tr>
                <tr :if={@message.footer != []}>
                  <td class="footer">
                    <p :for={line <- @message.footer} class="footer-line">{line}</p>
                  </td>
                </tr>
              </table>
              <!--[if mso]></td></tr></table><![endif]-->
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  defp block(%{block: {:paragraph, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <p class="text">{@text}</p>
    """
  end

  defp block(%{block: {:rows, rows}} = assigns) do
    assigns = assign(assigns, rows: rows, last: length(rows) - 1)

    ~H"""
    <table
      :if={@rows != []}
      role="presentation"
      width="100%"
      cellpadding="0"
      cellspacing="0"
      border="0"
    >
      <tr>
        <td class="rows">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
            <tr :for={{{item, detail}, index} <- Enum.with_index(@rows)}>
              <td class={["row-item", index == @last && "row-last"]}>{item}</td>
              <td class={["row-detail", index == @last && "row-last"]} align="right">{detail}</td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
    """
  end

  defp block(%{block: {:action, action}} = assigns) do
    assigns = assign(assigns, :action, action)

    ~H"""
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
      <tr>
        <td class="action">
          <table role="presentation" cellpadding="0" cellspacing="0" border="0">
            <tr>
              <td class="button-cell" bgcolor={@t.lime}>
                <a class="button" href={@action.url} target="_blank">{@action.label}</a>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
    <p :if={@action.hint} class="hint">{@action.hint}</p>
    <p class="link">
      <a class="link-anchor" href={@action.url} target="_blank">{@action.url}</a>
    </p>
    """
  end

  defp block(%{block: {:notice, lines}} = assigns) do
    assigns = assign(assigns, :lines, lines)

    ~H"""
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
      <tr>
        <td class="divider">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
            <tr>
              <td class="rule" bgcolor={@t.divider}>&nbsp;</td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
    <p :for={line <- @lines} class="notice">{line}</p>
    """
  end
end

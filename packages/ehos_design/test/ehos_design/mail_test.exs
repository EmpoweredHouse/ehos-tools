defmodule EhosDesign.MailTest do
  # eh-os D-122: the layout every mailed message is rendered in, as HTML and as plain text from the
  # same blocks. The text part is compared whole; the HTML is read back with LazyHTML, and each
  # test compares the elements it is about. Async, Floki's setting included: CONTRIBUTING counts
  # it as configuration a library reads the same way everywhere, and no other test writes HTML
  # out through Floki's default, since the mail's parser asks for escaping itself.
  use ExUnit.Case, async: true

  alias EhosDesign.Mail
  alias EhosDesign.Mail.Theme

  doctest EhosDesign.Mail

  @url "https://console.example.test/people/log-in/SFMyNTY.abc-def_123?a=1&b=2"
  @footer "\n\n--\nSent by EHOS for office, https://console.example.test.\n"
  # An attribute that links or fetches, with its value as written: `href`, `src`, `srcset`,
  # `background`, `poster`, `action`, namespaced (`xlink:href`) or not.
  @fetching ~r/[\s"'\/](?:[a-z]+:)?(href|src|srcset|background|poster|action)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i
  @blocks "a block is {:paragraph, text}, {:rows, [{item, detail}]}, " <>
            "{:action, %{label: label, url: url}} or {:notice, text | [text]}"
  @rows "needs a :rows block's rows, a list of {item, detail} strings, not empty"
  @notice "needs a :notice block's text, a string or a list of strings, not empty"

  test "both parts carry every line and the link, and the text part leaves out the HTML's extras" do
    html = parse(Mail.html(message()))

    assert Mail.text(message()) ==
             "EHOS · office\n\nSign in to office\n\nSomeone asked to sign in.\n\n" <>
               "If it was you, use the button below.\n\nSign in:\n#{@url}\n\n" <>
               "This link works once, within 15 minutes.\nDo not forward it." <> @footer

    assert texts(html, "title") == ["Your sign-in link for office"]
    assert texts(html, ".preview") == ["It works once, within 15 minutes."]
    assert texts(html, ".wordmark") == ["EHOS\u00A0\u00A0office"]
    assert texts(html, ".label") == ["Sign-in link"]
    assert texts(html, "h1.heading") == ["Sign in to office"]

    assert texts(html, "p.text") ==
             ["Someone asked to sign in.", "If it was you, use the button below."]

    assert texts(html, "a.button") == ["Sign in"]
    assert texts(html, ".hint") == ["If the button does not work, open this link:"]
    assert texts(html, "a.link-anchor") == [@url]

    assert texts(html, ".notice") ==
             ["This link works once, within 15 minutes.", "Do not forward it."]

    assert texts(html, ".footer-line") == [
             "Sent by EHOS for office, https://console.example.test."
           ]

    assert attribute(html, "a", "href") == [@url, @url]
  end

  # EHOS's layout set its name and the installation two non-breaking spaces apart; whitespace
  # beside them would show as one more space.
  test "the brand and its context are two non-breaking spaces apart, and nothing else" do
    assert texts(parse(Mail.html(message())), "td.wordmark") == ["EHOS\u00A0\u00A0office"]
    assert texts(parse(Mail.html(Map.delete(message(), :context))), "td.wordmark") == ["EHOS"]
    assert attribute(parse(Mail.html(message())), "[phx-no-format]", "phx-no-format") == []
  end

  test "rows show each item with its detail, in both parts" do
    rows = [{"Bank statements", "by 10.11.2026"}, {"Cost invoices", "by 12.11.2026"}]
    message = message(%{body: [{:paragraph, "Please send us:"}, {:rows, rows}]})
    html = parse(Mail.html(message))

    assert Mail.text(message) ==
             "EHOS · office\n\nSign in to office\n\nPlease send us:\n\n" <>
               "- Bank statements: by 10.11.2026\n- Cost invoices: by 12.11.2026" <> @footer

    assert texts(html, "td.row-item") == ["Bank statements", "Cost invoices"]
    assert texts(html, "td.row-detail") == ["by 10.11.2026", "by 12.11.2026"]
    # The last row closes the list with a hairline under it.
    assert texts(html, "td.row-last") == ["Cost invoices", "by 12.11.2026"]
  end

  test "a message without an action has no button and no link, and optional parts may be left out" do
    message =
      message(%{body: [{:paragraph, "Nothing to open."}], footer: []})
      |> Map.drop([:context, :label, :lang])

    html = parse(Mail.html(message))

    assert Mail.text(message) == "EHOS\n\nSign in to office\n\nNothing to open.\n"
    assert count(html, "a, .button, .label, .context, .footer") == 0
    assert attribute(html, "html", "lang") == ["en"]
  end

  test "a notice may be one line, and an action needs no hint" do
    message =
      message(%{
        body: [
          {:action, %{label: "Open", url: "https://a.example.test/"}},
          {:notice, "One line."}
        ]
      })

    html = parse(Mail.html(message))

    assert Mail.text(message) ==
             "EHOS · office\n\nSign in to office\n\nOpen:\nhttps://a.example.test/\n\nOne line." <>
               @footer

    assert texts(html, ".hint") == []
    assert texts(html, ".notice") == ["One line."]
  end

  test "a hint given as nil, and a context or label given empty, are none" do
    message =
      message(%{
        context: "",
        label: "",
        body: [
          {:action, %{label: "Open", url: @url, hint: nil}},
          {:action, %{label: "Go", url: @url, hint: ""}}
        ]
      })

    html = parse(Mail.html(message))

    assert Mail.text(message) ==
             "EHOS\n\nSign in to office\n\nOpen:\n#{@url}\n\nGo:\n#{@url}" <> @footer

    assert count(html, ".hint, .context, .label") == 0
  end

  test "an action leads to an absolute http, https or mailto link" do
    for url <- [
          "https://a.example.test/x?y=1",
          "http://a.example.test",
          "mailto:office@example.test"
        ] do
      html = parse(Mail.html(message(%{body: [{:action, %{label: "Open", url: url}}]})))

      assert attribute(html, "a", "href") == [url, url]
    end
  end

  # Read in the HTML as written, not as parsed: a parser reads Outlook's conditional comments as
  # comments, and Outlook renders what is in them, written as the template wrote it, in any case
  # and with any quoting. Every attribute that links or fetches is listed with its value.
  test "the HTML links nowhere but the action's link, and fetches nothing when it is opened" do
    html = Mail.html(message())
    escaped = @url |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    assert Regex.scan(@fetching, html, capture: :all_but_first) == [
             ["href", ~s("#{escaped}")],
             ["href", ~s("#{escaped}")]
           ]

    refute html =~ ~r/<(img|link|script|iframe|object|embed|v:)\b/i
    refute html =~ ~r/url\(|image-set\(|@import|http-equiv/i
  end

  test "the HTML is styled with the light theme's tokens, inline, and no custom property" do
    html = Mail.html(message(%{lang: "pl"}))
    document = parse(html)
    t = Theme.tokens()

    assert attribute(document, "[bgcolor]", "bgcolor") == [t.canvas, t.surface, t.lime, t.divider]

    assert attribute(document, "td.panel", "style") == [
             "background-color: #{t.surface}; border: 1px solid #{t.border}; " <>
               "border-radius: #{t.radius_lg}; padding: 36px 32px 32px;"
           ]

    assert attribute(document, "td.button-cell", "style") == [
             "background-color: #{t.lime}; border-radius: #{t.radius_sm}; " <>
               "mso-padding-alt: 12px 22px;"
           ]

    assert attribute(document, "a.button", "style") == [
             "border-radius: #{t.radius_sm}; color: #{t.on_accent}; display: inline-block; " <>
               "font-family: #{t.sans}; font-size: 15px; font-weight: 500; line-height: 1.2; " <>
               "padding: 12px 22px; text-decoration: none;"
           ]

    assert attribute(document, "p.text", "style") ==
             List.duplicate(
               "color: #{t.text_secondary}; font-family: #{t.sans}; font-size: #{t.body_size}; " <>
                 "font-weight: 400; letter-spacing: #{t.body_track}; line-height: #{t.body_lh}; " <>
                 "margin: 0 0 14px;",
               2
             )

    assert attribute(document, "h1.heading", "style") == [
             "color: #{t.text_primary}; font-family: #{t.sans}; font-size: #{t.h3_size}; " <>
               "font-weight: 500; letter-spacing: #{t.h3_track}; line-height: #{t.h3_lh}; " <>
               "margin: 0 0 16px;"
           ]

    assert attribute(document, "td.rule", "style") == [
             "background-color: #{t.divider}; font-size: 1px; height: 1px; line-height: 1px;"
           ]

    refute html =~ "var(--"
    assert attribute(document, "html", "lang") == ["pl"]
  end

  test "a value with markup in it is shown as text" do
    html =
      parse(
        Mail.html(
          message(%{
            lang: ~s[en" onload="x()],
            brand: ~s(<i>Office</i>),
            context: ~s(<b>"x"</b>),
            subject: "</title><script>alert(1)</script>",
            preview: "<img src=x>",
            label: "<u>Label</u>",
            heading: "<h2>Heading</h2>",
            body: [
              {:paragraph, "<script>alert(1)</script> invited you."},
              {:rows, [{"<u>item</u>", "<s>detail</s>"}]},
              {:action,
               %{
                 label: "<em>Open</em>",
                 url: "https://example.test/?a=1&b=2",
                 hint: "<b>Hint</b>"
               }},
              {:notice, "<marquee>"}
            ],
            footer: ["<hr>"]
          })
        )
      )

    assert count(html, "script, b, i, u, s, em, img, marquee, hr, h2") == 0
    assert texts(html, "title") == ["</title><script>alert(1)</script>"]
    assert texts(html, ".preview") == ["<img src=x>"]
    assert texts(html, ".label") == ["<u>Label</u>"]
    assert texts(html, "h1.heading") == ["<h2>Heading</h2>"]
    assert texts(html, ".wordmark") == [~s(<i>Office</i>\u00A0\u00A0<b>"x"</b>)]
    assert texts(html, "p.text") == ["<script>alert(1)</script> invited you."]
    assert texts(html, "td.row-item") == ["<u>item</u>"]
    assert texts(html, "td.row-detail") == ["<s>detail</s>"]
    assert texts(html, "a.button") == ["<em>Open</em>"]
    assert texts(html, ".notice") == ["<marquee>"]
    assert texts(html, ".footer-line") == ["<hr>"]
    assert texts(html, ".hint") == ["<b>Hint</b>"]
    assert attribute(html, "html", "lang") == [~s[en" onload="x()]]
    assert attribute(html, "[onload]", "onload") == []
    assert attribute(html, "a", "href") == List.duplicate("https://example.test/?a=1&b=2", 2)
  end

  test "a value with markup is shown as text whatever the host configures for Floki" do
    mock_floki_encode_raw_html(false)
    paragraph = ~s[<script>x()</script><img src="https://track.example.test/p">]
    subject = "</title><script>y()</script>"
    html = parse(Mail.html(message(%{subject: subject, body: [{:paragraph, paragraph}]})))

    assert count(html, "script, img") == 0
    assert texts(html, "title") == [subject]
    assert texts(html, "p.text") == [paragraph]
  end

  test "the stylesheet is written into each element, and the narrow screen's rules stay in the head" do
    html = Mail.html(message())
    document = parse(html)

    assert String.slice(html, 0, 16) == "<!DOCTYPE html>\n"
    # A collapsed border is drawn square around the panel's rounded background.
    assert attribute(document, "table.container", "style") ==
             ["border-collapse: separate; border-spacing: 0; max-width: 560px; width: 100%;"]

    assert [style] = texts(document, "head style")
    assert style =~ ~r/@media only screen and \(max-width: 600px\) \{\n\s*\.outer \{/
  end

  # premailex keeps a comment only when it starts exactly so; without them Outlook for Windows,
  # which ignores max-width, stretches the panel across the window.
  test "Outlook's fixed width survives premailex" do
    html = Mail.html(message())
    t = Theme.tokens()

    assert html =~ ~s(<!--[if mso]><table role="presentation" width="560")
    assert html =~ "<!--[if mso]></td></tr></table><![endif]-->"

    assert attribute(parse(html), "div.preview", "style") == [
             "color: #{t.canvas}; display: none; font-size: 1px; line-height: 1px; " <>
               "max-height: 0; mso-hide: all; opacity: 0; overflow: hidden;"
           ]
  end

  # Gmail clips a message past about 102 KB, hiding its end behind a link; inline styles repeat on
  # every row, so a long list is what would reach it first.
  test "a message with thirty rows stays well under Gmail's clipping" do
    rows = for i <- 1..30, do: {"Document number #{i} for the month", "by 10.11.2026"}
    message = message(%{body: [{:paragraph, "Please send us:"}, {:rows, rows} | message().body]})

    assert byte_size(Mail.html(message)) < 60_000
  end

  test "a block it does not know raises, in both parts, naming its kind and key but no value" do
    for {block, error} <- [
          {{:table, [["a", "b"]]}, "does not know a :table block: #{@blocks}"},
          {@url, "does not know a block that is not {kind, content}: #{@blocks}"},
          {{:paragraph, :not_text}, "needs a :paragraph block's text, a string"},
          {{:rows, [{"item"}]}, @rows},
          {{:rows, []}, @rows},
          {{:action, @url}, "needs an :action block's map, of :label, :url and :hint"},
          {{:action, %{url: @url}}, "needs an :action block's :label, a string"},
          {{:action, %{label: "Open"}}, "needs an :action block's :url, a string"},
          {{:action, %{label: "Open", url: @url, hint: 1}},
           "needs an :action block's :hint, a string or nil"},
          {{:notice, ["a", nil]}, @notice},
          {{:notice, []}, @notice}
        ] do
      message = message(%{body: [block]})

      assert_raise ArgumentError, "EhosDesign.Mail " <> error, fn -> Mail.html(message) end
      assert_raise ArgumentError, "EhosDesign.Mail " <> error, fn -> Mail.text(message) end
    end
  end

  test "an action leading anywhere but an absolute http, https or mailto link raises, naming no more than its scheme" do
    for {url, what} <- [
          {"javascript:alert(1)", "a javascript: link"},
          {"JavaScript:alert(1)", "a javascript: link"},
          {"data:text/html,x", "a data: link"},
          {"data:text/html,<b>x</b>", "a link that is not a valid URI"},
          {"vbscript:x", "a vbscript: link"},
          {"file:///etc/passwd", "a file: link"},
          {"example.test:4000/log-in/SFMyNTY.abc", "a link of another scheme"},
          {"office:SFMyNTY.abc@example.test", "a link of another scheme"},
          {"/relative/path", "a link without a scheme"},
          {"https://", "a https: link without a host"},
          {"mailto:", "a mailto: link without an address"},
          {"https://exa mple.test/log-in/SFMyNTY.abc", "a link that is not a valid URI"},
          {<<"https://a.example.test", 0xFF, "/log-in/SFMyNTY.abc">>,
           "a link that is not a valid URI"}
        ] do
      message = message(%{body: [{:action, %{label: "Open", url: url}}]})

      error =
        "EhosDesign.Mail leads an action only to an absolute http, https or mailto link, " <>
          "not #{what}"

      assert_raise ArgumentError, error, fn -> Mail.html(message) end
      assert_raise ArgumentError, error, fn -> Mail.text(message) end
    end
  end

  test "a message without its words or its blocks raises" do
    for {key, value, error} <- [
          {:brand, nil, "EhosDesign.Mail needs :brand, a string"},
          {:heading, "", "EhosDesign.Mail needs :heading, a string"},
          {:subject, 1, "EhosDesign.Mail needs :subject, a string"},
          {:preview, nil, "EhosDesign.Mail needs :preview, a string"},
          {:body, [], "EhosDesign.Mail needs :body, a list of blocks"},
          {:body, nil, "EhosDesign.Mail needs :body, a list of blocks"},
          {:footer, nil, "EhosDesign.Mail needs :footer, a list of lines, [] for none"},
          {:footer, [nil], "EhosDesign.Mail needs :footer, a list of lines, [] for none"},
          {:context, ["a"], "EhosDesign.Mail needs :context, a string or nil"},
          {:label, 5, "EhosDesign.Mail needs :label, a string or nil"},
          {:lang, :pl, "EhosDesign.Mail needs :lang, a string or nil"}
        ] do
      message = Map.put(message(), key, value)

      assert_raise ArgumentError, error, fn -> Mail.html(message) end
      assert_raise ArgumentError, error, fn -> Mail.text(message) end
    end
  end

  defp message(overrides \\ %{}) do
    Map.merge(
      %{
        brand: "EHOS",
        context: "office",
        subject: "Your sign-in link for office",
        preview: "It works once, within 15 minutes.",
        label: "Sign-in link",
        heading: "Sign in to office",
        body: [
          {:paragraph, "Someone asked to sign in."},
          {:paragraph, "If it was you, use the button below."},
          {:action,
           %{label: "Sign in", url: @url, hint: "If the button does not work, open this link:"}},
          {:notice, ["This link works once, within 15 minutes.", "Do not forward it."]}
        ],
        footer: ["Sent by EHOS for office, https://console.example.test."]
      },
      overrides
    )
  end

  # A host that tells Floki not to escape what it writes out, for this test alone.
  defp mock_floki_encode_raw_html(value) do
    previous = Application.fetch_env(:floki, :encode_raw_html)
    Application.put_env(:floki, :encode_raw_html, value)
    on_exit(fn -> restore_floki(previous) end)
  end

  defp restore_floki({:ok, value}), do: Application.put_env(:floki, :encode_raw_html, value)
  defp restore_floki(:error), do: Application.delete_env(:floki, :encode_raw_html)

  defp parse(html), do: LazyHTML.from_document(html)

  # The text of each element `selector` finds, as written, whitespace included.
  defp texts(html, selector), do: html |> LazyHTML.query(selector) |> Enum.map(&LazyHTML.text/1)

  defp attribute(html, selector, name),
    do: html |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  defp count(html, selector), do: html |> LazyHTML.query(selector) |> Enum.count()
end

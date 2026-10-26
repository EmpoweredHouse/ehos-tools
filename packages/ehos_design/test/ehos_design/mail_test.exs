defmodule EhosDesign.MailTest do
  # eh-os D-122: the layout every mailed message is rendered in, as HTML and as plain text from the
  # same blocks.
  use ExUnit.Case, async: true

  alias EhosDesign.Mail
  alias EhosDesign.Mail.Theme

  doctest EhosDesign.Mail

  @url "https://console.example.test/people/log-in/SFMyNTY.abc-def_123?a=1&b=2"

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

  # The values of every `attr="…"` in `html`.
  defp attribute(html, name) do
    ~r/\s#{name}="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  defp escaped(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  test "both parts carry every line and the link, and the text part leaves out the HTML's extras" do
    message = message()
    html = Mail.html(message)
    text = Mail.text(message)

    assert html =~ ~s(href="#{escaped(@url)}")
    assert text =~ "Sign in:\n#{@url}\n"
    assert text =~ ~r/\AEHOS · office\n\nSign in to office\n\n/
    assert text =~ ~r/\n\n--\nSent by EHOS for office, https:\/\/console\.example\.test\.\n\z/

    lines =
      ["Someone asked to sign in.", "If it was you, use the button below.", "Sign in"] ++
        ["This link works once, within 15 minutes.", "Do not forward it."] ++ message.footer

    for line <- [message.brand, message.context, message.heading | lines] do
      assert text =~ line
      assert html =~ escaped(line)
    end

    # The preview, the label and the hint above the written-out link are the HTML's alone.
    for line <- [message.preview, message.label, "If the button does not work, open this link:"] do
      assert html =~ line
      refute text =~ line
    end
  end

  test "rows show each item with its detail, in both parts" do
    rows = [{"Bank statements", "by 10.11.2026"}, {"Cost invoices", "by 12.11.2026"}]
    message = message(%{body: [{:paragraph, "Please send us:"}, {:rows, rows}]})
    html = Mail.html(message)

    assert Mail.text(message) =~
             "Please send us:\n\n- Bank statements: by 10.11.2026\n- Cost invoices: by 12.11.2026\n"

    assert [_, _] = Regex.scan(~r/<td[^>]*class="row-item[^"]*"[^>]*>/, html)
    assert html =~ ~r/class="row-item\s*"[^>]*>Bank statements</
    assert html =~ ~r/class="row-detail\s*"[^>]*>by 10\.11\.2026</
    # The last row closes the list with a hairline under it.
    assert html =~ ~r/class="row-item row-last"[^>]*>Cost invoices</
  end

  test "a message without an action has no button and no link, and optional parts may be left out" do
    message =
      message(%{body: [{:paragraph, "Nothing to open."}], footer: []})
      |> Map.drop([:context, :label, :lang])

    html = Mail.html(message)
    text = Mail.text(message)

    refute html =~ ~s(class="button")
    refute html =~ "href="
    refute html =~ ~s(class="label")
    refute html =~ ~s(class="context")
    refute html =~ ~s(class="footer")
    assert html =~ ~s(lang="en")
    assert text == "EHOS\n\nSign in to office\n\nNothing to open.\n"
  end

  test "a notice may be one line, and an action needs no hint" do
    message =
      message(%{
        body: [
          {:action, %{label: "Open", url: "https://a.example.test/"}},
          {:notice, "One line."}
        ]
      })

    html = Mail.html(message)

    refute html =~ ~s(class="hint")
    assert html =~ ~r/class="notice"[^>]*>One line\.</
    assert Mail.text(message) =~ "Open:\nhttps://a.example.test/\n\nOne line.\n"
  end

  test "a block it does not know raises, in both parts" do
    for block <- [
          {:table, [["a", "b"]]},
          {:paragraph, :not_text},
          {:rows, [{"item"}]},
          {:action, %{label: "Open"}},
          {:action, %{label: "Open", url: "https://a.example.test/", hint: 1}},
          {:notice, ["a", nil]}
        ] do
      message = message(%{body: [block]})
      assert_raise ArgumentError, ~r/does not know the block/, fn -> Mail.html(message) end
      assert_raise ArgumentError, ~r/does not know the block/, fn -> Mail.text(message) end
    end
  end

  test "an action leads only to an absolute http, https or mailto link" do
    for url <- [
          "javascript:alert(1)",
          "JavaScript:alert(1)",
          "data:text/html,<b>x</b>",
          "vbscript:x",
          "file:///etc/passwd",
          "/relative/path",
          "https://",
          "mailto:",
          "https://exa mple.test/"
        ] do
      message = message(%{body: [{:action, %{label: "Open", url: url}}]})

      assert_raise ArgumentError, ~r/only to an absolute http, https or mailto link/, fn ->
        Mail.html(message)
      end

      assert_raise ArgumentError, ~r/only to an absolute http, https or mailto link/, fn ->
        Mail.text(message)
      end
    end

    for url <- [
          "https://a.example.test/x?y=1",
          "http://a.example.test",
          "mailto:office@example.test"
        ] do
      assert Mail.html(message(%{body: [{:action, %{label: "Open", url: url}}]})) =~ "Open"
    end
  end

  test "a hint given as nil, and a context or label given empty, are none" do
    message =
      message(%{
        context: "",
        label: "",
        body: [{:action, %{label: "Open", url: @url, hint: nil}}]
      })

    html = Mail.html(message)

    refute html =~ ~s(class="hint")
    refute html =~ ~s(class="context")
    refute html =~ ~s(class="label")
    refute html =~ "&nbsp;"
    assert Mail.text(message) =~ ~r/\AEHOS\n\n/
  end

  test "the HTML links nowhere but the action's link, and fetches nothing when it is opened" do
    html = Mail.html(message())

    assert attribute(html, "href") |> Enum.uniq() == [escaped(@url)]
    assert attribute(html, "src") == []
    refute html =~ ~r/<(img|link|script|iframe|object)\b/i
    refute html =~ ~r/url\(/i
    refute html =~ ~r/@import/i
  end

  test "the HTML is styled with the light theme's tokens, inline, and no custom property" do
    html = Mail.html(message(%{lang: "pl", body: message().body ++ [{:rows, [{"a", "b"}]}]}))
    tokens = Theme.tokens()

    for key <- [
          :canvas,
          :surface,
          :border,
          :divider,
          :text_primary,
          :text_secondary,
          :lime,
          :on_accent
        ] do
      assert html =~ tokens[key], "the HTML does not use #{key}, #{tokens[key]}"
    end

    refute html =~ "var(--"
    assert html =~ ~s(lang="pl")
  end

  test "a value with markup in it is shown as text" do
    html =
      Mail.html(
        message(%{
          brand: ~s(<i>Office</i>),
          context: ~s(<b>"x"</b>),
          body: [
            {:paragraph, "<script>alert(1)</script> invited you."},
            {:rows, [{"<u>item</u>", "<s>detail</s>"}]},
            {:action, %{label: "<em>Open</em>", url: "https://example.test/?a=1&b=2"}},
            {:notice, "<marquee>"}
          ],
          footer: ["<hr>"]
        })
      )

    for tag <- ~w(script b i u s em img marquee hr) do
      refute html =~ ~r/<#{tag}\b/, tag
    end

    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt; invited you."
    assert html =~ "&lt;b&gt;&quot;x&quot;&lt;/b&gt;"
    assert html =~ "&lt;u&gt;item&lt;/u&gt;"
  end

  test "the stylesheet is written into each element, and the narrow screen's rules stay in the head" do
    html = Mail.html(message())
    tokens = Theme.tokens()
    [button] = Regex.run(~r/<a[^>]*class="button"[^>]*>/, html)

    assert button =~ ~s(style=")

    assert html =~
             ~r/<td[^>]*class="button-cell"[^>]*bgcolor="#{tokens.lime}"[^>]*style="[^"]*background-color: #{tokens.lime}/

    assert button =~ "color: #{tokens.on_accent}"
    assert html =~ ~r/<td[^>]*class="panel"[^>]*style="[^"]*border: 1px solid #{tokens.border}/
    assert html =~ ~r/<style[^>]*>.*@media only screen and \(max-width: 600px\)/s
    assert html =~ ~r/^<!DOCTYPE html>/

    # A collapsed border is drawn square around the panel's rounded background.
    assert html =~ ~r/<table[^>]*class="container"[^>]*style="[^"]*border-collapse: separate/
  end

  # premailex keeps a comment only when it starts exactly so; without them Outlook for Windows,
  # which ignores max-width, stretches the panel across the window.
  test "Outlook's fixed width survives premailex" do
    html = Mail.html(message())

    assert html =~ ~s(<!--[if mso]><table role="presentation" width="560")
    assert html =~ "<!--[if mso]></td></tr></table><![endif]-->"
    assert html =~ ~r/<div[^>]*class="preview"[^>]*style="[^"]*mso-hide: all/
  end

  # Gmail clips a message past about 102 KB, hiding its end behind a link; inline styles repeat on
  # every row, so a long list is what would reach it first.
  test "a message with thirty rows stays well under Gmail's clipping" do
    rows = for i <- 1..30, do: {"Document number #{i} for the month", "by 10.11.2026"}
    message = message(%{body: [{:paragraph, "Please send us:"}, {:rows, rows} | message().body]})

    assert byte_size(Mail.html(message)) < 60_000
  end
end

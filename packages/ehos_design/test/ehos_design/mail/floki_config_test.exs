defmodule EhosDesign.Mail.FlokiConfigTest do
  # A host may tell Floki not to escape what it writes out; the mail's values stay text anyway.
  # Not async: the setting is the whole VM's.
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:floki, :encode_raw_html)
    Application.put_env(:floki, :encode_raw_html, false)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:floki, :encode_raw_html),
        else: Application.put_env(:floki, :encode_raw_html, previous)
    end)
  end

  test "a value with markup is shown as text whatever the host configures for Floki" do
    html =
      EhosDesign.Mail.html(%{
        brand: "Office",
        subject: "s",
        preview: "p",
        heading: "h",
        body: [{:paragraph, ~s[<script>x()</script><img src="https://track.example.test/p">]}],
        footer: []
      })

    refute html =~ "<script"
    refute html =~ "<img"
    assert html =~ "&lt;script&gt;x()&lt;/script&gt;"
  end
end

defmodule EhosDesign.Mail.HTMLParser do
  @moduledoc false
  # premailex's Floki parser, but writing the HTML out with its text escaped whatever the host
  # configures: Floki's own `raw_html/1` follows `config :floki, :encode_raw_html`, and with it
  # `false` every value a sender gave would come back as markup.

  @behaviour Premailex.HTMLParser

  @impl true
  defdelegate parse(html), to: Premailex.HTMLParser.Floki

  @impl true
  def to_html(tree), do: Floki.raw_html(tree, encode: true)
end

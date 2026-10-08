defmodule EhosDesign.Browser.Endpoint do
  @moduledoc """
  The browser test's server: one page, its stylesheets taken from `priv/css` as they ship, and
  its script as esbuild bundles it into `_build/test/browser`.
  """

  use Phoenix.Endpoint, otp_app: :ehos_design

  @session_options [
    store: :cookie,
    key: "_ehos_design_browser",
    signing_salt: "browser-test",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/css", from: {:ehos_design, "priv/css"}
  plug Plug.Static, at: "/js", from: Path.join(Mix.Project.build_path(), "browser")
  plug Plug.Session, @session_options
  plug EhosDesign.Browser.Router
end

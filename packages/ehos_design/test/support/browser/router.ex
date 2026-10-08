defmodule EhosDesign.Browser.Router do
  @moduledoc "The browser test's one route."

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {EhosDesign.Browser.Layout, :root}
    plug :protect_from_forgery
  end

  scope "/" do
    pipe_through :browser
    live "/", EhosDesign.Browser.FormLive
  end
end

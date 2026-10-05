defmodule TestWeb.SignInComponents do
  @moduledoc """
  The way in and out of the application's pages. People sign in through EHOS, at the
  routes `EhOsContract.Auth.SignIn.Router` serves under `/auth/ehos`, and EHOS returns a
  sign-out to the application's root.
  """
  use TestWeb, :html

  alias EhOsContract.Auth.Session

  @doc """
  A sign-in link for a visitor, and a sign-out button for a browser that holds a session.
  Signing out is a `POST` behind CSRF protection.
  """
  attr(:conn, Plug.Conn, required: true)

  def sign_in_or_out(assigns) do
    assigns =
      assign(
        assigns,
        :signed_in?,
        Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil
      )

    ~H"""
    <div id="sign-in-or-out" class="fixed top-4 right-4 z-10">
      <.form :if={@signed_in?} id="sign-out" for={%{}} action="/auth/ehos/sign-out" method="post">
        <button type="submit" class="btn btn-sm">Sign out</button>
      </.form>
      <.link :if={!@signed_in?} id="sign-in" href="/auth/ehos/sign-in" class="btn btn-sm btn-primary">
        Sign in
      </.link>
    </div>
    """
  end
end

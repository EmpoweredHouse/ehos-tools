defmodule Ehosctl.Logout do
  @moduledoc """
  `ehosctl logout`: ends the sign-in to the installation (eh-os D-89).

  It revokes the refresh token at EHOS (RFC 7009), then forgets the sign-in on this machine
  (`Ehosctl.Credentials.forget/2`), under the sign-in's lock (T-08). When EHOS cannot be told, the
  sign-in is forgotten all the same, and the command says so: it then ends at EHOS by its own
  limits. It does not sign the browser out of EHOS, which is a sign-in of its own.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Credentials
  alias Ehosctl.Failure
  alias Ehosctl.Output
  alias Ehosctl.SignIn
  alias Ehosctl.SystemKeychain
  alias Ehosctl.TokenStore

  @impl Ehosctl.Command
  def name, do: :logout

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :sign_in

  @impl Ehosctl.Command
  def summary, do: "Sign out of an installation."

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Sign out of an installation. EHOS ends the sign-in, and ehosctl removes it from " <>
          "this computer.",
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], _parsed, opts) do
    {name, installation} = Keyword.fetch!(opts, :installation)
    url = installation["url"]

    # Whatever is kept under the name is forgotten, a sign-in to an address the installation no
    # longer has included; only EHOS at the installation's address is told.
    case TokenStore.read(Credentials.state_dir(opts), name) do
      :none when not is_map_key(installation, "sign_in") ->
        {:ok,
         %{
           text: Output.outcome(:unchanged, "You are not signed in to #{name}."),
           json: %{installation: name, signed_out: false, revoked: false}
         }}

      _signed_in ->
        TokenStore.with_lock(Credentials.state_dir(opts), name, fn ->
          sign_out(name, url, opts)
        end)
    end
  end

  defp sign_out(name, url, opts) do
    revoked = revoke(name, url, opts)

    with :ok <- Credentials.forget(name, opts) do
      {:ok, result(name, url, revoked)}
    end
  end

  # Whether EHOS was told: `:ok`, or why not.
  defp revoke(name, url, opts) do
    key = %{dir: Credentials.state_dir(opts), name: name, url: url}

    with {:ok, session} <- Credentials.session(name, url, opts),
         {:ok, backend} <- TokenStore.backend(session.store, SystemKeychain.current().backend()),
         {:ok, token} <- backend.get(key),
         {:ok, _endpoints} <-
           Credentials.at_endpoints(
             session,
             url,
             opts,
             :revocation,
             &SignIn.current().revoke(&1, token)
           ) do
      :ok
    else
      # Running logout again finds no sign-in here, so what the error says to do does not hold.
      {{:error, _kind, message}, _endpoints} -> {:error, Failure.said(message)}
      {:error, _kind, message} -> {:error, Failure.said(message)}
      {:error, message} -> {:error, "ehosctl could not read its token: #{message}"}
      :none -> {:error, "This computer keeps no token for the installation."}
    end
  end

  defp result(name, url, :ok),
    do: %{
      text:
        Output.lines([
          Output.outcome(:done, "Signed out of #{name}."),
          Output.values([{"Address", url}])
        ]),
      json: %{installation: name, signed_out: true, revoked: true}
    }

  # The sign-in stays at EHOS until it ends it: why EHOS did not hear, under the outcome.
  defp result(name, url, {:error, why}) do
    %{
      text:
        Output.lines([
          Output.outcome(:warning, "Signed out of #{name} on this computer only."),
          Output.values([{"Address", url}, {"Reason", why}]),
          "  EHOS did not receive the sign-out. EHOS ends the sign-in itself, at the latest 3 " <>
            "days after its last use."
        ]),
      json: %{installation: name, signed_out: true, revoked: false, reason: why}
    }
  end
end

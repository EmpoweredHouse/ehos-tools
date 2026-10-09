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
  alias Ehosctl.Output
  alias Ehosctl.SignIn
  alias Ehosctl.TokenStore

  @impl Ehosctl.Command
  def name, do: :logout

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about: "Sign out of an installation: end the sign-in at EHOS, and forget it here.",
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
           text: "You are not signed in to #{name}.",
           json: %{installation: name, signed_out: false, revoked: false}
         }}

      _signed_in ->
        TokenStore.with_lock(Credentials.state_dir(opts), name, fn ->
          revoked = revoke(name, url, opts)

          with :ok <- Credentials.forget(name, opts) do
            {:ok, result(name, url, revoked)}
          end
        end)
    end
  end

  # Whether EHOS was told: `:ok`, or why not.
  defp revoke(name, url, opts) do
    key = %{dir: Credentials.state_dir(opts), name: name, url: url}

    with {:ok, session} <- Credentials.session(name, url, opts),
         {:ok, backend} <- TokenStore.backend(session.store, Credentials.keychain(opts)),
         {:ok, token} <- backend.get(key),
         {:ok, provider} <- SignIn.provider(url, opts),
         :ok <- SignIn.revoke(provider, token) do
      :ok
    else
      {:error, _kind, message} -> {:error, message}
      {:error, message} -> {:error, "its token could not be read: #{message}"}
      :none -> {:error, "no token was kept for it here"}
    end
  end

  defp result(name, url, :ok),
    do: %{
      text: "Signed out of #{name} (#{url}).",
      json: %{installation: name, signed_out: true, revoked: true}
    }

  defp result(name, url, {:error, why}) do
    %{
      text:
        "Signed out of #{name} (#{url}) on this computer. EHOS was not told, so the sign-in " <>
          "ends there by itself, at the latest three days from its last use. Why: #{why}",
      json: %{installation: name, signed_out: true, revoked: false, reason: why}
    }
  end
end

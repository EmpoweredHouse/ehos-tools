defmodule Ehosctl.SessionSecretsTest do
  use ExUnit.Case, async: true

  alias Ehosctl.SessionSecrets

  test "opens a session with the verifier and the public key, never the password" do
    secrets = SessionSecrets.new()
    body = SessionSecrets.opening(secrets, "read", 1800)

    assert body == %{
             "level" => "read",
             "verifier" => secrets.verifier,
             "publicKey" => EhosTunnel.Key.public_key(secrets.key),
             "ttl" => 1800
           }

    assert {:ok, _spki} = EhosTunnel.Key.decode_public_key(body["publicKey"])
    refute JSON.encode!(body) =~ secrets.password
    assert SessionSecrets.opening(secrets, "write", nil) |> Map.has_key?("ttl") == false
  end

  test "shows neither the password nor the key when inspected" do
    secrets = SessionSecrets.new()
    shown = inspect(secrets)

    refute shown =~ secrets.password
    refute shown =~ "ECPrivateKey"
    assert shown =~ secrets.verifier
  end
end

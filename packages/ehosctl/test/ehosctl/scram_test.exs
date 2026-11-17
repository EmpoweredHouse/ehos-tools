defmodule Ehosctl.ScramTest do
  use ExUnit.Case, async: true

  alias Ehosctl.Scram

  doctest Ehosctl.Scram

  # RFC 7677's example exchange, for the password "pencil".
  @salt "W22ZaJ0SNY7soEsUEjb6gQ=="
  @auth_message "n=user,r=rOprNGfwEbeRWgbNEkqO," <>
                  "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," <>
                  "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096," <>
                  "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
  @client_proof "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
  @server_signature "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

  # EHOS's check of a verifier (`Ehos.Cluster`): 4096 to 100 000 iterations, a salt of 12 to 88
  # characters and two 32-byte keys, in padded base64.
  @ehos ~r/\ASCRAM-SHA-256\$(\d+):([A-Za-z0-9+\/]{12,88}={0,2})\$([A-Za-z0-9+\/]{43}=):([A-Za-z0-9+\/]{43}=)\z/

  test "a server holding the verifier checks RFC 7677's client, and signs as RFC 7677's server" do
    verifier = Scram.verifier("pencil", Base.decode64!(@salt), 4096)
    [_all, "4096", @salt, stored_key, server_key] = Regex.run(@ehos, verifier)

    # What PostgreSQL does with the client's proof: its ClientKey hashes to the StoredKey.
    signature = :crypto.mac(:hmac, :sha256, Base.decode64!(stored_key), @auth_message)
    client_key = :crypto.exor(Base.decode64!(@client_proof), signature)
    assert :crypto.hash(:sha256, client_key) == Base.decode64!(stored_key)

    assert Base.encode64(:crypto.mac(:hmac, :sha256, Base.decode64!(server_key), @auth_message)) ==
             @server_signature
  end

  test "a password is 43 characters of unpadded base64url, new each time" do
    passwords = for _ <- 1..20, do: Scram.password()

    assert Enum.all?(passwords, &(&1 =~ ~r/\A[A-Za-z0-9_-]{43}\z/))
    assert passwords |> Enum.uniq() |> length() == 20
  end

  test "a verifier is what EHOS takes, with a salt of its own each time" do
    password = Scram.password()
    verifiers = for _ <- 1..5, do: Scram.verifier(password)

    for verifier <- verifiers do
      assert [_all, "4096", salt, _stored, _server] = Regex.run(@ehos, verifier)
      assert byte_size(Base.decode64!(salt)) == 16
      refute verifier =~ password
    end

    assert verifiers |> Enum.uniq() |> length() == 5
  end
end

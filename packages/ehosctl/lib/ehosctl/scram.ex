defmodule Ehosctl.Scram do
  @moduledoc """
  The password of a data session, and its SCRAM-SHA-256 verifier, the one thing about it that
  `ehosctl` sends to EHOS (eh-os
  [D-171](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0171-a-person-s-database-session-gets-a-role-that-is-made-as-its-binding-s-roles-are-a-member-of-its-schema-s-read-or-write-group-with-a-password-only-the-person-s-client-knows-and-openbao-makes-none.md)).

  The password is 32 bytes from the system's random source, as unpadded base64url: 43 characters
  of `A-Z a-z 0-9 - _`, which a password file, a connection string and SASLprep leave as they are.
  The verifier is PostgreSQL's form of RFC 5802 and RFC 7677's stored keys:

      SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>

  with `SaltedPassword = PBKDF2-HMAC-SHA-256(password, salt, iterations)`,
  `StoredKey = SHA-256(HMAC(SaltedPassword, "Client Key"))` and
  `ServerKey = HMAC(SaltedPassword, "Server Key")`, each in padded base64. A salt of 16 random
  bytes and 4096 iterations are PostgreSQL's own defaults (`scram_iterations`); EHOS takes 4096
  to 100 000 and a salt of 12 to 88 characters. With 256 random bits in the password, more
  iterations would protect nothing a guess could reach.
  """

  @iterations 4096
  @salt_bytes 16
  @password_bytes 32

  @doc "A new password: 32 random bytes as unpadded base64url."
  @spec password() :: String.t()
  def password,
    do: @password_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "The verifier of `password`, with a new random salt and 4096 iterations."
  @spec verifier(String.t()) :: String.t()
  def verifier(password),
    do: verifier(password, :crypto.strong_rand_bytes(@salt_bytes), @iterations)

  @doc """
  The verifier of `password` with `salt` and `iterations`, in PostgreSQL's form.

      iex> Ehosctl.Scram.verifier("pencil", Base.decode64!("W22ZaJ0SNY7soEsUEjb6gQ=="), 4096)
      "SCRAM-SHA-256$4096:W22ZaJ0SNY7soEsUEjb6gQ==$WG5d8oPm3OtcPnkdi4Uo7BkeZkBFzpcXkuLmtbsT4qY=:wfPLwcE6nTWhTAmQ7tl2KeoiWGPlZqQxSrmfPwDl2dU="
  """
  @spec verifier(String.t(), binary(), pos_integer()) :: String.t()
  def verifier(password, salt, iterations) do
    salted = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)
    stored_key = :crypto.hash(:sha256, :crypto.mac(:hmac, :sha256, salted, "Client Key"))
    server_key = :crypto.mac(:hmac, :sha256, salted, "Server Key")

    "SCRAM-SHA-256$#{iterations}:#{Base.encode64(salt)}$" <>
      "#{Base.encode64(stored_key)}:#{Base.encode64(server_key)}"
  end
end

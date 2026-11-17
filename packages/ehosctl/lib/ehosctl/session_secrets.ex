defmodule Ehosctl.SessionSecrets do
  @moduledoc """
  What a person's computer makes for one data session, and keeps to itself: its password, made
  as `Ehosctl.Scram` says, and its key, an ECDSA key pair on P-256 (`EhosTunnel.Key`), whose
  private half proves the session to the data gateway (eh-os
  [D-149](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0149-a-person-s-database-session-reaches-its-instance-through-a-data-gateway-of-its-own-not-the-governance-plane.md),
  [D-171](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0171-a-person-s-database-session-gets-a-role-that-is-made-as-its-binding-s-roles-are-a-member-of-its-schema-s-read-or-write-group-with-a-password-only-the-person-s-client-knows-and-openbao-makes-none.md)).

  EHOS is sent `opening/3`: the password's verifier and the key's public half, neither of which
  opens the session. The password and the private key stay in memory, and `inspect/1` shows
  neither, so no crash report or log line carries them.
  """

  @derive {Inspect, only: [:verifier]}
  @enforce_keys [:password, :verifier, :key]
  defstruct [:password, :verifier, :key]

  @typedoc "A data session's password, its verifier and its key."
  @type t :: %__MODULE__{
          password: String.t(),
          verifier: String.t(),
          key: EhosTunnel.Key.private_key()
        }

  @doc "A new password, its verifier, and a new key."
  @spec new() :: t()
  def new do
    password = Ehosctl.Scram.password()

    %__MODULE__{
      password: password,
      verifier: Ehosctl.Scram.verifier(password),
      key: EhosTunnel.Key.generate()
    }
  end

  @doc """
  The body that opens a data session of `level` (`"read"` or `"write"`) for `ttl` seconds, `nil`
  for EHOS's default, one hour: the verifier and the key's public half, never the password.
  """
  @spec opening(t(), String.t(), pos_integer() | nil) :: map()
  def opening(%__MODULE__{} = secrets, level, ttl) do
    body = %{
      "level" => level,
      "verifier" => secrets.verifier,
      "publicKey" => EhosTunnel.Key.public_key(secrets.key)
    }

    if ttl, do: Map.put(body, "ttl", ttl), else: body
  end
end

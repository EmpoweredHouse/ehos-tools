defmodule EhosTunnel.Key do
  @moduledoc """
  A session's key: an ECDSA key pair on the curve P-256, its public half as EHOS takes it in a
  session's `publicKey`, and its fingerprint (eh-os D-179).

  The `publicKey` is base64 with padding (RFC 4648, section 4) of the DER encoding of the key's
  `SubjectPublicKeyInfo` (RFC 5280): the algorithm `id-ecPublicKey`, the curve `prime256v1`, and
  the point uncompressed. The fingerprint is the SHA-256 of those DER bytes, the same for the key
  a client sent and the key in the certificate it presents.

      iex> key = EhosTunnel.Key.generate()
      iex> {:ok, spki} = key |> EhosTunnel.Key.public_key() |> EhosTunnel.Key.decode_public_key()
      iex> spki == EhosTunnel.Key.spki(key)
      true

  The private half stays in memory: nothing here writes it anywhere.
  """

  @typedoc "A P-256 private key, as Erlang's `:public_key` holds one (`#ECPrivateKey{}`)."
  @type private_key ::
          {:ECPrivateKey, :ecPrivkeyVer1 | 1, binary(), {:namedCurve, tuple()}, binary(),
           :asn1_NOVALUE}

  @typedoc """
  Why `decode_public_key/1` refused a value: `:not_base64` for anything that is not base64 with
  padding, `:not_p256` for a key of another type or curve, a compressed point, or bytes before or
  after the `SubjectPublicKeyInfo`, and `:not_on_curve` for a point that is not on P-256.
  """
  @type refusal :: :not_base64 | :not_p256 | :not_on_curve

  # prime256v1, also called secp256r1 and P-256.
  @curve {1, 2, 840, 10_045, 3, 1, 7}

  # Every P-256 `SubjectPublicKeyInfo` with an uncompressed point starts with these 27 bytes and
  # holds 64 more, the point's two coordinates: SEQUENCE (89 bytes) { SEQUENCE { OID
  # id-ecPublicKey, OID prime256v1 }, BIT STRING (66 bytes, no unused bits) { 0x04, x, y } }. So a
  # value is read by its length and this prefix, with no ASN.1 decoder, which keeps a refusal cheap
  # whatever the value holds.
  @spki_prefix <<0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
                 0x04>>

  # The base64 of a 91-byte `SubjectPublicKeyInfo`, with padding.
  @encoded_size 124

  # The curve's equation, y² = x³ - 3x + b over the field of p (SEC 2, section 2.4.2).
  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B

  @doc """
  A new key pair on P-256, from the system's random source through OpenSSL (`:crypto`).
  """
  @spec generate() :: private_key()
  def generate, do: :public_key.generate_key({:namedCurve, @curve})

  @doc """
  The DER encoding of the key's `SubjectPublicKeyInfo`: what `public_key/1` encodes and
  `fingerprint/1` hashes.
  """
  @spec spki(private_key()) :: binary()
  def spki({:ECPrivateKey, _version, _private, {:namedCurve, @curve}, point, _attributes}) do
    {:SubjectPublicKeyInfo, der, :not_encrypted} =
      :public_key.pem_entry_encode(
        :SubjectPublicKeyInfo,
        {{:ECPoint, point}, {:namedCurve, @curve}}
      )

    der
  end

  @doc """
  The key's public half as a session's `publicKey`: base64, with padding, of its
  `SubjectPublicKeyInfo` in DER.
  """
  @spec public_key(private_key()) :: String.t()
  def public_key(key), do: key |> spki() |> Base.encode64()

  @doc """
  Reads a session's `publicKey` back to the DER of its `SubjectPublicKeyInfo`, or refuses it.

  It takes only what `public_key/1` makes: base64 with padding of a P-256 key, its point
  uncompressed and on the curve. Any other value, of any type, is a `t:refusal/0`, never an
  exception, and the answer costs a length check and a few multiplications.

      iex> EhosTunnel.Key.decode_public_key("not base64!")
      {:error, :not_base64}
  """
  @spec decode_public_key(term()) :: {:ok, binary()} | {:error, refusal()}
  def decode_public_key(encoded)
      when is_binary(encoded) and byte_size(encoded) == @encoded_size do
    case Base.decode64(encoded) do
      {:ok, der} -> p256(der)
      :error -> {:error, :not_base64}
    end
  end

  def decode_public_key(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, _der} -> {:error, :not_p256}
      :error -> {:error, :not_base64}
    end
  end

  def decode_public_key(_encoded), do: {:error, :not_base64}

  @doc """
  The key's fingerprint: the SHA-256 of its `SubjectPublicKeyInfo` in DER, 32 bytes. The gateway
  sends the governance plane the fingerprint of the key in a client's certificate, and the
  governance plane compares it with the session's.
  """
  @spec fingerprint(binary()) :: <<_::256>>
  def fingerprint(spki) when is_binary(spki), do: :crypto.hash(:sha256, spki)

  @doc "`fingerprint/1` in base64 with padding, for a fingerprint carried as text."
  @spec encoded_fingerprint(binary()) :: String.t()
  def encoded_fingerprint(spki), do: spki |> fingerprint() |> Base.encode64()

  defp p256(<<@spki_prefix, x::unsigned-big-256, y::unsigned-big-256>> = der) do
    if on_curve?(x, y), do: {:ok, der}, else: {:error, :not_on_curve}
  end

  defp p256(_der), do: {:error, :not_p256}

  defp on_curve?(x, y) when x < @p and y < @p,
    do: rem(y * y, @p) == Integer.mod(x * x * x - 3 * x + @b, @p)

  defp on_curve?(_x, _y), do: false
end

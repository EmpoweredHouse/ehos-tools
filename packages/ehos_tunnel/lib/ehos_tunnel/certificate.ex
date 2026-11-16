defmodule EhosTunnel.Certificate do
  @moduledoc """
  The certificate a client presents to the data gateway: an X.509 v3 certificate for a session's
  key, signed by that key with ecdsa-with-SHA256 (eh-os D-179).

  The gateway reads only the key in it, which the TLS handshake proved the client holds: no name,
  date or extension. So the certificate names its subject `ehos-tunnel`, is valid from 1970 to
  the end of 9999 (RFC 5280, section 4.1.2.5, for a certificate with no expiry), and has no
  extensions, and reading no clock keeps it a function of the key and a random serial number.

      iex> key = EhosTunnel.Key.generate()
      iex> certificate = EhosTunnel.Certificate.self_signed(key)
      iex> EhosTunnel.Certificate.spki(certificate) == {:ok, EhosTunnel.Key.spki(key)}
      true
  """

  require Record

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  # ecdsa-with-SHA256 (RFC 5758), id-ecPublicKey and prime256v1 (RFC 5480), commonName (X.520).
  @ecdsa_with_sha256 {1, 2, 840, 10_045, 4, 3, 2}
  @id_ec_public_key {1, 2, 840, 10_045, 2, 1}
  @prime256v1 {1, 2, 840, 10_045, 3, 1, 7}
  @common_name {2, 5, 4, 3}

  @name {:rdnSequence, [[{:AttributeTypeAndValue, @common_name, {:utf8String, "ehos-tunnel"}}]]}
  @validity {:Validity, {:utcTime, ~c"700101000000Z"}, {:generalTime, ~c"99991231235959Z"}}

  @doc """
  A self-signed certificate for `key`, as DER. Two calls give two certificates with different
  serial numbers and signatures, for the same key.
  """
  @spec self_signed(EhosTunnel.Key.private_key()) :: binary()
  def self_signed(
        {:ECPrivateKey, _version, _private, {:namedCurve, @prime256v1}, point, _attributes} = key
      ) do
    tbs(
      version: :v3,
      serialNumber: serial_number(),
      signature: {:SignatureAlgorithm, @ecdsa_with_sha256, :asn1_NOVALUE},
      issuer: @name,
      validity: @validity,
      subject: @name,
      subjectPublicKeyInfo:
        {:OTPSubjectPublicKeyInfo,
         {:PublicKeyAlgorithm, @id_ec_public_key, {:namedCurve, @prime256v1}}, {:ECPoint, point}}
    )
    |> :public_key.pkix_sign(key)
  end

  def self_signed(_key), do: raise(ArgumentError, "the key is not a P-256 private key")

  @doc """
  The options that make an `:ssl` client present `certificate` with `key`, for `:ssl.connect/3`
  or a client built on it, such as Mint's `:transport_opts`.
  """
  @spec ssl_options(binary(), EhosTunnel.Key.private_key()) :: [:ssl.tls_client_option()]
  def ssl_options(certificate, key) do
    [cert: certificate, key: {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, key)}]
  end

  @doc """
  The DER of the `SubjectPublicKeyInfo` in a certificate, for `EhosTunnel.Key.fingerprint/1`:
  what the gateway reads of the certificate a client presented. It refuses a certificate whose key
  is not on P-256, and anything that is not a certificate in DER.
  """
  @spec spki(binary()) :: {:ok, binary()} | {:error, :not_a_certificate | :not_p256}
  def spki(certificate) when is_binary(certificate) do
    certificate |> decode() |> key_of()
  end

  @doc """
  The `:ssl` options of the gateway's side of the handshake, beside its own certificate and key:
  it asks for a client's certificate, fails a handshake without one, and accepts a single
  self-signed certificate, by its issuer naming its subject, and nothing that names another
  issuer, since it trusts no issuer for clients. It does not check the certificate's signature:
  the handshake proves that the client holds the certificate's key, which is all the gateway
  reads (`spki/1`).

  It names no certificate authority in its request (`certificate_authorities: false`): a TLS 1.3
  client, Erlang's among them, sends only a certificate one of the named authorities issued, and
  so would send none of a session's.
  """
  @spec gateway_ssl_options() :: [:ssl.tls_server_option()]
  def gateway_ssl_options do
    [
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      cacerts: [],
      certificate_authorities: false,
      verify_fun: {&verify/3, nil}
    ]
  end

  defp verify(_certificate, {:bad_cert, :selfsigned_peer}, state), do: {:valid, state}
  defp verify(_certificate, {:bad_cert, _reason} = reason, _state), do: {:fail, reason}
  defp verify(_certificate, {:extension, _extension}, state), do: {:unknown, state}
  defp verify(_certificate, :valid, state), do: {:valid, state}
  defp verify(_certificate, :valid_peer, state), do: {:valid, state}

  # A positive serial number of at most 20 bytes (RFC 5280, section 4.1.2.2), from 16 random ones.
  defp serial_number, do: :binary.decode_unsigned(:crypto.strong_rand_bytes(16)) + 1

  defp decode(certificate) do
    {:ok, :public_key.pkix_decode_cert(certificate, :otp)}
  rescue
    _not_a_certificate -> {:error, :not_a_certificate}
  end

  defp key_of({:ok, {:OTPCertificate, tbs(subjectPublicKeyInfo: info), _algorithm, _signature}}),
    do: p256(info)

  defp key_of({:error, _reason} = error), do: error

  defp p256(
         {:OTPSubjectPublicKeyInfo,
          {:PublicKeyAlgorithm, @id_ec_public_key, {:namedCurve, @prime256v1}}, {:ECPoint, point}}
       ) do
    {:SubjectPublicKeyInfo, der, :not_encrypted} =
      :public_key.pem_entry_encode(
        :SubjectPublicKeyInfo,
        {{:ECPoint, point}, {:namedCurve, @prime256v1}}
      )

    {:ok, der}
  end

  defp p256(_info), do: {:error, :not_p256}
end

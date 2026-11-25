defmodule EhosPlatform.TestCA do
  # A client CA as k3s's, which signs a certificate for the key in a CSR, for the tests of
  # `EhosPlatform.Server.ClientCertificate` and of `tunnel`. Hidden, as `EhosPlatform.TestSupport`.
  @moduledoc false

  @doc "A new CA, ECDSA P-256 or RSA (`kind`): its certificate, as PEM, and its key."
  @spec new(String.t(), :ec | :rsa) :: %{pem: String.t(), der: binary(), key: tuple()}
  def new(name \\ "k3s-client-ca", kind \\ :ec) do
    key =
      if kind == :rsa,
        do: :public_key.generate_key({:rsa, 2048, 65_537}),
        else: :public_key.generate_key({:namedCurve, :secp256r1})

    %{cert: der} = :public_key.pkix_test_root_cert(String.to_charlist(name), [{:key, key}])
    %{pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}]), der: der, key: key}
  end

  @doc """
  A certificate, as PEM, that `ca` signs for the Ed25519 public key `public` with the common name
  `user`, valid from `from` to `until`, as `YYMMDDHHMMSSZ`, with the signature algorithm of the
  CA's own certificate.
  """
  @spec sign(map(), binary(), String.t(), String.t(), String.t()) :: String.t()
  def sign(ca, public, user, from, until) do
    ca_tbs = ca.der |> :public_key.pkix_decode_cert(:otp) |> elem(1)

    tbs =
      {:OTPTBSCertificate, :v3, 7, elem(ca_tbs, 3), elem(ca_tbs, 6),
       {:Validity, {:utcTime, String.to_charlist(from)}, {:utcTime, String.to_charlist(until)}},
       {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, user}}]]},
       {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 3, 101, 112}, :asn1_NOVALUE},
        {:ECPoint, public}}, :asn1_NOVALUE, :asn1_NOVALUE, :asn1_NOVALUE}

    :public_key.pem_encode([{:Certificate, :public_key.pkix_sign(tbs, ca.key), :not_encrypted}])
  end

  @doc "The public key in a CSR, as PEM."
  @spec requested_key(String.t()) :: binary()
  def requested_key(csr) do
    [{:CertificationRequest, der, :not_encrypted}] = :public_key.pem_decode(csr)
    {:CertificationRequest, info, _, _} = :public_key.der_decode(:CertificationRequest, der)
    {:CertificationRequestInfo, _, _, {_, _, public}, _} = info
    public
  end
end

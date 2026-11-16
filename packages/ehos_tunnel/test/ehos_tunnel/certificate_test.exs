defmodule EhosTunnel.CertificateTest do
  use ExUnit.Case, async: true

  alias EhosTunnel.{Certificate, Key}

  @p256 [key: {:namedCurve, :secp256r1}, digest: :sha256]

  describe "self_signed/1" do
    test "is signed by its own key with ecdsa-with-SHA256, for that key" do
      key = Key.generate()
      certificate = Certificate.self_signed(key)
      {:ECPrivateKey, _version, _private, curve, point, _attributes} = key

      assert :public_key.pkix_verify(certificate, {{:ECPoint, point}, curve})
      assert :public_key.pkix_is_self_signed(certificate)

      {:OTPCertificate, _tbs, {:SignatureAlgorithm, algorithm, _parameters}, _signature} =
        :public_key.pkix_decode_cert(certificate, :otp)

      assert algorithm == {1, 2, 840, 10_045, 4, 3, 2}
      assert Certificate.spki(certificate) == {:ok, Key.spki(key)}
    end

    test "is not verified by another key" do
      {:ECPrivateKey, _version, _private, curve, point, _attributes} = Key.generate()

      refute :public_key.pkix_verify(
               Certificate.self_signed(Key.generate()),
               {{:ECPoint, point}, curve}
             )
    end

    test "a TLS 1.3 server that takes self-signed client certificates sees the key's fingerprint" do
      key = Key.generate()
      server = server_config()
      {:ok, listen} = :ssl.listen(0, server_options(server))
      {:ok, {_address, port}} = :ssl.sockname(listen)
      test = self()

      spawn_link(fn ->
        {:ok, socket} = :ssl.transport_accept(listen)
        {:ok, socket} = :ssl.handshake(socket, 5_000)
        {:ok, peer} = :ssl.peercert(socket)
        send(test, {:peer, peer})
      end)

      {:ok, client} =
        :ssl.connect(
          ~c"localhost",
          port,
          [
            versions: [:"tlsv1.3"],
            verify: :verify_peer,
            cacerts: server[:cacerts],
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ] ++ Certificate.ssl_options(Certificate.self_signed(key), key),
          5_000
        )

      assert_receive {:peer, peer}, 5_000
      {:ok, spki} = Certificate.spki(peer)

      assert Key.fingerprint(spki) == Key.fingerprint(Key.spki(key))
      :ssl.close(client)
    end

    test "a TLS 1.3 server with gateway_ssl_options/0 refuses a client with no certificate" do
      server = server_config()
      {:ok, listen} = :ssl.listen(0, server_options(server))
      {:ok, {_address, port}} = :ssl.sockname(listen)
      test = self()

      spawn_link(fn ->
        {:ok, socket} = :ssl.transport_accept(listen)
        send(test, {:handshake, :ssl.handshake(socket, 5_000)})
      end)

      {:ok, _client} =
        :ssl.connect(~c"localhost", port, [versions: [:"tlsv1.3"], verify: :verify_none], 5_000)

      assert_receive {:handshake, {:error, {:tls_alert, {:certificate_required, _text}}}}, 5_000
    end
  end

  describe "spki/1" do
    test "refuses what is not a certificate, and a certificate for a key not on P-256" do
      rsa = :public_key.pkix_test_root_cert(~c"rsa", key: {:rsa, 2048, 65_537})

      assert Certificate.spki("not a certificate") == {:error, :not_a_certificate}
      assert Certificate.spki(rsa.cert) == {:error, :not_p256}
    end

    test "refuses a certificate whose P-256 point is not on the curve" do
      {:OTPCertificate, tbs, algorithm, signature} =
        :public_key.pkix_decode_cert(Certificate.self_signed(Key.generate()), :otp)

      {:OTPSubjectPublicKeyInfo, key_algorithm, {:ECPoint, _point}} = elem(tbs, 7)
      off_curve = {:OTPSubjectPublicKeyInfo, key_algorithm, {:ECPoint, <<4, 0::512>>}}
      forged = {:OTPCertificate, put_elem(tbs, 7, off_curve), algorithm, signature}

      assert Certificate.spki(:public_key.pkix_encode(:OTPCertificate, forged, :otp)) ==
               {:error, :not_p256}
    end
  end

  defp server_config do
    # P-256 and SHA-256: the test helper's default curve and digest are not TLS 1.3's.
    root = :public_key.pkix_test_root_cert(~c"ehos_tunnel test CA", @p256)

    :public_key.pkix_test_data(%{
      server_chain: %{
        root: root,
        intermediates: [],
        peer:
          @p256 ++ [extensions: [{:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}]]
      },
      client_chain: %{root: root, intermediates: [], peer: @p256}
    })[:server_config]
  end

  defp server_options(server) do
    [
      cert: server[:cert],
      key: server[:key],
      versions: [:"tlsv1.3"],
      reuseaddr: true
    ] ++ Certificate.gateway_ssl_options()
  end
end

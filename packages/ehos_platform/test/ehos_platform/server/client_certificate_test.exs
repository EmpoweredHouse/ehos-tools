defmodule EhosPlatform.Server.ClientCertificateTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.Server.ClientCertificate
  alias EhosPlatform.TestCA

  @user "ehos-administrator:ada:1a2b3c4d"

  test "makes a CSR for the user alone, with the key's public key, signed by the key" do
    key = ClientCertificate.new_key()
    csr = ClientCertificate.csr(key, @user)

    [{:CertificationRequest, der, :not_encrypted}] = :public_key.pem_decode(csr)

    {:CertificationRequest, info, algorithm, signature} =
      :public_key.der_decode(:CertificationRequest, der)

    {:CertificationRequestInfo, :v1, subject, _key, []} = info

    assert subject ==
             {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, @user}}]]}

    assert TestCA.requested_key(csr) == elem(key, 4)
    assert elem(algorithm, 1) == {1, 3, 101, 112}

    {:ok, info_der} = :"PKCS-10".encode(:CertificationRequestInfo, info)
    assert :public_key.verify(info_der, :none, signature, {:ed_pub, :ed25519, elem(key, 4)})
  end

  test "asks the cluster for a client certificate of 12 hours from the API server's signer" do
    assert ClientCertificate.request("ehos-administrator-ada-1a2b3c4d-0a0b0c0d", "CSR") == %{
             "apiVersion" => "certificates.k8s.io/v1",
             "kind" => "CertificateSigningRequest",
             "metadata" => %{"name" => "ehos-administrator-ada-1a2b3c4d-0a0b0c0d"},
             "spec" => %{
               "request" => Base.encode64("CSR"),
               "signerName" => "kubernetes.io/kube-apiserver-client",
               "usages" => ["client auth"],
               "expirationSeconds" => 43_200
             }
           }
  end

  describe "check_request/3" do
    setup do
      key = ClientCertificate.new_key()
      csr = ClientCertificate.csr(key, @user)

      created =
        "ehos-administrator-ada-1a2b3c4d-0a0b0c0d"
        |> ClientCertificate.request(csr)
        |> Map.update!("metadata", &Map.merge(&1, %{"uid" => "u-1", "resourceVersion" => "41"}))

      %{key: key, csr: csr, created: created}
    end

    test "takes the CSR this workstation made, as the cluster created it", context do
      assert ClientCertificate.check_request(context.created, context.csr, {context.key, @user}) ==
               :ok
    end

    test "refuses another CSR, signer, usage, lifetime, or one approved already", context do
      %{key: key, csr: csr, created: created} = context
      other = ClientCertificate.csr(ClientCertificate.new_key(), @user)

      for changed <- [
            put_in(created, ["spec", "request"], Base.encode64(other)),
            put_in(created, ["spec", "signerName"], "kubernetes.io/legacy-unknown"),
            put_in(created, ["spec", "usages"], ["client auth", "server auth"]),
            put_in(created, ["spec", "expirationSeconds"], 31_536_000),
            Map.put(created, "status", %{"conditions" => [%{"type" => "Approved"}]}),
            update_in(created, ["metadata"], &Map.delete(&1, "uid"))
          ] do
        assert ClientCertificate.check_request(changed, csr, {key, @user}) ==
                 {:error,
                  "The certificate signing request on the server is not the one that ehosctl " <>
                    "made. ehosctl did not approve it. Run the command again."}
      end

      assert {:error, _not_ours} = ClientCertificate.check_request(created, csr, {key, "other"})
    end
  end

  describe "a certificate the cluster issued" do
    setup do
      ca = TestCA.new()
      key = ClientCertificate.new_key()
      pem = TestCA.sign(ca, elem(key, 4), @user, "261119080000Z", "261119200000Z")
      %{ca: ca, key: key, pem: pem}
    end

    test "is checked against the key and the user", %{key: key, pem: pem} do
      assert ClientCertificate.check_certificate(pem, key, @user) == :ok

      assert {:error, _} =
               ClientCertificate.check_certificate(pem, key, "ehos-administrator:bob:0a0b0c0d")

      assert {:error, _} =
               ClientCertificate.check_certificate(pem, ClientCertificate.new_key(), @user)

      assert ClientCertificate.expires(pem) == ~U[2026-11-19 20:00:00Z]
    end

    test "is not kept before it is valid, and is kept under an RSA client CA", %{key: key} do
      key_pem = ClientCertificate.key_pem(key)
      ec = TestCA.new()
      later = TestCA.sign(ec, elem(key, 4), @user, "261119140000Z", "261120020000Z")
      refute ClientCertificate.usable?(later, key_pem, @user, ec.pem, ~U[2026-11-19 12:00:00Z])

      rsa = TestCA.new("k3s-client-ca", :rsa)
      pem = TestCA.sign(rsa, elem(key, 4), @user, "261119080000Z", "261119200000Z")
      assert ClientCertificate.usable?(pem, key_pem, @user, rsa.pem, ~U[2026-11-19 12:00:00Z])
    end

    test "is kept while the client CA signed it and it has an hour left", context do
      %{ca: ca, key: key, pem: pem} = context
      key_pem = ClientCertificate.key_pem(key)

      assert ClientCertificate.usable?(pem, key_pem, @user, ca.pem, ~U[2026-11-19 18:59:00Z])
      refute ClientCertificate.usable?(pem, key_pem, @user, ca.pem, ~U[2026-11-19 19:01:00Z])

      refute ClientCertificate.usable?(
               pem,
               key_pem,
               @user,
               TestCA.new().pem,
               ~U[2026-11-19 12:00:00Z]
             )

      refute ClientCertificate.usable?(
               pem,
               ClientCertificate.key_pem(ClientCertificate.new_key()),
               @user,
               ca.pem,
               ~U[2026-11-19 12:00:00Z]
             )

      refute ClientCertificate.usable?(pem, key_pem, "other", ca.pem, ~U[2026-11-19 12:00:00Z])
      refute ClientCertificate.usable?(nil, nil, @user, ca.pem, ~U[2026-11-19 12:00:00Z])
    end
  end

  test "writes a kubeconfig with the server CA, the tunnel's port, the certificate and the key" do
    assert ClientCertificate.kubeconfig("ehos-acme", 16_443, "SERVER CA", "CERT", "KEY") == %{
             "apiVersion" => "v1",
             "kind" => "Config",
             "clusters" => [
               %{
                 "name" => "ehos-acme",
                 "cluster" => %{
                   "certificate-authority-data" => Base.encode64("SERVER CA"),
                   "server" => "https://127.0.0.1:16443"
                 }
               }
             ],
             "users" => [
               %{
                 "name" => "ehos-acme",
                 "user" => %{
                   "client-certificate-data" => Base.encode64("CERT"),
                   "client-key-data" => Base.encode64("KEY")
                 }
               }
             ],
             "contexts" => [
               %{
                 "name" => "ehos-acme",
                 "context" => %{"cluster" => "ehos-acme", "user" => "ehos-acme"}
               }
             ],
             "current-context" => "ehos-acme"
           }
  end
end

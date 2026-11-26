defmodule Ehosctl.DataCaTest do
  use ExUnit.Case, async: true

  alias Ehosctl.DataCa
  alias Ehosctl.TestCA

  doctest Ehosctl.DataCa

  test "takes a CA whose fingerprint is the SHA-256 of its certificate's key, as EHOS computes it" do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = TestCA.certificate("Data CA", key)

    assert DataCa.parse(%{"certificate" => pem, "keySha256" => spki_sha256(key)}) ==
             {:ok, %{certificate: pem, key_sha256: spki_sha256(key)}}

    assert DataCa.fingerprint(pem) == {:ok, spki_sha256(key)}
  end

  test "refuses a CA whose fingerprint is another key's, two certificates, or no certificate" do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = TestCA.certificate("Data CA", key)
    other = TestCA.certificate("Another CA", :public_key.generate_key({:namedCurve, :secp256r1}))
    {:ok, other_sha256} = DataCa.fingerprint(other)

    for given <- [
          %{"certificate" => pem, "keySha256" => other_sha256},
          %{"certificate" => pem <> other, "keySha256" => spki_sha256(key)},
          %{"certificate" => "not a certificate", "keySha256" => spki_sha256(key)},
          %{"certificate" => pem},
          nil
        ] do
      assert DataCa.parse(given) == :error
    end
  end

  test "reads a kept CA back, and refuses one that config.json holds in another shape" do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = TestCA.certificate("Data CA", key)
    stored = %{"certificate" => pem, "key_sha256" => spki_sha256(key)}

    assert DataCa.kept({"staging", %{"url" => "u", "data_ca" => stored}}, :data) ==
             {:ok, %{certificate: pem, key_sha256: spki_sha256(key)}}

    assert DataCa.kept({"staging", %{"url" => "u"}}, :gateway) == {:ok, nil}

    for broken <- [Map.put(stored, "key_sha256", "AAAA"), Map.put(stored, "more", 1), "pem"] do
      assert DataCa.kept({"staging", %{"url" => "u", "gateway_ca" => broken}}, :gateway) ==
               {:error, :failed,
                %Ehosctl.Failure{
                  said:
                    "The gateway CA that ehosctl keeps for staging in config.json is not a CA " <>
                      "it can read.",
                  advice: "Remove \"gateway_ca\" from it, then sign in again:",
                  to_do: ["ehosctl login --installation staging"]
                }}
    end
  end

  test "reads a session's CAs, and names the installation when one is not a CA" do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = TestCA.certificate("Gateway CA", key)
    given = %{"certificate" => pem, "keySha256" => spki_sha256(key)}
    ca = %{certificate: pem, key_sha256: spki_sha256(key)}

    assert DataCa.parsed(%{"dataCa" => nil, "gatewayCa" => given}, {"staging", %{}}) ==
             {:ok, %{data: nil, gateway: ca}}

    assert DataCa.parsed(%{"dataCa" => %{"certificate" => "x"}}, {"staging", %{}}) ==
             {:error, :failed,
              "staging gave a data CA that is not one certificate with its own fingerprint, so " <>
                "ehosctl does not trust it."}
  end

  # The SubjectPublicKeyInfo of an EC key, made from the key alone, so the test does not compute
  # the fingerprint as the code does.
  defp spki_sha256({:ECPrivateKey, _version, _private, params, public, _attributes}) do
    spki =
      :public_key.der_encode(
        :SubjectPublicKeyInfo,
        {:SubjectPublicKeyInfo, {:AlgorithmIdentifier, {1, 2, 840, 10_045, 2, 1}, params}, public}
      )

    Base.encode64(:crypto.hash(:sha256, spki))
  end
end

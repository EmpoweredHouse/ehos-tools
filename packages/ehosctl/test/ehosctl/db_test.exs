defmodule Ehosctl.DbTest do
  use Ehosctl.SignInCase

  alias Ehosctl.TestCA

  @changed_gateway "ehosctl: local gives a gateway CA with another key than the one ehosctl " <>
                     "keeps, so ehosctl does not trust it, and refuses data sessions that use " <>
                     "it. If your installation's administrator told you that the key changed, " <>
                     "and gave you its fingerprint, run `ehosctl db trust-ca FINGERPRINT` with it.\n"

  @now ~U[2026-10-28 12:00:00Z]

  setup %{provider: provider} do
    stub_now(@now)
    FakeProvider.put_id_token_claims(provider, %{"auth_time" => DateTime.to_unix(@now)})

    [data, gateway, new_gateway] =
      for _ <- 1..3, do: :public_key.generate_key({:namedCurve, :secp256r1})

    %{keys: %{data: data, gateway: gateway, new_gateway: new_gateway}}
  end

  describe "login" do
    test "keeps the data CA and the gateway CA from the first sign-in, beyond logging out", %{
      provider: provider,
      opts: opts,
      keys: keys
    } do
      data = ca("Data CA", keys.data)
      gateway = ca("Gateway CA", keys.gateway)
      answer_cas(provider, data, gateway)

      {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)

      assert {code, stdout} == {0, signed_in(provider)}
      refute stderr =~ "CA"
      assert kept_cas(opts) == %{data: stored(data), gateway: stored(gateway)}

      {0, _stdout, ""} = ehosctl(["logout"], opts)
      assert kept_cas(opts) == %{data: stored(data), gateway: stored(gateway)}
    end

    test "takes a renewed certificate with the kept key, and not one with another key", %{
      provider: provider,
      opts: opts,
      keys: keys
    } do
      data = ca("Data CA", keys.data)
      gateway = ca("Gateway CA", keys.gateway)
      answer_cas(provider, data, gateway)
      login!(provider, opts)

      renewed = ca("Data CA renewed", keys.data)
      other = ca("Gateway CA", keys.new_gateway)
      answer_cas(provider, renewed, other)

      {code, stdout, stderr} = ehosctl(["login"], opts)

      assert {code, stdout} == {0, signed_in(provider)}
      assert String.ends_with?(stderr, @changed_gateway)
      assert kept_cas(opts) == %{data: stored(renewed), gateway: stored(gateway)}
    end

    test "keeps nothing from an installation that runs no data gateway", %{
      provider: provider,
      opts: opts
    } do
      {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)

      assert {code, stdout} == {0, signed_in(provider)}
      refute stderr =~ "CA"
      assert kept_cas(opts) == %{data: nil, gateway: nil}
    end

    test "signs in, and says so, when the CAs cannot be read", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/data-ca", 503, %{
        "error" => "ehos_unavailable",
        "message" => "EHOS cannot answer now. Try again later."
      })

      {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)

      assert {code, stdout} == {0, signed_in(provider)}

      assert String.ends_with?(
               stderr,
               "ehosctl: ehosctl could not read the data CA and the gateway CA of local, " <>
                 "which a data session needs: EHOS cannot answer now. Try again later. Run " <>
                 "`ehosctl login` again before you open one.\n"
             )

      assert kept_cas(opts) == %{data: nil, gateway: nil}
    end

    test "trusts no CA that is not its own certificate's", %{
      provider: provider,
      opts: opts,
      keys: keys
    } do
      data = ca("Data CA", keys.data)
      gateway = %{ca("Gateway CA", keys.gateway) | key_sha256: ca("x", keys.data).key_sha256}
      answer_cas(provider, data, gateway)

      {code, _stdout, stderr} = ehosctl(["login", provider.issuer], opts)

      assert code == 0
      assert stderr =~ "local gave a gateway CA that is not one certificate with its own"
      assert kept_cas(opts) == %{data: nil, gateway: nil}
    end
  end

  describe "db trust-ca" do
    setup %{provider: provider, opts: opts, keys: keys} do
      data = ca("Data CA", keys.data)
      gateway = ca("Gateway CA", keys.gateway)
      answer_cas(provider, data, gateway)
      login!(provider, opts)

      new_gateway = ca("Gateway CA", keys.new_gateway)
      answer_cas(provider, data, new_gateway)

      %{data: data, gateway: gateway, new_gateway: new_gateway}
    end

    test "takes the CA with the fingerprint the person typed", %{
      opts: opts,
      data: data,
      new_gateway: new_gateway
    } do
      assert ehosctl(["db", "trust-ca", new_gateway.key_sha256], opts) ==
               {0, "ehosctl now trusts the gateway CA of local with this fingerprint.\n", ""}

      assert kept_cas(opts) == %{data: stored(data), gateway: stored(new_gateway)}

      {0, stdout, ""} = ehosctl(["db", "trust-ca", new_gateway.key_sha256, "--json"], opts)

      assert JSON.decode!(stdout) == %{
               "installation" => "local",
               "ca" => "gateway",
               "key_sha256" => new_gateway.key_sha256,
               "changed" => false
             }
    end

    test "takes a fingerprint typed in hexadecimal, with colons", %{
      opts: opts,
      new_gateway: new_gateway
    } do
      hex =
        new_gateway.key_sha256
        |> Base.decode64!()
        |> Base.encode16()
        |> String.graphemes()
        |> Enum.chunk_every(2)
        |> Enum.map_join(":", &Enum.join/1)

      assert {0, _stdout, ""} = ehosctl(["db", "trust-ca", hex], opts)
      assert kept_cas(opts).gateway == stored(new_gateway)
    end

    test "keeps the old CA when no CA has the fingerprint", %{
      opts: opts,
      data: data,
      gateway: gateway
    } do
      typed = ca("Somebody's CA", :public_key.generate_key({:namedCurve, :secp256r1})).key_sha256

      assert ehosctl(["db", "trust-ca", typed], opts) ==
               {1, "",
                "ehosctl: Neither the data CA nor the gateway CA that local gives has the " <>
                  "fingerprint #{typed}. ehosctl trusts nothing new. Check the fingerprint " <>
                  "with the administrator of the installation.\n"}

      assert kept_cas(opts) == %{data: stored(data), gateway: stored(gateway)}
    end

    test "refuses what is not a fingerprint", %{opts: opts} do
      assert ehosctl(["db", "trust-ca", "abc"], opts) ==
               {2, "",
                "ehosctl: \"abc\" is not a fingerprint. A fingerprint is a SHA-256 in base64, " <>
                  "such as qUiQTy8PR5uPgZdpSzAYSw0u0cHNKh7A+4XSmaGSpEc=, or in hexadecimal.\n"}
    end
  end

  defp ca(name, key) do
    pem = TestCA.certificate(name, key)
    {:ok, key_sha256} = Ehosctl.DataCa.fingerprint(pem)
    %{certificate: pem, key_sha256: key_sha256}
  end

  defp answer_cas(provider, data, gateway),
    do:
      api(provider, "GET", "/api/v1/data-ca", 200, %{
        "dataCa" => given(data),
        "gatewayCa" => given(gateway)
      })

  defp given(%{certificate: pem, key_sha256: key_sha256}),
    do: %{"certificate" => pem, "keySha256" => key_sha256}

  defp stored(%{certificate: pem, key_sha256: key_sha256}),
    do: %{"certificate" => pem, "key_sha256" => key_sha256}

  defp kept_cas(opts) do
    {:ok, config} = Config.read(opts[:config_dir])
    installation = config.installations["local"]
    %{data: installation["data_ca"], gateway: installation["gateway_ca"]}
  end

  defp signed_in(provider),
    do:
      "Signed in to local (#{provider.issuer}) as grace@example.com, until " <>
        "31 October 2026, 12:00 UTC.\n"
end

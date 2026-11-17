defmodule Ehosctl.DbTest do
  use Ehosctl.SignInCase

  alias Ehosctl.TestCA

  @changed_gateway "ehosctl: local gives a gateway CA with another key than the one ehosctl " <>
                     "keeps, so ehosctl does not trust it, and refuses data sessions that use " <>
                     "it. If your installation's administrator told you that the key changed, " <>
                     "and gave you its fingerprint, run `ehosctl db trust-ca FINGERPRINT` with it.\n"

  @now ~U[2026-10-28 12:00:00Z]
  @session_id "6f1c2a9e-5b7d-4c1e-9a2f-3d4e5f6a7b8c"

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
      refute stderr =~ "ehosctl: "
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
      refute stderr =~ "ehosctl: "
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

  describe "db sessions" do
    setup %{provider: provider, opts: opts} do
      login!(provider, opts)
      :ok
    end

    test "lists the open data sessions of an application in an environment", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", "/api/v1/applications/ledger/environments/staging/sessions", 200, %{
        "sessions" => [Map.put(session(), "more", "not printed")]
      })

      {code, stdout, stderr} = ehosctl(["db", "sessions", "ledger", "--env", "staging"], opts)

      assert {code, stderr} == {0, ""}

      assert stdout ==
               """
                ID                                    APPLICATION  ENVIRONMENT  LEVEL  STATE  OPENED                      EXPIRES
                #{@session_id}  ledger       staging      read   open   28 October 2026, 12:00 UTC  28 October 2026, 13:00 UTC
               """
               |> String.split("\n")
               |> Enum.map_join("\n", &String.trim_trailing/1)

      {0, json, ""} = ehosctl(["db", "sessions", "ledger", "--env", "staging", "--json"], opts)
      assert JSON.decode!(json) == %{"sessions" => [session()]}
    end

    test "lists the person's own with --mine, and says when there are none", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", "/api/v1/sessions", 200, %{"sessions" => []})

      assert ehosctl(["db", "sessions", "--mine"], opts) ==
               {0,
                "You have no open data sessions. A data session shows here when you open one " <>
                  "with `ehosctl db connect` or `ehosctl db tunnel`.\n", ""}
    end

    test "says EHOS's refusal in its words", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/environments/production/sessions", 403, %{
        "error" => "forbidden",
        "message" => "You cannot open a data session on ledger in production."
      })

      assert ehosctl(["db", "sessions", "ledger", "--env", "production"], opts) ==
               {3, "", "ehosctl: You cannot open a data session on ledger in production.\n"}
    end

    test "needs an application with --env, or --mine alone", %{opts: opts} do
      both =
        "ehosctl: Give an application and --env, such as `ehosctl db sessions ledger --env " <>
          "staging`, or give --mine for your own data sessions.\n"

      assert ehosctl(["db", "sessions"], opts) == {2, "", both}
      assert ehosctl(["db", "sessions", "ledger"], opts) == {2, "", both}

      assert ehosctl(["db", "sessions", "ledger", "--env", "staging", "--mine"], opts) ==
               {2, "",
                "ehosctl: --mine lists your own data sessions everywhere. Give it without an " <>
                  "application or --env.\n"}
    end
  end

  describe "db end" do
    setup %{provider: provider, opts: opts} do
      login!(provider, opts)
      :ok
    end

    test "ends a data session", %{provider: provider, opts: opts} do
      api(provider, "DELETE", "/api/v1/sessions/#{@session_id}", 200, %{
        "session" => %{"id" => @session_id, "state" => "ended"}
      })

      assert ehosctl(["db", "end", @session_id], opts) ==
               {0, "Ended the data session #{@session_id}.\n", ""}

      {0, json, ""} = ehosctl(["db", "end", @session_id, "--json"], opts)
      assert JSON.decode!(json) == %{"session" => %{"id" => @session_id, "state" => "ended"}}
    end

    test "ends a data session whose ID is typed in upper case, as EHOS answers it", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "DELETE", "/api/v1/sessions/#{@session_id}", 200, %{
        "session" => %{"id" => @session_id, "state" => "ended"}
      })

      assert ehosctl(["db", "end", String.upcase(@session_id)], opts) ==
               {0, "Ended the data session #{@session_id}.\n", ""}
    end

    test "says EHOS's refusal of a session that already ended", %{provider: provider, opts: opts} do
      api(provider, "DELETE", "/api/v1/sessions/#{@session_id}", 409, %{
        "error" => "already_ended",
        "message" => "The data session already ended."
      })

      assert ehosctl(["db", "end", @session_id], opts) ==
               {1, "", "ehosctl: The data session already ended.\n"}
    end

    test "refuses what is not the ID of a session, and asks EHOS nothing", %{
      provider: provider,
      opts: opts
    } do
      assert ehosctl(["db", "end", "../me"], opts) ==
               {2, "",
                "ehosctl: ../me is not the ID of a data session. `ehosctl db sessions " <>
                  "--mine` shows the IDs of your data sessions.\n"}

      assert FakeProvider.requests(provider, "DELETE /api/v1/sessions/../me") == []
    end
  end

  defp session,
    do: %{
      "id" => @session_id,
      "application" => "ledger",
      "environment" => "staging",
      "level" => "read",
      "role" => "ehos_s_abcdefghijklmnopqrst",
      "state" => "open",
      "opened_at" => "2026-10-28T12:00:00Z",
      "expires_at" => "2026-10-28T13:00:00Z",
      "ended_at" => nil,
      "end_reason" => nil
    }

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

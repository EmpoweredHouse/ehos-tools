defmodule Ehosctl.LoginTest do
  use Ehosctl.SignInCase

  doctest Ehosctl.Login

  test "signs in through the browser, and keeps the sign-in", %{provider: provider, opts: opts} do
    {0, stdout, stderr} = ehosctl(["login", provider.issuer], opts)

    assert stdout =~ "Signed in to local (#{provider.issuer}) as grace@example.com, until "
    assert stderr =~ "Opening your browser to sign in to local (#{provider.issuer})."
    assert stderr =~ provider.issuer <> "/oauth/authorize?"

    {:ok, config} = Config.read(opts[:config_dir])
    assert config.current == "local"

    assert %{"url" => url, "sign_in" => sign_in} = config.installations["local"]
    assert url == provider.issuer
    assert sign_in["subject"] == "0b9f6c1e-person"
    assert sign_in["email"] == "grace@example.com"

    # The refresh token is in the keychain, the one EHOS has live, and nowhere in a file.
    [refresh_token] = MapSet.to_list(FakeProvider.refresh_tokens(provider))
    assert FakeKeychain.items(opts[:state_dir]) == [{"local", provider.issuer, refresh_token}]
    refute File.exists?(Path.join(opts[:state_dir], "local.token"))

    assert {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    assert session.store == :keychain
    assert %{token: "credential-" <> _} = session.credentials[provider.issuer]

    for file <- [opts[:config_dir], opts[:state_dir]] ++ Path.wildcard(opts[:state_dir] <> "/*") do
      expected = if File.dir?(file), do: 0o700, else: 0o600
      assert Bitwise.band(File.stat!(file).mode, 0o777) == expected, file
    end
  end

  test "asks for the code flow with PKCE, as EHOS's terminal client", %{
    provider: provider,
    opts: opts
  } do
    login!(provider, opts)

    assert_received {:authorization, params}
    assert params["response_type"] == "code"
    assert params["client_id"] == "ehosctl"
    assert params["scope"] == "openid email"
    assert params["max_age"] == "0"
    assert params["code_challenge_method"] == "S256"
    assert byte_size(params["state"]) >= 32 and byte_size(params["nonce"]) >= 32
    assert params["redirect_uri"] =~ ~r{\Ahttp://127\.0\.0\.1:\d+/callback\z}
    refute Map.has_key?(params, "prompt")
    refute Map.has_key?(params, "resource")

    # Redeemed with its verifier, and nothing that authenticates a client.
    [exchange] = FakeProvider.requests(provider, "/oauth/token")
    assert exchange["grant_type"] == "authorization_code"
    assert exchange["client_id"] == "ehosctl"
    assert exchange["redirect_uri"] == params["redirect_uri"]
    assert is_binary(exchange["code_verifier"])
    refute Map.has_key?(exchange, "client_secret")
    refute Map.has_key?(exchange, "client_assertion")
  end

  test "--json prints the sign-in", %{provider: provider, opts: opts} do
    {0, stdout, _stderr} = ehosctl(["login", provider.issuer, "--json"], opts)

    assert %{
             "installation" => "local",
             "url" => url,
             "subject" => "0b9f6c1e-person",
             "email" => "grace@example.com",
             "until" => until
           } = JSON.decode!(stdout)

    assert url == provider.issuer

    # As whoami says it: three days unrenewed, before the seven days from the sign-in.
    {:ok, until, 0} = DateTime.from_iso8601(until)
    assert DateTime.diff(until, DateTime.utc_now()) in (3 * 86_400 - 5)..(3 * 86_400 + 5)

    {0, text, _stderr} = ehosctl(["login"], opts)
    assert text =~ "until #{Ehosctl.Output.date(DateTime.add(DateTime.utc_now(), 3 * 86_400))}"
    {0, whoami, _stderr} = ehosctl(["whoami", "--json"], opts)
    assert JSON.decode!(whoami)["until"] == DateTime.to_iso8601(until)
  end

  test "refuses an ID token whose auth_time is no time there is", %{
    provider: provider,
    opts: opts
  } do
    FakeProvider.put_id_token_claims(provider, %{"auth_time" => 999_999_999_999_999_999})

    assert {1, "", stderr} = ehosctl(["login", provider.issuer], opts)
    assert stderr =~ "says you signed in at no time there is"
  end

  test "keeps the CA EHOSCTL_CA_FILE names beside the installation, and trusts it again (T-14)",
       %{provider: provider, opts: opts, tmp_dir: dir} do
    [ca, other] =
      for name <- ["EHOS CA", "Another CA"] do
        %{cert: der} = :public_key.pkix_test_root_cert(String.to_charlist(name), [])
        :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
      end

    file = Path.join(dir, "ca.crt")
    File.write!(file, "the installation's CA\n" <> ca)
    with_ca = Keyword.put(opts, :env, %{"EHOSCTL_CA_FILE" => file})

    login!(provider, with_ca)
    assert kept(opts) == ca

    # Signing in again without the variable keeps it; with another CA, that one replaces it.
    File.rm!(file)
    {0, _stdout, _stderr} = ehosctl(["login"], opts)
    assert kept(opts) == ca

    File.write!(file, other)
    login!(provider, with_ca)
    assert kept(opts) == other
  end

  test "without the variable, signs in trusting the CA kept for the installation, and not with it",
       %{provider: provider, opts: opts} do
    # A CA that does not decode is refused when it is trusted, so the refusal shows which is.
    :ok =
      Config.write(
        %Config{
          current: "local",
          installations: %{"local" => %{"url" => provider.issuer, "ca" => "not a certificate"}}
        },
        opts[:config_dir]
      )

    assert {1, "", stderr} = ehosctl(["login"], opts)
    assert stderr =~ "the CA ehosctl keeps for local holds no certificate it can read"
    assert kept(opts) == "not a certificate"

    file = Path.join(Path.dirname(opts[:config_dir]), "ca.crt")
    %{cert: der} = :public_key.pkix_test_root_cert(~c"EHOS CA", [])
    File.write!(file, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))

    {0, _stdout, _stderr} =
      ehosctl(["login"], Keyword.put(opts, :env, %{"EHOSCTL_CA_FILE" => file}))

    assert kept(opts) == File.read!(file)
  end

  test "keeps no CA from a sign-in that did not finish", %{provider: provider, opts: opts} do
    file = Path.join(Path.dirname(opts[:config_dir]), "ca.crt")
    %{cert: der} = :public_key.pkix_test_root_cert(~c"EHOS CA", [])
    File.write!(file, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))

    opts =
      opts
      |> Keyword.merge(open_browser: fn _url -> :ok end, timeout: 100)
      |> Keyword.put(:env, %{"EHOSCTL_CA_FILE" => file})

    assert {1, "", _stderr} = ehosctl(["login", provider.issuer], opts)
    assert Config.read(opts[:config_dir]) == {:ok, %Config{}}
  end

  test "drops the CA kept for a name that moves to another address", %{
    provider: provider,
    opts: opts
  } do
    :ok =
      Config.write(
        %Config{
          installations: %{"local" => %{"url" => "https://ehos.example.com", "ca" => "pem"}}
        },
        opts[:config_dir]
      )

    login!(provider, opts, ["--installation", "local"])
    assert kept(opts) == nil
  end

  defp kept(opts, name \\ "local") do
    {:ok, config} = Config.read(opts[:config_dir])
    config.installations[name]["ca"]
  end

  test "names the installation with --installation", %{provider: provider, opts: opts} do
    login!(provider, opts, ["--installation", "dev"])

    {:ok, config} = Config.read(opts[:config_dir])
    assert config.current == "dev"
    assert Map.keys(config.installations) == ["dev"]
  end

  test "without a URL, signs in again to the current installation", %{
    provider: provider,
    opts: opts
  } do
    login!(provider, opts)
    {0, stdout, _stderr} = ehosctl(["login"], opts)
    assert stdout =~ "Signed in to local"

    # The first sign-in's token was replaced in the keychain.
    assert [{"local", _url, token}] = FakeKeychain.items(opts[:state_dir])
    assert MapSet.member?(FakeProvider.refresh_tokens(provider), token)
  end

  test "without a URL or a current installation, says to name one", %{opts: opts} do
    assert {2, "", stderr} = ehosctl(["login"], opts)
    assert stderr =~ "ehosctl login URL"
  end

  test "keeps a name that is another installation's for it", %{provider: provider, opts: opts} do
    :ok =
      Config.write(
        %Config{installations: %{"local" => %{"url" => "https://ehos.example.com"}}},
        opts[:config_dir]
      )

    assert {2, "", stderr} = ehosctl(["login", provider.issuer], opts)
    assert stderr =~ "an installation named local is at https://ehos.example.com"
    assert stderr =~ "--installation NAME"
  end

  test "refuses an address that is not an installation's", %{opts: opts} do
    for url <- [
          "http://ehos.example.com",
          "https://ehos.example.com/console",
          "https://ehos.example.com?x=1",
          "https://user@ehos.example.com",
          "ftp://ehos.example.com",
          "https://ehos.example.com\e[2J",
          "ehos.example.com"
        ] do
      assert {2, "", _stderr} = ehosctl(["login", url], Keyword.delete(opts, :allow_http)), url
    end
  end

  test "keeps the token in a file, saying so, where EHOSCTL_TOKEN_STORE asks", %{
    provider: provider,
    opts: opts
  } do
    login!(provider, Keyword.put(opts, :env, %{"EHOSCTL_TOKEN_STORE" => "file"}))

    file = Path.join(opts[:state_dir], "local.token")
    assert_received {:warn, warning}
    assert warning =~ "kept in #{file}, which only you can read (EHOSCTL_TOKEN_STORE=file)"
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert MapSet.member?(FakeProvider.refresh_tokens(provider), File.read!(file))
    assert FakeKeychain.items(opts[:state_dir]) == []
  end

  test "keeps the token in a file where there is no keychain", %{provider: provider, opts: opts} do
    login!(provider, Keyword.put(opts, :keychain, nil))

    assert_received {:warn, warning}
    assert warning =~ "no system keychain was found"
    assert File.exists?(Path.join(opts[:state_dir], "local.token"))
  end

  test "keeps the token in a file when the keychain does not take it", %{
    provider: provider,
    opts: opts
  } do
    login!(provider, Keyword.put(opts, :keychain, Ehosctl.LockedKeychain))

    assert_received {:warn, warning}
    assert warning =~ "the keychain is locked, so it is kept in"
    assert {:ok, %{store: :file}} = TokenStore.read(opts[:state_dir], "local")
  end

  test "a sign-in moved to a file forgets its keychain item", %{provider: provider, opts: opts} do
    login!(provider, opts)
    assert [_item] = FakeKeychain.items(opts[:state_dir])

    login!(provider, Keyword.put(opts, :env, %{"EHOSCTL_TOKEN_STORE" => "file"}))
    assert FakeKeychain.items(opts[:state_dir]) == []
  end

  for store <- ["keychain", "file"] do
    test "an installation signed in to at a new address ends the old sign-in (#{store})", %{
      provider: old,
      opts: opts
    } do
      opts = Keyword.put(opts, :env, %{"EHOSCTL_TOKEN_STORE" => unquote(store)})
      login!(old, opts, ["--installation", "staging"])
      [old_token] = MapSet.to_list(FakeProvider.refresh_tokens(old))

      new = FakeProvider.start()
      opts = Keyword.put(opts, :open_browser, FakeProvider.browser(new))
      lock = TokenStore.path(opts[:state_dir], "staging", "lock")
      test = self()
      FakeProvider.on_revoke(old, fn -> send(test, {:locked, File.exists?(lock)}) end)
      login!(new, opts, ["--installation", "staging"])

      # Not under the lock, which a renewal of the new sign-in would wait on.
      assert_received {:locked, false}

      # Ended at the old address, and the new token is the one kept.
      assert [%{"token" => ^old_token}] = FakeProvider.requests(old, "/oauth/revoke")
      {:ok, config} = Config.read(opts[:config_dir])
      installation = {"staging", config.installations["staging"]}
      {:ok, session} = TokenStore.read(opts[:state_dir], "staging")

      :ok =
        TokenStore.write(opts[:state_dir], "staging", %{session | credentials: %{}})

      assert {:ok, _credential} = Ehosctl.Credentials.fetch(installation, :ehos, opts)
    end
  end

  test "ends the old sign-in trusting the CA kept for the old address, not the new one's", %{
    provider: old,
    opts: opts
  } do
    login!(old, opts, ["--installation", "staging"])

    # A CA that does not decode is refused when it is trusted, so the warning shows which is.
    {:ok, config} = Config.read(opts[:config_dir])

    :ok =
      config |> Config.put_ca("staging", "not a certificate") |> Config.write(opts[:config_dir])

    new = FakeProvider.start()

    login!(new, Keyword.put(opts, :open_browser, FakeProvider.browser(new)), [
      "--installation",
      "staging"
    ])

    assert_received {:warn, warning}
    assert warning =~ "the sign-in to #{old.issuer}, which this one replaces, was not ended"
    assert warning =~ "the CA ehosctl keeps for staging holds no certificate"
    assert kept(opts, "staging") == nil
  end

  test "ends the old sign-in trusting no CA kept for another address than the old one", %{
    provider: old,
    opts: opts
  } do
    login!(old, opts, ["--installation", "staging"])

    # config.json moved on, as one synced from elsewhere can, while this machine's sign-in did not.
    {:ok, config} = Config.read(opts[:config_dir])

    :ok =
      config
      |> Config.put("staging", "https://ehos.elsewhere.example.com")
      |> Config.put_ca("staging", "not a certificate")
      |> Config.write(opts[:config_dir])

    new = FakeProvider.start()

    login!(new, Keyword.put(opts, :open_browser, FakeProvider.browser(new)), [
      "--installation",
      "staging"
    ])

    refute_received {:warn, _warning}
    assert [_revoked] = FakeProvider.requests(old, "/oauth/revoke")
  end

  test "a caller of keep/5 that names no CA leaves the installation's", %{
    provider: provider,
    opts: opts
  } do
    login!(provider, opts)
    {:ok, config} = Config.read(opts[:config_dir])
    :ok = config |> Config.put_ca("local", "pem") |> Config.write(opts[:config_dir])
    {:ok, session} = TokenStore.read(opts[:state_dir], "local")

    tokens = %{
      claims: %{"sub" => "0b9f6c1e-person", "email" => "grace@example.com", "auth_time" => 1},
      credential: "credential",
      expires_in: 600,
      refresh_token: "refresh"
    }

    endpoints = %{token: session.endpoints["token"], revocation: nil}

    assert {:ok, _sign_in} =
             Ehosctl.Credentials.keep("local", provider.issuer, tokens, endpoints, opts)

    assert kept(opts) == "pem"
  end

  test "waits past a callback that is not its own", %{provider: provider, opts: opts} do
    opts =
      Keyword.put(
        opts,
        :open_browser,
        FakeProvider.browser(provider, before: %{"state" => "forged", "code" => "c"})
      )

    assert {0, _stdout, _stderr} = ehosctl(["login", provider.issuer], opts)
  end

  test "refuses an answer that names another issuer", %{provider: provider, opts: opts} do
    opts = Keyword.put(opts, :open_browser, FakeProvider.browser(provider, iss: "https://evil"))

    assert {1, "", stderr} = ehosctl(["login", provider.issuer], opts)
    assert stderr =~ "did not come from #{provider.issuer}"
    assert FakeProvider.requests(provider, "/oauth/token") == []
  end

  test "refuses an answer without the issuer (RFC 9207)", %{provider: provider, opts: opts} do
    opts = Keyword.put(opts, :open_browser, FakeProvider.browser(provider, iss: nil))
    assert {1, "", _stderr} = ehosctl(["login", provider.issuer], opts)
  end

  test "says EHOS refused when it sends an error back", %{provider: provider, opts: opts} do
    opts =
      Keyword.put(
        opts,
        :open_browser,
        FakeProvider.browser(provider, code: nil, error: "access_denied")
      )

    assert {3, "", stderr} = ehosctl(["login", provider.issuer], opts)
    assert stderr =~ "EHOS did not sign you in (access_denied)"
  end

  test "refuses an ID token for another nonce", %{provider: provider, opts: opts} do
    FakeProvider.put_id_token_claims(provider, %{"nonce" => "another"})

    assert {1, "", _stderr} = ehosctl(["login", provider.issuer], opts)
    assert FakeKeychain.items(opts[:state_dir]) == []
    assert {:ok, %Config{installations: installations}} = Config.read(opts[:config_dir])
    assert installations == %{}
  end

  test "refuses an ID token signed by a key EHOS does not publish", %{
    provider: provider,
    opts: opts
  } do
    FakeProvider.sign_with_another_key(provider)

    assert {1, "", stderr} = ehosctl(["login", provider.issuer], opts)
    assert stderr =~ "did not pass a sign-in's checks"
    assert FakeKeychain.items(opts[:state_dir]) == []
  end

  test "gives up when the browser does not come back", %{provider: provider, opts: opts} do
    opts = opts |> Keyword.put(:open_browser, fn _url -> :ok end) |> Keyword.put(:timeout, 100)

    assert {1, "", stderr} = ehosctl(["login", provider.issuer], opts)
    assert stderr =~ "not finished in the browser in time"
  end

  test "says when EHOS stops answering between discovery and the exchange", %{
    provider: provider,
    opts: opts
  } do
    browser = FakeProvider.browser(provider)

    opts =
      Keyword.put(opts, :open_browser, fn url ->
        FakeProvider.down(provider)
        browser.(url)
      end)

    assert {5, "", stderr} = ehosctl(["login", provider.issuer], opts)
    assert stderr =~ "#{provider.issuer} did not answer."
  end

  test "says when EHOS does not answer", %{provider: provider, opts: opts} do
    FakeProvider.down(provider)
    assert {5, "", stderr} = ehosctl(["login", provider.issuer], opts)
    assert stderr =~ "#{provider.issuer} did not answer."
  end

  test "refuses a provider whose endpoints are elsewhere than its issuer", %{
    provider: provider,
    opts: opts
  } do
    for {field, endpoint} <- [
          {"authorization_endpoint", "https://evil.example.com/oauth/authorize"},
          {"token_endpoint", String.replace(provider.issuer, "localhost", "127.0.0.1") <> "/t"},
          {"revocation_endpoint", "https://ehos.example.com\e[2J/oauth/revoke"},
          # A browser reads a backslash as a slash: this is evil.example to it.
          {"authorization_endpoint",
           String.replace(provider.issuer, "//", "//evil.example\\@") <> "/oauth/authorize"}
        ] do
      FakeProvider.put_discovery(provider, %{field => endpoint})

      assert {1, "", stderr} = ehosctl(["login", provider.issuer], opts)
      assert stderr =~ "names an endpoint that is not https on #{provider.issuer} itself", field
      refute_received {:authorization, _params}
    end
  end

  test "refuses an address whose discovery names another issuer", %{
    provider: provider,
    opts: opts
  } do
    url = String.replace(provider.issuer, "localhost", "127.0.0.1")
    assert {1, "", stderr} = ehosctl(["login", url], opts)
    assert stderr =~ "names #{provider.issuer} as its issuer"
  end
end

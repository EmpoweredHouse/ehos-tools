defmodule Ehosctl.LoginTest do
  use Ehosctl.SignInCase

  doctest Ehosctl.Login

  # The time `ehosctl` reads, and the one EHOS says the person signed in at, so a sign-in's
  # until is known: three days unrenewed, before the seven from the sign-in.
  @now ~U[2026-10-28 12:00:00Z]

  @not_finished "ehosctl: the sign-in was not finished in the browser in time; " <>
                  "run `ehosctl login` again\n"

  setup %{provider: provider} do
    stub_now(@now)
    FakeProvider.put_id_token_claims(provider, %{"auth_time" => DateTime.to_unix(@now)})
  end

  test "signs in through the browser, and keeps the sign-in", %{provider: provider, opts: opts} do
    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)

    assert {code, stdout} == {0, signed_in(provider)}
    assert stderr =~ opening(provider)

    assert Config.read(opts[:config_dir]) ==
             {:ok,
              %Config{
                current: "local",
                installations: %{"local" => installation(provider)}
              }}

    # The refresh token is in the keychain, the one EHOS has live, and nowhere in a file.
    [refresh_token] = MapSet.to_list(FakeProvider.refresh_tokens(provider))
    assert FakeKeychain.items(opts[:state_dir]) == [{"local", provider.issuer, refresh_token}]
    refute File.exists?(Path.join(opts[:state_dir], "local.token"))

    # EHOS's API's credential, kept for its ten minutes, is new to each sign-in.
    {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    %{token: "credential-" <> _ = credential} = session.credentials[provider.issuer]

    assert session == kept_session(provider, :keychain, credential)

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

    # The state, the nonce, the challenge and the port are new to each sign-in.
    assert %{
             "state" => state,
             "nonce" => nonce,
             "code_challenge" => challenge,
             "redirect_uri" => redirect_uri
           } = params

    assert params == %{
             "response_type" => "code",
             "client_id" => "ehosctl",
             "scope" => "openid email",
             "max_age" => "0",
             "code_challenge_method" => "S256",
             "code_challenge" => challenge,
             "state" => state,
             "nonce" => nonce,
             "redirect_uri" => redirect_uri
           }

    assert byte_size(state) >= 32 and byte_size(nonce) >= 32
    assert redirect_uri =~ ~r{\Ahttp://127\.0\.0\.1:\d+/callback\z}

    # Redeemed with the verifier of its challenge, at the address the browser came back to.
    assert [%{code: "code-" <> _, verifier: verifier, redirect_uri: ^redirect_uri}] =
             FakeProvider.calls(provider, :exchange)

    assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge
  end

  test "--json prints the sign-in", %{provider: provider, opts: opts} do
    {code, stdout, stderr} = ehosctl(["login", provider.issuer, "--json"], opts)

    assert code == 0
    assert stderr =~ opening(provider)

    assert JSON.decode!(stdout) == login_json(provider, "2026-10-31T12:00:00Z")

    # Signing in again makes a new sign-in, which may end a second or more later than the first
    # (ehos-tools#257): whoami says the until of the one it reports, to the second.
    stub_now(DateTime.add(@now, 90))
    {code, again, stderr} = ehosctl(["login", "--json"], opts)
    assert code == 0
    assert stderr =~ opening(provider)
    assert JSON.decode!(again) == login_json(provider, "2026-10-31T12:01:30Z")

    {code, whoami, stderr} = ehosctl(["whoami", "--json"], opts)
    assert {code, stderr} == {0, ""}
    assert JSON.decode!(whoami) == whoami(provider, "2026-10-31T12:01:30Z")

    stub_now(DateTime.add(@now, 180))
    {code, stdout, stderr} = ehosctl(["login"], opts)

    assert {code, stdout} ==
             {0,
              "Signed in to local (#{provider.issuer}) as grace@example.com, until " <>
                "31 October 2026, 12:03 UTC.\n"}

    assert stderr =~ opening(provider)
    {code, whoami, stderr} = ehosctl(["whoami", "--json"], opts)
    assert {code, stderr} == {0, ""}
    assert JSON.decode!(whoami) == whoami(provider, "2026-10-31T12:03:00Z")
  end

  test "keeps the CA EHOSCTL_CA_FILE names beside the installation, and trusts it again (T-14)",
       %{provider: provider, opts: opts, tmp_dir: dir} do
    [ca, other] = Enum.map(["EHOS CA", "Another CA"], &certificate/1)

    file = Path.join(dir, "ca.crt")
    File.write!(file, "the installation's CA\n" <> ca)
    stub_env(%{"EHOSCTL_CA_FILE" => file})

    login!(provider, opts)
    assert kept(opts) == ca

    # Signing in again without the variable keeps it; with another CA, that one replaces it.
    File.rm!(file)
    stub_env(%{})
    {code, stdout, stderr} = ehosctl(["login"], opts)
    assert {code, stdout} == {0, signed_in(provider)}
    assert stderr =~ opening(provider)
    assert kept(opts) == ca

    File.write!(file, other)
    stub_env(%{"EHOSCTL_CA_FILE" => file})
    login!(provider, opts)
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

    assert ehosctl(["login"], opts) ==
             {1, "",
              "ehosctl: the CA ehosctl keeps for local holds no certificate it can read; sign in to " <>
                "local again with EHOSCTL_CA_FILE set to the installation's CA\n"}

    assert kept(opts) == "not a certificate"

    file = Path.join(Path.dirname(opts[:config_dir]), "ca.crt")
    File.write!(file, certificate("EHOS CA"))
    stub_env(%{"EHOSCTL_CA_FILE" => file})

    {code, stdout, stderr} = ehosctl(["login"], opts)
    assert {code, stdout} == {0, signed_in(provider)}
    assert stderr =~ opening(provider)
    assert kept(opts) == File.read!(file)
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

  test "names the installation with --installation", %{provider: provider, opts: opts} do
    assert login!(provider, opts, ["--installation", "dev"]) == signed_in(provider, "dev")

    assert Config.read(opts[:config_dir]) ==
             {:ok, %Config{current: "dev", installations: %{"dev" => installation(provider)}}}
  end

  test "without a URL, signs in again to the current installation", %{
    provider: provider,
    opts: opts
  } do
    login!(provider, opts)
    [first] = MapSet.to_list(FakeProvider.refresh_tokens(provider))
    {code, stdout, stderr} = ehosctl(["login"], opts)
    assert {code, stdout} == {0, signed_in(provider)}
    assert stderr =~ opening(provider)

    # The first sign-in's token was replaced in the keychain.
    [token] = MapSet.to_list(FakeProvider.refresh_tokens(provider)) -- [first]
    assert FakeKeychain.items(opts[:state_dir]) == [{"local", provider.issuer, token}]
  end

  test "keeps the token in a file, saying so, where EHOSCTL_TOKEN_STORE asks", %{
    provider: provider,
    opts: opts
  } do
    stub_env(%{"EHOSCTL_TOKEN_STORE" => "file"})
    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)

    file = Path.join(opts[:state_dir], "local.token")
    assert {code, stdout} == {0, signed_in(provider)}

    assert stderr =~
             opening(
               provider,
               "ehosctl: your sign-in is kept in #{file}, which only you can read " <>
                 "(EHOSCTL_TOKEN_STORE=file).\n"
             )

    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert MapSet.to_list(FakeProvider.refresh_tokens(provider)) == [File.read!(file)]
    assert FakeKeychain.items(opts[:state_dir]) == []
  end

  test "keeps the token in a file where there is no keychain", %{provider: provider, opts: opts} do
    mock_keychain_backend(nil)
    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)

    assert {code, stdout} == {0, signed_in(provider)}

    assert stderr =~
             opening(
               provider,
               "ehosctl: no system keychain was found, so your sign-in is kept in " <>
                 "#{opts[:state_dir]}/local.token, which only you can read.\n"
             )

    assert MapSet.to_list(FakeProvider.refresh_tokens(provider)) ==
             [File.read!(Path.join(opts[:state_dir], "local.token"))]
  end

  test "keeps the token in a file when the keychain does not take it", %{
    provider: provider,
    opts: opts
  } do
    mock_keychain_backend(Ehosctl.LockedKeychain)
    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)

    assert {code, stdout} == {0, signed_in(provider)}

    assert stderr =~
             opening(
               provider,
               "ehosctl: cannot keep your sign-in: the keychain is locked, so it is kept in " <>
                 "#{opts[:state_dir]}/local.token, which only you can read.\n"
             )

    {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    %{token: "credential-" <> _ = credential} = session.credentials[provider.issuer]
    assert session == kept_session(provider, :file, credential)
  end

  test "a sign-in moved to a file forgets its keychain item", %{provider: provider, opts: opts} do
    login!(provider, opts)
    [token] = MapSet.to_list(FakeProvider.refresh_tokens(provider))
    assert FakeKeychain.items(opts[:state_dir]) == [{"local", provider.issuer, token}]

    stub_env(%{"EHOSCTL_TOKEN_STORE" => "file"})
    login!(provider, opts)
    assert FakeKeychain.items(opts[:state_dir]) == []
  end

  for store <- ["keychain", "file"] do
    test "an installation signed in to at a new address ends the old sign-in (#{store})", %{
      provider: old,
      opts: opts
    } do
      stub_env(%{"EHOSCTL_TOKEN_STORE" => unquote(store)})
      login!(old, opts, ["--installation", "staging"])
      [old_token] = MapSet.to_list(FakeProvider.refresh_tokens(old))

      new = start_provider()
      lock = TokenStore.path(opts[:state_dir], "staging", "lock")
      test = self()
      FakeProvider.on_revoke(old, fn -> send(test, {:locked, File.exists?(lock)}) end)
      login!(new, opts, ["--installation", "staging"])

      # Not under the lock, which a renewal of the new sign-in would wait on.
      assert_received {:locked, false}

      # Ended at the old address, and the new token is the one kept.
      endpoint = old.issuer <> "/oauth/revoke"
      assert [%{endpoint: ^endpoint, token: ^old_token}] = FakeProvider.calls(old, :revoke)
      {:ok, config} = Config.read(opts[:config_dir])
      installation = {"staging", config.installations["staging"]}
      {:ok, session} = TokenStore.read(opts[:state_dir], "staging")

      :ok =
        TokenStore.write(opts[:state_dir], "staging", %{session | credentials: %{}})

      assert {:ok, "credential-" <> _} = Ehosctl.Credentials.fetch(installation, :ehos, opts)
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

    new = start_provider()
    {code, stdout, stderr} = ehosctl(["login", new.issuer, "--installation", "staging"], opts)

    assert {code, stdout} == {0, signed_in(new, "staging")}

    assert stderr =~
             opening(
               new,
               "ehosctl: the sign-in to #{old.issuer}, which this one replaces, was not ended " <>
                 "there (the CA ehosctl keeps for staging holds no certificate it can read; sign " <>
                 "in to staging again with EHOSCTL_CA_FILE set to the installation's CA); it " <>
                 "ends by itself, at the latest three days from its last use.\n",
               "staging"
             )

    assert kept(opts, "staging") == nil
  end

  test "ends the old sign-in trusting no CA kept for another address than the old one", %{
    provider: old,
    opts: opts
  } do
    login!(old, opts, ["--installation", "staging"])
    [old_token] = MapSet.to_list(FakeProvider.refresh_tokens(old))

    # config.json moved on, as one synced from elsewhere can, while this machine's sign-in did not.
    {:ok, config} = Config.read(opts[:config_dir])

    :ok =
      config
      |> Config.put("staging", "https://ehos.elsewhere.example.com")
      |> Config.put_ca("staging", "not a certificate")
      |> Config.write(opts[:config_dir])

    new = start_provider()
    {code, stdout, stderr} = ehosctl(["login", new.issuer, "--installation", "staging"], opts)

    assert {code, stdout} == {0, signed_in(new, "staging")}
    # Ended, with nothing to say of it.
    assert stderr =~ opening(new, "", "staging")
    endpoint = old.issuer <> "/oauth/revoke"
    assert [%{endpoint: ^endpoint, token: ^old_token}] = FakeProvider.calls(old, :revoke)
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

    assert Ehosctl.Credentials.keep("local", provider.issuer, tokens, endpoints, opts) ==
             {:ok,
              %{
                "subject" => "0b9f6c1e-person",
                "email" => "grace@example.com",
                "signed_in_at" => "1970-01-01T00:00:01Z",
                "expires_at" => "1970-01-08T00:00:01Z"
              }, ~U[1970-01-08 00:00:01Z]}

    assert kept(opts) == "pem"
  end

  test "waits past a callback that is not its own", %{provider: provider, opts: opts} do
    stub_browser(FakeProvider.browser(provider, before: %{"state" => "forged", "code" => "c"}))

    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)
    assert {code, stdout} == {0, signed_in(provider)}
    assert stderr =~ opening(provider)
  end

  test "refuses an ID token whose auth_time is no time there is", %{
    provider: provider,
    opts: opts
  } do
    FakeProvider.put_id_token_claims(provider, %{"auth_time" => 999_999_999_999_999_999})

    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)
    assert {code, stdout} == {1, ""}

    assert stderr =~
             opening(
               provider,
               "ehosctl: EHOS's ID token says you signed in at no time there is\n"
             )
  end

  test "keeps no CA from a sign-in that did not finish", %{provider: provider, opts: opts} do
    file = Path.join(Path.dirname(opts[:config_dir]), "ca.crt")
    File.write!(file, certificate("EHOS CA"))

    stub_browser(fn _url -> :ok end)
    opts = Keyword.put(opts, :timeout, 100)
    stub_env(%{"EHOSCTL_CA_FILE" => file})

    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)
    assert {code, stdout} == {1, ""}
    assert stderr =~ opening(provider, @not_finished)
    assert Config.read(opts[:config_dir]) == {:ok, %Config{}}
  end

  test "without a URL or a current installation, says to name one", %{opts: opts} do
    assert ehosctl(["login"], opts) ==
             {2, "",
              "ehosctl: no installation is current; sign in to one first; name the " <>
                "installation's address: ehosctl login URL\n"}
  end

  test "keeps a name that is another installation's for it", %{provider: provider, opts: opts} do
    :ok =
      Config.write(
        %Config{installations: %{"local" => %{"url" => "https://ehos.example.com"}}},
        opts[:config_dir]
      )

    assert ehosctl(["login", provider.issuer], opts) ==
             {2, "",
              "ehosctl: an installation named local is at https://ehos.example.com; name this one " <>
                "with --installation NAME\n"}
  end

  test "refuses an address that is not an installation's", %{opts: opts} do
    for {url, stderr} <- [
          {"http://ehos.example.com",
           "ehosctl: http://ehos.example.com is plain HTTP; EHOS signs people in over https only\n"},
          {"https://ehos.example.com/console",
           not_an_address(~s("https://ehos.example.com/console"))},
          {"https://ehos.example.com?x=1", not_an_address(~s("https://ehos.example.com?x=1"))},
          {"https://user@ehos.example.com", not_an_address(~s("https://user@ehos.example.com"))},
          {"ftp://ehos.example.com", not_an_address(~s("ftp://ehos.example.com"))},
          {"https://ehos.example.com\e[2J", not_an_address(~S("https://ehos.example.com\e[2J"))},
          {"ehos.example.com", not_an_address(~s("ehos.example.com"))}
        ] do
      assert ehosctl(["login", url], opts) == {2, "", stderr}, url
    end
  end

  test "refuses an answer that names another issuer", %{provider: provider, opts: opts} do
    stub_browser(FakeProvider.browser(provider, iss: "https://evil"))

    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)
    assert {code, stdout} == {1, ""}

    assert stderr =~
             opening(
               provider,
               "ehosctl: the answer to this sign-in did not come from #{provider.issuer}\n"
             )

    assert FakeProvider.calls(provider, :exchange) == []
  end

  test "refuses an answer without the issuer (RFC 9207)", %{provider: provider, opts: opts} do
    stub_browser(FakeProvider.browser(provider, iss: nil))

    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)
    assert {code, stdout} == {1, ""}

    assert stderr =~
             opening(
               provider,
               "ehosctl: the answer to this sign-in did not come from #{provider.issuer}\n"
             )
  end

  test "says EHOS refused when it sends an error back", %{provider: provider, opts: opts} do
    stub_browser(FakeProvider.browser(provider, code: nil, error: "access_denied"))

    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)
    assert {code, stdout} == {3, ""}
    assert stderr =~ opening(provider, "ehosctl: EHOS did not sign you in (access_denied)\n")
  end

  test "gives up when the browser does not come back", %{provider: provider, opts: opts} do
    stub_browser(fn _url -> :ok end)
    opts = Keyword.put(opts, :timeout, 100)

    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)
    assert {code, stdout} == {1, ""}
    assert stderr =~ opening(provider, @not_finished)
  end

  test "says when EHOS stops answering between discovery and the exchange", %{
    provider: provider,
    opts: opts
  } do
    browser = FakeProvider.browser(provider)

    stub_browser(fn url ->
      FakeProvider.down(provider)
      browser.(url)
    end)

    {code, stdout, stderr} = ehosctl(["login", provider.issuer], opts)
    assert {code, stdout} == {5, ""}
    assert stderr =~ opening(provider, "ehosctl: #{provider.issuer} did not answer.\n")
  end

  test "says when EHOS does not answer", %{provider: provider, opts: opts} do
    FakeProvider.down(provider)

    assert ehosctl(["login", provider.issuer], opts) ==
             {5, "", "ehosctl: #{provider.issuer} did not answer.\n"}
  end

  # What `login` prints of a sign-in to `name` at `provider` that lasts until `@now` and three
  # days.
  defp signed_in(provider, name \\ "local") do
    "Signed in to #{name} (#{provider.issuer}) as grace@example.com, until " <>
      "31 October 2026, 12:00 UTC.\n"
  end

  defp not_an_address(quoted),
    do: "ehosctl: #{quoted} is not an installation's address, such as https://ehos.example.com\n"

  # What `config.json` keeps of an installation at `provider` signed in to at `@now`.
  defp installation(provider) do
    %{
      "url" => provider.issuer,
      "sign_in" => %{
        "subject" => "0b9f6c1e-person",
        "email" => "grace@example.com",
        "signed_in_at" => "2026-10-28T12:00:00Z",
        "expires_at" => "2026-11-04T12:00:00Z"
      }
    }
  end

  # What the state directory keeps of a sign-in to `provider` at `@now`, in `store`, with
  # `credential` for EHOS's API until ten minutes later.
  defp kept_session(provider, store, credential) do
    %{
      url: provider.issuer,
      store: store,
      renewed_at: @now,
      endpoints: %{
        "token" => provider.issuer <> "/oauth/token",
        "revocation" => provider.issuer <> "/oauth/revoke"
      },
      credentials: %{
        provider.issuer => %{token: credential, expires_at: DateTime.add(@now, 600)}
      }
    }
  end

  # What `login --json` prints of a sign-in to `provider` that lasts `until`.
  defp login_json(provider, until) do
    %{
      "installation" => "local",
      "url" => provider.issuer,
      "subject" => "0b9f6c1e-person",
      "email" => "grace@example.com",
      "until" => until
    }
  end

  # What `whoami --json` says of that sign-in, made at `@now`.
  defp whoami(provider, until) do
    provider |> login_json(until) |> Map.put("signed_in_at", "2026-10-28T12:00:00Z")
  end

  # What `login` says on stderr when it opens the browser, followed by `then`: the URL it opens
  # holds a state, a nonce, a challenge and a port new to each sign-in.
  defp opening(provider, then \\ "", name \\ "local") do
    opening =
      "Opening your browser to sign in to #{name} (#{provider.issuer}).\n" <>
        "If it does not open, go to:\n\n  #{provider.issuer}/oauth/authorize?"

    ~r/\A#{Regex.escape(opening)}\S+\n\n#{Regex.escape(then)}\z/
  end

  # Another installation's EHOS, which the browser signs in to, at `@now`.
  defp start_provider do
    provider = FakeProvider.start(auth_time: DateTime.to_unix(@now))
    stub_browser(FakeProvider.browser(provider))
    provider
  end

  defp certificate(name) do
    %{cert: der} = :public_key.pkix_test_root_cert(String.to_charlist(name), [])
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  defp kept(opts, name \\ "local") do
    {:ok, config} = Config.read(opts[:config_dir])
    config.installations[name]["ca"]
  end

  defp mock_keychain_backend(backend),
    do: stub(Ehosctl.SystemKeychainMock, :backend, fn -> backend end)
end

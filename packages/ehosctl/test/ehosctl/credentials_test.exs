defmodule Ehosctl.CredentialsTest do
  # Not async, through `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process
  # shares.
  use Ehosctl.SignInCase

  alias Ehosctl.Credentials
  alias Ehosctl.HTTP

  @expired "Your sign-in has expired. Run `ehosctl login`."

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    {:ok, config} = Config.read(opts[:config_dir])
    %{installation: {"local", config.installations["local"]}}
  end

  describe "fetch/3" do
    test "a credential cached by login is used without renewing", ctx do
      assert Credentials.fetch(ctx.installation, :ehos, ctx.opts) ==
               {:ok, cached(ctx.opts, ctx.provider.issuer)}

      assert renewals(ctx.provider) == []
    end

    test "renews for EHOS's API, naming its issuer, and keeps the rotated token", ctx do
      %{provider: provider, opts: opts} = ctx
      before = refresh_token(provider)
      expire_cache(opts)

      # The credential is the provider's, made up as it renews.
      {:ok, credential} = Credentials.fetch(ctx.installation, :ehos, opts)

      assert renewals(provider) == [renewal(provider, before, provider.issuer)]

      rotated = refresh_token(provider)
      assert rotated != before
      assert FakeKeychain.items(opts[:state_dir]) == [{"local", provider.issuer, rotated}]
      assert cached(opts, provider.issuer) == credential

      # Cached now: the next fetch does not renew.
      assert Credentials.fetch(ctx.installation, :ehos, opts) == {:ok, credential}
      assert renewals(provider) == [renewal(provider, before, provider.issuer)]
    end

    test "a renewed credential is cached for as long as EHOS says it lives", ctx do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      stub_now(now)
      expire_cache(ctx.opts)

      FakeProvider.answer_renewal(
        ctx.provider,
        {:ok, %{credential: "c", expires_in: 600, refresh_token: "r", claims: %{}}}
      )

      assert Credentials.fetch(ctx.installation, :ehos, ctx.opts) == {:ok, "c"}
      {:ok, session} = TokenStore.read(ctx.opts[:state_dir], "local")

      assert session.credentials == %{
               ctx.provider.issuer => %{token: "c", expires_at: DateTime.add(now, 600)}
             }
    end

    test "renews for an application by its address, and caches each apart", ctx do
      address = "https://ledger.example.com"
      token = refresh_token(ctx.provider)
      ehos = cached(ctx.opts, ctx.provider.issuer)

      {:ok, credential} = Credentials.fetch(ctx.installation, address, ctx.opts)
      assert renewals(ctx.provider) == [renewal(ctx.provider, token, address)]

      assert cached(ctx.opts, address) == credential
      assert cached(ctx.opts, ctx.provider.issuer) == ehos
    end

    test "commands that need a credential at once renew once", ctx do
      token = refresh_token(ctx.provider)
      expire_cache(ctx.opts)

      results =
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn -> Credentials.fetch(ctx.installation, :ehos, ctx.opts) end)
        end)
        |> Enum.map(&Task.await(&1, 10_000))

      credential = cached(ctx.opts, ctx.provider.issuer)
      assert results == List.duplicate({:ok, credential}, 5)
      assert renewals(ctx.provider) == [renewal(ctx.provider, token, ctx.provider.issuer)]
    end

    test "a renewal that is redirected is not followed", ctx do
      expire_cache(ctx.opts)
      FakeProvider.answer_renewal(ctx.provider, {:error, :redirected})

      assert Credentials.fetch(ctx.installation, :ehos, ctx.opts) ==
               {:error, :failed,
                "#{ctx.provider.issuer} redirected a request that carries your token; ehosctl " <>
                  "did not follow"}
    end

    test "a sign-in EHOS ended is forgotten, as not signed in", ctx do
      %{provider: provider, opts: opts} = ctx
      expire_cache(opts)
      FakeProvider.answer_renewal(provider, {:error, :not_signed_in, @expired})

      assert Credentials.fetch(ctx.installation, :ehos, opts) ==
               {:error, :not_signed_in, @expired}

      assert FakeKeychain.items(opts[:state_dir]) == []
      assert TokenStore.read(opts[:state_dir], "local") == :none
      {:ok, config} = Config.read(opts[:config_dir])
      assert config.installations["local"] == %{"url" => ctx.provider.issuer}
    end

    test "an application where no role is bound is refused, and the token kept", ctx do
      %{provider: provider, opts: opts} = ctx
      token = refresh_token(provider)
      refused = {:error, :refused, Ehosctl.Refusal.sentence("no_capability")}
      FakeProvider.answer_renewal(provider, refused)

      assert Credentials.fetch(ctx.installation, "https://other.example.com", opts) == refused
      assert FakeKeychain.items(opts[:state_dir]) == [{"local", provider.issuer, token}]
    end

    test "a renewal refused with any other code fails, and keeps the sign-in", ctx do
      %{provider: provider, opts: opts} = ctx
      token = refresh_token(provider)
      expire_cache(opts)

      refused = {:error, :failed, "#{provider.issuer} refused the request (HTTP 401): no_keys"}
      FakeProvider.answer_renewal(provider, refused)

      assert Credentials.fetch(ctx.installation, :ehos, opts) == refused
      assert FakeKeychain.items(opts[:state_dir]) == [{"local", provider.issuer, token}]
    end

    test "EHOS not answering is a reason to try again later", ctx do
      token = refresh_token(ctx.provider)
      expire_cache(ctx.opts)
      FakeProvider.down(ctx.provider)

      assert Credentials.fetch(ctx.installation, :ehos, ctx.opts) ==
               {:error, :unreachable, "#{ctx.provider.issuer} did not answer."}

      assert FakeKeychain.items(ctx.opts[:state_dir]) == [
               {"local", ctx.provider.issuer, token}
             ]
    end

    test "an address from config.json that is plain HTTP is refused, not renewed over", ctx do
      # The sign-in, moved to the installation's address over plain HTTP, as a config.json and a
      # state directory edited by hand would have it.
      dir = ctx.opts[:state_dir]
      {name, installation} = ctx.installation
      url = String.replace(installation["url"], "https:", "http:")
      {:ok, session} = TokenStore.read(dir, name)
      [{^name, _url, refresh_token}] = FakeKeychain.items(dir)
      :ok = TokenStore.write(dir, name, %{session | url: url, credentials: %{}})
      :ok = FakeKeychain.put(%{dir: dir, name: name, url: url}, refresh_token)

      plain = {:error, :invalid, "#{url} is plain HTTP; sign in with its https address"}

      # The endpoints kept for a plain HTTP address do not pass, and discovery refuses it.
      mock_discovered_endpoints(url, plain)

      assert Credentials.fetch({name, %{installation | "url" => url}}, :ehos, ctx.opts) == plain
      assert renewals(ctx.provider) == []
    end

    test "an installation never signed in to is not signed in", ctx do
      assert Credentials.fetch(
               {"staging", %{"url" => "https://ehos.example.com"}},
               :ehos,
               ctx.opts
             ) == {:error, :not_signed_in, "You are not signed in. Run `ehosctl login`."}
    end

    test "a renewal waits for one in progress, and gives up after two minutes", ctx do
      lock = TokenStore.path(ctx.opts[:state_dir], "local", "lock")
      File.write!(lock, System.pid() <> " another-command")
      expire_cache(ctx.opts)
      stub_virtual_clock()
      # The process holding it runs: no `kill` is forked to ask.
      stub(Ehosctl.OSMock, :alive?, fn _pid -> true end)

      assert TokenStore.with_lock(ctx.opts[:state_dir], "local", fn -> :ran end) ==
               {:error, :failed,
                "another ehosctl is renewing this sign-in; if none is running, remove #{lock} " <>
                  "and #{lock}.break"}

      File.rm!(lock)
    end
  end

  describe "keep/5" do
    # ehos-tools#538: each held its own installation's lock, and the second to write config.json
    # wrote it as it read it, without the first's installation.
    test "two sign-ins to different installations at once both stay in config.json", ctx do
      %{provider: provider, opts: opts} = ctx
      {:ok, session} = TokenStore.read(opts[:state_dir], "local")
      endpoints = %{token: session.endpoints["token"], revocation: nil}
      mock_now_once_both_ask(~U[2026-11-01 12:00:00Z])

      keeps =
        for name <- ["one", "two"],
            do:
              Task.async(fn ->
                Credentials.keep(name, provider.issuer, tokens(), endpoints, opts)
              end)

      assert Task.await_many(keeps) == [
               {:ok, sign_in(), ~U[1970-01-08 00:00:01Z]},
               {:ok, sign_in(), ~U[1970-01-08 00:00:01Z]}
             ]

      {:ok, config} = Config.read(opts[:config_dir])

      assert Map.new(config.installations, fn {name, installation} ->
               {name, installation["sign_in"]}
             end) == %{
               "local" => config.installations["local"]["sign_in"],
               "one" => sign_in(),
               "two" => sign_in()
             }
    end
  end

  # ehos-tools#76: a sign-in keeps the endpoints discovery named, and renews and revokes there.
  describe "the endpoints a sign-in kept" do
    test "a renewal posts to them, reading neither discovery nor the JWKS", ctx do
      token = refresh_token(ctx.provider)
      expire_cache(ctx.opts)

      {:ok, _credential} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      # Login's, and no other.
      assert discoveries(ctx.provider) == [:discovery, :jwks]
      assert renewals(ctx.provider) == [renewal(ctx.provider, token, ctx.provider.issuer)]
    end

    test "a sign-in with none reads discovery once, and keeps them", ctx do
      keep_endpoints(ctx.opts, nil)
      expire_cache(ctx.opts)

      {:ok, _credential} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert discoveries(ctx.provider) == [:discovery, :discovery, :jwks]
      assert kept_endpoints(ctx.opts) == discovered(ctx.provider)

      expire_cache(ctx.opts)
      {:ok, _credential} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert discoveries(ctx.provider) == [:discovery, :discovery, :jwks]
    end

    test "one that is no longer there sends the renewal back to discovery", ctx do
      gone = ctx.provider.issuer <> "/oauth/gone"
      token = refresh_token(ctx.provider)
      keep_endpoints(ctx.opts, %{"token" => gone, "revocation" => nil})
      expire_cache(ctx.opts)

      {:ok, _credential} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert renewals(ctx.provider) == [renewal(ctx.provider, token, ctx.provider.issuer)]

      assert posted(ctx.provider, "/oauth/gone") == [
               %{endpoint: gone, refresh_token: token, resource: ctx.provider.issuer}
             ]

      assert kept_endpoints(ctx.opts) == discovered(ctx.provider)
    end

    test "one that redirects sends the renewal back to discovery, never following", ctx do
      moved = ctx.provider.issuer <> "/oauth/moved"
      token = refresh_token(ctx.provider)
      keep_endpoints(ctx.opts, %{"token" => moved})
      expire_cache(ctx.opts)

      {:ok, _credential} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)

      assert posted(ctx.provider, "/oauth/moved") == [
               %{endpoint: moved, refresh_token: token, resource: ctx.provider.issuer}
             ]

      assert renewals(ctx.provider) == [renewal(ctx.provider, token, ctx.provider.issuer)]
    end

    test "one that refuses the token is checked against discovery before forgetting", ctx do
      token = refresh_token(ctx.provider)
      keep_endpoints(ctx.opts, %{"token" => ctx.provider.issuer <> "/oauth/stale"})
      expire_cache(ctx.opts)

      {:ok, _credential} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert renewals(ctx.provider) == [renewal(ctx.provider, token, ctx.provider.issuer)]

      assert FakeKeychain.items(ctx.opts[:state_dir]) == [
               {"local", ctx.provider.issuer, refresh_token(ctx.provider)}
             ]
    end

    test "one that is not on the installation's address is not posted to", ctx do
      issuer = ctx.provider.issuer
      %URI{port: port} = URI.parse(issuer)

      for token_endpoint <- [
            "https://evil.example.com/oauth/token",
            "https://localhost:#{port + 1}/oauth/token",
            "https://LOCALHOST:#{port}/oauth/token",
            "https://evil@localhost:#{port}/oauth/token",
            "https://evil.example\\@localhost:#{port}/oauth/token",
            String.replace(issuer, "https:", "http:") <> "/oauth/token"
          ] do
        keep_endpoints(ctx.opts, %{"token" => token_endpoint})
        expire_cache(ctx.opts)
        before = discoveries(ctx.provider)
        renewed = renewals(ctx.provider)
        token = refresh_token(ctx.provider)

        assert {:ok, _credential} = Credentials.fetch(ctx.installation, :ehos, ctx.opts),
               token_endpoint

        assert discoveries(ctx.provider) == Enum.sort([:discovery | before]), token_endpoint

        assert renewals(ctx.provider) == renewed ++ [renewal(ctx.provider, token, issuer)],
               token_endpoint
      end
    end

    test "one that redirects where discovery names it too is said, not followed", ctx do
      moved = ctx.provider.issuer <> "/oauth/moved"
      token = refresh_token(ctx.provider)
      keep_endpoints(ctx.opts, %{"token" => moved})
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => moved})
      expire_cache(ctx.opts)

      assert Credentials.fetch(ctx.installation, :ehos, ctx.opts) ==
               {:error, :failed,
                "#{ctx.provider.issuer} redirected a request that carries your token; ehosctl " <>
                  "did not follow"}

      assert posted(ctx.provider, "/oauth/moved") == [
               %{endpoint: moved, refresh_token: token, resource: ctx.provider.issuer}
             ]

      assert renewals(ctx.provider) == []
    end

    test "a refusal stands when discovery does not answer, and forgets the sign-in", ctx do
      keep_endpoints(ctx.opts, %{"token" => ctx.provider.issuer <> "/oauth/stale"})
      FakeProvider.answer_discovery(ctx.provider, HTTP.unreachable(ctx.provider.issuer))
      expire_cache(ctx.opts)

      assert Credentials.fetch(ctx.installation, :ehos, ctx.opts) ==
               {:error, :not_signed_in, @expired}

      assert FakeKeychain.items(ctx.opts[:state_dir]) == []
    end

    test "one that discovery writes otherwise is still the same address", ctx do
      gone = ctx.provider.issuer <> "/oauth/gone"
      token = refresh_token(ctx.provider)
      keep_endpoints(ctx.opts, %{"token" => gone})

      # Discovery's own checks refuse another host or case, so a trailing slash is what is left.
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => gone <> "/"})
      expire_cache(ctx.opts)

      assert Credentials.fetch(ctx.installation, :ehos, ctx.opts) ==
               {:error, :failed, "#{ctx.provider.issuer}'s token endpoint is not there"}

      assert posted(ctx.provider, "/oauth/gone") == [
               %{endpoint: gone, refresh_token: token, resource: ctx.provider.issuer}
             ]
    end

    test "one that discovery names too, refusing the token, forgets the sign-in", ctx do
      stale = ctx.provider.issuer <> "/oauth/stale"
      token = refresh_token(ctx.provider)
      keep_endpoints(ctx.opts, %{"token" => stale})
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => stale})
      expire_cache(ctx.opts)

      assert Credentials.fetch(ctx.installation, :ehos, ctx.opts) ==
               {:error, :not_signed_in, @expired}

      assert posted(ctx.provider, "/oauth/stale") == [
               %{endpoint: stale, refresh_token: token, resource: ctx.provider.issuer}
             ]

      assert FakeKeychain.items(ctx.opts[:state_dir]) == []
    end

    test "one that discovery names again is not posted to twice", ctx do
      gone = ctx.provider.issuer <> "/oauth/gone"
      token = refresh_token(ctx.provider)
      keep_endpoints(ctx.opts, %{"token" => gone, "revocation" => nil})
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => gone})
      expire_cache(ctx.opts)

      assert Credentials.fetch(ctx.installation, :ehos, ctx.opts) ==
               {:error, :failed, "#{ctx.provider.issuer}'s token endpoint is not there"}

      assert posted(ctx.provider, "/oauth/gone") == [
               %{endpoint: gone, refresh_token: token, resource: ctx.provider.issuer}
             ]

      assert FakeKeychain.items(ctx.opts[:state_dir]) == [{"local", ctx.provider.issuer, token}]
    end

    test "logout posts to them too", ctx do
      token = refresh_token(ctx.provider)
      before = discoveries(ctx.provider)

      assert ehosctl(["logout"], ctx.opts) == {0, signed_out(ctx.provider), ""}

      assert posted(ctx.provider, "/oauth/revoke") == [
               %{endpoint: ctx.provider.issuer <> "/oauth/revoke", token: token}
             ]

      assert discoveries(ctx.provider) == before
    end

    test "logout with none kept for revocation asks discovery, and ends the sign-in", ctx do
      token = refresh_token(ctx.provider)

      keep_endpoints(ctx.opts, %{
        "token" => ctx.provider.issuer <> "/oauth/token",
        "revocation" => nil
      })

      assert ehosctl(["logout"], ctx.opts) == {0, signed_out(ctx.provider), ""}

      assert posted(ctx.provider, "/oauth/revoke") == [
               %{endpoint: ctx.provider.issuer <> "/oauth/revoke", token: token}
             ]
    end

    test "logout at a revocation endpoint that is gone asks discovery", ctx do
      gone = ctx.provider.issuer <> "/oauth/gone"
      token = refresh_token(ctx.provider)

      keep_endpoints(ctx.opts, %{
        "token" => ctx.provider.issuer <> "/oauth/token",
        "revocation" => gone
      })

      assert ehosctl(["logout"], ctx.opts) == {0, signed_out(ctx.provider), ""}
      assert posted(ctx.provider, "/oauth/gone") == [%{endpoint: gone, token: token}]

      assert posted(ctx.provider, "/oauth/revoke") == [
               %{endpoint: ctx.provider.issuer <> "/oauth/revoke", token: token}
             ]
    end

    test "logout says so when EHOS names no revocation endpoint at all", ctx do
      keep_endpoints(ctx.opts, %{"token" => ctx.provider.issuer <> "/oauth/token"})
      FakeProvider.put_discovery(ctx.provider, %{"revocation_endpoint" => :drop})

      assert ehosctl(["logout"], ctx.opts) ==
               {0,
                "Signed out of local (#{ctx.provider.issuer}) on this computer. EHOS was not " <>
                  "told, so the sign-in ends there by itself, at the latest three days from its " <>
                  "last use. Why: #{ctx.provider.issuer} does not say where to end a sign-in\n",
                ""}

      assert posted(ctx.provider, "/oauth/revoke") == []
    end
  end

  # As if the credential login cached had expired, so the next fetch renews.
  defp expire_cache(opts) do
    {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    :ok = TokenStore.write(opts[:state_dir], "local", %{session | credentials: %{}})
  end

  defp keep_endpoints(opts, endpoints) do
    {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    :ok = TokenStore.write(opts[:state_dir], "local", %{session | endpoints: endpoints})
  end

  defp kept_endpoints(opts) do
    {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    session.endpoints
  end

  # The endpoints the provider's discovery names.
  defp discovered(provider),
    do: %{
      "token" => provider.issuer <> "/oauth/token",
      "revocation" => provider.issuer <> "/oauth/revoke"
    }

  # What logout says when EHOS was told the sign-in ended.
  defp signed_out(provider), do: "Signed out of local (#{provider.issuer}).\n"

  # The credential the sign-in caches for `resource`.
  defp cached(opts, resource) do
    {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    session.credentials[resource].token
  end

  # The one refresh token the provider holds live: the sign-in's, which the keychain keeps.
  defp refresh_token(provider) do
    [token] = provider |> FakeProvider.refresh_tokens() |> MapSet.to_list()
    token
  end

  # Discovery and the JWKS read, in the order read, which a fallback reads without.
  defp discoveries(provider) do
    for {kind, calls} <- [
          discovery: FakeProvider.calls(provider, :discovery),
          jwks: FakeProvider.calls(provider, :jwks)
        ],
        _call <- calls,
        do: kind
  end

  # The renewals posted to the token endpoint discovery names.
  defp renewals(provider), do: posted(provider, "/oauth/token")

  defp renewal(provider, refresh_token, resource),
    do: %{
      endpoint: provider.issuer <> "/oauth/token",
      refresh_token: refresh_token,
      resource: resource
    }

  # What was posted to the provider's endpoint at `path`, a renewal or a revocation.
  defp posted(provider, path) do
    for call <- FakeProvider.calls(provider, :renew) ++ FakeProvider.calls(provider, :revoke),
        is_binary(call.endpoint) and URI.parse(call.endpoint).path == path,
        do: call
  end

  defp mock_discovered_endpoints(url, answer),
    do: expect(Ehosctl.SignInMock, :discovered_endpoints, fn ^url, _opts -> answer end)

  defp tokens,
    do: %{
      claims: %{"sub" => "0b9f6c1e-person", "email" => "grace@example.com", "auth_time" => 1},
      credential: "credential",
      expires_in: 600,
      refresh_token: "refresh"
    }

  defp sign_in,
    do: %{
      "subject" => "0b9f6c1e-person",
      "email" => "grace@example.com",
      "signed_in_at" => "1970-01-01T00:00:01Z",
      "expires_at" => "1970-01-08T00:00:01Z"
    }

  # The clock answers `now` only once two processes have asked, so two sign-ins that begin with
  # it go on together, as two commands at the same moment would.
  defp mock_now_once_both_ask(now) do
    {:ok, asked} = Agent.start_link(fn -> 0 end)

    stub(Ehosctl.ClockMock, :now, fn ->
      Agent.update(asked, &(&1 + 1))
      wait_for(fn -> Agent.get(asked, & &1) >= 2 end)
      now
    end)
  end

  defp wait_for(done?) do
    unless done?.() do
      Process.sleep(1)
      wait_for(done?)
    end
  end
end

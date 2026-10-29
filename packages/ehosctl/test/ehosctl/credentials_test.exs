defmodule Ehosctl.CredentialsTest do
  use Ehosctl.SignInCase

  alias Ehosctl.Credentials
  alias Ehosctl.HTTP

  @expired "Your sign-in has expired. Run `ehosctl login`."

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    {:ok, config} = Config.read(opts[:config_dir])
    %{installation: {"local", config.installations["local"]}}
  end

  # As if the credential login cached had expired, so the next fetch renews.
  defp expire_cache(opts) do
    {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    :ok = TokenStore.write(opts[:state_dir], "local", %{session | credentials: %{}})
  end

  # The renewals posted to the token endpoint discovery names.
  defp renewals(provider), do: posted(provider, "/oauth/token")

  # What was posted to the provider's endpoint at `path`, a renewal or a revocation.
  defp posted(provider, path) do
    for call <- FakeProvider.calls(provider, :renew) ++ FakeProvider.calls(provider, :revoke),
        is_binary(call.endpoint) and URI.parse(call.endpoint).path == path,
        do: call
  end

  test "a credential cached by login is used without renewing", ctx do
    assert {:ok, "credential-" <> _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
    assert renewals(ctx.provider) == []
  end

  test "renews for EHOS's API, naming its issuer, and keeps the rotated token", ctx do
    %{provider: provider, opts: opts} = ctx
    [{_name, _url, before}] = FakeKeychain.items(opts[:state_dir])
    expire_cache(opts)

    assert {:ok, credential} = Credentials.fetch(ctx.installation, :ehos, opts)

    assert [renewal] = renewals(provider)
    assert renewal.resource == provider.issuer
    assert renewal.refresh_token == before

    [{_name, _url, rotated}] = FakeKeychain.items(opts[:state_dir])
    assert rotated != before
    assert FakeProvider.refresh_tokens(provider) == MapSet.new([rotated])

    {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    assert session.credentials[provider.issuer].token == credential

    # Cached now: the next fetch does not renew.
    assert {:ok, ^credential} = Credentials.fetch(ctx.installation, :ehos, opts)
    assert length(renewals(provider)) == 1
  end

  test "a renewal that is redirected is not followed", ctx do
    expire_cache(ctx.opts)
    FakeProvider.answer_renewal(ctx.provider, {:error, :redirected})

    assert {:error, :failed, message} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
    assert message =~ "redirected a request that carries your token"
  end

  test "a renewed credential is cached for as long as EHOS says it lives", ctx do
    expire_cache(ctx.opts)

    FakeProvider.answer_renewal(
      ctx.provider,
      {:ok, %{credential: "c", expires_in: 600, refresh_token: "r", claims: %{}}}
    )

    assert {:ok, "c"} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
    {:ok, session} = TokenStore.read(ctx.opts[:state_dir], "local")
    expires_at = session.credentials[ctx.provider.issuer].expires_at
    assert DateTime.diff(expires_at, DateTime.utc_now()) in 595..600
  end

  describe "the endpoints a sign-in kept (#76)" do
    # Discovery and the JWKS, which a fallback reads without.
    defp discoveries(provider),
      do:
        length(FakeProvider.calls(provider, :discovery)) +
          length(FakeProvider.calls(provider, :jwks))

    defp keep_endpoints(opts, endpoints) do
      {:ok, session} = TokenStore.read(opts[:state_dir], "local")
      :ok = TokenStore.write(opts[:state_dir], "local", %{session | endpoints: endpoints})
    end

    test "a renewal posts to them, reading neither discovery nor the JWKS", ctx do
      expire_cache(ctx.opts)
      before = discoveries(ctx.provider)

      assert {:ok, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert discoveries(ctx.provider) == before
      assert [_renewal] = renewals(ctx.provider)
    end

    test "a sign-in with none reads discovery once, and keeps them", ctx do
      keep_endpoints(ctx.opts, nil)
      expire_cache(ctx.opts)
      before = discoveries(ctx.provider)

      assert {:ok, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert discoveries(ctx.provider) == before + 1

      assert {:ok, %{endpoints: %{"token" => token}}} =
               TokenStore.read(ctx.opts[:state_dir], "local")

      assert token == ctx.provider.issuer <> "/oauth/token"

      expire_cache(ctx.opts)
      assert {:ok, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert discoveries(ctx.provider) == before + 1
    end

    test "one that is no longer there sends the renewal back to discovery", ctx do
      keep_endpoints(ctx.opts, %{
        "token" => ctx.provider.issuer <> "/oauth/gone",
        "revocation" => nil
      })

      expire_cache(ctx.opts)

      assert {:ok, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert [_renewal] = renewals(ctx.provider)
      assert [_once] = posted(ctx.provider, "/oauth/gone")

      assert {:ok, %{endpoints: %{"token" => token}}} =
               TokenStore.read(ctx.opts[:state_dir], "local")

      assert token == ctx.provider.issuer <> "/oauth/token"
    end

    test "one that redirects sends the renewal back to discovery, never following", ctx do
      keep_endpoints(ctx.opts, %{"token" => ctx.provider.issuer <> "/oauth/moved"})
      expire_cache(ctx.opts)

      assert {:ok, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert [_once] = posted(ctx.provider, "/oauth/moved")
      assert [_renewal] = renewals(ctx.provider)
    end

    test "one that redirects where discovery names it too is said, not followed", ctx do
      moved = ctx.provider.issuer <> "/oauth/moved"
      keep_endpoints(ctx.opts, %{"token" => moved})
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => moved})
      expire_cache(ctx.opts)

      assert {:error, :failed, message} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert message =~ "redirected a request that carries your token"
      assert [_once] = posted(ctx.provider, "/oauth/moved")
      assert renewals(ctx.provider) == []
    end

    test "one that refuses the token is checked against discovery before forgetting", ctx do
      keep_endpoints(ctx.opts, %{"token" => ctx.provider.issuer <> "/oauth/stale"})
      expire_cache(ctx.opts)

      assert {:ok, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert [_renewal] = renewals(ctx.provider)
      assert [_kept] = FakeKeychain.items(ctx.opts[:state_dir])
    end

    test "a refusal stands when discovery does not answer, and forgets the sign-in", ctx do
      keep_endpoints(ctx.opts, %{"token" => ctx.provider.issuer <> "/oauth/stale"})
      FakeProvider.answer_discovery(ctx.provider, HTTP.unreachable(ctx.provider.issuer))
      expire_cache(ctx.opts)

      assert {:error, :not_signed_in, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert FakeKeychain.items(ctx.opts[:state_dir]) == []
    end

    test "one that discovery writes otherwise is still the same address", ctx do
      gone = ctx.provider.issuer <> "/oauth/gone"
      keep_endpoints(ctx.opts, %{"token" => gone})

      # Discovery's own checks refuse another host or case, so a trailing slash is what is left.
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => gone <> "/"})
      expire_cache(ctx.opts)

      assert {:error, :failed, message} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert message =~ "token endpoint is not there"
      assert [_once] = posted(ctx.provider, "/oauth/gone")
    end

    test "one that discovery names too, refusing the token, forgets the sign-in", ctx do
      stale = ctx.provider.issuer <> "/oauth/stale"
      keep_endpoints(ctx.opts, %{"token" => stale})
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => stale})
      expire_cache(ctx.opts)

      assert {:error, :not_signed_in, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert [_once] = posted(ctx.provider, "/oauth/stale")
      assert FakeKeychain.items(ctx.opts[:state_dir]) == []
    end

    test "one that is not on the installation's address is not posted to", ctx do
      issuer = ctx.provider.issuer
      %URI{port: port} = URI.parse(issuer)

      for token <- [
            "https://evil.example.com/oauth/token",
            "https://localhost:#{port + 1}/oauth/token",
            "https://LOCALHOST:#{port}/oauth/token",
            "https://evil@localhost:#{port}/oauth/token",
            "https://evil.example\\@localhost:#{port}/oauth/token",
            String.replace(issuer, "https:", "http:") <> "/oauth/token"
          ] do
        keep_endpoints(ctx.opts, %{"token" => token})
        expire_cache(ctx.opts)
        before = discoveries(ctx.provider)
        renewed = length(renewals(ctx.provider))

        assert {:ok, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts), token
        assert discoveries(ctx.provider) == before + 1, token
        assert length(renewals(ctx.provider)) == renewed + 1, token
      end
    end

    test "one that discovery names again is not posted to twice", ctx do
      gone = ctx.provider.issuer <> "/oauth/gone"
      keep_endpoints(ctx.opts, %{"token" => gone, "revocation" => nil})
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => gone})
      expire_cache(ctx.opts)

      assert {:error, :failed, message} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert message =~ "token endpoint is not there"
      assert [_one] = posted(ctx.provider, "/oauth/gone")
      assert [_kept] = FakeKeychain.items(ctx.opts[:state_dir])
    end

    test "logout with none kept for revocation asks discovery, and ends the sign-in", ctx do
      keep_endpoints(ctx.opts, %{
        "token" => ctx.provider.issuer <> "/oauth/token",
        "revocation" => nil
      })

      assert {0, stdout, ""} = ehosctl(["logout"], ctx.opts)
      assert stdout =~ "Signed out of local"
      refute stdout =~ "EHOS was not told"
      assert [_revocation] = posted(ctx.provider, "/oauth/revoke")
    end

    test "logout at a revocation endpoint that is gone asks discovery", ctx do
      keep_endpoints(ctx.opts, %{
        "token" => ctx.provider.issuer <> "/oauth/token",
        "revocation" => ctx.provider.issuer <> "/oauth/gone"
      })

      assert {0, stdout, ""} = ehosctl(["logout"], ctx.opts)
      refute stdout =~ "EHOS was not told"
      assert [_once] = posted(ctx.provider, "/oauth/gone")
      assert [_revocation] = posted(ctx.provider, "/oauth/revoke")
    end

    test "logout says so when EHOS names no revocation endpoint at all", ctx do
      keep_endpoints(ctx.opts, %{"token" => ctx.provider.issuer <> "/oauth/token"})
      FakeProvider.put_discovery(ctx.provider, %{"revocation_endpoint" => :drop})

      assert {0, stdout, ""} = ehosctl(["logout"], ctx.opts)
      assert stdout =~ "EHOS was not told"
      assert stdout =~ "does not say where to end a sign-in"
      assert posted(ctx.provider, "/oauth/revoke") == []
    end

    test "logout posts to them too", ctx do
      before = discoveries(ctx.provider)

      assert {0, _stdout, ""} = ehosctl(["logout"], ctx.opts)
      assert [_revocation] = posted(ctx.provider, "/oauth/revoke")
      assert discoveries(ctx.provider) == before
    end
  end

  test "renews for an application by its address, and caches each apart", ctx do
    address = "https://ledger.example.com"

    assert {:ok, credential} = Credentials.fetch(ctx.installation, address, ctx.opts)
    assert [%{resource: ^address}] = renewals(ctx.provider)

    {:ok, session} = TokenStore.read(ctx.opts[:state_dir], "local")
    assert session.credentials[address].token == credential
    assert Map.has_key?(session.credentials, ctx.provider.issuer)
  end

  test "commands that need a credential at once renew once", ctx do
    expire_cache(ctx.opts)

    results =
      1..5
      |> Enum.map(fn _ ->
        Task.async(fn -> Credentials.fetch(ctx.installation, :ehos, ctx.opts) end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert [{:ok, credential}] = Enum.uniq(results)
    assert is_binary(credential)
    assert length(renewals(ctx.provider)) == 1
  end

  test "a sign-in EHOS ended is forgotten, as not signed in", ctx do
    %{provider: provider, opts: opts} = ctx
    expire_cache(opts)
    FakeProvider.answer_renewal(provider, {:error, :not_signed_in, @expired})

    assert {:error, :not_signed_in, @expired} = Credentials.fetch(ctx.installation, :ehos, opts)

    assert FakeKeychain.items(opts[:state_dir]) == []
    assert TokenStore.read(opts[:state_dir], "local") == :none
    {:ok, config} = Config.read(opts[:config_dir])
    refute Map.has_key?(config.installations["local"], "sign_in")
  end

  test "an application where no role is bound is refused, and the token kept", ctx do
    %{provider: provider, opts: opts} = ctx

    FakeProvider.answer_renewal(
      provider,
      {:error, :refused, Ehosctl.Refusal.sentence("no_capability")}
    )

    assert {:error, :refused, "None of your roles grants anything" <> _} =
             Credentials.fetch(ctx.installation, "https://other.example.com", opts)

    assert [_item] = FakeKeychain.items(opts[:state_dir])
  end

  test "a renewal refused with any other code fails, and keeps the sign-in", ctx do
    %{provider: provider, opts: opts} = ctx
    expire_cache(opts)

    refused = {:error, :failed, "#{provider.issuer} refused the request (HTTP 401): no_keys"}
    FakeProvider.answer_renewal(provider, refused)

    assert Credentials.fetch(ctx.installation, :ehos, opts) == refused
    assert [_item] = FakeKeychain.items(opts[:state_dir])
  end

  test "EHOS not answering is a reason to try again later", ctx do
    expire_cache(ctx.opts)
    FakeProvider.down(ctx.provider)

    assert {:error, :unreachable, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
    assert [_item] = FakeKeychain.items(ctx.opts[:state_dir])
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
    expect(Ehosctl.SignInMock, :discovered_endpoints, fn ^url, _opts -> plain end)

    assert Credentials.fetch({name, %{installation | "url" => url}}, :ehos, ctx.opts) == plain
    assert renewals(ctx.provider) == []
  end

  test "an installation never signed in to is not signed in", ctx do
    assert {:error, :not_signed_in, "You are not signed in. Run `ehosctl login`."} =
             Credentials.fetch(
               {"staging", %{"url" => "https://ehos.example.com"}},
               :ehos,
               ctx.opts
             )
  end

  test "a renewal waits for one in progress, and gives up after its timeout", ctx do
    lock = TokenStore.path(ctx.opts[:state_dir], "local", "lock")
    File.write!(lock, System.pid() <> " another-command")
    expire_cache(ctx.opts)

    assert {:error, :failed, message} =
             TokenStore.with_lock(ctx.opts[:state_dir], "local", fn -> :ran end, timeout: 200)

    assert message =~
             "another ehosctl is renewing this sign-in; if none is running, remove #{lock}"

    File.rm!(lock)
  end
end

defmodule Ehosctl.CredentialsTest do
  use Ehosctl.SignInCase

  alias Ehosctl.Credentials

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

  defp renewals(provider),
    do:
      provider
      |> FakeProvider.requests("/oauth/token")
      |> Enum.filter(&(&1["grant_type"] == "refresh_token"))

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
    assert renewal["resource"] == provider.issuer
    assert renewal["refresh_token"] == before
    assert renewal["client_id"] == "ehosctl"
    refute Map.has_key?(renewal, "client_secret")

    [{_name, _url, rotated}] = FakeKeychain.items(opts[:state_dir])
    assert rotated != before
    assert FakeProvider.refresh_tokens(provider) == MapSet.new([rotated])

    {:ok, session} = TokenStore.read(opts[:state_dir], "local")
    assert session.credentials[provider.issuer].token == credential

    # Cached now: the next fetch does not renew.
    assert {:ok, ^credential} = Credentials.fetch(ctx.installation, :ehos, opts)
    assert length(renewals(provider)) == 1
  end

  test "keeps the rotated token from an answer without an ID token", ctx do
    expire_cache(ctx.opts)
    FakeProvider.renew_without_id_token(ctx.provider)

    assert {:ok, "credential-" <> _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
    [{_name, _url, rotated}] = FakeKeychain.items(ctx.opts[:state_dir])
    assert FakeProvider.refresh_tokens(ctx.provider) == MapSet.new([rotated])
  end

  test "a renewal that is redirected is not followed", ctx do
    expire_cache(ctx.opts)
    FakeProvider.answer_token(ctx.provider, 307, %{})

    assert {:error, :failed, message} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
    assert message =~ "redirected a request that carries your token"
  end

  test "a credential's lifetime out of range is taken as ten minutes", ctx do
    expire_cache(ctx.opts)

    FakeProvider.answer_token(ctx.provider, 200, %{
      "access_token" => "c",
      "refresh_token" => "r",
      "expires_in" => -5
    })

    assert {:ok, "c"} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
    {:ok, session} = TokenStore.read(ctx.opts[:state_dir], "local")
    expires_at = session.credentials[ctx.provider.issuer].expires_at
    assert DateTime.diff(expires_at, DateTime.utc_now()) in 595..600
  end

  describe "the endpoints a sign-in kept (#76)" do
    # Discovery and the JWKS, which a fallback reads without.
    defp discoveries(provider),
      do:
        length(FakeProvider.requests(provider, "/.well-known/openid-configuration")) +
          length(FakeProvider.requests(provider, "/jwks"))

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
      assert [_once] = FakeProvider.requests(ctx.provider, "/oauth/gone")

      assert {:ok, %{endpoints: %{"token" => token}}} =
               TokenStore.read(ctx.opts[:state_dir], "local")

      assert token == ctx.provider.issuer <> "/oauth/token"
    end

    test "one that redirects sends the renewal back to discovery, never following", ctx do
      keep_endpoints(ctx.opts, %{"token" => ctx.provider.issuer <> "/oauth/moved"})
      expire_cache(ctx.opts)

      assert {:ok, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert [_once] = FakeProvider.requests(ctx.provider, "/oauth/moved")
      assert [_renewal] = renewals(ctx.provider)
    end

    test "one that redirects where discovery names it too is said, not followed", ctx do
      moved = ctx.provider.issuer <> "/oauth/moved"
      keep_endpoints(ctx.opts, %{"token" => moved})
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => moved})
      expire_cache(ctx.opts)

      assert {:error, :failed, message} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert message =~ "redirected a request that carries your token"
      assert [_once] = FakeProvider.requests(ctx.provider, "/oauth/moved")
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
      FakeProvider.put_discovery(ctx.provider, %{"issuer" => "https://another.example.com"})
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
      assert message =~ "names no endpoint for this, or one that is not there"
      assert [_once] = FakeProvider.requests(ctx.provider, "/oauth/gone")
    end

    test "one that discovery names too, refusing the token, forgets the sign-in", ctx do
      stale = ctx.provider.issuer <> "/oauth/stale"
      keep_endpoints(ctx.opts, %{"token" => stale})
      FakeProvider.put_discovery(ctx.provider, %{"token_endpoint" => stale})
      expire_cache(ctx.opts)

      assert {:error, :not_signed_in, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
      assert [_once] = FakeProvider.requests(ctx.provider, "/oauth/stale")
      assert FakeKeychain.items(ctx.opts[:state_dir]) == []
    end

    test "one that is not on the installation's address is not posted to", ctx do
      issuer = ctx.provider.issuer
      %URI{port: port} = URI.parse(issuer)

      for token <- [
            "https://evil.example.com/oauth/token",
            "http://localhost:#{port + 1}/oauth/token",
            "http://LOCALHOST:#{port}/oauth/token",
            "http://evil@localhost:#{port}/oauth/token",
            "http://evil.example\\@localhost:#{port}/oauth/token",
            String.replace(issuer, "http:", "https:") <> "/oauth/token"
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
      assert message =~ "names no endpoint for this, or one that is not there"
      assert [_one] = FakeProvider.requests(ctx.provider, "/oauth/gone")
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
      assert [_revocation] = FakeProvider.requests(ctx.provider, "/oauth/revoke")
    end

    test "logout at a revocation endpoint that is gone asks discovery", ctx do
      keep_endpoints(ctx.opts, %{
        "token" => ctx.provider.issuer <> "/oauth/token",
        "revocation" => ctx.provider.issuer <> "/oauth/gone"
      })

      assert {0, stdout, ""} = ehosctl(["logout"], ctx.opts)
      refute stdout =~ "EHOS was not told"
      assert [_once] = FakeProvider.requests(ctx.provider, "/oauth/gone")
      assert [_revocation] = FakeProvider.requests(ctx.provider, "/oauth/revoke")
    end

    test "logout posts to them too", ctx do
      before = discoveries(ctx.provider)

      assert {0, _stdout, ""} = ehosctl(["logout"], ctx.opts)
      assert [_revocation] = FakeProvider.requests(ctx.provider, "/oauth/revoke")
      assert discoveries(ctx.provider) == before
    end
  end

  test "renews for an application by its address, and caches each apart", ctx do
    address = "https://ledger.example.com"

    assert {:ok, credential} = Credentials.fetch(ctx.installation, address, ctx.opts)
    assert [%{"resource" => ^address}] = renewals(ctx.provider)

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
    FakeProvider.answer_token(provider, 400, %{"error" => "invalid_grant"})

    assert {:error, :not_signed_in, "Your sign-in has expired. Run `ehosctl login`."} =
             Credentials.fetch(ctx.installation, :ehos, opts)

    assert FakeKeychain.items(opts[:state_dir]) == []
    assert TokenStore.read(opts[:state_dir], "local") == :none
    {:ok, config} = Config.read(opts[:config_dir])
    refute Map.has_key?(config.installations["local"], "sign_in")
  end

  test "an application where no role is bound is refused, and the token kept", ctx do
    %{provider: provider, opts: opts} = ctx
    FakeProvider.answer_token(provider, 400, %{"error" => "invalid_target"})

    assert {:error, :refused, "None of your roles grants anything" <> _} =
             Credentials.fetch(ctx.installation, "https://other.example.com", opts)

    assert [_item] = FakeKeychain.items(opts[:state_dir])
  end

  test "too many renewals is a reason to try again later", ctx do
    expire_cache(ctx.opts)
    FakeProvider.answer_token(ctx.provider, 429, %{"error" => "slow_down"})

    assert {:error, :unreachable, "Too many calls in the last minute." <> _} =
             Credentials.fetch(ctx.installation, :ehos, ctx.opts)
  end

  test "EHOS not answering is a reason to try again later", ctx do
    expire_cache(ctx.opts)
    FakeProvider.down(ctx.provider)

    assert {:error, :unreachable, _} = Credentials.fetch(ctx.installation, :ehos, ctx.opts)
    assert [_item] = FakeKeychain.items(ctx.opts[:state_dir])
  end

  test "an address from config.json that is plain HTTP is refused, not renewed over", ctx do
    expire_cache(ctx.opts)
    opts = Keyword.delete(ctx.opts, :allow_http)

    assert {:error, :invalid, message} = Credentials.fetch(ctx.installation, :ehos, opts)
    assert message =~ "is plain HTTP"
    assert FakeProvider.requests(ctx.provider, "/oauth/token") |> Enum.count() == 1
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

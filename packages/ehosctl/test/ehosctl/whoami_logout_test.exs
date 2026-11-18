defmodule Ehosctl.WhoamiLogoutTest do
  # Not async, through `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process
  # shares.
  use Ehosctl.SignInCase

  @now ~U[2026-10-28 12:00:00Z]

  describe "whoami" do
    test "says who is signed in, where, and until when", %{opts: opts} do
      stub_now(@now)
      provider = start_provider(auth_time: DateTime.to_unix(@now))
      login!(provider, opts)

      assert ehosctl(["whoami"], opts) ==
               {0,
                "You are grace@example.com, signed in to local (#{provider.issuer}) " <>
                  "until 31 October 2026, 12:00 UTC.\n", ""}

      {0, stdout, ""} = ehosctl(["whoami", "--json"], opts)

      # Three days unrenewed comes before seven days from the sign-in.
      assert JSON.decode!(stdout) == %{
               "installation" => "local",
               "url" => provider.issuer,
               "subject" => "0b9f6c1e-person",
               "email" => "grace@example.com",
               "signed_in_at" => "2026-10-28T12:00:00Z",
               "until" => "2026-10-31T12:00:00Z"
             }
    end

    test "names the subject when EHOS gave no email", %{opts: opts} do
      stub_now(@now)
      provider = start_provider(email: nil, auth_time: DateTime.to_unix(@now))
      login!(provider, opts)

      assert ehosctl(["whoami"], opts) ==
               {0,
                "You are 0b9f6c1e-person, signed in to local (#{provider.issuer}) " <>
                  "until 31 October 2026, 12:00 UTC.\n", ""}
    end

    test "a sign-in seven days old has expired", %{opts: opts} do
      stub_now(@now)
      provider = start_provider(auth_time: DateTime.to_unix(@now) - 7 * 86_400)
      login!(provider, opts)

      assert ehosctl(["whoami"], opts) ==
               {4, "",
                "ehosctl: Your sign-in to local has expired.\nWhat to do:\n  ehosctl login --installation local\n"}
    end

    test "a sign-in unrenewed for three days has expired", %{provider: provider, opts: opts} do
      stub_now(@now)
      login!(provider, opts)
      {:ok, session} = TokenStore.read(opts[:state_dir], "local")
      renewed_at = DateTime.add(@now, -3 * 86_400 - 1)
      :ok = TokenStore.write(opts[:state_dir], "local", %{session | renewed_at: renewed_at})

      assert ehosctl(["whoami"], opts) ==
               {4, "",
                "ehosctl: Your sign-in to local has expired.\nWhat to do:\n  ehosctl login --installation local\n"}
    end

    test "with no sign-in, says to sign in", %{opts: opts} do
      :ok =
        Config.write(
          %Config{
            current: "local",
            installations: %{"local" => %{"url" => "https://localhost:1"}}
          },
          opts[:config_dir]
        )

      assert ehosctl(["whoami"], opts) ==
               {4, "",
                "ehosctl: You are not signed in to local.\nWhat to do:\n  ehosctl login --installation local\n"}
    end
  end

  describe "logout" do
    test "revokes the refresh token at EHOS, then forgets the sign-in", %{
      provider: provider,
      opts: opts
    } do
      login!(provider, opts)
      [{_name, _url, refresh_token}] = FakeKeychain.items(opts[:state_dir])

      assert ehosctl(["logout"], opts) == {0, "Signed out of local (#{provider.issuer}).\n", ""}

      assert FakeProvider.calls(provider, :revoke) == [
               %{endpoint: provider.issuer <> "/oauth/revoke", token: refresh_token}
             ]

      assert FakeProvider.refresh_tokens(provider) == MapSet.new()
      assert FakeKeychain.items(opts[:state_dir]) == []
      assert File.ls!(opts[:state_dir]) == []

      # The installation stays, signed out.
      assert Config.read(opts[:config_dir]) ==
               {:ok,
                %Config{
                  current: "local",
                  installations: %{"local" => %{"url" => provider.issuer}}
                }}

      assert ehosctl(["whoami"], opts) ==
               {4, "",
                "ehosctl: You are not signed in to local.\nWhat to do:\n  ehosctl login --installation local\n"}
    end

    test "--json says whether EHOS was told", %{provider: provider, opts: opts} do
      login!(provider, opts)

      {0, stdout, ""} = ehosctl(["logout", "--json"], opts)

      assert JSON.decode!(stdout) == %{
               "installation" => "local",
               "signed_out" => true,
               "revoked" => true
             }
    end

    test "forgets a sign-in kept for an address the installation no longer has", %{
      provider: provider,
      opts: opts
    } do
      login!(provider, opts)
      {:ok, config} = Config.read(opts[:config_dir])
      # As a login cut short between the sign-in's file and config.json leaves it.
      moved =
        config
        |> Config.put("local", "https://ehos.example.com")
        |> Config.put_sign_in("local", nil)

      :ok = Config.write(moved, opts[:config_dir])

      assert ehosctl(["logout"], opts) ==
               {0,
                "Signed out of local (https://ehos.example.com) on this computer. EHOS did not receive the " <>
                  "sign-out, so EHOS ends the sign-in itself, at the latest 3 days after its " <>
                  "last use. Reason: " <>
                  "You are not signed in to local. Run `ehosctl login --installation local`.\n",
                ""}

      assert FakeKeychain.items(opts[:state_dir]) == []
      assert File.ls!(opts[:state_dir]) == []
    end

    test "forgets the sign-in when EHOS does not answer, and says so", %{
      provider: provider,
      opts: opts
    } do
      stub_env(%{"EHOSCTL_TOKEN_STORE" => "file"})
      login!(provider, opts)
      FakeProvider.down(provider)

      assert ehosctl(["logout"], opts) ==
               {0,
                "Signed out of local (#{provider.issuer}) on this computer. EHOS did not receive the " <>
                  "sign-out, so EHOS ends the sign-in itself, at the latest 3 days after its " <>
                  "last use. Reason: " <>
                  "#{provider.issuer} did not answer. Check the network connection of this computer, then run the command " <>
                  "again.\n", ""}

      assert File.ls!(opts[:state_dir]) == []

      {0, stdout, ""} = ehosctl(["logout", "--json"], opts)

      assert JSON.decode!(stdout) == %{
               "installation" => "local",
               "signed_out" => false,
               "revoked" => false
             }
    end

    test "says when EHOS redirects the revocation, and forgets all the same", %{
      provider: provider,
      opts: opts
    } do
      login!(provider, opts)
      FakeProvider.answer_revoke(provider, {:error, :redirected})

      assert ehosctl(["logout"], opts) ==
               {0,
                "Signed out of local (#{provider.issuer}) on this computer. EHOS did not receive the " <>
                  "sign-out, so EHOS ends the sign-in itself, at the latest 3 days after its " <>
                  "last use. Reason: " <>
                  "#{provider.issuer} redirected a request that carries your token. " <>
                  "ehosctl did not follow the redirect.\n", ""}

      assert FakeKeychain.items(opts[:state_dir]) == []
    end
  end

  defp start_provider(opts) do
    provider = FakeProvider.start(opts)
    stub_browser(FakeProvider.browser(provider))
    provider
  end
end

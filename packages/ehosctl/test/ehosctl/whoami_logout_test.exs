defmodule Ehosctl.WhoamiLogoutTest do
  use Ehosctl.SignInCase

  describe "whoami" do
    test "says who is signed in, where, and until when", %{provider: provider, opts: opts} do
      login!(provider, opts)

      {0, stdout, ""} = ehosctl(["whoami"], opts)
      assert stdout =~ "You are grace@example.com, signed in to local (#{provider.issuer}) until "

      {0, stdout, ""} = ehosctl(["whoami", "--json"], opts)

      assert %{
               "installation" => "local",
               "subject" => "0b9f6c1e-person",
               "email" => "grace@example.com",
               "signed_in_at" => signed_in_at,
               "until" => until
             } = JSON.decode!(stdout)

      {:ok, signed_in_at, 0} = DateTime.from_iso8601(signed_in_at)
      {:ok, until, 0} = DateTime.from_iso8601(until)
      # Three days unrenewed comes before seven days from the sign-in.
      assert DateTime.diff(until, signed_in_at) in (3 * 86_400 - 5)..(3 * 86_400 + 5)
    end

    test "names the subject when EHOS gave no email", %{opts: opts} do
      provider = FakeProvider.start(email: nil)
      opts = Keyword.put(opts, :open_browser, FakeProvider.browser(provider))
      login!(provider, opts)

      {0, stdout, ""} = ehosctl(["whoami"], opts)
      assert stdout =~ "You are 0b9f6c1e-person, signed in to local"
    end

    test "a sign-in seven days old has expired", %{opts: opts} do
      provider = FakeProvider.start(auth_time: System.os_time(:second) - 7 * 86_400)
      opts = Keyword.put(opts, :open_browser, FakeProvider.browser(provider))
      login!(provider, opts)

      assert {4, "", "ehosctl: Your sign-in has expired. Run `ehosctl login`.\n"} =
               ehosctl(["whoami"], opts)
    end

    test "a sign-in unrenewed for three days has expired", %{provider: provider, opts: opts} do
      login!(provider, opts)
      {:ok, session} = TokenStore.read(opts[:state_dir], "local")
      renewed_at = DateTime.add(DateTime.utc_now(:second), -3 * 86_400 - 1)
      :ok = TokenStore.write(opts[:state_dir], "local", %{session | renewed_at: renewed_at})

      assert {4, "", _stderr} = ehosctl(["whoami"], opts)
    end

    test "with no sign-in, says to sign in", %{opts: opts} do
      :ok =
        Config.write(
          %Config{
            current: "local",
            installations: %{"local" => %{"url" => "http://localhost:1"}}
          },
          opts[:config_dir]
        )

      assert {4, "", "ehosctl: You are not signed in. Run `ehosctl login`.\n"} =
               ehosctl(["whoami"], opts)
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

      assert [%{"client_id" => "ehosctl", "token" => ^refresh_token}] =
               FakeProvider.requests(provider, "/oauth/revoke")

      assert FakeProvider.refresh_tokens(provider) == MapSet.new()
      assert FakeKeychain.items(opts[:state_dir]) == []
      assert File.ls!(opts[:state_dir]) == []

      # The installation stays, signed out.
      {:ok, config} = Config.read(opts[:config_dir])
      assert config.installations["local"] == %{"url" => provider.issuer}
      assert {4, "", _stderr} = ehosctl(["whoami"], opts)
    end

    test "forgets the sign-in when EHOS does not answer, and says so", %{
      provider: provider,
      opts: opts
    } do
      login!(provider, Keyword.put(opts, :env, %{"EHOSCTL_TOKEN_STORE" => "file"}))
      FakeProvider.down(provider)

      {0, stdout, ""} = ehosctl(["logout"], opts)

      assert stdout =~
               "Signed out of local (#{provider.issuer}) on this computer. EHOS was not told"

      assert stdout =~ "did not answer"
      assert File.ls!(opts[:state_dir]) == []

      {0, stdout, ""} = ehosctl(["logout", "--json"], opts)

      assert JSON.decode!(stdout) == %{
               "installation" => "local",
               "signed_out" => false,
               "revoked" => false
             }
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
  end
end

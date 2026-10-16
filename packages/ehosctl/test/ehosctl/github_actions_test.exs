defmodule Ehosctl.GitHubActionsTest do
  use Ehosctl.SignInCase

  alias Ehosctl.GitHubActions

  doctest Ehosctl.GitHubActions

  # GitHub's token service, as a job sees it: a URL with a query of its own, and a request token
  # it must be sent. Each token it gives is `github:<audience>:<n>`, kept for `asked/1`.
  setup %{provider: provider, opts: opts} do
    github = Bypass.open()
    {:ok, given} = Agent.start_link(fn -> [] end)

    Bypass.stub(github, "GET", "/token", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer request-token"] and
           conn.query_params["api-version"] == "2.0" do
        audience = conn.query_params["audience"]
        n = Agent.get_and_update(given, &{length(&1) + 1, [audience | &1]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{"value" => "github:#{audience}:#{n}"}))
      else
        Plug.Conn.resp(conn, 403, "")
      end
    end)

    job = %{
      "EHOSCTL_URL" => provider.issuer,
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "http://localhost:#{github.port}/token?api-version=2.0",
      "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "request-token"
    }

    for app <- ~w(ledger other) do
      FakeProvider.stub_api(
        provider,
        "GET",
        "/api/v1/applications/#{app}/deployment-trusts",
        fn _ ->
          {200, %{"application" => app, "trusts" => []}}
        end
      )
    end

    %{given: given, job: job, opts: Keyword.put(opts, :env, job)}
  end

  defp asked(given), do: given |> Agent.get(& &1) |> Enum.reverse()

  defp exchanges(provider), do: FakeProvider.requests(provider, "/oauth/token")

  test "exchanges the job's token for a credential, and calls EHOS's API with it",
       %{provider: provider, given: given, opts: opts, tmp_dir: tmp_dir} do
    {0, stdout, ""} = ehosctl(["trust", "list", "--app", "ledger"], opts)
    assert stdout =~ "ledger trusts no GitHub repository."

    # GitHub's token is for EHOS's issuer, and the exchange names the application's trust.
    assert asked(given) == [provider.issuer]

    assert [exchange] = exchanges(provider)

    assert exchange == %{
             "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
             "client_id" => "github-actions",
             "subject_token" => "github:#{provider.issuer}:1",
             "subject_token_type" => "urn:ietf:params:oauth:token-type:id_token",
             "audience" => "ehos",
             "resource" => "#{provider.issuer}/api/v1/applications/ledger"
           }

    # Nothing is kept on the runner.
    refute File.exists?(Path.join(tmp_dir, "config"))
    refute File.exists?(Path.join(tmp_dir, "state"))
  end

  test "names no application when the command names none", %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", "/api/v1", fn _request ->
      {200, %{"version" => "0.9.0", "api" => "ehos.api/v1", "routes" => []}}
    end)

    ehosctl(["versions"], opts)
    assert [exchange | _] = exchanges(provider)
    refute Map.has_key?(exchange, "resource")
  end

  test "uses the credential while it lasts, and exchanges a fresh token after",
       %{provider: provider, given: given, opts: opts} do
    {0, _stdout, ""} = ehosctl(["trust", "list", "--app", "ledger"], opts)
    {0, _stdout, ""} = ehosctl(["trust", "list", "--app", "ledger"], opts)
    assert length(exchanges(provider)) == 1

    # One that has less than thirty seconds left is not used.
    FakeProvider.exchange_expires_in(provider, 20)
    {0, _stdout, ""} = ehosctl(["trust", "list", "--app", "other"], opts)
    {0, _stdout, ""} = ehosctl(["trust", "list", "--app", "other"], opts)

    assert [_, second, third] = exchanges(provider)
    assert second["subject_token"] != third["subject_token"]
    assert length(asked(given)) == 3
  end

  test "says why EHOS refused the job's token, without what it keeps for its record",
       %{provider: provider, opts: opts} do
    FakeProvider.answer_token(provider, 400, %{"error" => "invalid_grant"})

    assert {3, _stdout, stderr} = ehosctl(["trust", "list", "--app", "ledger"], opts)
    assert stderr =~ "refused this job's GitHub Actions token"
    assert stderr =~ "audit record, as a refused deployment_identity.exchange"
    assert stderr =~ "`ehosctl trust list --app ledger`"
    assert stderr =~ "`ehosctl github claim`"
  end

  test "says to wait when EHOS limits the repository's exchanges",
       %{provider: provider, opts: opts} do
    FakeProvider.answer_token(provider, 429, %{"error" => "slow_down"})

    assert {5, _stdout, stderr} = ehosctl(["trust", "list", "--app", "ledger"], opts)
    assert stderr =~ "60 a minute"
  end

  test "talks to EHOSCTL_URL only from a job GitHub gives a token to",
       %{provider: provider, given: given, opts: opts} do
    outside = Keyword.put(opts, :env, %{"EHOSCTL_URL" => provider.issuer})
    assert {4, _stdout, stderr} = ehosctl(["trust", "list", "--app", "ledger"], outside)
    assert stderr =~ "only from a GitHub Actions job"
    assert stderr =~ "unset EHOSCTL_URL and sign in with `ehosctl login #{provider.issuer}`"

    no_token =
      Keyword.put(opts, :env, %{"EHOSCTL_URL" => provider.issuer, "GITHUB_ACTIONS" => "true"})

    assert {4, _stdout, stderr} = ehosctl(["trust", "list", "--app", "ledger"], no_token)
    assert stderr =~ "`permissions: id-token: write`"

    assert asked(given) == []
    assert exchanges(provider) == []
  end

  test "an installation named by --installation or EHOSCTL_INSTALLATION wins, with its sign-in",
       %{provider: provider, given: given, job: job, opts: opts} do
    login!(provider, Keyword.put(opts, :env, %{}))
    {:ok, config} = Config.read(opts[:config_dir])
    name = config.current

    named = Keyword.put(opts, :env, Map.put(job, "EHOSCTL_INSTALLATION", name))
    {0, _stdout, ""} = ehosctl(["trust", "list", "--app", "ledger"], named)
    {0, _stdout, ""} = ehosctl(["trust", "list", "--app", "ledger", "--installation", name], opts)

    assert asked(given) == []
    refute Enum.any?(exchanges(provider), &(&1["client_id"] == "github-actions"))
  end

  test "EHOSCTL_URL is an installation's address alone" do
    config = %Config{}

    assert {:ok, {"EHOSCTL_URL", %{"url" => "https://ehos.example.com"}}} =
             Config.select(config, nil, %{"EHOSCTL_URL" => "https://EHOS.example.com/"})

    for url <- ["http://ehos.example.com", "https://ehos.example.com/api", "ehos.example.com"] do
      assert {:error, :invalid, "EHOSCTL_URL: " <> _} =
               Config.select(config, nil, %{"EHOSCTL_URL" => url})
    end

    # An empty one is none, as an empty EHOSCTL_INSTALLATION is.
    assert {:error, :not_signed_in, _} = Config.select(config, nil, %{"EHOSCTL_URL" => ""})
  end

  test "no one signs in to the address EHOSCTL_URL gives", %{opts: opts} do
    assert {2, _stdout, stderr} = ehosctl(["login"], opts)
    assert stderr =~ "EHOSCTL_URL names an installation a GitHub Actions job talks to"
  end

  test "gives no credential for an application", %{provider: provider} do
    installation = {"EHOSCTL_URL", %{"url" => provider.issuer, "via" => "EHOSCTL_URL"}}

    assert {:error, :refused, "A GitHub Actions job's credential reaches EHOS's API alone" <> _} =
             GitHubActions.credential(installation, "https://ledger.example.com", [])
  end
end

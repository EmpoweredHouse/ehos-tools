defmodule Ehosctl.GitHubActionsTest do
  use Ehosctl.SignInCase

  alias Ehosctl.FakeHTTP
  alias Ehosctl.GitHubActions

  doctest Ehosctl.GitHubActions

  # GitHub's token service, as a job sees it: a URL with a query of its own, and a request token
  # it must be sent. Each token it gives is `github:<audience>:<n>`, kept for `asked/1`.
  setup %{provider: provider, opts: opts} do
    github = FakeHTTP.open()
    {:ok, given} = Agent.start_link(fn -> [] end)

    FakeHTTP.stub(github, "GET", "/token", fn conn ->
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
      "ACTIONS_ID_TOKEN_REQUEST_URL" => "#{github.origin}/token?api-version=2.0",
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

    stub_env(job)
    %{given: given, job: job, opts: opts}
  end

  test "exchanges the job's token for a credential, and calls EHOS's API with it",
       %{provider: provider, given: given, opts: opts, tmp_dir: tmp_dir} do
    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {0, "ledger trusts no GitHub repository.\n", ""}

    # GitHub's token is for EHOS's issuer, and the exchange names the application's trust.
    assert asked(given) == [provider.issuer]
    assert exchanges(provider) == [exchange(provider, 1, "ledger")]

    # Nothing is kept on the runner.
    assert File.ls!(tmp_dir) == []
  end

  test "names no application when the command names none", %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", "/api/v1", fn _request ->
      {200, %{"version" => "0.9.0", "api" => "ehos.api/v1", "routes" => []}}
    end)

    # What `versions` prints is its own test's; this one reads the exchange it makes.
    {0, _versions, ""} = ehosctl(["versions"], opts)

    assert exchanges(provider) == [
             Map.delete(exchange(provider, 1, "ledger"), "resource")
           ]
  end

  test "uses the credential while it lasts, and exchanges a fresh token after",
       %{provider: provider, given: given, opts: opts} do
    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {0, "ledger trusts no GitHub repository.\n", ""}

    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {0, "ledger trusts no GitHub repository.\n", ""}

    assert exchanges(provider) == [exchange(provider, 1, "ledger")]

    # One that has less than thirty seconds left is not used.
    FakeProvider.exchange_expires_in(provider, 20)

    assert ehosctl(["trust", "list", "--app", "other"], opts) ==
             {0, "other trusts no GitHub repository.\n", ""}

    assert ehosctl(["trust", "list", "--app", "other"], opts) ==
             {0, "other trusts no GitHub repository.\n", ""}

    assert exchanges(provider) == [
             exchange(provider, 1, "ledger"),
             exchange(provider, 2, "other"),
             exchange(provider, 3, "other")
           ]

    assert asked(given) == [provider.issuer, provider.issuer, provider.issuer]
  end

  test "an installation named by --installation or EHOSCTL_INSTALLATION wins, with its sign-in",
       %{provider: provider, given: given, job: job, opts: opts} do
    stub_env(%{})
    login!(provider, opts)
    {:ok, config} = Config.read(opts[:config_dir])
    name = config.current

    stub_env(Map.put(job, "EHOSCTL_INSTALLATION", name))

    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {0, "ledger trusts no GitHub repository.\n", ""}

    stub_env(job)

    assert ehosctl(["trust", "list", "--app", "ledger", "--installation", name], opts) ==
             {0, "ledger trusts no GitHub repository.\n", ""}

    assert asked(given) == []
    assert exchanges(provider) == []
  end

  test "EHOSCTL_URL is an installation's address alone" do
    config = %Config{}

    assert Config.select(config, nil, %{"EHOSCTL_URL" => "https://EHOS.example.com/"}) ==
             {:ok,
              {"EHOSCTL_URL", %{"url" => "https://ehos.example.com", "via" => "EHOSCTL_URL"}}}

    for {url, said} <- [
          {"http://ehos.example.com",
           "EHOSCTL_URL: http://ehos.example.com is plain HTTP; EHOS signs people in over https only"},
          {"https://ehos.example.com/api",
           ~s(EHOSCTL_URL: "https://ehos.example.com/api" is not an installation's address, ) <>
             "such as https://ehos.example.com"},
          {"ehos.example.com",
           ~s(EHOSCTL_URL: "ehos.example.com" is not an installation's address, ) <>
             "such as https://ehos.example.com"}
        ] do
      assert Config.select(config, nil, %{"EHOSCTL_URL" => url}) == {:error, :invalid, said}
    end

    # An empty one is none, as an empty EHOSCTL_INSTALLATION is.
    assert Config.select(config, nil, %{"EHOSCTL_URL" => ""}) ==
             {:error, :not_signed_in, "no installation is current; sign in to one first"}
  end

  test "says why EHOS refused the job's token, without what it keeps for its record",
       %{provider: provider, opts: opts} do
    FakeProvider.answer_token(provider, 400, %{"error" => "invalid_grant"})

    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {3, "",
              "ehosctl: #{provider.issuer} refused this job's GitHub Actions token. Why is in its " <>
                "audit record, as a refused deployment_identity.exchange. A job is accepted with " <>
                "the repository trusted for ledger, an application of that name " <>
                "(`ehosctl trust list --app ledger`); a ref, environment, workflow and event the " <>
                "trust accepts; and the GitHub account that started the run linked to a person " <>
                "who may deploy there (`ehosctl github claim`).\n"}
  end

  test "says to wait when EHOS limits the repository's exchanges",
       %{provider: provider, opts: opts} do
    FakeProvider.answer_token(provider, 429, %{"error" => "slow_down"})

    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {5, "",
              "ehosctl: EHOS is limiting this repository's exchanges, 60 a minute: try again in " <>
                "a minute.\n"}
  end

  test "talks to EHOSCTL_URL only from a job GitHub gives a token to",
       %{provider: provider, given: given, opts: opts} do
    stub_env(%{"EHOSCTL_URL" => provider.issuer})

    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {4, "",
              "ehosctl: EHOSCTL_URL names #{provider.issuer}, which ehosctl talks to only from a " <>
                "GitHub Actions job, with the job's own token (T-18). On a terminal, unset " <>
                "EHOSCTL_URL and sign in with `ehosctl login #{provider.issuer}`.\n"}

    stub_env(%{"EHOSCTL_URL" => provider.issuer, "GITHUB_ACTIONS" => "true"})

    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {4, "",
              "ehosctl: EHOSCTL_URL names #{provider.issuer}, and GitHub gives this job no " <>
                "token: give the job `permissions: id-token: write` (T-18).\n"}

    assert asked(given) == []
    assert exchanges(provider) == []
  end

  test "sends GitHub's request token over https alone", %{provider: provider, job: job} do
    installation = {"EHOSCTL_URL", %{"url" => provider.issuer, "via" => "EHOSCTL_URL"}}
    stub_env(Map.put(job, "ACTIONS_ID_TOKEN_REQUEST_URL", "http://github.example/token"))

    assert GitHubActions.credential(installation, :ehos, []) ==
             {:error, :failed,
              "ACTIONS_ID_TOKEN_REQUEST_URL is not https; ehosctl sends it nothing."}

    assert exchanges(provider) == []
  end

  test "no one signs in to the address EHOSCTL_URL gives", %{opts: opts} do
    assert ehosctl(["login"], opts) ==
             {2, "",
              "ehosctl: EHOSCTL_URL names an installation a GitHub Actions job talks to with its " <>
                "own token (T-18), which no one signs in to; name the installation's address: " <>
                "ehosctl login URL\n"}
  end

  test "gives no credential for an application", %{provider: provider} do
    installation = {"EHOSCTL_URL", %{"url" => provider.issuer, "via" => "EHOSCTL_URL"}}

    assert GitHubActions.credential(installation, "https://ledger.example.com", []) ==
             {:error, :refused,
              "A GitHub Actions job's credential reaches EHOS's API alone: no application " <>
                "accepts it (eh-os D-110)."}
  end

  defp asked(given), do: given |> Agent.get(& &1) |> Enum.reverse()

  defp exchanges(provider), do: FakeProvider.requests(provider, "/oauth/token")

  # The exchange of GitHub's `n`th token for a credential for `app`'s trust.
  defp exchange(provider, n, app),
    do: %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "client_id" => "github-actions",
      "subject_token" => "github:#{provider.issuer}:#{n}",
      "subject_token_type" => "urn:ietf:params:oauth:token-type:id_token",
      "audience" => "ehos",
      "resource" => "#{provider.issuer}/api/v1/applications/#{app}"
    }
end

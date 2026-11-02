defmodule Ehosctl.GitHubActionsTest do
  use Ehosctl.SignInCase

  alias Ehosctl.BundleFixture
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

  # The account not linked yet comes first, since it is what a new developer's first run meets
  # (ehos-tools#608).
  test "says why EHOS refused the job's token, an unlinked account first, without what it " <>
         "keeps for its record",
       %{provider: provider, opts: opts} do
    FakeProvider.answer_token(provider, 400, %{"error" => "invalid_grant"})

    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {3, "",
              "ehosctl: #{provider.issuer} refused this job's GitHub Actions token. Its audit " <>
                "record says why, as a refused deployment_identity.exchange. The most frequent " <>
                "cause: the GitHub account that started the run is not linked to a person in " <>
                "EHOS yet. Then the owner of the account runs `ehosctl github list`, then " <>
                "`ehosctl github claim <run>`. Another person who holds ehos.people.manage " <>
                "checks with the owner that the run is theirs, and runs " <>
                "`ehosctl people github confirm`. If only one person holds it, that person " <>
                "confirms their own. Other causes: EHOS accepts a job only with a repository " <>
                "that ledger trusts, an application of that name " <>
                "(`ehosctl trust list --app ledger`), with a ref, environment, workflow and " <>
                "event that the trust accepts, and with a linked account whose person can " <>
                "deploy there.\n"}
  end

  # ehos_app's CI workflow tells this refusal from any other failure by its opening sentence, as
  # `ci.yml.eex` matches it.
  test "opens the refusal of the job's token with the sentence the template's CI matches",
       %{provider: provider, opts: opts} do
    FakeProvider.answer_token(provider, 400, %{"error" => "invalid_grant"})
    installation = {"EHOSCTL_URL", %{"url" => provider.issuer, "via" => "EHOSCTL_URL"}}

    {:error, :refused, said} = GitHubActions.credential(installation, :ehos, opts)

    assert said =~ ~r/^\S+ refused this job.s GitHub Actions token\. /

    assert said ==
             "#{provider.issuer} refused this job's GitHub Actions token. Its audit record " <>
               "says why, as a refused deployment_identity.exchange. The most frequent cause: " <>
               "the GitHub account that started the run is not linked to a person in EHOS yet. " <>
               "Then the owner of the account runs `ehosctl github list`, then " <>
               "`ehosctl github claim <run>`. Another person who holds ehos.people.manage " <>
               "checks with the owner that the run is theirs, and runs " <>
               "`ehosctl people github confirm`. If only one person holds it, that person " <>
               "confirms their own. Other causes: EHOS accepts a job only with a repository " <>
               "that exactly one application trusts, with a ref, environment, workflow and " <>
               "event that the trust accepts, and with a linked account whose person can " <>
               "deploy there."
  end

  # The register step of ehos_app's CI workflow reads `ehosctl builds register --json` for this
  # refusal: exit code 3, and on stderr a JSON error whose message opens as above.
  # `Ehosctl.TemplateTest` holds those pieces, at the pinned release and at this commit, to the
  # workflow; this holds the command at this commit to the code and the JSON the workflow reads
  # today, through every module between the exchange and the exit.
  test "refuses a build's registration with the job's token as the template's CI reads it",
       %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
    FakeProvider.answer_token(provider, 400, %{"error" => "invalid_grant"})
    bundle = Path.join(tmp_dir, "bundle")
    BundleFixture.write(bundle, ~s({"schema": "ehos.manifest/v3", "application": "ledger"}\n), [])
    image = "ghcr.io/example/ledger@sha256:" <> String.duplicate("a1", 32)
    installation = {"EHOSCTL_URL", %{"url" => provider.issuer, "via" => "EHOSCTL_URL"}}

    {:error, :refused, said} =
      GitHubActions.credential(installation, :ehos, Keyword.put(opts, :application, "ledger"))

    assert ehosctl(["builds", "register", bundle, "--image", image, "--json"], opts) ==
             {3, "", JSON.encode!(%{error: %{kind: :refused, message: said}}) <> "\n"}
  end

  test "says to wait when EHOS limits the repository's exchanges",
       %{provider: provider, opts: opts} do
    FakeProvider.answer_token(provider, 429, %{"error" => "slow_down"})

    assert ehosctl(["trust", "list", "--app", "ledger"], opts) ==
             {5, "",
              "ehosctl: EHOS limits the exchanges of this repository to 60 a minute. " <>
                "Try again in a minute.\n"}
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
              "ehosctl: EHOSCTL_URL names #{provider.issuer}, but GitHub gives this job no " <>
                "token. Give the job `permissions: id-token: write`.\n"}

    assert asked(given) == []
    assert exchanges(provider) == []
  end

  test "sends GitHub's request token over https alone", %{provider: provider, job: job} do
    installation = {"EHOSCTL_URL", %{"url" => provider.issuer, "via" => "EHOSCTL_URL"}}
    stub_env(Map.put(job, "ACTIONS_ID_TOKEN_REQUEST_URL", "http://github.example/token"))

    assert GitHubActions.credential(installation, :ehos, []) ==
             {:error, :failed,
              "ACTIONS_ID_TOKEN_REQUEST_URL is not an https address, so ehosctl sends it nothing."}

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
              "The credential of a GitHub Actions job reaches only the API of EHOS. No " <>
                "application accepts it."}
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

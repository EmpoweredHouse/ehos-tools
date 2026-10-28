defmodule Ehosctl.TrustsTest do
  use Ehosctl.SignInCase

  alias Ehosctl.FakeHTTP

  @trust "3f2a1b0c-9d8e-4f7a-8b6c-5d4e3f2a1b0c"
  @path "/api/v1/applications/ledger/deployment-trusts"

  @listed %{
    "id" => @trust,
    "repository" => "acme/ledger",
    "repository_owner_id" => 11,
    "repository_id" => 22,
    "refs" => ["refs/heads/main", "refs/pull/*/merge"],
    "environments" => [],
    "ref_protected" => false,
    "workflow" => nil,
    "warnings" => ["pull_requests", "branches"],
    "created_by_id" => "0b9c2a8e-1f0e-4d43-9f5b-3a1c2d4e5f60",
    "created_at" => "2026-10-16T10:00:00Z",
    "removed_by_id" => nil,
    "removed_at" => nil
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    github = FakeHTTP.open()
    %{github: github, opts: Keyword.put(opts, :github_api, github.origin)}
  end

  defp api(provider, method, path, status, body),
    do: FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  defp sent(provider, key) do
    [{^key, request} | _] =
      provider |> FakeProvider.requests(key) |> Enum.map(&{key, &1})

    JSON.decode!(request.body)
  end

  defp github_repo(github, status, body) do
    FakeHTTP.expect_once(github, "GET", "/repos/acme/ledger", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, JSON.encode!(body))
    end)
  end

  test "lists an application's trusts, with what narrows each", %{provider: provider, opts: opts} do
    narrowed = %{
      @listed
      | "id" => "t-2",
        "environments" => ["preview"],
        "ref_protected" => true,
        "workflow" => ".github/workflows/ci.yml"
    }

    api(provider, "GET", @path, 200, %{"application" => "ledger", "trusts" => [@listed, narrowed]})

    {0, stdout, ""} = ehosctl(["trust", "list", "--app", "ledger"], opts)
    assert stdout =~ ~r/REPOSITORY\s+REFS\s+ONLY\s+STATE\s+ID/

    assert stdout =~
             ~r/acme\/ledger\s+refs\/heads\/main, refs\/pull\/\*\/merge\s+in force\s+#{@trust}/

    assert stdout =~ "environments preview; protected refs; .github/workflows/ci.yml"

    {0, json, ""} = ehosctl(["trust", "list", "--app", "ledger", "--json"], opts)
    assert %{"application" => "ledger", "trusts" => [@listed, _]} = JSON.decode!(json)
  end

  test "asks for the removed ones too with --removed", %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", @path, fn %{query: query} ->
      assert query == %{"removed" => "true"}
      {200, %{"application" => "ledger", "trusts" => []}}
    end)

    {0, stdout, ""} = ehosctl(["trust", "list", "--app", "ledger", "--removed"], opts)
    assert stdout =~ "ledger trusts no GitHub repository."
  end

  test "refuses a list EHOS answers with what it would not give", %{
    provider: provider,
    opts: opts
  } do
    api(provider, "GET", @path, 200, %{"trusts" => [%{@listed | "repository_id" => "22"}]})
    assert {1, _stdout, stderr} = ehosctl(["trust", "list", "--app", "ledger"], opts)
    assert stderr =~ "answered with something ehosctl cannot read"
  end

  test "adds a trust, with the ids GitHub gives the repository, and prints EHOS's warnings",
       %{provider: provider, github: github, opts: opts} do
    github_repo(github, 200, %{"id" => 22, "full_name" => "Acme/Ledger", "owner" => %{"id" => 11}})

    api(provider, "POST", @path, 201, %{"trust" => @listed})

    {0, stdout, ""} =
      ehosctl(
        [
          "trust",
          "add",
          "--app",
          "ledger",
          "--repo",
          "acme/ledger",
          "--ref",
          "refs/heads/main",
          "--ref",
          "refs/pull/*/merge"
        ],
        opts
      )

    assert stdout =~ "Trusted acme/ledger in ledger on refs/heads/main, refs/pull/*/merge"
    assert stdout =~ "trust #{@trust}"
    assert stdout =~ ~s(keep the repository's "Send write tokens to workflows from fork pull)
    assert stdout =~ "anyone who can push a branch or tag this trust accepts can run there"
    assert stdout =~ "add it again for 'refs/pull/*/merge' alone"
    refute stdout =~ "EHOS warns"

    assert sent(provider, "POST #{@path}") == %{
             "repository" => "Acme/Ledger",
             "repository_owner_id" => 11,
             "repository_id" => 22,
             "refs" => ["refs/heads/main", "refs/pull/*/merge"],
             "environments" => [],
             "ref_protected" => false
           }
  end

  test "sends what narrows a trust, and the ids given instead of asking GitHub",
       %{provider: provider, opts: opts} do
    trust = %{
      @listed
      | "refs" => ["refs/heads/main"],
        "environments" => ["preview"],
        "ref_protected" => true,
        "workflow" => ".github/workflows/ci.yml",
        "warnings" => []
    }

    api(provider, "POST", @path, 201, %{"trust" => trust})

    {0, stdout, ""} =
      ehosctl(
        ~w(trust add --app ledger --repo acme/ledger --ref refs/heads/main --environment preview
           --protected --workflow .github/workflows/ci.yml --owner-id 11 --repo-id 22),
        opts
      )

    assert stdout =~
             "in the environments preview, protected refs only, from .github/workflows/ci.yml only"

    refute stdout =~ "Send write tokens"

    assert %{
             "repository" => "acme/ledger",
             "environments" => ["preview"],
             "ref_protected" => true,
             "workflow" => ".github/workflows/ci.yml"
           } = sent(provider, "POST #{@path}")
  end

  test "prints a warning it has no sentence for by EHOS's name for it",
       %{provider: provider, opts: opts} do
    api(provider, "POST", @path, 201, %{"trust" => %{@listed | "warnings" => ["newer_one"]}})

    {0, stdout, ""} =
      ehosctl(
        ~w(trust add --app ledger --repo acme/ledger --ref refs/heads/main --owner-id 11
           --repo-id 22),
        opts
      )

    assert stdout =~ "EHOS warns: newer_one."
  end

  test "refuses an application that names nothing, or . or .., before asking EHOS",
       %{opts: opts} do
    for app <- ["", ".", ".."],
        argv <- [
          ["trust", "list", "--app", app],
          ["trust", "add", "--app", app, "--repo", "acme/ledger", "--ref", "main"],
          ["trust", "remove", "--app", app, "a-trust"]
        ] do
      {2, "", stderr} = ehosctl(argv, opts)
      assert stderr =~ "#{inspect(app)} names no application."
    end

    {2, "", stderr} = ehosctl(["trust", "remove", "--app", "shop", ""], opts)
    assert stderr =~ ~s("" names no trust.)
  end

  test "refuses one id without the other, and a repository not named OWNER/NAME",
       %{opts: opts} do
    assert {2, _stdout, stderr} =
             ehosctl(
               ~w(trust add --app ledger --repo acme/ledger --ref refs/heads/main --owner-id 11),
               opts
             )

    assert stderr =~ "--owner-id and --repo-id go together"

    assert {2, _stdout, stderr} =
             ehosctl(~w(trust add --app ledger --repo ledger --ref refs/heads/main), opts)

    assert stderr =~ "name it as OWNER/NAME"

    for repo <- ~w(acme/. acme/..) do
      assert {2, _stdout, stderr} =
               ehosctl(~w(trust add --app ledger --repo #{repo} --ref refs/heads/main), opts)

      assert stderr =~ "name it as OWNER/NAME"
    end
  end

  test "says GitHub shows no such repository, and how to go on without it",
       %{github: github, opts: opts} do
    github_repo(github, 404, %{"message" => "Not Found"})

    assert {1, _stdout, stderr} =
             ehosctl(~w(trust add --app ledger --repo acme/ledger --ref refs/heads/main), opts)

    assert stderr =~ "GitHub shows no repository acme/ledger without a token"
    assert stderr =~ "--owner-id and --repo-id"
  end

  test "says a 403 from GitHub is about the repository, not about EHOS's releases",
       %{github: github, opts: opts} do
    github_repo(github, 403, %{"message" => "Resource not accessible"})

    assert {1, _stdout, stderr} =
             ehosctl(~w(trust add --app ledger --repo acme/ledger --ref refs/heads/main), opts)

    assert stderr =~ "GitHub shows no repository acme/ledger"
    refute stderr =~ "releases"
  end

  test "says GitHub's secondary rate limit is a limit, not a repository it does not show",
       %{github: github, opts: opts} do
    FakeHTTP.expect_once(github, "GET", "/repos/acme/ledger", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "60")
      |> Plug.Conn.resp(403, ~s({"message": "secondary rate limit"}))
    end)

    assert {1, _stdout, stderr} =
             ehosctl(~w(trust add --app ledger --repo acme/ledger --ref refs/heads/main), opts)

    refute stderr =~ "shows no repository"
  end

  test "prints EHOS's refusal in its words", %{provider: provider, opts: opts} do
    api(provider, "POST", @path, 422, %{
      "error" => "invalid",
      "message" => "repository_id is already trusted for this application."
    })

    assert {2, _stdout, stderr} =
             ehosctl(
               ~w(trust add --app ledger --repo acme/ledger --ref refs/heads/main --owner-id 11
                  --repo-id 22),
               opts
             )

    assert stderr =~ "already trusted"
  end

  test "removes a trust by its id, given in either case", %{provider: provider, opts: opts} do
    removed = %{@listed | "removed_at" => "2026-10-16T11:00:00Z"}
    api(provider, "DELETE", "#{@path}/#{String.upcase(@trust)}", 200, %{"trust" => removed})

    {0, stdout, ""} = ehosctl(["trust", "remove", String.upcase(@trust), "--app", "ledger"], opts)
    assert stdout =~ "Removed the trust of acme/ledger in ledger"
  end

  test "says a removal answered for another trust did something", %{
    provider: provider,
    opts: opts
  } do
    api(provider, "DELETE", "#{@path}/#{@trust}", 200, %{"trust" => %{@listed | "id" => "t-9"}})

    assert {1, _stdout, stderr} = ehosctl(["trust", "remove", @trust, "--app", "ledger"], opts)
    assert stderr =~ "`ehosctl trust list`"
  end
end

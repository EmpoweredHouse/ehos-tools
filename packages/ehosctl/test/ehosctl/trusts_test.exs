defmodule Ehosctl.TrustsTest do
  # Not async, through `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process
  # shares.
  use Ehosctl.SignInCase

  alias Ehosctl.FakeGitHub
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
    %{github: FakeGitHub.start(), opts: opts}
  end

  describe "trusts list" do
    test "lists an application's trusts, with what narrows each", %{
      provider: provider,
      opts: opts
    } do
      narrowed = %{
        @listed
        | "id" => "t-2",
          "environments" => ["preview"],
          "ref_protected" => true,
          "workflow" => ".github/workflows/ci.yml"
      }

      mock_api(provider, "GET", @path, 200, %{
        "application" => "ledger",
        "trusts" => [@listed, narrowed]
      })

      {0, stdout, ""} = ehosctl(["trusts", "list", "--app", "ledger"], opts)

      assert stdout == """
              REPOSITORY   REFS                                ONLY                                                            STATE     ID
              acme/ledger  refs/heads/main, refs/pull/*/merge                                                                  in force  3f2a1b0c-9d8e-4f7a-8b6c-5d4e3f2a1b0c
              acme/ledger  refs/heads/main, refs/pull/*/merge  environments preview; protected refs; .github/workflows/ci.yml  in force  t-2
             """

      {0, json, ""} = ehosctl(["trusts", "list", "--app", "ledger", "--json"], opts)
      assert JSON.decode!(json) == %{"application" => "ledger", "trusts" => [@listed, narrowed]}
    end

    test "asks for the removed ones too with --removed", %{provider: provider, opts: opts} do
      mock_api(provider, "GET", @path, 200, %{"application" => "ledger", "trusts" => []})

      assert ehosctl(["trusts", "list", "--app", "ledger", "--removed"], opts) ==
               {0,
                "ledger trusts no GitHub repository. A trust shows here when a person adds it with `ehosctl trusts add`.\n",
                ""}

      assert FakeProvider.requests(provider, "GET #{@path}") == [
               %{path: @path, query: %{"removed" => "true"}, body: "", content_type: nil}
             ]
    end

    test "refuses a list EHOS answers with what it would not give", %{
      provider: provider,
      opts: opts
    } do
      mock_api(provider, "GET", @path, 200, %{"trusts" => [%{@listed | "repository_id" => "22"}]})

      assert ehosctl(["trusts", "list", "--app", "ledger"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end
  end

  describe "trusts add" do
    test "adds a trust, with the ids GitHub gives the repository, and prints EHOS's warnings",
         %{provider: provider, github: github, opts: opts} do
      mock_github_repo(github, 200, %{
        "id" => 22,
        "full_name" => "Acme/Ledger",
        "owner" => %{"id" => 11}
      })

      mock_api(provider, "POST", @path, 201, %{"trust" => @listed})

      {0, stdout, stderr} =
        ehosctl(
          [
            "trusts",
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

      assert stdout == """
             ✓ Trusted acme/ledger in ledger.
               Trust   #{@trust}
               Refs    refs/heads/main
                       refs/pull/*/merge
             """

      # EHOS's warnings, each with its head and its explanation, on stderr.
      assert stderr == """
             ! The trust accepts pull requests.
               Keep "Send write tokens to workflows from fork pull requests" off in the repository. If it is on, a pull request from a fork deploys as the person who opened it.
             ! The trust accepts pull requests and also branches or tags, without --protected.
               The run of a pull request reaches only its own preview. But each person who can push a branch or a tag that this trust accepts can run a job there and reach each preview of the application. To stop this, remove the trust and add it again for 'refs/pull/*/merge' only. Do not use --protected for it: GitHub protects no ref of a pull request, so EHOS would refuse each run of a pull request.
             """

      assert sent(provider) == [
               %{
                 path: @path,
                 query: %{},
                 body: %{
                   "repository" => "Acme/Ledger",
                   "repository_owner_id" => 11,
                   "repository_id" => 22,
                   "refs" => ["refs/heads/main", "refs/pull/*/merge"],
                   "environments" => [],
                   "ref_protected" => false
                 },
                 content_type: "application/json"
               }
             ]
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

      mock_api(provider, "POST", @path, 201, %{"trust" => trust})

      assert ehosctl(
               ~w(trusts add --app ledger --repo acme/ledger --ref refs/heads/main --environment preview
                  --protected --workflow .github/workflows/ci.yml --owner-id 11 --repo-id 22),
               opts
             ) ==
               {0,
                """
                ✓ Trusted acme/ledger in ledger.
                  Trust            #{@trust}
                  Refs             refs/heads/main
                  Environments     preview
                  Ref protection   protected refs only
                  Workflow         .github/workflows/ci.yml
                """, ""}

      assert sent(provider) == [
               %{
                 path: @path,
                 query: %{},
                 body: %{
                   "repository" => "acme/ledger",
                   "repository_owner_id" => 11,
                   "repository_id" => 22,
                   "refs" => ["refs/heads/main"],
                   "environments" => ["preview"],
                   "ref_protected" => true,
                   "workflow" => ".github/workflows/ci.yml"
                 },
                 content_type: "application/json"
               }
             ]
    end

    test "prints a warning it has no sentence for by EHOS's name for it",
         %{provider: provider, opts: opts} do
      mock_api(provider, "POST", @path, 201, %{
        "trust" => %{@listed | "warnings" => ["newer_one"]}
      })

      assert ehosctl(
               ~w(trusts add --app ledger --repo acme/ledger --ref refs/heads/main --owner-id 11
                  --repo-id 22),
               opts
             ) ==
               {0,
                """
                ✓ Trusted acme/ledger in ledger.
                  Trust   #{@trust}
                  Refs    refs/heads/main
                          refs/pull/*/merge
                """, "! EHOS warns: newer_one.\n"}
    end

    test "--json prints EHOS's warnings in the document alone, none on stderr",
         %{provider: provider, opts: opts} do
      mock_api(provider, "POST", @path, 201, %{"trust" => @listed})

      {0, json, ""} =
        ehosctl(
          ~w(trusts add --app ledger --repo acme/ledger --ref refs/heads/main --owner-id 11
             --repo-id 22 --json),
          opts
        )

      assert JSON.decode!(json)["trust"]["warnings"] == ["pull_requests", "branches"]
    end

    test "refuses one id without the other, and a repository not named OWNER/NAME",
         %{opts: opts} do
      assert ehosctl(
               ~w(trusts add --app ledger --repo acme/ledger --ref refs/heads/main --owner-id 11),
               opts
             ) ==
               {2, "", "ehosctl: --owner-id and --repo-id go together. Give both, or neither.\n"}

      for repo <- ~w(ledger acme/. acme/..) do
        assert ehosctl(~w(trusts add --app ledger --repo #{repo} --ref refs/heads/main), opts) ==
                 {2, "",
                  "ehosctl: #{repo} is not the name of a GitHub repository. Give it as OWNER/NAME.\n"}
      end
    end

    test "says GitHub shows no such repository, and how to go on without it",
         %{github: github, opts: opts} do
      mock_github_repo(github, 404, %{"message" => "Not Found"})

      assert ehosctl(~w(trusts add --app ledger --repo acme/ledger --ref refs/heads/main), opts) ==
               {1, "",
                "ehosctl: GitHub does not show the repository acme/ledger without a token. Set " <>
                  "MISE_GITHUB_TOKEN or GITHUB_TOKEN, for example to the output of " <>
                  "`gh auth token`. Or give --owner-id and --repo-id.\n"}
    end

    test "says a 403 from GitHub is about the repository, not about EHOS's releases",
         %{github: github, opts: opts} do
      mock_github_repo(github, 403, %{"message" => "Resource not accessible"})

      assert ehosctl(~w(trusts add --app ledger --repo acme/ledger --ref refs/heads/main), opts) ==
               {1, "",
                "ehosctl: GitHub does not show the repository acme/ledger without a token. Set " <>
                  "MISE_GITHUB_TOKEN or GITHUB_TOKEN, for example to the output of " <>
                  "`gh auth token`. Or give --owner-id and --repo-id.\n"}
    end

    test "says GitHub's secondary rate limit is a limit, not a repository it does not show",
         %{github: github, opts: opts} do
      mock_github_rate_limit(github)

      assert ehosctl(~w(trusts add --app ledger --repo acme/ledger --ref refs/heads/main), opts) ==
               {1, "",
                "ehosctl: GitHub refused the request because the limit of requests is reached " <>
                  "(HTTP 403). Try again later.\n"}
    end

    test "prints EHOS's refusal in its words", %{provider: provider, opts: opts} do
      mock_api(provider, "POST", @path, 422, %{
        "error" => "invalid",
        "message" => "repository_id is already trusted for this application."
      })

      assert ehosctl(
               ~w(trusts add --app ledger --repo acme/ledger --ref refs/heads/main --owner-id 11
                  --repo-id 22),
               opts
             ) == {2, "", "ehosctl: repository_id is already trusted for this application.\n"}
    end
  end

  describe "trusts remove" do
    test "removes a trust by its id, given in either case", %{provider: provider, opts: opts} do
      removed = %{@listed | "removed_at" => "2026-10-16T11:00:00Z"}

      mock_api(provider, "DELETE", "#{@path}/#{String.upcase(@trust)}", 200, %{"trust" => removed})

      assert ehosctl(["trusts", "remove", String.upcase(@trust), "--app", "ledger"], opts) ==
               {0,
                "Removed the trust of acme/ledger in ledger. EHOS refuses its next job, and " <>
                  "each credential that EHOS already gave it.\n", ""}
    end

    test "says a removal answered for another trust did something", %{
      provider: provider,
      opts: opts
    } do
      mock_api(provider, "DELETE", "#{@path}/#{@trust}", 200, %{
        "trust" => %{@listed | "id" => "t-9"}
      })

      assert ehosctl(["trusts", "remove", @trust, "--app", "ledger"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. It " <>
                  "answered that something was done, but not as what was asked.\nWhat to do:\n  See what was done:\n  ehosctl trusts list --installation local\n"}
    end
  end

  describe "trusts" do
    test "refuses an application that names nothing, or . or .., before asking EHOS",
         %{opts: opts} do
      for app <- ["", ".", ".."],
          argv <- [
            ["trusts", "list", "--app", app],
            ["trusts", "add", "--app", app, "--repo", "acme/ledger", "--ref", "main"],
            ["trusts", "remove", "--app", app, "a-trust"]
          ] do
        assert ehosctl(argv, opts) ==
                 {2, "",
                  "ehosctl: #{inspect(app)} is not the name of an application. Give the name " <>
                    "of the application with --app.\n"}
      end

      assert ehosctl(["trusts", "remove", "--app", "shop", ""], opts) ==
               {2, "",
                ~s(ehosctl: "" is not the id of a trust.\n) <>
                  "What to do:\n" <>
                  "  See the ids:\n" <>
                  "  ehosctl trusts list --app shop --installation local\n"}
    end
  end

  defp mock_api(provider, method, path, status, body),
    do: FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  # The requests sent to the application's trusts, each with its JSON body decoded.
  defp sent(provider), do: json_requests(provider, "POST #{@path}")

  defp mock_github_repo(github, status, body) do
    FakeHTTP.expect_once(github, "GET", "/repos/acme/ledger", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, JSON.encode!(body))
    end)
  end

  defp mock_github_rate_limit(github) do
    FakeHTTP.expect_once(github, "GET", "/repos/acme/ledger", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "60")
      |> Plug.Conn.resp(403, ~s({"message": "secondary rate limit"}))
    end)
  end
end

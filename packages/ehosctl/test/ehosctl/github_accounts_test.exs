defmodule Ehosctl.GitHubAccountsTest do
  use Ehosctl.SignInCase

  @account "6c5b4a39-2817-4f6e-9d0c-1b2a3c4d5e6f"
  @run "8e7d6c5b-4a39-4281-9f6e-0d1c2b3a4f5e"
  @run_again "1a2b3c4d-5e6f-4a1b-8c2d-3e4f5a6b7c8d"
  @run_without_commit "9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"
  @grace "0b9c2a8e-1f0e-4d43-9f5b-3a1c2d4e5f60"

  @claimed %{
    "id" => @account,
    "person_id" => @grace,
    "github_id" => 4242,
    "login" => "grace-h",
    "claimed_at" => "2026-10-16T10:00:00Z",
    "confirmed_at" => nil,
    "confirmed_by_id" => nil,
    "removed_at" => nil
  }

  @refused_run %{
    "exchange" => @run,
    "github_id" => 4242,
    "login" => "grace-h",
    "repository" => "acme/ledger",
    "ref" => "refs/pull/12/merge",
    "event_name" => "pull_request",
    "sha" => "0123456789abcdef0123456789abcdef01234567",
    "run_url" => "https://github.com/acme/ledger/actions/runs/99",
    "at" => "2026-10-16T09:58:00Z"
  }

  @waiting Map.merge(@claimed, %{
             "person" => %{"id" => @grace, "email" => "grace@example.com"},
             "run" => @refused_run,
             "contested" => false
           })

  @claimed_stdout "Claimed grace-h as the account #{@account}. A people manager must confirm " <>
                    "it with `ehosctl people github confirm`. If you are the only people " <>
                    "manager, you confirm it. Until then, EHOS refuses the runs of the account.\n"
  @confirmed_stdout "Confirmed grace-h for grace@example.com. The runs of the account now " <>
                      "deploy on behalf of this person.\n"

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "github list, claim and remove" do
    # Each run with its commit, which tells several refused runs on one ref apart
    # (ehos-tools#608); a run GitHub signed no commit for shows it unknown, as `claim` does.
    test "lists their accounts and the runs they may claim one from",
         %{provider: provider, opts: opts} do
      linked = %{@claimed | "confirmed_at" => "2026-10-16T10:05:00Z"}

      pushed_again = %{
        @refused_run
        | "exchange" => @run_again,
          "sha" => "fedcba9876543210fedcba9876543210fedcba98",
          "at" => "2026-10-16T10:02:00Z"
      }

      no_commit = %{@refused_run | "exchange" => @run_without_commit, "sha" => nil}

      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [linked],
        "claimable" => [@refused_run, pushed_again, no_commit]
      })

      {0, stdout, ""} = ehosctl(["github", "list"], opts)

      assert stdout == """
              LOGIN    GITHUB ID  STATE   ID
              grace-h  4242       linked  #{@account}

             Runs that you can claim an account from, with `ehosctl github claim RUN`:
              LOGIN    REPOSITORY   REF                 COMMIT        AT                          RUN
              grace-h  acme/ledger  refs/pull/12/merge  0123456789ab  16 October 2026, 09:58 UTC  #{@run}
              grace-h  acme/ledger  refs/pull/12/merge  fedcba987654  16 October 2026, 10:02 UTC  #{@run_again}
              grace-h  acme/ledger  refs/pull/12/merge  unknown       16 October 2026, 09:58 UTC  #{@run_without_commit}
             """

      {0, json, ""} = ehosctl(["github", "list", "--json"], opts)

      assert JSON.decode!(json) == %{
               "accounts" => [linked],
               "claimable" => [@refused_run, pushed_again, no_commit]
             }
    end

    test "claims from the only run there is, after showing it and asking",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => [@refused_run]
      })

      api(provider, "POST", "/api/v1/me/github-accounts", 201, %{"account" => @claimed})

      mock_answer(true)
      assert ehosctl(["github", "claim"], opts) == {0, @claimed_stdout, ""}

      assert_received {:asked, question}

      assert question ==
               "The run of grace-h, GitHub id 4242:\n" <>
                 "  acme/ledger at refs/pull/12/merge, pull_request, commit 0123456789ab, " <>
                 "16 October 2026, 09:58 UTC\n" <>
                 "  https://github.com/acme/ledger/actions/runs/99\n" <>
                 "Is this run yours? [y/N] "

      assert json_requests(provider, "POST " <> "/api/v1/me/github-accounts") == [
               json_request("/api/v1/me/github-accounts", %{"exchange" => @run})
             ]
    end

    test "sends nothing when the run is not theirs", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => [@refused_run]
      })

      mock_answer(false)
      assert ehosctl(["github", "claim"], opts) == {0, "You did not claim the account.\n", ""}
      assert FakeProvider.requests(provider, "POST /api/v1/me/github-accounts") == []
    end

    test "removes one of their accounts", %{provider: provider, opts: opts} do
      removed = %{@claimed | "removed_at" => "2026-10-16T11:00:00Z"}

      api(provider, "DELETE", "/api/v1/me/github-accounts/#{@account}", 200, %{
        "account" => removed
      })

      assert ehosctl(["github", "remove", @account], opts) ==
               {0, "Removed grace-h. EHOS refuses the next run of the account.\n", ""}
    end

    test "asks to name a run among several, and none when there are none",
         %{provider: provider, opts: opts} do
      other = %{@refused_run | "exchange" => "1d2c3b4a-5968-4776-8584-93a2b1c0d9e8"}

      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => [@refused_run, other]
      })

      assert ehosctl(["github", "claim", "--yes"], opts) ==
               {2, "",
                "ehosctl: You have more than one run to claim from. Give one run, as `ehosctl " <>
                  "github list` shows it.\n"}

      api(provider, "POST", "/api/v1/me/github-accounts", 201, %{"account" => @claimed})

      assert ehosctl(["github", "claim", String.upcase(@run), "--yes"], opts) ==
               {0, @claimed_stdout, ""}

      assert json_requests(provider, "POST " <> "/api/v1/me/github-accounts") == [
               json_request("/api/v1/me/github-accounts", %{"exchange" => @run})
             ]

      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => []
      })

      assert ehosctl(["github", "claim", "--yes"], opts) ==
               {1, "",
                "ehosctl: You have no refused run to claim an account from. Run a GitHub " <>
                  "Actions job of a trusted repository first. When EHOS refuses the run, you " <>
                  "can claim its account.\n"}
    end

    test "prints EHOS's refusal of a run it will not let them claim",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => [@refused_run]
      })

      api(provider, "POST", "/api/v1/me/github-accounts", 422, %{
        "error" => "not_claimable",
        "message" => "That is not a refused run of yours to claim an account from."
      })

      assert ehosctl(["github", "claim", "--yes"], opts) ==
               {2, "", "ehosctl: That is not a refused run of yours to claim an account from.\n"}
    end

    test "refuses a run whose fields are not text, and prints none raw",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => [%{@refused_run | "at" => %{"when" => "now"}}]
      })

      assert ehosctl(["github", "claim", "--yes"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}

      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => [%{@refused_run | "at" => "2026-10-16\e[2K\e[1A"}]
      })

      mock_answer(false)
      assert ehosctl(["github", "claim"], opts) == {0, "You did not claim the account.\n", ""}
      assert_received {:asked, question}

      assert question ==
               "The run of grace-h, GitHub id 4242:\n" <>
                 ~S(  acme/ledger at refs/pull/12/merge, pull_request, commit 0123456789ab, "2026-10-16\e[2K\e[1A") <>
                 "\n  https://github.com/acme/ledger/actions/runs/99\n" <>
                 "Is this run yours? [y/N] "
    end
  end

  describe "people github list, confirm and remove" do
    test "lists the claims waiting, and which are contested", %{provider: provider, opts: opts} do
      contested = %{@waiting | "id" => "c-2", "contested" => true}
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [@waiting, contested]})

      {0, stdout, ""} = ehosctl(["people", "github", "list"], opts)

      assert stdout == """
              PERSON             LOGIN    REPOSITORY   NOTE                        ID
              grace@example.com  grace-h  acme/ledger  <none>                      #{@account}
              grace@example.com  grace-h  acme/ledger  someone else claims it too  c-2
             """

      {0, json, ""} = ehosctl(["people", "github", "list", "--json"], opts)
      assert JSON.decode!(json) == %{"accounts" => [@waiting, contested]}
    end

    # eh-os D-152: EHOS 0.24.0 and later say whether the caller may confirm each claim.
    test "keeps whether a claim may be confirmed, where EHOS says it", %{
      provider: provider,
      opts: opts
    } do
      own = Map.put(@waiting, "confirmable", true)
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [own]})

      {0, json, ""} = ehosctl(["people", "github", "list", "--json"], opts)
      assert %{"accounts" => [%{"confirmable" => true}]} = JSON.decode!(json)
    end

    test "says which claim is your own, and refuses to confirm it without asking", %{
      provider: provider,
      opts: opts
    } do
      own = %{@waiting | "contested" => true} |> Map.put("confirmable", false)
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [own]})

      {0, stdout, ""} = ehosctl(["people", "github", "list"], opts)
      assert stdout =~ "yours: another people manager confirms it; someone else claims it too"

      assert ehosctl(["people", "github", "confirm", @account], opts) ==
               {1, "",
                "ehosctl: You cannot confirm your own claim. Another people manager must confirm it.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/github-accounts/#{@account}/confirm") ==
               []
    end

    test "refuses a claim whose confirmable is not a yes or no", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/github-accounts", 200, %{
        "accounts" => [Map.put(@waiting, "confirmable", "true")]
      })

      assert ehosctl(["people", "github", "list"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end

    test "confirms a claim with the GitHub id it was shown, after asking",
         %{provider: provider, opts: opts} do
      contested = %{@waiting | "contested" => true}
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [contested]})

      api(provider, "POST", "/api/v1/github-accounts/#{@account}/confirm", 200, %{
        "account" => %{@claimed | "confirmed_at" => "2026-10-16T10:05:00Z"}
      })

      mock_answer(true)

      assert ehosctl(["people", "github", "confirm", @account], opts) ==
               {0, @confirmed_stdout, ""}

      assert_received {:asked, question}

      assert question ==
               "grace@example.com claims grace-h, GitHub id 4242, from this run:\n" <>
                 "  acme/ledger at refs/pull/12/merge, pull_request, commit 0123456789ab, " <>
                 "16 October 2026, 09:58 UTC\n" <>
                 "  https://github.com/acme/ledger/actions/runs/99\n" <>
                 "Another person also claims this account. Confirm it only for the person whose " <>
                 "run this is.\n" <>
                 "Have you checked with them that it is theirs? [y/N] "

      assert json_requests(provider, "POST " <> "/api/v1/github-accounts/#{@account}/confirm") ==
               [
                 json_request("/api/v1/github-accounts/#{@account}/confirm", %{
                   "github_id" => 4242
                 })
               ]
    end

    test "lists and confirms a claim EHOS keeps no run for, saying so",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/github-accounts", 200, %{
        "accounts" => [%{@waiting | "run" => nil}]
      })

      api(provider, "POST", "/api/v1/github-accounts/#{@account}/confirm", 200, %{
        "account" => %{@claimed | "confirmed_at" => "2026-10-16T10:05:00Z"}
      })

      {0, stdout, ""} = ehosctl(["people", "github", "list"], opts)

      assert stdout == """
              PERSON             LOGIN    REPOSITORY  NOTE    ID
              grace@example.com  grace-h  <none>      <none>  #{@account}
             """

      mock_answer(true)

      assert ehosctl(["people", "github", "confirm", @account], opts) ==
               {0, @confirmed_stdout, ""}

      assert_received {:asked, question}

      assert question ==
               "grace@example.com claims grace-h, GitHub id 4242, from this run:\n" <>
                 "  EHOS does not show this run any more. Ask the person which run it was.\n" <>
                 "Have you checked with them that it is theirs? [y/N] "
    end

    test "says a run's field GitHub did not sign is unknown", %{provider: provider, opts: opts} do
      run = %{@refused_run | "ref" => nil, "event_name" => nil, "at" => nil}

      api(provider, "GET", "/api/v1/github-accounts", 200, %{
        "accounts" => [%{@waiting | "run" => run}]
      })

      mock_answer(false)

      assert ehosctl(["people", "github", "confirm", @account], opts) ==
               {0, "You did not confirm the claim.\n", ""}

      assert_received {:asked, question}

      assert question ==
               "grace@example.com claims grace-h, GitHub id 4242, from this run:\n" <>
                 "  acme/ledger at unknown, unknown, commit 0123456789ab, unknown\n" <>
                 "  https://github.com/acme/ledger/actions/runs/99\n" <>
                 "Have you checked with them that it is theirs? [y/N] "
    end

    test "removes a person's account", %{provider: provider, opts: opts} do
      removed = %{@claimed | "removed_at" => "2026-10-16T11:00:00Z"}
      api(provider, "DELETE", "/api/v1/github-accounts/#{@account}", 200, %{"account" => removed})

      assert ehosctl(["people", "github", "remove", @account], opts) ==
               {0, "Removed grace-h. EHOS refuses the next run of the account.\n", ""}
    end

    test "confirms nothing that is not waiting, and nothing not checked",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [@waiting]})

      assert ehosctl(["people", "github", "confirm", "c-9", "--yes"], opts) ==
               {1, "",
                "ehosctl: c-9 is not a claim that waits for confirmation. Run " <>
                  "`ehosctl people github list` to see the claims.\n"}

      mock_answer(false)

      assert ehosctl(["people", "github", "confirm", @account], opts) ==
               {0, "You did not confirm the claim.\n", ""}

      assert FakeProvider.requests(provider, "POST /api/v1/github-accounts/#{@account}/confirm") ==
               []
    end

    test "prints EHOS's refusal of a claim that changed", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [@waiting]})

      api(provider, "POST", "/api/v1/github-accounts/#{@account}/confirm", 409, %{
        "error" => "changed",
        "message" => "The claim changed, was withdrawn or was confirmed since it was shown."
      })

      assert ehosctl(["people", "github", "confirm", @account, "--yes"], opts) ==
               {1, "",
                "ehosctl: The claim changed, was withdrawn or was confirmed since it was shown.\n"}
    end

    test "refuses a claim whose run is not one", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/github-accounts", 200, %{
        "accounts" => [%{@waiting | "run" => %{"repository" => 7}}]
      })

      assert ehosctl(["people", "github", "list"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end
  end

  # The POSTs sent to `path`, each body decoded.

  # The person is asked once, and answers yes, with `true`, or no.
  defp mock_answer(yes?) do
    test = self()

    expect(Ehosctl.TerminalMock, :gets, fn question ->
      send(test, {:asked, question})
      if yes?, do: "y\n", else: "n\n"
    end)
  end
end

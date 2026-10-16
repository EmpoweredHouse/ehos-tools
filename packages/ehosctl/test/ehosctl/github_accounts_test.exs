defmodule Ehosctl.GitHubAccountsTest do
  use Ehosctl.SignInCase

  @account "6c5b4a39-2817-4f6e-9d0c-1b2a3c4d5e6f"
  @run "8e7d6c5b-4a39-4281-9f6e-0d1c2b3a4f5e"
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

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp api(provider, method, path, status, body),
    do: FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  defp sent(provider, key) do
    [request | _] = FakeProvider.requests(provider, key)
    JSON.decode!(request.body)
  end

  defp answering(answer) do
    fn question ->
      send(self(), {:asked, question})
      answer
    end
  end

  describe "a person's own" do
    test "lists their accounts and the runs they may claim one from",
         %{provider: provider, opts: opts} do
      linked = %{@claimed | "confirmed_at" => "2026-10-16T10:05:00Z"}

      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [linked],
        "claimable" => [@refused_run]
      })

      {0, stdout, ""} = ehosctl(["github", "list"], opts)
      assert stdout =~ ~r/grace-h\s+4242\s+linked\s+#{@account}/
      assert stdout =~ "ehosctl github claim RUN"
      assert stdout =~ ~r/grace-h\s+acme\/ledger\s+refs\/pull\/12\/merge.*#{@run}/

      {0, json, ""} = ehosctl(["github", "list", "--json"], opts)
      assert %{"accounts" => [^linked], "claimable" => [@refused_run]} = JSON.decode!(json)
    end

    test "claims from the only run there is, after showing it and asking",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => [@refused_run]
      })

      api(provider, "POST", "/api/v1/me/github-accounts", 201, %{"account" => @claimed})

      {0, stdout, ""} = ehosctl(["github", "claim"], [confirm: answering(true)] ++ opts)
      assert stdout =~ "Claimed grace-h: account #{@account}. A people manager confirms it"

      assert_received {:asked, question}
      assert question =~ "grace-h, GitHub id 4242"
      assert question =~ "acme/ledger at refs/pull/12/merge, pull_request, commit 0123456789ab"
      assert question =~ "https://github.com/acme/ledger/actions/runs/99"
      assert question =~ "Is this run yours?"

      assert sent(provider, "POST /api/v1/me/github-accounts") == %{"exchange" => @run}
    end

    test "sends nothing when the run is not theirs", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => [@refused_run]
      })

      {0, stdout, ""} = ehosctl(["github", "claim"], [confirm: answering(false)] ++ opts)
      assert stdout =~ "Nothing was claimed."
      assert FakeProvider.requests(provider, "POST /api/v1/me/github-accounts") == []
    end

    test "asks to name a run among several, and none when there are none",
         %{provider: provider, opts: opts} do
      other = %{@refused_run | "exchange" => "1d2c3b4a-5968-4776-8584-93a2b1c0d9e8"}

      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => [@refused_run, other]
      })

      assert {2, _stdout, stderr} = ehosctl(["github", "claim", "--yes"], opts)
      assert stderr =~ "You have several runs to claim from"

      api(provider, "POST", "/api/v1/me/github-accounts", 201, %{"account" => @claimed})
      {0, _stdout, ""} = ehosctl(["github", "claim", String.upcase(@run), "--yes"], opts)
      assert sent(provider, "POST /api/v1/me/github-accounts") == %{"exchange" => @run}

      api(provider, "GET", "/api/v1/me/github-accounts", 200, %{
        "accounts" => [],
        "claimable" => []
      })

      assert {1, _stdout, stderr} = ehosctl(["github", "claim", "--yes"], opts)
      assert stderr =~ "No refused run of yours can be claimed from"
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

      assert {2, _stdout, stderr} = ehosctl(["github", "claim", "--yes"], opts)
      assert stderr =~ "not a refused run of yours"
    end

    test "removes one of their accounts", %{provider: provider, opts: opts} do
      removed = %{@claimed | "removed_at" => "2026-10-16T11:00:00Z"}

      api(provider, "DELETE", "/api/v1/me/github-accounts/#{@account}", 200, %{
        "account" => removed
      })

      {0, stdout, ""} = ehosctl(["github", "remove", @account], opts)
      assert stdout =~ "Removed grace-h: its next run is refused."
    end
  end

  describe "a people manager's" do
    test "lists the claims waiting, and which are contested", %{provider: provider, opts: opts} do
      contested = %{@waiting | "id" => "c-2", "contested" => true}
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [@waiting, contested]})

      {0, stdout, ""} = ehosctl(["people", "github", "list"], opts)
      assert stdout =~ ~r/grace@example\.com\s+grace-h\s+acme\/ledger\s+#{@account}/
      assert stdout =~ ~r/someone else claims it too\s+c-2/

      {0, json, ""} = ehosctl(["people", "github", "list", "--json"], opts)
      assert %{"accounts" => [@waiting, _]} = JSON.decode!(json)
    end

    test "confirms a claim with the GitHub id it was shown, after asking",
         %{provider: provider, opts: opts} do
      contested = %{@waiting | "contested" => true}
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [contested]})

      api(provider, "POST", "/api/v1/github-accounts/#{@account}/confirm", 200, %{
        "account" => %{@claimed | "confirmed_at" => "2026-10-16T10:05:00Z"}
      })

      {0, stdout, ""} =
        ehosctl(["people", "github", "confirm", @account], [confirm: answering(true)] ++ opts)

      assert stdout =~ "Confirmed grace-h for grace@example.com"

      assert_received {:asked, question}
      assert question =~ "grace@example.com claims grace-h, GitHub id 4242"
      assert question =~ "Someone else claims this account too"
      assert question =~ "Have you checked with them"

      assert sent(provider, "POST /api/v1/github-accounts/#{@account}/confirm") ==
               %{"github_id" => 4242}
    end

    test "confirms nothing that is not waiting, and nothing not checked",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [@waiting]})

      assert {1, _stdout, stderr} =
               ehosctl(["people", "github", "confirm", "c-9", "--yes"], opts)

      assert stderr =~ "is no claim waiting"

      {0, stdout, ""} =
        ehosctl(["people", "github", "confirm", @account], [confirm: answering(false)] ++ opts)

      assert stdout =~ "Nothing was confirmed."

      assert FakeProvider.requests(provider, "POST /api/v1/github-accounts/#{@account}/confirm") ==
               []
    end

    test "prints EHOS's refusal of a claim that changed", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/github-accounts", 200, %{"accounts" => [@waiting]})

      api(provider, "POST", "/api/v1/github-accounts/#{@account}/confirm", 409, %{
        "error" => "changed",
        "message" => "The claim changed, was withdrawn or was confirmed since it was shown."
      })

      assert {1, _stdout, stderr} =
               ehosctl(["people", "github", "confirm", @account, "--yes"], opts)

      assert stderr =~ "The claim changed"
    end

    test "removes a person's account", %{provider: provider, opts: opts} do
      removed = %{@claimed | "removed_at" => "2026-10-16T11:00:00Z"}
      api(provider, "DELETE", "/api/v1/github-accounts/#{@account}", 200, %{"account" => removed})

      {0, stdout, ""} = ehosctl(["people", "github", "remove", @account], opts)
      assert stdout =~ "Removed grace-h"
    end
  end
end

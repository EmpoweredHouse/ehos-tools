defmodule Ehosctl.AuditAgentsTest do
  # `ehosctl audit`, `activity` and `agents` (eh-os#343).
  use Ehosctl.SignInCase

  @row %{
    "id" => "e-1",
    "occurred_at" => "2026-10-10T18:32:31.004211Z",
    "actor" => "ada@example.com",
    "via" => "api",
    "action" => "role_binding.bind",
    "capability" => "ehos.role_binding.manage",
    "outcome" => "refused",
    "reason" => "not_in_force",
    "application" => "ledger",
    "environment" => "staging",
    "subject" => "bob@example.com",
    "details" => %{"role" => "ledger.nope"}
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp row(n), do: %{@row | "id" => "e-#{n}", "details" => %{"n" => n}}

  # Pages of `rows`, two to a page, each naming the next by its first row's index.
  defp serve(provider, path, rows) do
    FakeProvider.stub_api(provider, "GET", path, fn %{query: query} ->
      start = String.to_integer(query["after"] || "0")
      page = Enum.slice(rows, start, 2)
      next = start + 2

      if next < length(rows),
        do:
          {200, [{"link", ~s(<#{path}?limit=2&after=#{next}>; rel="next")}], %{"events" => page}},
        else: {200, %{"events" => page}}
    end)
  end

  describe "audit" do
    test "prints the newest decisions, as the page shows them", %{provider: provider, opts: opts} do
      serve(provider, "/api/v1/audit", [@row])

      {0, stdout, ""} = ehosctl(["audit"], opts)
      assert stdout =~ ~r/WHEN\s+WHO\s+ACTION\s+OUTCOME\s+WHERE\s+ABOUT\s+DETAILS/
      assert stdout =~ "refused: not_in_force"
      assert stdout =~ "ledger in staging"
      assert stdout =~ ~s({"role":"ledger.nope"})

      # One row more than the 100 printed, to tell whether older ones remain.
      assert [%{query: %{"limit" => "101"}}] =
               FakeProvider.requests(provider, "GET /api/v1/audit")
    end

    test "follows the pages up to --limit, and says older ones remain",
         %{provider: provider, opts: opts} do
      serve(provider, "/api/v1/audit", Enum.map(1..5, &row/1))

      {0, json, ""} = ehosctl(["audit", "--limit", "3", "--json"], opts)
      assert %{"events" => events, "more" => true} = JSON.decode!(json)
      assert Enum.map(events, & &1["id"]) == ["e-1", "e-2", "e-3"]

      {0, stdout, ""} = ehosctl(["audit", "--limit", "3"], opts)
      assert stdout =~ "Older decisions remain"

      {0, json, ""} = ehosctl(["audit", "--json"], opts)
      assert %{"events" => all, "more" => false} = JSON.decode!(json)
      assert length(all) == 5
    end

    test "says who acted when nobody did, and refuses a --limit below 1",
         %{provider: provider, opts: opts} do
      release = %{@row | "actor" => nil, "via" => "release", "application" => nil}
      serve(provider, "/api/v1/audit", [release])

      {0, stdout, ""} = ehosctl(["audit"], opts)
      assert stdout =~ "a release command"
      assert stdout =~ "the whole platform"

      {2, "", stderr} = ehosctl(["audit", "--limit", "0"], opts)
      assert stderr =~ "--limit"
    end

    test "a refused read exits 3, and a row EHOS would not give is not printed",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/audit", fn _ ->
        {403,
         %{"error" => "forbidden", "message" => "Reading the audit record needs ehos.audit.read."}}
      end)

      {3, "", stderr} = ehosctl(["audit"], opts)
      assert stderr =~ "ehos.audit.read"

      serve(provider, "/api/v1/audit", [%{@row | "details" => "not a map"}])
      {1, "", stderr} = ehosctl(["audit"], opts)
      assert stderr =~ "cannot read"
    end
  end

  test "a last page exactly full is the last when the next is empty, and a page is at most 500",
       %{provider: provider, opts: opts} do
    # As EHOS answers: a next page named whenever one is full, however many rows remain.
    FakeProvider.stub_api(provider, "GET", "/api/v1/audit", fn %{query: query} ->
      limit = String.to_integer(query["limit"])

      case query["after"] do
        nil ->
          rows = Enum.map(1..min(limit, 2), &row/1)

          link =
            if length(rows) == limit,
              do: [{"link", ~s(</api/v1/audit?limit=#{limit}&after=end>; rel="next")}],
              else: []

          {200, link, %{"events" => rows}}

        "end" ->
          {200, %{"events" => []}}
      end
    end)

    {0, json, ""} = ehosctl(["audit", "--limit", "2", "--json"], opts)
    assert %{"events" => [_, _], "more" => false} = JSON.decode!(json)

    {0, _json, ""} = ehosctl(["audit", "--limit", "600", "--json"], opts)

    assert %{query: %{"limit" => "500"}} =
             List.last(FakeProvider.requests(provider, "GET /api/v1/audit"))

    {0, _json, ""} = ehosctl(["audit", "--limit", "10000", "--json"], opts)

    {2, "", stderr} = ehosctl(["audit", "--limit", "10001"], opts)
    assert stderr =~ "from 1 to 10000"
  end

  test "a next page anywhere but the list's own is not followed", %{
    provider: provider,
    opts: opts
  } do
    for target <- [
          "/api/v1/people?after=x",
          "/api/v1/audit?after=x",
          "/api/v1/me/activity/x?after=x"
        ] do
      FakeProvider.stub_api(provider, "GET", "/api/v1/me/activity", fn _ ->
        {200, [{"link", ~s(<#{target}>; rel="next")}], %{"events" => [row(1)]}}
      end)

      {1, "", stderr} = ehosctl(["activity"], opts)
      assert stderr =~ "a next page ehosctl cannot follow"
    end

    assert FakeProvider.requests(provider, "GET /api/v1/people") == []
  end

  test "activity reads one's own rows, in pages", %{provider: provider, opts: opts} do
    serve(provider, "/api/v1/me/activity", Enum.map(1..3, &row/1))

    {0, json, ""} = ehosctl(["activity", "--json"], opts)
    assert %{"events" => [_, _, _], "more" => false} = JSON.decode!(json)
    assert length(FakeProvider.requests(provider, "GET /api/v1/me/activity")) == 2
  end

  describe "agents" do
    @agent %{"id" => "a-1", "name" => "month-closer", "created_at" => "2026-10-10T18:00:00Z"}

    test "lists and creates one's agents", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/me/agents", fn _ ->
        {200, %{"agents" => [@agent]}}
      end)

      FakeProvider.stub_api(provider, "POST", "/api/v1/me/agents", fn _ ->
        {201, %{"agent" => @agent}}
      end)

      {0, stdout, ""} = ehosctl(["agents", "list"], opts)
      assert stdout =~ ~r/month-closer\s+2026-10-10T18:00:00Z\s+a-1/

      {0, stdout, ""} = ehosctl(["agents", "create", "month-closer"], opts)
      assert stdout =~ "Created the agent month-closer, a-1."
      assert stdout =~ "--to a-1`"

      assert [%{body: body}] = FakeProvider.requests(provider, "POST /api/v1/me/agents")
      assert JSON.decode!(body) == %{"name" => "month-closer"}
    end

    test "a name that prints as nothing is refused before it is sent",
         %{provider: provider, opts: opts} do
      for name <- ["a\u202Eb", "bot\n", "a\u2028b"] do
        {2, "", stderr} = ehosctl(["agents", "create", name], opts)
        assert stderr =~ "a person can read"
      end

      assert FakeProvider.requests(provider, "POST /api/v1/me/agents") == []

      # Joiners stay: emoji and several scripts are written with them.
      FakeProvider.stub_api(provider, "POST", "/api/v1/me/agents", fn %{body: body} ->
        {201, %{"agent" => %{"id" => "a-2", "name" => JSON.decode!(body)["name"]}}}
      end)

      for name <- [
            "\u{1F9D1}\u200D\u{1F4BB} coder",
            "\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645"
          ] do
        assert {0, _stdout, ""} = ehosctl(["agents", "create", name], opts)
      end
    end

    test "a name used already exits 2, and one past the cap exits 1",
         %{provider: provider, opts: opts} do
      for {status, code, exit} <- [{422, "invalid", 2}, {409, "too_many_agents", 1}] do
        FakeProvider.stub_api(provider, "POST", "/api/v1/me/agents", fn _ ->
          {status, %{"error" => code, "message" => "EHOS says #{code}."}}
        end)

        {^exit, "", stderr} = ehosctl(["agents", "create", "helper"], opts)
        assert stderr =~ "EHOS says #{code}."
      end
    end
  end
end

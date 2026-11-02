defmodule Ehosctl.AuditAgentsTest do
  # `ehosctl audit`, `activity` and `agents` (eh-os#343). Not async, through
  # `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process shares.
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

  @agent %{"id" => "a-1", "name" => "month-closer", "created_at" => "2026-10-10T18:00:00Z"}

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "audit" do
    test "prints the newest decisions, as the page shows them", %{provider: provider, opts: opts} do
      serve(provider, "/api/v1/audit", [@row])

      {0, stdout, ""} = ehosctl(["audit"], opts)

      assert stdout == """
              WHEN                         WHO              ACTION             OUTCOME                WHERE              ABOUT            DETAILS
              2026-10-10T18:32:31.004211Z  ada@example.com  role_binding.bind  refused: not_in_force  ledger in staging  bob@example.com  {"role":"ledger.nope"}
             """

      # One row more than the 100 printed, to tell whether older ones remain.
      assert FakeProvider.requests(provider, "GET /api/v1/audit") == [
               list_request("/api/v1/audit", %{"limit" => "101"})
             ]
    end

    test "follows the pages up to --limit, and says older ones remain",
         %{provider: provider, opts: opts} do
      serve(provider, "/api/v1/audit", Enum.map(1..5, &row/1))

      {0, json, ""} = ehosctl(["audit", "--limit", "3", "--json"], opts)
      assert JSON.decode!(json) == %{"events" => Enum.map(1..3, &row/1), "more" => true}

      {0, stdout, ""} = ehosctl(["audit", "--limit", "3"], opts)

      assert stdout == """
              WHEN                         WHO              ACTION             OUTCOME                WHERE              ABOUT            DETAILS
              2026-10-10T18:32:31.004211Z  ada@example.com  role_binding.bind  refused: not_in_force  ledger in staging  bob@example.com  {"n":1}
              2026-10-10T18:32:31.004211Z  ada@example.com  role_binding.bind  refused: not_in_force  ledger in staging  bob@example.com  {"n":2}
              2026-10-10T18:32:31.004211Z  ada@example.com  role_binding.bind  refused: not_in_force  ledger in staging  bob@example.com  {"n":3}
             Older decisions remain: a larger --limit reads further.
             """

      {0, json, ""} = ehosctl(["audit", "--json"], opts)
      assert JSON.decode!(json) == %{"events" => Enum.map(1..5, &row/1), "more" => false}
    end

    test "a last page exactly full is the last when the next is empty, and a page is at most 500",
         %{provider: provider, opts: opts} do
      # Two rows: `--limit 2` asks for three, gets two and no next page, and so has them all.
      serve_full_pages(provider, 2)

      {0, json, ""} = ehosctl(["audit", "--limit", "2", "--json"], opts)
      assert JSON.decode!(json) == %{"events" => [row(1), row(2)], "more" => false}

      # 500 rows: a page of 500 is full, so EHOS names a next one, which is empty.
      serve_full_pages(provider, 500)
      all = %{"events" => Enum.map(1..500, &row/1), "more" => false}

      {0, json, ""} = ehosctl(["audit", "--limit", "500", "--json"], opts)
      assert JSON.decode!(json) == all

      {0, json, ""} = ehosctl(["audit", "--limit", "600", "--json"], opts)
      assert JSON.decode!(json) == all

      {0, json, ""} = ehosctl(["audit", "--limit", "10000", "--json"], opts)
      assert JSON.decode!(json) == all

      first = list_request("/api/v1/audit", %{"limit" => "500"})
      next = list_request("/api/v1/audit", %{"limit" => "500", "after" => "end"})

      assert FakeProvider.requests(provider, "GET /api/v1/audit") ==
               [
                 list_request("/api/v1/audit", %{"limit" => "3"})
                 | [first, next, first, next, first, next]
               ]

      assert ehosctl(["audit", "--limit", "10001"], opts) ==
               {2, "", "ehosctl: --limit is a whole number from 1 to 10000.\n"}
    end

    test "says who acted when nobody did, and refuses a --limit below 1",
         %{provider: provider, opts: opts} do
      release = %{@row | "actor" => nil, "via" => "release", "application" => nil}
      serve(provider, "/api/v1/audit", [release])

      {0, stdout, ""} = ehosctl(["audit"], opts)

      assert stdout == """
              WHEN                         WHO                ACTION             OUTCOME                WHERE               ABOUT            DETAILS
              2026-10-10T18:32:31.004211Z  a release command  role_binding.bind  refused: not_in_force  the whole platform  bob@example.com  {"role":"ledger.nope"}
             """

      assert ehosctl(["audit", "--limit", "0"], opts) ==
               {2, "", "ehosctl: --limit is a whole number from 1 to 10000.\n"}
    end

    test "a refused read exits 3, and a row EHOS would not give is not printed",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/audit", fn _ ->
        {403,
         %{"error" => "forbidden", "message" => "Reading the audit record needs ehos.audit.read."}}
      end)

      assert ehosctl(["audit"], opts) ==
               {3, "", "ehosctl: Reading the audit record needs ehos.audit.read.\n"}

      serve(provider, "/api/v1/audit", [%{@row | "details" => "not a map"}])

      assert ehosctl(["audit"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end
  end

  describe "activity" do
    test "reads one's own rows, in pages", %{provider: provider, opts: opts} do
      serve(provider, "/api/v1/me/activity", Enum.map(1..3, &row/1))

      {0, json, ""} = ehosctl(["activity", "--json"], opts)
      assert JSON.decode!(json) == %{"events" => Enum.map(1..3, &row/1), "more" => false}

      assert FakeProvider.requests(provider, "GET /api/v1/me/activity") == [
               list_request("/api/v1/me/activity", %{"limit" => "101"}),
               list_request("/api/v1/me/activity", %{"limit" => "2", "after" => "2"})
             ]
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
        serve_next_page_at(provider, target)

        assert ehosctl(["activity"], opts) ==
                 {1, "", "ehosctl: #{provider.issuer} gave a next page ehosctl cannot follow.\n"}
      end

      assert FakeProvider.requests(provider, "GET /api/v1/people") == []
    end
  end

  describe "agents" do
    test "lists and creates one's agents", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/me/agents", fn _ ->
        {200, %{"agents" => [@agent]}}
      end)

      FakeProvider.stub_api(provider, "POST", "/api/v1/me/agents", fn _ ->
        {201, %{"agent" => @agent}}
      end)

      {0, stdout, ""} = ehosctl(["agents", "list"], opts)

      assert stdout == """
              NAME          CREATED               ID
              month-closer  2026-10-10T18:00:00Z  a-1
             """

      assert ehosctl(["agents", "create", "month-closer"], opts) ==
               {0,
                "Created the agent month-closer, a-1. It holds no role yet. To bind a role to " <>
                  "it, run `ehosctl role-bindings bind <role> --to a-1`.\n", ""}

      assert FakeProvider.requests(provider, "POST /api/v1/me/agents") == [
               %{
                 path: "/api/v1/me/agents",
                 query: %{},
                 body: ~s({"name":"month-closer"}),
                 content_type: "application/json"
               }
             ]
    end

    test "a name that prints as nothing is refused before it is sent",
         %{provider: provider, opts: opts} do
      for {name, shown} <- [
            {"a\u202Eb", ~S("a\u202Eb")},
            {"bot\n", ~S("bot\n")},
            {"a\u2028b", ~S("a\u2028b")}
          ] do
        assert ehosctl(["agents", "create", name], opts) ==
                 {2, "",
                  "ehosctl: #{shown} contains characters that do not print or that move the " <>
                    "text around them. Give a name that a person can read.\n"}
      end

      assert FakeProvider.requests(provider, "POST /api/v1/me/agents") == []

      # Joiners stay: emoji and several scripts are written with them.
      FakeProvider.stub_api(provider, "POST", "/api/v1/me/agents", fn %{body: body} ->
        {201, %{"agent" => %{"id" => "a-2", "name" => JSON.decode!(body)["name"]}}}
      end)

      for {name, shown} <- [
            {"\u{1F9D1}\u200D\u{1F4BB} coder", "\"\u{1F9D1}\\u200D\u{1F4BB} coder\""},
            {"\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645",
             "\"\u0645\u06CC\\u200C\u062E\u0648\u0627\u0647\u0645\""}
          ] do
        assert ehosctl(["agents", "create", name], opts) ==
                 {0,
                  "Created the agent #{shown}, a-2. It holds no role yet. To bind a role to " <>
                    "it, run `ehosctl role-bindings bind <role> --to a-2`.\n", ""}
      end
    end

    test "a name used already exits 2, and one past the cap exits 1",
         %{provider: provider, opts: opts} do
      for {status, code, exit} <- [{422, "invalid", 2}, {409, "too_many_agents", 1}] do
        FakeProvider.stub_api(provider, "POST", "/api/v1/me/agents", fn _ ->
          {status, %{"error" => code, "message" => "EHOS says #{code}."}}
        end)

        assert ehosctl(["agents", "create", "helper"], opts) ==
                 {exit, "", "ehosctl: EHOS says #{code}.\n"}
      end
    end
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

  # A record of `total` rows that all fit on the first page, as EHOS answers it: a next page
  # named whenever one is full, however many rows remain, and that one empty.
  defp serve_full_pages(provider, total) do
    FakeProvider.stub_api(provider, "GET", "/api/v1/audit", fn %{query: query} ->
      limit = String.to_integer(query["limit"])

      case query["after"] do
        nil -> first_page(limit, total)
        "end" -> {200, %{"events" => []}}
      end
    end)
  end

  # The first `limit` rows, and a link to the next page when they fill it.
  defp first_page(limit, total) do
    rows = Enum.map(1..min(limit, total), &row/1)

    link =
      if length(rows) == limit,
        do: [{"link", ~s(</api/v1/audit?limit=#{limit}&after=end>; rel="next")}],
        else: []

    {200, link, %{"events" => rows}}
  end

  defp list_request(path, query),
    do: %{path: path, query: query, body: "", content_type: nil}

  defp serve_next_page_at(provider, target) do
    FakeProvider.stub_api(provider, "GET", "/api/v1/me/activity", fn _ ->
      {200, [{"link", ~s(<#{target}>; rel="next")}], %{"events" => [row(1)]}}
    end)
  end
end

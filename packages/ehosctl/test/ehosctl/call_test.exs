defmodule Ehosctl.CallTest do
  use Ehosctl.SignInCase

  alias Ehosctl.FakeApplication

  @capabilities [
    %{"name" => "ledger.record_entry", "label" => "Record an entry", "kind" => "command"},
    %{"name" => "ledger.entry_noted", "label" => "Note an entry", "kind" => "record"},
    %{"name" => "ledger.balance", "label" => "Balance", "kind" => "query"}
  ]

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    app = FakeApplication.start(provider)
    FakeProvider.put_me(provider, applications: [entry(app, "staging")])
    %{app: app}
  end

  defp entry(app, environment) do
    %{
      "application" => "ledger",
      "environment" => environment,
      "audience" => "ledger/#{environment}",
      "address" => app.address,
      "roles" => ["ledger.clerk"],
      "capabilities" => @capabilities
    }
  end

  defp credential_for(provider, request) do
    "Bearer " <> token = request.authorization
    FakeProvider.resource(provider, token)
  end

  describe "credential" do
    test "prints a credential for the application's address, and the same one while it lasts",
         %{provider: provider, app: app, opts: opts} do
      {0, stdout, ""} = ehosctl(["credential", "ledger"], opts)
      credential = String.trim_trailing(stdout)

      assert FakeProvider.resource(provider, credential) == app.address
      assert [_one] = Enum.filter(renewals(provider), &(&1["resource"] == app.address))

      {0, stdout, ""} = ehosctl(["credential", "ledger", "--json"], opts)

      assert %{
               "application" => "ledger",
               "environment" => "staging",
               "audience" => "ledger/staging",
               "address" => address,
               "credential" => ^credential
             } = JSON.decode!(stdout)

      assert address == app.address
      refute stdout =~ "refresh"
    end

    test "needs --env when roles are bound in several environments, and names them",
         %{provider: provider, app: app, opts: opts} do
      FakeProvider.put_me(provider,
        applications: [entry(app, "staging"), entry(app, "production")]
      )

      assert {2, "",
              "ehosctl: You hold roles in ledger in staging, production. Name one with --env.\n"} =
               ehosctl(["credential", "ledger"], opts)

      assert {0, _credential, ""} = ehosctl(["credential", "ledger", "--env", "production"], opts)
    end

    test "an application or environment without a role of yours is refused", %{opts: opts} do
      assert {3, "", "ehosctl: None of your roles is bound in journal." <> _} =
               ehosctl(["credential", "journal"], opts)

      assert {3, "", "ehosctl: None of your roles is bound in ledger in production; " <> _} =
               ehosctl(["credential", "ledger", "--env", "production"], opts)
    end

    test "EHOS refusing it, where nothing is granted, exits 3 in refusals.md's words",
         %{provider: provider, opts: opts} do
      # The credential for EHOS's API is cached, so only the application's is renewed.
      for code <- ["invalid_target", "no_capability"] do
        FakeProvider.answer_token(provider, 400, %{"error" => code})

        assert {3, "", "ehosctl: None of your roles grants anything in that application" <> _} =
                 ehosctl(["credential", "ledger"], opts)
      end
    end

    test "a credential with a terminal's control characters is not printed",
         %{provider: provider, opts: opts} do
      FakeProvider.answer_token(provider, 200, %{
        "access_token" => "x\e]52;c;aGk=\a",
        "refresh_token" => "refresh-next"
      })

      assert {1, "", "ehosctl: EHOS issued a credential ehosctl does not print.\n"} =
               ehosctl(["credential", "ledger"], opts)
    end
  end

  describe "call" do
    test "sends to the application trusting the CA kept for its installation (T-14)" do
      opts = [ca: {"staging", "pem"}, config_dir: "/c", timeout: 1]

      assert Ehosctl.Call.http_opts(%{headers: [{"idempotency-key", "k"}]}, opts) ==
               [headers: [{"idempotency-key", "k"}], ca: {"staging", "pem"}]
    end

    test "sends a command with typed fields, a new idempotency key and the application's credential",
         %{provider: provider, app: app, opts: opts} do
      {0, stdout, ""} =
        ehosctl(
          ["call", "ledger", "ledger.record_entry", "amount:=100", "note=rent", "paid:=true"],
          opts
        )

      assert stdout == """
             Done: ledger.record_entry, as 0192d3a4-command.
               event: ledger.entry_recorded at position 7
             """

      assert [request] = FakeApplication.requests(app)
      assert request.method == "POST"
      assert request.path == "/api/commands/ledger.record_entry"
      assert request.body == %{"amount" => 100, "note" => "rent", "paid" => true}

      assert request.idempotency_key =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      assert credential_for(provider, request) == app.address

      {0, _stdout, ""} = ehosctl(["call", "ledger", "ledger.record_entry", "amount:=1"], opts)
      [first, second] = FakeApplication.requests(app)
      assert first.idempotency_key != second.idempotency_key
    end

    test "sends the idempotency key given, and says when it was already done",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, 200, %{
        "command_id" => "0192d3a4-command",
        "identity" => %{"entry_id" => "e-1"},
        "duplicate" => true,
        "events" => []
      })

      {0, stdout, ""} =
        ehosctl(
          ["call", "ledger", "ledger.record_entry", "--idempotency-key", "req-81", "amount:=1"],
          opts
        )

      assert stdout ==
               "Already done with this idempotency key, as 0192d3a4-command; nothing was " <>
                 "recorded again.\n  identity: {\"entry_id\":\"e-1\"}\n"

      assert [%{idempotency_key: "req-81"}] = FakeApplication.requests(app)
    end

    test "--json prints the application's receipt", %{opts: opts} do
      {0, stdout, ""} = ehosctl(["call", "ledger", "ledger.record_entry", "--json"], opts)

      assert %{"command_id" => "0192d3a4-command", "position" => 7, "duplicate" => false} =
               JSON.decode!(stdout)
    end

    test "sends a recording to records, with its body", %{app: app, opts: opts} do
      {0, _stdout, ""} = ehosctl(["call", "ledger", "ledger.entry_noted", "entry_id=e-1"], opts)

      assert [
               %{
                 method: "POST",
                 path: "/api/records/ledger.entry_noted",
                 body: %{"entry_id" => "e-1"}
               }
             ] =
               FakeApplication.requests(app)
    end

    test "asks a query with its fields in the URL, a field given twice as a list",
         %{app: app, opts: opts} do
      {0, stdout, ""} =
        ehosctl(
          ["call", "ledger", "ledger.balance", "account=a 1", "since:=7", "tag=x", "tag=y"],
          opts
        )

      assert [request] = FakeApplication.requests(app)
      assert request.method == "GET"
      assert request.path == "/api/queries/ledger.balance"
      assert request.body == nil
      assert request.idempotency_key == nil

      assert URI.query_decoder(request.query) |> Enum.to_list() ==
               [{"account", "a 1"}, {"since", "7"}, {"tag", "x"}, {"tag", "y"}]

      # The fake answers with one row of what it was asked.
      assert stdout =~ ~s("account": "a 1")
    end

    test "a query's JSON list is repeated, and an object refused", %{app: app, opts: opts} do
      {0, _stdout, ""} = ehosctl(["call", "ledger", "ledger.balance", ~s(tag:=["x",2])], opts)
      assert [%{query: "tag=x&tag=2"}] = FakeApplication.requests(app)

      assert {2, "", "ehosctl: filter is an object" <> _} =
               ehosctl(["call", "ledger", "ledger.balance", ~s(filter:={"a":1})], opts)
    end

    test "--data gives fields from JSON, inline, in a file or on stdin, and fields go over it",
         %{app: app, opts: opts, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "entry.json")
      File.write!(file, ~s({"amount": 5, "note": "from the file"}))

      {0, _, ""} =
        ehosctl(
          ["call", "ledger", "ledger.record_entry", "--data", ~s({"amount": 1}), "note=x"],
          opts
        )

      {0, _, ""} =
        ehosctl(
          ["call", "ledger", "ledger.record_entry", "--data", "@" <> file, "amount:=6"],
          opts
        )

      stub(Ehosctl.TerminalMock, :read_input, fn :eof -> ~s({"amount": 9}) end)
      {0, _, ""} = ehosctl(["call", "ledger", "ledger.record_entry", "--data", "-"], opts)

      assert Enum.map(FakeApplication.requests(app), & &1.body) == [
               %{"amount" => 1, "note" => "x"},
               %{"amount" => 6, "note" => "from the file"},
               %{"amount" => 9}
             ]
    end

    test "a command line it cannot read sends nothing, and exits 2", %{app: app, opts: opts} do
      for {argv, message} <- [
            {["amount"], "amount is not a field"},
            {["=1"], "=1 is not a field"},
            {["amount:=1x"], "amount:= takes JSON"},
            {["note=a", "note=b"], "note is given twice"},
            {["--data", "[1]"], "--data does not hold a JSON object"},
            {["--data", "@/nonexistent/file.json"], "cannot read /nonexistent/file.json"}
          ] do
        assert {2, "", "ehosctl: " <> stderr} =
                 ehosctl(["call", "ledger", "ledger.record_entry" | argv], opts)

        assert stderr =~ message
      end

      assert FakeApplication.requests(app) == []
    end

    test "a capability no role of yours grants is sent as a command, for the application to refuse and record",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, 403, %{"refused" => "missing_capability"})

      assert {3, "",
              "ehosctl: You may not do this: it needs `ledger.close_year`, which none of your " <>
                "roles grants here." <> _} =
               ehosctl(["call", "ledger", "ledger.close_year", "year:=2026"], opts)

      assert [%{method: "POST", path: "/api/commands/ledger.close_year"}] =
               FakeApplication.requests(app)
    end

    test "EHOS refusing a credential where nothing is granted is said, and nothing reaches the application",
         %{provider: provider, app: app, opts: opts} do
      FakeProvider.answer_token(provider, 400, %{"error" => "no_capability"})

      assert {3, "", "ehosctl: None of your roles grants anything in that application" <> _} =
               ehosctl(["call", "ledger", "ledger.close_year"], opts)

      assert FakeApplication.requests(app) == []
    end

    test "a name that would leave its place in the path is refused, and nothing is sent",
         %{app: app, opts: opts} do
      for name <- ["", ".", ".."] do
        assert {2, "", "ehosctl: " <> stderr} = ehosctl(["call", "ledger", name], opts)
        assert stderr =~ "names no capability."
      end

      assert FakeApplication.requests(app) == []
    end

    test "one not granted is tried as each kind until the application finds it",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, 404, %{"error" => "not_found"})

      assert {3, "",
              "ehosctl: None of your roles grants `ledger.yearly` in ledger in staging, and the " <>
                "application has nothing of that name." <> _} =
               ehosctl(["call", "ledger", "ledger.yearly", "year:=2026"], opts)

      assert [
               %{method: "POST", path: "/api/commands/ledger.yearly"},
               %{method: "POST", path: "/api/records/ledger.yearly"},
               %{method: "GET", path: "/api/queries/ledger.yearly", query: ""}
             ] = FakeApplication.requests(app)
    end

    test "the kinds stop at the one the application finds, and a query is asked without the fields",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, "commands", 404, %{"error" => "not_found"})
      FakeApplication.answer(app, "records", 403, %{"refused" => "missing_capability"})

      assert {3, "", "ehosctl: You may not do this" <> _} =
               ehosctl(["call", "ledger", "ledger.entry_flagged", "note=x"], opts)

      assert [
               %{path: "/api/commands/" <> _},
               %{path: "/api/records/" <> _, body: %{"note" => "x"}}
             ] =
               FakeApplication.requests(app)

      FakeApplication.answer(app, "records", 404, %{"error" => "not_found"})
      FakeApplication.answer(app, "queries", 403, %{"refused" => "missing_capability"})

      assert {3, "", _stderr} = ehosctl(["call", "ledger", "ledger.yearly", "year:=2026"], opts)

      assert %{path: "/api/queries/ledger.yearly", query: ""} =
               List.last(FakeApplication.requests(app))
    end

    test "fields a kind cannot carry are what is said when no kind sent is found",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, 404, %{"error" => "not_found"})

      assert {2, "", "ehosctl: " <> stderr} =
               ehosctl(["call", "ledger", "ledger.close_year", "year:=2026", "year:=2027"], opts)

      assert stderr =~ "year"

      assert [%{method: "GET", path: "/api/queries/ledger.close_year"}] =
               FakeApplication.requests(app)
    end

    test "a gateway's 5xx on the first kind stops there, and names the key it sent",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, "commands", 502, "<html>")

      assert {5, "", stderr} =
               ehosctl(["call", "ledger", "ledger.close_year", "--idempotency-key", "k-1"], opts)

      assert stderr =~ "--idempotency-key k-1"
      assert [%{path: "/api/commands/ledger.close_year"}] = FakeApplication.requests(app)
    end

    test "an application's refusal is said in refusals.md's words, with its kind's exit code",
         %{app: app, opts: opts} do
      cases = [
        {403, %{"refused" => "missing_capability"}, 3,
         "You may not do this: it needs `ledger.record_entry`, which none of your roles grants here. " <>
           "Ask for a role binding that does."},
        {403, %{"refused" => "outside_scope"}, 3,
         "Your role does not grant this for that value."},
        {422,
         %{"invalid" => %{"amount" => "type", "account" => "required", "total" => "positive"}}, 2,
         "Some fields do not fit: `account` is required; `amount` is of the wrong type; " <>
           "`total` breaks `positive`."},
        {422, %{"rejected" => "balance_not_negative"}, 2,
         "The application refused it: balance_not_negative."},
        {422, %{"error" => "idempotency_key_required"}, 2,
         "Creating this needs an idempotency key; `ehosctl` makes one unless you give your own."},
        {409, %{"error" => "conflict"}, 1, "Something changed it at the same moment. Try again."},
        {409, %{"error" => "idempotency_key_reused"}, 1,
         "That idempotency key was used for something else. Use a new one."},
        {404, %{"error" => "not_found"}, 1,
         "The application has no `ledger.record_entry`. Run `ehosctl apps` to see what it offers."},
        {404, %{"error" => "not_created"}, 1,
         "That has not been created, so nothing can be recorded about it yet."},
        {410, %{"error" => "subject_erased"}, 1, "The personal data asked for was erased."},
        {503, %{"error" => "not_supplied"}, 5,
         "The application could not fill in a value it supplies itself, and nothing was " <>
           "written. Try again."},
        {401, %{"error" => "no_actor"}, 4,
         "The application did not receive your credential. Run `ehosctl login`."},
        {401, %{"error" => "expired"}, 4, "Your sign-in has expired. Run `ehosctl login`."},
        {502, "<html>", 5,
         "#{app.address} is unavailable (HTTP 502). Try again later. It may have been done: " <>
           "send the same call with --idempotency-key req-1 to have it done once."}
      ]

      for {status, body, code, sentence} <- cases do
        FakeApplication.answer(app, status, body)

        assert {^code, "", stderr} =
                 ehosctl(
                   ["call", "ledger", "ledger.record_entry", "--idempotency-key", "req-1"],
                   opts
                 ),
               "#{status} #{inspect(body)}"

        assert stderr == "ehosctl: #{sentence}\n"
      end
    end

    test "a refusal under --json is the kind and the sentence", %{app: app, opts: opts} do
      FakeApplication.answer(app, 403, %{"refused" => "missing_capability"})
      {3, "", stderr} = ehosctl(["call", "ledger", "ledger.record_entry", "--json"], opts)

      assert %{"error" => %{"kind" => "refused", "message" => "You may not do this" <> _}} =
               JSON.decode!(stderr)
    end

    test "a command that reached the application and got no answer it can read names its key",
         %{app: app, opts: opts} do
      FakeApplication.no_answer(app)

      {5, "", stderr} =
        ehosctl(["call", "ledger", "ledger.record_entry", "--idempotency-key", "req-9"], opts)

      assert stderr =~ "#{app.address} did not answer."
      assert stderr =~ "send the same call with --idempotency-key req-9 to have it done once"
    end

    test "an answer that says nothing was done names no key", %{app: app, opts: opts} do
      for {status, body} <- [
            {429, %{"error" => "too_many_calls"}},
            {503, %{"error" => "not_supplied", "message" => "nothing written"}},
            {503, %{"error" => "temporarily_unavailable"}}
          ] do
        FakeApplication.answer(app, status, body)
        {5, "", stderr} = ehosctl(["call", "ledger", "ledger.record_entry"], opts)
        refute stderr =~ "--idempotency-key", "#{status} #{inspect(body)}"
      end
    end

    test "a capability of a kind it does not know needs a later ehosctl",
         %{provider: provider, app: app, opts: opts} do
      watch = %{"name" => "ledger.watch", "label" => "Watch", "kind" => "subscription"}

      FakeProvider.put_me(provider,
        applications: [%{entry(app, "staging") | "capabilities" => [watch]}]
      )

      assert {1, "", "ehosctl: `ledger.watch` is a subscription, which this version of " <> _} =
               ehosctl(["call", "ledger", "ledger.watch"], opts)
    end

    test "an application it could not connect to did nothing, and no key is named",
         %{app: app, opts: opts} do
      FakeApplication.down(app)

      {5, "", stderr} = ehosctl(["call", "ledger", "ledger.record_entry"], opts)
      assert stderr == "ehosctl: #{app.address} did not answer.\n"
    end

    test "an idempotency key that could not be one is refused before anything is sent",
         %{app: app, opts: opts} do
      for key <- ["", "a b", "a\r\nx-evil: 1", String.duplicate("k", 256)] do
        assert {2, "", "ehosctl: An idempotency key is printable ASCII of at most 255 bytes.\n"} =
                 ehosctl(
                   ["call", "ledger", "ledger.record_entry", "--idempotency-key", key],
                   opts
                 )
      end

      assert FakeApplication.requests(app) == []
    end

    test "a mistyped option is not sent as a field", %{app: app, opts: opts} do
      assert {2, "",
              "ehosctl: --evn=production is not an option of `ehosctl call`; see `ehosctl help call`.\n"} =
               ehosctl(["call", "ledger", "ledger.record_entry", "--evn=production"], opts)

      assert FakeApplication.requests(app) == []
    end

    test "a query's field goes over --data, and a list of lists is refused",
         %{app: app, opts: opts} do
      {0, _stdout, ""} =
        ehosctl(
          [
            "call",
            "ledger",
            "ledger.balance",
            "--data",
            ~s({"account": "a-1", "x": 1}),
            "account=a-2"
          ],
          opts
        )

      assert [%{query: query}] = FakeApplication.requests(app)
      assert URI.decode_query(query) == %{"account" => "a-2", "x" => "1"}

      for nested <- ["[[1,2]]", "[[1]]"] do
        assert {2, "", "ehosctl: tags is an object or a list of lists" <> _} =
                 ehosctl(["call", "ledger", "ledger.balance", "tags:=" <> nested], opts)
      end
    end

    test "help says how fields are written, and that it is governed", %{opts: opts} do
      {0, help, ""} = ehosctl(["call", "--help"], opts)
      assert help =~ "name:=<JSON>"
      assert help =~ "--idempotency-key"
      assert help =~ "Plane: governed."
    end
  end

  defp renewals(provider) do
    provider
    |> FakeProvider.requests("/oauth/token")
    |> Enum.filter(&(&1["grant_type"] == "refresh_token"))
  end
end

defmodule Ehosctl.CallTest do
  use Ehosctl.SignInCase

  alias Ehosctl.FakeApplication

  doctest Ehosctl.Call

  @capabilities [
    %{"name" => "ledger.record_entry", "label" => "Record an entry", "kind" => "command"},
    %{"name" => "ledger.entry_noted", "label" => "Note an entry", "kind" => "record"},
    %{"name" => "ledger.balance", "label" => "Balance", "kind" => "query"}
  ]

  # What `call` says of a field it cannot read.
  @field "Write `name=text`, or `name:=<JSON>` for a number, a boolean, null, a list or an object."

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    app = FakeApplication.start(provider)
    FakeProvider.put_me(provider, applications: [entry(app, "staging")])
    %{app: app}
  end

  describe "credential" do
    test "prints a credential for the application's address, and the same one while it lasts",
         %{provider: provider, app: app, opts: opts} do
      {code, stdout, stderr} = ehosctl(["credential", "ledger"], opts)

      assert {code, stderr} == {0, ""}
      # The fake issues a credential of random bytes.
      assert stdout =~ ~r/\Acredential-[\w-]+\n\z/
      credential = String.trim_trailing(stdout)

      assert FakeProvider.resource(provider, credential) == app.address
      endpoint = provider.issuer <> "/oauth/token"
      address = app.address

      assert [%{endpoint: ^endpoint, refresh_token: "refresh-" <> _, resource: ^address}] =
               renewals(provider)

      {code, stdout, stderr} = ehosctl(["credential", "ledger", "--json"], opts)

      assert {code, stderr} == {0, ""}

      assert JSON.decode!(stdout) == %{
               "application" => "ledger",
               "environment" => "staging",
               "audience" => "ledger/staging",
               "address" => app.address,
               "credential" => credential
             }
    end

    test "needs --env when roles are bound in several environments, and names them",
         %{provider: provider, app: app, opts: opts} do
      FakeProvider.put_me(provider,
        applications: [entry(app, "staging"), entry(app, "production")]
      )

      assert ehosctl(["credential", "ledger"], opts) ==
               {2, "",
                "ehosctl: You hold roles in ledger in staging, production. Name one with --env.\n"}

      {code, stdout, stderr} = ehosctl(["credential", "ledger", "--env", "production"], opts)

      assert {code, stderr} == {0, ""}
      assert stdout =~ ~r/\Acredential-[\w-]+\n\z/
    end

    test "an application or environment without a role of yours is refused", %{opts: opts} do
      assert ehosctl(["credential", "journal"], opts) ==
               {3, "",
                "ehosctl: None of your roles is bound in journal. Run `ehosctl apps` to see the applications you may use.\n"}

      assert ehosctl(["credential", "ledger", "--env", "production"], opts) ==
               {3, "",
                "ehosctl: None of your roles is bound in ledger in production. You hold roles in ledger in staging.\n"}
    end

    test "EHOS refusing it, where nothing is granted, exits 3 in refusals.md's words",
         %{provider: provider, opts: opts} do
      # The credential for EHOS's API is cached, so only the application's is renewed.
      refuse_renewal(provider)

      assert ehosctl(["credential", "ledger"], opts) ==
               {3, "", "ehosctl: #{Ehosctl.Refusal.sentence("no_capability")}\n"}
    end

    test "a credential with a terminal's control characters is not printed",
         %{provider: provider, opts: opts} do
      FakeProvider.answer_renewal(
        provider,
        {:ok,
         %{
           credential: "x\e]52;c;aGk=\a",
           expires_in: 600,
           refresh_token: "refresh-next",
           claims: %{}
         }}
      )

      assert ehosctl(["credential", "ledger"], opts) ==
               {1, "",
                "ehosctl: EHOS issued a credential with characters that ehosctl does not print.\n"}
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
      {code, stdout, stderr} =
        ehosctl(
          ["call", "ledger", "ledger.record_entry", "amount:=100", "note=rent", "paid:=true"],
          opts
        )

      assert {code, stderr} == {0, ""}

      assert stdout == """
             Done: ledger.record_entry, as 0192d3a4-command.
               event: ledger.entry_recorded at position 7
             """

      assert ehosctl(["call", "ledger", "ledger.record_entry", "amount:=1"], opts) ==
               {0, receipt("ledger.record_entry"), ""}

      assert [
               %{
                 method: "POST",
                 path: "/api/commands/ledger.record_entry",
                 query: "",
                 body: %{"amount" => 100, "note" => "rent", "paid" => true},
                 authorization: "Bearer " <> credential,
                 idempotency_key: first
               },
               %{
                 method: "POST",
                 path: "/api/commands/ledger.record_entry",
                 query: "",
                 body: %{"amount" => 1},
                 authorization: "Bearer " <> _credential,
                 idempotency_key: second
               }
             ] = FakeApplication.requests(app)

      assert FakeProvider.resource(provider, credential) == app.address
      assert first =~ @uuid
      assert second =~ @uuid
      assert first != second
    end

    test "sends the idempotency key given, and says when it was already done",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, 200, %{
        "command_id" => "0192d3a4-command",
        "identity" => %{"entry_id" => "e-1"},
        "duplicate" => true,
        "events" => []
      })

      {code, stdout, stderr} =
        ehosctl(
          ["call", "ledger", "ledger.record_entry", "--idempotency-key", "req-81", "amount:=1"],
          opts
        )

      assert {code, stderr} == {0, ""}

      assert stdout == """
             The application already ran a command with this idempotency key, as 0192d3a4-command. It recorded nothing again.
               identity: {"entry_id":"e-1"}
             """

      assert [
               %{
                 method: "POST",
                 path: "/api/commands/ledger.record_entry",
                 query: "",
                 body: %{"amount" => 1},
                 authorization: "Bearer " <> _credential,
                 idempotency_key: "req-81"
               }
             ] = FakeApplication.requests(app)
    end

    test "--json prints the application's receipt", %{opts: opts} do
      {code, stdout, stderr} = ehosctl(["call", "ledger", "ledger.record_entry", "--json"], opts)

      assert {code, stderr} == {0, ""}

      assert JSON.decode!(stdout) == %{
               "command_id" => "0192d3a4-command",
               "identity" => nil,
               "positions" => [7],
               "position" => 7,
               "duplicate" => false,
               "events" => [%{"type" => "ledger.entry_recorded", "position" => 7}]
             }
    end

    test "sends a recording to records, with its body", %{app: app, opts: opts} do
      assert ehosctl(["call", "ledger", "ledger.entry_noted", "entry_id=e-1"], opts) ==
               {0,
                """
                Done: ledger.entry_noted, as 0192d3a4-command.
                  identity: {"entry_id":"e-1"}
                  event: ledger.entry_recorded at position 7
                """, ""}

      assert [
               %{
                 method: "POST",
                 path: "/api/records/ledger.entry_noted",
                 query: "",
                 body: %{"entry_id" => "e-1"},
                 authorization: "Bearer " <> _credential,
                 idempotency_key: key
               }
             ] = FakeApplication.requests(app)

      assert key =~ @uuid
    end

    test "asks a query with its fields in the URL, a field given twice as a list",
         %{app: app, opts: opts} do
      {code, stdout, stderr} =
        ehosctl(
          ["call", "ledger", "ledger.balance", "account=a 1", "since:=7", "tag=x", "tag=y"],
          opts
        )

      assert {code, stderr} == {0, ""}

      # The fake answers with one row of what it was asked.
      assert stdout == """
             [
               {
                 "account": "a 1",
                 "since": "7",
                 "tag": "y"
               }
             ]
             """

      assert [
               %{
                 method: "GET",
                 path: "/api/queries/ledger.balance",
                 query: query,
                 body: nil,
                 authorization: "Bearer " <> _credential,
                 idempotency_key: nil
               }
             ] = FakeApplication.requests(app)

      assert URI.query_decoder(query) |> Enum.to_list() ==
               [{"account", "a 1"}, {"since", "7"}, {"tag", "x"}, {"tag", "y"}]
    end

    test "a query's JSON list is repeated, and an object refused", %{app: app, opts: opts} do
      assert ehosctl(["call", "ledger", "ledger.balance", ~s(tag:=["x",2])], opts) ==
               {0, ~s([\n  { "tag": "2" }\n]\n), ""}

      assert ehosctl(["call", "ledger", "ledger.balance", ~s(filter:={"a":1})], opts) ==
               {2, "",
                "ehosctl: filter is an object or a list of lists. A query takes only text, numbers, " <>
                  "booleans and lists of them.\n"}

      assert [
               %{
                 method: "GET",
                 path: "/api/queries/ledger.balance",
                 query: "tag=x&tag=2",
                 body: nil,
                 authorization: "Bearer " <> _credential,
                 idempotency_key: nil
               }
             ] = FakeApplication.requests(app)
    end

    test "a query's field goes over --data, and a list of lists is refused",
         %{app: app, opts: opts} do
      data = ~s({"account": "a-1", "x": 1})

      assert ehosctl(["call", "ledger", "ledger.balance", "--data", data, "account=a-2"], opts) ==
               {0,
                """
                [
                  {
                    "account": "a-2",
                    "x": "1"
                  }
                ]
                """, ""}

      assert [
               %{
                 method: "GET",
                 path: "/api/queries/ledger.balance",
                 query: query,
                 body: nil,
                 authorization: "Bearer " <> _credential,
                 idempotency_key: nil
               }
             ] = FakeApplication.requests(app)

      assert URI.decode_query(query) == %{"account" => "a-2", "x" => "1"}

      for nested <- ["[[1,2]]", "[[1]]"] do
        assert ehosctl(["call", "ledger", "ledger.balance", "tags:=" <> nested], opts) ==
                 {2, "",
                  "ehosctl: tags is an object or a list of lists. A query takes only text, numbers, " <>
                    "booleans and lists of them.\n"}
      end
    end

    test "--data gives fields from JSON, inline, in a file or on stdin, and fields go over it",
         %{app: app, opts: opts, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "entry.json")
      File.write!(file, ~s({"amount": 5, "note": "from the file"}))

      assert ehosctl(
               ["call", "ledger", "ledger.record_entry", "--data", ~s({"amount": 1}), "note=x"],
               opts
             ) == {0, receipt("ledger.record_entry"), ""}

      assert ehosctl(
               ["call", "ledger", "ledger.record_entry", "--data", "@" <> file, "amount:=6"],
               opts
             ) == {0, receipt("ledger.record_entry"), ""}

      mock_read_input(~s({"amount": 9}))

      assert ehosctl(["call", "ledger", "ledger.record_entry", "--data", "-"], opts) ==
               {0, receipt("ledger.record_entry"), ""}

      assert [
               %{
                 method: "POST",
                 path: "/api/commands/ledger.record_entry",
                 query: "",
                 body: %{"amount" => 1, "note" => "x"},
                 authorization: "Bearer " <> credential,
                 idempotency_key: inline_key
               },
               %{
                 method: "POST",
                 path: "/api/commands/ledger.record_entry",
                 query: "",
                 body: %{"amount" => 6, "note" => "from the file"},
                 authorization: "Bearer " <> credential,
                 idempotency_key: file_key
               },
               %{
                 method: "POST",
                 path: "/api/commands/ledger.record_entry",
                 query: "",
                 body: %{"amount" => 9},
                 authorization: "Bearer " <> credential,
                 idempotency_key: stdin_key
               }
             ] = FakeApplication.requests(app)

      for key <- [inline_key, file_key, stdin_key], do: assert(key =~ @uuid)
    end

    test "help says how fields are written, and that it is governed", %{opts: opts} do
      {code, stdout, stderr} = ehosctl(["call", "--help"], opts)

      assert {code, stderr} == {0, ""}

      assert stdout == """
             ehosctl #{Ehosctl.version()}
             Call an application: run a command, make a recording, or ask a query. A field is `name=text` or `name:=<JSON>`, such as `amount:=100`.

             USAGE:
                 ehosctl call [--json] [--env ENVIRONMENT] [--data JSON] [--idempotency-key KEY] [--installation NAME] APPLICATION CAPABILITY [FIELD] ...

             ARGS:

                 APPLICATION        The application, as `ehosctl apps` shows it.
                 CAPABILITY         The capability to call, as `ehosctl apps` shows it, such
                                    as ledger.record_entry.
                 FIELD              The fields of the call: `name=text`, or `name:=<JSON>`
                                    for a number, a boolean, null, a list or an object. In a
                                    query, a field that you give more than once is a list.

             FLAGS:

                 --json        Print one JSON document instead of words.

             OPTIONS:

                 --env                    The environment. If you hold a role in only one
                                          environment, you can leave it out.
                 --data                   A JSON object of fields: inline, @file.json, or -
                                          for stdin. A FIELD replaces the field of the same
                                          name in this object.
                 --idempotency-key        The idempotency key of the command. If you send the
                                          command again with the same key, the application
                                          runs it only once.
                 --installation           The installation to talk to, instead of
                                          EHOSCTL_INSTALLATION or the current one.

             Plane: governed. This command acts as you, through EHOS. EHOS decides and records each request.

             """
    end

    test "a command line it cannot read sends nothing, and exits 2", %{app: app, opts: opts} do
      for {argv, message} <- [
            {["amount"], "amount is not a field. #{@field}"},
            {["=1"], "=1 is not a field. #{@field}"},
            {["amount:=1x"], "amount:= needs JSON, and 1x is not JSON. Write text as amount=…"},
            {["note=a", "note=b"], "You gave note twice. To give a list, write note:=[…]."},
            {["--data", "[1]"], "--data does not contain a JSON object."},
            {["--data", "@/nonexistent/file.json"],
             "/nonexistent/file.json: ehosctl cannot read it (no such file or directory)."}
          ] do
        assert ehosctl(["call", "ledger", "ledger.record_entry" | argv], opts) ==
                 {2, "", "ehosctl: #{message}\n"}
      end

      assert FakeApplication.requests(app) == []
    end

    test "a capability no role of yours grants is sent as a command, for the application to refuse and record",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, 403, %{"refused" => "missing_capability"})

      assert ehosctl(["call", "ledger", "ledger.close_year", "year:=2026"], opts) ==
               {3, "",
                "ehosctl: You may not do this: it needs `ledger.close_year`, which none of your " <>
                  "roles grants here. Ask for a role binding that does.\n"}

      assert [
               %{
                 method: "POST",
                 path: "/api/commands/ledger.close_year",
                 query: "",
                 body: %{"year" => 2026},
                 authorization: "Bearer " <> _credential,
                 idempotency_key: key
               }
             ] = FakeApplication.requests(app)

      assert key =~ @uuid
    end

    test "EHOS refusing a credential where nothing is granted is said, and nothing reaches the application",
         %{provider: provider, app: app, opts: opts} do
      refuse_renewal(provider)

      assert ehosctl(["call", "ledger", "ledger.close_year"], opts) ==
               {3, "", "ehosctl: #{Ehosctl.Refusal.sentence("no_capability")}\n"}

      assert FakeApplication.requests(app) == []
    end

    test "a name that would leave its place in the path is refused, and nothing is sent",
         %{app: app, opts: opts} do
      for name <- ["", ".", ".."] do
        assert ehosctl(["call", "ledger", name], opts) ==
                 {2, "",
                  "ehosctl: #{inspect(name)} is not the name of a capability. Run `ehosctl apps` to see the " <>
                    "capabilities that your roles grant.\n"}
      end

      assert FakeApplication.requests(app) == []
    end

    test "one not granted is tried as each kind until the application finds it",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, 404, %{"error" => "not_found"})

      assert ehosctl(["call", "ledger", "ledger.yearly", "year:=2026"], opts) ==
               {3, "",
                "ehosctl: None of your roles grants `ledger.yearly` in ledger in staging, and the " <>
                  "application has no capability with that name. Run `ehosctl apps` to see the " <>
                  "capabilities that your roles grant.\n"}

      assert [
               %{
                 method: "POST",
                 path: "/api/commands/ledger.yearly",
                 query: "",
                 body: %{"year" => 2026},
                 authorization: "Bearer " <> credential,
                 idempotency_key: command_key
               },
               %{
                 method: "POST",
                 path: "/api/records/ledger.yearly",
                 query: "",
                 body: %{"year" => 2026},
                 authorization: "Bearer " <> credential,
                 idempotency_key: record_key
               },
               %{
                 method: "GET",
                 path: "/api/queries/ledger.yearly",
                 query: "",
                 body: nil,
                 authorization: "Bearer " <> credential,
                 idempotency_key: nil
               }
             ] = FakeApplication.requests(app)

      # Each kind is sent with a new key of its own.
      assert command_key =~ @uuid
      assert record_key =~ @uuid
      assert command_key != record_key
    end

    test "the kinds stop at the one the application finds, and a query is asked without the fields",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, "commands", 404, %{"error" => "not_found"})
      FakeApplication.answer(app, "records", 403, %{"refused" => "missing_capability"})

      assert ehosctl(["call", "ledger", "ledger.entry_flagged", "note=x"], opts) ==
               {3, "",
                "ehosctl: You may not do this: it needs `ledger.entry_flagged`, which none of " <>
                  "your roles grants here. Ask for a role binding that does.\n"}

      FakeApplication.answer(app, "records", 404, %{"error" => "not_found"})
      FakeApplication.answer(app, "queries", 403, %{"refused" => "missing_capability"})

      assert ehosctl(["call", "ledger", "ledger.yearly", "year:=2026"], opts) ==
               {3, "",
                "ehosctl: You may not do this: it needs `ledger.yearly`, which none of your " <>
                  "roles grants here. Ask for a role binding that does.\n"}

      assert [
               %{
                 method: "POST",
                 path: "/api/commands/ledger.entry_flagged",
                 query: "",
                 body: %{"note" => "x"},
                 authorization: "Bearer " <> credential,
                 idempotency_key: flagged_command_key
               },
               %{
                 method: "POST",
                 path: "/api/records/ledger.entry_flagged",
                 query: "",
                 body: %{"note" => "x"},
                 authorization: "Bearer " <> credential,
                 idempotency_key: flagged_record_key
               },
               %{
                 method: "POST",
                 path: "/api/commands/ledger.yearly",
                 query: "",
                 body: %{"year" => 2026},
                 authorization: "Bearer " <> credential,
                 idempotency_key: yearly_command_key
               },
               %{
                 method: "POST",
                 path: "/api/records/ledger.yearly",
                 query: "",
                 body: %{"year" => 2026},
                 authorization: "Bearer " <> credential,
                 idempotency_key: yearly_record_key
               },
               %{
                 method: "GET",
                 path: "/api/queries/ledger.yearly",
                 query: "",
                 body: nil,
                 authorization: "Bearer " <> credential,
                 idempotency_key: nil
               }
             ] = FakeApplication.requests(app)

      for key <- [flagged_command_key, flagged_record_key, yearly_command_key, yearly_record_key] do
        assert key =~ @uuid
      end
    end

    test "fields a kind cannot carry are what is said when no kind sent is found",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, 404, %{"error" => "not_found"})

      assert ehosctl(["call", "ledger", "ledger.close_year", "year:=2026", "year:=2027"], opts) ==
               {2, "", "ehosctl: You gave year twice. To give a list, write year:=[…].\n"}

      assert [
               %{
                 method: "GET",
                 path: "/api/queries/ledger.close_year",
                 query: "",
                 body: nil,
                 authorization: "Bearer " <> _credential,
                 idempotency_key: nil
               }
             ] = FakeApplication.requests(app)
    end

    test "a gateway's 5xx on the first kind stops there, and names the key it sent",
         %{app: app, opts: opts} do
      FakeApplication.answer(app, "commands", 502, "<html>")

      assert ehosctl(
               ["call", "ledger", "ledger.close_year", "--idempotency-key", "k-1"],
               opts
             ) ==
               {5, "",
                "ehosctl: #{app.address} is unavailable (HTTP 502). Try again later. The " <>
                  "application possibly ran the command. Send the same call again with " <>
                  "--idempotency-key k-1, and the application runs it only once.\n"}

      assert [
               %{
                 method: "POST",
                 path: "/api/commands/ledger.close_year",
                 query: "",
                 body: %{},
                 authorization: "Bearer " <> _credential,
                 idempotency_key: "k-1"
               }
             ] = FakeApplication.requests(app)
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
         "#{app.address} is unavailable (HTTP 502). Try again later. The application possibly ran " <>
           "the command. Send the same call again with --idempotency-key req-1, and the " <>
           "application runs it only once."}
      ]

      for {status, body, code, sentence} <- cases do
        FakeApplication.answer(app, status, body)

        assert ehosctl(
                 ["call", "ledger", "ledger.record_entry", "--idempotency-key", "req-1"],
                 opts
               ) == {code, "", "ehosctl: #{sentence}\n"},
               "#{status} #{inspect(body)}"
      end
    end

    test "a refusal under --json is the kind and the sentence", %{app: app, opts: opts} do
      FakeApplication.answer(app, 403, %{"refused" => "missing_capability"})

      {code, stdout, stderr} =
        ehosctl(["call", "ledger", "ledger.record_entry", "--json"], opts)

      assert {code, stdout} == {3, ""}

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "refused",
                 "message" =>
                   "You may not do this: it needs `ledger.record_entry`, which none of your " <>
                     "roles grants here. Ask for a role binding that does."
               }
             }
    end

    test "a command that reached the application and got no answer it can read names its key",
         %{app: app, opts: opts} do
      FakeApplication.no_answer(app)

      assert ehosctl(
               ["call", "ledger", "ledger.record_entry", "--idempotency-key", "req-9"],
               opts
             ) ==
               {5, "",
                "ehosctl: #{app.address} did not answer. The application possibly ran the " <>
                  "command. Send the same call again with --idempotency-key req-9, and the " <>
                  "application runs it only once.\n"}
    end

    test "an answer that says nothing was done names no key", %{app: app, opts: opts} do
      for {status, body, stderr} <- [
            {429, %{"error" => "too_many_calls"},
             "ehosctl: #{app.address} answered HTTP 429: too_many_calls.\n"},
            {503, %{"error" => "not_supplied", "message" => "nothing written"},
             "ehosctl: The application could not fill in a value it supplies itself, and nothing " <>
               "was written. Try again.\n"},
            {503, %{"error" => "temporarily_unavailable"},
             "ehosctl: #{app.address} answered HTTP 503: temporarily_unavailable.\n"}
          ] do
        FakeApplication.answer(app, status, body)

        assert ehosctl(["call", "ledger", "ledger.record_entry"], opts) == {5, "", stderr},
               "#{status} #{inspect(body)}"
      end
    end

    test "a capability of a kind it does not know needs a later ehosctl",
         %{provider: provider, app: app, opts: opts} do
      watch = %{"name" => "ledger.watch", "label" => "Watch", "kind" => "subscription"}

      FakeProvider.put_me(provider,
        applications: [%{entry(app, "staging") | "capabilities" => [watch]}]
      )

      assert ehosctl(["call", "ledger", "ledger.watch"], opts) ==
               {1, "",
                "ehosctl: `ledger.watch` is a subscription, which this version of ehosctl cannot call. " <>
                  "Install a later version of ehosctl.\n"}
    end

    test "an application it could not connect to did nothing, and no key is named",
         %{app: app, opts: opts} do
      FakeApplication.down(app)

      assert ehosctl(["call", "ledger", "ledger.record_entry"], opts) ==
               {5, "", "ehosctl: #{app.address} did not answer.\n"}
    end

    test "an idempotency key that could not be one is refused before anything is sent",
         %{app: app, opts: opts} do
      for key <- ["", "a b", "a\r\nx-evil: 1", String.duplicate("k", 256)] do
        assert ehosctl(
                 ["call", "ledger", "ledger.record_entry", "--idempotency-key", key],
                 opts
               ) ==
                 {2, "", "ehosctl: An idempotency key is printable ASCII of at most 255 bytes.\n"}
      end

      assert FakeApplication.requests(app) == []
    end

    test "a mistyped option is not sent as a field", %{app: app, opts: opts} do
      assert ehosctl(["call", "ledger", "ledger.record_entry", "--evn=production"], opts) ==
               {2, "",
                "ehosctl: --evn=production is not an option of `ehosctl call`. Run `ehosctl help call` to see the options.\n"}

      assert FakeApplication.requests(app) == []
    end
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

  # What `call` prints of the fake application's receipt for a command or a recording.
  defp receipt(capability) do
    """
    Done: #{capability}, as 0192d3a4-command.
      event: ledger.entry_recorded at position 7
    """
  end

  defp renewals(provider), do: FakeProvider.calls(provider, :renew)

  # EHOS issues no credential where none of the person's roles grants anything.
  defp refuse_renewal(provider) do
    FakeProvider.answer_renewal(
      provider,
      {:error, :refused, Ehosctl.Refusal.sentence("no_capability")}
    )
  end

  defp mock_read_input(input),
    do: expect(Ehosctl.TerminalMock, :read_input, fn :eof -> input end)
end

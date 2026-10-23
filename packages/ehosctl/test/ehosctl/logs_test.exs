defmodule Ehosctl.LogsTest do
  use Ehosctl.SignInCase

  @logs "/api/v1/applications/ledger/environments/staging/logs"
  @tail @logs <> "/tail"

  @newest %{
    "time" => "2026-10-13T10:00:02.000000002Z",
    "message" => "** (RuntimeError) DATABASE_URL is missing",
    "fields" => %{"k8s.pod.name" => "ledger-7d9f-x2", "severity_text" => "error"}
  }
  @oldest %{
    "time" => "2026-10-13T10:00:01.000000001Z",
    "message" => "Starting the ledger",
    "fields" => %{"k8s.pod.name" => "ledger-7d9f-x2", "ehos.image" => "a1b2"}
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    %{opts: Keyword.merge(opts, logs_retry_ms: 0)}
  end

  # EHOS's reading, newest first, as `GET …/logs` answers it.
  defp page(provider, path, body, headers \\ []),
    do: FakeProvider.stub_api(provider, "GET", path, fn _ -> {200, headers, body} end)

  defp ledger(lines),
    do: %{"application" => "ledger", "environment" => "staging", "lines" => lines}

  defp line_event(line), do: "id: #{line["time"]}\nevent: line\ndata: #{JSON.encode!(line)}\n\n"
  defp end_event(reason), do: "event: end\ndata: #{reason}\n\n"

  # The tail, one list of chunks for each time it is opened, the last one repeated; each opening
  # is kept with its credential and its Last-Event-ID, for `openings/1`, and the process answering
  # it.
  #
  # ehosctl closes the connection once it has read what it needs, often before the answer has
  # ended, and Cowboy then shuts the answering process down: Bypass would raise that `shutdown`
  # when the test exits. So the answering process traps it, and a process of its own sends the
  # chunks, since Cowboy waits for each one to be written, forever once the connection has gone:
  # the answer ends when they are all sent or the connection has gone, whichever comes first, and a
  # sender that crashed crashes the answer, so the test fails rather than reading a dropped tail.
  # The test waits for every answer to end before Bypass's own `on_exit`, which runs after this
  # one: Bypass 2.1.0 crashes when it is left waiting for an answer, and stops after a few crashes.
  defp tail(provider, path, answers) do
    {:ok, agent} = Agent.start(fn -> {answers, []} end)

    on_exit(fn ->
      try do
        for %{answerer: pid} <- openings(agent) do
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        end
      after
        Agent.stop(agent)
      end
    end)

    Bypass.stub(provider.bypass, "GET", path, fn conn ->
      Process.flag(:trap_exit, true)
      ["Bearer " <> credential] = Plug.Conn.get_req_header(conn, "authorization")
      last = conn |> Plug.Conn.get_req_header("last-event-id") |> List.first()
      query = URI.decode_query(conn.query_string)
      answerer = self()

      chunks =
        Agent.get_and_update(agent, fn {answers, openings} ->
          accept = conn |> Plug.Conn.get_req_header("accept") |> List.first()

          opening = %{
            credential: credential,
            last: last,
            query: query,
            accept: accept,
            answerer: answerer
          }

          case answers do
            [last_answer] -> {last_answer, {[last_answer], [opening | openings]}}
            [next | rest] -> {next, {rest, [opening | openings]}}
          end
        end)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      sender =
        spawn_link(fn ->
          Enum.each(chunks, fn
            {:sleep, ms} -> Process.sleep(ms)
            chunk -> Plug.Conn.chunk(conn, chunk)
          end)
        end)

      receive do
        {:EXIT, ^sender, :normal} ->
          conn

        {:EXIT, ^sender, reason} ->
          exit(reason)

        {:EXIT, _connection, :shutdown} ->
          Process.exit(sender, :kill)
          conn
      end
    end)

    agent
  end

  # A Last-Event-ID from a little before the reading, as the store writes a time, sent when the
  # reading printed no line.
  defp before_reading?(id) do
    {:ok, at, 0} = DateTime.from_iso8601(id)
    ago = DateTime.diff(DateTime.utc_now(), at, :millisecond)
    id =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,9})?Z\z/ and ago in 5_000..15_000
  end

  defp openings(agent),
    do: agent |> Agent.get(fn {_answers, openings} -> openings end) |> Enum.reverse()

  describe "reading" do
    test "prints the lines oldest first, each with its time, pod, level and message, and sends " <>
           "the filters",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([@newest, @oldest]))

      {0, stdout, ""} =
        ehosctl(
          ~w(logs ledger --env staging --deployment d-1 --since 2h --grep DATABASE --limit 50),
          opts
        )

      assert stdout == """
             2026-10-13T10:00:01.000000001Z ledger-7d9f-x2 Starting the ledger
             2026-10-13T10:00:02.000000002Z ledger-7d9f-x2 ERROR ** (RuntimeError) DATABASE_URL is missing
             """

      assert [request] = FakeProvider.requests(provider, "GET " <> @logs)

      assert request.query == %{
               "deployment" => "d-1",
               "since" => "2h",
               "grep" => "DATABASE",
               "limit" => "50"
             }
    end

    test "says when older lines remain, and when there are none at all",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([@newest]), [
        {"link", ~s(<https://ehos.example.com#{@logs}?after=x>; rel="next")}
      ])

      {0, stdout, ""} = ehosctl(~w(logs ledger --env staging), opts)
      assert stdout =~ "Older lines remain: a larger --limit reads further."

      page(provider, @logs, ledger([]))
      {0, stdout, ""} = ehosctl(~w(logs ledger --env staging), opts)

      assert stdout ==
               "No lines from ledger in staging in the time read. --since reads further back.\n"
    end

    test "--json prints one document, the lines oldest first and nothing else EHOS added",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([Map.put(@newest, "extra", 1), @oldest]))

      {0, stdout, ""} = ehosctl(~w(logs ledger --env staging --json), opts)

      assert JSON.decode!(stdout) == %{
               "application" => "ledger",
               "environment" => "staging",
               "lines" => [@oldest, @newest],
               "more" => false
             }
    end

    test "a line that would act on the terminal is printed escaped",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([%{@newest | "message" => "boom\e[2J"}]))

      {0, stdout, ""} = ehosctl(~w(logs ledger --env staging), opts)
      assert stdout =~ ~S(boom\u{1B}[2J")
      refute stdout =~ "\e"
    end

    test "a message of several lines has its later ones indented, so none passes for a line",
         %{provider: provider, opts: opts} do
      forged = "ok\n2026-10-13T10:00:09Z billing-1 ERROR payment refused"
      page(provider, @logs, ledger([%{@newest | "message" => forged}]))

      {0, stdout, ""} = ehosctl(~w(logs ledger --env staging), opts)

      assert stdout ==
               "2026-10-13T10:00:02.000000002Z ledger-7d9f-x2 ERROR ok\n" <>
                 "    2026-10-13T10:00:09Z billing-1 ERROR payment refused\n"
    end

    test "--platform reads EHOS's own logs", %{provider: provider, opts: opts} do
      page(provider, "/api/v1/platform/logs", %{"application" => "ehos", "lines" => [@oldest]})

      {0, stdout, ""} = ehosctl(~w(logs --platform), opts)
      assert stdout =~ "Starting the ledger"
    end

    test "an answer for another application is one ehosctl cannot read",
         %{provider: provider, opts: opts} do
      page(provider, @logs, %{ledger([@newest]) | "application" => "billing"})

      {1, "", stderr} = ehosctl(~w(logs ledger --env staging), opts)
      assert stderr =~ "answered with something ehosctl cannot read"
    end
  end

  describe "the command line" do
    test "an application needs --env, --platform takes no application, and one of the two is named",
         %{opts: opts} do
      {2, "", stderr} = ehosctl(~w(logs ledger), opts)
      assert stderr =~ "Name the environment whose logs to read with --env."

      {2, "", stderr} = ehosctl(~w(logs ledger --platform), opts)
      assert stderr =~ "--platform reads EHOS's own logs"

      {2, "", stderr} = ehosctl(~w(logs --platform --deployment d-1), opts)
      assert stderr =~ "--platform reads EHOS's own logs"

      {2, "", stderr} = ehosctl(~w(logs), opts)
      assert stderr =~ "or --platform for EHOS's own"

      {2, "", stderr} = ehosctl(~w(logs .. --env staging), opts)
      assert stderr =~ "names no application or environment"
    end
  end

  describe "refusals" do
    test "each is printed in EHOS's words with its kind's exit code",
         %{provider: provider, opts: opts} do
      for {status, code, exit} <- [
            {403, "forbidden", 3},
            {404, "not_found", 1},
            {422, "invalid", 2},
            {503, "logs_unavailable", 5}
          ] do
        FakeProvider.stub_api(provider, "GET", @logs, fn _ ->
          {status, %{"error" => code, "message" => "EHOS says #{code}."}}
        end)

        assert {^exit, "", stderr} = ehosctl(~w(logs ledger --env staging), opts)
        assert stderr == "ehosctl: EHOS says #{code}.\n"
      end
    end

    test "an EHOS without the route is said to need a later EHOS",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", @logs, fn _ -> {404, %{"errors" => %{}}} end)

      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ ->
        {200,
         %{
           "component" => "ehos",
           "version" => "0.9.0",
           "commit" => nil,
           "produces" => ["ehos.api/v1"],
           "accepts" => [],
           "requires" => %{},
           "routes" => [%{"method" => "GET", "path" => "/api/v1/me/roles"}]
         }}
      end)

      {1, "", stderr} = ehosctl(~w(logs ledger --env staging), opts)
      assert stderr =~ "runs EHOS 0.9.0, which has no"
      assert stderr =~ "this command needs a later EHOS"
    end
  end

  describe "--follow" do
    test "prints the reading, then follows from its newest line, and ends after the hour with 0",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([@newest, @oldest]))
      next = %{@newest | "time" => "2026-10-13T10:00:03.000000003Z", "message" => "Up"}
      tail = tail(provider, @tail, [[line_event(next), end_event("expired")]])

      {0, stdout, stderr} = ehosctl(~w(logs ledger --env staging --grep x --follow), opts)

      assert stdout =~ ~r/Starting the ledger\n.*DATABASE_URL is missing\n.* ERROR Up\n\z/
      assert stderr =~ "The tail ended after an hour"
      assert [%{last: "2026-10-13T10:00:02.000000002Z", query: %{"grep" => "x"}}] = openings(tail)
    end

    test "after credential_expired, opens the tail again with a new credential from the last " <>
           "line, losing and repeating none",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      first = %{@oldest | "time" => "2026-10-13T10:00:05.000000005Z", "message" => "one"}
      second = %{@oldest | "time" => "2026-10-13T10:00:06.000000006Z", "message" => "two"}

      tail =
        tail(provider, @tail, [
          [line_event(first), end_event("credential_expired")],
          [line_event(second), end_event("expired")]
        ])

      {0, stdout, _stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)

      assert [_one, _two] = String.split(stdout, "\n", trim: true)
      assert stdout =~ ~r/ one\n.* two\n\z/

      assert [opened, reopened] = openings(tail)
      assert before_reading?(opened.last)
      assert reopened.last == first["time"]
      assert reopened.credential != opened.credential
      assert FakeProvider.resource(provider, reopened.credential) == provider.issuer
    end

    test "--json prints each line as one JSON object of its own", %{
      provider: provider,
      opts: opts
    } do
      page(provider, @logs, ledger([@oldest]))
      tail(provider, @tail, [[line_event(@newest), end_event("expired")]])

      {0, stdout, stderr} = ehosctl(~w(logs ledger --env staging --follow --json), opts)

      assert stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1) ==
               [@oldest, @newest]

      assert %{"end" => %{"reason" => "expired"}} = JSON.decode!(stderr)
    end

    test "every other end is said with its kind's exit code", %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))

      for {reason, exit, said} <- [
            {"refused", 3, "you may no longer read these logs"},
            {"unavailable", 5, "could not read the logs from its store"},
            {"too_slow", 1, "did not take the lines as fast as they came"},
            {"bored", 1, "a reason this ehosctl does not know: bored"}
          ] do
        tail(provider, @tail, [[end_event(reason)]])
        assert {^exit, "", stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)
        assert stderr =~ said
      end
    end

    test "a tail that drops is opened again from the last line, and given up after three drops " <>
           "in a row",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      tail = tail(provider, @tail, [[line_event(@oldest)], [": keep-alive\n\n"], []])

      {5, stdout, stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)

      assert stdout =~ "Starting the ledger"
      assert stderr =~ "stopped answering the tail, 4 times in a row"
      assert [%{last: first} | reopened] = openings(tail)
      assert before_reading?(first)
      assert length(reopened) == 3
      assert Enum.all?(reopened, &(&1.last == @oldest["time"]))
    end

    test "asks for JSON too, and is told when EHOS has the reading but not the tail",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      tail = tail(provider, @tail, [[end_event("expired")]])
      {0, "", _stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)
      assert [%{accept: "text/event-stream, application/json"}] = openings(tail)

      # Phoenix answers a route it lacks in JSON only when JSON is accepted.
      Bypass.stub(provider.bypass, "GET", @tail, fn conn ->
        if conn |> Plug.Conn.get_req_header("accept") |> List.first() =~ "application/json",
          do: Plug.Conn.resp(conn, 404, ~s({"errors":{"detail":"Not Found"}})),
          else: Plug.Conn.resp(conn, 404, "Not Found")
      end)

      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ ->
        {200,
         %{
           "component" => "ehos",
           "version" => "0.9.0",
           "commit" => nil,
           "produces" => ["ehos.api/v1"],
           "accepts" => [],
           "requires" => %{},
           "routes" => [%{"method" => "GET", "path" => @logs}]
         }}
      end)

      {1, "", stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)
      assert stderr =~ "runs EHOS 0.9.0, which has no"
      assert stderr =~ "this command needs a later EHOS"
    end

    test "a credential that ends each tail within a minute, lines or none, is renewed three " <>
           "times in a row, not more",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      tail = tail(provider, @tail, [[line_event(@oldest), end_event("credential_expired")]])

      {1, _stdout, stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)
      assert stderr =~ "ended the tail at once 4 times in a row"
      assert length(openings(tail)) == 4
    end

    test "ends after an hour from its start, however often its tail was opened again",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      tail = tail(provider, @tail, [[line_event(@oldest), end_event("credential_expired")]])

      opts = Keyword.merge(opts, logs_hour_ms: 300, logs_steady_ms: 0)
      {0, _stdout, stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)

      assert stderr =~ "The tail ended after an hour"
      assert length(openings(tail)) > 1
    end

    test "ends at the hour within a tail too, at the next part that comes",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))

      tail(provider, @tail, [
        [line_event(@oldest), {:sleep, 400}, ": keep-alive\n\n", end_event("refused")]
      ])

      opts = Keyword.put(opts, :logs_hour_ms, 200)
      {0, _stdout, stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)
      assert stderr =~ "The tail ended after an hour"
    end

    test "after a reading with no line, starts five seconds before it by EHOS's clock",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", @logs, fn _ ->
        {200, [{"date", "Tue, 13 Oct 2026 10:00:00 GMT"}], ledger([])}
      end)

      tail = tail(provider, @tail, [[end_event("expired")]])
      {0, "", _stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)
      assert [%{last: "2026-10-13T09:59:55Z"}] = openings(tail)
    end

    test "a line with an empty id leaves the place where the tail is opened again as it was",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([@oldest]))
      no_id = "id:\nevent: line\ndata: #{JSON.encode!(@newest)}\n\n"

      tail =
        tail(provider, @tail, [
          [no_id, end_event("credential_expired")],
          [end_event("expired")]
        ])

      {0, _stdout, _stderr} = ehosctl(~w(logs ledger --env staging --follow), opts)
      assert [_opened, %{last: last}] = openings(tail)
      assert last == @oldest["time"]
    end

    test "a fourth tail at once is refused in EHOS's words", %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))

      FakeProvider.stub_api(provider, "GET", @tail, fn _ ->
        {429, %{"error" => "too_many_tails", "message" => "You already follow three logs."}}
      end)

      {5, "", "ehosctl: You already follow three logs.\n"} =
        ehosctl(~w(logs ledger --env staging --follow), opts)
    end
  end
end

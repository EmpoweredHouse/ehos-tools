defmodule Ehosctl.LogsTest do
  use Ehosctl.SignInCase

  @logs "/api/v1/applications/ledger/environments/staging/logs"
  @tail @logs <> "/tail"

  # The time EHOS answers a reading at, as its `Date` header says, and five seconds before it, where
  # a tail after a reading with no line starts.
  @read_at "Tue, 13 Oct 2026 10:00:10 GMT"
  @before_reading "2026-10-13T10:00:05Z"

  @accept "text/event-stream, application/json"

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

  @newest_printed "2026-10-13T10:00:02.000000002Z ledger-7d9f-x2 ERROR ** (RuntimeError) DATABASE_URL is missing\n"
  @oldest_printed "2026-10-13T10:00:01.000000001Z ledger-7d9f-x2 Starting the ledger\n"

  @platform_alone "--platform reads the logs of EHOS, so it takes no application, --env or " <>
                    "--deployment. Leave them out, or leave out --platform."
  @hour_ended "! The tail ended after 1 hour, the longest that a tail lasts.\n  Run the command again to continue.\n"

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    # A reconnection waits for nothing, and a silence in the tail takes no time.
    stub_virtual_clock()
    %{opts: opts}
  end

  describe "logs" do
    test "prints the lines oldest first, each with its time, pod, level and message, and sends " <>
           "the filters",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([@newest, @oldest]))

      assert ehosctl(
               ~w(logs ledger --env staging --deployment d-1 --since 2h --grep DATABASE --limit 50),
               opts
             ) == {0, @oldest_printed <> @newest_printed, ""}

      assert FakeProvider.requests(provider, "GET " <> @logs) == [
               %{
                 path: @logs,
                 query: %{
                   "deployment" => "d-1",
                   "since" => "2h",
                   "grep" => "DATABASE",
                   "limit" => "50"
                 },
                 body: "",
                 content_type: nil
               }
             ]
    end

    test "says when older lines remain, and when there are none at all",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([@newest]), [
        {"link", ~s(<https://ehos.example.com#{@logs}?after=x>; rel="next")}
      ])

      assert ehosctl(~w(logs ledger --env staging), opts) ==
               {0, @newest_printed <> "Older lines remain. Give a larger --limit to read them.\n",
                ""}

      page(provider, @logs, ledger([]))

      assert ehosctl(~w(logs ledger --env staging), opts) ==
               {0,
                "No lines from ledger in staging in the time that EHOS read. Give --since to read " <>
                  "further back.\n", ""}
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

      assert ehosctl(~w(logs ledger --env staging), opts) ==
               {0,
                ~S("2026-10-13T10:00:02.000000002Z ledger-7d9f-x2 ERROR boom\u{1B}[2J") <> "\n",
                ""}
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

      assert ehosctl(~w(logs --platform), opts) == {0, @oldest_printed, ""}
    end

    test "an answer for another application is one ehosctl cannot read",
         %{provider: provider, opts: opts} do
      page(provider, @logs, %{ledger([@newest]) | "application" => "billing"})

      assert ehosctl(~w(logs ledger --env staging), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end

    test "an application needs --env, --platform takes no application, and one of the two is named",
         %{opts: opts} do
      for {argv, said} <- [
            {~w(logs ledger),
             "The command names no environment. Give the environment of the application with --env."},
            {~w(logs ledger --platform), @platform_alone},
            {~w(logs --platform --deployment d-1), @platform_alone},
            {~w(logs),
             "The command names no application. Give the name of an application, or --platform " <>
               "for the logs of EHOS."},
            {~w(logs .. --env staging),
             ".. is not the name of an application or an environment. Give the name of the " <>
               "application and of one of its environments."}
          ] do
        assert ehosctl(argv, opts) == {2, "", "ehosctl: #{said}\n"}
      end
    end

    test "each refusal is printed in EHOS's words with its kind's exit code",
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

        assert ehosctl(~w(logs ledger --env staging), opts) ==
                 {exit, "", "ehosctl: EHOS says #{code}.\n"}
      end
    end

    test "an EHOS without the route is said to need a later EHOS",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", @logs, fn _ -> {404, %{"errors" => %{}}} end)
      serve_ehos_0_9_0(provider, "/api/v1/me/roles")

      assert ehosctl(~w(logs ledger --env staging), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} runs EHOS 0.9.0, which has no `GET #{@logs}`: this " <>
                  "command needs a later EHOS. The operator upgrades EHOS to have it.\n"}
    end
  end

  describe "logs --follow" do
    test "prints the reading, then follows from its newest line, and ends after the hour with 0",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([@newest, @oldest]))
      next = %{@newest | "time" => "2026-10-13T10:00:03.000000003Z", "message" => "Up"}
      tail = tail([[line_event(next), end_event("expired")]])

      assert ehosctl(~w(logs ledger --env staging --grep x --follow), opts) ==
               {0,
                @oldest_printed <>
                  @newest_printed <> "2026-10-13T10:00:03.000000003Z ledger-7d9f-x2 ERROR Up\n",
                @hour_ended}

      assert openings(tail) == [
               %{last: "2026-10-13T10:00:02.000000002Z", query: %{"grep" => "x"}, accept: @accept}
             ]
    end

    test "after credential_expired, opens the tail again with a new credential from the last " <>
           "line, losing and repeating none",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      first = %{@oldest | "time" => "2026-10-13T10:00:05.000000005Z", "message" => "one"}
      second = %{@oldest | "time" => "2026-10-13T10:00:06.000000006Z", "message" => "two"}

      tail =
        tail([
          [line_event(first), end_event("credential_expired")],
          [line_event(second), end_event("expired")]
        ])

      assert ehosctl(~w(logs ledger --env staging --follow), opts) ==
               {0,
                """
                2026-10-13T10:00:05.000000005Z ledger-7d9f-x2 one
                2026-10-13T10:00:06.000000006Z ledger-7d9f-x2 two
                """, @hour_ended}

      assert openings(tail) == [
               %{last: @before_reading, query: %{}, accept: @accept},
               %{last: first["time"], query: %{}, accept: @accept}
             ]

      # A credential is the provider's own random token: the second is a new one, for EHOS's API.
      assert [opened, reopened] = credentials(tail)
      assert reopened != opened
      assert FakeProvider.resource(provider, reopened) == provider.issuer
    end

    test "--json prints each line as one JSON object of its own", %{
      provider: provider,
      opts: opts
    } do
      page(provider, @logs, ledger([@oldest]))
      tail([[line_event(@newest), end_event("expired")]])

      {0, stdout, stderr} = ehosctl(~w(logs ledger --env staging --follow --json), opts)

      assert stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1) ==
               [@oldest, @newest]

      assert JSON.decode!(stderr) == %{
               "end" => %{
                 "message" =>
                   "The tail ended after 1 hour, the longest that a tail lasts. Run the " <>
                     "command again to continue.",
                 "reason" => "expired"
               }
             }
    end

    test "every other end is said with its kind's exit code", %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))

      for {reason, exit, said} <- [
            {"refused", 3, "The tail ended, because you can no longer read these logs."},
            {"unavailable", 5,
             "The tail ended, because EHOS could not read the logs from its store. Run the command " <>
               "again."},
            {"too_slow", 1,
             "The tail ended, because this terminal did not take the lines as fast as EHOS " <>
               "sent them. Give --grep or --deployment to get fewer lines."},
            {"bored", 1,
             "The tail ended for a reason that this version of ehosctl does not know: bored."}
          ] do
        tail([[end_event(reason)]])

        assert ehosctl(~w(logs ledger --env staging --follow), opts) ==
                 {exit, "", "ehosctl: #{said}\n"}
      end
    end

    test "a tail that drops is opened again from the last line, and given up after three drops " <>
           "in a row",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      tail = tail([[line_event(@oldest)], [": keep-alive\n\n"], []])

      assert ehosctl(~w(logs ledger --env staging --follow), opts) ==
               {5, @oldest_printed,
                "ehosctl: #{provider.issuer} stopped answering the tail 4 times in a row. Run the " <>
                  "command again later.\n"}

      assert openings(tail) == [
               %{last: @before_reading, query: %{}, accept: @accept},
               %{last: @oldest["time"], query: %{}, accept: @accept},
               %{last: @oldest["time"], query: %{}, accept: @accept},
               %{last: @oldest["time"], query: %{}, accept: @accept}
             ]
    end

    test "asks for JSON too, and is told when EHOS has the reading but not the tail",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      tail = tail([[end_event("expired")]])
      assert ehosctl(~w(logs ledger --env staging --follow), opts) == {0, "", @hour_ended}
      assert openings(tail) == [%{last: @before_reading, query: %{}, accept: @accept}]

      mock_tail_not_found()
      serve_ehos_0_9_0(provider, @logs)

      assert ehosctl(~w(logs ledger --env staging --follow), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} runs EHOS 0.9.0, which has no `GET #{@tail}`: this " <>
                  "command needs a later EHOS. The operator upgrades EHOS to have it.\n"}
    end

    test "a credential that ends each tail within a minute, lines or none, is renewed three " <>
           "times in a row, not more",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      tail = tail([[line_event(@oldest), end_event("credential_expired")]])

      assert ehosctl(~w(logs ledger --env staging --follow), opts) ==
               {1, String.duplicate(@oldest_printed, 4),
                "ehosctl: #{provider.issuer} ended the tail at once 4 times in a row. Each " <>
                  "time, it said that the credential had expired, but each credential was " <>
                  "new.\n"}

      assert openings(tail) == [
               %{last: @before_reading, query: %{}, accept: @accept},
               %{last: @oldest["time"], query: %{}, accept: @accept},
               %{last: @oldest["time"], query: %{}, accept: @accept},
               %{last: @oldest["time"], query: %{}, accept: @accept}
             ]
    end

    test "ends after an hour from its start, however often its tail was opened again",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))
      # Each tail stays open for more than a minute, so none ended at once: 59 print their line
      # within the hour, and the 60th ends at it.
      tail =
        tail([[{:sleep, 61_000}, line_event(@oldest), end_event("credential_expired")]])

      assert ehosctl(~w(logs ledger --env staging --follow), opts) ==
               {0, String.duplicate(@oldest_printed, 59), @hour_ended}

      assert openings(tail) ==
               [
                 %{last: @before_reading, query: %{}, accept: @accept}
                 | List.duplicate(%{last: @oldest["time"], query: %{}, accept: @accept}, 59)
               ]
    end

    test "ends at the hour within a tail too, at the next part that comes",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))

      tail([
        [line_event(@oldest), {:sleep, 3_600_000}, ": keep-alive\n\n", end_event("refused")]
      ])

      assert ehosctl(~w(logs ledger --env staging --follow), opts) ==
               {0, @oldest_printed, @hour_ended}
    end

    test "after a reading with no line, starts five seconds before it by EHOS's clock",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", @logs, fn _ ->
        {200, [{"date", "Tue, 13 Oct 2026 10:00:00 GMT"}], ledger([])}
      end)

      tail = tail([[end_event("expired")]])
      assert ehosctl(~w(logs ledger --env staging --follow), opts) == {0, "", @hour_ended}
      assert openings(tail) == [%{last: "2026-10-13T09:59:55Z", query: %{}, accept: @accept}]
    end

    test "a line with an empty id leaves the place where the tail is opened again as it was",
         %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([@oldest]))
      no_id = "id:\nevent: line\ndata: #{JSON.encode!(@newest)}\n\n"

      tail =
        tail([
          [no_id, end_event("credential_expired")],
          [end_event("expired")]
        ])

      assert ehosctl(~w(logs ledger --env staging --follow), opts) ==
               {0, @oldest_printed <> @newest_printed, @hour_ended}

      assert openings(tail) == [
               %{last: @oldest["time"], query: %{}, accept: @accept},
               %{last: @oldest["time"], query: %{}, accept: @accept}
             ]
    end

    test "a fourth tail at once is refused in EHOS's words", %{provider: provider, opts: opts} do
      page(provider, @logs, ledger([]))

      FakeProvider.stub_api(provider, "GET", @tail, fn _ ->
        {429, %{"error" => "too_many_tails", "message" => "You already follow three logs."}}
      end)

      assert ehosctl(~w(logs ledger --env staging --follow), opts) ==
               {5, "", "ehosctl: You already follow three logs.\n"}
    end
  end

  # EHOS's reading, newest first, as `GET …/logs` answers it, at `@read_at` unless `headers` says.
  defp page(provider, path, body, headers \\ []),
    do:
      FakeProvider.stub_api(provider, "GET", path, fn _ ->
        {200, [{"date", @read_at} | headers], body}
      end)

  defp ledger(lines),
    do: %{"application" => "ledger", "environment" => "staging", "lines" => lines}

  defp line_event(line), do: "id: #{line["time"]}\nevent: line\ndata: #{JSON.encode!(line)}\n\n"
  defp end_event(reason), do: "event: end\ndata: #{reason}\n\n"

  # An EHOS 0.9.0 whose API description lists `route` alone.
  defp serve_ehos_0_9_0(provider, route) do
    FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ ->
      {200,
       %{
         "component" => "ehos",
         "version" => "0.9.0",
         "commit" => nil,
         "produces" => ["ehos.api/v1"],
         "accepts" => [],
         "requires" => %{},
         "routes" => [%{"method" => "GET", "path" => route}]
       }}
    end)
  end

  # A tail EHOS does not have: Phoenix answers a route it lacks in JSON only when JSON is accepted.
  defp mock_tail_not_found do
    expect(Ehosctl.HTTPMock, :stream, fn _url, _credential, headers, _handler, _opts ->
      {"accept", accept} = List.keyfind(headers, "accept", 0)

      body =
        if accept =~ "application/json", do: %{"errors" => %{"detail" => "Not Found"}}

      {:ok, %{status: 404, headers: %{}, body: body}}
    end)
  end

  # The tail, one list of chunks for each time it is opened, the last one repeated, each handed
  # over as a part of its own, with `{:sleep, ms}` between parts where the tail is silent; each
  # opening is kept with its credential, its Last-Event-ID, its query and what it accepts, for
  # `openings/1` and `credentials/1`. An answer that ends is closed, as `Ehosctl.HTTP.stream/5`
  # says.
  defp tail(answers) do
    {:ok, agent} = Agent.start_link(fn -> {answers, []} end)

    stub(Ehosctl.HTTPMock, :stream, fn url, credential, headers, {acc, handle}, _opts ->
      %URI{path: @tail, query: query} = URI.parse(url)
      header = &List.keyfind(headers, &1, 0, {&1, nil})

      opening = %{
        credential: credential,
        last: elem(header.("last-event-id"), 1),
        query: URI.decode_query(query || ""),
        accept: elem(header.("accept"), 1)
      }

      agent
      |> Agent.get_and_update(fn {answers, openings} ->
        next_answer(answers, opening, openings)
      end)
      |> Enum.reduce_while({:closed, acc}, &part(&1, &2, handle))
    end)

    agent
  end

  # The last list of chunks is repeated for every opening after it.
  defp next_answer([last_answer], opening, openings),
    do: {last_answer, {[last_answer], [opening | openings]}}

  defp next_answer([next | rest], opening, openings), do: {next, {rest, [opening | openings]}}

  defp part({:sleep, ms}, closed, _handle) do
    Ehosctl.Clock.current().sleep(ms)
    {:cont, closed}
  end

  defp part(chunk, {:closed, acc}, handle) do
    case handle.(chunk, acc) do
      {:cont, acc} -> {:cont, {:closed, acc}}
      {:halt, result} -> {:halt, {:halted, result}}
    end
  end

  # Where and how each opening asked, oldest first; its credential, a token the provider made up,
  # is `credentials/1`'s.
  defp openings(agent), do: Enum.map(opened(agent), &Map.delete(&1, :credential))

  defp credentials(agent), do: Enum.map(opened(agent), & &1.credential)

  defp opened(agent),
    do: agent |> Agent.get(fn {_answers, openings} -> openings end) |> Enum.reverse()
end

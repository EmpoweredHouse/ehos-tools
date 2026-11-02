defmodule Ehosctl.Logs do
  @moduledoc """
  `ehosctl logs <application> --env E` and `ehosctl logs --platform`: the lines an application
  wrote in an environment, or EHOS's own, as EHOS keeps them and its console's Logs view shows
  them (eh-os D-93, eh-os#478). Reading an application's needs
  `ehos.telemetry.read` in the environment, and EHOS's own needs `ehos.platform_telemetry.read` at
  the whole platform, which reads no application's (eh-os D-102); EHOS records every reading, and
  every refusal, without its lines.

  It reads one page, `GET /api/v1/applications/:name/environments/:environment/logs` or
  `GET /api/v1/platform/logs`, narrowed by `--deployment` (an application's, read as its image),
  `--since` (`15m`, `2h`, `7d` or a time; EHOS reads the last hour unless told) and `--grep`, at
  most `--limit` lines (EHOS takes 1 to 1000, and gives 100 unless told). EHOS answers the newest
  first; they are printed oldest first, the newest next to the prompt, each as its time, its pod,
  its level when it has one, and its message, through `Ehosctl.Output.shown_lines/1`, so a line an
  application wrote cannot act on the terminal. Under `--json`, one document,
  `{"application", "environment", "lines", "more"}`, the lines oldest first as EHOS gives them.

  `--follow` prints that page, then follows the same logs as they come from `…/logs/tail`, as
  server-sent events (eh-os D-97), from the newest line it printed (`Last-Event-ID`), so no line is
  lost or printed twice. Under `--json`, each line is one JSON object on its own line. A tail ends
  with a reason:

  - `credential_expired`, when the credential that opened it expires, about every ten minutes: a
    new one is fetched, never the one EHOS called expired, and the tail is opened again from the
    last line printed. Nothing is said.
  - `expired`, after an hour: said, and the exit code is 0.
  - `refused` (3), `unavailable` (5), `too_slow` (1), or a reason this `ehosctl` does not know (1):
    said, as an error of its kind.

  A tail whose connection drops, or that hears nothing, no line and no keep-alive, for 45 seconds,
  is opened again from the last line printed, at most three times in a row before it is said that
  EHOS stopped answering.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Credentials
  alias Ehosctl.HTTP
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias ServerSentEvents.Parser

  require Ehosctl.Api

  # A tail that drops is opened again this many times in a row before the follow ends.
  @reconnects 3
  # The most bytes of one event held before it is whole: EHOS's lines are smaller by far.
  @max_event_bytes 4_000_000
  # How long a follow lasts, as one tail of EHOS's does.
  @hour_ms :timer.hours(1)

  # How long a tail stays open, lines or none, to have worked: one that ends sooner ended at once.
  @steady_ms 60_000

  @impl Ehosctl.Command
  def name, do: :logs

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Print the logs of an application in an environment, or the logs of EHOS. The " <>
          "newest line is last.",
      args: [
        application: [
          value_name: "APPLICATION",
          required: false,
          help: "The application to read the logs of. Leave it out with --platform."
        ]
      ],
      options: [
        env: [
          long: "--env",
          value_name: "ENVIRONMENT",
          help: "The environment of the application."
        ],
        deployment: [
          long: "--deployment",
          value_name: "ID",
          help: "Show only the lines of the image of this deployment."
        ],
        since: [
          long: "--since",
          value_name: "SINCE",
          help:
            "How far back to read: 15m, 2h, 7d, or a time in ISO 8601. If you do not give it, " <>
              "EHOS reads the last hour."
        ],
        grep: [
          long: "--grep",
          value_name: "TEXT",
          help: "Show only the lines that contain this text."
        ],
        limit: [
          long: "--limit",
          value_name: "N",
          parser: :integer,
          help: "How many of the newest lines to read, from 1 to 1000. The default is 100."
        ]
      ],
      flags: [
        platform: [
          long: "--platform",
          help: "Read the logs of EHOS, not the logs of an application."
        ],
        follow: [
          long: "--follow",
          short: "-f",
          help: "After the lines, print each new line when it arrives, for up to 1 hour."
        ],
        json: [
          long: "--json",
          help:
            "Print one JSON document, not text. With --follow, print one JSON object on each " <>
              "line."
        ]
      ]
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    %{platform: platform?, follow: follow?, json: json?} = parsed.flags
    options = parsed.options

    with {:ok, target} <- target(parsed.args[:application], options, platform?),
         path = path(target),
         installation = Keyword.fetch!(opts, :installation),
         filters = filters(options),
         started = Ehosctl.Clock.current().monotonic(),
         {:ok, page} <- read(installation, target, path, filters, opts) do
      if follow? do
        Enum.each(page.lines, &say(&1, json?))
        tail = path <> "/tail?" <> URI.encode_query(Map.take(filters, ["deployment", "grep"]))

        state = %{
          last: newest(page.lines, page.at),
          expired: nil,
          drops: 0,
          until: started + @hour_ms,
          why: :dropped
        }

        follow(installation, tail, state, json?, opts)
      else
        {:ok, %{text: text(page), json: page.json}}
      end
    end
  end

  # Where the tail starts: after the newest line printed, or, when none was, from a little before
  # the reading, by EHOS's clock, as the reading's `Date` says, so a line written while the tail was
  # being opened is not lost, and this machine's clock, which may be ahead, hides none. EHOS takes
  # a time as the store writes it, and sends only lines after it, so none printed is printed again.
  # Without a `Date`, the tail starts when it opens.
  defp newest([], nil), do: nil
  defp newest([], at), do: at |> DateTime.add(-5, :second) |> DateTime.to_iso8601()

  defp newest(lines, at) do
    case List.last(lines)["time"] do
      time when is_binary(time) and time != "" -> time
      _none -> newest([], at)
    end
  end

  defp target(nil, %{env: nil, deployment: nil}, true), do: {:ok, :platform}

  defp target(_application, _options, true),
    do:
      {:error, :invalid,
       "--platform reads the logs of EHOS, so it takes no application, --env or " <>
         "--deployment. Leave them out, or leave out --platform."}

  defp target(nil, _options, false),
    do:
      {:error, :invalid,
       "The command names no application. Give the name of an application, or --platform for " <>
         "the logs of EHOS."}

  defp target(_application, %{env: nil}, false),
    do:
      {:error, :invalid,
       "The command names no environment. Give the environment of the application with --env."}

  defp target(application, %{env: env}, false) do
    case Enum.find([application, env], &Api.is_nameless(&1)) do
      nil ->
        {:ok, {application, env}}

      word ->
        {:error, :invalid,
         "#{Refusal.shown(word)} is not the name of an application or an environment. Give " <>
           "the name of the application and of one of its environments."}
    end
  end

  defp path(:platform), do: "/api/v1/platform/logs"

  defp path({application, env}),
    do: "/api/v1/applications/#{Api.segment(application)}/environments/#{Api.segment(env)}/logs"

  defp filters(options) do
    options
    |> Map.take([:deployment, :since, :grep, :limit])
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new(fn {name, value} -> {Atom.to_string(name), to_string(value)} end)
  end

  # One page, oldest first, and whether older lines remain: EHOS names a next page whenever one is
  # full.
  defp read(installation, target, path, filters, opts) do
    case Api.answer(installation, :get, path <> "?" <> URI.encode_query(filters), nil, opts) do
      {:ok, %{status: 200, body: body} = answer} ->
        if page?(body, target) do
          lines = body["lines"] |> Enum.map(&kept/1) |> Enum.reverse()
          more? = next?(answer.headers["link"])

          json = %{
            "application" => body["application"],
            "environment" => body["environment"],
            "lines" => lines,
            "more" => more?
          }

          at = server_time(answer.headers["date"])
          {:ok, %{target: target, lines: lines, more?: more?, json: json, at: at}}
        else
          Api.unexpected(installation)
        end

      {:ok, answer} ->
        Api.refusal(answer, installation)

      {:error, kind, message, :sent} ->
        {:error, kind, message}

      error ->
        error
    end
  end

  # The time an answer's `Date` header says (RFC 9110, 5.6.7), or `nil`.
  defp server_time(date) when is_binary(date) do
    case :httpd_util.convert_request_date(String.to_charlist(date)) do
      {{_year, _month, _day}, {_hour, _minute, _second}} = at ->
        DateTime.from_naive!(NaiveDateTime.from_erl!(at), "Etc/UTC")

      :bad_date ->
        nil
    end
  end

  defp server_time(nil), do: nil

  defp page?(%{"lines" => lines} = body, target) when is_list(lines),
    do: about?(body, target) and Enum.all?(lines, &line?/1)

  defp page?(_body, _target), do: false

  defp about?(body, :platform), do: body["application"] == "ehos"

  defp about?(body, {application, env}),
    do: body["application"] == application and body["environment"] == env

  defp line?(%{"message" => message, "fields" => fields} = line)
       when is_binary(message) and is_map(fields),
       do: is_nil(line["time"]) or is_binary(line["time"])

  defp line?(_line), do: false

  # Kept to the fields a line has, so nothing else an answer holds reaches a script under `--json`.
  defp kept(line), do: Map.take(line, ~w(time message fields))

  defp next?(nil), do: false
  defp next?(link), do: link =~ ~r/;\s*rel\s*=\s*"?[^";,]*\bnext\b/i

  defp text(%{lines: [], target: target}),
    do:
      "No lines from #{whose(target)} in the time that EHOS read. Give --since to read " <>
        "further back."

  defp text(%{lines: lines, more?: more?}) do
    shown = Enum.map_join(lines, "\n", &printed/1)

    if more?,
      do: shown <> "\nOlder lines remain. Give a larger --limit to read them.",
      else: shown
  end

  defp whose(:platform), do: "EHOS"
  defp whose({application, env}), do: "#{application} in #{env}"

  # A line as a terminal shows it: its time, its pod, its level when it has one, and its message,
  # the columns of the console's Logs view.
  defp shown(line) do
    fields = line["fields"]

    [line["time"], fields["k8s.pod.name"], level(fields), line["message"]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" ")
  end

  defp level(fields) do
    case fields["severity_text"] || fields["log.level"] do
      level when is_binary(level) -> String.upcase(level)
      _none -> nil
    end
  end

  defp say(line, true), do: IO.puts(Output.json(line))
  defp say(line, false), do: IO.puts(printed(line))

  # A message of several lines has its later ones indented, so none of them reads as a line of its
  # own, with a time and a pod another application could write.
  defp printed(line),
    do: line |> shown() |> Output.shown_lines() |> String.replace("\n", "\n    ")

  # The tail, opened again after the credential it was opened with expired, or after it dropped,
  # from the last line printed, until an hour from the start: EHOS bounds one tail to an hour, and
  # each one opened again would start another. `state` holds that line's time, the credential EHOS
  # said was expired, how many times in a row the tail has failed, and when the hour ends.
  defp follow(installation, path, state, json?, opts) do
    if Ehosctl.Clock.current().monotonic() >= state.until,
      do: ended("expired", json?),
      else: followed(installation, path, state, json?, opts)
  end

  defp followed(installation, path, state, json?, opts) do
    case tail(installation, path, state, json?, opts) do
      {:halted, {:end, "credential_expired", credential, acc}} ->
        state = %{state | last: acc.last, expired: credential}
        expired(installation, path, state, acc, json?, opts)

      {:halted, {:end, reason, _credential, _acc}} ->
        ended(reason, json?)

      {:halted, :too_large} ->
        Output.error(
          :failed,
          "#{url(installation)} sent an event that is too large for ehosctl to read. " <>
            "ehosctl stopped the tail.",
          json?
        )

      {:halted, :unreadable} ->
        {:error, kind, message} = Api.unexpected(installation)
        Output.error(kind, message, json?)

      {:closed, acc} ->
        closed(installation, path, state, acc, json?, opts)

      {:refused, {:error, kind, message}} ->
        Output.error(kind, message, json?)

      {:error, :unreachable, _message} ->
        reconnect(
          installation,
          path,
          %{state | drops: state.drops + 1, why: :dropped},
          json?,
          opts
        )

      {:error, kind, message} ->
        Output.error(kind, message, json?)
    end
  end

  # A credential that ends a tail that stayed open, as one does about every ten minutes, is
  # renewed at once; one that ends a tail within a minute, lines or none, counts as a tail that
  # failed, so renewals EHOS keeps refusing are paced and given up.
  defp expired(installation, path, state, acc, json?, opts) do
    if lasted?(acc),
      do: follow(installation, path, %{state | drops: 0}, json?, opts),
      else:
        reconnect(
          installation,
          path,
          %{state | drops: state.drops + 1, why: :ended_at_once},
          json?,
          opts
        )
  end

  defp closed(installation, path, state, acc, json?, opts) do
    drops = if worked?(acc), do: 1, else: state.drops + 1

    reconnect(
      installation,
      path,
      %{state | last: acc.last, drops: drops, why: :dropped},
      json?,
      opts
    )
  end

  # A tail that printed a line, or stayed open, keep-alives and all, for a minute, was working.
  defp worked?(acc), do: acc.heard? or lasted?(acc)

  defp lasted?(acc), do: Ehosctl.Clock.current().monotonic() - acc.opened >= @steady_ms

  defp reconnect(installation, _path, %{drops: drops, why: :ended_at_once}, json?, _opts)
       when drops > @reconnects do
    Output.error(
      :failed,
      "#{url(installation)} ended the tail at once #{drops} times in a row. Each time, it " <>
        "said that the credential had expired, but each credential was new.",
      json?
    )
  end

  defp reconnect(installation, _path, %{drops: drops}, json?, _opts) when drops > @reconnects do
    Output.error(
      :unreachable,
      "#{url(installation)} stopped answering the tail #{drops} times in a row. Run the " <>
        "command again later.",
      json?
    )
  end

  defp reconnect(installation, path, state, json?, opts) do
    Ehosctl.Clock.current().sleep(1_000 * state.drops)
    follow(installation, path, state, json?, opts)
  end

  defp tail(installation, path, state, json?, opts) do
    {_name, %{"url" => url}} = installation
    fetch_opts = Keyword.put(opts, :instead_of, state.expired)

    with {:ok, credential} <- Credentials.fetch(installation, :ehos, fetch_opts) do
      # JSON too, so a refusal, and an EHOS without the route, answer in JSON: Phoenix picks an
      # error's format from Accept, and answers a stream's alone in HTML.
      headers =
        [{"accept", "text/event-stream, application/json"}] ++
          if state.last, do: [{"last-event-id", state.last}], else: []

      acc = %{
        parser: Parser.new(),
        held: 0,
        last: state.last,
        heard?: false,
        opened: Ehosctl.Clock.current().monotonic(),
        until: state.until
      }

      handle = &events(&1, &2, credential, json?)

      case HTTP.current().stream(url <> path, credential, headers, {acc, handle}, opts) do
        # A refusal ends the follow whatever its kind, `too_many_tails` and `logs_unavailable` too.
        {:ok, answer} ->
          tail_refused(installation, path, answer, opts)

        result ->
          result
      end
    end
  end

  defp tail_refused(installation, path, answer, opts) do
    case Api.routed_answer(installation, :get, path, answer, opts) do
      {:lacking, message} -> {:refused, {:error, :failed, message}}
      {:ok, answer} -> {:refused, Api.refusal(answer, installation)}
    end
  end

  # The events in a part of the tail: each line printed as it comes, and the end with its reason.
  defp events(part, acc, credential, json?) do
    {events, parser} = Parser.parse(acc.parser, part)
    held = if events == [], do: acc.held + byte_size(part), else: byte_size(part)
    acc = %{acc | parser: parser, held: held}

    cond do
      held > @max_event_bytes ->
        {:halt, :too_large}

      # The hour ends within a tail too, at its next part: a keep-alive comes every 15 seconds.
      Ehosctl.Clock.current().monotonic() >= acc.until ->
        {:halt, {:end, "expired", credential, acc}}

      true ->
        Enum.reduce_while(events, {:cont, acc}, &event(&1, &2, credential, json?))
    end
  end

  defp event(%{event: "line", data: data} = event, {:cont, acc}, _credential, json?) do
    with {:ok, line} <- JSON.decode(data), true <- line?(line) do
      say(kept(line), json?)
      # An empty id would send an empty Last-Event-ID, which says nothing of where it was.
      last = if event[:id] in [nil, ""], do: acc.last, else: event[:id]
      {:cont, {:cont, %{acc | last: last, heard?: true}}}
    else
      _unreadable -> {:halt, {:halt, :unreadable}}
    end
  end

  defp event(%{event: "end", data: reason}, {:cont, acc}, credential, _json?),
    do: {:halt, {:halt, {:end, reason, credential, acc}}}

  # An event a later EHOS adds is passed over.
  defp event(_event, result, _credential, _json?), do: {:cont, result}

  defp ended("expired", json?) do
    message =
      "The tail ended after 1 hour, the longest that a tail lasts. Run the command again to " <>
        "continue."

    IO.puts(
      :stderr,
      if(json?,
        do: Output.json(%{end: %{reason: "expired", message: message}}),
        else: "ehosctl: " <> message
      )
    )

    0
  end

  defp ended("refused", json?),
    do:
      Output.error(
        :refused,
        "The tail ended, because you can no longer read these logs.",
        json?
      )

  defp ended("unavailable", json?),
    do:
      Output.error(
        :unreachable,
        "The tail ended, because EHOS could not read the logs from its store. Run the " <>
          "command again.",
        json?
      )

  defp ended("too_slow", json?),
    do:
      Output.error(
        :failed,
        "The tail ended, because this terminal did not take the lines as fast as EHOS sent " <>
          "them. Give --grep or --deployment to get fewer lines.",
        json?
      )

  defp ended(reason, json?),
    do:
      Output.error(
        :failed,
        "The tail ended for a reason that this version of ehosctl does not know: " <>
          "#{Refusal.shown(reason)}.",
        json?
      )

  defp url({_name, installation}), do: installation["url"]
end

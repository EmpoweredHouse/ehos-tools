defmodule Ehosctl.Logs do
  @moduledoc """
  `ehosctl logs <application> --env E` and `ehosctl logs --platform`: the lines an application
  wrote in an environment, or EHOS's own, as EHOS keeps them and its console's Logs view shows
  them (eh-os D-93, EmpoweredHouse/eh-os#478). Reading an application's needs
  `ehos.telemetry.read` in the environment, and EHOS's own needs it at the whole platform; EHOS
  records every reading, and every refusal, without its lines.

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

  # A tail that drops is opened again this many times in a row before the follow ends.
  @reconnects 3
  # The most bytes of one event held before it is whole: EHOS's lines are smaller by far.
  @max_event_bytes 4_000_000

  @impl Ehosctl.Command
  def name, do: :logs

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Print an application's logs in an environment, or EHOS's own, newest last; " <>
          "--follow prints new lines as they come.",
      args: [
        application: [
          value_name: "APPLICATION",
          required: false,
          help: "The application whose logs to read; left out with --platform."
        ]
      ],
      options: [
        env: [long: "--env", value_name: "ENVIRONMENT", help: "The application's environment."],
        deployment: [
          long: "--deployment",
          value_name: "ID",
          help: "Only the lines of this deployment's image."
        ],
        since: [
          long: "--since",
          value_name: "SINCE",
          help: "How far back: 15m, 2h, 7d, or a time (ISO 8601); the last hour unless given."
        ],
        grep: [long: "--grep", value_name: "TEXT", help: "Only lines that hold this text."],
        limit: [
          long: "--limit",
          value_name: "N",
          parser: :integer,
          help: "How many of the newest lines, from 1 to 1000; 100 unless given."
        ]
      ],
      flags:
        [
          platform: [
            long: "--platform",
            help: "Read EHOS's own logs instead of an application's."
          ],
          follow: [
            long: "--follow",
            short: "-f",
            help: "Then print new lines as they come, for up to an hour."
          ]
        ] ++ Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    %{platform: platform?, follow: follow?, json: json?} = parsed.flags
    options = parsed.options

    with {:ok, target} <- target(parsed.args[:application], options, platform?) do
      path = path(target)
      installation = Keyword.fetch!(opts, :installation)
      filters = filters(options)

      with {:ok, page} <- read(installation, target, path, filters, opts) do
        if follow? do
          Enum.each(page.lines, &say(&1, json?))
          newest = page.lines |> List.last() |> then(&(&1 && &1["time"]))
          tail = path <> "/tail?" <> URI.encode_query(Map.take(filters, ["deployment", "grep"]))
          follow(installation, tail, %{last: newest, expired: nil, drops: 0}, json?, opts)
        else
          {:ok, %{text: text(page), json: page.json}}
        end
      end
    end
  end

  defp target(nil, %{env: nil, deployment: nil}, true), do: {:ok, :platform}

  defp target(_application, _options, true),
    do:
      {:error, :invalid,
       "--platform reads EHOS's own logs: it takes no application, --env or --deployment."}

  defp target(nil, _options, false),
    do:
      {:error, :invalid, "Name the application whose logs to read, or --platform for EHOS's own."}

  defp target(_application, %{env: nil}, false),
    do: {:error, :invalid, "Name the environment whose logs to read with --env."}

  defp target(application, %{env: env}, false) do
    case Enum.find([application, env], &(&1 in ["", ".", ".."])) do
      nil -> {:ok, {application, env}}
      word -> {:error, :invalid, "#{Refusal.shown(word)} names no application or environment."}
    end
  end

  defp path(:platform), do: "/api/v1/platform/logs"

  defp path({application, env}),
    do: "/api/v1/applications/#{segment(application)}/environments/#{segment(env)}/logs"

  defp segment(name), do: URI.encode(name, &URI.char_unreserved?/1)

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

          {:ok, %{target: target, lines: lines, more?: more?, json: json}}
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
    do: "No lines from #{whose(target)} in the time read. --since reads further back."

  defp text(%{lines: lines, more?: more?}) do
    shown = Enum.map_join(lines, "\n", &shown/1)
    if more?, do: shown <> "\nOlder lines remain: a larger --limit reads further.", else: shown
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
  defp say(line, false), do: IO.puts(Output.shown_lines(shown(line)))

  # The tail, opened again after the credential it was opened with expired, or after it dropped,
  # from the last line printed. `state` holds that line's time, the credential EHOS said was
  # expired, and how many times in a row the tail has dropped.
  defp follow(installation, path, state, json?, opts) do
    case tail(installation, path, state, json?, opts) do
      {:halted, {:end, "credential_expired", credential, last}} ->
        follow(
          installation,
          path,
          %{state | last: last, expired: credential, drops: 0},
          json?,
          opts
        )

      {:halted, {:end, reason, _credential, _last}} ->
        ended(reason, json?)

      {:halted, :too_large} ->
        Output.error(
          :failed,
          "#{url(installation)} sent an event larger than ehosctl reads.",
          json?
        )

      {:halted, :unreadable} ->
        {:error, kind, message} = Api.unexpected(installation)
        Output.error(kind, message, json?)

      {:closed, acc} ->
        drops = if acc.heard?, do: 1, else: state.drops + 1
        reconnect(installation, path, %{state | last: acc.last, drops: drops}, json?, opts)

      {:refused, {:error, kind, message}} ->
        Output.error(kind, message, json?)

      {:error, :unreachable, _message} ->
        reconnect(installation, path, %{state | drops: state.drops + 1}, json?, opts)

      {:error, kind, message} ->
        Output.error(kind, message, json?)
    end
  end

  defp reconnect(installation, _path, %{drops: drops}, json?, _opts) when drops > @reconnects do
    Output.error(
      :unreachable,
      "#{url(installation)} stopped answering the tail, #{drops} times in a row.",
      json?
    )
  end

  defp reconnect(installation, path, state, json?, opts) do
    Process.sleep(Keyword.get(opts, :logs_retry_ms, 1_000) * state.drops)
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

      acc = %{parser: Parser.new(), held: 0, last: state.last, heard?: false}
      handle = &events(&1, &2, credential, json?)

      case HTTP.stream(url <> path, credential, headers, {acc, handle}, opts) do
        # A refusal ends the follow whatever its kind, `too_many_tails` and `logs_unavailable` too.
        {:ok, answer} ->
          case Api.routed_answer(installation, :get, path, answer, opts) do
            {:lacking, message} -> {:refused, {:error, :failed, message}}
            {:ok, answer} -> {:refused, Api.refusal(answer, installation)}
          end

        result ->
          result
      end
    end
  end

  # The events in a part of the tail: each line printed as it comes, and the end with its reason.
  defp events(part, acc, credential, json?) do
    {events, parser} = Parser.parse(acc.parser, part)
    held = if events == [], do: acc.held + byte_size(part), else: byte_size(part)
    # Anything at all, a keep-alive too, says the tail was working before it dropped.
    acc = %{acc | parser: parser, held: held, heard?: acc.heard? or part != ""}

    if held > @max_event_bytes,
      do: {:halt, :too_large},
      else: Enum.reduce_while(events, {:cont, acc}, &event(&1, &2, credential, json?))
  end

  defp event(%{event: "line", data: data} = event, {:cont, acc}, _credential, json?) do
    with {:ok, line} <- JSON.decode(data), true <- line?(line) do
      say(kept(line), json?)
      {:cont, {:cont, %{acc | last: event[:id] || acc.last}}}
    else
      _unreadable -> {:halt, {:halt, :unreadable}}
    end
  end

  defp event(%{event: "end", data: reason}, {:cont, acc}, credential, _json?),
    do: {:halt, {:halt, {:end, reason, credential, acc.last}}}

  # An event a later EHOS adds is passed over.
  defp event(_event, result, _credential, _json?), do: {:cont, result}

  defp ended("expired", json?) do
    message = "The tail ended after an hour, as every tail does. Run the command again to go on."

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
    do: Output.error(:refused, "The tail ended: you may no longer read these logs.", json?)

  defp ended("unavailable", json?),
    do:
      Output.error(
        :unreachable,
        "The tail ended: EHOS could not read the logs from its store. Try again.",
        json?
      )

  defp ended("too_slow", json?),
    do:
      Output.error(
        :failed,
        "The tail ended: this terminal did not take the lines as fast as they came. " <>
          "Narrow them with --grep or --deployment.",
        json?
      )

  defp ended(reason, json?),
    do:
      Output.error(
        :failed,
        "The tail ended for a reason this ehosctl does not know: #{Refusal.shown(reason)}.",
        json?
      )

  defp url({_name, installation}), do: installation["url"]
end

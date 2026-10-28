defmodule Ehosctl.Call do
  @moduledoc """
  `ehosctl call <application> <capability> [field=value | field:=json …] [--data D] [--env E]`:
  does one thing in an application, as the person, through the routes of `EhOsContract.Plug`
  (T-10).

  The capability's kind comes from `ehosctl apps` (`Ehosctl.Api.applications/2`): a command is
  sent as `POST <address>/api/commands/<capability>`, a recording as
  `POST <address>/api/records/<capability>`, both with the fields as a JSON object, and a query as
  `GET <address>/api/queries/<capability>?<fields>`. The credential is the application's, from
  `Ehosctl.Credentials.fetch/3`.

  A capability none of the person's roles grants there is still asked for, so that whoever refuses
  it decides and records the refusal (eh-os FM-21, P-4, T-12): EHOS, which issues no
  credential where their roles grant nothing (`no_capability`), or the application, which refuses
  a credential without the capability (`missing_capability`). `ehosctl` cannot know the kind of a
  capability it was not granted, so it sends it as a command, then as a recording, then as a query
  without the fields, until the application finds it: `EhOsContract.Plug` routes by kind before it
  asks anything, so a kind that is not the capability's is answered not found and decides nothing.
  A kind the fields cannot make is left out, and is what the person is told when no kind sent is
  found. An application where none of their roles is bound is refused here, since its address is
  not known.

  Fields are typed as HTTPie types them: `field=value` is text, and `field:=json` a JSON value,
  a number, a boolean, `null`, a list or an object. `--data` gives a JSON object to start from,
  inline, `@file.json` or `-` for stdin, and the fields go over it. A query's list is a field
  given more than once, or a JSON list.

  Every command and recording carries an `idempotency-key`: a new one each time, which the
  application needs for a command that creates its aggregate and honours for every other, or the
  one `--idempotency-key` gives, to send the same call again and have it done once.

  An application's refusal is said in eh-os `docs/refusals.md`'s words, and exits with its kind's
  code (`Ehosctl.Refusal.application/3`).
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Credentials
  alias Ehosctl.HTTP
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @routes %{"command" => "commands", "record" => "records", "query" => "queries"}

  @impl Ehosctl.Command
  def name, do: :call

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Call an application: run a command, record something, or ask a query. Fields are " <>
          "`name=text` or `name:=<JSON>`, as in `amount:=100`.",
      allow_unknown_args: true,
      args: [
        application: [
          value_name: "APPLICATION",
          required: true,
          help: "The application, as `ehosctl apps` names it."
        ],
        capability: [
          value_name: "CAPABILITY",
          required: true,
          help: "What to call, as `ehosctl apps` lists it: ledger.record_entry."
        ],
        fields: [
          value_name: "FIELD",
          required: false,
          help:
            "The call's fields: `name=text`, or `name:=<JSON>` for a number, a boolean, null, " <>
              "a list or an object. A query takes a field more than once as a list."
        ]
      ],
      options: [
        env: Ehosctl.Credential.env_option(),
        data: [
          long: "--data",
          value_name: "JSON",
          help: "A JSON object of fields, inline, @file.json, or - for stdin; FIELDs go over it."
        ],
        idempotency_key: [
          long: "--idempotency-key",
          value_name: "KEY",
          help: "The command's idempotency key, to send it again and have it done once."
        ]
      ],
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{application: application, capability: capability} = parsed.args
    words = List.wrap(parsed.args[:fields]) ++ parsed.unknown

    with {:ok, fields} <- fields(words),
         {:ok, data} <- data(parsed.options.data, opts),
         :ok <- key(parsed.options.idempotency_key),
         {:ok, applications} <- Api.applications(installation, opts),
         {:ok, entry} <- Api.choose(applications, application, parsed.options.env),
         {:ok, kinds, granted?} <- kinds(entry, capability),
         {:ok, requests, unmade} <-
           requests(kinds, granted?, entry["address"], capability, data, fields, parsed.options),
         {:ok, credential} <- Credentials.fetch(installation, entry["address"], opts) do
      attempt(requests, credential, capability, {granted?, entry, unmade}, opts)
    end
  end

  # Each kind's request, in order, and the first error of a kind the fields cannot make. Not
  # granted, a query is asked without the fields: a URL is kept in logs where a body is not, and the
  # application refuses a credential without the capability before it reads them.
  defp requests(kinds, granted?, address, capability, data, fields, options) do
    built =
      for kind <- kinds do
        if kind == "query" and not granted?,
          do: request(kind, address, capability, %{}, [], options),
          else: request(kind, address, capability, data, fields, options)
      end

    unmade = Enum.find(built, &match?({:error, _kind, _message}, &1))

    case for({:ok, request} <- built, do: request) do
      [] -> unmade
      requests -> {:ok, requests, unmade}
    end
  end

  # Sent without a grant, a kind the application does not find the capability as is followed by
  # the next. When it finds it as none of those sent, a kind the fields could not make is what was
  # wrong, if there was one; else the person's roles grant no such capability there.
  defp attempt(
         [request | rest],
         credential,
         capability,
         {_granted?, entry, unmade} = context,
         opts
       ) do
    case send_request(request, credential, capability, context, opts) do
      :no_such_kind when rest != [] ->
        attempt(rest, credential, capability, context, opts)

      :no_such_kind when unmade != nil ->
        unmade

      :no_such_kind ->
        {:error, :refused,
         "None of your roles grants `#{Refusal.shown(capability)}` in " <>
           "#{Refusal.shown(entry["application"])} in #{Refusal.shown(entry["environment"])}, " <>
           "and the application has nothing of that name. Run `ehosctl apps` to see what they " <>
           "grant."}

      result ->
        result
    end
  end

  @doc """
  The fields of the command line, in order, as `{name, value}`: `name=value` as text, and
  `name:=json` as the JSON value it decodes to. A word that is neither is an error of kind
  `:invalid`.

      iex> Ehosctl.Call.fields(["note=hi", "amount:=100", "tags:=[\\"a\\"]"])
      {:ok, [{"note", "hi"}, {"amount", 100}, {"tags", ["a"]}]}
  """
  @spec fields([String.t()]) :: {:ok, [{String.t(), term()}]} | Refusal.error()
  def fields(words) do
    Enum.reduce_while(words, {:ok, []}, fn word, {:ok, fields} ->
      case field(word) do
        {:ok, field} -> {:cont, {:ok, [field | fields]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.reverse(fields)}
      error -> error
    end
  end

  # An option Optimus does not know reaches here too, `--evn=production` among them: it is a
  # mistyped option, never a field to send.
  defp field("-" <> _ = word),
    do:
      {:error, :invalid,
       "#{Refusal.shown(word)} is not an option of `ehosctl call`; see `ehosctl help call`."}

  defp field(word) do
    case String.split(word, "=", parts: 2) do
      [name, value] when name != "" and name != ":" ->
        if String.ends_with?(name, ":"),
          do: json_field(String.trim_trailing(name, ":"), value),
          else: {:ok, {name, value}}

      _ ->
        {:error, :invalid,
         "#{Refusal.shown(word)} is not a field: write `name=text`, or `name:=<JSON>` for a " <>
           "number, a boolean, null, a list or an object."}
    end
  end

  defp json_field(name, value) do
    case JSON.decode(value) do
      {:ok, decoded} ->
        {:ok, {name, decoded}}

      {:error, _reason} ->
        {:error, :invalid,
         "#{Refusal.shown(name)}:= takes JSON, and #{Refusal.shown(value)} is not: write " <>
           "text as #{Refusal.shown(name)}=…"}
    end
  end

  # `--data`: inline JSON, `@file`, or `-` for stdin (`opts[:stdin]` in tests).
  defp data(nil, _opts), do: {:ok, %{}}

  defp data("-", opts) do
    stdin = Keyword.get_lazy(opts, :stdin, fn -> IO.read(:stdio, :eof) end)
    if is_binary(stdin), do: object(stdin, "stdin"), else: object("", "stdin")
  end

  defp data("@" <> file, _opts) do
    case File.read(file) do
      {:ok, text} ->
        object(text, file)

      {:error, reason} ->
        {:error, :invalid, "cannot read #{file}: #{:file.format_error(reason)}"}
    end
  end

  defp data(text, _opts), do: object(text, "--data")

  defp object(text, where) do
    case JSON.decode(text) do
      {:ok, %{} = object} -> {:ok, object}
      _other -> {:error, :invalid, "#{where} does not hold a JSON object."}
    end
  end

  # refusals.md's rule for a key, checked before anything is sent, so that a key that could not
  # be one never reaches a header.
  defp key(nil), do: :ok

  defp key(key) do
    if key =~ ~r/\A[\x21-\x7E]{1,255}\z/,
      do: :ok,
      else: {:error, :invalid, Refusal.sentence("idempotency_key_invalid")}
  end

  # The capability's kind, and whether the person's roles grant it there. One they are not granted
  # is tried as every kind, for EHOS or the application to refuse and record (the module's doc).
  defp kinds(entry, capability) do
    case Enum.find(entry["capabilities"], &(&1["name"] == capability)) do
      %{"kind" => kind} ->
        if Api.known_kind?(kind),
          do: {:ok, [kind], true},
          else:
            {:error, :failed,
             "`#{Refusal.shown(capability)}` is a #{Refusal.shown(kind)}, which this version of " <>
               "ehosctl cannot call. Install a later one."}

      # A name that would leave its place in the path is none EHOS lists (`Ehosctl.Api`): it is
      # refused before anything is sent, since a client resolves dot segments.
      nil when Api.is_nameless(capability) ->
        {:error, :invalid,
         "#{inspect(capability)} names no capability. Run `ehosctl apps` to see what your roles " <>
           "grant."}

      nil ->
        {:ok, ["command", "record", "query"], false}
    end
  end

  @doc """
  The request a call of `capability` makes, before it is sent, as `%{method, url, body,
  headers, address}`: a command's or a recording's fields over `data` as its JSON body, with an
  `idempotency-key`, or a query's in its URL. A field given twice in a body is an error of kind
  `:invalid`; in a query, a list.
  """
  @spec request(String.t(), String.t(), String.t(), map(), [{String.t(), term()}], map()) ::
          {:ok, map()} | Refusal.error()
  def request(kind, address, capability, data, fields, options) do
    url =
      String.trim_trailing(address, "/") <>
        "/api/" <>
        Map.fetch!(@routes, kind) <> "/" <> Api.segment(capability)

    result =
      if kind == "query",
        do: query(url, data, fields),
        else: body(url, data, fields, options[:idempotency_key] || new_key())

    with {:ok, request} <- result, do: {:ok, Map.put(request, :address, address)}
  end

  defp body(url, data, fields, key) do
    case fields -- Enum.uniq_by(fields, &elem(&1, 0)) do
      [] ->
        {:ok,
         %{
           method: :post,
           url: url,
           body: Map.merge(data, Map.new(fields)),
           headers: [{"idempotency-key", key}]
         }}

      [{name, _value} | _] ->
        {:error, :invalid,
         "#{Refusal.shown(name)} is given twice; a list is written #{Refusal.shown(name)}:=[…]."}
    end
  end

  defp query(url, data, fields) do
    given = MapSet.new(fields, &elem(&1, 0))
    pairs = Enum.reject(data, fn {name, _value} -> name in given end) ++ fields

    case Enum.find(pairs, fn {_name, value} -> parameter(value) == :error end) do
      {name, _value} ->
        {:error, :invalid,
         "#{Refusal.shown(name)} is an object or a list of lists, and a query takes text, " <>
           "numbers, booleans and lists of them."}

      nil ->
        parameters =
          Enum.flat_map(pairs, fn {name, value} ->
            {:ok, values} = parameter(value)
            Enum.map(values, &{name, &1})
          end)

        query = if parameters == [], do: "", else: "?" <> URI.encode_query(parameters)
        {:ok, %{method: :get, url: url <> query, body: nil, headers: []}}
    end
  end

  # A query's values are text in its URL, which the application decodes by the field's type.
  defp parameter(list) when is_list(list) do
    if Enum.any?(list, &(is_list(&1) or is_map(&1))),
      do: :error,
      else: {:ok, Enum.flat_map(list, &elem(parameter(&1), 1))}
  end

  defp parameter(%{}), do: :error
  defp parameter(nil), do: {:ok, [""]}
  defp parameter(text) when is_binary(text), do: {:ok, [text]}
  defp parameter(value), do: {:ok, [JSON.encode!(value)]}

  # T-10: a new key on every command, which a command that creates its aggregate needs and any
  # other honours. A key of the form the application accepts: printable ASCII, a UUID's text.
  defp new_key do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      Enum.join(
        [
          binary_part(hex, 0, 8),
          binary_part(hex, 8, 4),
          binary_part(hex, 12, 4),
          binary_part(hex, 16, 4),
          binary_part(hex, 20, 12)
        ],
        "-"
      )
    end)
  end

  @doc """
  The options the request to the application is sent with: its headers, the environment, read for
  `EHOSCTL_CA_FILE`, and the CA kept for the installation the application runs in (T-14), whose
  CA signs the application's certificate as it signs EHOS's.
  """
  @spec http_opts(
          %{required(:headers) => [{String.t(), String.t()}], optional(atom()) => term()},
          keyword()
        ) :: keyword()
  def http_opts(request, opts), do: [headers: request.headers] ++ Keyword.take(opts, [:ca])

  defp send_request(request, credential, capability, {granted?, _entry, _unmade}, opts) do
    address = request.address

    case HTTP.request(
           request.method,
           request.url,
           credential,
           request.body,
           http_opts(request, opts)
         ) do
      {:ok, %{status: 200, body: %{} = body}} ->
        {:ok, %{text: text(body, capability), json: body}}

      {:ok, %{status: 200}} ->
        {:error, :failed, "#{address} answered with something ehosctl cannot read."}

      # Sent without a grant, as a kind that is not the capability's (`attempt/5`).
      {:ok, %{status: 404, body: %{"error" => "not_found"}}} when not granted? ->
        :no_such_kind

      {:ok, answer} ->
        error = Refusal.application(answer, capability, address)

        if answer.status >= 500 and not nothing_done?(answer.body),
          do: maybe_done(error, request),
          else: error

      {:error, kind, message, :sent} ->
        maybe_done({:error, kind, message}, request)

      error ->
        error
    end
  end

  # What an application says when it wrote nothing, or what answers before it is reached.
  defp nothing_done?(%{} = body),
    do: (body["error"] || body["refused"]) in ~w(not_supplied temporarily_unavailable)

  defp nothing_done?(_body), do: false

  # A command that went unanswered, or answered by a 5xx a gateway could have sent for it, may
  # have been done: the key it carried is what sends it again and has it done once (T-10).
  defp maybe_done({:error, kind, message}, %{method: :post} = request) do
    [{"idempotency-key", key}] = request.headers

    {:error, kind,
     message <>
       " It may have been done: send the same call with --idempotency-key #{key} to have " <>
       "it done once."}
  end

  defp maybe_done(error, _request), do: error

  defp text(%{"command_id" => id} = receipt, capability) do
    head =
      if receipt["duplicate"] == true,
        do:
          "Already done with this idempotency key, as #{shown(id)}; nothing was recorded again.",
        else: "Done: #{Refusal.shown(capability)}, as #{shown(id)}."

    identity =
      if receipt["identity"] in [nil, false, "", [], %{}],
        do: [],
        else: ["  identity: #{shown(receipt["identity"])}"]

    events =
      for %{"type" => type} = event <- List.wrap(receipt["events"]),
          do: "  event: #{shown(type)} at position #{shown(event["position"])}"

    Enum.join([head | identity ++ events], "\n")
  end

  defp text(%{"rows" => []}, _capability), do: "No rows."
  defp text(%{"row" => nil}, _capability), do: "No row."
  defp text(%{"rows" => rows}, _capability), do: Output.pretty_json(rows)
  defp text(%{"row" => row}, _capability), do: Output.pretty_json(row)
  defp text(body, _capability), do: Output.pretty_json(body)

  defp shown(value) when is_binary(value), do: Refusal.shown(value)
  # What is not text is shown as the application sent it: a unit's identity is an object of its
  # fields, `{"computer_id":"01a1…"}`.
  defp shown(value), do: Output.json(value)
end

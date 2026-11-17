defmodule Ehosctl.Db do
  @moduledoc """
  `ehosctl db`: a person's data sessions, a time-limited way into one application's database in
  one environment (eh-os
  [D-149](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0149-a-person-s-database-session-reaches-its-instance-through-a-data-gateway-of-its-own-not-the-governance-plane.md),
  [D-171](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0171-a-person-s-database-session-gets-a-role-that-is-made-as-its-binding-s-roles-are-a-member-of-its-schema-s-read-or-write-group-with-a-password-only-the-person-s-client-knows-and-openbao-makes-none.md)).

  - `db connect APP --env E [--write] [--ttl D]` opens a data session, starts `psql` on it in
    the terminal, and ends the session when `psql` exits (`Ehosctl.DataSession`);
  - `db tunnel APP --env E [--write] [--ttl D]` opens one, prints how another client connects
    to it, and keeps it until Ctrl-C or its end;
  - `db sessions APP --env E` lists the open data sessions of an application in an environment,
    for a person who may end them there; `db sessions --mine` lists the person's own;
  - `db end ID` ends a data session now: its person's, or one where the person manages role
    bindings. Its connections close, and its database role is dropped.

  EHOS decides and records each call, and its refusal is printed in its words.

  `db trust-ca FINGERPRINT` takes the data CA or the gateway CA that the installation gives now,
  when its fingerprint is the one the person typed: the one way a CA with a new key replaces the
  one `ehosctl` keeps (`Ehosctl.DataCa`). The fingerprint comes from the installation's
  administrator, outside EHOS, so a governance plane taken over cannot give it.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.DataCa
  alias Ehosctl.DataSession
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @look "`ehosctl db sessions --mine`"

  defp named(app, env) do
    if Api.is_nameless(app) or Api.is_nameless(env),
      do: {:error, :invalid, "Give the names of the application and of the environment."},
      else: :ok
  end

  # `--ttl` in seconds, from a minute; EHOS refuses one past its installation's limit.
  defp ttl_seconds(nil), do: {:ok, nil}

  defp ttl_seconds(ttl) do
    case Regex.run(~r/\A([1-9][0-9]{0,5})([smh])\z/, ttl) do
      [_ttl, count, unit] ->
        at_least_a_minute(String.to_integer(count) * unit(unit), ttl)

      nil ->
        {:error, :invalid,
         "--ttl #{Refusal.shown(ttl)} is not a duration. Give a number and a unit, such as 30m or 2h."}
    end
  end

  defp unit("s"), do: 1
  defp unit("m"), do: 60
  defp unit("h"), do: 3_600

  defp at_least_a_minute(seconds, _ttl) when seconds >= 60, do: {:ok, seconds}

  defp at_least_a_minute(_seconds, ttl),
    do: {:error, :invalid, "--ttl #{Refusal.shown(ttl)} is less than 1 minute. Give 1m or more."}

  # psql runs on the terminal, so without one a session would open for nothing, and count
  # against the person's sessions in the hour.
  defp terminal(:connect) do
    if Ehosctl.Terminal.current().input_terminal?(),
      do: :ok,
      else:
        {:error, :invalid,
         "ehosctl db connect starts psql on your terminal, and finds none. Use " <>
           "`ehosctl db tunnel` to connect another client without one."}
  end

  defp terminal(:tunnel), do: :ok

  # `db connect` runs psql; `db tunnel` waits in `sleep`, which Ctrl-C ends.
  defp program(command) do
    name = if command == :connect, do: "psql", else: "sleep"

    case Ehosctl.OS.current().find_executable(name) do
      nil when command == :connect ->
        {:error, :failed,
         "ehosctl db connect needs psql, the client of PostgreSQL, version 16 or later. " <>
           "Install it, or use `ehosctl db tunnel` with another client."}

      nil ->
        {:error, :failed, "ehosctl db tunnel needs the program sleep, and finds none."}

      path ->
        {:ok, path}
    end
  end

  # Each event of the session's tunnels that needs a word, on stderr, as it comes; and the
  # command told when the session has ended, for `db tunnel`'s wait.
  defp printer(session) do
    host = DataSession.gateway_host(session)
    command = self()

    fn event ->
      said(DataSession.said(event, host))
      if DataSession.ended?(event), do: send(command, {:data_session_ended, session.id})
    end
  end

  defp said(nil), do: :ok
  defp said(sentence), do: IO.puts(:stderr, "ehosctl: " <> sentence)

  defp run(:connect, psql, session, app, env, level) do
    IO.puts(:stderr, opened(session, app, env, level) <> " psql starts.")
    Ehosctl.Runner.current().foreground(psql, [], DataSession.libpq(session))
  end

  defp run(:tunnel, sleep, session, app, env, level) do
    terminal = Ehosctl.Terminal.current()
    terminal? = terminal.input_terminal?()
    IO.puts(opened(session, app, env, level) <> "\n\n" <> connection(session))
    if terminal.error_terminal?(), do: IO.puts(:stderr, "Password: " <> session.secrets.password)
    seconds = max(DateTime.diff(session.expires_at, Ehosctl.Clock.current().now()), 1)
    wait(terminal?, sleep, seconds, session.id)
    0
  end

  # At a terminal, Ctrl-C ends the wait, and a session that ends sooner is said there. Without
  # one, as in a script, the wait lasts until the session's end, or until a tunnel says that it
  # ended (`printer/1`), or until the process is stopped, and then EHOS ends it at its time.
  defp wait(true, sleep, seconds, _id),
    do: Ehosctl.Runner.current().foreground(sleep, [Integer.to_string(seconds)], [])

  defp wait(false, _sleep, seconds, id) do
    receive do
      {:data_session_ended, ^id} -> :ok
    after
      seconds * 1000 -> :ok
    end
  end

  defp opened(session, app, env, level),
    do:
      "Opened the data session #{session.id} on #{app} in #{env}, to #{level}, until " <>
        "#{Output.date(session.expires_at)}."

  # Standard output may go to a file or a log, which keeps it beyond the session and may show it
  # to others, and under Burrito it is always a pipe, whatever it ends in: so it names the
  # password file, which only the person can read. The password itself goes to standard error,
  # and only when that is a terminal (`run/6`).
  # `require_auth` is left out of the libpq line, since libpq 13 to 15 refuse the whole line for
  # it; `channel_binding=require` admits SCRAM alone.
  defp connection(session) do
    database = session.database
    port = Integer.to_string(session.port)
    options = DataSession.options(database)
    root_cert = session.files.root_cert

    """
    Connect a database client to it with these values:

      Host          #{database.host}
      Address       127.0.0.1
      Port          #{port}
      Database      #{database.name}
      User          #{database.user}
      Password      in the password file #{session.files.passfile}
      CA            #{root_cert}
      Options       #{options}

    libpq:  host=#{database.host} hostaddr=127.0.0.1 port=#{port} dbname=#{database.name} user=#{database.user} sslmode=verify-full sslrootcert=#{DataSession.quoted(root_cert)} passfile=#{DataSession.quoted(session.files.passfile)} channel_binding=require options=#{DataSession.quoted(options)}
    JDBC:   jdbc:postgresql://127.0.0.1:#{port}/#{database.name}?user=#{database.user}&sslmode=verify-ca&sslrootcert=#{root_cert}&channelBinding=require

    The client must verify the server against the CA and require channel binding: libpq 13 or
    later, pgjdbc 42.7.12 or later. libpq also checks the host. A client that cannot give the host
    apart from the address, such as JDBC, checks the CA alone (verify-ca). Give it the options too.

    Press Ctrl-C to end the data session. Without a terminal, it lasts until its end.
    """
    |> String.trim_trailing()
  end

  # What a session's row shows, and `--json` prints: no answer carries a password or a verifier.
  @shown ~w(id application environment level role state opened_at expires_at ended_at end_reason)

  @impl Ehosctl.Command
  def name, do: :db

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    [
      about: "Open, list and end your data sessions, and trust the CAs that they use.",
      subcommands: [
        connect: [
          name: "connect",
          about:
            "Open a data session on an application in an environment, and start psql on it. " <>
              "The data session ends when psql exits.",
          args: [app: app_arg()],
          options: session_options(),
          flags: session_flags()
        ],
        tunnel: [
          name: "tunnel",
          about:
            "Open a data session on an application in an environment, and show how another " <>
              "database client connects to it. Press Ctrl-C to end the data session.",
          args: [app: app_arg()],
          options: session_options(),
          flags: session_flags()
        ],
        sessions: [
          name: "sessions",
          about:
            "List the open data sessions of an application in an environment, or your own " <>
              "with --mine.",
          args: [
            app: [
              value_name: "APP",
              required: false,
              help: "The application. Give it with --env, or give --mine instead."
            ]
          ],
          options: [
            env: [
              long: "--env",
              value_name: "ENVIRONMENT",
              help: "The environment of the application."
            ]
          ],
          flags:
            [mine: [long: "--mine", help: "List your own open data sessions, everywhere."]] ++
              Output.json_flag()
        ],
        end: [
          name: "end",
          about:
            "End a data session now. Its connections close, and its database role is removed.",
          args: [
            id: [
              value_name: "ID",
              required: true,
              help: "The ID of the data session, as `ehosctl db sessions` shows it."
            ]
          ],
          flags: Output.json_flag()
        ],
        trust_ca: [
          name: "trust-ca",
          about:
            "Trust the new data CA or gateway CA of the installation. Give the fingerprint " <>
              "that the administrator of the installation gave you.",
          args: [
            fingerprint: [
              value_name: "FINGERPRINT",
              required: true,
              help:
                "The SHA-256 of the key of the CA, in base64, or in hexadecimal with or " <>
                  "without colons."
            ]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  defp app_arg,
    do: [value_name: "APP", required: true, help: "The application whose database you open."]

  defp session_options do
    [
      env: [
        long: "--env",
        value_name: "ENVIRONMENT",
        required: true,
        help: "The environment of the application."
      ],
      ttl: [
        long: "--ttl",
        value_name: "DURATION",
        help:
          "How long the data session lasts, from 1m up to the limit of the installation. If " <>
            "you give none, it lasts 1 hour. Examples: 30m, 2h."
      ]
    ]
  end

  defp session_flags do
    [
      write: [
        long: "--write",
        help:
          "Open a data session that can change the data. Without it, the data session can only " <>
            "read."
      ]
    ]
  end

  @doc "Runs the subcommand in `path`, for the installation in `opts[:installation]`."
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([command], parsed, opts) when command in [:connect, :tunnel] do
    installation = Keyword.fetch!(opts, :installation)
    %{args: %{app: app}, options: %{env: env, ttl: ttl}, flags: %{write: write?}} = parsed
    level = if write?, do: "write", else: "read"

    with :ok <- named(app, env),
         {:ok, seconds} <- ttl_seconds(ttl),
         :ok <- terminal(command),
         {:ok, program} <- program(command),
         {:ok, session} <- DataSession.open(installation, app, env, level, seconds, opts),
         {:ok, session} <- DataSession.listen(session, printer(session), opts) do
      # Whatever happens to the program, the session ends here, and its files go.
      try do
        run(command, program, session, app, env, level)
      after
        IO.puts(:stderr, DataSession.close(session, opts))
      end
    end
  end

  def call([:sessions], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, where} <- where(parsed.args[:app], parsed.options[:env], parsed.flags[:mine]),
         {:ok, %{"sessions" => sessions}} when is_list(sessions) <-
           Api.read(installation, sessions_path(where), opts),
         true <- Enum.all?(sessions, &session?/1) || Api.unexpected(installation) do
      sessions = Enum.map(sessions, &Map.take(&1, @shown))
      {:ok, %{text: sessions_text(where, sessions), json: %{sessions: sessions}}}
    else
      {:ok, _body} -> Api.unexpected(Keyword.fetch!(opts, :installation))
      error -> error
    end
  end

  def call([:end], %{args: %{id: typed}}, opts) do
    with :ok <- session_id(typed) do
      # EHOS answers an ID in lower case, whatever case it was asked in (`Ecto.UUID`).
      id = String.downcase(typed)

      Api.write(
        opts,
        {:delete, "/api/v1/sessions/" <> id, nil},
        [
          status: 200,
          key: "session",
          valid?: &match?(%{"id" => ^id, "state" => "ended"}, &1),
          only: &Map.take(&1, ["id", "state"]),
          look: @look
        ],
        fn _session -> "Ended the data session #{id}." end
      )
    end
  end

  def call([:trust_ca], %{args: %{fingerprint: typed}}, opts) do
    {name, _installation} = installation = Keyword.fetch!(opts, :installation)

    with :ok <- kept_here(installation),
         {:ok, fingerprint} <- fingerprint(typed),
         {:ok, offered} <- DataCa.offered(installation, opts),
         {:ok, kind, ca} <- matching(offered, fingerprint, name),
         before = before(installation, kind),
         {:ok, _read, _written} <-
           Config.update(config_dir(opts), &{:ok, Config.put_data_ca(&1, name, kind, ca)}) do
      {:ok, trusted(name, kind, fingerprint, before)}
    end
  end

  defp where(nil, nil, true), do: {:ok, :mine}

  defp where(app, env, mine) when is_binary(app) and is_binary(env) and mine != true do
    if Api.is_nameless(app) or Api.is_nameless(env),
      do: {:error, :invalid, "Give the names of the application and of the environment."},
      else: {:ok, {app, env}}
  end

  defp where(_app, _env, true),
    do:
      {:error, :invalid,
       "--mine lists your own data sessions everywhere. Give it without an application or " <>
         "--env."}

  defp where(_app, _env, _mine),
    do:
      {:error, :invalid,
       "Give an application and --env, such as `ehosctl db sessions ledger --env staging`, " <>
         "or give --mine for your own data sessions."}

  defp sessions_path(:mine), do: "/api/v1/sessions"

  defp sessions_path({app, env}),
    do: "/api/v1/applications/#{Api.segment(app)}/environments/#{Api.segment(env)}/sessions"

  # A row is printed only when its words are there and its times can be read.
  defp session?(%{} = session) do
    Enum.all?(~w(id application environment level state), &is_binary(session[&1])) and
      Enum.all?(~w(opened_at expires_at), &match?({:ok, _, _}, time(session[&1])))
  end

  defp session?(_session), do: false

  defp time(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp time(_value), do: :error

  defp sessions_text(:mine, []),
    do:
      "You have no open data sessions. A data session shows here when you open one with " <>
        "`ehosctl db connect` or `ehosctl db tunnel`."

  defp sessions_text({app, env}, []),
    do:
      "#{Refusal.shown(app)} has no open data sessions in #{Refusal.shown(env)}. A data " <>
        "session shows here when a person opens one there."

  defp sessions_text(_where, sessions) do
    sessions
    |> Enum.map(fn session ->
      %{
        "ID" => Refusal.shown(session["id"]),
        "APPLICATION" => Refusal.shown(session["application"]),
        "ENVIRONMENT" => Refusal.shown(session["environment"]),
        "LEVEL" => Refusal.shown(session["level"]),
        "STATE" => Refusal.shown(session["state"]),
        "OPENED" => Output.date(session["opened_at"]),
        "EXPIRES" => Output.date(session["expires_at"])
      }
    end)
    |> Output.table(~w(ID APPLICATION ENVIRONMENT LEVEL STATE OPENED EXPIRES))
  end

  defp session_id(id) do
    if Api.uuid?(id),
      do: :ok,
      else:
        {:error, :invalid,
         "#{Refusal.shown(id)} is not the ID of a data session. `ehosctl db sessions --mine` " <>
           "shows the IDs of your data sessions."}
  end

  # `EHOSCTL_URL` names an installation that no `config.json` keeps (T-18).
  defp kept_here(installation) do
    if Config.from_url?(installation),
      do:
        {:error, :invalid,
         "EHOSCTL_URL names an installation that ehosctl keeps nothing for. Run " <>
           "`ehosctl login URL` with the address of the installation."},
      else: :ok
  end

  defp fingerprint(typed) do
    case DataCa.typed(typed) do
      {:ok, fingerprint} ->
        {:ok, fingerprint}

      :error ->
        {:error, :invalid,
         "#{inspect(typed)} is not a fingerprint. A fingerprint is a SHA-256 in base64, such " <>
           "as qUiQTy8PR5uPgZdpSzAYSw0u0cHNKh7A+4XSmaGSpEc=, or in hexadecimal."}
    end
  end

  defp matching(offered, fingerprint, name) do
    found =
      Enum.find(DataCa.kinds(), fn kind ->
        match?(%{key_sha256: ^fingerprint}, offered[kind])
      end)

    if found,
      do: {:ok, found, offered[found]},
      else:
        {:error, :failed,
         "Neither the data CA nor the gateway CA that #{name} gives has the fingerprint " <>
           "#{fingerprint}. ehosctl trusts nothing new. Check the fingerprint with the " <>
           "administrator of the installation."}
  end

  # A kept CA `ehosctl` cannot read is replaced too: this is how the person mends it.
  defp before(installation, kind) do
    case DataCa.kept(installation, kind) do
      {:ok, kept} -> kept
      {:error, _kind, _message} -> nil
    end
  end

  defp trusted(name, kind, fingerprint, before) do
    already? = match?(%{key_sha256: ^fingerprint}, before)

    text =
      if already?,
        do: "ehosctl already trusts the #{DataCa.label(kind)} of #{name} with this fingerprint.",
        else: "ehosctl now trusts the #{DataCa.label(kind)} of #{name} with this fingerprint."

    %{
      text: text,
      json: %{installation: name, ca: kind, key_sha256: fingerprint, changed: not already?}
    }
  end

  defp config_dir(opts), do: Keyword.get_lazy(opts, :config_dir, &Config.dir/0)
end

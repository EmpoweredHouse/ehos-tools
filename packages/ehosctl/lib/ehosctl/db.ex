defmodule Ehosctl.Db do
  @moduledoc """
  `ehosctl db`: a person's data sessions, a time-limited way into one application's database in
  one environment (eh-os
  [D-149](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0149-a-person-s-database-session-reaches-its-instance-through-a-data-gateway-of-its-own-not-the-governance-plane.md),
  [D-171](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0171-a-person-s-database-session-gets-a-role-that-is-made-as-its-binding-s-roles-are-a-member-of-its-schema-s-read-or-write-group-with-a-password-only-the-person-s-client-knows-and-openbao-makes-none.md)).

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
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @look "`ehosctl db sessions --mine`"

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

  @doc "Runs the subcommand in `path`, for the installation in `opts[:installation]`."
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
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

  def call([:end], %{args: %{id: id}}, opts) do
    with :ok <- session_id(id) do
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

defmodule Ehosctl.DataSession do
  @moduledoc """
  One data session as `ehosctl db connect` and `ehosctl db tunnel` hold it, from its opening to
  its end (eh-os
  [D-149](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0149-a-person-s-database-session-reaches-its-instance-through-a-data-gateway-of-its-own-not-the-governance-plane.md),
  [D-179](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0179-ehosctl-reaches-the-data-gateway-at-data-host-with-one-websocket-per-connection-proving-its-session-with-a-self-signed-p-256-certificate-for-the-key-it-sent.md)).

  `open/6` makes the session's password and key (`Ehosctl.SessionSecrets`), opens the session
  with their verifier and public half, and checks EHOS's answer: the tunnel is the installation's
  data gateway's, and the data CA and the gateway CA are the ones `ehosctl` keeps
  (`Ehosctl.DataCa`). It then listens on a local port, where each connection goes through a
  tunnel of its own to the data gateway (`Ehosctl.Tunnel`), verified against the kept gateway CA
  alone, and writes the password file and the data CA for `libpq` (`Ehosctl.SessionFiles`).
  `close/2` ends it all: the listener, the session at EHOS, and the files.

  `libpq/1` is the connection as `libpq`'s variables: `sslmode=verify-full` against the kept
  data CA, with the instance's name apart from the local address, channel binding and SCRAM
  required, and the session's timeouts in `options`, since the role cannot carry them (eh-os
  D-171).
  """

  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.DataCa
  alias Ehosctl.Failure
  alias Ehosctl.Output
  alias Ehosctl.Postgres
  alias Ehosctl.Refusal
  alias Ehosctl.SessionFiles
  alias Ehosctl.SessionSecrets

  @enforce_keys [:installation, :id, :secrets, :database, :expires_at, :tunnel_url]
  defstruct [
    :installation,
    :id,
    :secrets,
    :database,
    :expires_at,
    :tunnel_url,
    :gateway_ca,
    :data_ca,
    :listener,
    :port,
    :files,
    ends_with_role_binding: false
  ]

  @typedoc "A data session that `open/6` opened, and `listen/3` made reachable."
  @type t :: %__MODULE__{}

  @typedoc "Where the session's database is, as EHOS answers it."
  @type database :: %{
          host: String.t(),
          port: pos_integer(),
          name: String.t(),
          user: String.t(),
          schema: String.t() | nil
        }

  # A session's role answers within 30 seconds when 50 open together (eh-os D-177); EHOS waits
  # longer than CloudNativePG's 30 seconds before it refuses one, so the request waits longer
  # still.
  @open_timeout_ms 120_000

  # A moment in ISO 8601, as EHOS writes one into a sentence.
  @moment ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})/

  @outside_guide "The guide for the installation administrator says how to give a person a " <>
                   "way to that data: https://github.com/EmpoweredHouse/eh-os/blob/main/docs/" <>
                   "INSTALLING.md#give-a-person-a-way-to-an-applications-data-on-a-database-" <>
                   "outside-the-installation"

  # The timeouts of a session's connection (the plan of eh-os's Stage 14, step 6).
  @timeouts [
    statement_timeout: "5min",
    lock_timeout: "5s",
    idle_in_transaction_session_timeout: "1min"
  ]

  @doc """
  Opens a data session on `application` in `environment` of `installation`, of `level`
  (`"read"` or `"write"`) for `ttl` seconds, `nil` for EHOS's default. Needs the data CA and
  the gateway CA kept for the installation. A session whose answer `ehosctl` does not trust is
  ended at once, and the error says why.
  """
  @spec open(
          {Config.name(), Config.installation()},
          String.t(),
          String.t(),
          String.t(),
          pos_integer() | nil,
          keyword()
        ) :: {:ok, t()} | Api.error()
  def open(installation, application, environment, level, ttl, opts) do
    secrets = SessionSecrets.new()

    path =
      "/api/v1/applications/#{Api.segment(application)}/environments/" <>
        "#{Api.segment(environment)}/sessions"

    with {:ok, data_ca} <- kept_ca(installation, :data),
         {:ok, gateway_ca} <- kept_ca(installation, :gateway),
         {:ok, body} <-
           requested(
             installation,
             path,
             SessionSecrets.opening(secrets, level, ttl),
             Keyword.put(opts, :timeout, @open_timeout_ms)
           ) do
      checked(body["session"], installation, secrets, data_ca, gateway_ca, opts)
    end
  end

  defp kept_ca(installation, kind) do
    case DataCa.kept(installation, kind) do
      {:ok, nil} -> {:error, :failed, no_ca(installation, kind)}
      result -> result
    end
  end

  defp no_ca({name, _installation}, kind),
    do:
      Failure.new(
        "ehosctl keeps no #{DataCa.label(kind)} for #{name}, so it cannot check a data session " <>
          "there.",
        reason: "If the installation runs no data gateway, it opens no data session.",
        advice: "Sign in again, which keeps the CA:",
        to_do: ["ehosctl login --installation #{name}"]
      )

  defp requested(installation, path, body, opts) do
    case Api.answer(installation, :post, path, body, opts) do
      {:ok, %{status: 201, body: %{"session" => %{}} = answer}} ->
        {:ok, answer}

      {:ok, %{status: status} = answer} when status not in 200..299 ->
        answer |> Api.refusal(installation) |> guided()

      {:ok, _other} ->
        Api.unexpected(installation)

      {:error, kind, message, :sent} ->
        {:error, kind,
         message
         |> Failure.added(" EHOS possibly opened the data session.")
         |> Failure.with_to_do("See it, then end it with its ID:", [
           Config.command("ehosctl db sessions --mine", installation),
           Config.command("ehosctl db end ID", installation)
         ])}

      error ->
        error
    end
  end

  # eh-os D-170: on a database outside the installation, its administrator gives a person a way
  # to the data, and the guide says how; EHOS's sentence names the groups.
  defp guided({:error, kind, message, %{"code" => "outside_installation"} = refusal}),
    do: Refusal.added({:error, kind, message, refusal}, "\n" <> @outside_guide)

  # eh-os D-203: EHOS's sentence gives the role binding's end in ISO 8601, which ehosctl shows as
  # it shows every moment (T-28).
  defp guided({:error, kind, message, %{"code" => "binding_ends"} = refusal})
       when is_binary(message),
       do: {:error, kind, Regex.replace(@moment, message, &Output.date/1), refusal}

  defp guided(error), do: error

  # Whatever is wrong with an answer, a session it names is ended, so none is left open that
  # this command cannot reach.
  defp checked(session, installation, secrets, data_ca, gateway_ca, opts) do
    with {:ok, id} <- session_id(session, installation),
         {:ok, opened} <- read(session, id, installation, secrets),
         :ok <- same_cas(session, installation, data_ca, gateway_ca) do
      {:ok, %{opened | data_ca: data_ca, gateway_ca: gateway_ca}}
    else
      {:ended, id, error} -> ended_with(installation, id, error, opts)
      error -> error
    end
  end

  defp session_id(%{"id" => id}, _installation) when is_binary(id) do
    if Api.uuid?(id), do: {:ok, id}, else: {:error, :failed, "EHOS gave no ID for the session."}
  end

  defp session_id(_session, installation), do: Api.unexpected(installation)

  defp read(session, id, {_name, %{"url" => url}} = installation, secrets) do
    expected = EhosTunnel.Protocol.url("wss://data." <> URI.parse(url).host, id)

    with {:tunnel, %{"url" => ^expected, "protocol" => protocol}} <- {:tunnel, session["tunnel"]},
         true <- protocol == EhosTunnel.Protocol.subprotocol(),
         {:ok, database} <- database(session["database"]),
         expires when is_binary(expires) <- session["expires_at"],
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires) do
      {:ok,
       %__MODULE__{
         installation: installation,
         id: id,
         secrets: secrets,
         database: database,
         expires_at: expires_at,
         # eh-os D-203: the end of a role binding in production set the session's end. An EHOS
         # before it gives no key.
         ends_with_role_binding: session["ends_with_role_binding"] == true,
         tunnel_url: expected
       }}
    else
      {:tunnel, _other} ->
        {:ended, id,
         {:error, :failed,
          "EHOS gave a tunnel that is not the data gateway of the installation, at " <>
            "data.#{URI.parse(url).host}. ehosctl does not use it."}}

      _other ->
        {:ended, id, Api.unexpected(installation)}
    end
  end

  # An EHOS older than 0.32 names no schema.
  defp database(%{"host" => host, "port" => port, "name" => name, "user" => user} = given)
       when is_binary(host) and is_integer(port) and port in 1..65_535 and is_binary(name) and
              is_binary(user) do
    schema = given["schema"]
    words = [host, name, user | if(is_nil(schema), do: [], else: [schema])]

    if Enum.all?(words, &(is_binary(&1) and &1 =~ ~r/\A[A-Za-z0-9_.-]{1,253}\z/)),
      do: {:ok, %{host: host, port: port, name: name, user: user, schema: schema}},
      else: :error
  end

  defp database(_given), do: :error

  # The CAs a session's answer gives must be the kept ones: a renewed certificate with the kept
  # key is taken at the next login, never here.
  defp same_cas(session, installation, data_ca, gateway_ca) do
    case DataCa.parsed(session, installation) do
      {:ok, offered} -> changed_ca(offered, data_ca, gateway_ca, installation, session["id"])
      error -> {:ended, session["id"], error}
    end
  end

  defp changed_ca(offered, data_ca, gateway_ca, installation, id) do
    [data: data_ca, gateway: gateway_ca]
    |> Enum.find(fn {kind, kept} ->
      match?({:changed, _offered}, DataCa.compare(kept, offered[kind]))
    end)
    |> changed_kind(installation, id)
  end

  defp changed_kind(nil, _installation, _id), do: :ok

  defp changed_kind({kind, _kept}, {name, _installation}, id),
    do: {:ended, id, {:error, :failed, DataCa.changed(name, kind)}}

  defp ended_with(installation, id, error, opts),
    do: with_end(error, finish(installation, id, opts))

  # An error after which the session could not be ended says so, and how to end it.
  defp with_end(error, {:ended, _sentence}), do: error
  defp with_end(error, {:not_ended, sentence}), do: Refusal.added(error, " " <> sentence)

  @doc """
  Listens on a local port for the session, with `on_event` called for each event of its tunnels
  (`t:EhosTunnel.Client.event/0`), and writes its password file and data CA in the state
  directory `opts[:state_dir]` names, or `Ehosctl.TokenStore.dir/1`'s. On failure, the session
  is ended.
  """
  @spec listen(t(), (EhosTunnel.Client.event() -> term()), keyword()) :: {:ok, t()} | Api.error()
  def listen(%__MODULE__{} = session, on_event, opts) do
    dir = SessionFiles.dir(Keyword.get_lazy(opts, :state_dir, &Ehosctl.TokenStore.dir/0))
    SessionFiles.sweep(dir, Ehosctl.Clock.current().now())

    case listening(session, on_event) do
      {:ok, listener} ->
        port = Ehosctl.Tunnel.current().port(listener)
        with_files(%{session | listener: listener, port: port}, dir, opts)

      error ->
        closed(session, error, opts)
    end
  end

  # The session as it is now, the listener included, is what a failure here closes.
  defp with_files(session, dir, opts) do
    case SessionFiles.write(dir, files_of(session)) do
      {:ok, files} -> {:ok, %{session | files: files}}
      error -> closed(session, error, opts)
    end
  end

  defp closed(session, error, opts), do: with_end(error, closing(session, opts))

  defp listening(session, on_event) do
    [{:Certificate, ca, :not_encrypted}] = :public_key.pem_decode(session.gateway_ca.certificate)

    case Ehosctl.Tunnel.current().listen(
           url: session.tunnel_url,
           key: session.secrets.key,
           cacerts: [ca],
           on_event: on_event
         ) do
      {:ok, listener} ->
        {:ok, listener}

      {:error, reason} ->
        {:error, :failed,
         "ehosctl cannot listen on the loopback address for the data session " <>
           "(#{:inet.format_error(reason)})."}
    end
  end

  defp files_of(session) do
    %{
      id: session.id,
      expires_at: session.expires_at,
      host: session.database.host,
      port: session.port,
      database: session.database.name,
      user: session.database.user,
      password: session.secrets.password,
      data_ca: session.data_ca.certificate
    }
  end

  @doc """
  Ends what `open/6` and `listen/3` started: closes the listener, which closes each tunnel, ends
  the session at EHOS, and removes its files. Returns the sentence that says how the session
  ended, for stderr.
  """
  @spec close(t(), keyword()) :: String.t()
  def close(%__MODULE__{} = session, opts) do
    {_ended, sentence} = closing(session, opts)
    sentence
  end

  defp closing(session, opts) do
    if session.listener, do: Ehosctl.Tunnel.current().close(session.listener)
    if session.files, do: SessionFiles.remove(session.files)
    finish(session.installation, session.id, opts)
  end

  # `already_ended` is how a session that ended by itself, or at the gateway, answers.
  defp finish(installation, id, opts) do
    case Api.answer(installation, :delete, "/api/v1/sessions/" <> id, nil, opts) do
      {:ok, %{status: 200}} ->
        {:ended, "Ended the data session #{id}."}

      {:ok, %{status: 409, body: %{"error" => "already_ended"}}} ->
        {:ended, "The data session #{id} had already ended."}

      _other ->
        {:not_ended,
         "ehosctl could not end the data session #{id}. Run `ehosctl db end #{id}`. EHOS ends " <>
           "it at its time in any case."}
    end
  end

  @doc """
  The connection to the session's database as `libpq`'s variables: the instance's name as `host`
  and the local port's address as `hostaddr`, so `sslmode=verify-full` checks the name against
  the kept data CA; channel binding and SCRAM required; the password from the password file;
  and the session's timeouts, and its schema as `search_path` when EHOS names one, in
  `PGOPTIONS`. Variables that would change any of this, such as `PGPASSWORD` or `PGSERVICE`,
  are taken out.
  """
  @spec libpq(t()) :: [{String.t(), String.t() | nil}]
  def libpq(%__MODULE__{} = session) do
    [
      {"PGHOST", session.database.host},
      {"PGHOSTADDR", "127.0.0.1"},
      {"PGPORT", Integer.to_string(session.port)},
      {"PGDATABASE", session.database.name},
      {"PGUSER", session.database.user},
      {"PGSSLMODE", "verify-full"},
      {"PGSSLROOTCERT", session.files.root_cert},
      {"PGCHANNELBINDING", "require"},
      {"PGREQUIREAUTH", "scram-sha-256"},
      {"PGPASSFILE", session.files.passfile},
      {"PGOPTIONS", options(session.database)},
      {"PGAPPNAME", "ehosctl db connect"}
    ] ++
      Enum.map(
        ~w(PGPASSWORD PGSERVICE PGSERVICEFILE PGSSLCERT PGSSLKEY PGSSLCRL
                       PGSSLCRLDIR PGSSLNEGOTIATION PGTARGETSESSIONATTRS PGCONNECT_TIMEOUT
                       PGGSSENCMODE PGSSLMINPROTOCOLVERSION),
        &{&1, nil}
      )
  end

  @doc """
  The session's settings as `libpq`'s `options`: its timeouts, and `search_path` when `database`
  names a schema, quoted as an identifier so PostgreSQL keeps its case. A schema that `open/6`
  took has no space or backslash, which libpq's options would split or escape. An EHOS older than
  0.32 names no schema, and the options then leave `search_path` as the role has it.

      iex> Ehosctl.DataSession.options(%{schema: "ehos_ledger_staging"})
      ~s(-c statement_timeout=5min -c lock_timeout=5s -c idle_in_transaction_session_timeout=1min -c search_path="ehos_ledger_staging")

      iex> Ehosctl.DataSession.options(%{schema: nil})
      "-c statement_timeout=5min -c lock_timeout=5s -c idle_in_transaction_session_timeout=1min"
  """
  @spec options(%{schema: String.t() | nil}) :: String.t()
  def options(%{schema: nil}), do: settings(@timeouts)

  def options(%{schema: schema}),
    do: settings(@timeouts ++ [search_path: Postgres.identifier(schema)])

  defp settings(settings),
    do: Enum.map_join(settings, " ", fn {name, value} -> "-c #{name}=#{value}" end)

  @doc """
  `value` as a value of libpq's keyword/value form: in single quotes, with `\\` and `'` escaped,
  so a path with a space or a quote stays one value.

      iex> Ehosctl.DataSession.quoted("/home/grace/Grace's state/a b.crt")
      "'/home/grace/Grace\\\\'s state/a b.crt'"
  """
  @spec quoted(String.t()) :: String.t()
  def quoted(value), do: "'" <> String.replace(value, ["\\", "'"], &("\\" <> &1)) <> "'"

  @doc """
  What a person is told about `event`, one of the session's tunnels' (`t:EhosTunnel.Client.event/0`),
  or `nil` for an event that needs no word: a tunnel that opened, or one whose local connection
  ended.
  """
  @spec said(EhosTunnel.Client.event(), String.t()) :: String.t() | nil
  def said({:open, _tunnel}, _host), do: nil
  def said({:ended, _tunnel}, _host), do: nil

  def said({:refused, _tunnel, %{status: 403}}, _host),
    do:
      "The data gateway refused a connection: the data session does not exist, or it is not " <>
        "the session of this key."

  def said({:refused, _tunnel, %{status: 409, end_reason: reason}}, _host),
    do: "The data gateway refused a connection: #{end_reason(reason)}"

  def said({:refused, _tunnel, %{status: 429}}, _host),
    do:
      "The data gateway refused a connection: the data session has 3 connections open, or " <>
        "the gateway is full. Close a connection, then try again."

  def said({:refused, _tunnel, %{status: 502}}, _host),
    do: "The data gateway cannot reach the database. Try again later."

  def said({:refused, _tunnel, %{status: 503}}, _host),
    do:
      "The data gateway opens no new connection, because EHOS does not answer it now. " <>
        "Connections that are open stay open. Try again later."

  def said({:refused, _tunnel, %{status: status}}, _host),
    do: "The data gateway refused a connection (HTTP #{status})."

  def said({:closed, _tunnel, %{code: 4001, end_reason: reason}}, _host),
    do: "The data gateway closed a connection: #{end_reason(reason)}"

  def said({:closed, _tunnel, %{code: 1001}}, _host),
    do: "The data gateway restarted and closed a connection. Connect again."

  def said({:closed, _tunnel, %{code: code}}, _host),
    do: "The data gateway closed a connection (code #{code})."

  def said({:failed, _tunnel, :timeout}, host),
    do: "The data gateway at #{host} did not answer in time. Try again later."

  def said({:failed, _tunnel, %{__exception__: true} = error}, host),
    do: "ehosctl could not reach the data gateway at #{host}: #{Exception.message(error)}"

  def said({:failed, _tunnel, _reason}, host),
    do:
      "The data gateway at #{host} did not answer as ehosctl expects. Make sure that " <>
        "ehosctl is the latest version."

  def said({:stopped, _reason}, _host),
    do: "ehosctl stopped listening for connections of the data session."

  @doc "Whether `event` says that the session has ended, so no connection can open any more."
  @spec ended?(EhosTunnel.Client.event()) :: boolean()
  def ended?({:refused, _tunnel, %{status: 409}}), do: true
  def ended?({:closed, _tunnel, %{code: 4001}}), do: true
  def ended?({:stopped, _reason}), do: true
  def ended?(_event), do: false

  defp end_reason(:expired), do: "the data session expired. Open a new one."
  defp end_reason(:ended), do: "the data session was ended. Open a new one."

  defp end_reason(:deployment),
    do: "a deployment of the application ended the data session. Open a new one."

  defp end_reason(:revoked),
    do: "you no longer hold a role that gives this data session, so EHOS ended it."

  defp end_reason(reason), do: "the data session ended (#{Refusal.shown(to_string(reason))})."

  @doc "The data gateway's host for `session`, as its messages name it."
  @spec gateway_host(t()) :: String.t()
  def gateway_host(%__MODULE__{tunnel_url: url}), do: URI.parse(url).host
end

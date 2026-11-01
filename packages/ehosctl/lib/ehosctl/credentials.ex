defmodule Ehosctl.Credentials do
  @moduledoc """
  A person's sign-ins to installations of EHOS, and the ten-minute credentials they renew
  (eh-os D-89, T-08).

  `keep/5` keeps what `ehosctl login` obtained, `fetch/3` gives a governed command a credential
  for one audience, renewing under the lock only when none is cached, and `forget/2` forgets a
  sign-in on this machine. Each takes the options a command is handed: `:config_dir`,
  `:state_dir`, `:ca`, the CA kept for the installation (T-14), and `:request_opts` for oidcc.

  Who signed in and until when is kept beside the installation in `config.json` (T-07), under
  `"sign_in"`: `"subject"`, `"email"` when EHOS gave one, `"signed_in_at"` and `"expires_at"`.
  """

  alias Ehosctl.Config
  alias Ehosctl.GitHubActions
  alias Ehosctl.SignIn
  alias Ehosctl.SystemKeychain
  alias Ehosctl.TokenStore

  # D-89's limits, which EHOS does not publish: seven days from the sign-in, three days unrenewed.
  @absolute_seconds 7 * 24 * 3600
  @idle_seconds 3 * 24 * 3600

  # A cached credential is used until this long before it expires, so a command that takes a
  # few seconds still presents one that is valid.
  @margin_seconds 30

  @not_signed_in "You are not signed in. Run `ehosctl login`."

  @type error :: {:error, Ehosctl.Output.kind(), String.t()}

  @doc """
  A credential for `resource` from the sign-in to `installation`: `:ehos` for EHOS's API, or an
  application's address. A cached one is used while it has more than thirty seconds left;
  otherwise the sign-in is renewed, under its lock, and the rotated refresh token kept before the
  credential is.

  A sign-in EHOS has ended (`invalid_grant`) is forgotten, and is an error of kind
  `:not_signed_in`. `opts[:instead_of]` names a credential EHOS has said is expired, as a tail of
  the logs says when it ends with it (eh-os D-97): it is not given again, however long this
  machine's clock says it has left.

  For the address `EHOSCTL_URL` gives, which has no sign-in, the credential is a GitHub Actions
  job's, exchanged from the job's own token (`Ehosctl.GitHubActions`, T-18).
  """
  @spec fetch({Config.name(), Config.installation()}, :ehos | String.t(), keyword()) ::
          {:ok, String.t()} | error()
  def fetch(installation, resource \\ :ehos, opts \\ [])

  # T-18: the address EHOSCTL_URL gives has no sign-in; a GitHub Actions job's token stands for one.
  def fetch({"EHOSCTL_URL", _installation} = named, resource, opts) when is_tuple(named) do
    if Config.from_url?(named),
      do: GitHubActions.credential(named, resource, opts),
      else: signed_in_credential(named, resource, opts)
  end

  def fetch(named, resource, opts), do: signed_in_credential(named, resource, opts)

  defp signed_in_credential({name, installation}, resource, opts) do
    dir = state_dir(opts)
    url = installation["url"]
    resource = if resource == :ehos, do: url, else: resource

    with {:ok, session} <- read_session(dir, name, url),
         nil <- cached(session, resource, opts[:instead_of]) do
      TokenStore.with_lock(dir, name, fn ->
        renew({name, installation}, resource, opts)
      end)
    else
      token when is_binary(token) -> {:ok, token}
      error -> error
    end
  end

  @doc """
  A credential for EHOS's API from the sign-in to `installation` that is cached and has more than
  thirty seconds left, or `nil`: never renewed, so nothing is written and no lock is taken. For
  what may be skipped, as the update notice's look at the installation is.
  """
  @spec cached_credential({Config.name(), Config.installation()}, keyword()) :: String.t() | nil
  def cached_credential({"EHOSCTL_URL", %{"via" => "EHOSCTL_URL"}}, _opts), do: nil

  def cached_credential({name, installation}, opts) do
    url = installation["url"]

    case read_session(state_dir(opts), name, url) do
      {:ok, session} -> cached(session, url)
      _none -> nil
    end
  end

  # Read again under the lock: another command may have renewed while this one waited.
  defp renew({name, installation}, resource, opts) do
    dir = state_dir(opts)
    url = installation["url"]
    key = %{dir: dir, name: name, url: url}

    with {:ok, session} <- read_session(dir, name, url),
         nil <- cached(session, resource, opts[:instead_of]),
         {:ok, _sign_in} <- signed_in(installation),
         {:ok, backend} <- TokenStore.backend(session.store, SystemKeychain.current().backend()),
         {:ok, refresh_token} <- refresh_token(backend, key, name, opts),
         {result, endpoints} <-
           at_endpoints(
             session,
             url,
             opts,
             :token,
             &SignIn.current().renew(&1, refresh_token, resource)
           ) do
      renewed(result, endpoints, backend, key, session, resource, opts)
    else
      token when is_binary(token) -> {:ok, token}
      error -> error
    end
  end

  # Endpoints are kept only from a renewal that worked, so `endpoints` is set there.
  defp renewed({:ok, tokens}, endpoints, backend, key, session, resource, _opts) do
    session = Map.put(session, :endpoints, SignIn.keepable(endpoints))
    rotated(backend, key, session, resource, tokens)
  end

  defp renewed(
         {:error, :not_signed_in, _message} = expired,
         _endpoints,
         _backend,
         key,
         _session,
         _resource,
         opts
       ) do
    with :ok <- forget(key.name, opts), do: expired
  end

  defp renewed(error, _endpoints, _backend, _key, _session, _resource, _opts), do: error

  defp rotated(backend, key, session, resource, tokens) do
    now = DateTime.truncate(Ehosctl.Clock.current().now(), :second)

    case backend.put(key, tokens.refresh_token) do
      :ok ->
        session = %{
          session
          | renewed_at: now,
            credentials:
              Map.put(session.credentials, resource, %{
                token: tokens.credential,
                expires_at: DateTime.add(now, tokens.expires_in)
              })
        }

        with :ok <- TokenStore.write(key.dir, key.name, session), do: {:ok, tokens.credential}

      {:error, message} ->
        {:error, :failed,
         "EHOS renewed your sign-in, and its new token could not be kept (#{message}). " <>
           "Run `ehosctl login`."}
    end
  end

  defp refresh_token(backend, key, name, opts) do
    case backend.get(key) do
      {:ok, token} ->
        {:ok, token}

      :none ->
        with :ok <- forget(name, opts), do: {:error, :not_signed_in, @not_signed_in}

      {:error, message} ->
        {:error, :failed, "cannot read your sign-in: #{message}"}
    end
  end

  @doc """
  Runs `post` at the endpoints of the sign-in to `url`, which posts to the one `endpoint` names,
  and returns what it returned with the endpoints that answered, `nil` when discovery could not
  be read (ehos-tools#76).

  They are the ones `session` kept, when they still pass `Ehosctl.SignIn.kept_endpoints/3`. So a
  renewal is one request, not discovery, the JWKS and the renewal, and EHOS's discovery, its
  issuer included, is checked at `login` and whenever the kept endpoints will not do, rather than
  before every renewal. They will not do when they no longer pass, when the one `post` needs is
  missing, or when it answers that it is not there (404, 405, 410), with a redirect, or that the
  sign-in is over (`invalid_grant`), which an address now serving something else could say.
  Then the endpoints are read from discovery, without the JWKS, and `post` runs once more only if
  discovery names another address for `endpoint`: the same request to the same address twice
  could spend a refresh token twice. Otherwise the first answer stands.
  """
  @spec at_endpoints(
          TokenStore.session() | nil,
          String.t(),
          keyword(),
          :token | :revocation,
          (SignIn.endpoints() -> result)
        ) :: {result | error(), SignIn.endpoints() | nil}
        when result: term()
  def at_endpoints(session, url, opts, endpoint, post) do
    case SignIn.kept_endpoints(url, session && session[:endpoints], opts) do
      {:ok, kept} ->
        result = post.(kept)

        if elsewhere?(result),
          do: at_discovered(url, opts, endpoint, post, {kept, result}),
          else: {result, kept}

      :stale ->
        at_discovered(url, opts, endpoint, post, nil)
    end
  end

  # What a kept endpoint answers that discovery may say otherwise about.
  defp elsewhere?({:error, reason}) when reason in [:moved, :redirected], do: true
  defp elsewhere?({:error, :not_signed_in, _message}), do: true
  defp elsewhere?(_result), do: false

  defp at_discovered(url, opts, endpoint, post, tried) do
    case {SignIn.current().discovered_endpoints(url, opts), tried} do
      {{:ok, endpoints}, {kept, result}} ->
        if same_address?(Map.fetch!(kept, endpoint), Map.fetch!(endpoints, endpoint)),
          do: {settled(result, endpoints, endpoint), endpoints},
          else: {settled(post.(endpoints), endpoints, endpoint), endpoints}

      {{:ok, endpoints}, nil} ->
        {settled(post.(endpoints), endpoints, endpoint), endpoints}

      # A refusal of the sign-in stands when discovery cannot say otherwise: the token is dead
      # there, and posting it again on every command would only ring EHOS's alarms.
      {_error, {_kept, {:error, :not_signed_in, _message} = refused}} ->
        {refused, nil}

      {error, _tried} ->
        {error, nil}
    end
  end

  # One address however it is written: case, a default port, a trailing slash.
  defp same_address?(same, same), do: true

  defp same_address?(one, other) when is_binary(one) and is_binary(other) do
    normal = fn address ->
      case URI.new(address) do
        {:ok, %URI{scheme: scheme, host: host, port: port, path: path, query: query}}
        when is_binary(host) ->
          {String.downcase(scheme || ""), String.downcase(host), port,
           String.trim_trailing(path || "", "/"), query}

        _ ->
          address
      end
    end

    normal.(one) == normal.(other)
  end

  defp same_address?(_one, _other), do: false

  defp settled({:error, reason}, endpoints, endpoint) when reason in [:moved, :redirected],
    do: SignIn.moved(reason, endpoints, endpoint)

  defp settled(result, _endpoints, _endpoint), do: result

  @doc """
  Keeps what `ehosctl login` obtained for the installation `name` at `url`: the refresh token in
  the first store that takes it (`Ehosctl.TokenStore.choose/2`), the credential for EHOS's API in
  the sign-in's file, and who signed in, when and until when in `config.json`, where the
  installation is added or updated and made the current one, and beside it the endpoints `login`
  read (`endpoints`), which later renewals post to, and the CA `opts[:keep_ca]` holds as PEM, or
  none for `nil` (T-14). A sign-in it replaces is forgotten on this machine, and ended at its old
  address trusting the CA kept for that one.

  When the token is kept in a file, stderr is told so, as D-89 asks.
  Returns the `"sign_in"` kept in `config.json`, and until when it holds unrenewed (`until/2`),
  from the `renewed_at` kept with it, as `whoami` reads it.
  """
  @spec keep(Config.name(), String.t(), SignIn.tokens(), SignIn.endpoints(), keyword()) ::
          {:ok, map(), DateTime.t()} | error()
  def keep(name, url, tokens, endpoints, opts) do
    dir = state_dir(opts)
    config_dir = config_dir(opts)
    env = Ehosctl.SystemEnv.current().all()
    key = %{dir: dir, name: name, url: url}
    now = DateTime.truncate(Ehosctl.Clock.current().now(), :second)

    with {:ok, sign_in} <- sign_in(tokens.claims, now),
         {:ok, stores} <- TokenStore.choose(env, SystemKeychain.current().backend()),
         # Read first, so a file this version cannot write back stops the sign-in before anything
         # is kept; `replace/6` reads it again, under its lock.
         {:ok, _config} <- Config.read(config_dir) do
      new = %{tokens: tokens, endpoints: endpoints, sign_in: sign_in, now: now}

      TokenStore.with_lock(dir, name, fn ->
        replace(key, new, stores, env, config_dir, opts)
      end)
      |> case do
        # Ended after the lock is released: the old address may take its time not answering, and
        # a command waiting on the new sign-in need not wait for it.
        {:ok, sign_in, moved, old_opts} ->
          end_moved(moved, old_opts)
          {:ok, sign_in, until(sign_in, %{renewed_at: now})}

        error ->
          error
      end
    end
  end

  # Under the sign-in's lock: what `new` holds takes the place of what was kept under `key`, and
  # `config.json` is changed under its own, which every installation's sign-in shares.
  defp replace(%{dir: dir, name: name, url: url} = key, new, stores, env, config_dir, opts) do
    %{tokens: tokens, endpoints: endpoints, sign_in: sign_in, now: now} = new
    previous = TokenStore.read(dir, name)
    # Read before the new token can take its place, as a file under the same name does.
    moved = moved_from(previous, key)

    with {:ok, store} <- put_first(stores, key, tokens.refresh_token, env),
         :ok <- forget_previous(previous, key, store),
         :ok <-
           TokenStore.write(dir, name, %{
             url: url,
             store: store,
             renewed_at: now,
             credentials: %{
               url => %{
                 token: tokens.credential,
                 expires_at: DateTime.add(now, tokens.expires_in)
               }
             },
             endpoints: SignIn.keepable(endpoints)
           }),
         {:ok, config, _kept} <-
           Config.update(config_dir, &{:ok, signed_in_config(&1, key, sign_in, opts)}) do
      {:ok, sign_in, moved, moved_opts(moved, config, name, opts)}
    end
  end

  defp signed_in_config(config, %{name: name, url: url}, sign_in, opts) do
    config =
      config
      |> Config.put(name, url)
      |> Config.put_sign_in(name, sign_in)
      |> kept_ca(name, opts)

    %{config | current: name}
  end

  # For the revocation at the old address: the CA kept for it, which `put` drops with its URL, and
  # only while `config.json` still has the installation there; one kept for another URL is not.
  defp moved_opts({%{url: old_url}, _token}, config, name, opts) do
    case config.installations[name] do
      %{"url" => ^old_url} = installation -> Config.trusting(opts, {name, installation})
      _other -> Keyword.delete(opts, :ca)
    end
  end

  defp moved_opts(nil, _config, _name, opts), do: opts

  # The CA `opts[:keep_ca]` holds, or none when it is `nil`; a caller that does not name it leaves
  # the installation's as it is.
  defp kept_ca(config, name, opts) do
    case Keyword.fetch(opts, :keep_ca) do
      {:ok, pem} -> Config.put_ca(config, name, pem)
      :error -> config
    end
  end

  # A sign-in to the installation's old address, which this one replaces: its URL and token, to
  # end at EHOS there once this one is kept. Nothing else ever could: every later command talks
  # to the new address.
  defp moved_from({:ok, %{url: old_url} = previous}, key) when old_url != key.url do
    with {:ok, backend} <- TokenStore.backend(previous.store, SystemKeychain.current().backend()),
         {:ok, token} <- backend.get(%{key | url: old_url}) do
      {previous, token}
    else
      _none -> nil
    end
  end

  defp moved_from(_previous, _key), do: nil

  defp end_moved(nil, _opts), do: :ok

  defp end_moved({%{url: old_url} = previous, token}, opts) do
    case at_endpoints(previous, old_url, opts, :revocation, &SignIn.current().revoke(&1, token)) do
      {:ok, _endpoints} -> :ok
      {{:error, _kind, message}, _endpoints} -> end_moved_warning(old_url, message)
    end
  end

  defp end_moved_warning(old_url, message) do
    IO.puts(
      :stderr,
      "ehosctl: the sign-in to #{old_url}, which this one replaces, was not ended there " <>
        "(#{message}); it ends by itself, at the latest three days from its last use."
    )
  end

  # The token a sign-in it replaces kept somewhere the new one did not overwrite: in another
  # store, or in the keychain under another URL. A file is named by the installation alone, so
  # the new token has already taken its place.
  defp forget_previous({:ok, previous}, key, store)
       when previous.store != store or (store == :keychain and previous.url != key.url) do
    with {:ok, backend} <- TokenStore.backend(previous.store, SystemKeychain.current().backend()) do
      case backend.delete(%{key | url: previous.url}) do
        :ok ->
          :ok

        {:error, message} ->
          {:error, :failed, "cannot forget the sign-in this one replaces: #{message}"}
      end
    end
  end

  defp forget_previous(_previous, _key, _store), do: :ok

  # The first store that keeps it. A file is said aloud, with why: D-89 asks for a warning, and
  # a keychain that refused is worth knowing about.
  defp put_first(stores, key, secret, env) do
    file = TokenStore.File.path(key)

    Enum.reduce_while(stores, nil, fn {kind, backend}, refused ->
      case backend.put(key, secret) do
        :ok ->
          warn_if_file(kind, env, refused, file)
          {:halt, {:ok, kind}}

        {:error, message} ->
          {:cont, {:error, :failed, "cannot keep your sign-in: #{message}"}}
      end
    end)
  end

  defp warn_if_file(:file, env, refused, file),
    do: IO.puts(:stderr, "ehosctl: " <> file_warning(env, refused, file))

  defp warn_if_file(_kind, _env, _refused, _file), do: nil

  defp file_warning(%{"EHOSCTL_TOKEN_STORE" => "file"}, nil, file),
    do: "your sign-in is kept in #{file}, which only you can read (EHOSCTL_TOKEN_STORE=file)."

  defp file_warning(_env, nil, file),
    do:
      "no system keychain was found, so your sign-in is kept in #{file}, which only you can read."

  defp file_warning(_env, {:error, _kind, message}, file),
    do: "#{message}, so it is kept in #{file}, which only you can read."

  @doc """
  Forgets the sign-in to the installation `name` on this machine: its refresh token, its file
  and its `"sign_in"` in `config.json`. It does not tell EHOS; `ehosctl logout` does, first.
  """
  @spec forget(Config.name(), keyword()) :: :ok | error()
  def forget(name, opts) do
    config_dir = config_dir(opts)

    with :ok <- forget_session(state_dir(opts), name),
         do: signed_out_in(config_dir, name)
  end

  # An installation `config.json` does not hold is left without a lock, so forgetting one, as
  # EHOSCTL_URL's, creates no directory. One it holds, or a file that could not be read, which a
  # write through a link may leave half written for a moment (`Ehosctl.Config.write/2`), is read
  # again under the lock.
  defp signed_out_in(config_dir, name) do
    case Config.read(config_dir) do
      {:ok, %Config{installations: installations}} when not is_map_key(installations, name) ->
        :ok

      _held_or_unread ->
        signed_out_under_lock(config_dir, name)
    end
  end

  defp signed_out_under_lock(config_dir, name) do
    with {:ok, _read, _written} <- Config.update(config_dir, &{:ok, signed_out(&1, name)}),
         do: :ok
  end

  # Read again under the lock, where another command may have removed it.
  defp signed_out(config, name) do
    if Map.has_key?(config.installations, name),
      do: Config.put_sign_in(config, name, nil),
      else: config
  end

  defp forget_session(dir, name) do
    case TokenStore.read(dir, name) do
      {:ok, session} ->
        TokenStore.forget(dir, name, session, SystemKeychain.current().backend())

      :none ->
        :ok

      # A file this version cannot read is forgotten all the same: it was a sign-in.
      {:error, _kind, _message} ->
        TokenStore.File.delete(%{dir: dir, name: name}) |> forgotten(dir, name)
    end
  end

  defp forgotten(:ok, dir, name) do
    case File.rm(TokenStore.path(dir, name, "json")) do
      result when result in [:ok, {:error, :enoent}] ->
        :ok

      {:error, reason} ->
        {:error, :failed, "cannot remove a sign-in: #{:file.format_error(reason)}"}
    end
  end

  defp forgotten({:error, message}, _dir, _name), do: {:error, :failed, message}

  @doc """
  Until when the sign-in lasts, as far as `ehosctl` knows: seven days from when the person signed
  in, or three days after the last renewal, whichever is first (eh-os D-89).
  """
  @spec until(map(), %{required(:renewed_at) => DateTime.t(), optional(atom()) => term()}) ::
          DateTime.t()
  def until(%{"expires_at" => expires_at}, session) do
    {:ok, absolute, _offset} = DateTime.from_iso8601(expires_at)
    Enum.min([absolute, DateTime.add(session.renewed_at, @idle_seconds)], DateTime)
  end

  @doc """
  The `"sign_in"` of the installation, when it is one `ehosctl` wrote and can show: a subject, an
  email if any, and the two times.
  """
  @spec signed_in(Config.installation()) :: {:ok, map()} | error()
  def signed_in(installation) do
    with %{"subject" => subject, "signed_in_at" => at, "expires_at" => until} = sign_in
         when is_binary(subject) and is_binary(at) and is_binary(until) <-
           installation["sign_in"],
         true <- Ehosctl.Output.printable?(subject),
         true <- is_nil(sign_in["email"]) or Ehosctl.Output.printable?(sign_in["email"]),
         {:ok, _, _} <- DateTime.from_iso8601(at),
         {:ok, _, _} <- DateTime.from_iso8601(until) do
      {:ok, sign_in}
    else
      _ -> {:error, :not_signed_in, @not_signed_in}
    end
  end

  # What `config.json` keeps of the ID token's claims: who, and from when EHOS's limits run.
  defp sign_in(%{"sub" => subject} = claims, now) when is_binary(subject) do
    signed_in_at =
      case claims["auth_time"] do
        time when is_integer(time) -> DateTime.from_unix(time)
        _none -> {:ok, now}
      end

    email = claims["email"]

    with {:ok, signed_in_at} <- signed_in_at,
         true <-
           Ehosctl.Output.printable?(subject) and
             (is_nil(email) or (is_binary(email) and Ehosctl.Output.printable?(email))) do
      {:ok,
       %{
         "subject" => subject,
         "signed_in_at" => DateTime.to_iso8601(signed_in_at),
         "expires_at" => signed_in_at |> DateTime.add(@absolute_seconds) |> DateTime.to_iso8601()
       }
       |> then(&if email, do: Map.put(&1, "email", email), else: &1)}
    else
      {:error, _reason} ->
        {:error, :failed, "EHOS's ID token says you signed in at no time there is"}

      false ->
        {:error, :failed, "EHOS named you with characters ehosctl does not print"}
    end
  end

  defp sign_in(_claims, _now), do: {:error, :failed, "EHOS's ID token names nobody"}

  @doc """
  The sign-in to the installation `name` at `url` kept in the state directory of `opts`: an error
  of kind `:not_signed_in` when there is none, or it is to another address.
  """
  @spec session(Config.name(), String.t(), keyword()) :: {:ok, TokenStore.session()} | error()
  def session(name, url, opts), do: read_session(state_dir(opts), name, url)

  defp read_session(dir, name, url) do
    case TokenStore.read(dir, name) do
      {:ok, %{url: ^url} = session} -> {:ok, session}
      {:ok, _another_url} -> {:error, :not_signed_in, @not_signed_in}
      :none -> {:error, :not_signed_in, @not_signed_in}
      error -> error
    end
  end

  defp cached(session, resource, instead_of \\ nil) do
    case session.credentials[resource] do
      %{token: ^instead_of} ->
        nil

      %{token: token, expires_at: expires_at} ->
        if DateTime.diff(expires_at, Ehosctl.Clock.current().now()) > @margin_seconds, do: token

      nil ->
        nil
    end
  end

  @doc "The state directory `opts` name, else `Ehosctl.TokenStore.dir/1`'s."
  @spec state_dir(keyword()) :: Path.t()
  def state_dir(opts),
    do:
      Keyword.get_lazy(opts, :state_dir, fn ->
        TokenStore.dir(Ehosctl.SystemEnv.current().all())
      end)

  defp config_dir(opts),
    do:
      Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(Ehosctl.SystemEnv.current().all()) end)
end

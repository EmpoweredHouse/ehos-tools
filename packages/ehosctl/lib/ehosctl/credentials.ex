defmodule Ehosctl.Credentials do
  @moduledoc """
  A person's sign-ins to installations of EHOS, and the ten-minute credentials they renew
  (eh-os D-89, T-08).

  `keep/5` keeps what `ehosctl login` obtained, `fetch/3` gives a governed command a credential
  for one audience, renewing under the lock only when none is cached, and `forget/2` forgets a
  sign-in on this machine. Each takes the options a command is handed: `:config_dir`,
  `:state_dir`, `:keychain` (the backend for the system's keychain, `nil` for none), `:env`, and
  `:request_opts` for oidcc.

  Who signed in and until when is kept beside the installation in `config.json` (T-07), under
  `"sign_in"`: `"subject"`, `"email"` when EHOS gave one, `"signed_in_at"` and `"expires_at"`.
  """

  alias Ehosctl.Config
  alias Ehosctl.SignIn
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
  `:not_signed_in`.
  """
  @spec fetch({Config.name(), Config.installation()}, :ehos | String.t(), keyword()) ::
          {:ok, String.t()} | error()
  def fetch({name, installation}, resource \\ :ehos, opts \\ []) do
    dir = state_dir(opts)
    url = installation["url"]
    resource = if resource == :ehos, do: url, else: resource

    with {:ok, session} <- read_session(dir, name, url),
         nil <- cached(session, resource) do
      TokenStore.with_lock(dir, name, fn ->
        renew({name, installation}, resource, opts)
      end)
    else
      token when is_binary(token) -> {:ok, token}
      error -> error
    end
  end

  # Read again under the lock: another command may have renewed while this one waited.
  defp renew({name, installation}, resource, opts) do
    dir = state_dir(opts)
    url = installation["url"]
    key = %{dir: dir, name: name, url: url}

    with {:ok, session} <- read_session(dir, name, url),
         nil <- cached(session, resource),
         {:ok, _sign_in} <- signed_in(installation),
         {:ok, backend} <- TokenStore.backend(session.store, keychain(opts)),
         {:ok, refresh_token} <- refresh_token(backend, key, name, opts),
         {result, endpoints} <-
           at_endpoints(session, url, opts, :token, &SignIn.renew(&1, refresh_token, resource)) do
      case result do
        {:ok, tokens} ->
          session = Map.put(session, :endpoints, SignIn.keepable(endpoints))
          rotated(backend, key, session, resource, tokens)

        {:error, :not_signed_in, _message} = expired ->
          with :ok <- forget(name, opts), do: expired

        error ->
          error
      end
    else
      token when is_binary(token) -> {:ok, token}
      error -> error
    end
  end

  defp rotated(backend, key, session, resource, tokens) do
    now = DateTime.utc_now(:second)

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
  and returns what it returned with the endpoints that answered (#76). They are the ones `session` kept, when they still pass
  `Ehosctl.SignIn.kept_endpoints/3`; otherwise, or when the one `post` needs is missing or
  answers that it is not there (`{:error, :moved}`, which spent nothing), they are read from
  discovery now, and `post` runs once more if discovery names another `endpoint`. So a renewal is
  one request, not discovery, the JWKS and the renewal.

  An error reading discovery is returned as it is.
  """
  @spec at_endpoints(
          TokenStore.session() | nil,
          String.t(),
          keyword(),
          :token | :revocation,
          (SignIn.endpoints() -> result)
        ) :: {result, SignIn.endpoints()} | error()
        when result: term()
  def at_endpoints(session, url, opts, endpoint, post) do
    case SignIn.kept_endpoints(url, session && session[:endpoints], opts) do
      {:ok, kept} ->
        case post.(kept) do
          {:error, :moved} -> at_discovered(url, opts, endpoint, post, kept)
          result -> {result, kept}
        end

      :stale ->
        at_discovered(url, opts, endpoint, post, nil)
    end
  end

  # Posted again only to endpoints discovery names otherwise than the ones that answered: the
  # same request to the same address twice could spend a refresh token twice, were the answer
  # that it is not there not EHOS's own.
  defp at_discovered(url, opts, endpoint, post, kept) do
    with {:ok, provider} <- SignIn.provider(url, opts) do
      endpoints = SignIn.endpoints(provider)

      result =
        if kept && Map.fetch!(kept, endpoint) == Map.fetch!(endpoints, endpoint),
          do: {:error, :moved},
          else: post.(endpoints)

      case result do
        {:error, :moved} ->
          {{:error, :failed, "#{url} names no endpoint for this, or one that is not there"},
           endpoints}

        result ->
          {result, endpoints}
      end
    end
  end

  @doc """
  Keeps what `ehosctl login` obtained for the installation `name` at `url`: the refresh token in
  the first store that takes it (`Ehosctl.TokenStore.choose/2`), the credential for EHOS's API in
  the sign-in's file, and who signed in, when and until when in `config.json`, where the
  installation is added or updated and made the current one, and beside it the endpoints `login`
  read (`endpoints`), which later renewals post to. A sign-in it replaces is forgotten on this
  machine.

  When the token is kept in a file, `opts[:warn]` is told so (stderr by default), as D-89 asks.
  Returns the `"sign_in"` kept in `config.json`.
  """
  @spec keep(Config.name(), String.t(), SignIn.tokens(), SignIn.endpoints(), keyword()) ::
          {:ok, map()} | error()
  def keep(name, url, tokens, endpoints, opts) do
    dir = state_dir(opts)
    config_dir = config_dir(opts)
    env = env(opts)
    key = %{dir: dir, name: name, url: url}
    now = DateTime.utc_now(:second)

    with {:ok, sign_in} <- sign_in(tokens.claims, now),
         {:ok, stores} <- TokenStore.choose(env, keychain(opts)),
         {:ok, config} <- Config.read(config_dir) do
      TokenStore.with_lock(dir, name, fn ->
        previous = TokenStore.read(dir, name)
        # Read before the new token can take its place, as a file under the same name does.
        moved = moved_from(previous, key, opts)

        with {:ok, store} <- put_first(stores, key, tokens.refresh_token, env, opts),
             :ok <- forget_previous(previous, key, store, opts),
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
             config = config |> Config.put(name, url) |> Config.put_sign_in(name, sign_in),
             :ok <- Config.write(%{config | current: name}, config_dir) do
          {:ok, sign_in, moved}
        end
      end)
      |> case do
        # Ended after the lock is released: the old address may take its time not answering, and
        # a command waiting on the new sign-in need not wait for it.
        {:ok, sign_in, moved} ->
          end_moved(moved, opts)
          {:ok, sign_in}

        error ->
          error
      end
    end
  end

  # A sign-in to the installation's old address, which this one replaces: its URL and token, to
  # end at EHOS there once this one is kept. Nothing else ever could: every later command talks
  # to the new address.
  defp moved_from({:ok, %{url: old_url} = previous}, key, opts) when old_url != key.url do
    with {:ok, backend} <- TokenStore.backend(previous.store, keychain(opts)),
         {:ok, token} <- backend.get(%{key | url: old_url}) do
      {previous, token}
    else
      _none -> nil
    end
  end

  defp moved_from(_previous, _key, _opts), do: nil

  defp end_moved(nil, _opts), do: :ok

  defp end_moved({%{url: old_url} = previous, token}, opts) do
    warn = Keyword.get(opts, :warn, &IO.puts(:stderr, &1))

    case at_endpoints(previous, old_url, opts, :revocation, &SignIn.revoke(&1, token)) do
      {:ok, _endpoints} ->
        :ok

      {{:error, _kind, message}, _endpoints} ->
        end_moved_warning(warn, old_url, message)

      {:error, _kind, message} ->
        end_moved_warning(warn, old_url, message)
    end
  end

  defp end_moved_warning(warn, old_url, message) do
    warn.(
      "ehosctl: the sign-in to #{old_url}, which this one replaces, was not ended there " <>
        "(#{message}); it ends by itself, at the latest three days from its last use."
    )
  end

  # The token a sign-in it replaces kept somewhere the new one did not overwrite: in another
  # store, or in the keychain under another URL. A file is named by the installation alone, so
  # the new token has already taken its place.
  defp forget_previous({:ok, previous}, key, store, opts)
       when previous.store != store or (store == :keychain and previous.url != key.url) do
    with {:ok, backend} <- TokenStore.backend(previous.store, keychain(opts)) do
      case backend.delete(%{key | url: previous.url}) do
        :ok ->
          :ok

        {:error, message} ->
          {:error, :failed, "cannot forget the sign-in this one replaces: #{message}"}
      end
    end
  end

  defp forget_previous(_previous, _key, _store, _opts), do: :ok

  # The first store that keeps it. A file is said aloud, with why: D-89 asks for a warning, and
  # a keychain that refused is worth knowing about.
  defp put_first(stores, key, secret, env, opts) do
    warn = Keyword.get(opts, :warn, &IO.puts(:stderr, &1))
    file = TokenStore.File.path(key)

    Enum.reduce_while(stores, nil, fn {kind, backend}, refused ->
      case backend.put(key, secret) do
        :ok ->
          if kind == :file, do: warn.("ehosctl: " <> file_warning(env, refused, file))
          {:halt, {:ok, kind}}

        {:error, message} ->
          {:cont, {:error, :failed, "cannot keep your sign-in: #{message}"}}
      end
    end)
  end

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

    with :ok <- forget_session(state_dir(opts), name, opts),
         {:ok, config} <- Config.read(config_dir) do
      if Map.has_key?(config.installations, name),
        do: Config.write(Config.put_sign_in(config, name, nil), config_dir),
        else: :ok
    end
  end

  defp forget_session(dir, name, opts) do
    case TokenStore.read(dir, name) do
      {:ok, session} ->
        TokenStore.forget(dir, name, session, keychain(opts))

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
  @spec until(map(), %{renewed_at: DateTime.t()}) :: DateTime.t()
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

  defp cached(session, resource) do
    case session.credentials[resource] do
      %{token: token, expires_at: expires_at} ->
        if DateTime.diff(expires_at, DateTime.utc_now()) > @margin_seconds, do: token

      nil ->
        nil
    end
  end

  @doc "The state directory `opts` name, else `Ehosctl.TokenStore.dir/1`'s."
  @spec state_dir(keyword()) :: Path.t()
  def state_dir(opts),
    do: Keyword.get_lazy(opts, :state_dir, fn -> TokenStore.dir(env(opts)) end)

  @doc "The keychain backend `opts` name, else the system's (`Ehosctl.TokenStore.keychain/0`)."
  @spec keychain(keyword()) :: module() | nil
  def keychain(opts), do: Keyword.get_lazy(opts, :keychain, &TokenStore.keychain/0)

  defp config_dir(opts), do: Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env(opts)) end)
  defp env(opts), do: Keyword.get_lazy(opts, :env, &System.get_env/0)
end

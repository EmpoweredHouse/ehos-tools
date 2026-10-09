defmodule Ehosctl.SignIn do
  @moduledoc """
  The terminal's side of signing in to EHOS (eh-os D-89), over oidcc (T-09).

  `ehosctl` is EHOS's public client `ehosctl`: it proves nothing but the PKCE verifier it kept.

    * **Discovery** reads `/.well-known/openid-configuration` at the installation's URL, which
      must be its issuer, and the JWKS it names (`provider/2`).
    * **Authorization** sends the browser to EHOS with the code flow, PKCE `S256`, a `state` and
      a `nonce`, scope `openid email`, `max_age=0` so EHOS asks for the password, no `prompt` and
      no `resource` (`authorization/2`). The browser comes back to
      `http://127.0.0.1:<port>/callback` (`Ehosctl.SignIn.Loopback`), where `state` and `iss`
      (RFC 9207) are checked (`callback/3`).
    * **The exchange** gives a credential for EHOS's API, a refresh token and an ID token, whose
      signature, issuer, audience and `nonce` oidcc checks (`exchange/3`).
    * **Renewal** names a `resource` (RFC 8707), and returns one credential and the refresh token
      that replaces the one spent (`renew/3`). It is posted to the token endpoint the sign-in
      kept (`kept_endpoints/3`), without reading discovery or the JWKS again.
    * **Revocation** ends the sign-in at EHOS (RFC 7009), which oidcc does not do (`revoke/2`).

  Errors are of the kinds `Ehosctl.Output` gives exit codes to, in the words of eh-os's
  `docs/refusals.md`.
  """

  @client_id "ehosctl"
  @scopes [:openid, :email]

  # How long `ehosctl` waits for EHOS to answer one request.
  @timeout_ms 30_000

  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @typedoc "An installation's provider, as discovery and its JWKS describe it."
  @type provider :: %{issuer: String.t(), context: Oidcc.ClientContext.t(), opts: map()}

  @typedoc """
  The two endpoints a renewal and a revocation are posted to, with the options they are posted
  with: from a provider just read (`endpoints/1`), or as a sign-in kept them (`kept_endpoints/3`).
  """
  @type endpoints :: %{
          issuer: String.t(),
          token: String.t(),
          revocation: String.t() | nil,
          request_opts: map()
        }

  @typedoc "What one authorization request keeps to check its callback and redeem its code."
  @type request :: %{
          state: String.t(),
          nonce: String.t(),
          verifier: String.t(),
          redirect_uri: String.t()
        }

  @typedoc """
  What the token endpoint gave: a credential, how many seconds it lives, the refresh token that
  replaces the one spent, and the ID token's claims.
  """
  @type tokens :: %{
          credential: String.t(),
          expires_in: pos_integer(),
          refresh_token: String.t(),
          claims: map()
        }

  @type error :: {:error, Ehosctl.Output.kind(), String.t()}

  @expired "Your sign-in has expired. Run `ehosctl login`."

  # What an endpoint that is no longer there answers, before it spends anything.
  @moved [404, 405, 410]

  @doc "The client EHOS knows the terminal as."
  @spec client_id() :: String.t()
  def client_id, do: @client_id

  @doc """
  The installation's address as `ehosctl` keeps it: an `https` origin. A path, a query, a
  fragment or user information is refused, and so is a character a terminal would act on. EHOS
  signs no one in over plain HTTP, so `ehosctl` does not either; `allow_http: true` is for the
  tests' fake EHOS alone.

      iex> Ehosctl.SignIn.origin("https://EHOS.example.com/")
      {:ok, "https://ehos.example.com"}

      iex> {:error, :invalid, _} = Ehosctl.SignIn.origin("http://localhost:4000")
  """
  @spec origin(String.t(), keyword()) :: {:ok, String.t()} | error()
  def origin(url, opts \\ []) do
    schemes = if opts[:allow_http], do: ["https", "http"], else: ["https"]

    with true <- Ehosctl.Output.printable?(url) and not String.contains?(url, [" ", "\""]),
         {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(host) and host != "" <-
           URI.new(url),
         true <- scheme in ["https", "http"] and is_nil(uri.userinfo),
         true <- uri.path in [nil, "", "/"] and is_nil(uri.query) and is_nil(uri.fragment) do
      if scheme in schemes,
        do:
          {:ok, URI.to_string(%URI{scheme: scheme, host: String.downcase(host), port: uri.port})},
        else: {:error, :invalid, "#{url} is plain HTTP; EHOS signs people in over https only"}
    else
      _ ->
        {:error, :invalid,
         "#{inspect(url)} is not an installation's address, such as https://ehos.example.com"}
    end
  end

  @doc """
  Whether `host` is this machine's: `localhost`, a name under `.localhost`, `127.0.0.1` or `::1`.
  """
  @spec loopback?(String.t()) :: boolean()
  def loopback?(host),
    do: host in @loopback_hosts or String.ends_with?(host, ".localhost") or host == "[::1]"

  @doc """
  Reads the provider at the installation's URL `issuer`: its discovery document, which must name
  `issuer` as its own, and its JWKS. `opts` may name `:env`, read for `EHOSCTL_CA_FILE`
  (`request_opts/2`).

  The issuer is checked again by `origin/2`, since it may come from `config.json`, and every
  endpoint `ehosctl` uses must be `https` on the issuer's own host: the code, the PKCE verifier
  and the refresh token are sent there, and the person's browser is sent to the authorization
  endpoint.
  """
  @spec provider(String.t(), keyword()) :: {:ok, provider()} | error()
  def provider(issuer, opts \\ []) do
    with {:ok, configuration, load} <- discover(issuer, opts),
         {:ok, {jwks, _expiry}} <-
           discovered(Oidcc.ProviderConfiguration.load_jwks(configuration.jwks_uri, load), issuer) do
      context = Oidcc.ClientContext.from_manual(configuration, jwks, @client_id, :unauthenticated)
      {:ok, %{issuer: issuer, context: context, opts: %{request_opts: load.request_opts}}}
    end
  end

  @doc """
  The token and revocation endpoints of the provider at `issuer`, from its discovery document
  alone, checked as `provider/2` checks them: what a renewal or a revocation needs when the ones
  a sign-in kept will not do. The JWKS is not read, which neither needs.
  """
  @spec discovered_endpoints(String.t(), keyword()) :: {:ok, endpoints()} | error()
  def discovered_endpoints(issuer, opts \\ []) do
    with {:ok, configuration, load} <- discover(issuer, opts) do
      {:ok, endpoints_of(configuration, issuer, load.request_opts)}
    end
  end

  defp discover(issuer, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    allow_http = Keyword.get(opts, :allow_http, false)

    with {:ok, ^issuer} <- stored(origin(issuer, allow_http: allow_http), issuer),
         {:ok, request_opts} <- request_opts(issuer, env) do
      load = %{request_opts: request_opts, quirks: %{allow_unsafe_http: allow_http}}

      with {:ok, {configuration, _expiry}} <-
             discovered(Oidcc.ProviderConfiguration.load_configuration(issuer, load), issuer),
           :ok <- endpoints(configuration, issuer) do
        {:ok, configuration, load}
      end
    end
  end

  # An address from config.json that is not an origin `login` would keep, as it is.
  defp stored({:ok, issuer}, issuer), do: {:ok, issuer}

  defp stored({:error, _kind, message}, _issuer),
    do: {:error, :invalid, message <> "; sign in with its https address: ehosctl login URL"}

  defp stored({:ok, _other}, issuer),
    do:
      {:error, :invalid,
       "#{inspect(issuer)} is not an installation's address as ehosctl keeps it; " <>
         "sign in with it again: ehosctl login URL"}

  defp endpoints(configuration, issuer) do
    required = [
      configuration.authorization_endpoint,
      configuration.token_endpoint,
      configuration.jwks_uri
    ]

    # The revocation endpoint may be missing, which `revoke/2` says; not elsewhere.
    revocation = configuration.revocation_endpoint

    if Enum.all?(required, &on_issuer?(&1, issuer)) and
         (revocation == :undefined or on_issuer?(revocation, issuer)),
       do: :ok,
       else:
         {:error, :failed,
          "#{issuer} names an endpoint that is not https on #{issuer} itself; " <>
            "ehosctl does not sign in there"}
  end

  # On the issuer's own scheme, host and port, parsed strictly, and with no user information or
  # backslash, which a browser reads otherwise than URI does: `https://evil.example\\@ehos.example.com`
  # is evil.example to a browser.
  defp on_issuer?(endpoint, issuer) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(issuer)

    is_binary(endpoint) and Ehosctl.Output.printable?(endpoint) and
      not String.contains?(endpoint, "\\") and
      match?(
        {:ok, %URI{scheme: ^scheme, host: ^host, port: ^port, userinfo: nil}},
        URI.new(endpoint)
      )
  end

  @doc """
  The token and revocation endpoints of `provider`, read just now and checked by `provider/2`.
  """
  @spec endpoints(provider()) :: endpoints()
  def endpoints(provider) do
    endpoints_of(
      provider.context.provider_configuration,
      provider.issuer,
      provider.opts.request_opts
    )
  end

  defp endpoints_of(configuration, issuer, request_opts) do
    %{
      issuer: issuer,
      token: configuration.token_endpoint,
      revocation:
        if(is_binary(configuration.revocation_endpoint),
          do: configuration.revocation_endpoint
        ),
      request_opts: request_opts
    }
  end

  @doc """
  The endpoints a sign-in kept (`"token"` and `"revocation"`, as `keepable/1` gives them), checked
  again as discovery's are: `:stale` when they no longer pass, which sends `ehosctl` back to
  discovery. `opts` are `provider/2`'s.
  """
  @spec kept_endpoints(String.t(), map() | nil, keyword()) :: {:ok, endpoints()} | :stale
  def kept_endpoints(issuer, %{"token" => token} = kept, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    revocation = kept["revocation"]

    with {:ok, ^issuer} <- origin(issuer, allow_http: Keyword.get(opts, :allow_http, false)),
         true <- on_issuer?(token, issuer),
         true <- is_nil(revocation) or on_issuer?(revocation, issuer),
         {:ok, request_opts} <- request_opts(issuer, env) do
      {:ok, %{issuer: issuer, token: token, revocation: revocation, request_opts: request_opts}}
    else
      _ -> :stale
    end
  end

  def kept_endpoints(_issuer, _kept, _opts), do: :stale

  @doc "The endpoints as a sign-in keeps them, in `<name>.json`."
  @spec keepable(endpoints()) :: %{String.t() => String.t() | nil}
  def keepable(endpoints), do: %{"token" => endpoints.token, "revocation" => endpoints.revocation}

  @doc """
  The options every request to EHOS is made with: a timeout, and for `https` hostname checking
  and the system's CA certificates, rather than `httpc`'s defaults.

  `EHOSCTL_CA_FILE` in `env` names a PEM file of CA certificates trusted besides the system's, as
  `curl --cacert` names one: a local EHOS's, such as the k3d cluster's `_build/k3d/ca.crt`.
  """
  @spec request_opts(String.t(), %{String.t() => String.t()}) :: {:ok, map()} | error()
  def request_opts(issuer, env) do
    with {:ok, extra} <- ca_file(env["EHOSCTL_CA_FILE"]) do
      case URI.parse(issuer).scheme do
        "https" ->
          # A handshake that fails is said once, in ehosctl's words, rather than also in the
          # notices :ssl logs.
          ssl =
            :httpc.ssl_verify_host_options(true)
            |> Keyword.update(:cacerts, extra, &(&1 ++ extra))
            |> Keyword.put(:log_level, :none)

          {:ok, %{timeout: @timeout_ms, ssl: ssl}}

        _http ->
          {:ok, %{timeout: @timeout_ms}}
      end
    end
  end

  defp ca_file(empty) when empty in [nil, ""], do: {:ok, []}

  defp ca_file(file) do
    with {:ok, pem} <- File.read(file),
         [_ | _] = certificates <-
           for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      {:ok, certificates}
    else
      {:error, reason} ->
        {:error, :failed, "cannot read EHOSCTL_CA_FILE, #{file}: #{:file.format_error(reason)}"}

      [] ->
        {:error, :failed, "EHOSCTL_CA_FILE, #{file}, holds no PEM certificate"}
    end
  end

  @doc """
  The URL to send the browser to, and what the request keeps to check its callback: a new
  `state`, `nonce` and PKCE verifier, and `redirect_uri`.
  """
  @spec authorization(provider(), String.t()) :: {:ok, String.t(), request()} | error()
  def authorization(provider, redirect_uri) do
    request = %{
      state: random(),
      nonce: random(),
      verifier: random(),
      redirect_uri: redirect_uri
    }

    case Oidcc.Authorization.create_redirect_url(provider.context, %{
           redirect_uri: redirect_uri,
           scopes: @scopes,
           state: request.state,
           nonce: request.nonce,
           pkce_verifier: request.verifier,
           require_pkce: true,
           url_extension: [{"max_age", "0"}]
         }) do
      {:ok, url} ->
        {:ok, IO.iodata_to_binary(url), request}

      {:error, reason} ->
        {:error, :failed, "#{provider.issuer} cannot sign ehosctl in: #{why(reason)}"}
    end
  end

  @doc """
  Reads the query the browser came back with: `{:ok, code}`, an error EHOS sent back, or
  `:ignore` for a `state` that is not this request's, which is not this sign-in's answer.

  The response must name the issuer as `iss` (RFC 9207), as EHOS's discovery says it does: a
  code from another provider is never sent to this one.
  """
  @spec callback(%{String.t() => String.t()}, request(), String.t()) ::
          {:ok, String.t()} | :ignore | error()
  def callback(params, request, issuer) do
    cond do
      not same?(params["state"], request.state) ->
        :ignore

      params["iss"] != issuer ->
        {:error, :failed, "the answer to this sign-in did not come from #{issuer}"}

      is_binary(params["error"]) ->
        {:error, :refused, "EHOS did not sign you in (#{printable(params["error"])})"}

      is_binary(params["code"]) and params["code"] != "" ->
        {:ok, params["code"]}

      true ->
        {:error, :failed, "#{issuer} sent the browser back without a code"}
    end
  end

  @doc "Redeems the code of `request` at the token endpoint, with no client authentication."
  @spec exchange(provider(), String.t(), request()) :: {:ok, tokens()} | error()
  def exchange(provider, code, request) do
    provider.context
    |> then(
      &Oidcc.Token.retrieve(code, &1, %{
        redirect_uri: request.redirect_uri,
        pkce_verifier: request.verifier,
        require_pkce: true,
        nonce: request.nonce,
        preferred_auth_methods: [:none],
        request_opts: provider.opts.request_opts
      })
    )
    |> tokens(provider.issuer)
  end

  @doc """
  Renews the sign-in with `refresh_token`, for the credential of `resource`: EHOS's issuer for its
  API, or an application's address.

  The request is posted by `ehosctl` itself, not oidcc: EHOS has rotated the refresh token by the
  time it answers, so an answer is taken whenever it carries a credential and the refresh token
  that replaces the one spent. oidcc would refuse it for a check of the ID token beside them,
  which a renewal may leave out (OpenID Connect Core §12.2), and the new refresh token would be
  lost with it. The person is already known from the sign-in.

  `{:error, :moved}` is an endpoint EHOS says is not there (404, 405 or 410), and
  `{:error, :redirected}` one that redirects, which is never followed. Neither spent anything:
  the caller reads discovery again and posts to what it names now
  (`Ehosctl.Credentials.at_endpoints/5`), or says why with `moved/2`.
  """
  @spec renew(endpoints(), String.t(), String.t()) ::
          {:ok, tokens()} | {:error, :moved | :redirected} | error()
  def renew(endpoints, refresh_token, resource) do
    endpoint = endpoints.token

    params = %{
      "grant_type" => "refresh_token",
      "client_id" => @client_id,
      "refresh_token" => refresh_token,
      "resource" => resource
    }

    case post(endpoints, endpoint, params) do
      {:ok, 200, %{"access_token" => credential, "refresh_token" => rotated} = body}
      when is_binary(credential) and is_binary(rotated) ->
        # Within what a credential lives (D-33's ten minutes), so a value out of range neither
        # renews on every command nor keeps a credential for ever.
        expires_in =
          case body["expires_in"] do
            seconds when is_integer(seconds) and seconds > 0 -> min(seconds, 3600)
            _other -> 600
          end

        {:ok,
         %{credential: credential, expires_in: expires_in, refresh_token: rotated, claims: %{}}}

      {:ok, 200, _body} ->
        {:error, :failed, "EHOS's answer lacked a credential or a refresh token"}

      {:ok, status, _body} when status in @moved ->
        {:error, :moved}

      {:ok, status, _body} when status in 300..399 ->
        {:error, :redirected}

      {:ok, status, body} ->
        http_error(status, body, endpoints.issuer)

      {:error, reason} ->
        transport_error(reason, endpoints.issuer)
    end
  end

  @doc """
  Ends the sign-in at EHOS: posts `refresh_token` to the revocation endpoint (RFC 7009). EHOS
  answers `200` for a token it revoked and for one it does not know alike. `{:error, :moved}` is
  as `renew/3` says, and also the endpoints naming no revocation endpoint.
  """
  @spec revoke(endpoints(), String.t()) :: :ok | {:error, :moved | :redirected} | error()
  def revoke(endpoints, refresh_token) do
    case post(endpoints, endpoints.revocation, %{
           "client_id" => @client_id,
           "token" => refresh_token
         }) do
      {:ok, 200, _body} ->
        :ok

      {:ok, status, _body} when status in @moved ->
        {:error, :moved}

      {:ok, status, _body} when status in 300..399 ->
        {:error, :redirected}

      # RFC 7009 §2.2: a token the server does not know is answered 200 too, so any other answer
      # is the request refused, never the sign-in already over.
      {:ok, status, body} ->
        {:error, :failed,
         Enum.join(
           ["#{endpoints.issuer} refused to end the sign-in (HTTP #{status})" | said(body)],
           ": "
         )}

      # None kept: discovery may name one now (`Ehosctl.Credentials.at_endpoints/5`).
      {:error, :no_endpoint} ->
        {:error, :moved}

      {:error, reason} ->
        transport_error(reason, endpoints.issuer)
    end
  end

  @doc "Why a request posted to endpoints `issuer`'s discovery names now went nowhere."
  @spec moved(:moved | :redirected, String.t()) :: error()
  def moved(:moved, issuer),
    do: {:error, :failed, "#{issuer} names no endpoint for this, or one that is not there"}

  def moved(:redirected, issuer),
    do:
      {:error, :failed,
       "#{issuer} redirected a request that carries your token; ehosctl did not follow"}

  # No answer: a handshake that failed, said with its alert, or none at all.
  defp transport_error(reason, issuer),
    do: if(tls_alert(reason), do: untrusted(issuer, reason), else: unreachable(issuer))

  # A form posted to one of the provider's endpoints, and its answer's status and JSON body.
  defp post(_endpoints, endpoint, _params) when not is_binary(endpoint),
    do: {:error, :no_endpoint}

  defp post(endpoints, endpoint, params) do
    %{request_opts: request_opts} = endpoints

    # Never followed: a redirect would send the refresh token on to wherever it points, and an
    # answer from there would be taken as EHOS's.
    http_options =
      [timeout: request_opts.timeout, autoredirect: false] ++
        if ssl = request_opts[:ssl], do: [ssl: ssl], else: []

    case :httpc.request(
           :post,
           {String.to_charlist(endpoint), [{~c"accept", ~c"application/json"}],
            ~c"application/x-www-form-urlencoded", URI.encode_query(params)},
           http_options,
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        decoded =
          case JSON.decode(body) do
            {:ok, decoded} -> decoded
            {:error, _} -> %{}
          end

        {:ok, status, decoded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discovered({:ok, result}, _issuer), do: {:ok, result}

  defp discovered({:error, {:issuer_mismatch, issuer}}, url),
    do:
      {:error, :failed,
       "#{url} names #{printable(issuer)} as its issuer; sign in with that address"}

  defp discovered({:error, {:http_error, 404, _body}}, url),
    do: {:error, :failed, "#{url} is not an installation of EHOS: it has no discovery document"}

  defp discovered({:error, {:http_error, status, body}}, url), do: http_error(status, body, url)

  defp discovered({:error, reason}, url) do
    cond do
      tls_alert(reason) ->
        untrusted(url, reason)

      network?(reason) ->
        unreachable(url)

      true ->
        {:error, :failed,
         "#{url} is not an installation of EHOS ehosctl can sign in to (#{why(reason)})"}
    end
  end

  defp tokens({:ok, %Oidcc.Token{} = token}, _issuer) do
    with %Oidcc.Token.Access{token: credential, expires: expires_in} when is_binary(credential) <-
           token.access,
         %Oidcc.Token.Refresh{token: refresh} when is_binary(refresh) <- token.refresh,
         %Oidcc.Token.Id{claims: claims} <- token.id do
      {:ok,
       %{
         credential: credential,
         expires_in:
           if(is_integer(expires_in) and expires_in > 0, do: min(expires_in, 3600), else: 600),
         refresh_token: refresh,
         claims: claims
       }}
    else
      _incomplete ->
        {:error, :failed, "EHOS's answer lacked a credential, a refresh token or an ID token"}
    end
  end

  defp tokens({:error, {:http_error, status, body}}, issuer), do: http_error(status, body, issuer)

  defp tokens({:error, reason}, issuer) do
    cond do
      tls_alert(reason) ->
        untrusted(issuer, reason)

      network?(reason) ->
        unreachable(issuer)

      true ->
        {:error, :failed, "#{issuer}'s answer did not pass a sign-in's checks (#{why(reason)})"}
    end
  end

  # docs/refusals.md: the kinds and their sentences.
  defp http_error(400, %{"error" => "invalid_grant"}, _issuer),
    do: {:error, :not_signed_in, @expired}

  defp http_error(400, %{"error" => "invalid_target"}, _issuer),
    do:
      {:error, :refused,
       "None of your roles grants anything in that application and environment, so no " <>
         "credential was issued. Ask for a role binding there."}

  defp http_error(429, _body, _issuer),
    do: {:error, :unreachable, "Too many calls in the last minute. Try again in a minute."}

  defp http_error(status, _body, issuer) when status >= 500,
    do: {:error, :unreachable, "#{issuer} is unavailable (HTTP #{status}). Try again later."}

  defp http_error(status, body, issuer),
    do:
      {:error, :failed,
       Enum.join(["#{issuer} refused the request (HTTP #{status})" | said(body)], ": ")}

  # What an OAuth error's body says, printed safely.
  defp said(body) when is_map(body),
    do: for(key <- ["error", "error_description"], is_binary(body[key]), do: printable(body[key]))

  defp said(_body), do: []

  defp unreachable(issuer), do: {:error, :unreachable, "#{issuer} did not answer."}

  defp untrusted(issuer, reason),
    do:
      {:error, :failed,
       "the TLS handshake with #{issuer} failed (#{tls_alert(reason)}). For a local EHOS whose " <>
         "CA this machine does not trust, set EHOSCTL_CA_FILE to that CA's certificate."}

  # The alert of a TLS handshake that failed, which httpc reports inside its connection error,
  # or nil: most often `unknown_ca`, a certificate this machine does not trust.
  defp tls_alert({:tls_alert, {alert, _description}}) when is_atom(alert), do: alert
  defp tls_alert({:tls_alert, _alert}), do: :tls_alert
  defp tls_alert(term) when is_tuple(term), do: term |> Tuple.to_list() |> tls_alert()
  defp tls_alert(term) when is_list(term), do: Enum.find_value(term, &tls_alert/1)
  defp tls_alert(_term), do: nil

  # What httpc answers when no answer came: no connection, or none in time.
  defp network?({:failed_connect, _}), do: true
  defp network?(:timeout), do: true
  defp network?(:socket_closed_remotely), do: true
  defp network?({:shutdown, _}), do: true

  defp network?(reason) when reason in [:econnrefused, :nxdomain, :ehostunreach, :closed],
    do: true

  defp network?(_reason), do: false

  # oidcc's reasons are atoms or tuples that may hold a token's claims: only their name is shown.
  defp why(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp why(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp why(_reason), do: "unexpected answer"

  defp printable(text) when is_binary(text),
    do: if(Ehosctl.Output.printable?(text), do: text, else: inspect(text))

  defp printable(other), do: inspect(other)

  # Compared in constant time, as a secret is.
  defp same?(given, expected) when is_binary(given),
    do: byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)

  defp same?(_given, _expected), do: false

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end

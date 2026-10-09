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
      signature, issuer, audience and `nonce` oidcc checks (`exchange/4`).
    * **Renewal** names a `resource` (RFC 8707), and returns one credential and the refresh token
      that replaces the one spent (`renew/4`).
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
  """
  @spec provider(String.t(), keyword()) :: {:ok, provider()} | error()
  def provider(issuer, opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    with {:ok, request_opts} <- request_opts(issuer, env) do
      # Only the tests' fake EHOS is plain HTTP (`origin/2`).
      http? = URI.parse(issuer).scheme == "http"
      load = %{request_opts: request_opts, quirks: %{allow_unsafe_http: http?}}

      with {:ok, {configuration, _expiry}} <-
             discovered(Oidcc.ProviderConfiguration.load_configuration(issuer, load), issuer),
           {:ok, {jwks, _expiry}} <-
             discovered(
               Oidcc.ProviderConfiguration.load_jwks(configuration.jwks_uri, load),
               issuer
             ) do
        context =
          Oidcc.ClientContext.from_manual(configuration, jwks, @client_id, :unauthenticated)

        {:ok, %{issuer: issuer, context: context, opts: %{request_opts: request_opts}}}
      end
    end
  end

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
  Renews the sign-in of `subject` with `refresh_token`, for the credential of `resource`: EHOS's
  issuer for its API, or an application's address. The refresh token is spent, whatever is
  answered, unless EHOS refuses before rotating it, as it does a `resource` the person has no role
  at.
  """
  @spec renew(provider(), String.t(), String.t(), String.t()) :: {:ok, tokens()} | error()
  def renew(provider, refresh_token, resource, subject) do
    refresh_token
    |> Oidcc.Token.refresh(provider.context, %{
      expected_subject: subject,
      preferred_auth_methods: [:none],
      body_extension: [{"resource", resource}],
      request_opts: provider.opts.request_opts
    })
    |> tokens(provider.issuer)
  end

  @doc """
  Ends the sign-in at EHOS: posts `refresh_token` to the revocation endpoint (RFC 7009). EHOS
  answers `200` for a token it revoked and for one it does not know alike.
  """
  @spec revoke(provider(), String.t()) :: :ok | error()
  def revoke(provider, refresh_token) do
    endpoint = provider.context.provider_configuration.revocation_endpoint
    body = URI.encode_query(%{"client_id" => @client_id, "token" => refresh_token})
    %{request_opts: request_opts} = provider.opts

    http_options =
      [timeout: request_opts.timeout] ++
        if ssl = request_opts[:ssl], do: [ssl: ssl], else: []

    cond do
      not is_binary(endpoint) ->
        {:error, :failed, "#{provider.issuer} does not say where to end a sign-in"}

      true ->
        case :httpc.request(
               :post,
               {String.to_charlist(endpoint), [], ~c"application/x-www-form-urlencoded", body},
               http_options,
               body_format: :binary
             ) do
          {:ok, {{_version, 200, _reason}, _headers, _body}} ->
            :ok

          {:ok, {{_version, status, _reason}, _headers, _body}} ->
            http_error(status, %{}, provider.issuer)

          {:error, _reason} ->
            unreachable(provider.issuer)
        end
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
         expires_in: if(is_integer(expires_in), do: expires_in, else: 600),
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
    if network?(reason) and not tls_alert(reason),
      do: unreachable(issuer),
      else:
        {:error, :failed, "#{issuer}'s answer did not pass a sign-in's checks (#{why(reason)})"}
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

  defp http_error(status, body, issuer) do
    said =
      if is_map(body),
        do:
          for(
            key <- ["error", "error_description"],
            is_binary(body[key]),
            do: printable(body[key])
          ),
        else: []

    {:error, :failed, Enum.join(["#{issuer} refused the request (HTTP #{status})" | said], ": ")}
  end

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

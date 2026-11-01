defmodule Ehosctl.SignIn do
  @moduledoc """
  The terminal's side of signing in to EHOS (eh-os D-89), over oidcc (T-09). What talks to the
  installation's provider (discovery, the exchange, renewal and revocation) is a way out (T-20),
  `Ehosctl.SignInImpl`, which a test mocks; what checks and builds its requests here does not.

  `ehosctl` is EHOS's public client `ehosctl`: it proves nothing but the PKCE verifier it kept.

    * **Discovery** reads `/.well-known/openid-configuration` at the installation's URL, which
      must be its issuer, and the JWKS it names (`c:provider/2`).
    * **Authorization** sends the browser to EHOS with the code flow, PKCE `S256`, a `state` and
      a `nonce`, scope `openid email`, `max_age=0` so EHOS asks for the password, no `prompt` and
      no `resource` (`authorization/2`), pushed to EHOS first when its discovery names an
      endpoint for that (RFC 9126, `c:redirect_url/2`). The browser comes back to
      `http://127.0.0.1:<port>/callback` (`Ehosctl.SignIn.Loopback`), where `state` and `iss`
      (RFC 9207) are checked (`callback/3`).
    * **The exchange** gives a credential for EHOS's API, a refresh token and an ID token, whose
      signature, issuer, audience and `nonce` oidcc checks (`c:exchange/3`).
    * **Renewal** names a `resource` (RFC 8707), and returns one credential and the refresh token
      that replaces the one spent (`c:renew/3`). It is posted to the token endpoint the sign-in
      kept (`kept_endpoints/3`), without reading discovery or the JWKS again.
    * **Revocation** ends the sign-in at EHOS (RFC 7009), which oidcc does not do (`c:revoke/2`).

  Errors are of the kinds `Ehosctl.Output` gives exit codes to, in the words of eh-os's
  `docs/refusals.md`.
  """

  alias Ehosctl.TLS

  @client_id "ehosctl"
  @scopes [:openid, :email]

  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  # The most code points of an `error_description` shown, and the most bytes of it read.
  @reason_shown 200
  @reason_read 8192

  @typedoc """
  An installation's provider, as discovery and its JWKS describe it: its `context` is oidcc's
  `Oidcc.ClientContext`.
  """
  # The context is a term here: oidcc's types ask for an entry in maps its own decoder leaves
  # empty, which a mock held to this type would refuse.
  @type provider :: %{issuer: String.t(), context: term(), opts: map()}

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

  @doc """
  Reads the provider at the installation's URL `issuer`: its discovery document, which must name
  `issuer` as its own, and its JWKS. `opts` may name `:ca`, the CA kept for the installation (`Ehosctl.TLS.request_opts/3`).

  The issuer is checked again by `origin/1`, since it may come from `config.json`, and every
  endpoint `ehosctl` uses must be `https` on the issuer's own host: the code, the PKCE verifier
  and the refresh token are sent there, and the person's browser is sent to the authorization
  endpoint.
  """
  @callback provider(String.t(), keyword()) :: {:ok, provider()} | error()

  @doc """
  The token and revocation endpoints of the provider at `issuer`, from its discovery document
  alone, checked as `c:provider/2` checks them: what a renewal or a revocation needs when the ones
  a sign-in kept will not do. The JWKS is not read, which neither needs.
  """
  @callback discovered_endpoints(String.t(), keyword()) :: {:ok, endpoints()} | error()

  @doc """
  The URL to send the browser to for `request`. When the provider's discovery names a pushed
  authorization request endpoint (RFC 9126), oidcc posts the request there first, with the
  installation's request options, and the URL names what it answered.
  """
  @callback redirect_url(provider(), request()) :: {:ok, String.t()} | error()

  @doc "Redeems the code of `request` at the token endpoint, with no client authentication."
  @callback exchange(provider(), String.t(), request()) :: {:ok, tokens()} | error()

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
  (`Ehosctl.Credentials.at_endpoints/5`), or says why with `moved/3`.
  """
  @callback renew(endpoints(), String.t(), String.t()) ::
              {:ok, tokens()} | {:error, :moved | :redirected} | error()

  @doc """
  Ends the sign-in at EHOS: posts `refresh_token` to the revocation endpoint (RFC 7009). EHOS
  answers `200` for a token it revoked and for one it does not know alike. `{:error, :moved}` is
  as `c:renew/3` says, and also the endpoints naming no revocation endpoint.
  """
  @callback revoke(endpoints(), String.t()) :: :ok | {:error, :moved | :redirected} | error()

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module

  @doc "The client EHOS knows the terminal as."
  @spec client_id() :: String.t()
  def client_id, do: @client_id

  @doc """
  The installation's address as `ehosctl` keeps it: `Ehosctl.Config.origin/1`'s.

      iex> Ehosctl.SignIn.origin("https://EHOS.example.com/")
      {:ok, "https://ehos.example.com"}
  """
  @spec origin(String.t()) :: {:ok, String.t()} | error()
  defdelegate origin(url), to: Ehosctl.Config

  @doc """
  Whether `host` is this machine's: `localhost`, a name under `.localhost`, `127.0.0.1` or `::1`.
  """
  @spec loopback?(String.t()) :: boolean()
  def loopback?(host),
    do: host in @loopback_hosts or String.ends_with?(host, ".localhost") or host == "[::1]"

  # On the issuer's own scheme, host and port, parsed strictly, and with no user information or
  # backslash, which a browser reads otherwise than URI does: `https://evil.example\\@ehos.example.com`
  # is evil.example to a browser.
  @doc false
  @spec on_issuer?(term(), String.t()) :: boolean()
  def on_issuer?(endpoint, issuer) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(issuer)

    is_binary(endpoint) and Ehosctl.Output.printable?(endpoint) and
      not String.contains?(endpoint, "\\") and
      match?(
        {:ok, %URI{scheme: ^scheme, host: ^host, port: ^port, userinfo: nil}},
        URI.new(endpoint)
      )
  end

  @doc """
  The token and revocation endpoints of `provider`, read just now and checked by `c:provider/2`.
  """
  @spec endpoints(provider()) :: endpoints()
  def endpoints(provider) do
    endpoints_of(
      provider.context.provider_configuration,
      provider.issuer,
      provider.opts.request_opts
    )
  end

  @doc false
  @spec endpoints_of(Oidcc.ProviderConfiguration.t(), String.t(), map()) :: endpoints()
  def endpoints_of(configuration, issuer, request_opts) do
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
  discovery. `opts` are `c:provider/2`'s.
  """
  @spec kept_endpoints(String.t(), map() | nil, keyword()) :: {:ok, endpoints()} | :stale
  def kept_endpoints(issuer, %{"token" => token} = kept, opts) do
    env = Ehosctl.SystemEnv.current().all()
    revocation = kept["revocation"]

    with {:ok, ^issuer} <- origin(issuer),
         true <- on_issuer?(token, issuer),
         true <- is_nil(revocation) or on_issuer?(revocation, issuer),
         {:ok, request_opts} <- TLS.request_opts(issuer, env, Keyword.get(opts, :ca)) do
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

    with {:ok, url} <- current().redirect_url(provider, request), do: {:ok, url, request}
  end

  @doc false
  @spec scopes() :: [atom()]
  def scopes, do: @scopes

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
        {:error, :refused,
         Enum.join(
           [
             "EHOS did not sign you in (#{Ehosctl.Refusal.shown(params["error"])})"
             | reason(params["error_description"])
           ],
           ": "
         )}

      is_binary(params["code"]) and params["code"] != "" ->
        {:ok, params["code"]}

      true ->
        {:error, :failed, "#{issuer} sent the browser back without a code"}
    end
  end

  @doc """
  Why a request posted to the endpoint `endpoint` of `endpoints`, as `issuer`'s discovery names
  them now, went nowhere.
  """
  @spec moved(:moved | :redirected, endpoints(), :token | :revocation) :: error()
  def moved(:moved, %{revocation: nil, issuer: issuer}, :revocation),
    do: {:error, :failed, "#{issuer} does not say where to end a sign-in"}

  def moved(:moved, %{issuer: issuer}, endpoint),
    do: {:error, :failed, "#{issuer}'s #{name(endpoint)} endpoint is not there"}

  def moved(:redirected, %{issuer: issuer}, _endpoint),
    do:
      {:error, :failed,
       "#{issuer} redirected a request that carries your token; ehosctl did not follow"}

  defp name(:token), do: "token"
  defp name(:revocation), do: "revocation"

  # An OAuth error's `error_description` (RFC 6749 §4.1.2.1 and §5.2), a sentence for a person:
  # on one line, its whitespace one space, without the characters `Ehosctl.Output.shown_lines/1`
  # would escape or that are not assigned, and at most @reason_shown code points long, or
  # nothing. Only its first @reason_read bytes are read: a token endpoint's body has no bound.
  @doc false
  @spec reason(term()) :: [String.t()]
  def reason(description) when is_binary(description) do
    reason =
      description
      |> binary_slice(0, @reason_read)
      |> String.replace_invalid("")
      |> String.replace(~r/(?!\s)(?:\p{Cc}|\p{Cn}|(?!\x{200C}|\x{200D})\p{Cf})/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.codepoints()

    cond do
      reason == [] ->
        []

      length(reason) > @reason_shown ->
        [(reason |> Enum.take(@reason_shown - 1) |> Enum.join() |> String.trim_trailing()) <> "…"]

      true ->
        [Enum.join(reason)]
    end
  end

  def reason(_description), do: []

  # oidcc's reasons are atoms or tuples that may hold a token's claims: only their name is shown.
  @doc false
  @spec why(term()) :: String.t()
  def why(reason) when is_atom(reason), do: Atom.to_string(reason)

  def why(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  def why(_reason), do: "unexpected answer"

  # Compared in constant time, as a secret is.
  defp same?(given, expected) when is_binary(given),
    do: byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)

  defp same?(_given, _expected), do: false

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end

defmodule Ehosctl.SignInImpl do
  @moduledoc "The `Ehosctl.SignIn` that talks to the installation's provider, through oidcc and `:httpc`."

  @behaviour Ehosctl.SignIn

  import Ehosctl.SignIn,
    only: [endpoints_of: 3, on_issuer?: 2, origin: 1, reason: 1, scopes: 0, why: 1]

  alias Ehosctl.HTTP
  alias Ehosctl.TLS

  @client_id Ehosctl.SignIn.client_id()

  @expired "Your sign-in has expired. Run `ehosctl login`."

  # What an endpoint that is no longer there answers, before it spends anything.
  @moved [404, 405, 410]

  @impl true
  def provider(issuer, opts) do
    with {:ok, configuration, load, request_opts} <- discover(issuer, opts),
         {:ok, {jwks, _expiry}} <-
           discovered(
             Oidcc.ProviderConfiguration.load_jwks(configuration.jwks_uri, load),
             issuer,
             request_opts.trusted
           ) do
      context = Oidcc.ClientContext.from_manual(configuration, jwks, @client_id, :unauthenticated)
      {:ok, %{issuer: issuer, context: context, opts: %{request_opts: request_opts}}}
    end
  end

  @impl true
  def discovered_endpoints(issuer, opts) do
    with {:ok, configuration, _load, request_opts} <- discover(issuer, opts) do
      {:ok, endpoints_of(configuration, issuer, request_opts)}
    end
  end

  defp discover(issuer, opts) do
    env = Ehosctl.SystemEnv.current().all()

    with {:ok, ^issuer} <- stored(origin(issuer), issuer),
         {:ok, request_opts} <- TLS.request_opts(issuer, env, Keyword.get(opts, :ca)) do
      load = %{request_opts: oidcc_opts(request_opts)}

      with {:ok, {configuration, _expiry}} <-
             discovered(
               Oidcc.ProviderConfiguration.load_configuration(issuer, load),
               issuer,
               request_opts.trusted
             ),
           :ok <- check_endpoints(configuration, issuer) do
        {:ok, configuration, load, request_opts}
      end
    end
  end

  # oidcc's request options are a closed map (`:oidcc_http_util.request_opts()`): `:trusted`,
  # which ehosctl keeps for its own errors, is not one of them.
  defp oidcc_opts(request_opts), do: Map.delete(request_opts, :trusted)

  # An address from config.json that is not an origin `login` would keep, as it is.
  defp stored({:ok, issuer}, issuer), do: {:ok, issuer}

  defp stored({:error, _kind, message}, _issuer),
    do: {:error, :invalid, message <> "; sign in with its https address: ehosctl login URL"}

  defp stored({:ok, _other}, issuer),
    do:
      {:error, :invalid,
       "#{inspect(issuer)} is not an installation's address as ehosctl keeps it; " <>
         "sign in with it again: ehosctl login URL"}

  defp check_endpoints(configuration, issuer) do
    required = [
      configuration.authorization_endpoint,
      configuration.token_endpoint,
      configuration.jwks_uri
    ]

    # The revocation endpoint may be missing, which `revoke/2` says, and the pushed
    # authorization request endpoint, which `redirect_url/2` posts to when it is named; not
    # elsewhere.
    optional = [
      configuration.revocation_endpoint,
      configuration.pushed_authorization_request_endpoint
    ]

    if Enum.all?(required, &on_issuer?(&1, issuer)) and
         Enum.all?(optional, &(&1 == :undefined or on_issuer?(&1, issuer))),
       do: :ok,
       else:
         {:error, :failed,
          "#{issuer} names an endpoint that is not https on #{issuer} itself; " <>
            "ehosctl does not sign in there"}
  end

  @impl true
  def redirect_url(provider, request) do
    provider.context
    |> Oidcc.Authorization.create_redirect_url(%{
      redirect_uri: request.redirect_uri,
      scopes: scopes(),
      state: request.state,
      nonce: request.nonce,
      pkce_verifier: request.verifier,
      require_pkce: true,
      url_extension: [{"max_age", "0"}],
      request_opts: oidcc_opts(provider.opts.request_opts)
    })
    |> pushed(provider.issuer, provider.opts.request_opts[:trusted])
  end

  # The URL, or why a pushed authorization request failed, read as the exchange's failures are.
  defp pushed({:ok, url}, _issuer, _trusted), do: {:ok, IO.iodata_to_binary(url)}

  defp pushed({:error, {:http_error, status, body}}, issuer, _trusted)
       when status == 429 or status >= 500,
       do: http_error(status, body, issuer)

  # Not the token endpoint's 400s: a pushed request is answered with the authorization
  # endpoint's codes (RFC 9126), and oidcc gives a 2xx without a `request_uri` the same shape.
  defp pushed({:error, {:http_error, status, body}}, issuer, _trusted),
    do:
      {:error, :failed,
       Enum.join(
         [
           "#{issuer} did not take the pushed authorization request (HTTP #{status})" | said(body)
         ],
         ": "
       )}

  defp pushed({:error, reason}, issuer, trusted) do
    cond do
      HTTP.tls_alert(reason) ->
        HTTP.untrusted(issuer, reason, trusted)

      HTTP.network?(reason) ->
        HTTP.unreachable(issuer)

      true ->
        {:error, :failed, "#{issuer} cannot sign ehosctl in: #{why(reason)}"}
    end
  end

  @impl true
  def exchange(provider, code, request) do
    provider.context
    |> then(
      &Oidcc.Token.retrieve(code, &1, %{
        redirect_uri: request.redirect_uri,
        pkce_verifier: request.verifier,
        require_pkce: true,
        nonce: request.nonce,
        preferred_auth_methods: [:none],
        request_opts: oidcc_opts(provider.opts.request_opts)
      })
    )
    |> tokens(provider.issuer, provider.opts.request_opts[:trusted])
  end

  @impl true
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
        expires_in = renewed_expires_in(body["expires_in"])

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
        HTTP.transport_error(reason, endpoints.issuer, endpoints.request_opts[:trusted])
    end
  end

  # Within what a credential lives (D-33's ten minutes), so a value out of range neither
  # renews on every command nor keeps a credential for ever.
  defp renewed_expires_in(seconds) when is_integer(seconds) and seconds > 0,
    do: min(seconds, 3600)

  defp renewed_expires_in(_other), do: 600

  @impl true
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
        HTTP.transport_error(reason, endpoints.issuer, endpoints.request_opts[:trusted])
    end
  end

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

  defp discovered({:ok, result}, _issuer, _trusted), do: {:ok, result}

  defp discovered({:error, {:issuer_mismatch, issuer}}, url, _trusted),
    do:
      {:error, :failed,
       "#{url} names #{Ehosctl.Refusal.shown(issuer)} as its issuer; sign in with that address"}

  defp discovered({:error, {:http_error, 404, _body}}, url, _trusted),
    do: {:error, :failed, "#{url} is not an installation of EHOS: it has no discovery document"}

  defp discovered({:error, {:http_error, status, body}}, url, _trusted),
    do: http_error(status, body, url)

  defp discovered({:error, reason}, url, trusted) do
    cond do
      HTTP.tls_alert(reason) ->
        HTTP.untrusted(url, reason, trusted)

      HTTP.network?(reason) ->
        HTTP.unreachable(url)

      true ->
        {:error, :failed,
         "#{url} is not an installation of EHOS ehosctl can sign in to (#{why(reason)})"}
    end
  end

  defp tokens({:ok, %Oidcc.Token{} = token}, _issuer, _trusted) do
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

  defp tokens({:error, {:http_error, status, body}}, issuer, _trusted),
    do: http_error(status, body, issuer)

  defp tokens({:error, reason}, issuer, trusted) do
    cond do
      HTTP.tls_alert(reason) ->
        HTTP.untrusted(issuer, reason, trusted)

      HTTP.network?(reason) ->
        HTTP.unreachable(issuer)

      true ->
        {:error, :failed, "#{issuer}'s answer did not pass a sign-in's checks (#{why(reason)})"}
    end
  end

  # docs/refusals.md: the kinds and their sentences.
  defp http_error(400, %{"error" => "invalid_grant"}, _issuer),
    do: {:error, :not_signed_in, @expired}

  # RFC 8707's code for a `resource` nothing is granted at, and refusals.md's for the same.
  defp http_error(400, %{"error" => code}, _issuer)
       when code in ["invalid_target", "no_capability"],
       do: {:error, :refused, Ehosctl.Refusal.sentence("no_capability")}

  defp http_error(429, _body, _issuer),
    do: {:error, :unreachable, "Too many calls in the last minute. Try again in a minute."}

  defp http_error(status, _body, issuer) when status >= 500,
    do: {:error, :unreachable, "#{issuer} is unavailable (HTTP #{status}). Try again later."}

  # A refusal refusals.md names is one (`Ehosctl.Refusal.kind/1`). Every other answer is a
  # failure, never `:not_signed_in`: that forgets the sign-in, which only `invalid_grant` may do.
  defp http_error(status, body, issuer),
    do:
      {:error, kind(body),
       Enum.join(["#{issuer} refused the request (HTTP #{status})" | said(body)], ": ")}

  defp kind(%{"error" => code}) when is_binary(code),
    do: if(Ehosctl.Refusal.kind(code) == :refused, do: :refused, else: :failed)

  defp kind(_body), do: :failed

  # What an OAuth error's body says, printed safely.
  defp said(body) when is_map(body) do
    code = if is_binary(body["error"]), do: [Ehosctl.Refusal.shown(body["error"])], else: []
    code ++ reason(body["error_description"])
  end

  defp said(_body), do: []
end

defmodule Ehosctl.FakeProvider do
  @moduledoc """
  A fake EHOS for the tests of the commands: it signs people in through the mock of
  `Ehosctl.SignIn`, and serves EHOS's API at its address through `Ehosctl.FakeHTTP`. Nothing
  listens on a port; how `Ehosctl.SignInImpl` talks to a real provider is its own test's, on
  `Ehosctl.FakeIssuer`.

  It keeps what a provider would: the codes it issued with their PKCE challenge, `nonce` and
  redirect URI, and the refresh tokens that are live, each rotated on use, so a token used twice
  is refused. Each call of `Ehosctl.SignIn` it answers is kept, for the tests to read
  (`calls/2`), and each request to its API (`requests/2`). `browser/2` plays the person's
  browser: it signs in at once and comes back to `ehosctl`'s callback.

  What `Ehosctl.SignIn` would return otherwise, a test says with `answer_discovery/2`,
  `answer_renewal/2` and `answer_revoke/2`. A sign-in kept with an endpoint at one of these
  paths is answered as EHOS answers there now: `/oauth/gone` is not there (`{:error, :moved}`),
  `/oauth/moved` redirects (`{:error, :redirected}`), and `/oauth/stale` is served by something
  that refuses every token.

  Its API serves what EHOS tells a terminal (eh-os `docs/terminal-api.md`): `GET /api/v1/me/roles`
  and `GET /api/v1/me/applications`, answering what `put_me/2` set to a credential it issued for
  EHOS's API, and `{"error", "message"}` otherwise; any other route of the API answers as a test
  says with `stub_api/4`. Its token endpoint takes a GitHub Actions job's exchange (eh-os D-110).
  `resource/2` says which `resource` a credential was issued for.
  """

  alias Ehosctl.FakeHTTP
  alias Ehosctl.HTTP

  @client_id "ehosctl"
  @expired "Your sign-in has expired. Run `ehosctl login`."

  defstruct [:http, :issuer, :jwk, :agent]

  @type t :: %__MODULE__{}

  @doc """
  Starts a provider. `opts` may set `:email` (`nil` for none), `:subject` and `:auth_time`.
  """
  @spec start(keyword()) :: t()
  def start(opts \\ []) do
    http = FakeHTTP.open()

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          codes: %{},
          refresh_tokens: MapSet.new(),
          requests: [],
          calls: [],
          down: false,
          token_answer: nil,
          renewal_answer: nil,
          revoke_answer: nil,
          discovery_answer: nil,
          discovery: %{},
          on_revoke: nil,
          subject: Keyword.get(opts, :subject, "0b9f6c1e-person"),
          email: Keyword.get(opts, :email, "grace@example.com"),
          auth_time: Keyword.get(opts, :auth_time, System.os_time(:second)),
          id_token: %{},
          issued: %{},
          me: %{roles: [], applications: []},
          api_answer: nil,
          exchange_expires_in: 600
        }
      end)

    provider = %__MODULE__{
      http: http,
      issuer: http.origin,
      jwk: JOSE.JWK.generate_key({:okp, :Ed25519}),
      agent: agent
    }

    FakeHTTP.stub(http, "POST", "/oauth/token", &exchange_token(&1, provider))
    FakeHTTP.stub(http, "GET", "/api/v1/me/roles", &me(&1, provider, :roles))
    FakeHTTP.stub(http, "GET", "/api/v1/me/applications", &me(&1, provider, :applications))
    serve(provider)
    provider
  end

  @doc """
  The requests sent to its API at `path`, oldest first, each as `stub_api/4` gives it to a route,
  or, at its token endpoint, as the decoded form it posted.
  """
  @spec requests(t(), String.t()) :: [map()]
  def requests(provider, path) do
    provider.agent
    |> Agent.get(& &1.requests)
    |> Enum.reverse()
    |> Enum.flat_map(fn {request_path, request} ->
      if request_path == path, do: [request], else: []
    end)
  end

  @doc """
  The calls of `Ehosctl.SignIn` it answered of `kind`, oldest first: `:discovery` (discovery read
  by `c:Ehosctl.SignIn.provider/2` or `c:Ehosctl.SignIn.discovered_endpoints/2`, with `:jwks` for the JWKS the first reads too),
  `:exchange`, `:renew` and `:revoke`, each with the endpoint it was posted to and what was sent.
  """
  @spec calls(t(), :discovery | :jwks | :exchange | :renew | :revoke) :: [map()]
  def calls(provider, kind) do
    provider.agent
    |> Agent.get(& &1.calls)
    |> Enum.reverse()
    |> Enum.flat_map(fn {call_kind, call} -> if call_kind == kind, do: [call], else: [] end)
  end

  @doc "The refresh tokens that are live."
  @spec refresh_tokens(t()) :: MapSet.t()
  def refresh_tokens(provider), do: Agent.get(provider.agent, & &1.refresh_tokens)

  @doc """
  Makes its token endpoint answer a GitHub Actions job's next exchanges with `status` and `body`
  instead, until `answer_normally/1`.
  """
  @spec answer_token(t(), pos_integer(), map()) :: :ok
  def answer_token(provider, status, body),
    do: Agent.update(provider.agent, &%{&1 | token_answer: {status, body}})

  @doc "Makes the next renewals return `result`, as `c:Ehosctl.SignIn.renew/3` would."
  @spec answer_renewal(t(), term()) :: :ok
  def answer_renewal(provider, result),
    do: Agent.update(provider.agent, &%{&1 | renewal_answer: result})

  @doc "Makes the next revocations return `result`, as `c:Ehosctl.SignIn.revoke/2` would."
  @spec answer_revoke(t(), term()) :: :ok
  def answer_revoke(provider, result),
    do: Agent.update(provider.agent, &%{&1 | revoke_answer: result})

  @doc """
  Makes discovery return `result`, as `c:Ehosctl.SignIn.discovered_endpoints/2` would, for one
  that cannot be read.
  """
  @spec answer_discovery(t(), term()) :: :ok
  def answer_discovery(provider, result),
    do: Agent.update(provider.agent, &%{&1 | discovery_answer: result})

  @doc "Makes the credentials the next GitHub Actions exchanges give expire after `seconds`."
  @spec exchange_expires_in(t(), pos_integer()) :: :ok
  def exchange_expires_in(provider, seconds),
    do: Agent.update(provider.agent, &%{&1 | exchange_expires_in: seconds})

  @doc "Makes its token endpoint and API answer as a provider does."
  @spec answer_normally(t()) :: :ok
  def answer_normally(provider),
    do: Agent.update(provider.agent, &%{&1 | token_answer: nil, api_answer: nil})

  @doc "Puts `claims` over those of the next ID tokens' claims."
  @spec put_id_token_claims(t(), map()) :: :ok
  def put_id_token_claims(provider, claims),
    do: Agent.update(provider.agent, &%{&1 | id_token: claims})

  @doc "Calls `fun` when a revocation arrives, before it is answered."
  @spec on_revoke(t(), (-> term())) :: :ok
  def on_revoke(provider, fun), do: Agent.update(provider.agent, &%{&1 | on_revoke: fun})

  @doc """
  Puts `fields` over the endpoints discovery names, `"token_endpoint"` and
  `"revocation_endpoint"`; one given as `:drop` is named by none.
  """
  @spec put_discovery(t(), map()) :: :ok
  def put_discovery(provider, fields),
    do: Agent.update(provider.agent, &%{&1 | discovery: fields})

  @doc """
  The person's browser, for `Ehosctl.Case.stub_browser/1`: it reads the authorization URL, as
  EHOS would, issues a code for it, and goes back to the redirect URI with `code`, `state` and
  `iss`. `overrides` replaces any of those three in the callback, and `:before` is a callback
  query to send first.
  """
  @spec browser(t(), keyword()) :: (String.t() -> :ok)
  def browser(provider, overrides \\ []) do
    test = self()

    fn url -> authorize(provider, overrides, test, url) end
  end

  defp authorize(provider, overrides, test, url) do
    %URI{query: query} = URI.parse(url)
    params = URI.decode_query(query)
    send(test, {:authorization, params})
    code = "code-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))

    Agent.update(provider.agent, fn state ->
      put_in(state, [:codes, code], %{
        challenge: params["code_challenge"],
        nonce: params["nonce"],
        redirect_uri: params["redirect_uri"]
      })
    end)

    query =
      %{"code" => code, "state" => params["state"], "iss" => provider.issuer}
      |> Map.merge(
        Map.new(Keyword.drop(overrides, [:before]), fn {k, v} -> {to_string(k), v} end)
      )
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    callbacks =
      case overrides[:before] do
        nil -> [query]
        before -> [before, query]
      end

    {:ok, _} =
      Task.start(fn ->
        for callback <- callbacks do
          {:ok, _response} =
            :httpc.request(
              String.to_charlist(params["redirect_uri"] <> "?" <> URI.encode_query(callback))
            )
        end
      end)

    :ok
  end

  @doc "The `resource` the credential `token` was issued for, or `nil` for one it never issued."
  @spec resource(t(), String.t()) :: String.t() | nil
  def resource(provider, token), do: Agent.get(provider.agent, & &1.issued[token])

  @doc "Sets what `GET /api/v1/me/roles` (`:roles`) or `GET /api/v1/me/applications` lists."
  @spec put_me(t(), keyword()) :: :ok
  def put_me(provider, me),
    do: Agent.update(provider.agent, &%{&1 | me: Map.merge(&1.me, Map.new(me))})

  @doc "Makes EHOS's API answer `status` and `body` instead, until `answer_normally/1`."
  @spec answer_api(t(), pos_integer(), map()) :: :ok
  def answer_api(provider, status, body),
    do: Agent.update(provider.agent, &%{&1 | api_answer: {status, body}})

  @doc """
  Answers `method` at `path` of EHOS's API, a route whose `:name` segments match any, with
  `answer`: given `%{path, query, body, content_type}` (the body as it was sent), it returns
  `{status, body}` or `{status, headers, body}`. The credential is checked first, as
  `GET /api/v1/me/roles` checks it, and each request is kept, for `requests/2` as
  `"<METHOD> <path>"`.
  """
  @spec stub_api(t(), String.t(), String.t(), (map() -> tuple())) :: :ok
  def stub_api(provider, method, path, answer) do
    FakeHTTP.stub(provider.http, method, path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 4_000_000)

      request = %{
        path: conn.request_path,
        query: URI.decode_query(conn.query_string),
        body: body,
        content_type: conn |> Plug.Conn.get_req_header("content-type") |> List.first()
      }

      key = "#{method} #{conn.request_path}"
      Agent.update(provider.agent, &%{&1 | requests: [{key, request} | &1.requests]})

      with :ok <- authorized(conn, provider) do
        api_answer(conn, answer.(request))
      end
    end)
  end

  defp api_answer(conn, {status, headers, body}) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, name, value)
    end)
    |> json(status, body)
  end

  defp api_answer(conn, {status, body}), do: json(conn, status, body)

  @doc "Takes the provider down: neither it nor its API answers."
  @spec down(t()) :: :ok
  def down(provider) do
    Agent.update(provider.agent, &%{&1 | down: true})
    FakeHTTP.down(provider.http)
  end

  # The test's providers, by issuer, which the mock of `Ehosctl.SignIn` answers as: started and
  # stubbed by the test's first `start/1`. An issuer no provider has does not answer.
  defp serve(provider) do
    providers =
      case Process.get(__MODULE__) do
        nil ->
          {:ok, providers} = Agent.start_link(fn -> %{} end)
          Process.put(__MODULE__, providers)
          stub_sign_in(providers)
          providers

        providers ->
          providers
      end

    Agent.update(providers, &Map.put(&1, provider.issuer, provider))
  end

  defp stub_sign_in(providers) do
    Hammox.stub(Ehosctl.SignInMock, :provider, fn issuer, opts ->
      answer(providers, issuer, &read_provider(&1, opts))
    end)

    Hammox.stub(Ehosctl.SignInMock, :discovered_endpoints, fn issuer, opts ->
      answer(providers, issuer, &discovered_endpoints(&1, opts))
    end)

    Hammox.stub(Ehosctl.SignInMock, :exchange, fn signed_in, code, request ->
      answer(providers, signed_in.issuer, &exchange(&1, code, request))
    end)

    Hammox.stub(Ehosctl.SignInMock, :renew, fn endpoints, refresh_token, resource ->
      answer(providers, endpoints.issuer, &renew(&1, endpoints, refresh_token, resource))
    end)

    Hammox.stub(Ehosctl.SignInMock, :revoke, fn endpoints, refresh_token ->
      answer(providers, endpoints.issuer, &revoke(&1, endpoints, refresh_token))
    end)
  end

  # The provider at `issuer` answers, unless it is down, or there is none.
  defp answer(providers, issuer, answer) do
    case Agent.get(providers, &Map.get(&1, issuer)) do
      %__MODULE__{} = provider ->
        answer_up(provider, Agent.get(provider.agent, & &1.down), answer)

      nil ->
        HTTP.unreachable(issuer)
    end
  end

  defp answer_up(provider, true = _down, _answer), do: HTTP.unreachable(provider.issuer)
  defp answer_up(provider, false, answer), do: answer.(provider)

  # Discovery and the JWKS, read into the context oidcc builds the authorization URL from, with
  # the options a request to the installation is made with (`Ehosctl.TLS.request_opts/3`).
  defp read_provider(provider, opts) do
    with {:ok, request_opts} <- request_opts(provider, opts) do
      record(provider, :discovery, %{})
      record(provider, :jwks, %{})
      configuration = configuration(provider)
      jwks = JOSE.JWK.to_public(provider.jwk)
      context = Oidcc.ClientContext.from_manual(configuration, jwks, @client_id, :unauthenticated)
      {:ok, %{issuer: provider.issuer, context: context, opts: %{request_opts: request_opts}}}
    end
  end

  defp discovered_endpoints(provider, opts) do
    case Agent.get(provider.agent, & &1.discovery_answer) do
      nil ->
        with {:ok, request_opts} <- request_opts(provider, opts) do
          record(provider, :discovery, %{})

          {:ok,
           Ehosctl.SignIn.endpoints_of(configuration(provider), provider.issuer, request_opts)}
        end

      answer ->
        answer
    end
  end

  defp request_opts(provider, opts),
    do:
      Ehosctl.TLS.request_opts(
        provider.issuer,
        Ehosctl.SystemEnv.current().all(),
        Keyword.get(opts, :ca)
      )

  # The discovery document EHOS serves (eh-os D-89), decoded as oidcc decodes one read over HTTP.
  defp configuration(provider) do
    issuer = provider.issuer
    fields = Agent.get(provider.agent, & &1.discovery)

    {:ok, configuration} =
      %{
        "issuer" => issuer,
        "authorization_endpoint" => issuer <> "/oauth/authorize",
        "token_endpoint" => issuer <> "/oauth/token",
        "jwks_uri" => issuer <> "/jwks",
        "revocation_endpoint" => issuer <> "/oauth/revoke",
        "revocation_endpoint_auth_methods_supported" => ["none"],
        "response_types_supported" => ["code"],
        "response_modes_supported" => ["query"],
        "grant_types_supported" => ["authorization_code", "refresh_token", "client_credentials"],
        "subject_types_supported" => ["public"],
        "id_token_signing_alg_values_supported" => ["Ed25519"],
        "token_endpoint_auth_methods_supported" => ["private_key_jwt", "none"],
        "token_endpoint_auth_signing_alg_values_supported" => ["Ed25519", "EdDSA"],
        "scopes_supported" => ["openid", "email", "profile"],
        "code_challenge_methods_supported" => ["S256"],
        "authorization_response_iss_parameter_supported" => true
      }
      |> Map.merge(fields)
      |> Map.reject(fn {_field, value} -> value == :drop end)
      |> Oidcc.ProviderConfiguration.decode_configuration()

    configuration
  end

  # A code issued for this request: its verifier matches the challenge, and its redirect URI is
  # the one the browser was sent back to.
  defp exchange(provider, code, request) do
    record(provider, :exchange, %{
      code: code,
      verifier: request.verifier,
      redirect_uri: request.redirect_uri
    })

    issued =
      Agent.get_and_update(provider.agent, fn state ->
        {state.codes[code], update_in(state.codes, &Map.delete(&1, code))}
      end)

    challenge = Base.url_encode64(:crypto.hash(:sha256, request.verifier), padding: false)

    if issued && issued.challenge == challenge && issued.redirect_uri == request.redirect_uri,
      do: {:ok, tokens(provider, %{"nonce" => issued.nonce}, provider.issuer)},
      else: {:error, :not_signed_in, @expired}
  end

  defp renew(provider, endpoints, refresh_token, resource) do
    record(provider, :renew, %{
      endpoint: endpoints.token,
      refresh_token: refresh_token,
      resource: resource
    })

    state = Agent.get(provider.agent, & &1)

    case {URI.parse(endpoints.token).path, state.renewal_answer} do
      {"/oauth/gone", _answer} -> {:error, :moved}
      {"/oauth/moved", _answer} -> {:error, :redirected}
      {"/oauth/stale", _answer} -> {:error, :not_signed_in, @expired}
      {_path, nil} -> rotate(provider, refresh_token, resource)
      {_path, answer} -> answer
    end
  end

  defp rotate(provider, presented, resource) do
    live? =
      Agent.get_and_update(provider.agent, fn state ->
        {MapSet.member?(state.refresh_tokens, presented),
         %{state | refresh_tokens: MapSet.delete(state.refresh_tokens, presented)}}
      end)

    # The person is known from the sign-in: a renewal's claims are none.
    if live?,
      do: {:ok, %{tokens(provider, %{}, resource) | claims: %{}}},
      else: {:error, :not_signed_in, @expired}
  end

  defp revoke(provider, endpoints, refresh_token) do
    record(provider, :revoke, %{endpoint: endpoints.revocation, token: refresh_token})
    state = Agent.get(provider.agent, & &1)
    if state.on_revoke, do: state.on_revoke.()

    case {endpoints.revocation && URI.parse(endpoints.revocation).path, state.revoke_answer} do
      {nil, _answer} ->
        {:error, :moved}

      {"/oauth/gone", _answer} ->
        {:error, :moved}

      {"/oauth/moved", _answer} ->
        {:error, :redirected}

      {_path, nil} ->
        Agent.update(provider.agent, fn state ->
          %{state | refresh_tokens: MapSet.delete(state.refresh_tokens, refresh_token)}
        end)

      {_path, answer} ->
        answer
    end
  end

  defp tokens(provider, claims, resource) do
    refresh = new_refresh_token()
    state = Agent.get(provider.agent, & &1)
    credential = "credential-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
    now = System.os_time(:second)

    Agent.update(provider.agent, fn state ->
      %{
        state
        | refresh_tokens: MapSet.put(state.refresh_tokens, refresh),
          issued: Map.put(state.issued, credential, resource)
      }
    end)

    claims =
      %{
        "iss" => provider.issuer,
        "sub" => state.subject,
        "aud" => @client_id,
        "iat" => now,
        "exp" => now + 600,
        "auth_time" => state.auth_time
      }
      |> Map.merge(claims)
      |> then(&if state.email, do: Map.put(&1, "email", state.email), else: &1)
      |> Map.merge(state.id_token)

    %{credential: credential, expires_in: 600, refresh_token: refresh, claims: claims}
  end

  # A GitHub Actions job's exchange (eh-os D-110), which `Ehosctl.HTTP` posts: no client
  # authentication, and a subject token the fake GitHub token service gave for this issuer,
  # `github:<audience>:<n>`.
  defp exchange_token(conn, provider) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = URI.decode_query(body)
    Agent.update(provider.agent, &%{&1 | requests: [{"/oauth/token", params} | &1.requests]})

    expected = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "client_id" => "github-actions",
      "subject_token_type" => "urn:ietf:params:oauth:token-type:id_token",
      "audience" => "ehos"
    }

    cond do
      answer = Agent.get(provider.agent, & &1.token_answer) ->
        {status, body} = answer
        json(conn, status, body)

      Map.take(params, Map.keys(expected)) == expected and
          String.starts_with?(params["subject_token"] || "", "github:#{provider.issuer}:") ->
        credential = "ci-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
        Agent.update(provider.agent, &put_in(&1, [:issued, credential], provider.issuer))

        json(conn, 200, %{
          "access_token" => credential,
          "issued_token_type" => "urn:ietf:params:oauth:token-type:access_token",
          "token_type" => "Bearer",
          "expires_in" => Agent.get(provider.agent, & &1.exchange_expires_in)
        })

      true ->
        json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  # EHOS's API: a credential it issued for itself, else refusals.md's `{"error", "message"}`.
  defp me(conn, provider, what) do
    Agent.update(provider.agent, &%{&1 | requests: [{conn.request_path, %{}} | &1.requests]})

    with :ok <- authorized(conn, provider),
         do:
           json(conn, 200, %{
             to_string(what) => Agent.get(provider.agent, &Map.fetch!(&1.me, what))
           })
  end

  # `:ok` for a credential it issued for itself, else the answer: `answer_api/3`'s, or a 401.
  defp authorized(conn, provider) do
    state = Agent.get(provider.agent, & &1)

    case {state.api_answer, Plug.Conn.get_req_header(conn, "authorization")} do
      {{status, body}, _authorization} ->
        json(conn, status, body)

      {nil, ["Bearer " <> token]} ->
        if state.issued[token] == provider.issuer,
          do: :ok,
          else:
            json(conn, 401, %{
              "error" => "wrong_audience",
              "message" => "Your credential is for another application or environment."
            })

      {nil, _none} ->
        json(conn, 401, %{
          "error" => "missing",
          "message" => "You are not signed in. Run `ehosctl login`."
        })
    end
  end

  defp record(provider, kind, call),
    do: Agent.update(provider.agent, &%{&1 | calls: [{kind, call} | &1.calls]})

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end

  defp new_refresh_token, do: "refresh-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
end

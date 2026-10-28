defmodule Ehosctl.FakeProvider do
  @moduledoc """
  A fake EHOS for the tests of signing in: its provider's discovery document, JWKS, token
  endpoint and revocation endpoint on a local port (Bypass), with ID tokens signed by an Ed25519
  key, as EHOS signs them (eh-os D-64).

  It keeps what a provider would: the codes it issued with their PKCE challenge and `nonce`, and
  the refresh tokens that are live, each rotated on use, so a token used twice is refused. Every
  request it is sent is kept, for the tests to read (`requests/2`). `browser/2` plays the
  person's browser: it signs in at once and comes back to `ehosctl`'s callback.

  At the same address, through `Ehosctl.FakeHTTP`, it also serves what `Ehosctl.HTTP` sends: a
  GitHub Actions job's exchange at the token endpoint, and what EHOS's API tells a terminal (eh-os
  `docs/terminal-api.md`):
  `GET /api/v1/me/roles` and `GET /api/v1/me/applications`, answering what `put_me/2` set to a
  credential it issued for EHOS's API, and `{"error", "message"}` otherwise; any other route of
  the API answers as a test says with `stub_api/4`. `resource/2` says
  which `resource` a credential was issued for.
  """

  @client_id "ehosctl"

  defstruct [:bypass, :http, :issuer, :jwk, :agent]

  @type t :: %__MODULE__{}

  @doc """
  Starts a provider. `opts` may set `:email` (`nil` for none), `:subject` and `:auth_time`.
  """
  @spec start(keyword()) :: t()
  def start(opts \\ []) do
    bypass = Bypass.open()
    issuer = "http://localhost:#{bypass.port}"
    jwk = JOSE.JWK.generate_key({:okp, :Ed25519})

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          codes: %{},
          refresh_tokens: MapSet.new(),
          requests: [],
          token_answer: nil,
          subject: Keyword.get(opts, :subject, "0b9f6c1e-person"),
          email: Keyword.get(opts, :email, "grace@example.com"),
          auth_time: Keyword.get(opts, :auth_time, System.os_time(:second)),
          id_token: %{},
          signing_jwk: nil,
          renewal_id_token: true,
          discovery: %{},
          on_revoke: nil,
          revoke_answer: nil,
          issued: %{},
          me: %{roles: [], applications: []},
          api_answer: nil,
          exchange_expires_in: 600
        }
      end)

    http = Ehosctl.FakeHTTP.open(origin: issuer)
    provider = %__MODULE__{bypass: bypass, http: http, issuer: issuer, jwk: jwk, agent: agent}
    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", &discovery(&1, provider))
    Bypass.stub(bypass, "GET", "/jwks", &jwks(&1, provider))
    Bypass.stub(bypass, "POST", "/oauth/token", &token(&1, provider))
    Bypass.stub(bypass, "POST", "/oauth/revoke", &revoke(&1, provider))
    # What `Ehosctl.HTTP` sends: EHOS's API, and a GitHub Actions job's exchange.
    Ehosctl.FakeHTTP.stub(http, "POST", "/oauth/token", &token(&1, provider))
    Ehosctl.FakeHTTP.stub(http, "GET", "/api/v1/me/roles", &me(&1, provider, :roles))

    Ehosctl.FakeHTTP.stub(
      http,
      "GET",
      "/api/v1/me/applications",
      &me(&1, provider, :applications)
    )

    # Endpoints a sign-in may have kept that EHOS no longer serves: one gone, one that redirects
    # to where the endpoint is now, and one served by something that refuses every token.
    for {path, answer} <- [
          {"/oauth/gone", &Plug.Conn.resp(&1, 404, "")},
          {"/oauth/moved",
           &(&1
             |> Plug.Conn.put_resp_header("location", issuer <> "/oauth/token")
             |> Plug.Conn.resp(308, ""))},
          {"/oauth/stale", &json(&1, 400, %{"error" => "invalid_grant"})}
        ] do
      Bypass.stub(bypass, "POST", path, fn conn ->
        {conn, params} = form(conn)
        Agent.update(provider.agent, &%{&1 | requests: [{path, params} | &1.requests]})
        answer.(conn)
      end)
    end

    provider
  end

  @doc """
  The requests sent to `path`, oldest first, as their decoded form bodies; an empty map for a GET
  of the discovery document or the JWKS.
  """
  @spec requests(t(), String.t()) :: [map()]
  def requests(provider, path) do
    provider.agent
    |> Agent.get(& &1.requests)
    |> Enum.reverse()
    |> Enum.flat_map(fn {request_path, params} ->
      if request_path == path, do: [params], else: []
    end)
  end

  @doc "The refresh tokens that are live."
  @spec refresh_tokens(t()) :: MapSet.t()
  def refresh_tokens(provider), do: Agent.get(provider.agent, & &1.refresh_tokens)

  @doc """
  Makes the token endpoint answer the next requests with `status` and `body` instead, until
  `answer_normally/1`.
  """
  @spec answer_token(t(), pos_integer(), map()) :: :ok
  def answer_token(provider, status, body),
    do: Agent.update(provider.agent, &%{&1 | token_answer: {status, body}})

  @doc "Makes the credentials the next token exchanges give expire after `seconds`."
  @spec exchange_expires_in(t(), pos_integer()) :: :ok
  def exchange_expires_in(provider, seconds),
    do: Agent.update(provider.agent, &%{&1 | exchange_expires_in: seconds})

  @doc "Makes the token endpoint answer as a provider does."
  @spec answer_normally(t()) :: :ok
  def answer_normally(provider),
    do: Agent.update(provider.agent, &%{&1 | token_answer: nil, api_answer: nil})

  @doc "Puts `claims` over those of the next ID tokens, as a provider that gets them wrong."
  @spec put_id_token_claims(t(), map()) :: :ok
  def put_id_token_claims(provider, claims),
    do: Agent.update(provider.agent, &%{&1 | id_token: claims})

  @doc "Calls `fun` when a revocation request arrives, before it is answered."
  @spec on_revoke(t(), (-> term())) :: :ok
  def on_revoke(provider, fun), do: Agent.update(provider.agent, &%{&1 | on_revoke: fun})

  @doc "Makes the revocation endpoint answer with `status` and `body` instead."
  @spec answer_revoke(t(), pos_integer(), map()) :: :ok
  def answer_revoke(provider, status, body),
    do: Agent.update(provider.agent, &%{&1 | revoke_answer: {status, body}})

  @doc """
  Puts `fields` over those of the discovery document, as a provider that gets them wrong; a field
  given as `:drop` is left out.
  """
  @spec put_discovery(t(), map()) :: :ok
  def put_discovery(provider, fields),
    do: Agent.update(provider.agent, &%{&1 | discovery: fields})

  @doc "Leaves the ID token out of the next renewals' answers, as OpenID Connect Core §12.2 allows."
  @spec renew_without_id_token(t()) :: :ok
  def renew_without_id_token(provider),
    do: Agent.update(provider.agent, &%{&1 | renewal_id_token: false})

  @doc "Signs the next ID tokens with a key the JWKS does not publish."
  @spec sign_with_another_key(t()) :: :ok
  def sign_with_another_key(provider),
    do:
      Agent.update(
        provider.agent,
        &%{&1 | signing_jwk: JOSE.JWK.generate_key({:okp, :Ed25519})}
      )

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

  @doc "Issues a refresh token that is live, as a sign-in that already happened."
  @spec issue_refresh_token(t()) :: String.t()
  def issue_refresh_token(provider) do
    token = new_refresh_token()
    Agent.update(provider.agent, &%{&1 | refresh_tokens: MapSet.put(&1.refresh_tokens, token)})
    token
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
    Ehosctl.FakeHTTP.stub(provider.http, method, path, fn conn ->
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

  @doc "Takes the provider down: nothing answers at its address."
  @spec down(t()) :: :ok
  def down(provider) do
    Ehosctl.FakeHTTP.down(provider.http)
    Bypass.down(provider.bypass)
  end

  defp discovery(conn, provider) do
    record(provider, "/.well-known/openid-configuration")

    issuer = provider.issuer

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
    |> Map.merge(Agent.get(provider.agent, & &1.discovery))
    |> Map.reject(fn {_field, value} -> value == :drop end)
    |> then(&json(conn, 200, &1))
  end

  defp jwks(conn, provider) do
    record(provider, "/jwks")

    {_fields, public} = provider.jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    key = Map.merge(public, %{"kid" => "key-1", "use" => "sig", "alg" => "Ed25519"})
    json(conn, 200, %{"keys" => [key]})
  end

  defp token(conn, provider) do
    {conn, params} = form(conn)
    Agent.update(provider.agent, &%{&1 | requests: [{"/oauth/token", params} | &1.requests]})

    case Agent.get(provider.agent, & &1.token_answer) do
      {status, body} -> answer(conn, provider, status, body)
      nil -> grant(conn, provider, params)
    end
  end

  # A GitHub Actions job's exchange (eh-os D-110): no client authentication, and a subject token
  # the fake GitHub token service gave for this issuer, `github:<audience>:<n>`.
  defp grant(
         conn,
         provider,
         %{"grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange"} = params
       ) do
    expected = %{
      "client_id" => "github-actions",
      "subject_token_type" => "urn:ietf:params:oauth:token-type:id_token",
      "audience" => "ehos"
    }

    if Map.take(params, Map.keys(expected)) == expected and
         String.starts_with?(params["subject_token"] || "", "github:#{provider.issuer}:") do
      credential = "ci-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
      Agent.update(provider.agent, &put_in(&1, [:issued, credential], provider.issuer))

      json(conn, 200, %{
        "access_token" => credential,
        "issued_token_type" => "urn:ietf:params:oauth:token-type:access_token",
        "token_type" => "Bearer",
        "expires_in" => Agent.get(provider.agent, & &1.exchange_expires_in)
      })
    else
      json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  # A public client: its client_id, and no secret or assertion.
  defp grant(conn, provider, params) do
    if params["client_id"] == @client_id and not is_map_key(params, "client_secret") and
         not is_map_key(params, "client_assertion"),
       do: granted(conn, provider, params),
       else: json(conn, 401, %{"error" => "invalid_client"})
  end

  defp granted(conn, provider, %{"grant_type" => "authorization_code"} = params) do
    code =
      Agent.get_and_update(provider.agent, fn state ->
        {state.codes[params["code"]], update_in(state.codes, &Map.delete(&1, params["code"]))}
      end)

    challenge =
      Base.url_encode64(:crypto.hash(:sha256, params["code_verifier"] || ""), padding: false)

    if code && code.challenge == challenge && code.redirect_uri == params["redirect_uri"] do
      json(conn, 200, tokens(provider, %{"nonce" => code.nonce}, provider.issuer))
    else
      json(conn, 400, %{"error" => "invalid_grant", "error_description" => "the code is invalid"})
    end
  end

  defp granted(
         conn,
         provider,
         %{"grant_type" => "refresh_token", "refresh_token" => presented} = params
       ) do
    resource = params["resource"] || provider.issuer

    live? =
      Agent.get_and_update(provider.agent, fn state ->
        {MapSet.member?(state.refresh_tokens, presented),
         %{state | refresh_tokens: MapSet.delete(state.refresh_tokens, presented)}}
      end)

    tokens =
      if Agent.get(provider.agent, & &1.renewal_id_token),
        do: tokens(provider, %{}, resource),
        else: provider |> tokens(%{}, resource) |> Map.delete("id_token")

    if live?,
      do: json(conn, 200, tokens),
      else: json(conn, 400, %{"error" => "invalid_grant", "error_description" => "reused"})
  end

  defp granted(conn, _provider, _params),
    do: json(conn, 400, %{"error" => "unsupported_grant_type"})

  defp tokens(provider, claims, resource) do
    refresh = new_refresh_token()
    state = Agent.get(provider.agent, & &1)
    Agent.update(provider.agent, &%{&1 | refresh_tokens: MapSet.put(&1.refresh_tokens, refresh)})
    now = System.os_time(:second)

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

    {_fields, id_token} =
      (state.signing_jwk || provider.jwk)
      |> JOSE.JWT.sign(%{"alg" => "Ed25519", "kid" => "key-1"}, claims)
      |> JOSE.JWS.compact()

    credential = "credential-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
    Agent.update(provider.agent, &put_in(&1, [:issued, credential], resource))

    %{
      "access_token" => credential,
      "token_type" => "Bearer",
      "expires_in" => 600,
      "refresh_token" => refresh,
      "id_token" => id_token,
      "scope" => "openid email"
    }
  end

  # EHOS's API: a credential it issued for itself, else refusals.md's `{"error", "message"}`.
  defp me(conn, provider, what) do
    record(provider, conn.request_path)

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

  defp revoke(conn, provider) do
    {conn, params} = form(conn)

    Agent.update(provider.agent, fn state ->
      %{
        state
        | requests: [{"/oauth/revoke", params} | state.requests],
          refresh_tokens: MapSet.delete(state.refresh_tokens, params["token"])
      }
    end)

    state = Agent.get(provider.agent, & &1)
    if state.on_revoke, do: state.on_revoke.()

    case state.revoke_answer do
      {status, body} -> answer(conn, provider, status, body)
      nil -> json(conn, 200, %{})
    end
  end

  # A redirect points elsewhere on the provider, where nothing answers as the endpoint did.
  defp answer(conn, provider, status, body) when status in 300..399,
    do:
      conn
      |> Plug.Conn.put_resp_header("location", provider.issuer <> "/elsewhere")
      |> json(status, body)

  defp answer(conn, _provider, status, body), do: json(conn, status, body)

  defp record(provider, path),
    do: Agent.update(provider.agent, &%{&1 | requests: [{path, %{}} | &1.requests]})

  defp form(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {conn, URI.decode_query(body)}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end

  defp new_refresh_token, do: "refresh-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
end

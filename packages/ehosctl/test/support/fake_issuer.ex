defmodule Ehosctl.FakeIssuer do
  @moduledoc """
  EHOS's provider on a local port, for the tests of `Ehosctl.SignInImpl`, the one module that
  talks to it: its discovery document, JWKS, token endpoint, revocation endpoint and, when a test
  names it, pushed authorization request endpoint, with ID
  tokens signed by an Ed25519 key, as EHOS signs them (eh-os D-64). Every other test signs in
  through `Ehosctl.FakeProvider`, which answers in its place.

  It answers over https, as EHOS does, at `https://localhost:<port>` on this machine alone, with a
  certificate for `localhost` and `127.0.0.1` from a CA of the tests' own, which every provider
  started in the run shares: a test that needs two CAs cannot have them from two providers.
  `opts/1` gives the CA as `:ca`, as `ehosctl login` keeps one for an installation (T-14), so
  `ehosctl` needs no way to talk to a provider over plain HTTP.

  It keeps what a provider would: the codes it issued with their PKCE challenge and `nonce`, and
  the refresh tokens that are live, each rotated on use, so a token used twice is refused. Every
  request it is sent is kept, for the tests to read (`requests/2`). `authorize/2` plays the
  person's browser: it signs in at once and returns the code.
  """

  @behaviour Plug

  @client_id "ehosctl"

  defstruct [:ref, :issuer, :ca, :jwk, :agent]

  @type t :: %__MODULE__{}

  @doc """
  Starts a provider. `opts` may set `:email` (`nil` for none), `:subject` and `:auth_time`.
  """
  @spec start(keyword()) :: t()
  def start(opts \\ []) do
    {tls, ca} = certificate()
    ref = make_ref()
    jwk = JOSE.JWK.generate_key({:okp, :Ed25519})

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          routes: %{},
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
          revoke_answer: nil
        }
      end)

    {:ok, _pid} =
      Plug.Cowboy.https(
        __MODULE__,
        [agent: agent],
        [ref: ref, ip: {127, 0, 0, 1}, port: 0] ++ tls
      )

    ExUnit.Callbacks.on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    issuer = "https://localhost:#{:ranch.get_port(ref)}"

    provider = %__MODULE__{ref: ref, issuer: issuer, ca: ca, jwk: jwk, agent: agent}
    route(provider, "GET", "/.well-known/openid-configuration", &discovery(&1, provider))
    route(provider, "GET", "/jwks", &jwks(&1, provider))
    route(provider, "POST", "/oauth/token", &token(&1, provider))
    route(provider, "POST", "/oauth/revoke", &revoke(&1, provider))
    # A pushed authorization request endpoint (RFC 9126), which discovery names only when a test
    # puts it there (`put_discovery/2`).
    route(provider, "POST", "/oauth/par", &push(&1, provider))

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
      route(provider, "POST", path, fn conn ->
        {conn, params} = form(conn)
        Agent.update(provider.agent, &%{&1 | requests: [{path, params} | &1.requests]})
        answer.(conn)
      end)
    end

    provider
  end

  @doc "The options that make `Ehosctl.SignInImpl` trust the provider's CA: `:ca`, as kept."
  @spec opts(t()) :: keyword()
  def opts(provider), do: [ca: {"local", provider.ca}]

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :agent)

  # A request reaches the route for its method and path, and nothing else answers it.
  @impl Plug
  def call(conn, agent) do
    plug = Agent.get(agent, &Map.fetch!(&1.routes, {conn.method, conn.request_path}))

    # A connection per request: `:httpc` would send the next one over a connection an earlier
    # request opened, whose TLS options were checked then, and hide a request made without them.
    conn
    |> plug.()
    |> Plug.Conn.put_resp_header("connection", "close")
    |> Plug.Conn.send_resp()
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

  @doc "Makes the token endpoint answer as a provider does."
  @spec answer_normally(t()) :: :ok
  def answer_normally(provider),
    do: Agent.update(provider.agent, &%{&1 | token_answer: nil})

  @doc "Puts `claims` over those of the next ID tokens, as a provider that gets them wrong."
  @spec put_id_token_claims(t(), map()) :: :ok
  def put_id_token_claims(provider, claims),
    do: Agent.update(provider.agent, &%{&1 | id_token: claims})

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
  Signs the person in at the authorization URL `url`, as EHOS would, and returns the code it
  issued for it, with the PKCE challenge, `nonce` and redirect URI it names.
  """
  @spec authorize(t(), String.t()) :: String.t()
  def authorize(provider, url) do
    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    code = "code-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))

    Agent.update(provider.agent, fn state ->
      put_in(state, [:codes, code], %{
        challenge: params["code_challenge"],
        nonce: params["nonce"],
        redirect_uri: params["redirect_uri"]
      })
    end)

    code
  end

  @doc "Issues a refresh token that is live, as a sign-in that already happened."
  @spec issue_refresh_token(t()) :: String.t()
  def issue_refresh_token(provider) do
    token = new_refresh_token()
    Agent.update(provider.agent, &%{&1 | refresh_tokens: MapSet.put(&1.refresh_tokens, token)})
    token
  end

  @doc "Takes the provider down: nothing answers on its port."
  @spec down(t()) :: :ok
  def down(provider), do: Plug.Cowboy.shutdown(provider.ref)

  defp route(provider, method, path, plug),
    do: Agent.update(provider.agent, &put_in(&1, [:routes, {method, path}], plug))

  @doc """
  Makes the certificate and CA every provider of the run serves, once, from `test_helper.exs`,
  before any test runs: its RSA keys take a tenth of a second.
  """
  @spec make_certificate() :: :ok
  def make_certificate, do: :persistent_term.put({__MODULE__, :certificate}, new_certificate())

  defp certificate, do: :persistent_term.get({__MODULE__, :certificate})

  # The server's certificate, for `localhost` and `127.0.0.1`, and the CA that signed it, as PEM.
  defp new_certificate do
    san =
      {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost", iPAddress: <<127, 0, 0, 1>>]}

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65_537}, digest: :sha256],
          intermediates: [],
          peer: [key: {:rsa, 2048, 65_537}, digest: :sha256, extensions: [san]]
        },
        client_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          intermediates: [],
          peer: [key: {:rsa, 2048, 65_537}]
        }
      })

    ca =
      :public_key.pem_encode(for der <- client[:cacerts], do: {:Certificate, der, :not_encrypted})

    {Keyword.take(server, [:cert, :key, :cacerts]) ++ [log_level: :none], ca}
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
      json(conn, 200, tokens(provider, %{"nonce" => code.nonce}))
    else
      json(conn, 400, %{"error" => "invalid_grant", "error_description" => "the code is invalid"})
    end
  end

  defp granted(
         conn,
         provider,
         %{"grant_type" => "refresh_token", "refresh_token" => presented}
       ) do
    live? =
      Agent.get_and_update(provider.agent, fn state ->
        {MapSet.member?(state.refresh_tokens, presented),
         %{state | refresh_tokens: MapSet.delete(state.refresh_tokens, presented)}}
      end)

    tokens =
      if Agent.get(provider.agent, & &1.renewal_id_token),
        do: tokens(provider, %{}),
        else: provider |> tokens(%{}) |> Map.delete("id_token")

    if live?,
      do: json(conn, 200, tokens),
      else: json(conn, 400, %{"error" => "invalid_grant", "error_description" => "reused"})
  end

  defp granted(conn, _provider, _params),
    do: json(conn, 400, %{"error" => "unsupported_grant_type"})

  defp tokens(provider, claims) do
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

    %{
      "access_token" => credential,
      "token_type" => "Bearer",
      "expires_in" => 600,
      "refresh_token" => refresh,
      "id_token" => id_token,
      "scope" => "openid email"
    }
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

  defp push(conn, provider) do
    {conn, params} = form(conn)
    Agent.update(provider.agent, &%{&1 | requests: [{"/oauth/par", params} | &1.requests]})

    json(conn, 201, %{
      "request_uri" => "urn:ietf:params:oauth:request_uri:pushed",
      "expires_in" => 60
    })
  end

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

defmodule Ehosctl.GitHubActions do
  @moduledoc """
  A credential for EHOS's API in a GitHub Actions job, from the job's own token, with no sign-in
  and no stored secret (T-18, eh-os
  [D-110](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0110-a-pipeline-deploys-as-its-application-s-deployment-identity-trusted-per-github-repository-exchanging-github-actions-token-for-a-credential-that-reaches-only-ephemeral-environments.md),
  [`docs/deployment-identity-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/deployment-identity-api.md#the-exchange)).

  It is used for the installation `EHOSCTL_URL` names (`Ehosctl.Config.select/4`), and only there:

    1. EHOS's discovery document gives its issuer and token endpoint
       (`Ehosctl.SignIn.discovered_endpoints/2`).
    2. GitHub is asked for the job's token, whose audience is that issuer, at
       `ACTIONS_ID_TOKEN_REQUEST_URL` with `ACTIONS_ID_TOKEN_REQUEST_TOKEN`, which GitHub sets in
       a job with `permissions: id-token: write`.
    3. The token is exchanged at the token endpoint (RFC 8693), with `client_id=github-actions`,
       `audience=ehos`, and, when the command names its application (`opts[:application]`),
       `resource=<issuer>/api/v1/applications/<application>`, which of the repository's trusts
       is meant.

  The credential is kept in the calling process, and nowhere else, until thirty seconds before it
  expires; after that a fresh GitHub token is exchanged, since there is no refresh token. A refusal
  is `invalid_grant` with no detail, and is said with the causes a person can fix; the reason is in
  EHOS's audit record.
  """

  alias Ehosctl.Api
  alias Ehosctl.HTTP
  alias Ehosctl.Refusal
  alias Ehosctl.SignIn

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @id_token "urn:ietf:params:oauth:token-type:id_token"

  # As a sign-in's cached credential is used (`Ehosctl.Credentials`).
  @margin_seconds 30
  # GitHub's token service's answer, a JWT of a few kilobytes. EHOS's answer to the exchange is
  # read as every answer of EHOS's API is (`Ehosctl.HTTP.request/5`).
  @max_bytes 64 * 1024

  @type error :: {:error, Ehosctl.Output.kind(), String.t()}

  @doc """
  Whether `env` is a GitHub Actions job's that GitHub gives a token to: both
  `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_ID_TOKEN_REQUEST_TOKEN` are set.

      iex> Ehosctl.GitHubActions.job?(%{"ACTIONS_ID_TOKEN_REQUEST_URL" => "u", "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t"})
      true

      iex> Ehosctl.GitHubActions.job?(%{"GITHUB_ACTIONS" => "true"})
      false
  """
  @spec job?(%{String.t() => String.t()}) :: boolean()
  def job?(env),
    do:
      present?(env["ACTIONS_ID_TOKEN_REQUEST_URL"]) and
        present?(env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"])

  @doc """
  A credential for EHOS's API at `installation`, by exchanging the job's token, or the one this
  process already has while it has more than thirty seconds left. `opts[:instead_of]` names a
  credential EHOS has said is expired, which is not given again. Takes the options a command is
  handed: `:env`, `:ca`, `:application`, `:timeout`, and `:allow_http` for the tests.

  A credential for an application is refused before anything is sent: no application accepts a
  deployment identity's.
  """
  @spec credential({String.t(), map()}, :ehos | String.t(), keyword()) ::
          {:ok, String.t()} | error()
  def credential({_name, installation}, :ehos, opts) do
    url = installation["url"]
    key = {__MODULE__, url, opts[:application]}

    instead_of = opts[:instead_of]

    case Process.get(key) do
      %{token: token, expires_at: expires_at} when token != instead_of ->
        if DateTime.diff(expires_at, DateTime.utc_now()) > @margin_seconds,
          do: {:ok, token},
          else: exchanged(key, url, opts)

      _none ->
        exchanged(key, url, opts)
    end
  end

  def credential(_installation, _resource, _opts),
    do:
      {:error, :refused,
       "A GitHub Actions job's credential reaches EHOS's API alone: no application accepts it " <>
         "(eh-os D-110)."}

  defp exchanged(key, url, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    with :ok <- in_a_job(env, url),
         :ok <- token_service(env["ACTIONS_ID_TOKEN_REQUEST_URL"], opts),
         {:ok, endpoints} <- SignIn.discovered_endpoints(url, opts),
         {:ok, github_token} <- github_token(endpoints.issuer, env, opts),
         {:ok, token, expires_in} <- exchange(endpoints, github_token, opts) do
      Process.put(key, %{token: token, expires_at: DateTime.add(DateTime.utc_now(), expires_in)})
      {:ok, token}
    end
  end

  defp in_a_job(env, url) do
    cond do
      job?(env) ->
        :ok

      env["GITHUB_ACTIONS"] == "true" ->
        {:error, :not_signed_in,
         "EHOSCTL_URL names #{url}, and GitHub gives this job no token: give the job " <>
           "`permissions: id-token: write` (T-18)."}

      true ->
        {:error, :not_signed_in,
         "EHOSCTL_URL names #{url}, which ehosctl talks to only from a GitHub Actions job, with " <>
           "the job's own token (T-18). On a terminal, unset EHOSCTL_URL and sign in with " <>
           "`ehosctl login #{url}`."}
    end
  end

  # The request token is sent there, so never in clear: https, or http for the tests alone.
  defp token_service(url, opts) do
    schemes = if opts[:allow_http], do: ["https", "http"], else: ["https"]

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(host) and host != "" ->
        if scheme in schemes,
          do: :ok,
          else:
            {:error, :failed,
             "ACTIONS_ID_TOKEN_REQUEST_URL is not https; ehosctl sends it nothing."}

      _other ->
        {:error, :failed,
         "ACTIONS_ID_TOKEN_REQUEST_URL is not an address; ehosctl sends it nothing."}
    end
  end

  # GitHub's token service, on GitHub's host: trusted through the system's CAs alone, never with
  # a CA given for an installation, and sent only the request token GitHub set for it.
  defp github_token(issuer, env, opts) do
    request_url = env["ACTIONS_ID_TOKEN_REQUEST_URL"]
    separator = if String.contains?(request_url, "?"), do: "&", else: "?"
    url = request_url <> separator <> URI.encode_query(%{"audience" => issuer})

    headers = [
      {"authorization", "Bearer " <> String.trim(env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"])},
      {"accept", "application/json"}
    ]

    get_opts =
      opts
      |> Keyword.delete(:ca)
      |> Keyword.merge(
        env: Map.delete(env, "EHOSCTL_CA_FILE"),
        max_bytes: @max_bytes,
        installation?: false
      )

    case HTTP.get(url, headers, get_opts) do
      {:ok, %{status: 200, body: body}} ->
        case JSON.decode(body) do
          {:ok, %{"value" => token}} when is_binary(token) and token != "" -> {:ok, token}
          _other -> {:error, :failed, "GitHub's token service answered something unreadable."}
        end

      {:ok, %{status: status}} ->
        {:error, :failed,
         "GitHub's token service refused to give this job a token (HTTP #{status}): the job " <>
           "needs `permissions: id-token: write`."}

      error ->
        error
    end
  end

  defp exchange(endpoints, github_token, opts) do
    params =
      [
        {"grant_type", @grant},
        {"client_id", "github-actions"},
        {"subject_token", github_token},
        {"subject_token_type", @id_token},
        {"audience", "ehos"}
      ] ++
        case opts[:application] do
          nil -> []
          app -> [{"resource", resource(endpoints.issuer, app)}]
        end

    body = {:raw, "application/x-www-form-urlencoded", URI.encode_query(params)}

    case HTTP.request(
           :post,
           endpoints.token,
           nil,
           body,
           Keyword.take(opts, [:env, :ca, :timeout])
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}}
      when is_binary(token) and token != "" and is_integer(expires_in) and expires_in > 0 ->
        {:ok, token, expires_in}

      {:ok, %{status: 400, body: %{"error" => "invalid_grant"}}} ->
        {:error, :refused, refused(endpoints.issuer, opts[:application])}

      {:ok, %{status: 429}} ->
        {:error, :unreachable,
         "EHOS is limiting this repository's exchanges, 60 a minute: try again in a minute."}

      {:ok, %{status: status, body: %{"error" => code}}} when is_binary(code) ->
        {:error, :failed,
         "EHOS refused the exchange of this job's token as #{Refusal.shown(code)} " <>
           "(HTTP #{status}); this ehosctl may be older than the installation."}

      {:ok, %{status: status}} ->
        {:error, :failed, "#{endpoints.issuer} answered the exchange with HTTP #{status}."}

      {:error, kind, message, :sent} ->
        {:error, kind, message}

      error ->
        error
    end
  end

  defp resource(issuer, app),
    do: "#{issuer}/api/v1/applications/#{Api.segment(app)}"

  defp refused(issuer, application) do
    trusted =
      case application do
        nil ->
          "the repository trusted by exactly one application"

        app ->
          "the repository trusted for #{Refusal.shown(app)}, an application of that name " <>
            "(`ehosctl trust list --app #{Refusal.shown(app)}`)"
      end

    "#{issuer} refused this job's GitHub Actions token. Why is in its audit record, as a refused " <>
      "deployment_identity.exchange. A job is accepted with #{trusted}; a ref, environment, " <>
      "workflow and event the trust accepts; and the GitHub account that started the run linked " <>
      "to a person who may deploy there (`ehosctl github claim`)."
  end

  defp present?(value), do: value not in [nil, ""]
end

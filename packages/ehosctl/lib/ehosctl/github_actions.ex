defmodule Ehosctl.GitHubActions do
  @moduledoc """
  A credential for EHOS's API in a GitHub Actions job, from the job's own token, with no sign-in
  and no stored secret (T-18, eh-os
  [D-110](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0110-a-pipeline-deploys-as-its-application-s-deployment-identity-trusted-per-github-repository-exchanging-github-actions-token-for-a-credential-that-reaches-only-ephemeral-environments.md),
  [`docs/deployment-identity-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/deployment-identity-api.md#the-exchange)).

  It is used for the installation `EHOSCTL_URL` names (`Ehosctl.Config.select/3`), and only there:

    1. EHOS's discovery document gives its issuer and token endpoint
       (`c:Ehosctl.SignIn.discovered_endpoints/2`).
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
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.SignIn
  alias EhosPlatform.Shell

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @id_token "urn:ietf:params:oauth:token-type:id_token"

  # As a sign-in's cached credential is used (`Ehosctl.Credentials`).
  @margin_seconds 30
  # GitHub's token service's answer, a JWT of a few kilobytes. EHOS's answer to the exchange is
  # read as every answer of EHOS's API is (`c:Ehosctl.HTTP.request/5`).
  @max_bytes 64 * 1024

  @type error :: {:error, Ehosctl.Output.kind(), Ehosctl.Failure.message()}

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
  handed: `:ca`, `:application` and `:timeout`.

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
        if DateTime.diff(expires_at, Ehosctl.Clock.current().now()) > @margin_seconds,
          do: {:ok, token},
          else: exchanged(key, url, opts)

      _none ->
        exchanged(key, url, opts)
    end
  end

  def credential(_installation, _resource, _opts),
    do:
      {:error, :refused,
       "The credential of a GitHub Actions job reaches only the API of EHOS. No application " <>
         "accepts it."}

  defp exchanged(key, url, opts) do
    env = Ehosctl.SystemEnv.current().all()

    with :ok <- in_a_job(env, url),
         :ok <- token_service(env["ACTIONS_ID_TOKEN_REQUEST_URL"]),
         {:ok, endpoints} <- SignIn.current().discovered_endpoints(url, opts),
         {:ok, github_token} <- github_token(endpoints.issuer, env, opts),
         {:ok, token, expires_in} <- exchange(endpoints, github_token, opts) do
      Process.put(key, %{
        token: token,
        expires_at: DateTime.add(Ehosctl.Clock.current().now(), expires_in)
      })

      {:ok, token}
    end
  end

  defp in_a_job(env, url) do
    cond do
      job?(env) ->
        :ok

      env["GITHUB_ACTIONS"] == "true" ->
        {:error, :not_signed_in,
         "EHOSCTL_URL names #{url}, but GitHub gives this job no token. Give the job " <>
           "`permissions: id-token: write`."}

      true ->
        {:error, :not_signed_in,
         "EHOSCTL_URL names #{url}. ehosctl uses this address only in a GitHub Actions job, " <>
           "with the token of the job." <>
           Output.offered(
             [
               " On a terminal, unset EHOSCTL_URL and run ",
               {:command, "ehosctl login #{Shell.word(url)}"},
               "."
             ],
             " On a terminal, unset EHOSCTL_URL and run `ehosctl login` with the address."
           )}
    end
  end

  # The request token is sent there, so never in clear: https only.
  defp token_service(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(host) and host != "" ->
        if scheme == "https",
          do: :ok,
          else:
            {:error, :failed,
             "ACTIONS_ID_TOKEN_REQUEST_URL is not an https address, so ehosctl sends it nothing."}

      _other ->
        {:error, :failed,
         "ACTIONS_ID_TOKEN_REQUEST_URL is not an address, so ehosctl sends it nothing."}
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

    # GitHub's host is trusted through the system's CAs alone, neither EHOSCTL_CA_FILE nor the CA
    # kept for an installation.
    get_opts =
      opts
      |> Keyword.delete(:ca)
      |> Keyword.merge(max_bytes: @max_bytes, installation?: false)

    case HTTP.current().get(url, headers, get_opts) do
      {:ok, %{status: 200, body: body}} ->
        case JSON.decode(body) do
          {:ok, %{"value" => token}} when is_binary(token) and token != "" ->
            {:ok, token}

          _other ->
            {:error, :failed,
             "The token service of GitHub gave an answer that ehosctl cannot read."}
        end

      {:ok, %{status: status}} ->
        {:error, :failed,
         "The token service of GitHub refused to give this job a token (HTTP #{status}). Give " <>
           "the job `permissions: id-token: write`."}

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
      ] ++ resource_param(endpoints, opts[:application])

    body = {:raw, "application/x-www-form-urlencoded", URI.encode_query(params)}

    :post
    |> HTTP.current().request(endpoints.token, nil, body, Keyword.take(opts, [:ca, :timeout]))
    |> exchange_answered(endpoints, opts)
  end

  defp resource_param(_endpoints, nil), do: []
  defp resource_param(endpoints, app), do: [{"resource", resource(endpoints.issuer, app)}]

  defp exchange_answered(
         {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}},
         _endpoints,
         _opts
       )
       when is_binary(token) and token != "" and is_integer(expires_in) and expires_in > 0,
       do: {:ok, token, expires_in}

  defp exchange_answered(
         {:ok, %{status: 400, body: %{"error" => "invalid_grant"}}},
         endpoints,
         opts
       ),
       do: {:error, :refused, refused(endpoints.issuer, opts[:application])}

  defp exchange_answered({:ok, %{status: 429}}, _endpoints, _opts),
    do:
      {:error, :unreachable,
       "EHOS limits the exchanges of this repository to 60 a minute. Try again in a minute."}

  defp exchange_answered({:ok, %{status: status, body: %{"error" => code}}}, _endpoints, _opts)
       when is_binary(code),
       do:
         {:error, :failed,
          "EHOS refused the exchange of the token of this job as #{Refusal.shown(code)} " <>
            "(HTTP #{status}). This ehosctl can be older than the installation."}

  defp exchange_answered({:ok, %{status: status}}, endpoints, _opts),
    do: {:error, :failed, "#{endpoints.issuer} answered the exchange with HTTP #{status}."}

  defp exchange_answered({:error, _kind, _message, :sent} = unanswered, _endpoints, _opts),
    do: HTTP.unanswered_read(unanswered)

  defp exchange_answered(error, _endpoints, _opts), do: error

  defp resource(issuer, app),
    do: "#{issuer}/api/v1/applications/#{Api.segment(app)}"

  defp refused(issuer, application) do
    trusted =
      case application do
        nil ->
          "a repository that exactly one application trusts"

        app ->
          "a repository that #{Refusal.shown(app)} trusts, an application of that name" <>
            Output.offered([
              " (",
              {:command, "ehosctl trusts list --app #{Shell.word(app)}"},
              ")"
            ])
      end

    # The opening sentence is what ehos_app's CI workflow matches to tell this refusal from any
    # other failure: it stays as it is. The cause a new developer meets first comes first.
    "#{issuer} refused this job's GitHub Actions token. Its audit record says why, as a " <>
      "refused deployment_identity.exchange. The most frequent cause: the GitHub account that " <>
      "started the run is not linked to a person in EHOS yet. Then the owner of the account " <>
      "runs `ehosctl github list`, then `ehosctl github claim RUN`. Another person who holds " <>
      "ehos.people.manage checks with the owner that the run is theirs, and runs " <>
      "`ehosctl people github confirm`. If only one person holds it, that person confirms " <>
      "their own. Other causes: EHOS accepts a job only with #{trusted}, with a ref, " <>
      "environment, workflow and event that the trust accepts, and with a linked account " <>
      "whose person can deploy there."
  end

  defp present?(value), do: value not in [nil, ""]
end

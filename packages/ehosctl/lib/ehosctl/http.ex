defmodule Ehosctl.HTTP do
  @moduledoc """
  A request that carries a credential, to EHOS's API or to an application, and what it means when
  no answer came.

  Every request is made with `Ehosctl.SignIn.request_opts/2`'s options: a timeout, and for
  `https` hostname checking and the CA certificates `EHOSCTL_CA_FILE` adds to the system's. A
  redirect is never followed, since it would send the credential on to wherever it points.
  """

  @typedoc "An answer: its status, its headers with lowercase names, and its body as JSON."
  @type answer :: %{status: pos_integer(), headers: %{String.t() => String.t()}, body: term()}

  @doc """
  Sends `method` to `url` with `credential` as a bearer token, and `body`, when not `nil`, as
  JSON. Returns the answer, with a body that is not JSON as `nil`, or an error of a kind
  (`t:Ehosctl.Output.kind/0`): `:unreachable` when nothing answered in time, `:failed` when the TLS
  handshake failed or the answer was a redirect.

  `opts` may name `:env`, read for `EHOSCTL_CA_FILE`, and `:headers`, sent besides.
  """
  @spec request(:get | :post, String.t(), String.t(), term(), keyword()) ::
          {:ok, answer()} | {:error, Ehosctl.Output.kind(), String.t()}
  def request(method, url, credential, body, opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    origin = origin(url)

    headers =
      [{"authorization", "Bearer " <> credential}, {"accept", "application/json"}] ++
        Keyword.get(opts, :headers, [])

    headers = for {name, value} <- headers, do: {String.to_charlist(name), value}

    with {:ok, request_opts} <- Ehosctl.SignIn.request_opts(url, env) do
      http_options =
        [timeout: request_opts.timeout, autoredirect: false] ++
          if ssl = request_opts[:ssl], do: [ssl: ssl], else: []

      request =
        case {method, body} do
          {:get, _body} ->
            {String.to_charlist(url), headers}

          {:post, body} ->
            {String.to_charlist(url), headers, ~c"application/json",
             JSON.encode!(if(is_nil(body), do: %{}, else: body))}
        end

      case :httpc.request(method, request, http_options, body_format: :binary) do
        {:ok, {{_version, status, _reason}, _headers, _body}} when status in 300..399 ->
          {:error, :failed,
           "#{origin} redirected a request that carries your credential; ehosctl did not follow"}

        {:ok, {{_version, status, _reason}, headers, body}} ->
          {:ok,
           %{
             status: status,
             headers: Map.new(headers, fn {name, value} -> {lower(name), to_string(value)} end),
             body: decode(body)
           }}

        {:error, reason} ->
          transport_error(reason, origin)
      end
    end
  end

  defp lower(name), do: name |> to_string() |> String.downcase()

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        URI.to_string(%URI{scheme: scheme, host: host, port: port})

      _ ->
        url
    end
  end

  @doc """
  Why a request to `where` got no answer, from what `:httpc` said: a TLS handshake that failed,
  of kind `:failed`, or no answer at all, of kind `:unreachable`.
  """
  @spec transport_error(term(), String.t()) :: {:error, Ehosctl.Output.kind(), String.t()}
  def transport_error(reason, where),
    do: if(tls_alert(reason), do: untrusted(where, reason), else: unreachable(where))

  @doc "`where` did not answer: an error of kind `:unreachable`."
  @spec unreachable(String.t()) :: {:error, :unreachable, String.t()}
  def unreachable(where), do: {:error, :unreachable, "#{where} did not answer."}

  @doc "The TLS handshake with `where` failed, with the alert in `reason`: of kind `:failed`."
  @spec untrusted(String.t(), term()) :: {:error, :failed, String.t()}
  def untrusted(where, reason),
    do:
      {:error, :failed,
       "the TLS handshake with #{where} failed (#{tls_alert(reason)}). For a local EHOS whose " <>
         "CA this machine does not trust, set EHOSCTL_CA_FILE to that CA's certificate."}

  @doc """
  The alert of a TLS handshake that failed, which `:httpc` reports inside its connection error,
  or `nil`: most often `unknown_ca`, a certificate this machine does not trust.
  """
  @spec tls_alert(term()) :: atom() | nil
  def tls_alert({:tls_alert, {alert, _description}}) when is_atom(alert), do: alert
  def tls_alert({:tls_alert, _alert}), do: :tls_alert
  def tls_alert(term) when is_tuple(term), do: term |> Tuple.to_list() |> tls_alert()
  def tls_alert(term) when is_list(term), do: Enum.find_value(term, &tls_alert/1)
  def tls_alert(_term), do: nil

  @doc "Whether `:httpc`'s `reason` means that no answer came: no connection, or none in time."
  @spec network?(term()) :: boolean()
  def network?({:failed_connect, _}), do: true
  def network?(:timeout), do: true
  def network?(:socket_closed_remotely), do: true
  def network?({:shutdown, _}), do: true

  def network?(reason) when reason in [:econnrefused, :nxdomain, :ehostunreach, :closed],
    do: true

  def network?(_reason), do: false
end

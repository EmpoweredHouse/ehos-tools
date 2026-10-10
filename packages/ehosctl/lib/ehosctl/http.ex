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
  JSON, or, as `{:raw, content_type, bytes}`, as those bytes, unchanged. Returns the answer, with
  a body that is not JSON as `nil`, or an error of a kind (`t:Ehosctl.Output.kind/0`): `:failed` for a redirect, a TLS handshake that failed, or a header
  value holding a line break or non-ASCII, which is never sent; `:unreachable` when the
  connection could not be made. `{:error, :unreachable, message, :sent}` when the connection was
  made and no answer HTTP can read came: the request may have been done.

  `opts` may name `:env`, read for `EHOSCTL_CA_FILE`, and `:headers`, sent besides.
  """
  @spec request(:get | :post | :patch, String.t(), String.t(), term(), keyword()) ::
          {:ok, answer()}
          | {:error, Ehosctl.Output.kind(), String.t()}
          | {:error, :unreachable, String.t(), :sent}
  def request(method, url, credential, body, opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    origin = origin(url)

    headers =
      [{"authorization", "Bearer " <> credential}, {"accept", "application/json"}] ++
        Keyword.get(opts, :headers, [])

    with true <-
           Enum.all?(headers, fn {_name, value} -> header?(value) end) ||
             {:error, :failed, "ehosctl will not send a header holding a line break or non-ASCII"},
         headers = for({name, value} <- headers, do: {String.to_charlist(name), value}),
         {:ok, request_opts} <- Ehosctl.SignIn.request_opts(url, env) do
      http_options =
        [timeout: request_opts.timeout, autoredirect: false] ++
          if ssl = request_opts[:ssl], do: [ssl: ssl], else: []

      request =
        case {method, body} do
          {:get, _body} ->
            {String.to_charlist(url), headers}

          {_method, {:raw, content_type, bytes}} ->
            {String.to_charlist(url), headers, String.to_charlist(content_type), bytes}

          {_method, body} ->
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
          no_answer(reason, origin)
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

  # Only a handshake that failed or a connection that was never made means the request was not
  # sent. Anything else, a timeout, a closed socket, an answer that is not HTTP, may come after
  # the application did it, so it is `:sent`.
  defp no_answer(reason, where) do
    cond do
      tls_alert(reason) -> untrusted(where, reason)
      connect_failed?(reason) -> unreachable(where)
      true -> Tuple.insert_at(unreachable(where), 3, :sent)
    end
  end

  # A header value is sent as it is, so one that could end the header, or that is not ASCII, is
  # never sent: the credential included, which comes from EHOS.
  defp header?(value), do: is_binary(value) and value =~ ~r/\A[\x20-\x7E]*\z/

  defp connect_failed?({:failed_connect, _}), do: true
  defp connect_failed?(reason), do: reason in [:econnrefused, :nxdomain, :ehostunreach]

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

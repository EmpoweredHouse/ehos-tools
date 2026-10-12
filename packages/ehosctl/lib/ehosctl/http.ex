defmodule Ehosctl.HTTP do
  @moduledoc """
  A request that carries a credential, to EHOS's API or to an application, and what it means when
  no answer came.

  Every request is made with `Ehosctl.SignIn.request_opts/2`'s options: a timeout, and for
  `https` hostname checking and the CA certificates `EHOSCTL_CA_FILE` adds to the system's. A
  redirect is never followed, since it would send the credential on to wherever it points.
  """

  @typedoc """
  An answer: its status, its headers with lowercase names, a header sent on several lines joined
  by commas, and its body as JSON.
  """
  @type answer :: %{status: pos_integer(), headers: %{String.t() => String.t()}, body: term()}

  @doc """
  Sends `method` to `url` with `credential` as a bearer token, and `body`, when not `nil`, as
  JSON, or, as `{:raw, content_type, bytes}`, as those bytes, unchanged. Returns the answer, with
  a body that is not JSON as `nil`, or an error of a kind (`t:Ehosctl.Output.kind/0`): `:failed` for a redirect, a TLS handshake that failed, or a header
  value holding a line break or non-ASCII, which is never sent; `:unreachable` when the
  connection could not be made. `{:error, :unreachable, message, :sent}` when the connection was
  made and no answer HTTP can read came: the request may have been done.

  `opts` may name `:env`, read for `EHOSCTL_CA_FILE`, `:headers`, sent besides, and `:timeout`
  in milliseconds, instead of the 30 seconds every request has: as long to connect, and again for
  the answer once the request is sent. A caller that needs one bound on both, as the update
  notice does, waits for the request itself.
  """
  @spec request(:get | :post | :patch | :delete, String.t(), String.t(), term(), keyword()) ::
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
      timeout = Keyword.get(opts, :timeout, request_opts.timeout)

      http_options =
        [timeout: timeout, connect_timeout: timeout, autoredirect: false] ++
          if ssl = request_opts[:ssl], do: [ssl: ssl], else: []

      request =
        case {method, body} do
          {:get, _body} ->
            {String.to_charlist(url), headers}

          # A removal names what it removes in its path, and sends no body.
          {:delete, nil} ->
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
             headers: headers(headers),
             body: decode(body)
           }}

        {:error, reason} ->
          no_answer(reason, origin, request_opts.ca_file)
      end
    end
  end

  @doc """
  Sends `GET` to `url` with `headers`, never following a redirect, and reads the answer's body no
  further than `opts[:max_bytes]`: a larger one is an error of kind `:failed` that says how large
  an answer may be, and is not read on. Returns the answer with its body as the bytes it is, for
  the caller to decode, or an error of a kind as `request/5`'s.

  A success's body is read as it streams, and refused once it passes the limit, or at once when
  its `content-length` says it would. `:httpc` streams only a 200, so the body of any other status
  is read whole; it is still refused when larger. `opts` may name `:env`, read for
  `EHOSCTL_CA_FILE`, and `:timeout` in milliseconds, for the whole request.
  """
  @spec get(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, %{status: pos_integer(), headers: %{String.t() => String.t()}, body: binary()}}
          | {:error, Ehosctl.Output.kind(), String.t()}
  def get(url, headers, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    origin = origin(url)

    with true <-
           Enum.all?(headers, fn {_name, value} -> header?(value) end) ||
             {:error, :failed, "ehosctl will not send a header holding a line break or non-ASCII"},
         {:ok, request_opts} <- Ehosctl.SignIn.request_opts(url, env) do
      timeout = Keyword.get(opts, :timeout, request_opts.timeout)

      http_options =
        [timeout: timeout, connect_timeout: timeout, autoredirect: false] ++
          if ssl = request_opts[:ssl], do: [ssl: ssl], else: []

      request =
        {String.to_charlist(url), for({name, value} <- headers, do: {~c"#{name}", value})}

      profile = downloads()

      case :httpc.request(
             :get,
             request,
             http_options,
             [sync: false, stream: :self, body_format: :binary],
             profile
           ) do
        {:ok, ref} ->
          deadline = System.monotonic_time(:millisecond) + timeout + 1_000
          streamed(ref, {max_bytes, origin, deadline, profile, request_opts.ca_file}, nil, [], 0)

        {:error, reason} ->
          transport_error(reason, origin, request_opts.ca_file)
      end
    end
  end

  # The answer as `:httpc` sends it to the caller: in parts for a 200, whole for anything else.
  defp streamed(
         ref,
         {max_bytes, origin, deadline, profile, ca_file} = limits,
         headers,
         parts,
         size
       ) do
    receive do
      {:http, {^ref, :stream_start, headers}} ->
        headers = headers(headers)

        case Integer.parse(headers["content-length"] || "") do
          {length, ""} when length > max_bytes -> too_large(ref, limits)
          _unknown -> streamed(ref, limits, headers, parts, size)
        end

      {:http, {^ref, :stream, part}} ->
        size = size + byte_size(part)

        if size > max_bytes,
          do: too_large(ref, limits),
          else: streamed(ref, limits, headers, [part | parts], size)

      {:http, {^ref, :stream_end, _trailers}} ->
        body = parts |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, %{status: 200, headers: headers, body: body}}

      {:http, {^ref, {{_version, status, _reason}, headers, body}}} ->
        if byte_size(body) > max_bytes,
          do: too_large(ref, limits),
          else: {:ok, %{status: status, headers: headers(headers), body: body}}

      {:http, {^ref, {:error, reason}}} ->
        transport_error(reason, origin, ca_file)
    after
      # One deadline for the whole download, not for each part. `:httpc`'s own timeout, a second
      # earlier, ends the request first; this keeps the caller from waiting past it whatever
      # `:httpc` does.
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        :httpc.cancel_request(ref, profile)
        unreachable(origin)
    end
  end

  defp too_large(ref, {max_bytes, origin, _deadline, profile, _ca_file}) do
    :httpc.cancel_request(ref, profile)

    {:error, :failed,
     "#{origin} answered with more than #{max_bytes} bytes, more than ehosctl reads from it."}
  end

  # `get/3`'s own `:httpc` profile, so `versions` and `changelog` can read release files from
  # GitHub eight at a time: the default profile keeps two connections to a host and queues up to
  # five requests on each, one after another. Started by the first caller, and given its options
  # by every caller before its request: a caller that found it already started could otherwise
  # send before the first had set them.
  @downloads :ehosctl_downloads

  defp downloads do
    case :inets.start(:httpc, profile: @downloads) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = :httpc.set_options([max_sessions: 8, max_keep_alive_length: 1], @downloads)
    @downloads
  end

  defp lower(name), do: name |> to_string() |> String.downcase()

  # A header sent on several lines is one value, its lines joined by commas (RFC 9110, 5.3): two
  # `Link` lines are read as one list of links.
  defp headers(headers) do
    headers
    |> Enum.group_by(fn {name, _value} -> lower(name) end, fn {_name, value} ->
      to_string(value)
    end)
    |> Map.new(fn {name, values} -> {name, Enum.join(values, ", ")} end)
  end

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
  defp no_answer(reason, where, ca_file) do
    cond do
      tls_alert(reason) -> untrusted(where, reason, ca_file)
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
  of kind `:failed`, or no answer at all, of kind `:unreachable`. `ca_file` is the
  `EHOSCTL_CA_FILE` the request trusted, or `nil` (`untrusted/3`).
  """
  @spec transport_error(term(), String.t(), String.t() | nil) ::
          {:error, Ehosctl.Output.kind(), String.t()}
  def transport_error(reason, where, ca_file \\ nil),
    do: if(tls_alert(reason), do: untrusted(where, reason, ca_file), else: unreachable(where))

  @doc "`where` did not answer: an error of kind `:unreachable`."
  @spec unreachable(String.t()) :: {:error, :unreachable, String.t()}
  def unreachable(where), do: {:error, :unreachable, "#{where} did not answer."}

  @doc """
  The TLS handshake with `where` failed, with the alert in `reason`: of kind `:failed`. Without
  `ca_file`, it says to set `EHOSCTL_CA_FILE`; with the one the request trusted, that its CA did
  not sign the certificate, when the alert is `unknown_ca`.
  """
  @spec untrusted(String.t(), term(), String.t() | nil) :: {:error, :failed, String.t()}
  def untrusted(where, reason, ca_file \\ nil) do
    alert = tls_alert(reason)
    failed = "the TLS handshake with #{where} failed (#{alert})."

    advice =
      cond do
        is_nil(ca_file) ->
          " For a local EHOS whose CA this machine does not trust, set EHOSCTL_CA_FILE to " <>
            "that CA's certificate."

        alert == :unknown_ca ->
          " The CA in EHOSCTL_CA_FILE=#{Ehosctl.Refusal.shown(ca_file)} did not sign its " <>
            "certificate, and no CA this machine trusts did."

        true ->
          ""
      end

    {:error, :failed, failed <> advice}
  end

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

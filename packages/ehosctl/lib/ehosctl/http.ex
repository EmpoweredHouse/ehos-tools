defmodule Ehosctl.HTTP do
  @moduledoc """
  A request that carries a credential, to EHOS's API or to an application, and what it means when
  no answer came.

  Every request is made with `Ehosctl.TLS.request_opts/3`'s options: a timeout, and for
  `https` hostname checking and the CA certificates `EHOSCTL_CA_FILE` and the CA kept for the
  installation (T-14) add to the system's. A
  redirect is never followed, since it would send the credential on to wherever it points.
  """

  @typedoc """
  An answer: its status, its headers with lowercase names, a header sent on several lines joined
  by commas, and its body as JSON.
  """
  @type answer :: %{status: pos_integer(), headers: %{String.t() => String.t()}, body: term()}

  # A success is read no further than this. `ehosctl call` returns an application's own data, so
  # the bound is generous: it is against an answer that does not end.
  @max_request_bytes 16 * 1_048_576

  # Any other answer is read to a refusal's size at most, here and in `stream/5`.
  @max_answer_bytes 1_048_576

  # Set in the calling process when Finch could not connect (`watch_connections/0`).
  @not_connected {__MODULE__, :not_connected}

  @doc """
  Sends `method` to `url` with `credential` as a bearer token, or none when it is `nil`, and
  `body`, when not `nil`, as JSON, or, as `{:raw, content_type, bytes}`, as those bytes,
  unchanged. Returns the answer, with a body that is not JSON as `nil`, or an error of a kind
  (`t:Ehosctl.Output.kind/0`): `:failed` for a redirect, a TLS handshake that failed, or a header
  value holding a line break or non-ASCII, which is never sent; `:unreachable` when the
  connection could not be made. `{:error, :unreachable, message, :sent}` when the connection was
  made and no answer HTTP can read came: the request may have been done.

  `opts` may name `:env`, read for `EHOSCTL_CA_FILE`, `:ca`, the CA kept for the installation
  (`Ehosctl.TLS.request_opts/3`), `:headers`, sent besides, and `:timeout`
  in milliseconds, instead of the 30 seconds every request has: as long to connect, and again for
  the answer once the request is sent. A caller that needs one bound on both, as the update
  notice does, waits for the request itself.

  A success is read no further than `:max_bytes`, 16 MiB unless given, and any other answer to
  1 MiB: past it, the body is `nil`, as a body that is not JSON is. A redirect is not read at all.
  """
  @spec request(
          :get | :post | :put | :patch | :delete,
          String.t(),
          String.t() | nil,
          term(),
          keyword()
        ) ::
          {:ok, answer()}
          | {:error, Ehosctl.Output.kind(), String.t()}
          | {:error, :unreachable, String.t(), :sent}
  def request(method, url, credential, body, opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    origin = origin(url)

    # A token exchange carries no credential, only the token it sends in its body.
    authorization = if credential, do: [{"authorization", "Bearer " <> credential}], else: []

    headers =
      authorization ++ [{"accept", "application/json"}] ++ Keyword.get(opts, :headers, [])

    with true <-
           Enum.all?(headers, fn {_name, value} -> header?(value) end) ||
             {:error, :failed, "ehosctl will not send a header holding a line break or non-ASCII"},
         {:ok, request_opts} <- Ehosctl.TLS.request_opts(url, env, Keyword.get(opts, :ca)) do
      timeout = Keyword.get(opts, :timeout, request_opts.timeout)
      max_bytes = Keyword.get(opts, :max_bytes, @max_request_bytes)

      # The answer's bytes as Req reads them, for any status, which `:httpc` reads whole when it
      # is not a 200. A refusal is read to a refusal's size, as `stream/5` reads one, and a
      # redirect not at all.
      into = fn {:data, part}, {request, response} ->
        {parts, size} = Req.Response.get_private(response, :read, {[], 0})
        size = size + byte_size(part)

        bound =
          if response.status in 200..299, do: max_bytes, else: min(max_bytes, @max_answer_bytes)

        cond do
          response.status in 300..399 ->
            {:halt, {request, response}}

          size > bound ->
            {:halt, {request, Req.Response.put_private(response, :read, :too_large)}}

          true ->
            {:cont, {request, Req.Response.put_private(response, :read, {[part | parts], size})}}
        end
      end

      {content, headers} =
        case {method, body} do
          {:get, _body} ->
            {nil, headers}

          # A removal names what it removes in its path, and sends no body unless it confirms.
          {:delete, nil} ->
            {nil, headers}

          {_method, {:raw, content_type, bytes}} ->
            {bytes, [{"content-type", content_type} | headers]}

          {_method, body} ->
            {JSON.encode!(body || %{}), [{"content-type", "application/json"} | headers]}
        end

      # As long to connect, and about as long again for the answer once connected:
      # `request_timeout` bounds it, headers included, though Finch checks it only between waits,
      # each bound by `receive_timeout`.
      request =
        Req.new(
          method: method,
          url: url,
          headers: headers,
          body: content,
          into: into,
          redirect: false,
          # Tried once: a failed connection is then this request's, never sent
          # (`watch_connections/0`).
          retry: false,
          decode_body: false,
          compressed: false,
          receive_timeout: timeout,
          request_timeout: timeout,
          connect_options:
            [timeout: timeout] ++
              if(ssl = request_opts[:ssl], do: [transport_opts: ssl], else: [])
        )

      watch_connections()
      Process.delete(@not_connected)
      result = Req.request(request)
      answered(result, Process.delete(@not_connected), {origin, request_opts.trusted})
    end
  end

  defp answered({:ok, %Req.Response{status: status}}, _not_connected, {origin, _trusted})
       when status in 300..399,
       do:
         {:error, :failed,
          "#{origin} redirected a request that carries your credential; ehosctl did not follow"}

  defp answered({:ok, %Req.Response{} = response}, _not_connected, _where) do
    case Req.Response.get_private(response, :read, {[], 0}) do
      # Too large to read is no body, as a body that is not JSON is: a success still says it was
      # done, and a refusal is read by its status.
      :too_large ->
        {:ok, whole(response, :too_large)}

      {parts, _size} ->
        {:ok, whole(response, parts)}
    end
  end

  defp answered({:error, exception}, not_connected, {origin, trusted}) do
    reason = reason(exception)

    if not_connected == true and is_nil(tls_alert(reason)),
      do: unreachable(origin),
      else: no_answer(reason, origin, trusted)
  end

  # Finch connects in the calling process, and says by telemetry when it could not: a request
  # that never had a connection was never sent, which Mint's reason alone does not tell, since a
  # connection that timed out or closed is `:timeout` or `:closed` as an answer that did is.
  # That holds for HTTP/1, Req's protocol here; Finch's HTTP/2 pool connects in its own process,
  # where the flag is never set, and a failure would then read as sent, the cautious side.
  defp watch_connections do
    case :telemetry.attach(
           __MODULE__,
           [:finch, :connect, :stop],
           &__MODULE__.connection_ended/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def connection_ended(_event, _measurements, %{error: _error}, _config),
    do: Process.put(@not_connected, true)

  def connection_ended(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Sends `GET` to `url` with `headers`, never following a redirect, and reads the answer's body no
  further than `opts[:max_bytes]`: a larger one is an error of kind `:failed` that says how large
  an answer may be, and is not read on. Returns the answer with its body as the bytes it is, for
  the caller to decode, or an error of a kind as `request/5`'s.

  A success's body is read as it streams, and refused once it passes the limit, or at once when
  its `content-length` says it would. `:httpc` streams only a 200, so the body of any other status
  is read whole; it is still refused when larger. `opts` may name `:env`, read for
  `EHOSCTL_CA_FILE`, `:ca`, as `request/5`'s, `:timeout` in milliseconds, for the whole request,
  and `installation?: false` for a host that is no installation's, GitHub's, whose failed
  handshake is then not followed by advice about an installation's CA.
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
         {:ok, request_opts} <- Ehosctl.TLS.request_opts(url, env, Keyword.get(opts, :ca)) do
      timeout = Keyword.get(opts, :timeout, request_opts.timeout)

      http_options =
        [timeout: timeout, connect_timeout: timeout, autoredirect: false] ++
          if ssl = request_opts[:ssl], do: [ssl: ssl], else: []

      request =
        {String.to_charlist(url), for({name, value} <- headers, do: {~c"#{name}", value})}

      profile = downloads()
      # `nil` for a host that is no installation's, which gets no advice about one's CA.
      trusted = if Keyword.get(opts, :installation?, true), do: request_opts.trusted

      case :httpc.request(
             :get,
             request,
             http_options,
             [sync: false, stream: :self, body_format: :binary],
             profile
           ) do
        {:ok, ref} ->
          deadline = System.monotonic_time(:millisecond) + timeout + 1_000
          streamed(ref, {max_bytes, origin, deadline, profile, trusted}, nil, [], 0)

        {:error, reason} ->
          transport_error(reason, origin, trusted)
      end
    end
  end

  @doc """
  Sends `GET` to `url` with `credential` as a bearer token and `headers` besides, never following
  a redirect, through Req rather than `:httpc`, and hands the body of a 200 that is
  `text/event-stream` to `handle` as it comes, a part at a time, for an answer that does not end by
  itself. `handle` takes a part and its `acc`, starting from `acc`, and returns `{:cont, acc}` to
  read on or `{:halt, result}` to stop. It runs in the calling process, and nothing more is read
  from the connection while it does: a reader that is slow to print is slow to read, which the
  server sees.

  Returns `{:halted, result}` when `handle` stopped; `{:closed, acc}` when the answer ended, the
  connection dropped once a part of it had come, or nothing came for `opts[:idle]` milliseconds
  after one, a connection that drops before any part being an error as below;
  any other answer, a 200 of another type too, as `{:ok, answer}`, its body JSON as
  `request/5`'s; or an error of a kind as `request/5`'s when no answer began. `opts` may name
  `:env`, `:ca` and `:timeout`, as `request/5`'s, which bounds the connection, and `:idle`, which
  bounds the wait for the answer to begin and each silence after: 45 seconds unless given.
  """
  @spec stream(
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          {acc, (binary(), acc -> {:cont, acc} | {:halt, result})},
          keyword()
        ) ::
          {:halted, result}
          | {:closed, acc}
          | {:ok, answer()}
          | {:error, Ehosctl.Output.kind(), String.t()}
        when acc: term(), result: term()
  def stream(url, credential, headers, {acc, handle}, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    origin = origin(url)
    headers = [{"authorization", "Bearer " <> credential} | headers]

    with true <-
           Enum.all?(headers, fn {_name, value} -> header?(value) end) ||
             {:error, :failed, "ehosctl will not send a header holding a line break or non-ASCII"},
         {:ok, request_opts} <- Ehosctl.TLS.request_opts(url, env, Keyword.get(opts, :ca)) do
      timeout = Keyword.get(opts, :timeout, request_opts.timeout)

      # Where the parts go while Req reads: the events' `acc`, or the bytes of any other answer.
      # Kept in the process, since a connection that drops returns Req's error alone.
      key = {__MODULE__, make_ref()}

      into = fn {:data, part}, {request, response} ->
        state = Process.get(key) || first(response, acc, timeout)
        {next, state} = part(state, part, handle)
        Process.put(key, state)
        {next, {request, response}}
      end

      # Req, through Mint, hands over every part as it comes: `:httpc` holds back a part that
      # came with the headers until the next one does, which in a tail may be a keep-alive 15
      # seconds later. No redirect is followed and nothing is tried again, as for every request.
      request =
        Req.new(
          url: url,
          headers: headers,
          into: into,
          redirect: false,
          retry: false,
          decode_body: false,
          compressed: false,
          receive_timeout: Keyword.get(opts, :idle, 45_000),
          connect_options:
            [timeout: timeout] ++
              if(ssl = request_opts[:ssl], do: [transport_opts: ssl], else: [])
        )

      result = Req.request(request)
      state = Process.delete(key)
      streamed(result, state, acc, {origin, request_opts.trusted})
    end
  end

  defp first(%Req.Response{status: 200} = response, acc, timeout) do
    if events?(response), do: {:events, acc}, else: other(timeout)
  end

  defp first(_response, _acc, timeout), do: other(timeout)

  defp other(timeout), do: {:other, [], 0, System.monotonic_time(:millisecond) + timeout}

  defp events?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.starts_with?(String.downcase(&1), "text/event-stream"))
  end

  defp part({:events, acc}, part, handle) do
    case handle.(part, acc) do
      {:cont, acc} -> {:cont, {:events, acc}}
      {:halt, result} -> {:halt, {:halted, result}}
    end
  end

  # Any other answer is read whole, to a refusal's size at most (`@max_answer_bytes`), within the
  # request's timeout.
  defp part({:other, parts, size, deadline}, part, _handle) do
    size = size + byte_size(part)

    if size > @max_answer_bytes or System.monotonic_time(:millisecond) > deadline,
      do: {:halt, {:other, :too_large, size, deadline}},
      else: {:cont, {:other, [part | parts], size, deadline}}
  end

  defp streamed({:ok, %Req.Response{status: status}}, _state, _acc, {origin, _trusted})
       when status in 300..399,
       do:
         {:error, :failed,
          "#{origin} redirected a request that carries your credential; ehosctl did not follow"}

  defp streamed({:ok, _response}, {:halted, result}, _acc, _where), do: {:halted, result}
  defp streamed({:ok, _response}, {:events, acc}, _acc, _where), do: {:closed, acc}

  defp streamed({:ok, %Req.Response{status: 200} = response}, nil, acc, _where) do
    if events?(response), do: {:closed, acc}, else: {:ok, whole(response, [])}
  end

  defp streamed({:ok, response}, {:other, parts, _size, _deadline}, _acc, _where),
    do: {:ok, whole(response, parts)}

  defp streamed({:ok, response}, nil, _acc, _where), do: {:ok, whole(response, [])}
  defp streamed({:error, _exception}, {:events, acc}, _acc, _where), do: {:closed, acc}

  defp streamed({:error, exception}, _state, _acc, {origin, trusted}),
    do: transport_error(reason(exception), origin, trusted)

  defp whole(response, parts) do
    body =
      case parts do
        :too_large -> nil
        parts -> parts |> Enum.reverse() |> IO.iodata_to_binary() |> decode()
      end

    headers = Map.new(response.headers, fn {name, values} -> {name, Enum.join(values, ", ")} end)
    %{status: response.status, headers: headers, body: body}
  end

  defp reason(%{reason: reason}), do: reason
  defp reason(exception), do: exception

  # The answer as `:httpc` sends it to the caller: in parts for a 200, whole for anything else.
  defp streamed(
         ref,
         {max_bytes, origin, deadline, profile, trusted} = limits,
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
        transport_error(reason, origin, trusted)
    after
      # One deadline for the whole download, not for each part. `:httpc`'s own timeout, a second
      # earlier, ends the request first; this keeps the caller from waiting past it whatever
      # `:httpc` does.
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        :httpc.cancel_request(ref, profile)
        unreachable(origin)
    end
  end

  defp too_large(ref, {max_bytes, origin, _deadline, profile, _trusted}) do
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
  defp no_answer(reason, where, trusted) do
    cond do
      tls_alert(reason) -> untrusted(where, reason, trusted)
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
  Why a request to `where` got no answer, from what `:httpc` or Mint said: a TLS handshake that failed,
  of kind `:failed`, or no answer at all, of kind `:unreachable`. `trusted` is what the request
  trusted besides the system's CAs, or `nil` for a host that is no installation's (`untrusted/3`).
  """
  @spec transport_error(term(), String.t(), [trusted()] | nil) ::
          {:error, Ehosctl.Output.kind(), String.t()}
  def transport_error(reason, where, trusted \\ []),
    do: if(tls_alert(reason), do: untrusted(where, reason, trusted), else: unreachable(where))

  @doc "`where` did not answer: an error of kind `:unreachable`."
  @spec unreachable(String.t()) :: {:error, :unreachable, String.t()}
  def unreachable(where), do: {:error, :unreachable, "#{where} did not answer."}

  @typedoc """
  A CA a request trusted besides the system's: the file `EHOSCTL_CA_FILE` named, or the one
  `ehosctl login` kept for the installation of that name (T-14).
  """
  @type trusted :: {:file, String.t()} | {:kept, String.t()}

  @doc """
  The TLS handshake with `where` failed, with the alert in `reason`: of kind `:failed`. When the
  request trusted no CA besides the system's, it says how to give `ehosctl` the installation's;
  when it trusted some (`trusted`), and the alert is `unknown_ca`, that none of them signed the
  certificate. With `trusted` `nil`, for a host that is no installation's, it says nothing more.
  """
  @spec untrusted(String.t(), term(), [trusted()] | nil) :: {:error, :failed, String.t()}
  def untrusted(where, reason, trusted \\ []) do
    alert = tls_alert(reason)
    failed = "the TLS handshake with #{where} failed (#{alert})."

    advice =
      cond do
        is_nil(trusted) ->
          ""

        trusted == [] ->
          " If its CA is the installation's own, as a server's or a local EHOS's is, sign in " <>
            "with EHOSCTL_CA_FILE set to that CA's certificate: ehosctl login keeps it for " <>
            "the installation."

        alert == :unknown_ca ->
          " #{not_signed(trusted)}, and no CA this machine trusts did." <> kept_advice(trusted)

        true ->
          ""
      end

    {:error, :failed, failed <> advice}
  end

  defp not_signed([{:file, file}]),
    do: "The CA in EHOSCTL_CA_FILE=#{Ehosctl.Refusal.shown(file)} did not sign its certificate"

  defp not_signed([{:kept, name}]),
    do: "The CA ehosctl keeps for #{name} did not sign its certificate"

  defp not_signed(trusted),
    do: "Neither #{Enum.map_join(trusted, " nor ", &trusted_name/1)} signed its certificate"

  defp trusted_name({:file, file}), do: "the CA in EHOSCTL_CA_FILE=#{Ehosctl.Refusal.shown(file)}"
  defp trusted_name({:kept, name}), do: "the CA ehosctl keeps for #{name}"

  defp kept_advice(trusted) do
    case List.keyfind(trusted, :kept, 0) do
      {:kept, name} ->
        " If the installation's CA changed, sign in to #{name} again with EHOSCTL_CA_FILE set " <>
          "to the new one."

      nil ->
        ""
    end
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

defmodule Ehosctl.SignIn.Loopback do
  @moduledoc """
  Where the browser comes back to (T-09): a socket on `127.0.0.1`, on a port the kernel picks,
  that waits for one request to `/callback`.

  Requests are read with the VM's own HTTP parser (`packet: :http_bin`), their request line and
  headers only, never a body, one at a time. Any other request is answered with a 404 and does not
  end the wait, nor does a callback that `respond` passes over (a `state` that is not the
  sign-in's). A request has five seconds to arrive whole, at most 100 headers and lines of at
  most 8 KiB, so a local process that holds connections open delays the browser's callback by
  five seconds a connection at most, and never past the wait's own end.
  """

  @typedoc "An open listener."
  @opaque t :: %{socket: :gen_tcp.socket(), port: :inet.port_number()}

  @typedoc """
  What `await/3` does with a callback's query: `{:done, result, page}` answers with `page` and
  returns `result`, `{:ignore, page}` answers and keeps waiting.
  """
  @type response :: {:done, term(), String.t()} | {:ignore, String.t()}

  # How long one request has to arrive whole once its connection is open, how many headers it
  # may have, and how long a line of it may be.
  @request_timeout_ms 5_000
  @max_headers 100
  @max_line_bytes 8_192

  @doc "Opens a listener on `127.0.0.1`, on a port the kernel picks."
  @spec open() :: {:ok, t()} | {:error, :inet.posix()}
  def open do
    with {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             ip: {127, 0, 0, 1},
             packet: :http_bin,
             packet_size: @max_line_bytes,
             active: false
           ]),
         {:ok, port} <- :inet.port(socket) do
      {:ok, %{socket: socket, port: port}}
    end
  end

  @doc "The address the browser is sent back to: `http://127.0.0.1:<port>/callback`."
  @spec redirect_uri(t()) :: String.t()
  def redirect_uri(%{port: port}), do: "http://127.0.0.1:#{port}/callback"

  @doc """
  Waits up to `timeout` milliseconds for a request to `/callback`, and hands its query, decoded,
  to `respond`. Returns `{:ok, result}`, or `{:error, :timeout}`. `opts[:request_timeout]` is how
  long one request has to arrive, five seconds by default.
  """
  @spec await(t(), non_neg_integer(), (%{String.t() => String.t()} -> response()), keyword()) ::
          {:ok, term()} | {:error, :timeout | :inet.posix()}
  def await(%{socket: socket}, timeout, respond, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop(socket, deadline, respond, Keyword.get(opts, :request_timeout, @request_timeout_ms))
  end

  @doc "Closes the listener."
  @spec close(t()) :: :ok
  def close(%{socket: socket}), do: :gen_tcp.close(socket)

  defp loop(socket, deadline, respond, request_timeout) do
    case :gen_tcp.accept(socket, left(deadline)) do
      {:ok, client} ->
        # The request's own deadline, never past the wait's.
        request_deadline =
          min(System.monotonic_time(:millisecond) + request_timeout, deadline)

        case serve(client, respond, request_deadline) do
          {:done, result} -> {:ok, result}
          :continue -> loop(socket, deadline, respond, request_timeout)
        end

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp serve(client, respond, deadline) do
    result =
      case read_request(client, deadline) do
        {:ok, :GET, "/callback", query} ->
          case respond.(URI.decode_query(query)) do
            {:done, result, page} ->
              reply(client, 200, page)
              {:done, result}

            {:ignore, page} ->
              reply(client, 400, page)
              :continue
          end

        {:ok, _method, _path, _query} ->
          reply(client, 404, "Not found.")
          :continue

        :error ->
          :continue
      end

    :gen_tcp.close(client)
    result
  end

  defp read_request(client, deadline) do
    with {:ok, {:http_request, method, {:abs_path, target}, _version}} <-
           :gen_tcp.recv(client, 0, left(deadline)),
         :ok <- skip_headers(client, deadline, @max_headers) do
      {path, query} =
        case String.split(target, "?", parts: 2) do
          [path, query] -> {path, query}
          [path] -> {path, ""}
        end

      {:ok, method, path, query}
    else
      _other -> :error
    end
  end

  defp skip_headers(client, deadline, headers_left) do
    case :gen_tcp.recv(client, 0, left(deadline)) do
      {:ok, :http_eoh} ->
        :ok

      {:ok, {:http_header, _, _, _, _}} when headers_left > 0 ->
        skip_headers(client, deadline, headers_left - 1)

      _too_many_or_broken ->
        :error
    end
  end

  # A page of its own, which loads nothing and sends no referrer: its address holds the code.
  defp reply(client, status, text) do
    body = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>ehosctl</title></head>
    <body style="font-family: system-ui, sans-serif; margin: 3rem;"><p>#{escape(text)}</p></body>
    </html>
    """

    reason = %{200 => "OK", 400 => "Bad Request", 404 => "Not Found"}[status]

    :gen_tcp.send(client, [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "Content-Type: text/html; charset=utf-8\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Cache-Control: no-store\r\n",
      "Referrer-Policy: no-referrer\r\n",
      "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n",
      "Connection: close\r\n\r\n",
      body
    ])
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end

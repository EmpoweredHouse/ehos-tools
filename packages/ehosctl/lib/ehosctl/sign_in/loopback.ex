defmodule Ehosctl.SignIn.Loopback do
  @moduledoc """
  Where the browser comes back to (T-09): a socket on `127.0.0.1`, on a port the kernel picks,
  that waits for one request to `/callback`.

  Requests are read with the VM's own HTTP parser (`packet: :http_bin`), their request line and
  headers only, never a body. Any other request is answered with a 404 and does not end the wait,
  nor does a callback that `respond` passes over (a `state` that is not the sign-in's).
  """

  @typedoc "An open listener."
  @opaque t :: %{socket: :gen_tcp.socket(), port: :inet.port_number()}

  @typedoc """
  What `await/3` does with a callback's query: `{:done, result, page}` answers with `page` and
  returns `result`, `{:ignore, page}` answers and keeps waiting.
  """
  @type response :: {:done, term(), String.t()} | {:ignore, String.t()}

  # How long one request has to arrive whole once its connection is open.
  @request_timeout_ms 5_000

  @doc "Opens a listener on `127.0.0.1`, on a port the kernel picks."
  @spec open() :: {:ok, t()} | {:error, :inet.posix()}
  def open do
    with {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             ip: {127, 0, 0, 1},
             packet: :http_bin,
             active: false,
             reuseaddr: true
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
  to `respond`. Returns `{:ok, result}`, or `{:error, :timeout}`.
  """
  @spec await(t(), non_neg_integer(), (%{String.t() => String.t()} -> response())) ::
          {:ok, term()} | {:error, :timeout | :inet.posix()}
  def await(%{socket: socket}, timeout, respond) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop(socket, deadline, respond)
  end

  @doc "Closes the listener."
  @spec close(t()) :: :ok
  def close(%{socket: socket}), do: :gen_tcp.close(socket)

  defp loop(socket, deadline, respond) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_tcp.accept(socket, remaining) do
      {:ok, client} ->
        case serve(client, respond) do
          {:done, result} -> {:ok, result}
          :continue -> loop(socket, deadline, respond)
        end

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp serve(client, respond) do
    result =
      case read_request(client) do
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

  defp read_request(client) do
    with {:ok, {:http_request, method, {:abs_path, target}, _version}} <-
           :gen_tcp.recv(client, 0, @request_timeout_ms),
         :ok <- skip_headers(client) do
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

  defp skip_headers(client) do
    case :gen_tcp.recv(client, 0, @request_timeout_ms) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> skip_headers(client)
      _other -> :error
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

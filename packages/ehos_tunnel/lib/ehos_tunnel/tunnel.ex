defmodule EhosTunnel.Tunnel do
  @moduledoc false
  # One tunnel of `EhosTunnel.ClientImpl`: it waits for its accepted connection, opens the
  # WebSocket to the gateway, then passes bytes both ways until either side ends. It traps exits,
  # so that its listener's end reaches `terminate/2`, which closes the tunnel with 1001 rather
  # than dropping it.

  use GenServer, restart: :temporary

  alias EhosTunnel.Protocol

  @max_frame_size Protocol.max_frame_size()

  # A refusal's body is a short JSON document; past this, the rest is not read, and the refusal
  # is read from its status alone.
  @max_body 65_536

  # RFC 6455, section 7.4.1: the endpoint ends the connection because the other broke the protocol.
  @protocol_error 1002

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @impl GenServer
  def init(config) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       config: config,
       socket: nil,
       conn: nil,
       ref: nil,
       websocket: nil,
       status: nil,
       headers: [],
       body: [],
       body_size: 0,
       heard: false
     }}
  end

  @impl GenServer
  def handle_info({:socket, socket}, %{config: config} = state) do
    state = %{state | socket: socket}

    with {:ok, conn} <-
           Mint.HTTP.connect(:https, config.host, config.port,
             protocols: [:http1],
             transport_opts: config.tls
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(:wss, conn, config.path, [
             {"sec-websocket-protocol", Protocol.subprotocol()}
           ]) do
      Process.send_after(self(), :upgrade_timeout, config.upgrade_timeout)
      {:noreply, %{state | conn: conn, ref: ref}}
    else
      {:error, error} -> fail(state, error)
      {:error, conn, error} -> fail(%{state | conn: conn}, error)
    end
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    data |> chunks() |> Enum.reduce_while({:noreply, state}, &send_binary/2) |> read_on()
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    state |> send_close(:normal) |> stop({:ended, self()})
  end

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state) do
    state |> send_close(:normal) |> stop({:ended, self()})
  end

  def handle_info(:upgrade_timeout, %{conn: conn, websocket: nil} = state) when conn != nil,
    do: fail(state, :timeout)

  # The gateway pings every 30 seconds, so a tunnel that heard nothing for the silence it allows
  # has lost the gateway, even where TCP has not noticed. A check every `silence_timeout` finds a
  # silence between one and two of them long.
  def handle_info(:silence_check, %{heard: true} = state) do
    Process.send_after(self(), :silence_check, state.config.silence_timeout)
    {:noreply, %{state | heard: false}}
  end

  def handle_info(:silence_check, %{conn: conn} = state) when conn != nil,
    do: state |> send_close(:going_away) |> fail(:timeout)

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        responses(responses, %{state | conn: conn, heard: true})

      {:error, conn, error, responses} ->
        responses |> responses(%{state | conn: conn}) |> then_fail(error)

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Its listener's end, as its parent, or a stop on the way out: a tunnel still open says
  # goodbye with 1001 before its connections close.
  @impl GenServer
  def terminate(_reason, state) do
    state = send_close(state, :going_away)
    if state.conn, do: Mint.HTTP.close(state.conn)
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end

  # A crash report shows the state and the last message: the TLS options hold the session's
  # private key, a local read holds the client's bytes, a password among them, and Mint's buffers
  # and a read from the gateway hold the database's answers.
  @impl GenServer
  def format_status(status) do
    status
    |> Map.update(:state, nil, &redacted/1)
    |> Map.update(:message, nil, &redacted_message/1)
  end

  defp redacted(%{config: config} = state) do
    %{
      state
      | config: %{config | tls: :redacted},
        conn: state.conn && :redacted,
        websocket: state.websocket && :redacted,
        body: :redacted
    }
  end

  defp redacted(state), do: state

  defp redacted_message({transport, socket, _data}) when transport in [:tcp, :ssl],
    do: {transport, socket, :redacted}

  defp redacted_message(message), do: message

  defp responses(responses, state),
    do: Enum.reduce_while(responses, {:noreply, state}, &response/2)

  # A refusal whose body runs until the connection closes can end in Mint's error for the closed
  # socket, with no `:done`: what was read is the refusal.
  defp then_fail(
         {:noreply, %{websocket: nil, status: status} = state},
         %Mint.TransportError{reason: :closed}
       )
       when is_integer(status) and status != 101 do
    refusal = Protocol.refusal(status, IO.iodata_to_binary(state.body))
    stop(state, {:refused, self(), refusal})
  end

  defp then_fail({:noreply, state}, error), do: fail(state, error)
  defp then_fail(stopped, _error), do: stopped

  defp response({:status, ref, status}, {:noreply, %{ref: ref} = state}),
    do: {:cont, {:noreply, %{state | status: status}}}

  defp response({:headers, ref, headers}, {:noreply, %{ref: ref} = state}),
    do: {:cont, {:noreply, %{state | headers: state.headers ++ headers}}}

  defp response({:data, ref, data}, {:noreply, %{ref: ref, websocket: nil} = state}),
    do: {:cont, {:noreply, body(state, data)}}

  defp response({:data, ref, data}, {:noreply, %{ref: ref} = state}) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} -> frames(frames, %{state | websocket: websocket})
      {:error, websocket, error} -> {:halt, fail(%{state | websocket: websocket}, error)}
    end
  end

  defp response({:done, ref}, {:noreply, %{ref: ref, status: 101} = state}),
    do: {:cont, upgraded(state)}

  defp response({:done, ref}, {:noreply, %{ref: ref} = state}) do
    refusal = Protocol.refusal(state.status, IO.iodata_to_binary(state.body))
    {:halt, stop(state, {:refused, self(), refusal})}
  end

  defp response({:error, ref, error}, {:noreply, %{ref: ref} = state}),
    do: {:halt, fail(state, error)}

  defp response(_response, result), do: {:cont, result}

  # After a 101, Mint gives the bytes that came in the same read as the answer as its body: the
  # gateway's first frames, which `upgraded/1` reads once the WebSocket is made.
  defp body(%{status: 101} = state, data), do: %{state | body: [state.body, data]}

  defp body(state, data) do
    kept = binary_part(data, 0, min(byte_size(data), @max_body - state.body_size))
    %{state | body: [state.body, kept], body_size: state.body_size + byte_size(kept)}
  end

  # Mint's connections are opaque types whose structs mint_web_socket matches inside
  # `Mint.WebSocket.new/4`, so OTP 28's Dialyzer reads `new/4` as never succeeding, and what
  # follows its success as unreachable. The client's tests open tunnels through it.
  @dialyzer {:nowarn_function, upgraded: 1, first_frames: 2}
  defp upgraded(state) do
    with :ok <- subprotocol(state.headers),
         {:ok, conn, websocket} <-
           Mint.WebSocket.new(state.conn, state.ref, state.status, state.headers) do
      :ok = :inet.setopts(state.socket, active: :once)
      Process.send_after(self(), :silence_check, state.config.silence_timeout)
      state.config.on_event.({:open, self()})
      early = IO.iodata_to_binary(state.body)
      first_frames(early, %{state | conn: conn, websocket: websocket, body: [], heard: false})
    else
      {:error, :no_subprotocol} -> fail(state, :no_subprotocol)
      {:error, conn, error} -> fail(%{state | conn: conn}, error)
    end
  end

  defp first_frames("", state), do: {:noreply, state}

  defp first_frames(data, state) do
    {_cont_or_halt, result} = response({:data, state.ref, data}, {:noreply, state})
    result
  end

  defp subprotocol(headers) do
    if {"sec-websocket-protocol", Protocol.subprotocol()} in headers,
      do: :ok,
      else: {:error, :no_subprotocol}
  end

  defp frames(frames, state) do
    case Enum.reduce_while(frames, {:noreply, state}, &frame/2) do
      {:noreply, _state} = result -> {:cont, result}
      stopped -> {:halt, stopped}
    end
  end

  defp frame({:binary, data}, {:noreply, state}) do
    case :gen_tcp.send(state.socket, data) do
      :ok -> {:cont, {:noreply, state}}
      {:error, _closed} -> {:halt, state |> send_close(:normal) |> stop({:ended, self()})}
    end
  end

  defp frame({:ping, data}, {:noreply, state}) do
    case send_frame({:pong, data}, state) do
      {:noreply, _state} = result -> {:cont, result}
      stopped -> {:halt, stopped}
    end
  end

  defp frame({:close, code, text}, {:noreply, state}) do
    state = send_close(state, :normal)
    {:halt, stop(state, {:closed, self(), Protocol.close(code, text)})}
  end

  defp frame({:text, _text}, {:noreply, state}),
    do: {:halt, state |> send_close(:text_frame) |> fail(:text_frame)}

  # A frame Mint could not read (an unknown opcode, reserved bits, a bad close payload): it reads
  # no further, so the bytes after it are lost, and the tunnel cannot go on.
  defp frame({:error, reason}, {:noreply, state}),
    do: {:halt, state |> send_close(@protocol_error) |> fail({:bad_frame, reason})}

  defp frame({:pong, _data}, result), do: {:cont, result}

  defp send_binary(data, {:noreply, state}) do
    case send_frame({:binary, data}, state) do
      {:noreply, _state} = result -> {:cont, result}
      stopped -> {:halt, stopped}
    end
  end

  defp read_on({:noreply, state}) do
    :ok = :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  defp read_on(stopped), do: stopped

  defp send_frame(frame, state) do
    case transmit(frame, state) do
      {:ok, state} -> {:noreply, state}
      {:error, state, error} -> fail(state, error)
    end
  end

  # A close on the way out: whatever fails here, the tunnel ends anyway, for the reason it ends.
  defp send_close(%{websocket: nil} = state, _reason), do: state
  defp send_close(%{conn: nil} = state, _reason), do: state

  defp send_close(state, code) when is_integer(code) do
    case transmit({:close, code, ""}, state) do
      {:ok, state} -> state
      {:error, state, _error} -> state
    end
  end

  defp send_close(state, reason), do: send_close(state, Protocol.close_code(reason))

  defp transmit(frame, state) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} -> stream(data, %{state | websocket: websocket})
      {:error, websocket, error} -> {:error, %{state | websocket: websocket}, error}
    end
  end

  defp stream(data, state) do
    case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, conn, error} -> {:error, %{state | conn: conn}, error}
    end
  end

  defp chunks(data) when byte_size(data) <= @max_frame_size, do: [data]

  defp chunks(<<chunk::binary-size(@max_frame_size), rest::binary>>), do: [chunk | chunks(rest)]

  defp fail(state, reason), do: stop(state, {:failed, self(), reason})

  defp stop(state, event) do
    state.config.on_event.(event)
    if state.conn, do: Mint.HTTP.close(state.conn)
    if state.socket, do: :gen_tcp.close(state.socket)
    {:stop, :normal, %{state | conn: nil, socket: nil, websocket: nil}}
  end
end

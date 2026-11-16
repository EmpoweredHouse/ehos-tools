defmodule EhosTunnel.Tunnel do
  @moduledoc false
  # One tunnel of `EhosTunnel.ClientImpl`: it waits for its accepted connection, opens the
  # WebSocket to the gateway, then passes bytes both ways until either side ends. It traps exits,
  # so that its listener's end closes the tunnel with 1001 rather than dropping it.

  use GenServer, restart: :temporary

  alias EhosTunnel.Protocol

  @max_frame_size Protocol.max_frame_size()

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
       body: []
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

  def handle_info({:EXIT, _listener, _reason}, state) do
    state |> send_close(:going_away) |> stop(nil)
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        Enum.reduce_while(responses, {:noreply, %{state | conn: conn}}, &response/2)

      {:error, conn, error, _responses} ->
        fail(%{state | conn: conn}, error)

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp response({:status, ref, status}, {:noreply, %{ref: ref} = state}),
    do: {:cont, {:noreply, %{state | status: status}}}

  defp response({:headers, ref, headers}, {:noreply, %{ref: ref} = state}),
    do: {:cont, {:noreply, %{state | headers: state.headers ++ headers}}}

  defp response({:data, ref, data}, {:noreply, %{ref: ref, websocket: nil} = state}),
    do: {:cont, {:noreply, %{state | body: [state.body | data]}}}

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

  defp upgraded(state) do
    with :ok <- subprotocol(state.headers),
         {:ok, conn, websocket} <-
           Mint.WebSocket.new(state.conn, state.ref, state.status, state.headers) do
      :ok = :inet.setopts(state.socket, active: :once)
      state.config.on_event.({:open, self()})
      {:noreply, %{state | conn: conn, websocket: websocket}}
    else
      {:error, :no_subprotocol} -> fail(state, :no_subprotocol)
      {:error, conn, error} -> fail(%{state | conn: conn}, error)
    end
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

  defp frame(_pong, result), do: {:cont, result}

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

  defp send_close(state, reason) do
    case transmit({:close, Protocol.close_code(reason), ""}, state) do
      {:ok, state} -> state
      {:error, state, _error} -> state
    end
  end

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
    if event, do: state.config.on_event.(event)
    if state.conn, do: Mint.HTTP.close(state.conn)
    if state.socket, do: :gen_tcp.close(state.socket)
    {:stop, :normal, %{state | conn: nil, socket: nil}}
  end
end

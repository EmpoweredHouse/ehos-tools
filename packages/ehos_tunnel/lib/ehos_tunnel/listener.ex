defmodule EhosTunnel.Listener do
  @moduledoc false
  # `EhosTunnel.ClientImpl`'s listener: it accepts connections on the loopback address, in a
  # process of its own since accepting blocks, and starts a linked `EhosTunnel.Tunnel` for each.
  # It traps exits, so a tunnel's end leaves it running.

  use GenServer

  @spec start_link(map(), :inet.port_number()) :: GenServer.on_start()
  def start_link(config, port), do: GenServer.start_link(__MODULE__, {config, port})

  @impl GenServer
  def init({config, port}) do
    Process.flag(:trap_exit, true)

    case :gen_tcp.listen(port, [
           :binary,
           packet: :raw,
           active: false,
           ip: {127, 0, 0, 1},
           reuseaddr: true,
           nodelay: true
         ]) do
      {:ok, socket} ->
        listener = self()
        spawn_link(fn -> accept(socket, listener) end)
        {:ok, %{config: config, socket: socket}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, %{socket: socket} = state) do
    {:ok, port} = :inet.port(socket)
    {:reply, port, state}
  end

  def handle_call(:tunnel, _from, %{config: config} = state) do
    {:reply, EhosTunnel.Tunnel.start_link(config), state}
  end

  # A tunnel or the acceptor that ended; the listener goes on.
  @impl GenServer
  def handle_info({:EXIT, _process, _reason}, state), do: {:noreply, state}

  # The tunnels trap exits, and close when the listener does.
  @impl GenServer
  def terminate(_reason, %{socket: socket}), do: :gen_tcp.close(socket)

  # The listener's configuration, from `EhosTunnel.ClientImpl.listen/1`'s options; a caller's
  # mistake raises in the caller.
  @spec config(keyword()) :: map()
  def config(opts) do
    key = Keyword.fetch!(opts, :key)

    certificate =
      Keyword.get_lazy(opts, :certificate, fn -> EhosTunnel.Certificate.self_signed(key) end)

    uri = URI.parse(Keyword.fetch!(opts, :url))

    unless uri.scheme == "wss" and is_binary(uri.host) do
      raise ArgumentError, "the tunnel URL is not a wss:// URL with a host"
    end

    %{
      host: uri.host,
      port: uri.port,
      path: uri.path || "/",
      on_event: Keyword.get(opts, :on_event, fn _event -> :ok end),
      tls:
        [versions: [:"tlsv1.3"], verify: :verify_peer] ++
          ca(opts) ++ EhosTunnel.Certificate.ssl_options(certificate, key)
    }
  end

  defp ca(opts) do
    case {Keyword.get(opts, :cacerts), Keyword.get(opts, :cacertfile)} do
      {[_ | _] = cacerts, nil} -> [cacerts: cacerts]
      {nil, path} when is_binary(path) -> [cacertfile: path]
      _neither_or_both -> raise ArgumentError, "give the gateway's CA as :cacerts or :cacertfile"
    end
  end

  # Runs in a process of its own, since accepting blocks; a closed socket ends it.
  defp accept(socket, listener) do
    with {:ok, connection} <- :gen_tcp.accept(socket),
         {:ok, tunnel} <- GenServer.call(listener, :tunnel),
         :ok <- :gen_tcp.controlling_process(connection, tunnel) do
      send(tunnel, {:socket, connection})
      accept(socket, listener)
    end
  end
end

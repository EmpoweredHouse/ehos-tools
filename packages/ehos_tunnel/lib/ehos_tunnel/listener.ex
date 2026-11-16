defmodule EhosTunnel.Listener do
  @moduledoc false
  # `EhosTunnel.ClientImpl`'s listener: it owns the listening socket its caller opened, accepts
  # connections on it in a process of its own since accepting blocks, and starts a linked
  # `EhosTunnel.Tunnel` for each. It traps exits, so a tunnel's end leaves it running; the
  # acceptor's end, but for the socket's closing, stops it and tells its caller.

  use GenServer

  @p256 {1, 2, 840, 10_045, 3, 1, 7}

  # Refusals of `accept` that pass once descriptors or memory are freed.
  @passing [:emfile, :enfile, :enobufs, :enomem, :system_limit]

  @spec start_link(map(), :inet.socket()) :: GenServer.on_start()
  def start_link(config, socket), do: GenServer.start_link(__MODULE__, {config, socket})

  @impl GenServer
  def init({config, socket}) do
    Process.flag(:trap_exit, true)
    listener = self()
    acceptor = spawn_link(fn -> accept(socket, listener) end)
    {:ok, %{config: config, socket: socket, acceptor: acceptor}}
  end

  @impl GenServer
  def handle_call(:port, _from, %{socket: socket} = state) do
    {:ok, port} = :inet.port(socket)
    {:reply, port, state}
  end

  def handle_call(:tunnel, _from, %{config: config} = state) do
    {:reply, EhosTunnel.Tunnel.start_link(config), state}
  end

  @impl GenServer
  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state) do
    state.config.on_event.({:stopped, reason})
    {:stop, :normal, state}
  end

  # A tunnel that ended; the listener goes on.
  def handle_info({:EXIT, _tunnel, _reason}, state), do: {:noreply, state}

  # The tunnels trap exits, and close in their own `terminate/2` when the listener ends.
  @impl GenServer
  def terminate(_reason, %{socket: socket}), do: :gen_tcp.close(socket)

  @impl GenServer
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{config: config} = state -> %{state | config: %{config | tls: :redacted}}
      state -> state
    end)
  end

  # The listener's configuration, from `EhosTunnel.ClientImpl.listen/1`'s options. A caller's
  # mistake raises in the caller, with a message that names the option and never its value, since
  # the options hold the session's private key.
  @spec config(keyword()) :: map()
  def config(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "give listen/1 a keyword list")

    key = key(Keyword.get(opts, :key))
    certificate = certificate(Keyword.get(opts, :certificate), key)
    uri = url(Keyword.get(opts, :url))

    %{
      host: uri.host,
      port: uri.port,
      path: uri.path || "/",
      on_event: on_event(Keyword.get(opts, :on_event, fn _event -> :ok end)),
      upgrade_timeout: timeout(Keyword.get(opts, :upgrade_timeout, 30_000), :upgrade_timeout),
      silence_timeout:
        timeout(
          Keyword.get(opts, :silence_timeout, EhosTunnel.Protocol.silence_timeout()),
          :silence_timeout
        ),
      tls:
        [versions: [:"tlsv1.3"], verify: :verify_peer] ++
          ca(opts) ++ EhosTunnel.Certificate.ssl_options(certificate, key)
    }
  end

  defp key({:ECPrivateKey, _version, private, {:namedCurve, @p256}, point, _attributes} = key)
       when is_binary(private) and byte_size(private) <= 32 and is_binary(point),
       do: key

  defp key(_key), do: raise(ArgumentError, "give the session's P-256 private key as :key")

  defp on_event(function) when is_function(function, 1), do: function
  defp on_event(_function), do: raise(ArgumentError, "give :on_event as a function of one event")

  defp timeout(milliseconds, _name) when is_integer(milliseconds) and milliseconds > 0,
    do: milliseconds

  defp timeout(_milliseconds, name),
    do: raise(ArgumentError, "give #{inspect(name)} as a number of milliseconds above 0")

  defp certificate(nil, key), do: EhosTunnel.Certificate.self_signed(key)
  defp certificate(certificate, _key) when is_binary(certificate), do: certificate

  defp certificate(_certificate, _key),
    do: raise(ArgumentError, "give :certificate as a DER binary")

  defp url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "wss", host: host} = uri when is_binary(host) and host != "" -> uri
      _other -> raise ArgumentError, "the tunnel URL is not a wss:// URL with a host"
    end
  end

  defp url(_url), do: raise(ArgumentError, "the tunnel URL is not a wss:// URL with a host")

  defp ca(opts) do
    case {Keyword.get(opts, :cacerts), Keyword.get(opts, :cacertfile)} do
      {[_ | _] = cacerts, nil} -> [cacerts: cacerts]
      {nil, path} when is_binary(path) -> [cacertfile: path]
      _neither_or_both -> raise ArgumentError, "give the gateway's CA as :cacerts or :cacertfile"
    end
  end

  # Runs in a process of its own, since accepting blocks. The socket's closing ends it normally;
  # a connection that went before it was accepted is passed over; running out of descriptors or
  # memory passes, so it waits and accepts again, as ranch's acceptor does, rather than end the
  # tunnels already open; any other refusal ends it, and with it the listener, which would
  # otherwise keep its port and accept nothing.
  defp accept(socket, listener) do
    case :gen_tcp.accept(socket) do
      {:ok, connection} -> hand_over(connection, listener)
      {:error, :closed} -> exit(:normal)
      {:error, :econnaborted} -> :ok
      {:error, reason} when reason in @passing -> Process.sleep(100)
      {:error, reason} -> exit({:accept, reason})
    end

    accept(socket, listener)
  end

  defp hand_over(connection, listener) do
    with {:ok, tunnel} <- GenServer.call(listener, :tunnel),
         :ok <- given(connection, tunnel) do
      send(tunnel, {:socket, connection})
    else
      _not_started -> :gen_tcp.close(connection)
    end
  end

  defp given(connection, tunnel) do
    case :gen_tcp.controlling_process(connection, tunnel) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        GenServer.stop(tunnel)
        error
    end
  end
end

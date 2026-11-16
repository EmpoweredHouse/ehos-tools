defmodule EhosTunnel.Client do
  @moduledoc """
  A local port that carries each connection made to it to the data gateway, one tunnel each
  (eh-os D-179, D-180). A program such as `psql` connects to the port on the loopback address;
  the client opens a `wss` WebSocket to the session's tunnel URL for that connection, presents
  the session's certificate, and passes the bytes both ways.

  It is a behaviour, so that a caller's tests replace it (T-20); `EhosTunnel.ClientImpl` is the
  implementation, and its documentation has the options and the events.
  """

  @typedoc "A running listener."
  @type listener :: pid()

  @typedoc "One tunnel, the process that carries one accepted connection."
  @type tunnel :: pid()

  @typedoc """
  What happens to a tunnel, given to the `:on_event` function:

  - `{:open, tunnel}`: the gateway took the tunnel, and bytes pass;
  - `{:refused, tunnel, refusal}`: the gateway refused it before the upgrade, with its status and
    `reason` word (`EhosTunnel.Protocol.refusal/2`);
  - `{:closed, tunnel, close}`: the gateway closed an open tunnel, with its close code and, for
    4001, the session's end reason (`EhosTunnel.Protocol.close/2`);
  - `{:failed, tunnel, reason}`: the gateway could not be reached or verified, or broke the
    protocol; `reason` is an exception (a TLS alert is a `Mint.TransportError`),
    `:no_subprotocol` when its answer did not name `ehos-tunnel.v1`, `:text_frame`,
    `{:bad_frame, reason}` for a frame that could not be read, or `:timeout` when the gateway did
    not answer the upgrade in time, or sent nothing, not even a ping, for the silence it allows;
  - `{:ended, tunnel}`: the local connection ended, and the tunnel was closed with 1000;
  - `{:stopped, reason}`: the listener stopped accepting connections and closed its tunnels:
    the system refused it a connection for a reason that does not pass (`{:accept, posix}`), or
    its acceptor ended otherwise. `close/1` is then not needed, and answers `:ok`.
  """
  @type event ::
          {:open, tunnel()}
          | {:refused, tunnel(), EhosTunnel.Protocol.refusal()}
          | {:closed, tunnel(), EhosTunnel.Protocol.close()}
          | {:failed, tunnel(),
             Exception.t() | :no_subprotocol | :text_frame | :timeout | {:bad_frame, term()}}
          | {:ended, tunnel()}
          | {:stopped, term()}

  @doc """
  Starts a listener on the loopback address, linked to the caller, that opens a tunnel for each
  connection it accepts. It answers `{:error, reason}`, a `:inet` error such as `:eaddrinuse`,
  when the port cannot be listened on, and raises `ArgumentError` for options it cannot use.
  """
  @callback listen(opts :: keyword()) :: {:ok, listener()} | {:error, term()}

  @doc "The port a listener listens on, the one the system chose when `:port` was 0."
  @callback port(listener()) :: :inet.port_number()

  @doc "Stops a listener, and closes each of its tunnels with 1001."
  @callback close(listener()) :: :ok
end

defmodule EhosTunnel.ClientImpl do
  @moduledoc """
  `EhosTunnel.Client` over Erlang's `:gen_tcp` and Mint's WebSocket client.

  `listen/1` takes:

  - `:url`, required: the session's tunnel URL, `wss://data.<host>/v1/sessions/<id>/tunnel`, as
    its `tunnel.url` says;
  - `:key`, required: the session's private key, from `EhosTunnel.Key.generate/0`;
  - `:certificate`: the certificate presented, by default `EhosTunnel.Certificate.self_signed/1`
    of the key;
  - `:cacerts`, a list of DER certificates, or `:cacertfile`, a PEM file: the CA the gateway's
    certificate is verified against: the gateway CA that EHOS gives as `gatewayCa`, and the
    caller keeps from its first login (eh-os D-181), never the system's roots. One is required;
    the gateway's certificate must also name the URL's host. Prefer `:cacerts`: Mint keeps what
    it read of each `:cacertfile` path for the life of the VM, so a file rewritten at the same
    path is not read again;
  - `:port`: the local port, 0 (the default) for one the system chooses;
  - `:on_event`: a function of one `t:EhosTunnel.Client.event/0`, called in the tunnel's or the
    listener's process; by default it does nothing;
  - `:upgrade_timeout`: how long a tunnel waits for the gateway to answer its upgrade, in
    milliseconds, 30 000 by default;
  - `:silence_timeout`: in milliseconds, by default `EhosTunnel.Protocol.silence_timeout/0`: an
    open tunnel that hears nothing from the gateway, a ping included, for between one and two of
    them closes with 1001.

  Each tunnel speaks TLS 1.3 alone and asks for the subprotocol `ehos-tunnel.v1`, which the
  gateway's answer must name. A local read larger than 1 MiB goes as several binary frames. The
  key stays in memory: it reaches `:ssl` as DER, never a file, and a crash report shows neither
  it nor the bytes a tunnel carries, in its state or its last message.

  The port is on the loopback address, where any process of the machine can connect to it, and
  so use the session; the database still asks for the session's password.

      key = EhosTunnel.Key.generate()
      # … open the session with EhosTunnel.Key.public_key(key) …
      {:ok, listener} =
        EhosTunnel.ClientImpl.listen(
          url: session["tunnel"]["url"],
          key: key,
          cacerts: [ca],
          on_event: fn event -> send(cli, {:tunnel, event}) end
        )

      port = EhosTunnel.ClientImpl.port(listener)
      # psql -h 127.0.0.1 -p <port> …
  """

  @behaviour EhosTunnel.Client

  alias EhosTunnel.Listener

  @listen_options [
    :binary,
    packet: :raw,
    active: false,
    ip: {127, 0, 0, 1},
    reuseaddr: true,
    nodelay: true
  ]

  # The socket is opened here, so that a port in use is an answer to the caller rather than a
  # listener's exit through the link; the listener then owns it.
  @impl EhosTunnel.Client
  def listen(opts) do
    config = Listener.config(opts)

    with {:ok, socket} <- :gen_tcp.listen(local_port(opts), @listen_options) do
      started(Listener.start_link(config, socket), socket)
    end
  end

  @impl EhosTunnel.Client
  def port(listener), do: GenServer.call(listener, :port)

  # A listener that stopped itself (`{:stopped, reason}`) is closed already.
  @impl EhosTunnel.Client
  def close(listener) do
    GenServer.stop(listener)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
  end

  defp local_port(opts) do
    case Keyword.get(opts, :port, 0) do
      port when port in 0..65_535 -> port
      _other -> raise ArgumentError, "give :port as a port number, or 0"
    end
  end

  defp started({:ok, listener}, socket) do
    case :gen_tcp.controlling_process(socket, listener) do
      :ok ->
        {:ok, listener}

      {:error, _reason} = error ->
        close(listener)
        :gen_tcp.close(socket)
        error
    end
  end

  defp started({:error, _reason} = error, socket) do
    :gen_tcp.close(socket)
    error
  end
end

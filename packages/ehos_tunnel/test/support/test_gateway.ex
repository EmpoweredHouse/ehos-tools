defmodule EhosTunnel.TestGateway do
  @moduledoc """
  A stand-in for the data gateway, for the client's tests: Bandit over TLS 1.3 on the loopback
  address, asking for a client certificate and taking a self-signed one, as eh-os D-179 says the
  gateway does. It tells the test the fingerprint of each certificate it saw, and answers by the
  session's identifier in the path:

  - `echo`: upgrades and sends each binary frame back; a frame `end` closes the tunnel with 4001
    and `revoked`, and a frame `ping` makes it ping the client;
  - `refuse-<reason>`: refuses with that reason's status and body, and `endReason` `expired` for
    `ended`;
  - `no-subprotocol`: upgrades without naming the subprotocol.

  The test gives its certificate and key, for `localhost`.
  """

  @behaviour Plug

  import Plug.Conn

  alias EhosTunnel.Protocol

  @doc """
  Starts the gateway under the test's supervisor with its certificate and key, telling `test` what
  it sees; answers its port.
  """
  @spec start(pid(), binary(), {atom(), binary()}) :: :inet.port_number()
  def start(test, certificate, key) do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: {__MODULE__, test},
         scheme: :https,
         ip: :loopback,
         port: 0,
         startup_log: false,
         thousand_island_options: [
           transport_options:
             [
               cert: certificate,
               key: key,
               versions: [:"tlsv1.3"]
             ] ++ EhosTunnel.Certificate.gateway_ssl_options()
         ]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @impl Plug
  def init(test), do: test

  @impl Plug
  def call(conn, test) do
    {:ok, spki} = EhosTunnel.Certificate.spki(get_peer_data(conn).ssl_cert)
    send(test, {:gateway, :fingerprint, EhosTunnel.Key.fingerprint(spki)})
    answer(conn, conn.path_info, test)
  end

  defp answer(conn, ["v1", "sessions", "echo", "tunnel"], test) do
    conn
    |> put_resp_header("sec-websocket-protocol", Protocol.subprotocol())
    |> WebSockAdapter.upgrade(EhosTunnel.TestGateway.Socket, test, [])
  end

  defp answer(conn, ["v1", "sessions", "no-subprotocol", "tunnel"], test),
    do: WebSockAdapter.upgrade(conn, EhosTunnel.TestGateway.Socket, test, [])

  defp answer(conn, ["v1", "sessions", "refuse-" <> word, "tunnel"], _test) do
    reason = Enum.find(Keyword.keys(Protocol.refusals()), &(Atom.to_string(&1) == word))
    end_reason = if reason == :ended, do: :expired

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      Protocol.refusal_status(reason),
      Protocol.refusal_body(reason, "Refused as the test asked.", end_reason)
    )
  end
end

defmodule EhosTunnel.TestGateway.Socket do
  @moduledoc "The test gateway's side of an open tunnel, as `EhosTunnel.TestGateway` describes it."

  @behaviour WebSock

  @impl WebSock
  def init(test), do: {:ok, test}

  @impl WebSock
  def handle_in({"end", opcode: :binary}, test), do: {:stop, :normal, {4001, "revoked"}, test}
  def handle_in({"ping", opcode: :binary}, test), do: {:push, {:ping, "are you there"}, test}
  def handle_in({data, opcode: :binary}, test), do: {:push, {:binary, data}, test}

  @impl WebSock
  def handle_control({payload, opcode: :pong}, test) do
    send(test, {:gateway, :pong, payload})
    {:ok, test}
  end

  def handle_control(_frame, test), do: {:ok, test}

  @impl WebSock
  def handle_info(_message, test), do: {:ok, test}
end

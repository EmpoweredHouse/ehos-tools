defmodule EhosTunnel.ClientTest do
  use ExUnit.Case, async: true

  alias EhosTunnel.{ClientImpl, Key, TestGateway}

  # P-256 and SHA-256: the test helper's default curve and digest are not TLS 1.3's.
  @p256 [key: {:namedCurve, :secp256r1}, digest: :sha256]

  setup do
    root = :public_key.pkix_test_root_cert(~c"ehos_tunnel test CA", @p256)
    localhost = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    server =
      :public_key.pkix_test_data(%{
        server_chain: %{root: root, intermediates: [], peer: @p256 ++ [extensions: [localhost]]},
        client_chain: %{root: root, intermediates: [], peer: @p256}
      })[:server_config]

    port = TestGateway.start(self(), server[:cert], server[:key])
    %{gateway: %{port: port, ca: root.cert}, key: Key.generate()}
  end

  describe "an open tunnel" do
    test "carries bytes both ways, and the gateway sees the session's key", ctx do
      {listener, local} = connect(ctx, "echo")
      assert_receive {:event, {:open, tunnel}}, 5_000

      :ok = :gen_tcp.send(local, "SELECT 1")

      assert {:ok, "SELECT 1"} = :gen_tcp.recv(local, 8, 5_000)
      assert_received {:gateway, :fingerprint, fingerprint}
      assert fingerprint == Key.fingerprint(Key.spki(ctx.key))

      :ok = :gen_tcp.close(local)
      assert_receive {:event, {:ended, ^tunnel}}, 5_000
      ClientImpl.close(listener)
    end

    test "carries a read larger than a frame as several frames, in order", ctx do
      {_listener, local} = connect(ctx, "echo")
      assert_receive {:event, {:open, _tunnel}}, 5_000
      data = :crypto.strong_rand_bytes(3 * 1_048_576 + 5)

      :ok = :gen_tcp.send(local, data)

      assert :gen_tcp.recv(local, byte_size(data), 10_000) == {:ok, data}
    end

    test "answers the gateway's ping", ctx do
      {_listener, local} = connect(ctx, "echo")
      assert_receive {:event, {:open, _tunnel}}, 5_000

      :ok = :gen_tcp.send(local, "ping")

      assert_receive {:gateway, :pong, "are you there"}, 5_000
    end

    test "reports the session's end, with its reason, and ends the local connection", ctx do
      {_listener, local} = connect(ctx, "echo")
      assert_receive {:event, {:open, tunnel}}, 5_000

      :ok = :gen_tcp.send(local, "end")

      assert_receive {:event, {:closed, ^tunnel, close}}, 5_000
      assert close == %{code: 4001, reason: :session_ended, end_reason: :revoked}
      assert :gen_tcp.recv(local, 0, 5_000) == {:error, :closed}
    end

    test "carries each local connection through a tunnel of its own", ctx do
      {listener, first} = connect(ctx, "echo")

      {:ok, second} =
        :gen_tcp.connect(~c"127.0.0.1", ClientImpl.port(listener), [:binary, active: false])

      assert_receive {:event, {:open, one}}, 5_000
      assert_receive {:event, {:open, other}}, 5_000

      :ok = :gen_tcp.send(first, "first")
      :ok = :gen_tcp.send(second, "second")

      assert one != other
      assert :gen_tcp.recv(first, 5, 5_000) == {:ok, "first"}
      assert :gen_tcp.recv(second, 6, 5_000) == {:ok, "second"}
    end

    test "closes with its listener", ctx do
      {listener, local} = connect(ctx, "echo")
      assert_receive {:event, {:open, _tunnel}}, 5_000
      port = ClientImpl.port(listener)

      :ok = ClientImpl.close(listener)

      assert :gen_tcp.recv(local, 0, 5_000) == {:error, :closed}

      assert :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false]) ==
               {:error, :econnrefused}
    end
  end

  describe "a tunnel the gateway does not open" do
    test "reports each refusal, with its status and reason", ctx do
      for {reason, status} <- EhosTunnel.Protocol.refusals() do
        {_listener, local} = connect(ctx, "refuse-#{reason}")

        assert_receive {:event, {:refused, _tunnel, refusal}}, 5_000

        assert refusal == %{
                 status: status,
                 reason: reason,
                 message: "Refused as the test asked.",
                 end_reason: if(reason == :ended, do: :expired)
               }

        assert :gen_tcp.recv(local, 0, 5_000) == {:error, :closed}
      end
    end

    test "fails when the gateway's answer does not name the subprotocol", ctx do
      {_listener, _local} = connect(ctx, "no-subprotocol")

      assert_receive {:event, {:failed, _tunnel, :no_subprotocol}}, 5_000
      refute_received {:event, {:open, _tunnel}}
    end

    test "fails when the gateway's certificate is not the given CA's", ctx do
      other_ca =
        :public_key.pkix_test_root_cert(~c"another CA",
          key: {:namedCurve, :secp256r1},
          digest: :sha256
        )

      {_listener, _local} = connect(%{ctx | gateway: %{ctx.gateway | ca: other_ca.cert}}, "echo")

      assert_receive {:event, {:failed, _tunnel, %Mint.TransportError{reason: reason}}}, 5_000
      assert {:tls_alert, {:unknown_ca, _text}} = reason
      refute_received {:gateway, :fingerprint, _fingerprint}
    end

    test "fails when the gateway's certificate does not name the URL's host", ctx do
      {_listener, _local} = connect(ctx, "echo", "127.0.0.1")

      assert_receive {:event, {:failed, _tunnel, %Mint.TransportError{reason: reason}}}, 5_000
      assert {:tls_alert, {:bad_certificate, _text}} = reason
    end
  end

  describe "listen/1" do
    test "listens on the loopback address alone, on the port given", ctx do
      {:ok, free} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(free)
      :ok = :gen_tcp.close(free)

      {:ok, listener} = ClientImpl.listen(options(ctx, "echo", "localhost") ++ [port: port])

      assert ClientImpl.port(listener) == port
      assert {:ok, {{127, 0, 0, 1}, ^port}} = :sys.get_state(listener).socket |> :inet.sockname()
    end

    test "refuses a URL that is not wss, and no CA", ctx do
      assert_raise ArgumentError, "the tunnel URL is not a wss:// URL with a host", fn ->
        ClientImpl.listen(
          Keyword.put(options(ctx, "echo", "localhost"), :url, "https://localhost/v1")
        )
      end

      assert_raise ArgumentError, "give the gateway's CA as :cacerts or :cacertfile", fn ->
        ClientImpl.listen(Keyword.delete(options(ctx, "echo", "localhost"), :cacerts))
      end
    end
  end

  defp connect(ctx, session, host \\ "localhost") do
    {:ok, listener} = ClientImpl.listen(options(ctx, session, host))

    {:ok, local} =
      :gen_tcp.connect(~c"127.0.0.1", ClientImpl.port(listener), [:binary, active: false])

    {listener, local}
  end

  defp options(ctx, session, host) do
    test = self()

    [
      url: EhosTunnel.Protocol.url("wss://#{host}:#{ctx.gateway.port}", session),
      key: ctx.key,
      cacerts: [ctx.gateway.ca],
      on_event: fn event -> send(test, {:event, event}) end
    ]
  end
end

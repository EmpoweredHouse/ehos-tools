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
    %{gateway: %{port: port, ca: root.cert}, server: server, key: Key.generate()}
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
      assert_receive {:gateway, :terminate, :remote}, 5_000
      ClientImpl.close(listener)
    end

    # The test gateway takes no frame over 1 MiB, as the gateway does. Loopback reads are smaller
    # than a frame, so this holds the order and the limit, not the split of a larger read.
    test "carries 3 MiB both ways, in order, in frames the gateway takes", ctx do
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

      assert_receive {:gateway, :terminate, :remote}, 5_000
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

  describe "a gateway that breaks the protocol" do
    test "fails a tunnel whose frame cannot be read, and closes it", ctx do
      # A frame with the reserved opcode 3, which RFC 6455 gives no meaning.
      port =
        raw_gateway(ctx, fn socket -> :ssl.send(socket, upgrade_answer(socket) <> <<0x83, 0>>) end)

      {_listener, local} = connect(%{ctx | gateway: %{ctx.gateway | port: port}}, "raw")

      assert_receive {:event, {:open, tunnel}}, 5_000
      assert_receive {:event, {:failed, ^tunnel, {:bad_frame, _reason}}}, 5_000
      assert :gen_tcp.recv(local, 0, 5_000) == {:error, :closed}
    end

    test "reads a frame the gateway sends in the same packet as its answer to the upgrade", ctx do
      port =
        raw_gateway(ctx, fn socket ->
          :ssl.send(socket, upgrade_answer(socket) <> <<0x88, 9, 4001::16, "revoked">>)
        end)

      {_listener, _local} = connect(%{ctx | gateway: %{ctx.gateway | port: port}}, "raw")

      assert_receive {:event, {:open, tunnel}}, 5_000
      assert_receive {:event, {:closed, ^tunnel, close}}, 5_000
      assert close == %{code: 4001, reason: :session_ended, end_reason: :revoked}
    end

    test "fails a tunnel whose upgrade the gateway does not answer", ctx do
      port = raw_gateway(ctx, fn _socket -> :ok end)
      opts = [upgrade_timeout: 200]
      {_listener, local} = connect(%{ctx | gateway: %{ctx.gateway | port: port}}, "raw", opts)

      assert_receive {:event, {:failed, _tunnel, :timeout}}, 5_000
      assert :gen_tcp.recv(local, 0, 5_000) == {:error, :closed}
    end

    test "fails an open tunnel from which the gateway sends nothing", ctx do
      port = raw_gateway(ctx, fn socket -> upgrade(socket) end)
      opts = [silence_timeout: 200]
      {_listener, local} = connect(%{ctx | gateway: %{ctx.gateway | port: port}}, "raw", opts)

      assert_receive {:event, {:open, tunnel}}, 5_000
      assert_receive {:event, {:failed, ^tunnel, :timeout}}, 5_000
      assert :gen_tcp.recv(local, 0, 5_000) == {:error, :closed}
    end

    test "reads a refusal whose body ends with the connection", ctx do
      body = EhosTunnel.Protocol.refusal_body(:refused, "Not yours.")

      port =
        raw_gateway(ctx, fn socket ->
          :ssl.send(socket, "HTTP/1.1 403 Forbidden\r\nconnection: close\r\n\r\n" <> body)
          :ssl.close(socket)
        end)

      {_listener, _local} = connect(%{ctx | gateway: %{ctx.gateway | port: port}}, "raw")

      assert_receive {:event, {:refused, _tunnel, refusal}}, 5_000
      assert refusal == %{status: 403, reason: :refused, message: "Not yours.", end_reason: nil}
    end

    test "reads a refusal from its status when its body is too long to read", ctx do
      port =
        raw_gateway(ctx, fn socket ->
          body = String.duplicate("x", 100_000)
          :ssl.send(socket, "HTTP/1.1 429 Too Many\r\ncontent-length: 100000\r\n\r\n" <> body)
        end)

      {_listener, _local} = connect(%{ctx | gateway: %{ctx.gateway | port: port}}, "raw")

      assert_receive {:event, {:refused, _tunnel, refusal}}, 5_000
      assert refusal == %{status: 429, reason: :too_many, message: nil, end_reason: nil}
    end
  end

  describe "listen/1" do
    test "listens on the loopback address alone", ctx do
      {:ok, listener} = ClientImpl.listen(options(ctx, "echo", "localhost"))
      port = ClientImpl.port(listener)

      assert {:ok, {{127, 0, 0, 1}, ^port}} = :inet.sockname(:sys.get_state(listener).socket)
    end

    test "answers an error, and stays linked to nothing, for a port in use", ctx do
      {:ok, taken} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(taken)
      links = Process.info(self(), :links)

      assert ClientImpl.listen(options(ctx, "echo", "localhost") ++ [port: port]) ==
               {:error, :eaddrinuse}

      assert Enum.sort(elem(Process.info(self(), :links), 1)) == Enum.sort(elem(links, 1))
    end

    test "refuses a URL that is not wss, a key that is not P-256, and no CA, naming no value",
         ctx do
      opts = options(ctx, "echo", "localhost")
      p384 = :public_key.generate_key({:namedCurve, :secp384r1})

      for {opts, message} <- [
            {Keyword.put(opts, :url, "https://localhost/v1"),
             "the tunnel URL is not a wss:// URL with a host"},
            {Keyword.delete(opts, :url), "the tunnel URL is not a wss:// URL with a host"},
            {Keyword.put(opts, :key, p384), "give the session's P-256 private key as :key"},
            {Keyword.delete(opts, :cacerts), "give the gateway's CA as :cacerts or :cacertfile"}
          ] do
        assert_raise ArgumentError, message, fn -> ClientImpl.listen(opts) end
      end
    end

    test "shows neither the key nor a tunnel's bytes in a status or crash report", ctx do
      {listener, _local} = connect(ctx, "echo")
      assert_receive {:event, {:open, tunnel}}, 5_000
      {:ECPrivateKey, _version, private, _curve, _point, _attributes} = ctx.key
      private_bytes = private |> :binary.bin_to_list() |> Enum.join(", ")

      for process <- [listener, tunnel] do
        report = inspect(:sys.get_status(process), limit: :infinity, printable_limit: :infinity)

        assert report =~ ":redacted"
        refute report =~ private_bytes
        refute report =~ Base.encode64(:public_key.der_encode(:ECPrivateKey, ctx.key))
      end
    end
  end

  defp connect(ctx, session, opts \\ [])

  defp connect(ctx, session, host) when is_binary(host),
    do: connect(ctx, session, [], host)

  defp connect(ctx, session, opts), do: connect(ctx, session, opts, "localhost")

  defp connect(ctx, session, opts, host) do
    {:ok, listener} = ClientImpl.listen(options(ctx, session, host) ++ opts)

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

  # A gateway on raw TLS, for what Bandit will not send: it takes the client's certificate as the
  # gateway does, reads the upgrade request, and hands the socket to `answer`.
  defp raw_gateway(%{server: server}, answer) do
    {:ok, listen} =
      :ssl.listen(
        0,
        [:binary, active: false, cert: server[:cert], key: server[:key], versions: [:"tlsv1.3"]] ++
          EhosTunnel.Certificate.gateway_ssl_options()
      )

    {:ok, {_address, port}} = :ssl.sockname(listen)

    spawn_link(fn ->
      {:ok, socket} = :ssl.transport_accept(listen)
      {:ok, socket} = :ssl.handshake(socket, 5_000)
      {:ok, request} = read_request(socket, "")
      Process.put(:request, request)
      answer.(socket)
      Process.sleep(:infinity)
    end)

    port
  end

  defp read_request(socket, read) do
    if String.contains?(read, "\r\n\r\n") do
      {:ok, read}
    else
      {:ok, more} = :ssl.recv(socket, 0, 5_000)
      read_request(socket, read <> more)
    end
  end

  defp upgrade(socket), do: :ok = :ssl.send(socket, upgrade_answer(socket))

  defp upgrade_answer(_socket) do
    [_, key] = Regex.run(~r/sec-websocket-key: (\S+)/i, Process.get(:request))
    accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

    "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: upgrade\r\n" <>
      "sec-websocket-accept: #{accept}\r\nsec-websocket-protocol: ehos-tunnel.v1\r\n\r\n"
  end
end

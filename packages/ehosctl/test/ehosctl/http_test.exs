defmodule Ehosctl.HTTPTest do
  # A request ends by its deadline: the whole download, not each part of it, and the caller's
  # own timeout when it gives one (the update notice's two seconds).
  use Ehosctl.Case, async: true

  alias Ehosctl.HTTPImpl

  describe "get/3" do
    test "a download that keeps sending ends at its deadline, not one part after another" do
      url = trickling_server()

      result =
        within(2_500, fn ->
          HTTPImpl.get(url <> "/slow", [], max_bytes: 1_000, timeout: 1_000)
        end)

      assert result == {:error, :unreachable, "#{url} did not answer."}
    end
  end

  describe "request/5" do
    test "reads a success no further than its bound" do
      url = endless_server("200 OK")

      result =
        within(5_000, fn ->
          HTTPImpl.request(:get, url <> "/api/v1", "token", nil, max_bytes: 64 * 1024)
        end)

      assert result ==
               {:ok, %{status: 200, body: nil, headers: %{"transfer-encoding" => "chunked"}}}
    end

    test "reads a refusal no further than a refusal's size" do
      url = endless_server("429 Too Many Requests")

      result =
        within(10_000, fn -> HTTPImpl.request(:get, url <> "/api/v1", "token", nil, []) end)

      assert result ==
               {:ok, %{status: 429, body: nil, headers: %{"transfer-encoding" => "chunked"}}}
    end

    test "ends by the caller's timeout" do
      url = silent_server()

      result =
        within(2_000, fn ->
          HTTPImpl.request(:get, url <> "/api/v1", "token", nil, timeout: 500)
        end)

      assert result == {:error, :unreachable, "#{url} did not answer.", :sent}
    end

    test "ends an answer that keeps coming by its deadline" do
      url = trickling_server()

      result =
        within(2_500, fn ->
          HTTPImpl.request(:get, url <> "/api/v1", "token", nil, timeout: 500)
        end)

      assert result == {:error, :unreachable, "#{url} did not answer.", :sent}
    end

    test "says a request that never had a connection was not sent" do
      url = closing_server()

      result =
        within(5_000, fn -> HTTPImpl.request(:post, url <> "/api/v1", "token", %{}, []) end)

      assert result == {:error, :unreachable, "#{url} did not answer."}
    end

    test "says a request that reached the server and got no answer may have been done" do
      for reply <- [nil, "HELLO\r\n\r\n"] do
        url = hanging_up_server(reply)

        result =
          within(5_000, fn ->
            HTTPImpl.request(:post, url <> "/api/commands/x", "token", %{}, [])
          end)

        assert result == {:error, :unreachable, "#{url} did not answer.", :sent}
      end
    end

    test "never sends a credential that could break a header" do
      url = silent_server()

      assert HTTPImpl.request(:get, url <> "/api/v1", "x\r\nx-evil: 1", nil, []) ==
               {:error, :failed,
                "ehosctl will not send a header holding a line break or non-ASCII"}
    end
  end

  describe "stream/5" do
    test "hands over what came, and ends as closed once nothing comes for its idle time" do
      url = hushed_server()

      result =
        within(2_000, fn ->
          HTTPImpl.stream(url <> "/tail", "token", [], collect(), idle: 300)
        end)

      assert result == {:closed, ["hello"]}
    end

    test "reads no further while a part is handled, so a slow reader is slow to read" do
      url =
        answering_server(
          "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n",
          ["3\r\none\r\n", "3\r\ntwo\r\n", "0\r\n\r\n"]
        )

      # While the first part is handled, the second is sent; it waits in the connection, not in the
      # handler's mailbox.
      handle = fn part, parts ->
        if parts == [], do: Process.sleep(400)
        {:messages, queued} = Process.info(self(), :messages)
        {:cont, [{part, queued} | parts]}
      end

      result =
        within(3_000, fn -> HTTPImpl.stream(url <> "/tail", "token", [], {[], handle}, []) end)

      assert result == {:closed, [{"two", []}, {"one", []}]}
    end

    test "gives a 200 of another type as an answer, not as events" do
      url =
        answering_server(
          "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: 15\r\n\r\n<p>Sign in</p>\n",
          []
        )

      result =
        within(2_000, fn -> HTTPImpl.stream(url <> "/tail", "token", [], collect(), []) end)

      assert result ==
               {:ok,
                %{
                  status: 200,
                  body: nil,
                  headers: %{"content-length" => "15", "content-type" => "text/html"}
                }}
    end

    test "reads any other answer within the request's timeout, however slowly it comes" do
      url =
        answering_server(
          "HTTP/1.1 502 Bad Gateway\r\ntransfer-encoding: chunked\r\n\r\n",
          List.duplicate("1\r\nx\r\n", 20)
        )

      result =
        within(2_000, fn ->
          HTTPImpl.stream(url <> "/tail", "token", [], collect(), timeout: 300)
        end)

      assert result ==
               {:ok, %{status: 502, body: nil, headers: %{"transfer-encoding" => "chunked"}}}
    end

    test "ends by its idle time when no answer begins" do
      url = silent_server()

      result =
        within(2_000, fn ->
          HTTPImpl.stream(url <> "/tail", "token", [], collect(), idle: 500)
        end)

      assert result == {:error, :unreachable, "#{url} did not answer."}
    end
  end

  defp within(milliseconds, fun) do
    task = Task.async(fun)

    case Task.yield(task, milliseconds) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> flunk("still waiting after #{milliseconds} ms")
    end
  end

  # A handler that keeps every part, newest first.
  defp collect, do: {[], fn part, parts -> {:cont, [part | parts]} end}

  # A socket that takes connections from this machine alone, and its port.
  defp listen do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listen)
    {listen, port}
  end

  # A server that takes a request and never answers it.
  defp silent_server do
    {listen, port} = listen()

    holder =
      spawn(fn ->
        {:ok, _socket} = :gen_tcp.accept(listen)
        Process.sleep(:infinity)
      end)

    :ok = :gen_tcp.controlling_process(listen, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    "http://localhost:#{port}"
  end

  # A server that answers 200 and then sends one byte every 200 ms, for as long as it is read.
  defp trickling_server do
    {listen, port} = listen()

    holder =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")

        Enum.reduce_while(1..100, :ok, fn _, :ok ->
          Process.sleep(200)
          sent(:gen_tcp.send(socket, "1\r\nx\r\n"))
        end)
      end)

    :ok = :gen_tcp.controlling_process(listen, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    "http://localhost:#{port}"
  end

  # Sending goes on until the client closes the connection.
  defp sent(:ok), do: {:cont, :ok}
  defp sent(_closed), do: {:halt, :ok}

  # A server that answers `status` and then sends a kilobyte at a time, for as long as it is read.
  defp endless_server(status) do
    {listen, port} = listen()

    holder =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        :gen_tcp.send(socket, "HTTP/1.1 #{status}\r\ntransfer-encoding: chunked\r\n\r\n")
        chunk = "400\r\n" <> String.duplicate("x", 1024) <> "\r\n"

        Enum.reduce_while(Stream.repeatedly(fn -> chunk end), :ok, fn chunk, :ok ->
          sent(:gen_tcp.send(socket, chunk))
        end)
      end)

    :ok = :gen_tcp.controlling_process(listen, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    "http://localhost:#{port}"
  end

  # A server that takes a connection and closes it at once, before any TLS handshake ends.
  defp closing_server do
    {listen, port} = listen()

    holder =
      spawn(fn ->
        Enum.each(Stream.repeatedly(fn -> :gen_tcp.accept(listen) end), fn
          {:ok, socket} -> :gen_tcp.close(socket)
          _error -> :ok
        end)
      end)

    :ok = :gen_tcp.controlling_process(listen, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    "https://localhost:#{port}"
  end

  # A server that begins an answer that does not end, sends one part, then goes silent.
  defp hushed_server do
    {listen, port} = listen()

    holder =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n" <>
            "5\r\nhello\r\n"
        )

        Process.sleep(:infinity)
      end)

    :ok = :gen_tcp.controlling_process(listen, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    "http://localhost:#{port}"
  end

  # A server that answers `head`, then sends each of `parts` as it is, 100 ms apart.
  defp answering_server(head, parts) do
    {listen, port} = listen()

    holder =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        :gen_tcp.send(socket, head)

        Enum.each(parts, fn part ->
          Process.sleep(100)
          :gen_tcp.send(socket, part)
        end)

        Process.sleep(:infinity)
      end)

    :ok = :gen_tcp.controlling_process(listen, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    "http://localhost:#{port}"
  end

  # A server that reads the request, then closes without answering, as an application that died
  # while doing it, or answers with `reply`, something that is not HTTP, as a broken proxy.
  defp hanging_up_server(reply) do
    {listen, port} = listen()

    holder =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        if reply, do: :gen_tcp.send(socket, reply)
        :gen_tcp.close(socket)
      end)

    :ok = :gen_tcp.controlling_process(listen, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    "http://localhost:#{port}"
  end
end

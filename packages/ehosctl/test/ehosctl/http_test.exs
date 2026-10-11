defmodule Ehosctl.HTTPTest do
  # A request ends by its deadline: the whole download, not each part of it, and the caller's
  # own timeout when it gives one (the update notice's two seconds).
  use ExUnit.Case, async: true

  alias Ehosctl.HTTP

  # A server that takes a request and never answers it.
  defp silent_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    holder =
      spawn(fn ->
        {:ok, _socket} = :gen_tcp.accept(listen)
        Process.sleep(:infinity)
      end)

    :ok = :gen_tcp.controlling_process(listen, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    "http://localhost:#{port}"
  end

  defp within(milliseconds, fun) do
    task = Task.async(fun)

    case Task.yield(task, milliseconds) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> flunk("still waiting after #{milliseconds} ms")
    end
  end

  # A server that answers 200 and then sends one byte every 200 ms, for as long as it is read.
  defp trickling_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    holder =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")

        Enum.reduce_while(1..100, :ok, fn _, :ok ->
          Process.sleep(200)

          case :gen_tcp.send(socket, "1\r\nx\r\n") do
            :ok -> {:cont, :ok}
            _closed -> {:halt, :ok}
          end
        end)
      end)

    :ok = :gen_tcp.controlling_process(listen, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    "http://localhost:#{port}"
  end

  test "a download that keeps sending ends at its deadline, not one part after another" do
    url = trickling_server()

    result =
      within(2_500, fn ->
        HTTP.get(url <> "/slow", [], max_bytes: 1_000, timeout: 1_000, env: %{})
      end)

    assert {:error, :unreachable, _} = result
  end

  test "request/5 ends by the caller's timeout" do
    url = silent_server()

    result =
      within(2_000, fn ->
        HTTP.request(:get, url <> "/api/v1", "token", nil, timeout: 500, env: %{})
      end)

    assert {:error, :unreachable, _message, :sent} = result
  end
end

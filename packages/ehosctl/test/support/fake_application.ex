defmodule Ehosctl.FakeApplication do
  @moduledoc """
  A fake application built on `eh_os_contract`, for the tests of `ehosctl call` and
  `ehosctl credential`: `EhOsContract.Plug`'s routes on a local port (Bypass), behind a check
  that the credential is one `Ehosctl.FakeProvider` issued for this application's address, as
  `EhOsContract.Auth.Plug` checks its audience.

  It answers a command or a recording with a receipt, and a query with its fields as one row,
  unless `answer/3` says otherwise. Every request is kept, for the tests to read (`requests/1`).
  """

  defstruct [:bypass, :address, :agent]

  @type t :: %__MODULE__{}

  @doc "Starts an application whose credentials `provider` issues."
  @spec start(Ehosctl.FakeProvider.t()) :: t()
  def start(provider) do
    bypass = Bypass.open()
    {:ok, agent} = Agent.start_link(fn -> %{requests: [], answer: nil} end)
    app = %__MODULE__{bypass: bypass, address: "http://localhost:#{bypass.port}", agent: agent}

    for {method, route} <- [{"POST", "commands"}, {"POST", "records"}, {"GET", "queries"}] do
      Bypass.stub(bypass, method, "/api/#{route}/:capability", &serve(&1, app, provider, route))
    end

    app
  end

  @doc """
  The requests it was sent, oldest first: `method`, `path`, `query`, `body` (decoded JSON, or
  `nil`), and the `authorization` and `idempotency-key` headers.
  """
  @spec requests(t()) :: [map()]
  def requests(app), do: app.agent |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "Makes it answer the next requests with `status` and `body` instead."
  @spec answer(t(), pos_integer(), term()) :: :ok
  def answer(app, status, body), do: Agent.update(app.agent, &%{&1 | answer: {status, body}})

  @doc "Takes the application down: nothing answers on its port."
  @spec down(t()) :: :ok
  def down(app), do: Bypass.down(app.bypass)

  defp serve(conn, app, provider, route) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    header = &List.first(Plug.Conn.get_req_header(conn, &1))

    request = %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      body: if(body == "", do: nil, else: JSON.decode!(body)),
      authorization: header.("authorization"),
      idempotency_key: header.("idempotency-key")
    }

    Agent.update(app.agent, &%{&1 | requests: [request | &1.requests]})

    case {Agent.get(app.agent, & &1.answer), request.authorization} do
      {{status, answer}, _authorization} ->
        json(conn, status, answer)

      {nil, "Bearer " <> token} ->
        if Ehosctl.FakeProvider.resource(provider, token) == app.address,
          do: json(conn, 200, accepted(route, request, conn)),
          else: json(conn, 401, %{"error" => "wrong_audience"})

      {nil, _none} ->
        json(conn, 401, %{"error" => "no_credential"})
    end
  end

  defp accepted("queries", _request, conn),
    do: %{"rows" => [URI.decode_query(conn.query_string)]}

  defp accepted(_route, request, _conn) do
    %{
      "command_id" => "0192d3a4-command",
      "identity" => if(id = request.body["entry_id"], do: %{"entry_id" => id}),
      "positions" => [7],
      "position" => 7,
      "duplicate" => false,
      "events" => [%{"type" => "ledger.entry_recorded", "position" => 7}]
    }
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end
end

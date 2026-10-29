defmodule Ehosctl.FakeHTTP do
  @moduledoc """
  Origins that answer `Ehosctl.HTTP` in a test, through its mock: what
  `Ehosctl.FakeProvider`, `Ehosctl.FakeApplication` and `Ehosctl.FakeGitHub` are served on, with
  no connection opened. A route is a plug, as it would be on a local port, and a request reaches
  it as a `Plug.Conn` with its method, path, query, headers and body as they would be sent.

  The answer comes back as `Ehosctl.HTTPImpl` gives it, for what a command reads of it: a
  redirect followed by none, a body read no further than `:max_bytes` or a refusal's size, and an
  origin that is down, or never opened, as one that did not answer. How `Ehosctl.HTTPImpl` itself
  reads a connection is its own test's, on a local port.

  A route may answer with what `Ehosctl.HTTP` returns instead of a `Plug.Conn`, as one that got
  no answer it can read: `{:error, :unreachable, message, :sent}`.

  The first `open/1` in a test stubs the mock with the test's origins; a test that
  says how one call answers expects it instead.
  """

  alias Ehosctl.HTTP

  defstruct [:origin, :routes]

  @type t :: %__MODULE__{origin: String.t(), routes: pid()}

  # As `Ehosctl.HTTPImpl` bounds them: a success, unless the request says, and any other answer.
  @max_request_bytes 16 * 1_048_576
  @max_answer_bytes 1_048_576

  @doc """
  Opens an origin with no route yet: `opts[:origin]`, or `https://localhost:<port>` on a port no
  other origin of the test has. An origin already open in the test raises, rather than dropping
  the routes it has: `Ehosctl.FakeGitHub` always opens GitHub's own.
  """
  @spec open(keyword()) :: t()
  def open(opts \\ []) do
    routes = routes()
    # As a request's URL is matched: the trailing slash and a default port go.
    origin = opts |> Keyword.get_lazy(:origin, &new_origin/0) |> origin()

    opened? =
      Agent.get_and_update(routes, fn origins ->
        if Map.has_key?(origins, origin),
          do: {false, origins},
          else: {true, Map.put(origins, origin, {:up, []})}
      end)

    unless opened?, do: raise(ArgumentError, "#{origin} is already open in this test")
    %__MODULE__{origin: origin, routes: routes}
  end

  @doc """
  Answers `method` at `path`, whose `:name` segments match any one segment, with `plug`, a
  function of the `Plug.Conn` that returns it with its answer. A later route for the same method
  and path replaces the earlier one.
  """
  @spec stub(t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t() | tuple())) :: :ok
  def stub(fake, method, path, plug) do
    Agent.update(fake.routes, fn origins ->
      Map.update!(origins, fake.origin, fn {state, routes} ->
        {state,
         [{method, path, plug} | Enum.reject(routes, &match?({^method, ^path, _plug}, &1))]}
      end)
    end)
  end

  @doc """
  Answers `method` at `path` with `plug` once, as `stub/4` does: a second request fails the test,
  and so does none by its end.
  """
  @spec expect_once(t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t() | tuple())) ::
          :ok
  def expect_once(fake, method, path, plug) do
    # Counted outside any process of the test's, which are gone by `on_exit/1`.
    calls = :counters.new(1, [])
    route = "#{method} #{fake.origin}#{path}"

    ExUnit.Callbacks.on_exit(fn ->
      unless :counters.get(calls, 1) == 1, do: raise("#{route} was expected once, and not sent")
    end)

    stub(fake, method, path, fn conn ->
      :counters.add(calls, 1, 1)
      if :counters.get(calls, 1) > 1, do: raise("#{route} was sent again")
      plug.(conn)
    end)
  end

  @doc "Takes the origin down: a request to it gets no answer, until `up/1`."
  @spec down(t()) :: :ok
  def down(fake), do: put_state(fake, :down)

  @doc "Brings the origin up again, with the routes it had."
  @spec up(t()) :: :ok
  def up(fake), do: put_state(fake, :up)

  defp put_state(fake, state),
    do:
      Agent.update(
        fake.routes,
        &Map.update!(&1, fake.origin, fn {_state, routes} -> {state, routes} end)
      )

  # The test's origins, started and stubbed by its first `open/1`.
  defp routes do
    case Process.get(__MODULE__) do
      nil ->
        {:ok, routes} = Agent.start_link(fn -> %{} end)
        Process.put(__MODULE__, routes)
        stub_mock(routes)
        routes

      routes ->
        routes
    end
  end

  defp stub_mock(routes) do
    Hammox.stub(Ehosctl.HTTPMock, :request, fn method, url, credential, body, opts ->
      request(routes, method, url, credential, body, opts)
    end)

    Hammox.stub(Ehosctl.HTTPMock, :get, fn url, headers, opts ->
      get(routes, url, headers, opts)
    end)

    Hammox.stub(Ehosctl.HTTPMock, :stream, fn url, credential, headers, handler, opts ->
      stream(routes, url, credential, headers, handler, opts)
    end)
  end

  defp request(routes, method, url, credential, body, opts) do
    headers = authorization(credential) ++ [{"accept", "application/json"}]
    {content, headers} = content(method, body, headers ++ Keyword.get(opts, :headers, []))
    origin = origin(url)

    case serve(routes, method, url, headers, content) do
      {:ok, %{status: status}} when status in 300..399 ->
        redirected(origin)

      {:ok, %{status: status} = conn} ->
        max_bytes =
          if status in 200..299,
            do: Keyword.get(opts, :max_bytes, @max_request_bytes),
            else: @max_answer_bytes

        body = if byte_size(body(conn)) > max_bytes, do: nil, else: decode(body(conn))
        {:ok, %{status: status, headers: headers(conn), body: body}}

      {:answer, answer} ->
        answer

      :down ->
        HTTP.unreachable(origin)
    end
  end

  defp get(routes, url, headers, opts) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    origin = origin(url)

    case serve(routes, :get, url, headers, nil) do
      {:ok, conn} ->
        if byte_size(body(conn)) > max_bytes,
          do:
            {:error, :failed,
             "#{origin} answered with more than #{max_bytes} bytes, more than ehosctl reads from it."},
          else: {:ok, %{status: conn.status, headers: headers(conn), body: body(conn)}}

      {:answer, answer} ->
        answer

      :down ->
        HTTP.unreachable(origin)
    end
  end

  # The body of an event stream reaches `handle` as one part, as it came.
  defp stream(routes, url, credential, headers, {acc, handle}, _opts) do
    origin = origin(url)

    case serve(routes, :get, url, authorization(credential) ++ headers, nil) do
      {:ok, %{status: status}} when status in 300..399 ->
        redirected(origin)

      {:ok, %{status: 200} = conn} ->
        if String.starts_with?(headers(conn)["content-type"] || "", "text/event-stream"),
          do: events(body(conn), acc, handle),
          else: {:ok, %{status: 200, headers: headers(conn), body: decode(body(conn))}}

      {:ok, conn} ->
        {:ok, %{status: conn.status, headers: headers(conn), body: decode(body(conn))}}

      {:answer, answer} ->
        answer

      :down ->
        HTTP.unreachable(origin)
    end
  end

  defp events("", acc, _handle), do: {:closed, acc}

  defp events(part, acc, handle) do
    case handle.(part, acc) do
      {:cont, acc} -> {:closed, acc}
      {:halt, result} -> {:halted, result}
    end
  end

  defp serve(routes, method, url, headers, content) do
    %URI{path: path} = uri = URI.parse(url)
    method = method |> to_string() |> String.upcase()

    case Agent.get(routes, &Map.get(&1, origin(url))) do
      {:up, origin_routes} ->
        plug = route(origin_routes, method, path || "/") || raise "no route for #{method} #{url}"

        conn =
          Enum.reduce(
            headers,
            Plug.Test.conn(
              method,
              URI.to_string(%{uri | scheme: nil, host: nil, port: nil}),
              content || ""
            ),
            fn {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value) end
          )

        case plug.(conn) do
          %Plug.Conn{} = conn -> {:ok, conn}
          answer -> {:answer, answer}
        end

      _down_or_never_opened ->
        :down
    end
  end

  defp route(routes, method, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, fn {route_method, route_path, plug} ->
      if route_method == method and matches?(String.split(route_path, "/", trim: true), segments),
        do: plug
    end)
  end

  defp matches?(route, segments) do
    length(route) == length(segments) and
      route
      |> Enum.zip(segments)
      |> Enum.all?(fn {part, segment} -> String.starts_with?(part, ":") or part == segment end)
  end

  defp authorization(nil), do: []
  defp authorization(credential), do: [{"authorization", "Bearer " <> credential}]

  # As `Ehosctl.HTTPImpl` sends a body.
  defp content(:get, _body, headers), do: {nil, headers}
  defp content(:delete, nil, headers), do: {nil, headers}
  defp content(_method, :none, headers), do: {nil, headers}

  defp content(_method, {:raw, content_type, bytes}, headers),
    do: {bytes, [{"content-type", content_type} | headers]}

  defp content(_method, body, headers),
    do: {JSON.encode!(body || %{}), [{"content-type", "application/json"} | headers]}

  # A chunked answer's body is the chunks sent, which `Plug.Test` keeps in its adapter.
  defp body(%Plug.Conn{state: :chunked, adapter: {_adapter, %{chunks: chunks}}}), do: chunks
  defp body(conn), do: conn.resp_body || ""

  # A server dates its answers (RFC 9110, 6.6.1), as Cowboy does, unless the route did.
  defp headers(conn) do
    conn.resp_headers
    |> Enum.group_by(fn {name, _value} -> String.downcase(name) end, &elem(&1, 1))
    |> Map.new(fn {name, values} -> {name, Enum.join(values, ", ")} end)
    |> Map.put_new_lazy("date", fn ->
      Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
    end)
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp redirected(origin),
    do:
      {:error, :failed,
       "#{origin} redirected a request that carries your credential; ehosctl did not follow"}

  defp origin(url) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    URI.to_string(%URI{scheme: scheme, host: host, port: port})
  end

  defp new_origin,
    do: "https://localhost:#{20_000 + rem(System.unique_integer([:positive]), 40_000)}"
end

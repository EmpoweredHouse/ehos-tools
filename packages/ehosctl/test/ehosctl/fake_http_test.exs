defmodule Ehosctl.FakeHTTPTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP

  @date "Thu, 29 Oct 2026 12:00:00 GMT"

  test "opening an origin already open raises, and keeps the routes it has" do
    github = FakeGitHub.start()
    FakeHTTP.stub(github, "GET", "/", &up/1)

    for origin <- [
          "https://api.github.com",
          "https://api.github.com:443",
          "https://api.github.com/"
        ] do
      assert_raise ArgumentError, "https://api.github.com is already open in this test", fn ->
        FakeHTTP.open(origin: origin)
      end
    end

    assert Ehosctl.HTTP.current().get("https://api.github.com/", [], max_bytes: 10) ==
             {:ok,
              %{
                status: 200,
                headers: %{
                  "cache-control" => "max-age=0, private, must-revalidate",
                  "date" => @date
                },
                body: "up"
              }}
  end

  # Dated by the route, so the whole answer is known.
  defp up(conn) do
    conn
    |> Plug.Conn.put_resp_header("date", @date)
    |> Plug.Conn.resp(200, "up")
  end
end

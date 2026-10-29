defmodule Ehosctl.FakeHTTPTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP

  test "opening an origin already open raises, and keeps the routes it has" do
    github = FakeGitHub.start()
    FakeHTTP.stub(github, "GET", "/", &Plug.Conn.resp(&1, 200, "up"))

    for origin <- [
          "https://api.github.com",
          "https://api.github.com:443",
          "https://api.github.com/"
        ] do
      assert_raise ArgumentError, "https://api.github.com is already open in this test", fn ->
        FakeHTTP.open(origin: origin)
      end
    end

    assert {:ok, %{status: 200, body: "up"}} =
             Ehosctl.HTTP.current().get("https://api.github.com/", [], max_bytes: 10)
  end
end

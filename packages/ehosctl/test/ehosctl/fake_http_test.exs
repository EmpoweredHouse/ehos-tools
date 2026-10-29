defmodule Ehosctl.FakeHTTPTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.FakeHTTP

  test "opening an origin already open raises, rather than dropping its routes" do
    github = FakeHTTP.open(origin: "https://api.github.com")
    FakeHTTP.stub(github, "GET", "/", &Plug.Conn.resp(&1, 200, ""))

    assert_raise ArgumentError, "https://api.github.com is already open in this test", fn ->
      FakeHTTP.open(origin: "https://api.github.com")
    end
  end
end

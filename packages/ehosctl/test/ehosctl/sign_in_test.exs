defmodule Ehosctl.SignInTest do
  use ExUnit.Case, async: true

  alias Ehosctl.SignIn
  alias Ehosctl.SignIn.Loopback

  doctest Ehosctl.SignIn

  describe "origin/1" do
    test "keeps an origin, lowercased, without a trailing slash" do
      assert SignIn.origin("https://ehos.example.com") == {:ok, "https://ehos.example.com"}

      assert SignIn.origin("https://ehos.example.com:8443/") ==
               {:ok, "https://ehos.example.com:8443"}
    end

    test "allows plain HTTP on this machine alone" do
      for url <-
            ~w(http://localhost:4000 http://127.0.0.1:4000 http://[::1]:4000 http://ehos.localhost) do
        assert {:ok, ^url} = SignIn.origin(url)
      end

      assert {:error, :invalid, message} = SignIn.origin("http://ehos.example.com")
      assert message =~ "is plain HTTP"
    end

    test "refuses anything but an origin" do
      for url <- [
            "https://ehos.example.com/console",
            "https://ehos.example.com/?a=b",
            "https://ehos.example.com/#x",
            "https://grace:secret@ehos.example.com",
            "https://ehos.example.com\u202E",
            "https://ehos.example.com\n",
            "https://ehos example.com",
            "file:///etc/passwd",
            "https://",
            ""
          ] do
        assert {:error, :invalid, _} = SignIn.origin(url), inspect(url)
      end
    end
  end

  describe "callback/3" do
    @request %{state: "the-state", nonce: "n", verifier: "v", redirect_uri: "r"}
    @issuer "https://ehos.example.com"

    test "gives the code of this request, from this issuer" do
      params = %{"state" => "the-state", "iss" => @issuer, "code" => "c"}
      assert SignIn.callback(params, @request, @issuer) == {:ok, "c"}
    end

    test "passes over another request's answer" do
      assert SignIn.callback(
               %{"state" => "other", "iss" => @issuer, "code" => "c"},
               @request,
               @issuer
             ) ==
               :ignore

      assert SignIn.callback(%{"iss" => @issuer, "code" => "c"}, @request, @issuer) == :ignore
    end

    test "refuses an answer from another issuer, or naming none" do
      for iss <- ["https://evil.example.com", nil] do
        params = %{"state" => "the-state", "iss" => iss, "code" => "c"}
        assert {:error, :failed, _} = SignIn.callback(params, @request, @issuer)
      end
    end

    test "an error EHOS sent back is a refusal, printed safely" do
      params = %{"state" => "the-state", "iss" => @issuer, "error" => "access_denied\e[2J"}
      assert {:error, :refused, message} = SignIn.callback(params, @request, @issuer)
      refute message =~ "\e"
    end
  end

  describe "the loopback listener" do
    test "answers another path with a 404 and waits on for the callback" do
      {:ok, listener} = Loopback.open()
      uri = Loopback.redirect_uri(listener)
      assert uri =~ ~r{\Ahttp://127\.0\.0\.1:\d+/callback\z}
      base = String.replace_suffix(uri, "/callback", "")

      waiting =
        Task.async(fn ->
          Loopback.await(listener, 5_000, fn params -> {:done, params, "Done."} end)
        end)

      {:ok, {{_, 404, _}, _, _}} = :httpc.request(String.to_charlist(base <> "/favicon.ico"))

      {:ok, {{_, 200, _}, headers, body}} =
        :httpc.request(String.to_charlist(uri <> "?code=c&state=s"))

      assert Task.await(waiting) == {:ok, %{"code" => "c", "state" => "s"}}
      assert {~c"referrer-policy", ~c"no-referrer"} in headers
      assert to_string(body) =~ "Done."
      Loopback.close(listener)
    end

    test "gives up after its timeout" do
      {:ok, listener} = Loopback.open()
      assert Loopback.await(listener, 50, fn _ -> {:done, :x, ""} end) == {:error, :timeout}
      Loopback.close(listener)
    end
  end
end

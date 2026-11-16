defmodule EhosTunnel.ProtocolTest do
  use ExUnit.Case, async: true

  alias EhosTunnel.Protocol

  test "the subprotocol, the path and the bounds are D-179's" do
    assert Protocol.subprotocol() == "ehos-tunnel.v1"

    assert Protocol.url("wss://data.ehos.example.com/", "s1") ==
             "wss://data.ehos.example.com/v1/sessions/s1/tunnel"

    assert {Protocol.max_frame_size(), Protocol.ping_interval(), Protocol.silence_timeout()} ==
             {1_048_576, 30_000, 90_000}
  end

  test "the refusals and the close codes are D-179's" do
    assert Protocol.refusals() == [
             malformed: 400,
             refused: 403,
             ended: 409,
             too_many: 429,
             instance_unreachable: 502,
             unavailable: 503
           ]

    assert Protocol.closes() == [
             normal: 1000,
             going_away: 1001,
             text_frame: 1003,
             too_big: 1009,
             failed: 1011,
             session_ended: 4001
           ]

    assert :revoked in Protocol.end_reasons()
  end

  describe "refusal/2" do
    test "reads back every refusal the gateway writes" do
      for {reason, status} <- Protocol.refusals() do
        body = Protocol.refusal_body(reason, "Why.")

        assert Protocol.refusal(Protocol.refusal_status(reason), body) ==
                 %{status: status, reason: reason, message: "Why.", end_reason: nil}
      end
    end

    test "reads an ended session's end reason" do
      assert Protocol.refusal(409, Protocol.refusal_body(:ended, "It ended.", :revoked)) ==
               %{status: 409, reason: :ended, message: "It ended.", end_reason: :revoked}
    end

    test "keeps a word this version does not know as it came" do
      body = ~s({"error": {"reason": "busy", "message": "Later.", "endReason": "moved"}})

      assert Protocol.refusal(429, body) ==
               %{status: 429, reason: "busy", message: "Later.", end_reason: "moved"}
    end

    test "gives the status's reason for a body that is not a refusal's, and none for another status" do
      assert Protocol.refusal(503, "<html>Service Unavailable</html>") ==
               %{status: 503, reason: :unavailable, message: nil, end_reason: nil}

      assert Protocol.refusal(404, ~s({"error": "nope"})) ==
               %{status: 404, reason: nil, message: nil, end_reason: nil}
    end
  end

  describe "close/2" do
    test "reads each close code, and the end reason of 4001 alone" do
      assert Protocol.close(4001, "revoked") == %{
               code: 4001,
               reason: :session_ended,
               end_reason: :revoked
             }

      assert Protocol.close(1001, "revoked") == %{
               code: 1001,
               reason: :going_away,
               end_reason: nil
             }

      assert Protocol.close(4999, "") == %{code: 4999, reason: 4999, end_reason: nil}
      assert Protocol.close(nil, nil) == %{code: nil, reason: nil, end_reason: nil}
    end
  end
end

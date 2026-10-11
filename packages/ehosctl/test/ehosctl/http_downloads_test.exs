defmodule Ehosctl.HTTPDownloadsTest do
  # `HTTP.get/3`'s profile reads release files eight at a time, whoever started it. Not async:
  # it stops and starts the profile the other tests use.
  use ExUnit.Case, async: false

  alias Ehosctl.HTTP

  @profile :ehosctl_downloads

  test "a profile another caller started has its options before a request is sent" do
    _stopped = :inets.stop(:httpc, @profile)
    {:ok, _pid} = :inets.start(:httpc, profile: @profile)
    assert {:ok, [max_sessions: 2]} = :httpc.get_options([:max_sessions], @profile)

    # Nothing listens there: the request fails at once, after the options are set.
    assert {:error, _kind, _message} =
             HTTP.get("http://localhost:1/release.json", [], max_bytes: 10, env: %{})

    assert {:ok, [max_sessions: 8]} = :httpc.get_options([:max_sessions], @profile)
  end
end

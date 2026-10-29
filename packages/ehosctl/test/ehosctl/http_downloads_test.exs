defmodule Ehosctl.HTTPDownloadsTest do
  # `HTTP.get/3`'s profile reads release files eight at a time, whoever started it. Not async:
  # it stops and starts the profile the other tests use.
  use Ehosctl.Case, async: false

  alias Ehosctl.HTTPImpl

  @profile :ehosctl_downloads

  describe "get/3" do
    test "reads release files eight at a time, in a profile another caller started" do
      _stopped = :inets.stop(:httpc, @profile)
      {:ok, _pid} = :inets.start(:httpc, profile: @profile)
      assert :httpc.get_options([:max_sessions], @profile) == {:ok, [max_sessions: 2]}

      # Nothing listens there: the request fails at once, after the options are set.
      assert HTTPImpl.get("http://localhost:1/release.json", [], max_bytes: 10) ==
               {:error, :unreachable, "http://localhost:1 did not answer."}

      assert :httpc.get_options([:max_sessions], @profile) == {:ok, [max_sessions: 8]}
    end
  end
end

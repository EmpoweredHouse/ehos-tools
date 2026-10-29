defmodule Mix.Tasks.EhosApp.InstallTest.HealthEndpoints do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "the health endpoints" do
    test "are a plug of their own, tested" do
      igniter = installed()
      health = content(igniter, "lib/test_web/health.ex")
      health_test = content(igniter, "test/test_web/health_test.exs")

      assert lines_starting(health, "defmodule ") == ["defmodule TestWeb.Health do"]

      assert lines(health, ~s|  get "/health/ready" do|, "  end") == """
               get "/health/ready" do
                 if EhOsContract.Auth.ready?(),
                   do: send_resp(conn, 200, "ready"),
                   else: send_resp(conn, 503, "no keys")
               end
             """

      assert lines_starting(health_test, "defmodule ") == ["defmodule TestWeb.HealthTest do"]
    end
  end
end

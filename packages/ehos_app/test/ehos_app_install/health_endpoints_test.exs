defmodule Mix.Tasks.EhosApp.InstallTest.HealthEndpoints do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "the health endpoints" do
    test "are a plug of their own, tested" do
      igniter = installed()

      assert content(igniter, "lib/test_web/health.ex") =~ "defmodule TestWeb.Health do"
      assert content(igniter, "lib/test_web/health.ex") =~ "EhOsContract.Auth.ready?()"

      assert content(igniter, "test/test_web/health_test.exs") =~
               "defmodule TestWeb.HealthTest do"
    end
  end
end

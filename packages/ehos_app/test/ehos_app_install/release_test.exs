defmodule Mix.Tasks.EhosApp.InstallTest.Release do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "the release and the image" do
    test "generates the release and the Dockerfile through Phoenix, then gives it the build secret" do
      assert install().tasks == [
               {"phx.gen.release", ["--docker"]},
               {"ehos_app.dockerfile", ["--yes"]}
             ]
    end

    test "writes under /tmp alone, and starts no distribution" do
      env = installed() |> content("rel/env.sh.eex")

      assert env =~ ~s|export RELEASE_TMP="${RELEASE_TMP:-/tmp}"|
      assert env =~ "export RELEASE_DISTRIBUTION=none"
    end
  end
end

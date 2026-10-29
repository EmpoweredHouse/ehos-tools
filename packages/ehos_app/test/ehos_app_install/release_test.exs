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
      assert_creates(install(), "rel/env.sh.eex", """
      #!/bin/sh

      # EHOS runs the release under Pod Security `restricted`, where the image's filesystem may be
      # read-only, so the release writes under /tmp alone. One replica, and nothing connects to it,
      # so the VM starts no distribution and no epmd.
      export RELEASE_DISTRIBUTION=none
      export RELEASE_TMP="${RELEASE_TMP:-/tmp}"
      export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"
      """)
    end
  end
end

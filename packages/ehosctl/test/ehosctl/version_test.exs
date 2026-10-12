defmodule Ehosctl.VersionTest do
  # What a release of ehosctl says about itself (eh-os D-91, docs/releases.md in eh-os).
  # Not async: one test reads the pin through `Template.install_dep/0`, which
  # `EHOSCTL_TEMPLATE_SOURCE` changes, and `Ehosctl.TemplateTest` sets that variable.
  use ExUnit.Case, async: false

  alias Ehosctl.{Template, Version}

  doctest Version
  doctest Ehosctl, only: [upgrade_command: 1]

  @commit "0123456789abcdef0123456789abcdef01234567"

  test "describes this build: its version, the commit it is told, and the ehos_app it pins" do
    assert Version.release(commit: @commit) == %{
             "schema" => "ehos.release/v1",
             "component" => "ehosctl",
             "version" => Ehosctl.version(),
             "commit" => @commit,
             "produces" => [],
             "accepts" => ["ehos.api/v1", "eh_os_contract.api/v1"],
             "requires" => %{},
             "pins" => %{"ehos_app" => Template.template_version()}
           }
  end

  test "pins the ehos_app version init requires" do
    {:ok, {:ehos_app, "== " <> version, _opts}} = Template.install_dep()
    assert Version.release(commit: @commit)["pins"] == %{"ehos_app" => version}
  end

  test "the version is mix.exs's, the one the release job compares with the tag" do
    assert Version.release(commit: @commit)["version"] == Mix.Project.config()[:version]
  end

  describe "mix ehosctl.release_file" do
    @describetag :tmp_dir

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "writes the release's description as JSON", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")
      Mix.Tasks.Ehosctl.ReleaseFile.run(["--commit", @commit, "--output", output])

      assert JSON.decode!(File.read!(output)) == Version.release(commit: @commit)
      assert_received {:mix_shell, :info, ["wrote " <> ^output]}
    end

    test "refuses a missing, short or malformed commit, and an argument it does not take",
         %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")

      for args <- [
            ["--output", output],
            ["--commit", "0123456", "--output", output],
            ["--commit", String.upcase(@commit), "--output", output],
            ["--commit", @commit, "--output", output, "extra"]
          ] do
        assert_raise Mix.Error, fn -> Mix.Tasks.Ehosctl.ReleaseFile.run(args) end
      end

      refute File.exists?(output)
    end
  end
end

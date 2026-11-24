defmodule Ehosctl.VersionTest do
  # What a release of ehosctl says about itself (eh-os D-91, docs/releases.md in eh-os).
  use Ehosctl.Case, async: true

  import ExUnit.CaptureIO

  alias Ehosctl.{Template, Version}

  doctest Version
  doctest Ehosctl, only: [upgrade_command: 1]

  @commit "0123456789abcdef0123456789abcdef01234567"

  describe "release/1" do
    test "describes this build: its version, the commit it is told, and the ehos_app it pins" do
      assert Version.release(commit: @commit) == %{
               "schema" => "ehos.release/v1",
               "component" => "ehosctl",
               "version" => Ehosctl.version(),
               "commit" => @commit,
               "produces" => [],
               "accepts" => ["ehos.api/v1", "ehos_contract.api/v1", "eh_os_contract.api/v1"],
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
  end

  describe "mix ehosctl.release_file" do
    @describetag :tmp_dir

    # What the task says is read from `Mix.Shell.IO`, the shell every test shares, through this
    # test's own stdout: swapping the shell would take what another async test's task prints.
    test "writes the release's description as JSON", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")

      assert capture_io(fn ->
               Mix.Tasks.Ehosctl.ReleaseFile.run(["--commit", @commit, "--output", output])
             end) == "wrote #{output}\n"

      assert JSON.decode!(File.read!(output)) == Version.release(commit: @commit)
    end

    test "refuses a missing, short or malformed commit, and an argument it does not take",
         %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")

      usage = "Usage: mix ehosctl.release_file --commit <sha> [--output <path>]"
      short = ~s(--commit is a full commit, 40 hexadecimal digits, not "0123456")

      upper =
        ~s(--commit is a full commit, 40 hexadecimal digits, not "#{String.upcase(@commit)}")

      for {args, message} <- [
            {["--output", output], usage},
            {["--commit", "0123456", "--output", output], short},
            {["--commit", String.upcase(@commit), "--output", output], upper},
            {["--commit", @commit, "--output", output, "extra"], usage}
          ] do
        assert_raise Mix.Error, message, fn -> Mix.Tasks.Ehosctl.ReleaseFile.run(args) end
      end

      refute File.exists?(output)
    end
  end
end

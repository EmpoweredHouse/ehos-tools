defmodule EhosApp.ReleaseTest do
  # What a release of ehos_app says about itself (eh-os D-91, docs/releases.md in eh-os).
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  doctest EhosApp

  @commit "0123456789abcdef0123456789abcdef01234567"

  test "describes this version, the commit it is told, and the ehos.yaml it produces" do
    assert EhosApp.release(@commit) == %{
             "schema" => "ehos.release/v1",
             "component" => "ehos_app",
             "version" => Mix.Project.config()[:version],
             "commit" => @commit,
             "produces" => [EhosApp.ehos_yaml_version()],
             "accepts" => [],
             "requires" => %{
               "eh_os_contract" => "~> 0.14.0",
               "eh_os_contract_auth" => "~> 0.12.0",
               "ehos_design" => "~> 0.6.0"
             }
           }
  end

  describe "mix ehos_app.release_file" do
    @describetag :tmp_dir

    test "writes the release's description as JSON, and says where", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")

      assert capture_io(fn ->
               Mix.Task.rerun("ehos_app.release_file", ["--commit", @commit, "--output", output])
             end) == "wrote #{output}\n"

      assert JSON.decode!(File.read!(output)) == EhosApp.release(@commit)
    end

    test "refuses a missing or short commit, and an argument it does not take", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")

      for args <- [
            ["--output", output],
            ["--commit", "0123456", "--output", output],
            ["--commit", @commit, "--output", output, "extra"]
          ] do
        assert_raise Mix.Error,
                     "Usage: mix ehos_app.release_file --commit <full sha> [--output <path>]",
                     fn -> Mix.Task.rerun("ehos_app.release_file", args) end
      end

      refute File.exists?(output)
    end
  end
end

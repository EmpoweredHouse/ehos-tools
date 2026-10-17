defmodule EhosApp.ReleaseTest do
  # What a release of ehos_app says about itself (eh-os D-91, docs/releases.md in eh-os).
  # Not async: the alias's test swaps Mix's shell, which is the VM's.
  use ExUnit.Case, async: false

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
               "eh_os_contract" => "~> 0.6.0",
               "eh_os_contract_auth" => "~> 0.3.0",
               "ehos_design" => "~> 0.2.0"
             }
           }
  end

  describe "mix ehos_app.release_file" do
    @describetag :tmp_dir

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "writes the release's description as JSON", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")
      Mix.Task.rerun("ehos_app.release_file", ["--commit", @commit, "--output", output])

      assert JSON.decode!(File.read!(output)) == EhosApp.release(@commit)
    end

    test "refuses a missing or short commit, and an argument it does not take", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")

      for args <- [
            ["--output", output],
            ["--commit", "0123456", "--output", output],
            ["--commit", @commit, "--output", output, "extra"]
          ] do
        assert_raise Mix.Error, fn -> Mix.Task.rerun("ehos_app.release_file", args) end
      end

      refute File.exists?(output)
    end
  end
end

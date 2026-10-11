defmodule EhosDesign.ReleaseTest do
  # What a release of ehos_design says about itself (eh-os D-91, docs/releases.md in eh-os).
  # Not async: the alias's test swaps Mix's shell, which is the VM's.
  use ExUnit.Case, async: false

  doctest EhosDesign

  @commit "0123456789abcdef0123456789abcdef01234567"

  test "describes this version and the commit it is told" do
    assert EhosDesign.release(@commit) == %{
             "schema" => "ehos.release/v1",
             "component" => "ehos_design",
             "version" => Mix.Project.config()[:version],
             "commit" => @commit,
             "produces" => [],
             "accepts" => [],
             "requires" => %{}
           }
  end

  describe "mix ehos_design.release_file" do
    @describetag :tmp_dir

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "writes the release's description as JSON", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")
      Mix.Task.rerun("ehos_design.release_file", ["--commit", @commit, "--output", output])

      assert JSON.decode!(File.read!(output)) == EhosDesign.release(@commit)
    end

    test "refuses a missing or short commit, and an argument it does not take", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")

      for args <- [
            ["--output", output],
            ["--commit", "0123456", "--output", output],
            ["--commit", @commit, "--output", output, "extra"]
          ] do
        assert_raise Mix.Error, fn -> Mix.Task.rerun("ehos_design.release_file", args) end
      end

      refute File.exists?(output)
    end
  end
end

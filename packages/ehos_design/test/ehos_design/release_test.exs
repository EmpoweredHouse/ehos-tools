defmodule EhosDesign.ReleaseTest do
  # What a release of ehos_design says about itself (eh-os D-91, docs/releases.md in eh-os). The
  # alias prints through Mix's own shell, which writes to this test's output, captured here.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  doctest EhosDesign

  @commit "0123456789abcdef0123456789abcdef01234567"
  @usage "Usage: mix ehos_design.release_file --commit <full sha> [--output <path>]"

  describe "release/1" do
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
  end

  describe "mix ehos_design.release_file" do
    @describetag :tmp_dir

    test "writes the release's description as JSON", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")

      assert capture_io(fn -> release_file(["--commit", @commit, "--output", output]) end) ==
               "wrote #{output}\n"

      assert JSON.decode!(File.read!(output)) == EhosDesign.release(@commit)
    end

    test "refuses a missing or short commit, and an argument it does not take", %{tmp_dir: dir} do
      output = Path.join(dir, "release.json")

      for args <- [
            ["--output", output],
            ["--commit", "0123456", "--output", output],
            ["--commit", @commit, "--output", output, "extra"]
          ] do
        assert_raise Mix.Error, @usage, fn -> release_file(args) end
      end

      refute File.exists?(output)
    end
  end

  defp release_file(args), do: Mix.Task.rerun("ehos_design.release_file", args)
end

defmodule Ehosctl.PlatformRunnerTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.PlatformRunner

  @moduletag :tmp_dir

  # A mise that answers `which` as the real one does, and says how it was asked.
  defp fake_mise(dir, answer) do
    mise = Path.join(dir, "mise")
    log = Path.join(dir, "asked")

    File.write!(mise, """
    #!/bin/sh
    echo "$PWD|$MISE_CEILING_PATHS|$MISE_PARANOID|$*" > #{log}
    #{answer}
    """)

    File.chmod!(mise, 0o755)
    {mise, log}
  end

  # T-13: the binary of the pin, asked for from a private directory mise may not look above, with
  # untrusted configuration refused.
  test "finds the binary of a pinned tool through mise, from a directory of its own", %{
    tmp_dir: dir
  } do
    tofu = Path.join(dir, "tofu-1.13.1")
    File.write!(tofu, "")
    {mise, log} = fake_mise(dir, "echo '#{tofu}'")

    assert PlatformRunner.resolve("tofu", mise: mise) == {:ok, tofu}

    [cwd, ceiling, paranoid, args] = log |> File.read!() |> String.trim() |> String.split("|")
    assert cwd == ceiling and cwd != File.cwd!()
    assert paranoid == "1"
    assert args == "which tofu --tool opentofu@1.13.1"
  end

  test "a pin mise has not installed is a program not found, not another version", %{tmp_dir: dir} do
    {mise, _log} = fake_mise(dir, "echo 'mise ERROR helm@4.3.0 is not installed' >&2; exit 1")
    assert PlatformRunner.resolve("helm", mise: mise) == {:error, :not_found}

    {mise, _log} = fake_mise(dir, "echo relative/kubectl")
    assert PlatformRunner.resolve("kubectl", mise: mise) == {:error, :not_found}

    assert PlatformRunner.resolve("tofu", mise: nil) == {:error, :not_found}
  end

  test "runs ssh, sh and gh as the system's, without asking mise" do
    for program <- ["ssh", "sh", "gh"] do
      assert PlatformRunner.resolve(program, mise: "/no/such/mise") == {:ok, program}
    end

    assert PlatformRunner.run_bounded("sh", ["-c", "echo here"], 5_000) == {"here\n", 0}
  end

  test "is the runner ehos_platform asks for" do
    behaviours = PlatformRunner.module_info(:attributes)[:behaviour]
    assert EhosPlatform.CommandRunner in behaviours
  end
end

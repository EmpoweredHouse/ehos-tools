defmodule EhosRelease.ChildEnvTest do
  # Not async: it sets a variable of this process's environment, which every test shares, to
  # show that changie, run in a caller's checkout, never gets it.
  use ExUnit.Case, async: false

  alias EhosRelease.ChangieImpl

  @fixture Path.expand("../fixtures/changie", __DIR__)

  @moduletag :tmp_dir

  setup do
    System.put_env("GH_TOKEN", "ehos-release-test-token")
    on_exit(fn -> System.delete_env("GH_TOKEN") end)
  end

  test "changie's templates cannot read the job's token", %{tmp_dir: dir} do
    File.cp_r!(@fixture, dir)
    File.mkdir_p!(Path.join(dir, "packages/shop"))
    config = File.read!(Path.join(dir, ".changie.yaml"))

    File.write!(
      Path.join(dir, ".changie.yaml"),
      String.replace(
        config,
        "versionFormat: '## [{{.VersionNoPrefix}}]",
        ~s(versionFormat: '## [{{.VersionNoPrefix}}] {{ env "GH_TOKEN" }})
      )
    )

    File.mkdir_p!(Path.join(dir, ".changes/unreleased"))

    File.write!(Path.join(dir, ".changes/unreleased/a.yaml"), """
    project: shop
    kind: Added
    body: A thing
    time: 2026-11-28T10:00:00.000000+01:00
    custom:
        Breaking: "No"
        Issue: EmpoweredHouse/eh-os#7
    """)

    assert ChangieImpl.batch(dir, "shop", "0.1.0") == :ok
    refute File.read!(Path.join(dir, ".changes/shop/0.1.0.md")) =~ "ehos-release-test-token"
  end
end

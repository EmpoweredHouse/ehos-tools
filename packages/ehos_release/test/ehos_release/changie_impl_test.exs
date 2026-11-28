defmodule EhosRelease.ChangieImplTest do
  # The implementation at the bottom, running the changie that `.tool-versions` pins on the
  # configuration T-34 gives, so a change of changie or of the configuration that moves the
  # floor or the changelog's shape fails here (T-34, Consequences).
  use ExUnit.Case, async: true

  alias EhosRelease.ChangieImpl

  @fixture Path.expand("../fixtures/changie", __DIR__)

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.cp_r!(@fixture, dir)
    File.mkdir_p!(Path.join(dir, "packages/shop"))
    File.mkdir_p!(Path.join(dir, "packages/shop_ui"))
    File.mkdir_p!(Path.join(dir, ".changes/shop"))

    File.write!(Path.join(dir, ".changes/shop/0.4.0.md"), """
    ## [0.4.0] - 2026-11-01

    ### Added

    - The first shop (EmpoweredHouse/eh-os#1)
    """)

    :ok
  end

  test "a fix alone raises the patch, an addition the minor, and a breaking fix the minor before 1.0",
       %{tmp_dir: dir} do
    fragment(dir, "shop", "Fixed", "No", "a.yaml")
    assert ChangieImpl.next(dir, "shop") == {:ok, "0.4.1"}

    fragment(dir, "shop", "Fixed", "Yes", "b.yaml")
    assert ChangieImpl.next(dir, "shop") == {:ok, "0.5.0"}

    File.rm!(Path.join(dir, ".changes/unreleased/b.yaml"))
    fragment(dir, "shop", "Added", "No", "c.yaml")
    assert ChangieImpl.next(dir, "shop") == {:ok, "0.5.0"}
  end

  test "a project with no fragment has no next version", %{tmp_dir: dir} do
    assert ChangieImpl.next(dir, "shop") == :none
  end

  test "writes the release's section in Keep a Changelog's shape, a breaking line marked",
       %{tmp_dir: dir} do
    fragment(dir, "shop", "Fixed", "Yes", "a.yaml")
    fragment(dir, "shop", "Added", "No", "b.yaml")

    assert ChangieImpl.batch(dir, "shop", "0.5.0") == :ok
    assert ChangieImpl.merge(dir) == :ok

    today = Date.utc_today() |> Date.to_iso8601()

    assert File.read!(Path.join(dir, "packages/shop/CHANGELOG.md")) == """
           # Changelog

           What changed, version by version.

           ## [0.5.0] - #{today}

           ### Added

           - Added a thing (EmpoweredHouse/eh-os#7)

           ### Fixed

           - **Breaking:** Fixed a thing (EmpoweredHouse/eh-os#7)

           ## [0.4.0] - 2026-11-01

           ### Added

           - The first shop (EmpoweredHouse/eh-os#1)
           """

    assert File.ls!(Path.join(dir, ".changes/unreleased")) == []
  end

  defp fragment(dir, project, kind, breaking, name) do
    File.mkdir_p!(Path.join(dir, ".changes/unreleased"))

    File.write!(Path.join(dir, ".changes/unreleased/#{name}"), """
    project: #{project}
    kind: #{kind}
    body: #{kind} a thing
    time: 2026-11-28T10:00:00.000000+01:00
    custom:
        Breaking: "#{breaking}"
        Issue: EmpoweredHouse/eh-os#7
    """)
  end
end

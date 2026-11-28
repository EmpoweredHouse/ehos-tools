defmodule EhosRelease.WorkflowsTest do
  use ExUnit.Case, async: true

  import EhosRelease.ReleaseRepo

  alias EhosRelease.{Source, Workflows}

  @moduletag :tmp_dir

  test "passes ehos-tools' release workflows that name the key, and refuses any other, in any case",
       %{tmp_dir: dir} do
    write(dir, ".github/workflows/release-pull-request.yml", "secrets: RELEASE_APP_PRIVATE_KEY\n")
    write(dir, ".github/workflows/ehos-release.yml", "environment: release-app\n")
    write(dir, ".github/workflows/ci.yml", "jobs: {}\n")
    write(dir, ".github/workflows/sneaky.yaml", "environment: Release-App\n")
    write(dir, ".github/workflows/copy.yml", "key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}\n")

    assert Workflows.key_refusals(Source.checkout(dir), "EmpoweredHouse/ehos-tools") == [
             ".github/workflows/copy.yml names the release App's key or the environment " <>
               "release-app, which only release-pull-request.yml may",
             ".github/workflows/sneaky.yaml names the release App's key or the environment " <>
               "release-app, which only release-pull-request.yml may"
           ]
  end

  test "refuses a copy of the reusable workflow that names the key in any other repository",
       %{tmp_dir: dir} do
    write(dir, ".github/workflows/release-pull-request.yml", "secrets: RELEASE_APP_PRIVATE_KEY\n")
    write(dir, ".github/workflows/ehos-release.yml", "environment: release-app\n")

    assert Workflows.key_refusals(Source.checkout(dir), "EmpoweredHouse/eh-os") == [
             ".github/workflows/ehos-release.yml names the release App's key or the environment " <>
               "release-app, which only release-pull-request.yml may"
           ]
  end
end

defmodule EhosRelease.OpenTest do
  use ExUnit.Case, async: true

  import Hammox
  import EhosRelease.ReleaseRepo

  alias EhosRelease.{ChangieMock, GitHubMock, GitMock, Open}

  setup :verify_on_exit!

  @moduletag :tmp_dir

  @repository "EmpoweredHouse/shop"
  @tools "EmpoweredHouse/ehos-tools"

  test "prepares the release at the floor of its fragments: the patch, the description, the branch",
       %{tmp_dir: dir} do
    write!(dir, "0.4.0")
    fragment!(dir, "a.yaml")
    fragment!(dir, "other.yaml", "Fixed", "shop_ui")

    mock_checks(dir, "0.5.0")
    mock_release(dir, "0.5.0")
    expect(GitHubMock, :issue_state, fn "EmpoweredHouse/eh-os", 7 -> {:ok, "open"} end)

    assert {:ok, release} = Open.open(dir, @repository, "shop", nil, mocks())

    assert Map.delete(release, :description) == %{
             component: "shop",
             version: "0.5.0",
             tag: "v0.5.0",
             branch: "release/shop-0.5.0",
             patch: "the patch"
           }

    assert release.description =~ "- EmpoweredHouse/eh-os#7: open, so its work is unfinished"
    assert release.description =~ "`packages/shop/CHANGELOG.md`:\n\n## [0.5.0] - 2026-11-28\n"
    assert release.description =~ "\n## Review\n"
    assert File.read!(Path.join(dir, "packages/shop/mix.exs")) =~ ~s(  @version "0.5.0"\n)
  end

  test "takes the maintainer's version above the floor, and shows an issue it cannot read as unknown",
       %{tmp_dir: dir} do
    write!(dir, "0.4.0")
    fragment!(dir, "a.yaml")
    mock_checks(dir, "0.5.0")
    mock_release(dir, "1.0.0")
    expect(GitHubMock, :issue_state, fn _repository, 7 -> {:error, "answered 404"} end)

    assert {:ok, %{version: "1.0.0", description: description}} =
             Open.open(dir, @repository, "shop", "1.0.0", mocks())

    assert description =~ "- EmpoweredHouse/eh-os#7: unknown, as the workflow could not read it"
  end

  test "refuses a version below the floor, and changes nothing", %{tmp_dir: dir} do
    write!(dir, "0.4.0")
    fragment!(dir, "a.yaml")
    mock_checks(dir, "0.5.0")

    assert Open.open(dir, @repository, "shop", "0.4.1", mocks()) ==
             {:error, ["the version 0.4.1 is below 0.5.0, the floor its fragments give"]}

    assert File.read!(Path.join(dir, "packages/shop/mix.exs")) =~ ~s(  @version "0.4.0"\n)
  end

  test "names every refusal at once: no fragment, an untagged pin, a workflow with the key",
       %{tmp_dir: dir} do
    write!(dir, "0.4.0")
    write(dir, ".github/workflows/leak.yml", "jobs:\n  x:\n    environment: release-app\n")

    expect(ChangieMock, :next, fn ^dir, "shop" -> :none end)
    mock_tags(%{})
    expect(GitHubMock, :rulesets, fn @tools -> {:ok, [protecting(["ehos_platform-v"])]} end)

    assert Open.open(dir, @repository, "shop", nil, mocks()) ==
             {:error,
              [
                "shop has no changelog fragment, so there is nothing to release",
                "packages/shop/priv/pins.json: ehos_platform pins #{@tools} " <>
                  "packages/ehos_platform at #{tagged()}, which no protected tag " <>
                  "ehos_platform-vX.Y.Z names",
                ".github/workflows/leak.yml names the release App's key or the environment " <>
                  "release-app, which only release-pull-request.yml may"
              ]}
  end

  test "names the version file it could not write", %{tmp_dir: dir} do
    write!(dir, "0.4.0")
    fragment!(dir, "a.yaml")
    mix_exs = Path.join(dir, "packages/shop/mix.exs")
    File.chmod!(mix_exs, 0o444)
    on_exit(fn -> File.chmod(mix_exs, 0o644) end)
    mock_checks(dir, "0.5.0")

    expect(ChangieMock, :batch, fn ^dir, "shop", "0.5.0" -> :ok end)
    expect(ChangieMock, :merge, fn ^dir -> :ok end)

    assert Open.open(dir, @repository, "shop", nil, mocks()) ==
             {:error, ["packages/shop/mix.exs: it could not be written"]}
  end

  test "refuses to write through a symbolic link the checkout holds", %{tmp_dir: dir} do
    write!(dir, "0.4.0")
    fragment!(dir, "a.yaml")
    outside = Path.join(dir, "../outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.rename!(Path.join(dir, "packages/shop"), Path.join(outside, "shop"))
    File.ln_s!(Path.join(outside, "shop"), Path.join(dir, "packages/shop"))
    mock_checks(dir, "0.5.0")

    assert Open.open(dir, @repository, "shop", nil, mocks()) ==
             {:error,
              ["packages/shop is a symbolic link, which a release does not write through"]}
  end

  test "refuses fragments anywhere but .changes/, the one directory the release may change",
       %{tmp_dir: dir} do
    write!(dir, "0.4.0")

    write(dir, ".changie.yaml", """
    changesDir: lib
    unreleasedDir: unreleased
    projects:
      - key: shop
        changelog: packages/shop/CHANGELOG.md
    """)

    assert Open.open(dir, @repository, "shop", nil, mocks()) ==
             {:error,
              [
                ~s(.changie.yaml's changesDir is "lib", not .changes, the one directory of ) <>
                  "fragments a release may change"
              ]}
  end

  test "refuses a component whose changelogs are not its changie projects'", %{tmp_dir: dir} do
    write!(dir, "0.4.0")

    write(dir, ".changie.yaml", """
    changesDir: .changes
    unreleasedDir: unreleased
    projects:
      - key: shop
        changelog: elsewhere/CHANGELOG.md
    """)

    assert Open.open(dir, @repository, "shop", nil, mocks()) ==
             {:error,
              ["shop's changelogs are not those of its changie projects: elsewhere/CHANGELOG.md"]}
  end

  defp mock_checks(dir, floor) do
    expect(ChangieMock, :next, fn ^dir, "shop" -> {:ok, floor} end)
    mock_tags(%{"ehos_platform-v0.21.0" => tagged()})
    expect(GitHubMock, :rulesets, fn @tools -> {:ok, [protecting(["ehos_platform-v"])]} end)
  end

  # The tags of the pinned producer, and of the component's own repository.
  defp mock_tags(producer) do
    expect(GitMock, :tags, 2, fn
      @tools -> {:ok, producer}
      @repository -> {:ok, %{"v0.4.0" => tagged()}}
    end)
  end

  defp mock_release(dir, version) do
    expect(ChangieMock, :batch, fn ^dir, "shop", ^version ->
      File.rm!(Path.join(dir, ".changes/unreleased/a.yaml"))
      write(dir, ".changes/shop/#{version}.md", "## [#{version}] - 2026-11-28\n")
      :ok
    end)

    expect(ChangieMock, :merge, fn ^dir -> :ok end)
    expect(GitMock, :patch, fn ^dir -> {:ok, "the patch"} end)
  end

  defp mocks, do: [git: GitMock, github: GitHubMock, changie: ChangieMock]
end

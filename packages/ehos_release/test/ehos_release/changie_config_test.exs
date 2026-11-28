defmodule EhosRelease.ChangieConfigTest do
  use ExUnit.Case, async: true

  alias EhosRelease.ChangieConfig

  @base """
  changesDir: .changes
  unreleasedDir: unreleased
  projects:
    - key: shop
      changelog: packages/shop/CHANGELOG.md
  """

  test "reads the configuration T-34 gives" do
    yaml = File.read!(Path.expand("../fixtures/changie/.changie.yaml", __DIR__))
    assert {:ok, %ChangieConfig{changes_dir: ".changes"}} = ChangieConfig.parse(yaml)
  end

  test "refuses replacements in a project, which rewrite any file of the checkout" do
    yaml =
      @base <>
        "    replacements:\n      - path: .git/config\n        find: x\n        replace: y\n"

    assert ChangieConfig.parse(yaml) ==
             {:error,
              ".changie.yaml's projects has replacements, which a release does not accept"}
  end

  test "refuses a key a release does not read, such as a version header" do
    assert ChangieConfig.parse(@base <> "versionHeaderPath: ../../secret\n") ==
             {:error, ".changie.yaml has versionHeaderPath, which a release does not accept"}
  end

  test "refuses a header, a directory of fragments or a changelog outside where it belongs" do
    assert ChangieConfig.parse(@base <> "headerPath: ../.git/config\n") ==
             {:error,
              ~s(.changie.yaml names "../.git/config", which leaves the directory it belongs in)}

    assert ChangieConfig.parse(String.replace(@base, "unreleased\n", "../../x\n")) ==
             {:error, ~s(.changie.yaml names "../../x", which leaves the directory it belongs in)}

    assert ChangieConfig.parse(String.replace(@base, "packages/shop/", "../")) ==
             {:error, ".changie.yaml's projects need a changelog inside the repository each"}
  end
end

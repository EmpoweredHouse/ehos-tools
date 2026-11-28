defmodule EhosRelease.ReleaseRepo do
  @moduledoc false

  # A caller's checkout of one component, `shop`, for the tests of the stages: its
  # configuration, changie's, a version file, a pin into ehos-tools and its workflows.

  @fixture Path.expand("../fixtures/changie", __DIR__)

  @config %{
    "components" => %{
      "shop" => %{
        "tag_prefix" => "v",
        "changie_projects" => ["shop"],
        "changelogs" => ["packages/shop/CHANGELOG.md"],
        "version_files" => [
          %{"path" => "packages/shop/mix.exs", "line" => ~s(  @version "{version}")}
        ],
        "pins" => [
          %{"kind" => "json", "path" => "packages/shop/priv/pins.json"},
          %{"kind" => "workflows", "path" => ".github/workflows"}
        ]
      }
    }
  }

  def tagged, do: String.duplicate("a", 40)

  def write!(dir, version) do
    File.cp_r!(@fixture, dir)
    write(dir, ".github/ehos-release.json", JSON.encode!(@config))

    write(
      dir,
      "packages/shop/mix.exs",
      "defmodule Shop.MixProject do\n  @version \"#{version}\"\nend\n"
    )

    write(dir, "packages/shop/CHANGELOG.md", "# Changelog\n")

    write(
      dir,
      "packages/shop/priv/pins.json",
      ~s({"ehos_platform": {"repository": "EmpoweredHouse/ehos-tools", "path": "packages/ehos_platform", "ref": "#{tagged()}"}})
    )

    write(dir, ".github/workflows/ci.yml", "jobs:\n  test:\n    runs-on: ubuntu-24.04\n")
    dir
  end

  def fragment!(dir, name, kind \\ "Added", project \\ "shop") do
    write(dir, ".changes/unreleased/#{name}", """
    project: #{project}
    kind: #{kind}
    body: A thing
    time: 2026-11-28T10:00:00.000000+01:00
    custom:
        Breaking: "No"
        Issue: EmpoweredHouse/eh-os#7
    """)
  end

  def write(dir, path, contents) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  def protecting(prefixes) do
    %{
      "target" => "tag",
      "enforcement" => "active",
      "bypass_actors" => [],
      "rules" => [%{"type" => "update"}, %{"type" => "deletion"}],
      "conditions" => %{
        "ref_name" => %{"include" => Enum.map(prefixes, &"refs/tags/#{&1}*"), "exclude" => []}
      }
    }
  end
end

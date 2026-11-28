defmodule EhosRelease.ConfigTest do
  use ExUnit.Case, async: true

  alias EhosRelease.Config
  alias EhosRelease.Config.Component

  @component %{
    "tag_prefix" => "ehos_release-v",
    "changie_projects" => ["ehos_release"],
    "changelogs" => ["packages/ehos_release/CHANGELOG.md"],
    "version_files" => [
      %{"path" => "packages/ehos_release/mix.exs", "line" => ~s(  @version "{version}")}
    ],
    "pins" => [
      %{"kind" => "mix_lock", "path" => "packages/ehos_release/mix.lock"},
      %{"kind" => "workflows", "path" => ".github/workflows"}
    ]
  }

  test "reads each component with its prefix, projects, changelogs, version files and pins" do
    assert Config.parse(json(%{"ehos_release" => @component})) ==
             {:ok,
              %Config{
                components: %{
                  "ehos_release" => %Component{
                    name: "ehos_release",
                    tag_prefix: "ehos_release-v",
                    changie_projects: ["ehos_release"],
                    changelogs: ["packages/ehos_release/CHANGELOG.md"],
                    version_files: [
                      %{path: "packages/ehos_release/mix.exs", line: ~s(  @version "{version}")}
                    ],
                    pins: [
                      %{kind: "mix_lock", path: "packages/ehos_release/mix.lock"},
                      %{kind: "workflows", path: ".github/workflows"}
                    ]
                  }
                }
              }}
  end

  test "lists every place the components pin, each once" do
    other = Map.put(@component, "pins", [%{"kind" => "workflows", "path" => ".github/workflows"}])
    {:ok, config} = Config.parse(json(%{"ehos_release" => @component, "other" => other}))

    assert Config.pin_sources(config) == [
             %{kind: "mix_lock", path: "packages/ehos_release/mix.lock"},
             %{kind: "workflows", path: ".github/workflows"}
           ]
  end

  test "names the components there are when asked for another" do
    {:ok, config} = Config.parse(json(%{"ehos_release" => @component}))

    assert Config.component(config, "ehosctl") ==
             {:error, ~s("ehosctl" is not a component of .github/ehos-release.json: ehos_release)}
  end

  test "refuses a file that leaves the repository, a line without one {version}, or an unknown kind" do
    assert refusal(%{"changelogs" => ["../CHANGELOG.md"]}) ==
             ".github/ehos-release.json: c's changelogs leaves the repository"

    assert refusal(%{"version_files" => [%{"path" => "/etc/passwd", "line" => "{version}"}]}) ==
             ".github/ehos-release.json: c's /etc/passwd leaves the repository"

    assert refusal(%{"version_files" => [%{"path" => "mix.exs", "line" => "@version"}]}) ==
             ".github/ehos-release.json: c's line for mix.exs does not hold {version} exactly once"

    assert refusal(%{"pins" => [%{"kind" => "shell", "path" => "x"}]}) ==
             ".github/ehos-release.json: c's pins need a kind " <>
               "(mix_lock, workflows, claude_settings, json) and a path each"

    assert refusal(%{"tag_prefix" => "v;rm"}) ==
             ".github/ehos-release.json: c's tag_prefix is not a tag prefix"
  end

  test "refuses what is not JSON, has no components, or a component name that is not one" do
    assert Config.parse("{") == {:error, ".github/ehos-release.json is not valid JSON"}
    assert Config.parse("[]") == {:error, ".github/ehos-release.json has no object `components`"}

    assert Config.parse(json(%{"Bad Name" => @component})) ==
             {:error, ~s("Bad Name" is not a component name)}
  end

  defp refusal(fields) do
    {:error, reason} = Config.parse(json(%{"c" => Map.merge(@component, fields)}))
    reason
  end

  defp json(components), do: JSON.encode!(%{"components" => components})
end

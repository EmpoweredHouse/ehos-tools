defmodule ReadmeTest do
  # ehos-tools#810: the README tells a project which release to depend on. A release's pull request
  # adds that version's section to CHANGELOG.md, so the newest section is the release the README
  # names, by its version and by its tag. A copy of ehos_design's
  # (packages/ehos_design/test/readme_test.exs), since sharing one would make a package depend on
  # another for its tests alone.
  use ExUnit.Case, async: true

  @package Path.expand("..", __DIR__)

  # Before the first release, the README names the version it will be, the package's without
  # `-dev`, so that the first release's pull request changes no line of it.
  test "the README's dependency names the newest release in CHANGELOG.md, by version and by tag" do
    released = newest_release() || first_release()

    readme = File.read!(Path.join(@package, "README.md"))

    assert Regex.scan(~r/\{:ehos_tunnel, "~> ([^"]+)"/, readme, capture: :all_but_first) ==
             [[released]]

    assert Regex.scan(~r/ehos_tunnel-v(\S+) names/, readme, capture: :all_but_first) == [
             [released]
           ]
  end

  defp newest_release do
    case Regex.run(~r/^## \[(\d+\.\d+\.\d+)\]/m, File.read!(Path.join(@package, "CHANGELOG.md")),
           capture: :all_but_first
         ) do
      [version] -> version
      nil -> nil
    end
  end

  defp first_release, do: String.trim_trailing(Mix.Project.config()[:version], "-dev")
end

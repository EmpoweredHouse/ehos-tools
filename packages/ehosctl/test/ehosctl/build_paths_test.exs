defmodule Ehosctl.BuildPathsTest do
  use ExUnit.Case, async: true

  # Two workflows list what goes into the binary: ci.yml's `build` filter, which decides whether a
  # pull request builds it, and changelog.yml's `ehosctl_code`, which decides whether it asks for a
  # line in ehosctl's changelog. A path added to one alone leaves a change to the binary unbuilt or
  # unrecorded, with nothing failing (ehos-tools#545). They differ by ci.yml itself, which builds
  # the binary but is not in it. YAML is read with YamlElixir, which ehos_platform brings in every
  # environment, so Mix will not take it as a test-only dependency here.
  @root Path.expand("../../../..", __DIR__)

  test "ci.yml's build filter and changelog.yml's ehosctl_code list the same paths" do
    build = filter(".github/workflows/ci.yml", "build", "build")
    ehosctl_code = filter(".github/workflows/changelog.yml", "filter", "ehosctl_code")

    assert build -- [".github/workflows/ci.yml"] == ehosctl_code
  end

  # The list `name` in the `dorny/paths-filter` step `id` of `workflow`, whose `filters` is YAML
  # inside a YAML string.
  defp filter(workflow, id, name) do
    jobs = @root |> Path.join(workflow) |> YamlElixir.read_from_file!() |> Map.fetch!("jobs")

    [filters] =
      for {_job, %{"steps" => steps}} <- jobs,
          %{"id" => ^id, "with" => %{"filters" => filters}} <- steps,
          do: filters

    filters |> YamlElixir.read_from_string!() |> Map.fetch!(name)
  end
end

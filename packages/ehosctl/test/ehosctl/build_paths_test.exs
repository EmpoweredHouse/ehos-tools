defmodule Ehosctl.BuildPathsTest do
  use Ehosctl.Case, async: true

  # Two workflows list what goes into the binary: ci.yml's `build` filter, which decides whether a
  # pull request builds it, and changelog.yml's `ehosctl_code`, which decides whether it asks for a
  # line in ehosctl's changelog. A path added to one alone leaves a change to the binary unbuilt or
  # unrecorded, with nothing failing (ehos-tools#545). They differ by ci.yml itself, which builds
  # the binary but is not in it. YAML is read with YamlElixir, which ehos_platform brings in every
  # environment, so Mix will not take it as a test-only dependency here.
  @root Path.expand("../../../..", __DIR__)
  @ci ".github/workflows/ci.yml"

  test "ci.yml's build filter and changelog.yml's ehosctl_code list the same paths" do
    build = filter(@ci, "build", "build")
    ehosctl_code = filter(".github/workflows/changelog.yml", "filter", "ehosctl_code")

    assert @ci in build
    assert MapSet.new(build -- [@ci]) == MapSet.new(ehosctl_code)
  end

  # What goes into the binary is ehosctl's to check too, or a pull request could build a binary
  # whose tests never ran.
  test "ci.yml's ehosctl filter covers every path its build filter lists" do
    ehosctl = filter(@ci, "filter", "ehosctl")

    uncovered = Enum.reject(filter(@ci, "build", "build"), &covered?(&1, ehosctl))

    assert uncovered == []
  end

  # The list `name` in the `dorny/paths-filter` step `id` of `workflow`, whose `filters` is YAML
  # inside a YAML string. A list nested by an alias is flattened, as the action does.
  defp filter(workflow, id, name) do
    jobs = @root |> Path.join(workflow) |> YamlElixir.read_from_file!() |> Map.fetch!("jobs")

    filters =
      for {_job, %{"steps" => steps}} <- jobs,
          %{"id" => ^id, "with" => %{"filters" => filters}} <- steps,
          do: filters

    case filters do
      [filters] -> filters |> YamlElixir.read_from_string!() |> Map.fetch!(name) |> List.flatten()
      found -> flunk("#{workflow} has #{length(found)} paths-filter steps with id #{id}, not one")
    end
  end

  defp covered?(path, globs) do
    path in globs or
      Enum.any?(
        globs,
        &(String.ends_with?(&1, "/**") and
            String.starts_with?(path, String.trim_trailing(&1, "**")))
      )
  end
end

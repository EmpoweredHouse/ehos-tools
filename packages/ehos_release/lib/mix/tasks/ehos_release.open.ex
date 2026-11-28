defmodule Mix.Tasks.EhosRelease.Open do
  @shortdoc "Prepares a component's release: its patch and its pull request's description"

  @moduledoc """
  `mix ehos_release.open --repo DIR --repository OWNER/NAME --output OUT COMPONENT [VERSION]`:
  the stage `open` of the release workflow (`EhosRelease.Open`), in the job that holds no key.

  For `COMPONENT` of the checkout in `DIR`, which is `OWNER/NAME` on GitHub, it checks the
  fragments, the pins and the workflows, computes the version (`VERSION` raises the floor), makes
  the release's change in the checkout, and writes three files into `OUT`:

  - `release.patch`, the change, which the job that opens the pull request checks and applies;
  - `description.md`, the pull request's description;
  - `release.json`, the component, version, tag and branch.

  Reads `GH_TOKEN` for GitHub, where it is set. Prints each refusal and exits with 1 when there is
  one, writing nothing.
  """

  use Mix.Task

  @switches [repo: :string, repository: :string, output: :string]

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    {component, version} = arguments(rest)
    [repo, repository, output] = Enum.map([:repo, :repository, :output], &required(opts, &1))

    Mix.Task.run("app.start")

    case EhosRelease.open(repo, repository, component, version) do
      {:ok, release} -> write(output, release)
      {:error, refusals} -> EhosRelease.Task.refuse(refusals)
    end
  end

  defp arguments([component]), do: {component, nil}
  defp arguments([component, version]), do: {component, version}
  defp arguments(_other), do: usage()

  defp required(opts, key), do: Keyword.get(opts, key) || usage()

  @spec usage() :: no_return()
  defp usage do
    Mix.raise(
      "Usage: mix ehos_release.open --repo DIR --repository OWNER/NAME --output OUT " <>
        "COMPONENT [VERSION]"
    )
  end

  defp write(output, release) do
    File.mkdir_p!(output)
    File.write!(Path.join(output, "release.patch"), release.patch)
    File.write!(Path.join(output, "description.md"), release.description)

    File.write!(
      Path.join(output, "release.json"),
      [JSON.encode!(Map.take(release, [:component, :version, :tag, :branch])), ?\n]
    )

    Mix.shell().info("#{release.component} #{release.version}: wrote #{output}")
  end
end

defmodule Mix.Tasks.EhosRelease.Merged do
  @shortdoc "Checks the release merged at a commit before it is tagged"

  @moduledoc """
  `mix ehos_release.merged --repo DIR --repository OWNER/NAME --output OUT COMMIT`: the stage
  `merged` of the release workflow (`EhosRelease.Merged`), in a job that holds no key.

  For the release pull request merged at `COMMIT` of `OWNER/NAME`, whose checkout at that commit is
  in `DIR`, it checks who merged it, what it changed, the version files, the fragments left, the
  pins and the workflows. When they pass, it writes `release.json` into `OUT`, with the component,
  version, tag and pull request. When one fails, it writes `refused.md` there instead, one reason
  on each line, prints them, and exits with 1.

  Reads `GH_TOKEN` for GitHub, where it is set.
  """

  use Mix.Task

  @switches [repo: :string, repository: :string, output: :string]

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    commit = argument(rest)
    [repo, repository, output] = Enum.map([:repo, :repository, :output], &required(opts, &1))

    Mix.Task.run("app.start")
    File.mkdir_p!(output)

    case EhosRelease.merged(repo, repository, commit) do
      {:ok, release} ->
        File.write!(Path.join(output, "release.json"), [JSON.encode!(release), ?\n])
        Mix.shell().info("#{release.component} #{release.version}: #{release.tag} may be tagged")

      {:error, refusals} ->
        File.write!(Path.join(output, "refused.md"), Enum.map(refusals, &[&1, ?\n]))
        EhosRelease.Task.refuse(refusals)
    end
  end

  defp argument([commit]), do: commit
  defp argument(_other), do: usage()

  defp required(opts, key), do: Keyword.get(opts, key) || usage()

  @spec usage() :: no_return()
  defp usage do
    Mix.raise(
      "Usage: mix ehos_release.merged --repo DIR --repository OWNER/NAME --output OUT COMMIT"
    )
  end
end

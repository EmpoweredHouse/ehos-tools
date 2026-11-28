defmodule Mix.Tasks.EhosRelease.Pins do
  @shortdoc "Checks that each pin a pull request adds or moves is on its producer's main"

  @moduledoc """
  `mix ehos_release.pins [--repo DIR] BASE`: for every pin the checkout in `DIR` (the current
  directory by default) adds or moves against the commit `BASE`, checks that it names a commit
  its producer's `main` contains (eh-os D-205, "Between releases"; `EhosRelease.pins/3`).

  Reads `GH_TOKEN` for GitHub, where it is set. Prints each refusal and exits with 1 when there is
  one. `.github/workflows/ehos-pins.yml` runs it on every pull request.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [repo: :string])

    base =
      case rest do
        [base] -> base
        _other -> Mix.raise("Usage: mix ehos_release.pins [--repo DIR] BASE")
      end

    Mix.Task.run("app.start")

    case EhosRelease.pins(Keyword.get(opts, :repo, "."), base) do
      {:ok, pins} ->
        Mix.shell().info("#{length(pins)} pins added or moved, each on its producer's main")

      {:error, refusals} ->
        Enum.each(refusals, fn refusal -> Mix.shell().error(refusal) end)
        Mix.raise("#{length(refusals)} refused", exit_status: 1)
    end
  end
end

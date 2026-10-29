defmodule Mix.Tasks.Review.Changelog do
  @shortdoc "Checks that a change leaves released changelog sections as they were"

  @moduledoc """
  Fails when a change edits a released version's section of a package's `CHANGELOG.md`, unless
  it is that package's release (`Review.Changelog`, ehos-tools#585).

      $ mix review.changelog HEAD^1 HEAD   # a pull request's merge commit, against its base
      $ mix review.changelog <before> HEAD # a push to main, against the commit before it

  The `changelog` workflow runs it on every pull request and on every push to `main`.
  """

  use Mix.Task

  @impl Mix.Task
  def run([from, to]) do
    case Review.Changelog.check(".", from, to) do
      :ok -> Mix.shell().info("No released version's section of a CHANGELOG.md changes")
      {:error, messages} -> Mix.raise(Enum.join(messages, "\n"))
    end
  end

  def run(_args), do: Mix.raise("Usage: mix review.changelog <from> <to>")
end

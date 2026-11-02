defmodule Mix.Tasks.Review.Plugins do
  @shortdoc "Checks that a change to a plugin raises its version once that version is tagged"

  @moduledoc """
  Fails when a change to a Claude Code plugin in `plugins/` keeps a version that already has its
  tag, `<plugin>-v<version>` (`Review.Plugins`).

      $ mix review.plugins HEAD^1 HEAD   # a pull request's merge commit, against its base
      $ mix review.plugins <before> HEAD # a push to main, each commit it adds

  The `changelog` workflow runs it on every pull request and on every push to `main`, in a
  checkout that holds the tags.
  """

  use Mix.Task

  @impl Mix.Task
  def run([from, to]) do
    case Review.Plugins.check(".", from, to) do
      :ok -> Mix.shell().info("No plugin changes under a version already tagged")
      {:error, messages} -> Mix.raise(Enum.join(messages, "\n"))
    end
  end

  def run(_args), do: Mix.raise("Usage: mix review.plugins <from> <to>")
end

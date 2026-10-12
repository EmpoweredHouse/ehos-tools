defmodule Mix.Tasks.EhosApp.UnlinkSkills do
  @shortdoc "Removes the links to skills ehos_app no longer copies, and the directories they leave"

  @moduledoc """
  #{@shortdoc}.

  `ehos_app` 0.3.0 to 0.8.1 copied its skills into `.agents/skills/<name>/` and linked each from
  `.claude/skills/<name>`, as `../../.agents/skills/<name>`. The skills are the `ehos-app` plugin's
  now, and `mix ehos_app.install` removes the copies still as a release wrote them. It cannot
  remove a link, so it runs this task, which removes every directory under `.agents/` left
  empty, then each link of that form whose skill is gone, and `.claude/skills/` when nothing is
  left in it. A link to a skill that is still there, an entry of the developer's own and a file of
  theirs are left alone, so a second run changes nothing.

      mix ehos_app.unlink_skills
  """

  use Mix.Task

  @skills ".agents/skills"
  @links ".claude/skills"

  @impl Mix.Task
  def run(_argv) do
    # The installer removes a skill's files and leaves its directories, which keep the link
    # resolving: they go first.
    remove_empty(".agents")

    for name <- dangling() do
      link = Path.join(@links, name)
      :ok = File.rm(link)
      Mix.shell().info([:yellow, "* unlinking ", :reset, link])
    end

    remove_empty(@links)
    :ok
  end

  @doc "The entries of `.claude/skills` that link into `.agents/skills` to a skill that is gone."
  @spec dangling() :: [String.t()]
  def dangling do
    case File.ls(@links) do
      {:ok, names} ->
        names
        |> Enum.filter(fn name ->
          link = Path.join(@links, name)

          File.read_link(link) == {:ok, Path.join(["..", "..", @skills, name])} and
            not File.exists?(link)
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # Bottom up, so a directory emptied by removing its own empty directories goes too.
  defp remove_empty(dir) do
    case File.lstat(dir) do
      {:ok, %{type: :directory}} ->
        dir |> File.ls!() |> Enum.each(&remove_empty(Path.join(dir, &1)))
        if File.ls!(dir) == [], do: File.rmdir!(dir)

      _ ->
        :ok
    end
  end
end

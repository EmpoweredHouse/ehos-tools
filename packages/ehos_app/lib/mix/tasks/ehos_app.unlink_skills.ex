defmodule Mix.Tasks.EhosApp.UnlinkSkills do
  @shortdoc "Removes the links to skills ehos_app no longer copies, and the directories they leave"

  @moduledoc """
  #{@shortdoc}.

  `ehos_app` 0.3.0 to 0.8.1 copied its skills into `.agents/skills/<name>/` and linked each from
  `.claude/skills/<name>`, as `../../.agents/skills/<name>`. The skills are the `ehos-app` plugin's
  now, and `mix ehos_app.install` removes the copies still as a release wrote them. It cannot
  remove a link, so it runs this task, which removes the directories of those skills left empty,
  then each link of that form whose skill is gone, and `.agents/skills/`, `.agents/` and
  `.claude/skills/` when nothing is left in them. A link to a skill that is still there, an entry
  of the developer's own, a directory of theirs and a file of theirs are left alone, so a second
  run changes nothing.

      mix ehos_app.unlink_skills
  """

  use Mix.Task

  @skills ".agents/skills"
  @links ".claude/skills"

  # The skills 0.3.0 to 0.8.1 copied.
  @released ["elixir-anti-patterns-review", "plan", "review", "ship"]

  @impl Mix.Task
  def run(_argv) do
    # The installer removes a skill's files and leaves its directories, which keep the link
    # resolving: they go first.
    for name <- @released, do: remove_empty(Path.join(@skills, name))

    for name <- dangling() do
      link = Path.join(@links, name)
      :ok = File.rm(link)
      Mix.shell().info([:yellow, "* unlinking ", :reset, link])
    end

    remove_if_empty(@skills)
    remove_if_empty(".agents")
    remove_if_empty(@links)
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

  # Bottom up, so a directory emptied by removing its own empty directories goes too. A link is
  # never followed, and a directory that cannot be read or removed is left as it is.
  defp remove_empty(dir) do
    with {:ok, %{type: :directory}} <- File.lstat(dir),
         {:ok, entries} <- File.ls(dir) do
      Enum.each(entries, &remove_empty(Path.join(dir, &1)))
      remove_if_empty(dir)
    end
  end

  defp remove_if_empty(dir) do
    with {:ok, %{type: :directory}} <- File.lstat(dir),
         {:ok, []} <- File.ls(dir),
         do: File.rmdir(dir)
  end
end

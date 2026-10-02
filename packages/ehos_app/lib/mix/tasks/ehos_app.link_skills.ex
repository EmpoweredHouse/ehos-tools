defmodule Mix.Tasks.EhosApp.LinkSkills do
  @shortdoc "Links every skill in .agents/skills from .claude/skills"

  @moduledoc """
  #{@shortdoc}.

  The skills are canonical in `.agents/skills/<name>/`, which other agents read, and Claude Code
  reads only `.claude/skills/`. Each skill without an entry there gets a relative symlink,
  `.claude/skills/<name> -> ../../.agents/skills/<name>`. An entry that exists, a link or a
  directory of the developer's, is left alone, so a second run changes nothing.

  `mix ehos_app.install` runs it when a skill has no link, since Igniter writes files and cannot
  make a symlink.

      mix ehos_app.link_skills
  """

  use Mix.Task

  @skills ".agents/skills"
  @links ".claude/skills"

  @impl Mix.Task
  def run(_argv) do
    for name <- missing() do
      File.mkdir_p!(@links)
      link = Path.join(@links, name)
      :ok = File.ln_s(Path.join(["..", "..", @skills, name]), link)
      Mix.shell().info([:green, "* linking ", :reset, link])
    end

    :ok
  end

  @doc "The skills in `.agents/skills` that have no entry in `.claude/skills`."
  @spec missing() :: [String.t()]
  def missing do
    case File.ls(@skills) do
      {:ok, names} ->
        names
        |> Enum.filter(&File.dir?(Path.join(@skills, &1)))
        |> Enum.reject(&match?({:ok, _}, File.lstat(Path.join(@links, &1))))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end
end

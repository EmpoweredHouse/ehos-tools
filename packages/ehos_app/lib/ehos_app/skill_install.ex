if Code.ensure_loaded?(Igniter) do
  defmodule EhosApp.SkillInstall do
    @moduledoc """
    Installs bundled skills through Igniter, preserving a team's edits and removals.

    The manifest records the last complete copy of each skill. An upgrade replaces a skill
    only when all its files still match that copy; a changed reference preserves the whole skill.
    """

    @manifest ".agents/ehos-skills.json"
    @root ".agents/skills"

    @doc "Installs skills and their provenance, or leaves an unreadable manifest untouched with a warning."
    @spec install(Igniter.t(), map()) :: Igniter.t()
    def install(igniter, skills \\ EhosApp.Skills.bundled()) do
      {igniter, manifest} = read(igniter, @manifest)
      install_manifest(igniter, decode(manifest), skills)
    end

    defp install_manifest(igniter, {:ok, previous}, skills) do
      {igniter, entries} =
        Enum.reduce(Enum.sort(skills), {igniter, previous}, fn {name, skill},
                                                               {igniter, entries} ->
          {igniter, entry} = install_skill(igniter, name, skill, previous[name])
          {igniter, Map.put(entries, name, entry)}
        end)

      write(igniter, @manifest, JSON.encode!(%{"version" => 1, "skills" => entries}) <> "\n")
    end

    defp install_manifest(igniter, :error, _skills) do
      Igniter.add_warning(
        igniter,
        "Cannot read .agents/ehos-skills.json. Skills were left unchanged; restore the manifest before upgrading them."
      )
    end

    defp install_skill(igniter, name, skill, previous) do
      {igniter, current} = read_files(igniter, name, skill, previous)

      if replaceable?(current, previous) do
        replace(igniter, name, skill, previous)
      else
        igniter =
          Igniter.add_notice(
            igniter,
            "Kept .agents/skills/#{name}: it contains files the project changed, removed or linked. " <>
              "Compare them with the bundled release before updating this skill by hand."
          )

        {igniter, previous || %{"managed" => false}}
      end
    end

    defp read_files(igniter, name, skill, previous) do
      paths = Map.keys(skill["files"]) ++ Map.keys((previous || %{})["files"] || %{})

      Enum.reduce(Enum.uniq(paths), {igniter, %{}}, fn path, {igniter, files} ->
        {igniter, content} = read(igniter, Path.join([@root, name, path]))
        {igniter, Map.put(files, path, content)}
      end)
    end

    defp replaceable?(current, nil), do: Enum.all?(current, fn {_path, text} -> is_nil(text) end)
    defp replaceable?(_current, %{"managed" => false}), do: false

    defp replaceable?(current, %{"files" => previous}) do
      Enum.all?(current, fn {path, text} ->
        if Map.has_key?(previous, path),
          do: is_binary(text) and hash(text) == previous[path],
          else: is_nil(text)
      end)
    end

    defp replace(igniter, name, skill, previous) do
      skill =
        Map.update!(
          skill,
          "files",
          &Map.new(&1, fn {path, text} ->
            {path, String.trim_trailing(text) <> "\n"}
          end)
        )

      igniter =
        Enum.reduce(skill["files"], igniter, fn {path, text}, igniter ->
          write(igniter, Path.join([@root, name, path]), text)
        end)

      removed = Map.keys((previous || %{})["files"] || %{}) -- Map.keys(skill["files"])
      igniter = Enum.reduce(removed, igniter, &Igniter.rm(&2, Path.join([@root, name, &1])))
      entry = Map.update!(skill, "files", &Map.new(&1, fn {path, text} -> {path, hash(text)} end))
      {igniter, entry}
    end

    defp decode(nil), do: {:ok, %{}}
    defp decode(:linked), do: :error

    defp decode(text) do
      case JSON.decode(text) do
        {:ok, %{"version" => 1, "skills" => entries}} when is_map(entries) ->
          if Enum.all?(entries, &valid_entry?/1), do: {:ok, entries}, else: :error

        _other ->
          :error
      end
    end

    defp valid_entry?({name, %{"managed" => false} = entry}) when map_size(entry) == 1,
      do: safe_name?(name)

    defp valid_entry?({name, %{"files" => files, "source" => source}})
         when is_map(files) and is_map(source) do
      safe_name?(name) and
        Enum.all?(files, fn {path, hash} ->
          safe_path?(path) and is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)
        end)
    end

    defp valid_entry?(_entry), do: false
    defp safe_name?(name), do: Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, name)

    defp safe_path?(path) do
      Path.type(path) == :relative and
        Enum.all?(
          String.split(path, "/"),
          &(&1 not in ["", ".", ".."] and not String.contains?(&1, "\\"))
        )
    end

    defp read(igniter, path) do
      if linked?(path), do: {igniter, :linked}, else: read_regular(igniter, path)
    end

    # A developer may share skills through links. Never follow one when deciding ownership.
    defp linked?(path) do
      path
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.any?(fn part ->
        match?({:ok, %File.Stat{type: :symlink}}, File.lstat(part))
      end)
    end

    defp read_regular(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)

      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} -> {igniter, Rewrite.Source.get(source, :content)}
        {:error, _} -> {igniter, nil}
      end
    end

    defp write(igniter, path, text) do
      if Igniter.exists?(igniter, path) do
        Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, fn _ -> text end))
      else
        Igniter.create_new_file(igniter, path, text)
      end
    end

    defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end
end

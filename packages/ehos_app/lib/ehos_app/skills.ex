defmodule EhosApp.Skills do
  @moduledoc """
  Builds namespaced filesystem skills from the plugin sources bundled with `ehos_app`.

  Sources retain their release, commit and file hashes. Adaptations affect invocation and
  sibling links, not the rules a skill applies. Applications need no plugin cache or network.
  """

  @root Path.expand("../../priv/skills", __DIR__)
  @sources (for path <- Path.wildcard(Path.join(@root, "*/source.json")) do
              @external_resource path
              path |> File.read!() |> JSON.decode!()
            end)
  @files Map.new(
           for source <- @sources, path <- Map.keys(source["files"]) do
             file = Path.join([@root, source["name"], path])
             @external_resource file
             {{source["name"], path}, File.read!(file)}
           end
         )

  @doc "Returns the bundled plugins' provenance and original file hashes."
  @spec sources() :: [map()]
  def sources, do: @sources

  @doc "Returns each namespaced skill's adapted files and upstream provenance."
  @spec bundled() :: %{String.t() => map()}
  def bundled do
    Map.new(for source <- sources(), skill <- skill_names(source), do: build(source, skill))
  end

  @doc """
  Verifies a project's filesystem skills against its recorded source pins and file hashes.

  Returns `{:ok, []}` for a complete bundle at this installer's pins. Missing, stale or edited
  copies return a refusal; reconcile retained edits and their manifest before recording a review.
  This check does not consult Claude Code or its plugin cache.
  """
  @spec check(Path.t()) :: {:ok, []} | {:error, String.t()}
  def check(dir) do
    with {:ok, text} <- File.read(Path.join(dir, ".agents/ehos-skills.json")),
         {:ok, %{"version" => 1, "skills" => entries}} when is_map(entries) <- JSON.decode(text),
         true <- Enum.all?(bundled(), &installed?(&1, entries, dir)) do
      {:ok, []}
    else
      _other ->
        {:error,
         "Cannot verify the Codex skills against this installer's pins and their recorded hashes. " <>
           "Run mix ehos_app.install, then reconcile retained skills and .agents/ehos-skills.json before review."}
    end
  end

  defp installed?({name, skill}, entries, dir) do
    case entries[name] do
      %{"source" => source, "files" => files} when is_map(files) ->
        source == skill["source"] and
          Enum.all?(Map.keys(skill["files"]), &file_matches?(dir, name, &1, files[&1]))

      _other ->
        false
    end
  end

  defp file_matches?(dir, name, path, hash) when is_binary(hash) do
    case File.read(Path.join([dir, ".agents/skills", name, path])) do
      {:ok, text} -> Base.encode16(:crypto.hash(:sha256, text), case: :lower) == hash
      _other -> false
    end
  end

  defp file_matches?(_dir, _name, _path, _hash), do: false

  defp build(source, skill) do
    name = source["name"] <> "-" <> skill
    prefix = skill <> "/"

    files =
      source["files"]
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Map.new(fn path ->
        text = Map.fetch!(@files, {source["name"], path})
        relative = String.replace_prefix(path, prefix, "")
        # Rewrite.Source.write/2 normalizes the final newline. Hash the bytes it writes,
        # including for upstream LICENSE files without a final newline.
        text = adapt(text, relative, source, skill) |> String.trim_trailing()
        {relative, text <> "\n"}
      end)

    original = Map.fetch!(@files, {source["name"], skill <> "/SKILL.md"})
    files = invocation_policy(files, original)
    provenance = Map.drop(source, ["files"])
    {name, %{"source" => provenance, "files" => files}}
  end

  defp adapt(text, path, source, skill) do
    if String.ends_with?(path, ".md") do
      text
      |> namespaced(source)
      |> invocation(path, source, skill)
    else
      text
    end
  end

  defp namespaced(text, source) do
    text =
      Enum.reduce(["ehos-app", "eh-os-contract"], text, fn name, text ->
        String.replace(text, name <> ":", name <> "-")
      end)

    text =
      text
      |> String.replace(
        "mix ehos_app.review record",
        "mix ehos_app.review record --harness codex"
      )
      |> String.replace("mix ehos_app.review check", "mix ehos_app.review check --harness codex")

    # Sibling skills move together; references inside a skill keep their relative paths.
    Enum.reduce(skill_names(source), text, fn skill, text ->
      text
      |> String.replace("../#{skill}/", "../#{source["name"]}-#{skill}/")
      |> String.replace("`#{skill}`", "`#{source["name"]}-#{skill}`")
    end)
  end

  defp invocation(text, "SKILL.md", source, skill) do
    [frontmatter, body] = String.split(text, "\n---\n", parts: 2)

    frontmatter =
      frontmatter
      |> String.replace(~r/^name: .*$/m, "name: #{source["name"]}-#{skill}")
      |> String.replace(~r/^(argument-hint|disable-model-invocation): .*\n?/m, "")
      |> then(
        &Regex.replace(~r/^description: (.*)$/m, &1, fn _, description ->
          "description: " <> JSON.encode!(String.replace(description, ["<", ">"], ""))
        end)
      )
      |> String.trim_trailing()

    frontmatter <>
      "\n---\n" <>
      """

      ## Loading this skill

      This copy comes from #{source["repo"]}, #{source["ref"]}, commit `#{source["commit"]}`.
      Its upstream path is `plugins/#{source["name"]}/skills/#{skill}/SKILL.md`.
      The following loading rules take precedence over harness-specific instructions below and in its references.

      Use the native skill loader when available. Otherwise read this exact `SKILL.md` with a filesystem tool.
      Read referenced files relative to this directory, including nested skill references.
      A reference such as `ehos-app-elixir` names `.agents/skills/ehos-app-elixir/SKILL.md` from the project root.
      The absence of a Skill tool or Claude plugin is not a missing skill; stop only if its file cannot be read.
      Pass reviewers the absolute paths of these skill and reference files, and require them to read each one.
      Skills whose `agents/openai.yaml` disables implicit invocation remain user-invoked only, even when read directly.
      Where the instructions say `$ARGUMENTS`, use the user's text after the skill name.
      Without Claude hooks, run `MIX_ENV=dev mix ehos_app.review record --harness codex` after review and commit.
      Before opening a pull request, run `MIX_ENV=dev mix ehos_app.review check --harness codex`.
      These commands keep the same checks; reading files does not waive review or permission requirements.
      """ <> body
  end

  defp invocation(text, _path, _source, _skill), do: text

  defp invocation_policy(files, original) do
    [frontmatter, _body] = String.split(original, "\n---\n", parts: 2)

    if String.contains?(frontmatter, "disable-model-invocation: true") do
      Map.put(files, "agents/openai.yaml", "policy:\n  allow_implicit_invocation: false\n")
    else
      files
    end
  end

  defp skill_names(source) do
    for path <- Map.keys(source["files"]),
        [skill, "SKILL.md"] <- [String.split(path, "/")],
        do: skill
  end
end

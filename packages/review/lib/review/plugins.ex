defmodule Review.Plugins do
  @moduledoc """
  Checks that a change to a Claude Code plugin in `plugins/` raises the plugin's version, once that
  version has a tag.

  Claude Code caches a plugin by the `version` in its `.claude-plugin/plugin.json`, and keeps the
  copy it has of a version, so a change shipped under a version already released reaches nobody.
  A plugin's release is a tag `<plugin>-v<version>` on the merge commit of the pull request that
  raised the version (CONTRIBUTING.md, "Versions and releases"). So a commit that changes
  `plugins/<plugin>/` fails when its `version` has that tag, unless the plugin's directory is as
  the tag has it, as in the commit the tag names. A commit between the raise and the tag whose
  run is started again after the tag fails when its directory differs from the tag's: the check
  reads the tags of today, not of the run it repeats.

  The `changelog` workflow runs it on a pull request's merge commit against its base, and on each
  commit a push to `main` adds, as `Review.Changelog`. It reads the tags of the checkout it runs
  in, so the checkout must hold them: a repository with none raises, since every version would
  read as new.
  """

  # A name with a control character is no plugin's, and printed in a message, a newline in it
  # would start a line of its own: one GitHub Actions reads as a workflow command.
  @plugin ~r{\Aplugins/([^/[:cntrl:]]+)/}

  @doc """
  Checks each commit on the first-parent line from `from`, exclusive, to `to`, in the git
  repository `dir` is in: every plugin in `plugins/` it changes against its first parent.

  Returns `:ok`, or one message for each plugin a commit changes under a tagged version, or whose
  `plugin.json` names its version in a way Claude Code cannot read. Raises when git fails, and
  when the repository has no tag. `:git` replaces `Review.GitImpl`, for a test.
  """
  @spec check(Path.t(), String.t(), String.t(), [{:git, module()}]) ::
          :ok | {:error, [String.t()]}
  def check(dir, from, to, opts \\ []) do
    git = Keyword.get(opts, :git, Review.GitImpl)
    commits = git.first_parents(dir, from, to)
    tags = dir |> git.tags() |> tags!()

    commits
    |> Enum.flat_map(&commit_errors(git, dir, tags, &1))
    |> errors()
  end

  defp tags!([]),
    do: raise("no tag in the repository: fetch the tags, or every plugin's version reads as new")

  defp tags!(tags), do: MapSet.new(tags)

  defp commit_errors(git, dir, tags, commit) do
    dir
    |> git.changed_files(commit)
    |> Enum.flat_map(&plugin/1)
    |> Enum.uniq()
    |> Enum.flat_map(&plugin_errors(git, dir, tags, commit, &1))
  end

  defp plugin(path) do
    case Regex.run(@plugin, path) do
      [_prefix, plugin] -> [plugin]
      nil -> []
    end
  end

  # A plugin the commit removes, or whose manifest names no version, has nothing to raise: Claude
  # Code then caches it by its commit. A manifest Claude Code cannot read is named.
  defp plugin_errors(git, dir, tags, commit, plugin) do
    directory = "plugins/#{plugin}"

    with {:ok, version} <- version(git.file(dir, commit, manifest(plugin))),
         tag = "#{plugin}-v#{version}",
         true <- MapSet.member?(tags, tag),
         true <-
           git.object(dir, commit, directory) != git.object(dir, "refs/tags/#{tag}", directory) do
      ["#{directory}, in #{short(commit)}: #{message(plugin, version)}"]
    else
      {:error, problem} -> ["#{manifest(plugin)}, in #{short(commit)}: #{problem}"]
      _released_as_it_is -> []
    end
  end

  defp errors([]), do: :ok
  defp errors(messages), do: {:error, messages}

  defp message(plugin, version),
    do:
      "changes the plugin, but its version #{version} is the one #{plugin}-v#{version} " <>
        "released, and Claude Code keeps the copy of a version it has, so the change reaches " <>
        "nobody. Raise `version` in #{manifest(plugin)} in the pull request that changes the " <>
        "plugin (CONTRIBUTING.md, \"Versions and releases\")."

  defp manifest(plugin), do: "plugins/#{plugin}/.claude-plugin/plugin.json"

  defp short(commit), do: String.slice(commit, 0, 12)

  defp version(nil), do: :none

  defp version(manifest) do
    case JSON.decode(manifest) do
      {:ok, %{"version" => version}} when is_binary(version) ->
        {:ok, version}

      {:ok, %{"version" => _version}} ->
        {:error, ~s(its `version` is not a string: write it in quotes, as "0.7.0")}

      {:ok, %{}} ->
        :none

      _not_an_object ->
        {:error, "it is not a JSON object, so Claude Code cannot load the plugin"}
    end
  end
end

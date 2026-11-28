defmodule EhosRelease.Description do
  @moduledoc """
  The release pull request's description (eh-os D-205, "A release", step 1; T-34): the notes of
  each changelog, each issue the fragments name with its state, open ones first and named as
  unfinished, and a `## Review` section that says what the workflow checked, which the check
  `review section` reads like every other pull request's (T-03).

  An issue shows as `owner/repo#n` and its state, never its title, which anyone may write in a
  public repository. An issue the workflow cannot read shows as unknown.
  """

  @typedoc "What the description says."
  @type release :: %{
          component: String.t(),
          version: String.t(),
          tag: String.t(),
          floor: String.t(),
          highest: String.t() | nil,
          notes: [{changelog :: String.t(), notes :: String.t()}],
          issues: [{issue :: String.t(), state :: String.t() | :unknown}]
        }

  @doc """
  The description, in Markdown.

      iex> EhosRelease.Description.write(%{component: "shop", version: "0.2.0", tag: "v0.2.0",
      ...>   floor: "0.2.0", highest: "0.1.0", notes: [{"CHANGELOG.md", "## [0.2.0] - 2026-11-28\\n"}],
      ...>   issues: [{"EmpoweredHouse/eh-os#2", "closed"}, {"EmpoweredHouse/eh-os#3", "open"}]})
      ...> |> String.split("\\n") |> Enum.filter(&String.starts_with?(&1, "- EmpoweredHouse"))
      ["- EmpoweredHouse/eh-os#3: open, so its work is unfinished",
       "- EmpoweredHouse/eh-os#2: closed"]
  """
  @spec write(release()) :: String.t()
  def write(release) do
    """
    Releases `#{release.component}` #{release.version}. When an administrator merges this pull \
    request, the release workflow checks the merge commit again and tags it `#{release.tag}`.

    ## Notes

    #{notes(release.notes)}
    ## Issues

    Each issue a changelog fragment names, with its state when the workflow read it. An open \
    issue comes first: its work is not finished, and this release carries part of it.

    #{issues(release.issues)}

    ## Review

    The release workflow wrote this pull request from the changelog fragments. It checked:

    - that a protected release tag of its own prefix names every pin of `#{release.component}`;
    - that #{release.version} is not below #{release.floor}, the floor its fragments give, \
    and is above #{highest(release.highest)};
    - that no workflow but the release workflow names the release App's key or its environment.

    Only the release App can push to this branch. To change the version, close this pull request, \
    delete its branch and start the release again with the version.
    """
  end

  defp notes(notes) do
    Enum.map_join(notes, "\n", fn {changelog, text} ->
      "`#{changelog}`:\n\n" <> String.trim_trailing(text) <> "\n"
    end)
  end

  defp issues([]), do: "No fragment names an issue."

  defp issues(issues) do
    issues
    |> Enum.sort_by(fn {issue, state} -> {state != "open", issue} end)
    |> Enum.map_join("\n", fn
      {issue, "open"} -> "- #{issue}: open, so its work is unfinished"
      {issue, :unknown} -> "- #{issue}: unknown, as the workflow could not read it"
      {issue, state} -> "- #{issue}: #{state}"
    end)
  end

  defp highest(nil), do: "every tag of the component, as it has none yet"
  defp highest(version), do: "#{version}, its highest tag"
end

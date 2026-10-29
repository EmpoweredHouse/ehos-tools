defmodule Review.Changelog do
  @moduledoc """
  Checks that a change leaves every released version's section of a package's `CHANGELOG.md` as
  it was, unless the change is that package's release (ehos-tools#585).

  A pull request's changelog line goes under `## [Unreleased]`. Each section below it is a
  release's notes, published with its tag, and a change that edits one describes a version as
  something it was not. Nobody has to mean it: when a package is released while a pull request
  that edits one of its `[Unreleased]` lines is open, merging carries the edit into the new
  version's section (ehos-tools#583). So the `changelog` workflow checks what merging a pull
  request makes against the base it merges onto, and each commit a push to `main` adds against
  the one before it.

  A release's own pull request renames `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and sets
  `X.Y.Z`, with no `-dev`, in the package's `mix.exs`. When `X.Y.Z` is above every version the
  changelog has released, the released sections may gain that one section at their top, and
  nothing else. A change that means to edit
  released notes, a repair among them, fails too: it is merged over the failure, with the reason
  in its description.
  """

  @changelog ~r{\Apackages/([^/]+)/CHANGELOG\.md\z}

  @doc """
  Checks each commit on the first-parent line from `from`, exclusive, to `to`, in the git
  repository `dir` is in, against its first parent: every `packages/*/CHANGELOG.md` it changes.
  A pull request's merge commit is one such commit; a push to `main` is one for each pull request
  it merges, so a release and the move to the next `-dev` pushed together are each judged alone.

  Returns `:ok`, or one message for each changelog whose released sections a commit changes.
  Raises when git fails. `:git` replaces `Review.GitImpl`, for a test.
  """
  @spec check(Path.t(), String.t(), String.t(), [{:git, module()}]) ::
          :ok | {:error, [String.t()]}
  def check(dir, from, to, opts \\ []) do
    git = Keyword.get(opts, :git, Review.GitImpl)

    dir
    |> git.first_parents(from, to)
    |> Enum.flat_map(&commit_errors(git, dir, &1))
    |> errors()
  end

  @doc ~S"""
  Returns `:ok` when the `CHANGELOG.md` `to` leaves the released sections of `from` as they
  were, or adds above them the section of `release`, the version a release sets (`nil` when the
  change releases nothing), when that version is above every one `from` has released. Otherwise
  says which released section it changes, and at which line of `to`.

      iex> from = "## [Unreleased]\n\n## [0.1.0] - 2026-10-01\n\n- First.\n"
      iex> Review.Changelog.released_sections(from, from <> "- Second.\n", nil)
      {:error, "line 6, under `## [0.1.0] - 2026-10-01`, changes a released version's notes"}
  """
  @spec released_sections(String.t(), String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def released_sections(from, to, release) do
    {_unreleased, old} = split(from)
    {above, new} = to |> split() |> without_release(newer(release, old))

    if new == old, do: :ok, else: {:error, change(old, new, above)}
  end

  defp changelog_package(path) do
    case Regex.run(@changelog, path) do
      [path, package] -> [{path, package}]
      nil -> []
    end
  end

  defp commit_errors(git, dir, commit) do
    dir
    |> git.changed_files(commit)
    |> Enum.flat_map(&changelog_package/1)
    |> Enum.flat_map(&package_errors(git, dir, &1, "#{commit}^1", commit))
  end

  defp package_errors(git, dir, {path, package}, from, to) do
    release = release(git.file(dir, from, mix(package)), git.file(dir, to, mix(package)))
    from_changelog = git.file(dir, from, path) || ""
    to_changelog = git.file(dir, to, path) || ""

    case released_sections(from_changelog, to_changelog, release) do
      :ok -> []
      {:error, message} -> ["#{path}: #{message}. #{remedy(package)}"]
    end
  end

  defp errors([]), do: :ok
  defp errors(messages), do: {:error, messages}

  defp remedy(package),
    do:
      "A pull request's line goes under `## [Unreleased]`, and only #{package}'s release " <>
        "turns that section into a version's. When #{package} was released while this pull " <>
        "request was open, merge `main` into it, put the released section back as it was " <>
        "released, and write the change under `## [Unreleased]`."

  defp mix(package), do: "packages/#{package}/mix.exs"

  # The version the change sets in a package's `mix.exs`, when it sets one with no `-dev`: what
  # a release's pull request does, and nothing else. A patch release sets one below the `-dev`
  # it replaces (0.13.0-dev to 0.12.1), so how it compares with that says nothing.
  defp release(mix_before, mix_after) do
    with version when version != nil <- version(mix_after),
         true <- version != version(mix_before),
         {:ok, %Version{pre: []}} <- Version.parse(version) do
      version
    else
      _not_a_release -> nil
    end
  end

  defp version(nil), do: nil

  defp version(mix_exs) do
    case Regex.run(~r/^\s*@version "([^"]+)"/m, mix_exs) do
      [_line, version] -> version
      nil -> nil
    end
  end

  # The release, when it is above the newest version the changelog has released: a section for
  # an older or the same version is not a release's.
  defp newer(nil, _released), do: nil
  defp newer(release, []), do: release

  defp newer(release, [heading | _older]) do
    with [_heading, newest] <- Regex.run(~r/\A## \[([^\]]+)\]/, heading),
         {:ok, newest} <- Version.parse(newest),
         :gt <- Version.compare(release, newest) do
      release
    else
      _not_newer -> nil
    end
  end

  # The lines from the first released version's heading on, and the ones above them.
  defp split(changelog),
    do: changelog |> String.split("\n") |> Enum.split_while(&(not released_heading?(&1)))

  defp released_heading?(line), do: String.starts_with?(line, "## [") and not unreleased?(line)

  defp unreleased?(line), do: String.starts_with?(line, "## [Unreleased]")

  # The released sections, without the one at their top when that one is the release's, and how
  # many lines of the file are above what is left.
  defp without_release({unreleased, [heading | rest] = released}, release)
       when is_binary(release) do
    if Regex.match?(~r/\A## \[#{Regex.escape(release)}\] - \d{4}-\d{2}-\d{2}\z/, heading) do
      older = Enum.drop_while(rest, &(not released_heading?(&1)))
      {length(unreleased) + length(released) - length(older), older}
    else
      {length(unreleased), released}
    end
  end

  defp without_release({unreleased, released}, _release), do: {length(unreleased), released}

  # Where the released sections first differ: a line of `new`, or, when `new` ends there, the
  # lines `old` goes on with. A non-empty list of them starts with a released heading, so a
  # section is always found.
  defp change(old, new, above) do
    index =
      old |> Enum.zip(new) |> Enum.take_while(fn {line, other} -> line == other end) |> length()

    if index < length(new),
      do:
        "line #{above + index + 1}, under `#{section(new, index)}`, changes a released " <>
          "version's notes",
      else: "it removes released lines, the first under `#{section(old, index)}`"
  end

  defp section(lines, index),
    do: lines |> Enum.take(index + 1) |> Enum.reverse() |> Enum.find(&released_heading?/1)
end

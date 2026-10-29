defmodule Review.Changelog do
  @moduledoc """
  Checks that a change leaves every released version's section of a package's `CHANGELOG.md` as
  it was, unless the change is that package's release (ehos-tools#585).

  A pull request's changelog line goes under `## [Unreleased]`. Each section below it is a
  release's notes, published with its tag, and a change that edits one describes a version as
  something it was not. Nobody has to mean it: when a package is released while a pull request
  that edits one of its `[Unreleased]` lines is open, merging carries the edit into the new
  version's section (ehos-tools#583). So the `changelog` workflow compares what merging a pull
  request makes with the base it merges onto, and each push to `main` with the commit before it.

  A release's own pull request renames `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and sets
  `X.Y.Z`, with no `-dev`, in the package's `mix.exs`. The released sections may gain that one
  section at their top, and nothing else.
  """

  @changelog ~r{\Apackages/([^/]+)/CHANGELOG\.md\z}

  @doc """
  Checks every `packages/*/CHANGELOG.md` that differs between the commits `from` and `to` of
  the git repository `dir` is in.

  Returns `:ok`, or one message for each changelog whose released sections changed. Raises when
  git cannot compare the two commits.
  """
  @spec check(Path.t(), String.t(), String.t()) :: :ok | {:error, [String.t()]}
  def check(dir, from, to) do
    top = git!(dir, ["rev-parse", "--show-toplevel"])

    top
    |> git!(["diff", "--name-only", from, to, "--"])
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&changelog_package/1)
    |> Enum.flat_map(&package_errors(top, &1, from, to))
    |> errors()
  end

  @doc ~S"""
  Returns `:ok` when the `CHANGELOG.md` `to` leaves the released sections of `from` as they
  were, or adds above them the section of `release`, the version a release sets (`nil` when the
  change releases nothing). Otherwise says which released section it changes, and at which line
  of `to`.

      iex> from = "## [Unreleased]\n\n## [0.1.0] - 2026-10-01\n\n- First.\n"
      iex> Review.Changelog.released_sections(from, from <> "- Second.\n", nil)
      {:error, "line 6, under `## [0.1.0] - 2026-10-01`, changes a released version's notes"}
  """
  @spec released_sections(String.t(), String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def released_sections(from, to, release) do
    {_unreleased, old} = split(from)
    {above, new} = to |> split() |> without_release(release)

    if new == old, do: :ok, else: {:error, change(old, new, above)}
  end

  defp changelog_package(path) do
    case Regex.run(@changelog, path) do
      [path, package] -> [{path, package}]
      nil -> []
    end
  end

  defp package_errors(top, {path, package}, from, to) do
    release = release(show(top, from, mix(package)), show(top, to, mix(package)))

    case released_sections(show(top, from, path), show(top, to, path), release) do
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

  # The version the change sets in a package's `mix.exs`, when it sets one with no `-dev`: what a
  # release's pull request does, and nothing else.
  defp release(mix_before, mix_after) do
    with version when version != nil <- version(mix_after),
         true <- version != version(mix_before),
         {:ok, %Version{pre: []}} <- Version.parse(version) do
      version
    else
      _not_a_release -> nil
    end
  end

  defp version(mix_exs) do
    case Regex.run(~r/^\s*@version "([^"]+)"/m, mix_exs) do
      [_line, version] -> version
      nil -> nil
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

  # A file the commit does not have reads as empty: a changelog added or removed is compared
  # with nothing. `git diff` has already read both commits, so a commit git cannot read is not
  # taken for a missing file.
  defp show(top, commit, path) do
    case System.cmd("git", ["-C", top, "show", "#{commit}:#{path}"], stderr_to_stdout: true) do
      {content, 0} -> content
      {_message, _status} -> ""
    end
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} exited with #{status}: #{output}"
    end
  end
end

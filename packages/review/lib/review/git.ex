defmodule Review.Git do
  @moduledoc """
  What `Review.Changelog` and `Review.Plugins` read of a git repository, as a way out, so that
  their tests can say what the commits hold (T-20).

  Each callback raises when git fails: the repository is the checkout CI or the developer runs
  the check in, and a commit it cannot read is an error to stop on, never a change to pass.
  """

  @doc """
  The commits on the first-parent line from `from`, exclusive, to `to`, oldest first: one merge
  commit for each pull request merged with the merge button. Raises when git fails, and when
  `from` is not on that line, since the commits would then be judged against a branch's history
  rather than against `from`.
  """
  @callback first_parents(dir :: Path.t(), from :: String.t(), to :: String.t()) :: [String.t()]

  @doc """
  The paths, from the repository's root, of the files `commit` changes against its first parent.
  A renamed file is its old path and its new one. Raises when git fails.
  """
  @callback changed_files(dir :: Path.t(), commit :: String.t()) :: [String.t()]

  @doc """
  The content of the file at `path`, from the repository's root, in `commit`, or `nil` when the
  commit has no such file. Raises when git fails.
  """
  @callback file(dir :: Path.t(), commit :: String.t(), path :: String.t()) :: String.t() | nil

  @doc """
  The id of the object at `path`, from the repository's root, in `rev`: a directory's tree, or a
  file's blob, equal in two commits exactly when its content is. `nil` when `rev` has no such
  path. `rev` is a commit or a tag on one. Raises when git fails.
  """
  @callback object(dir :: Path.t(), rev :: String.t(), path :: String.t()) :: String.t() | nil

  @doc """
  The names of the repository's tags, sorted by name. Raises when git fails.
  """
  @callback tags(dir :: Path.t()) :: [String.t()]
end

defmodule Review.GitImpl do
  @moduledoc false
  @behaviour Review.Git

  @impl true
  def first_parents(dir, from, to) do
    commits =
      dir |> git!(["rev-list", "--first-parent", "--reverse", "#{from}..#{to}"]) |> lines()

    on_line!(dir, commits, from, to)
    commits
  end

  # `--no-renames`, or a renamed file would be its new path alone; `-z`, or a path with a byte
  # git quotes would be printed in quotes; `--no-relative`, or a developer's `diff.relative`
  # would list only the files under the directory the task runs in.
  @impl true
  def changed_files(dir, commit),
    do:
      dir
      |> git!([
        "diff",
        "--name-only",
        "--no-renames",
        "--no-relative",
        "-z",
        "#{commit}^1",
        commit
      ])
      |> String.split(<<0>>, trim: true)

  @impl true
  def file(dir, commit, path) do
    case object(dir, commit, path) do
      nil -> nil
      object -> git!(dir, ["cat-file", "blob", object])
    end
  end

  @impl true
  def object(dir, rev, path) do
    case git!(dir, ["ls-tree", "--full-tree", "--object-only", rev, "--", path]) do
      "" -> nil
      object -> String.trim(object)
    end
  end

  # `--sort`, or a developer's `tag.sort` would order them; `--no-column`, or `column.ui` would
  # print several on a line.
  @impl true
  def tags(dir),
    do: dir |> git!(["tag", "--list", "--sort=refname", "--no-column"]) |> lines()

  defp lines(output), do: String.split(output, "\n", trim: true)

  # The oldest commit's first parent is `from` exactly when `from` is on `to`'s first-parent
  # line: a branch that merged `main` in and was pushed as `main` lists its own commits after
  # `from`, and the first of them has another parent.
  defp on_line!(_dir, [], _from, _to), do: :ok

  defp on_line!(dir, [oldest | _newer], from, to) do
    if git!(dir, ["rev-parse", "#{oldest}^1"]) != git!(dir, ["rev-parse", "#{from}^{commit}"]),
      do: raise("#{from} is not on #{to}'s first-parent line")
  end

  # Git's standard error is left to the terminal, so a warning is never read as output.
  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args]) do
      {output, 0} -> output
      {_output, status} -> raise "git #{Enum.join(args, " ")} exited with #{status}"
    end
  end
end

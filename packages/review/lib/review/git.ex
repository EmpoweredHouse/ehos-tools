defmodule Review.Git do
  @moduledoc """
  What `Review.Changelog` reads of a git repository, as a way out, so that its tests can say what
  the commits hold (T-20).

  Each callback raises when git fails: the repository is the checkout CI or the developer runs
  the check in, and a commit it cannot read is an error to stop on, never a change to pass.
  """

  @doc """
  The commits on the first-parent line from `from`, exclusive, to `to`, oldest first: one merge
  commit for each pull request merged with the merge button. Raises when git fails.
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
end

defmodule Review.GitImpl do
  @moduledoc false
  @behaviour Review.Git

  @impl true
  def first_parents(dir, from, to),
    do: dir |> git!(["rev-list", "--first-parent", "--reverse", "#{from}..#{to}"]) |> lines()

  # `--no-renames`, or a renamed file would be its new path alone; `-z`, or a path with a byte
  # git quotes would be printed in quotes.
  @impl true
  def changed_files(dir, commit),
    do:
      dir
      |> git!(["diff", "--name-only", "--no-renames", "-z", "#{commit}^1", commit])
      |> String.split(<<0>>, trim: true)

  @impl true
  def file(dir, commit, path) do
    case git!(dir, ["ls-tree", "--full-tree", "--object-only", commit, "--", path]) do
      "" -> nil
      object -> git!(dir, ["cat-file", "blob", String.trim(object)])
    end
  end

  defp lines(output), do: String.split(output, "\n", trim: true)

  # Git's standard error is left to the terminal, so a warning is never read as output.
  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args]) do
      {output, 0} -> output
      {_output, status} -> raise "git #{Enum.join(args, " ")} exited with #{status}"
    end
  end
end

defmodule EhosRelease.Git do
  @moduledoc """
  git, as a way out (T-20): the tags of a producer, and a caller's files as a commit has them. A
  caller names an implementation in `opts[:git]`, and `EhosRelease.GitImpl` is the default.
  """

  @doc """
  Every tag of `repository` (`owner/name` on GitHub), each with the commit it names, peeled from
  an annotated tag, in one call (T-34: one call per producer, not one per pin).
  """
  @callback tags(repository :: String.t()) ::
              {:ok, %{String.t() => String.t()}} | {:error, String.t()}

  @doc """
  The file at `path` as the commit `rev` of the checkout in `dir` has it, or `:missing` when the
  commit has no such file.
  """
  @callback show(dir :: Path.t(), rev :: String.t(), path :: String.t()) ::
              {:ok, binary()} | :missing | {:error, String.t()}

  @doc "The files under `path` in the commit `rev` of the checkout in `dir`, by their full path."
  @callback files(dir :: Path.t(), rev :: String.t(), path :: String.t()) ::
              {:ok, [String.t()]} | {:error, String.t()}
end

defmodule EhosRelease.GitImpl do
  @moduledoc """
  The `EhosRelease.Git` that runs git on this machine.

  A producer's tags are read over HTTPS from GitHub. eh-os is private, so when `GH_TOKEN` is set
  it goes to git as an HTTP header through `GIT_CONFIG_*` variables, never on the command line,
  where any user of the machine could read it.
  """

  @behaviour EhosRelease.Git

  @impl true
  def tags(repository) do
    url = "https://github.com/#{repository}.git"

    case git(["ls-remote", "--tags", url], env: auth_env()) do
      {:ok, output} -> {:ok, parse_tags(output)}
      {:error, status} -> {:error, "git ls-remote of #{repository} exited with #{status}"}
    end
  end

  @impl true
  def show(dir, rev, path) do
    case git(["-C", dir, "cat-file", "-e", "#{rev}:#{path}"]) do
      {:ok, _output} -> read(dir, rev, path)
      {:error, _status} -> :missing
    end
  end

  @impl true
  def files(dir, rev, path) do
    case git(["-C", dir, "ls-tree", "-r", "--name-only", rev, "--", path]) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      {:error, status} -> {:error, "git ls-tree of #{path} at #{rev} exited with #{status}"}
    end
  end

  @doc """
  The tags in what `git ls-remote --tags` prints, each with its commit: an annotated tag's own
  object is replaced by the commit its `^{}` line names.

      iex> EhosRelease.GitImpl.parse_tags(\"""
      ...> aaa\trefs/tags/v1.0.0
      ...> bbb\trefs/tags/ehos_app-v0.1.0
      ...> ccc\trefs/tags/ehos_app-v0.1.0^{}
      ...> \""")
      %{"v1.0.0" => "aaa", "ehos_app-v0.1.0" => "ccc"}
  """
  @spec parse_tags(String.t()) :: %{String.t() => String.t()}
  def parse_tags(output) do
    lines =
      for line <- String.split(output, "\n", trim: true),
          [object, "refs/tags/" <> tag] <- [String.split(line, "\t")],
          do: {tag, object}

    {peeled, plain} = Enum.split_with(lines, fn {tag, _} -> String.ends_with?(tag, "^{}") end)

    plain
    |> Map.new()
    |> Map.merge(
      Map.new(peeled, fn {tag, commit} -> {String.trim_trailing(tag, "^{}"), commit} end)
    )
  end

  defp read(dir, rev, path) do
    case git(["-C", dir, "show", "#{rev}:#{path}"]) do
      {:ok, contents} -> {:ok, contents}
      {:error, status} -> {:error, "git show of #{path} at #{rev} exited with #{status}"}
    end
  end

  defp git(args, opts \\ []) do
    case System.cmd("git", args, stderr_to_stdout: false, env: Keyword.get(opts, :env, [])) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, status}
    end
  end

  defp auth_env do
    case System.get_env("GH_TOKEN") do
      token when token in [nil, ""] ->
        []

      token ->
        basic = Base.encode64("x-access-token:" <> token)

        [
          {"GIT_CONFIG_COUNT", "1"},
          {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"},
          {"GIT_CONFIG_VALUE_0", "AUTHORIZATION: basic " <> basic}
        ]
    end
  end
end

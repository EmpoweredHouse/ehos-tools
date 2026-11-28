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
              {:ok, %{optional(String.t()) => String.t()}} | {:error, String.t()}

  @doc """
  The file at `path` as the commit `rev` of the checkout in `dir` has it, or `:missing` when the
  commit has no such file.
  """
  @callback show(dir :: Path.t(), rev :: String.t(), path :: String.t()) ::
              {:ok, binary()} | :missing | {:error, String.t()}

  @doc "The files under `path` in the commit `rev` of the checkout in `dir`, by their full path."
  @callback files(dir :: Path.t(), rev :: String.t(), path :: String.t()) ::
              {:ok, [String.t()]} | {:error, String.t()}

  @doc """
  Every change in the checkout in `dir`, new files included, as one patch `git apply` takes:
  the release's change, which the job that holds the key checks before it applies it (T-34).
  """
  @callback patch(dir :: Path.t()) :: {:ok, binary()} | {:error, String.t()}
end

defmodule EhosRelease.GitImpl do
  @moduledoc """
  The `EhosRelease.Git` that runs git on this machine.

  A producer's tags are read over HTTPS from GitHub. eh-os is private, so when `GH_TOKEN` is set
  it goes to git as an HTTP header through `GIT_CONFIG_*` variables, never on the command line,
  where any user of the machine could read it. That call alone gets it: git runs in the caller's
  checkout with no token in its environment, and with neither an fsmonitor nor hooks, so nothing
  the checkout configures runs with the job's token.
  """

  @behaviour EhosRelease.Git

  # What a program needs to run and reach GitHub, and no secret: the proxy and the certificate
  # authority of a self-hosted runner.
  @kept_env ~w(PATH HOME LANG LC_ALL TMPDIR RUNNER_TEMP HTTPS_PROXY https_proxy HTTP_PROXY
               http_proxy NO_PROXY no_proxy SSL_CERT_FILE SSL_CERT_DIR GIT_SSL_CAINFO)

  @impl true
  def tags(repository) do
    url = "https://github.com/#{repository}.git"

    case git(["ls-remote", "--tags", url], env: child_env() ++ auth_env()) do
      {:ok, output} -> {:ok, parse_tags(output)}
      {:error, status} -> {:error, "git ls-remote of #{repository} exited with #{status}"}
    end
  end

  @impl true
  def show(dir, rev, path) do
    case git(in_checkout(dir, ["cat-file", "-e", "#{rev}:#{path}"]), stderr_to_stdout: true) do
      {:ok, _output} -> read(dir, rev, path)
      {:error, _status} -> :missing
    end
  end

  @impl true
  def files(dir, rev, path) do
    case git(in_checkout(dir, ["ls-tree", "-r", "--name-only", rev, "--", path])) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      {:error, status} -> {:error, "git ls-tree of #{path} at #{rev} exited with #{status}"}
    end
  end

  @impl true
  def patch(dir) do
    with {:ok, _output} <- git(in_checkout(dir, ["add", "--all"])),
         {:ok, patch} <-
           git(
             in_checkout(dir, [
               "diff",
               "--cached",
               "--binary",
               "--no-renames",
               "--no-ext-diff",
               "--no-textconv"
             ])
           ) do
      {:ok, patch}
    else
      {:error, status} ->
        {:error, "git could not write the release's patch: it exited with #{status}"}
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
    case git(in_checkout(dir, ["show", "#{rev}:#{path}"])) do
      {:ok, contents} -> {:ok, contents}
      {:error, status} -> {:error, "git show of #{path} at #{rev} exited with #{status}"}
    end
  end

  @doc """
  This process's environment with every variable but those a program needs to run taken out, so
  that neither git nor changie, run in a caller's checkout, gets the job's token: changie's
  templates can read the environment.
  """
  @spec child_env() :: [{String.t(), nil}]
  def child_env do
    for {name, _value} <- System.get_env(), name not in @kept_env, do: {name, nil}
  end

  defp in_checkout(dir, args),
    do: ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", dir | args]

  defp git(args, opts \\ []) do
    case System.cmd("git", args,
           stderr_to_stdout: Keyword.get(opts, :stderr_to_stdout, false),
           env: Keyword.get(opts, :env, child_env())
         ) do
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

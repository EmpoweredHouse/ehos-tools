defmodule Review do
  @moduledoc """
  Records that a commit was reviewed, and checks it before a pull request is opened.

  Every change to ehos-tools is reviewed by its author before its pull request is opened (the
  `pre-pr-review` skill in `.claude/skills/`). Once the findings are settled and `mix check` passes
  in each package the change touches, `mix review record` marks `HEAD` as reviewed. A Claude Code
  hook (`.claude/settings.json`) runs `mix review gate` before `gh pr create` and refuses to go on
  when `HEAD` carries no mark.

  A mark is an empty file named after the commit, under `ehos-tools-review/` in the repository's
  common git directory. It is never committed, every worktree of the repository sees it, and any
  new commit, amend or rebase leaves the new `HEAD` unmarked, so a review always covers what is
  sent.

  Ported from EHOS's `Ehos.Dev.Review`
  ([eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/lib/ehos/dev/review.ex)), without its
  injected command runner: the tests run `git` on repositories of their own.
  """

  @marks "ehos-tools-review"
  # Marks older than this are removed when a new one is recorded: their commits were long since
  # sent, amended or rebased away.
  @mark_lifetime_days 90

  # The command that opens a pull request, or its alias `gh pr new`, however spaced.
  @opens_pull_request ~r/\bgh\s+pr\s+(?:create|new)\b/

  @doc """
  Marks the commit checked out in `dir` as reviewed.

  Refuses when the working tree has uncommitted changes, which the mark would not cover.
  """
  @spec record(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def record(dir \\ ".") do
    with {:ok, ""} <- dir |> git(["status", "--porcelain"]) |> clean(),
         {:ok, commit} <- git(dir, ["rev-parse", "HEAD"]),
         {:ok, path} <- mark(dir, commit) do
      File.mkdir_p!(Path.dirname(path))
      :ok = prune(Path.dirname(path))
      File.write!(path, "")
      {:ok, "#{short(commit)} is marked as reviewed"}
    end
  end

  @doc """
  Returns `:ok` when the commit checked out in `dir` was marked as reviewed, or says what to do.
  """
  @spec check(Path.t()) :: :ok | {:error, String.t()}
  def check(dir \\ ".") do
    with {:ok, commit} <- git(dir, ["rev-parse", "HEAD"]),
         {:ok, path} <- mark(dir, commit) do
      if File.exists?(path) do
        :ok
      else
        {:error,
         "#{short(commit)} has not been reviewed. Follow the pre-pr-review skill " <>
           "(.claude/skills/pre-pr-review): review the change, settle what the reviews find, " <>
           "pass `mix check` in each package it touches, then run `mix review record` in " <>
           "packages/review, and open the pull request again."}
      end
    end
  end

  @doc """
  Decides a Claude Code `PreToolUse` hook for a Bash command, given the hook's JSON input.

  A command that does not open a pull request passes. One that does, as `gh pr create` or its
  alias `gh pr new`, passes only when the working tree it runs in has its `HEAD` marked as
  reviewed. One that names a branch or a repository other than that tree's (`--head`, `--repo`)
  is refused, since the mark covers the tree's `HEAD` alone. Anything the gate cannot understand
  is refused rather than let through: the hook exists to stop unreviewed pull requests, not to
  guess.

  The gate reads shell text, so it guards against an honest mistake, not an adversary: a pull
  request opened through the API (`gh api`) or a tool other than Bash, and a push to an open
  pull request, are not seen.
  """
  @spec gate(String.t()) :: :ok | {:error, String.t()}
  def gate(json) do
    with {:ok, input} <- decode(json),
         {:ok, command} <- command(input) do
      case Regex.split(@opens_pull_request, command, parts: 2, include_captures: true) do
        [_command] -> :ok
        [before, _opens, args] -> check_opened(input, before, args)
      end
    end
  end

  defp check_opened(input, before, args) do
    if args =~ ~r/(?:^|\s)(?:--head|-H|--repo|-R)(?:[\s=]|$)/ do
      {:error,
       "the review mark covers the checked-out HEAD alone; open the pull request from a " <>
         "checkout of its branch, without --head or --repo"}
    else
      with {:ok, dir} <- hook_dir(input, before), do: check(dir)
    end
  end

  @doc """
  The working tree a hook's command runs in: the session's `cwd`, or the directory the command
  first changes into, as in `cd ../worktree && gh pr create`.

  A command that changes directory in any other way before it opens the pull request is refused,
  because the gate would check the wrong tree. What follows the command that opens it, such as
  its `--body`, is not read.

      iex> Review.hook_dir(%{"cwd" => "/repo", "tool_input" => %{"command" => "gh pr create"}})
      {:ok, "/repo"}

      iex> command = "cd ../wt && gh pr create"
      iex> Review.hook_dir(%{"cwd" => "/repo", "tool_input" => %{"command" => command}})
      {:ok, "/wt"}
  """
  @spec hook_dir(map()) :: {:ok, String.t()} | {:error, String.t()}
  def hook_dir(%{"cwd" => cwd, "tool_input" => %{"command" => command}} = input)
      when is_binary(cwd) and is_binary(command) do
    [before | _rest] = Regex.split(@opens_pull_request, command, parts: 2)
    hook_dir(input, before)
  end

  def hook_dir(_input), do: {:error, "the hook's input has no `cwd` or command"}

  # `before` is the command up to the one that opens the pull request: only a directory change
  # there decides where that one runs.
  defp hook_dir(%{"cwd" => cwd}, before) when is_binary(cwd) do
    {dir, rest} =
      case Regex.run(
             ~r/^\s*cd\s+(?:--\s+)?(?:"([^"]+)"|'([^']+)'|([^\s;&]+))\s*(?:&&|;)(.*)$/s,
             before,
             capture: :all_but_first
           ) do
        nil ->
          {cwd, before}

        groups ->
          {groups |> Enum.take(3) |> Enum.find(&(&1 != "")) |> Path.expand(cwd),
           List.last(groups)}
      end

    # Any other `cd` or `pushd`, a quoted one as in `bash -c 'cd ..'` included, and `env -C`.
    if rest =~ ~r/(^|[\s;&|('"`])(cd|pushd)\s|\benv\b[^;&|]*\s(-C|--chdir)\b/ do
      {:error,
       "cannot tell which working tree this command opens a pull request from; " <>
         "run it as `cd <worktree> && gh pr create ...`"}
    else
      {:ok, dir}
    end
  end

  defp hook_dir(_input, _before), do: {:error, "the hook's input has no `cwd`"}

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, input} when is_map(input) -> {:ok, input}
      _other -> {:error, "the hook's input is not a JSON object"}
    end
  end

  defp command(%{"tool_input" => %{"command" => command}}) when is_binary(command),
    do: {:ok, command}

  defp command(_input), do: {:error, "the hook's input has no command"}

  defp prune(marks) do
    cutoff = System.os_time(:second) - @mark_lifetime_days * 86_400

    # Another worktree may record, and prune, at the same time: a mark that is gone, or anything
    # but a mark, is left to it.
    for name <- File.ls!(marks),
        path = Path.join(marks, name),
        {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.stat(path, time: :posix)],
        mtime < cutoff do
      _ = File.rm(path)
    end

    :ok
  end

  defp mark(dir, commit) do
    with {:ok, git_dir} <- git(dir, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {:ok, Path.join([git_dir, @marks, commit])}
    end
  end

  defp clean({:ok, ""}), do: {:ok, ""}

  defp clean({:ok, _changes}),
    do: {:error, "the working tree has uncommitted changes; commit them, review, then record"}

  defp clean(error), do: error

  defp git(dir, args) do
    case System.find_executable("git") do
      nil ->
        {:error, "`git` is not installed"}

      git ->
        case System.cmd(git, ["-C", dir | args], stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output)}
          {output, _status} -> {:error, "`git #{Enum.join(args, " ")}` failed:\n" <> output}
        end
    end
  end

  defp short(commit), do: String.slice(commit, 0, 12)
end

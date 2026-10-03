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

  # The command that opens a pull request, or its alias `gh pr new`: however spaced, continued
  # over lines with `\`, and with flags between `pr` and the subcommand (`gh pr -R x create`).
  @opens_pull_request ~r/\bgh(?:\s|\\\n)+pr\b(?:[^;&|\n]|\\\n)*?\b(?:create|new)\b/

  # A flag that points the pull request at another branch or repository than the checkout's, in
  # any form gh accepts: `--head x`, `--head=x`, `-H x`, `-Hx`, a bundle like `-fH x`. Read in
  # everything after the command starts, so a body that names one is refused too.
  @other_branch_or_repo ~r/(?:^|\s)(?:--head\b|--repo\b|-[A-Za-z]*[HR])/

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

  # A fenced code block, which may hold a heading that is not one: opened by ``` (whose info
  # string has no backtick, or the line is inline code) or ~~~, and closed, as CommonMark has it,
  # by a fence of the same character at least as long, or by the end of the text.
  @fenced_code ~r/
    ^\ {0,3} (?: (`{3,}) [^`\n]* | (~{3,}) [^\n]* ) \n
    .*? (?: ^\ {0,3} (?: \1`* | \2~* ) [ \t]* $ | \z)
  /msx
  # An inline code span, which may hold `<!--` that opens no comment.
  @inline_code ~r/(`+)[^`\n].*?\1/
  # A level-2 heading whose first word is Review, and what follows it up to the next level-1 or
  # level-2 heading.
  @review_section ~r/^ {0,3}\#\#[ \t]+\**review\b[^\n]*$(.*?)(?=^ {0,3}\#{1,2}[ \t]|\z)/msi
  @rerun "Then edit the description: re-running the job reads the description it had."

  @doc ~S"""
  Returns `:ok` when a pull request's description records its author's review, or says what is
  missing.

  The local mark (`record/1`) is seen only on the author's machine. Where the pull request lands,
  CI reads its description instead (ehos-tools T-03): a `## Review` section, with something in it
  before the next `#` or `##` heading, saying what each review found and what became of it, or
  that the change is documentation alone. The heading may carry more after the word
  (`## Review ✅`, `## review:`); `## Reviews` is another heading. A comment (`<!-- … -->`,
  closed or not), a sub-heading, and a fenced code block are not something, and a heading inside
  a code block is not the section. Of several `## Review` sections, one with something in it is
  enough.

      iex> Review.pull_request_body("## What\n\nA fix.\n\n## Review\n\nNothing found.\n")
      :ok

      iex> {:error, message} = Review.pull_request_body("## What\n\nA fix.\n")
      iex> message =~ "no `## Review` section"
      true
  """
  @spec pull_request_body(String.t() | nil) :: :ok | {:error, String.t()}
  def pull_request_body(body) do
    body =
      (body || "")
      |> String.replace(~r/\r\n?/, "\n")
      # Code before comments: a `<!--` in code opens no comment.
      |> String.replace(@fenced_code, "")
      |> String.replace(@inline_code, "")
      |> String.replace(~r/<!--.*?(?:-->|\z)/s, "")

    sections = Regex.scan(@review_section, body, capture: :all_but_first)

    cond do
      sections == [] ->
        {:error,
         "the pull request's description has no `## Review` section. Follow the " <>
           "pre-pr-review skill (.claude/skills/pre-pr-review): list what each of the two " <>
           "reviews found and what became of each finding, or say the change is documentation " <>
           "alone, under `## Review`. " <> @rerun}

      Enum.any?(sections, fn [section] -> says_something?(section) end) ->
        :ok

      true ->
        {:error,
         "the pull request's `## Review` section is empty: say what each review found and " <>
           "what became of each finding, or that the change is documentation alone. " <> @rerun}
    end
  end

  defp says_something?(section) do
    section
    |> String.replace(~r/^ {0,3}\#{3,6}[ \t].*$/m, "")
    |> String.replace(~r/[\x{200B}\x{200C}\x{200D}\x{2060}\x{FEFF}]/u, "")
    |> String.trim()
    |> Kernel.!=("")
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
  reviewed. One that names a branch or a repository other than that tree's (`--head`, `--repo`,
  `GH_REPO`) is refused, since the mark covers the tree's `HEAD` alone; so is one where anything
  after the command opens names such a flag, a later command or the body's text included.
  Anything the gate cannot understand is refused rather than let through: the hook exists to stop
  unreviewed pull requests, not to guess.

  The gate reads shell text, so it guards against an honest mistake, not an adversary: a pull
  request opened through the API (`gh api`) or a tool other than Bash, and a push to an open
  pull request, are not seen.
  """
  @spec gate(String.t()) :: :ok | {:error, String.t()}
  def gate(json) do
    with {:ok, input} <- decode(json),
         {:ok, command} <- command(input) do
      case Regex.run(@opens_pull_request, command, return: :index) do
        nil ->
          :ok

        [{start, _length}] ->
          # `GH_REPO` names the repository from anywhere in the command, as an assignment or an
          # export before it.
          if binary_part(command, start, byte_size(command) - start) =~ @other_branch_or_repo or
               command =~ ~r/\bGH_REPO=/ do
            {:error,
             "the review mark covers the checked-out HEAD alone; open the pull request from " <>
               "a checkout of its branch, without --head, --repo or GH_REPO"}
          else
            with {:ok, dir} <- hook_dir(input), do: check(dir)
          end
      end
    end
  end

  @doc """
  The working tree a hook's command runs in: the session's `cwd`, or the directory the command
  first changes into, as in `cd ../worktree && gh pr create`.

  A command that changes directory in any other way before it opens its last pull request is
  refused, because the gate would check the wrong tree. What follows that, such as its `--body`,
  is not read.

      iex> Review.hook_dir(%{"cwd" => "/repo", "tool_input" => %{"command" => "gh pr create"}})
      {:ok, "/repo"}

      iex> command = "cd ../wt && gh pr create"
      iex> Review.hook_dir(%{"cwd" => "/repo", "tool_input" => %{"command" => command}})
      {:ok, "/wt"}
  """
  @spec hook_dir(map()) :: {:ok, String.t()} | {:error, String.t()}
  def hook_dir(%{"cwd" => cwd, "tool_input" => %{"command" => command}})
      when is_binary(cwd) and is_binary(command) do
    # Up to the last command that opens a pull request: a directory change anywhere before it
    # decides where that one, or an earlier one, runs.
    before =
      case Regex.scan(@opens_pull_request, command, return: :index) do
        [] -> command
        matches -> binary_part(command, 0, matches |> List.last() |> hd() |> elem(0))
      end

    hook_dir(cwd, before)
  end

  def hook_dir(_input), do: {:error, "the hook's input has no `cwd` or command"}

  defp hook_dir(cwd, before) do
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

    # Any other `cd`, `pushd` or `popd`, a quoted one as in `bash -c 'cd ..'` included, and
    # `env -C`.
    if rest =~ ~r/(^|[\s;&|('"`])(cd|pushd|popd)(\s|$)|\benv\b[^;&|]*\s(-C|--chdir)\b/ do
      {:error,
       "cannot tell which working tree this command opens a pull request from; " <>
         "run it as `cd <worktree> && gh pr create ...`"}
    else
      {:ok, dir}
    end
  end

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

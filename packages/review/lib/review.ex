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

  # What is not the description's text, removed in one pass from the left, so that whichever
  # starts first wins: a `<!--` in code opens no comment, and a fence in a comment opens no code.
  #
  # - A fenced code block, which may hold a heading that is not one: opened by ``` (whose info
  #   string has no backtick, or the line is inline code) or ~~~, and closed, as CommonMark has
  #   it, by a fence of the same character at least as long, or by the end of the text.
  # - An inline code span.
  # - A comment, closed or not.
  @not_text ~r/
      ^\ {0,3} (?: (`{3,}) [^`\n]* | (~{3,}) [^\n]* ) \n
        .*? (?: ^\ {0,3} (?: \1`* | \2~* ) [ \t]* $ | \z)
    | (`+) [^`\n] [^\n]*? \3
    | <!-- .*? (?: --> | \z)
  /msx
  # A level-2 heading whose first word is Review, and what follows it up to the next level-1 or
  # level-2 heading, an empty one (`##` alone) included.
  @review_section ~r/^ {0,3}\#\#[ \t]+\**review\b[^\n]*$(.*?)(?=^ {0,3}\#{1,2}(?:[ \t]|$)|\z)/msi
  # Lines that are Markdown's structure and say nothing: a sub-heading, a thematic break, an empty
  # list item or quote.
  @structure ~r/
      ^\ {0,3} \#{3,6} (?:[ \t].*)? $
    | ^\ {0,3} (?: (?:-[ \t]*){3,} | (?:\*[ \t]*){3,} | (?:_[ \t]*){3,} ) $
    | ^[ \t]* (?: (?: [-*+] | \d{1,9}[.)] ) (?=[ \t]|$) [ \t]* | > [ \t]* )+ $
  /mx
  @rerun "Then edit the description: re-running the job reads the description it had."

  @doc ~S"""
  Returns `:ok` when a pull request's description records its author's review, or says what is
  missing.

  The local mark (`record/1`) is seen only on the author's machine. Where the pull request lands,
  CI reads its description instead (ehos-tools T-03): a `## Review` section, with something in it
  before the next `#` or `##` heading, saying what each review found and what became of it, or
  that the change is documentation alone. The heading may carry more after the word
  (`## Review ✅`, `## review:`); `## Reviews` is another heading. A comment (`<!-- … -->`,
  closed or not), code, a sub-heading, a thematic break and an empty list item are not
  something, and a heading inside a code block or a comment is not the section. Of several
  `## Review` sections, one with something in it is enough. That is all CI can check: what the
  something says is for whoever reads the pull request.

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
      # A mark where the text was, so that what follows it cannot begin a line and read as
      # a heading GitHub does not show; `says_something?/1` reads the mark as nothing.
      |> String.replace(@not_text, "\0")

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
    |> String.replace(~r/[\x{0}\x{200B}\x{200C}\x{200D}\x{2060}\x{FEFF}]/u, "")
    |> String.replace(@structure, "")
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

  One that moves HEAD before it opens the pull request (a commit, a checkout, a rebase…), or sets
  `GIT_DIR` or `GIT_WORK_TREE`, is refused too: the gate reads HEAD before the command runs. So
  is one that names `gh` and is longer than 64 KiB, or too intricate for its regexes to read.

  The gate reads shell text, so it guards against an honest mistake, not an adversary: a pull
  request opened through the API (`gh api`) or a tool other than Bash, and a push to an open
  pull request, are not seen.
  """
  @spec gate(String.t()) :: :ok | {:error, String.t()}
  def gate(json) do
    with {:ok, input} <- decode(json),
         {:ok, command} <- command(input) do
      readable(fn -> gate_command(input, command) end)
    end
  end

  defp gate_command(input, command) do
    with :ok <- not_too_long(command) do
      case re(@opens_pull_request, command, capture: :first) do
        :nomatch ->
          :ok

        {:match, [{start, _length}]} ->
          # `GH_REPO` names the repository from anywhere in the command, as an assignment or an
          # export before it.
          if matches?(
               @other_branch_or_repo,
               binary_part(command, start, byte_size(command) - start)
             ) or
               matches?(~r/\bGH_REPO=/, command) do
            {:error,
             "the review mark covers the checked-out HEAD alone; open the pull request from " <>
               "a checkout of its branch, without --head, --repo or GH_REPO"}
          else
            before = before_last_opening(command)

            with :ok <- head_stays(before),
                 {:ok, dir} <- dir_before(input["cwd"], before),
                 do: check(dir)
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
    readable(fn -> dir_before(cwd, before_last_opening(command)) end)
  end

  def hook_dir(_input), do: {:error, "the hook's input has no `cwd` or command"}

  # Erlang's `re` gives up at a match limit, and then reports no match unless asked to report
  # the error: a regex looking for something to refuse would let the command through. Every
  # regex the gate uses runs through `re/3`, which reports it, and the gate then refuses.
  # `pull_request_body/1`'s do not: no description GitHub accepts comes near the limit, and CI,
  # not a hook, runs them.
  defp re(regex, subject, opts) do
    case :re.run(subject, regex.re_pattern, [:report_errors | opts]) do
      {:error, reason} -> throw({:unreadable, reason})
      result -> result
    end
  end

  defp matches?(regex, subject), do: re(regex, subject, capture: :none) == :match

  defp readable(fun) do
    fun.()
  catch
    {:unreadable, _reason} ->
      {:error,
       "this command is too intricate for the gate to read; open the pull request with a " <>
         "command of its own, its body in a file"}
  end

  # Some of these regexes take time that grows faster than the text on some inputs, and a hook
  # that runs past its timeout lets the command through. A command that names `gh` and is longer
  # than any an agent writes by hand is refused before they run; one that does not name it
  # opens no pull request, however long.
  @max_command_bytes 65_536

  defp not_too_long(command) do
    if byte_size(command) > @max_command_bytes and matches?(~r/\bgh\b/, command),
      do:
        {:error,
         "this command is longer than #{@max_command_bytes} bytes, more than the gate reads; " <>
           "open the pull request with a command of its own, its body in a file"},
      else: :ok
  end

  # The command up to the last one that opens a pull request: a directory change, or a move of
  # HEAD, anywhere before it decides where that one, or an earlier one, runs, and what it sends.
  defp before_last_opening(command) do
    case re(@opens_pull_request, command, [:global, capture: :first]) do
      :nomatch -> command
      {:match, matches} -> binary_part(command, 0, matches |> List.last() |> hd() |> elem(0))
    end
  end

  # The gate reads HEAD before the command runs. A git command before the pull request opens
  # that makes a commit or checks out another one would send what the mark does not cover, and
  # `GIT_DIR` or `GIT_WORK_TREE` point gh at another repository's HEAD. A `stash` or a `push`
  # leaves HEAD where it is. The subcommand is git's first word after its own options: those
  # that take a value (`-C dir`, `-c key=value`, `--work-tree x`, quoted or not) and those that
  # do not (`--no-pager`), so `git push origin revert-x` or `git log --grep merge` pass. A line
  # continued with `\` is read as one line. gh's own commands that check out are refused too:
  # `gh pr checkout`, after `-R x` or not, and `gh repo sync`. Each option is read one way only
  # (a possessive loop, a value that does not start with `-`), so no input makes the regex try
  # its options in more than one order.
  @moves_head ~r/
    \bgit
      (?: (?:\s|\\\n)+ (?: -[cC] | --(?:git-dir|work-tree|namespace|config-env|super-prefix) )
            (?:\s|\\\n)+ (?: "[^"]*" | '[^']*' | [^\s;&|"'-][^\s;&|]* )
        | (?:\s|\\\n)+ -[^\s;&|]+
      )*+
      (?:\s|\\\n)+
      (?:commit|checkout|switch|rebase|pull|merge|reset|am|cherry-pick|revert|bisect)
      (?![\w-])
    | \bgh (?:\s|\\\n)+ pr
      (?: (?:\s|\\\n)+ (?:-R|--repo) (?:\s|\\\n)+ [^\s;&|]+ | (?:\s|\\\n)+ -[^\s;&|]+ )*+
      (?:\s|\\\n)+ checkout (?![\w-])
    | \bgh (?:\s|\\\n)+ repo (?:\s|\\\n)+ sync (?![\w-])
    | \bGIT_(?:DIR|WORK_TREE)=
  /x

  defp head_stays(before) do
    if matches?(@moves_head, before) do
      {:error,
       "this command moves HEAD (a commit, a checkout, a rebase…) or points git elsewhere " <>
         "before it opens the pull request, so the review mark would not cover what is sent; " <>
         "run that first, review the commit it makes, then open the pull request on its own"}
    else
      :ok
    end
  end

  defp dir_before(cwd, before) when is_binary(cwd) do
    {dir, rest} =
      case re(
             ~r/^\s*cd\s+(?:--\s+)?(?:"([^"]+)"|'([^']+)'|([^\s;&]+))\s*(?:&&|;)(.*)$/s,
             before,
             [{:capture, :all_but_first, :binary}]
           ) do
        :nomatch ->
          {cwd, before}

        {:match, groups} ->
          {groups |> Enum.take(3) |> Enum.find(&(&1 != "")) |> Path.expand(cwd),
           List.last(groups)}
      end

    # Any other `cd`, `pushd` or `popd`, a quoted one as in `bash -c 'cd ..'` included, and
    # `env -C`.
    if matches?(~r/(^|[\s;&|('"`])(cd|pushd|popd)(\s|$)|\benv\b[^;&|]*\s(-C|--chdir)\b/, rest) do
      {:error,
       "cannot tell which working tree this command opens a pull request from; " <>
         "run it as `cd <worktree> && gh pr create ...`"}
    else
      {:ok, dir}
    end
  end

  defp dir_before(_cwd, _before), do: {:error, "the hook's input has no `cwd`"}

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

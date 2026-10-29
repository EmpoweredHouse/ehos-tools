defmodule Review do
  @moduledoc """
  Records that a commit was reviewed, and checks it before a pull request is opened.

  Every change to ehos-tools is reviewed by its author before its pull request is opened (the
  `ehos-dev:pre-pr-review` skill, with this repository's part in `.claude/review.md`). Once the
  findings are settled and `mix check` passes in each package the change touches,
  `mix review record` marks `HEAD` as reviewed. A Claude Code hook (`.claude/settings.json`) runs
  `mix review gate` before `gh pr create` and refuses to go on when `HEAD` carries no mark. Where
  the pull request lands, the `review` workflow runs `mix review pull_request`, which fails while
  its description does not record the review (T-03).

  The gate is `EhosApp.Review`, the one every application `ehos_app` generates has (T-17): this
  module gives it ehos-tools' marks, under `ehos-tools-review/` in the repository's common git
  directory, and messages that name this repository's skill and task. What a mark is, what the
  hook refuses and what a description must hold are documented there.
  """

  @opts [
    marks: "ehos-tools-review",
    unreviewed:
      "Follow the ehos-dev:pre-pr-review skill (this repository's part is .claude/review.md): " <>
        "review the change, settle what the reviews find, pass `mix check` in each package it " <>
        "touches, then run `mix review record` in packages/review, and open the pull request " <>
        "again.",
    no_section:
      "Follow the ehos-dev:pre-pr-review skill (this repository's part is .claude/review.md): " <>
        "list what each of the two reviews found and what became of each finding, or say the " <>
        "change is documentation alone, under `## Review`."
  ]

  @doc """
  What ehos-tools gives `EhosApp.Review`: the directory its marks go in, `ehos-tools-review`, and
  the messages that tell an author what to do, which name this repository's skill and task.
  """
  @spec options() :: [EhosApp.Review.option()]
  def options, do: @opts

  @doc """
  Marks the commit checked out in `dir` as reviewed (`EhosApp.Review.record/2`).

  Returns `{:ok, message}` naming the commit, as in `"0123456789ab is marked as reviewed"`.
  Refuses with `{:error, message}` when the working tree has uncommitted changes, which the mark
  would not cover, and when git cannot read `HEAD`: then the message names the git command that
  failed, with its output, or says that `git` is not installed.
  """
  @spec record(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def record(dir \\ "."), do: EhosApp.Review.record(dir, @opts)

  @doc """
  Returns `:ok` when the commit checked out in `dir` was marked as reviewed
  (`EhosApp.Review.check/2`).

  Otherwise returns `{:error, message}`: that the commit has not been reviewed, and what to do
  about it (follow the `ehos-dev:pre-pr-review` skill, then run `mix review record` in
  `packages/review`), or, as for `record/1`, why git cannot read `HEAD`.
  """
  @spec check(Path.t()) :: :ok | {:error, String.t()}
  def check(dir \\ "."), do: EhosApp.Review.check(dir, @opts)

  @doc ~S"""
  Decides a Claude Code `PreToolUse` hook for a Bash command, given the hook's JSON input, of
  which it reads `cwd` and `tool_input.command` (`EhosApp.Review.gate/2`).

  Returns `:ok` for a command that opens no pull request, and for one that opens it from a
  working tree whose `HEAD` is marked as reviewed. Otherwise returns `{:error, message}`, which
  the hook shows Claude: `check/1`'s message for an unreviewed `HEAD`, or why the command is
  refused when the gate cannot read it, it names a branch or repository other than the tree's, it
  moves `HEAD` before it opens the pull request, or it changes directory in a way the gate cannot
  follow. `EhosApp.Review.gate/2` says in full what it refuses.

      iex> Review.gate(~s({"cwd": "/repo", "tool_name": "Bash", "tool_input": {"command": "git status"}}))
      :ok

      iex> Review.gate("not JSON")
      {:error, "the hook's input is not a JSON object"}
  """
  @spec gate(String.t()) :: :ok | {:error, String.t()}
  def gate(json), do: EhosApp.Review.gate(json, @opts)

  @doc ~S"""
  Returns `:ok` when a pull request's description records its author's review, or
  `{:error, message}` saying what is missing (`EhosApp.Review.pull_request_body/2`, T-03): a
  `## Review` section, which a description that is `nil` has none of, or something in it. For a
  missing section, the message names this repository's skill and its part, `.claude/review.md`.

      iex> Review.pull_request_body("## What\n\nA fix.\n\n## Review\n\nNothing found.\n")
      :ok

      iex> {:error, message} = Review.pull_request_body("## What\n\nA fix.\n")
      iex> message =~ "ehos-dev:pre-pr-review"
      true
  """
  @spec pull_request_body(String.t() | nil) :: :ok | {:error, String.t()}
  def pull_request_body(body), do: EhosApp.Review.pull_request_body(body, @opts)
end

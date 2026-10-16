defmodule Review do
  @moduledoc """
  Records that a commit was reviewed, and checks it before a pull request is opened.

  Every change to ehos-tools is reviewed by its author before its pull request is opened (the
  `ehos-dev:pre-pr-review` skill, with this repository's part in `.claude/review.md`). Once the
  findings are settled and `mix check` passes in each package the change touches,
  `mix review record` marks `HEAD` as reviewed. A Claude Code hook (`.claude/settings.json`) runs
  `mix review gate` before `gh pr create` and refuses to go on when `HEAD` carries no mark.

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

  @doc "What ehos-tools gives `EhosApp.Review`: its marks' directory and its messages."
  @spec options() :: [EhosApp.Review.option()]
  def options, do: @opts

  @doc """
  Marks the commit checked out in `dir` as reviewed (`EhosApp.Review.record/2`).

  Refuses when the working tree has uncommitted changes, which the mark would not cover.
  """
  @spec record(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def record(dir \\ "."), do: EhosApp.Review.record(dir, @opts)

  @doc """
  Returns `:ok` when the commit checked out in `dir` was marked as reviewed, or says what to do
  (`EhosApp.Review.check/2`).
  """
  @spec check(Path.t()) :: :ok | {:error, String.t()}
  def check(dir \\ "."), do: EhosApp.Review.check(dir, @opts)

  @doc """
  Decides a Claude Code `PreToolUse` hook for a Bash command, given the hook's JSON input
  (`EhosApp.Review.gate/2`).
  """
  @spec gate(String.t()) :: :ok | {:error, String.t()}
  def gate(json), do: EhosApp.Review.gate(json, @opts)

  @doc ~S"""
  Returns `:ok` when a pull request's description records its author's review, or says what is
  missing (`EhosApp.Review.pull_request_body/2`, T-03).

      iex> {:error, message} = Review.pull_request_body("## What\n\nA fix.\n")
      iex> message =~ "ehos-dev:pre-pr-review"
      true
  """
  @spec pull_request_body(String.t() | nil) :: :ok | {:error, String.t()}
  def pull_request_body(body), do: EhosApp.Review.pull_request_body(body, @opts)
end

defmodule Mix.Tasks.EhosApp.ReviewTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Hammox

  alias Mix.Tasks.EhosApp.Review

  setup :verify_on_exit!

  @no_section "the pull request's description has no `## Review` section. Follow the " <>
                "ehos-app:pre-pr-review skill: list what each of its reviews found and what " <>
                "became of each finding, or say the change is documentation alone, under " <>
                "`## Review`. Then edit the description: re-running the job reads the " <>
                "description it had."

  # The task's `pull_request`, through `EhosApp.Review.run_task/3`, which takes the environment
  # in `opts`; the task passes none, and reads the process's.
  describe "pull_request" do
    test "passes a description that records the review" do
      mock_get("## What\n\nA fix.\n\n## Review\n\nNothing found.\n")

      assert capture_io(fn -> assert pull_request() == :ok end) ==
               "The pull request's description records its review\n"
    end

    test "fails a description without a review, naming the skill" do
      mock_get("## What\n\nA fix.\n")

      assert_raise Mix.Error, @no_section, fn -> pull_request() end
    end

    test "fails when the workflow passes no description" do
      mock_get(nil)

      assert_raise Mix.Error, @no_section, fn -> pull_request() end
    end

    # The task itself, which every application's `review` workflow runs, with no `:env`: it
    # reads the process's environment, where no test sets the variable.
    test "reads the description from the process's environment when given none" do
      assert System.get_env("PULL_REQUEST_BODY") == nil

      assert_raise Mix.Error, @no_section, fn -> Review.run(["pull_request"]) end
    end
  end

  test "says how to use it when given anything else" do
    assert_raise Mix.Error,
                 "Usage: mix ehos_app.review record | check | gate | pull_request | plugins",
                 fn ->
                   Review.run(["recrod"])
                 end
  end

  defp pull_request,
    do: EhosApp.Review.run_task(["pull_request"], "ehos_app.review", env: EhosApp.EnvMock)

  defp mock_get(body),
    do: expect(EhosApp.EnvMock, :get, fn "PULL_REQUEST_BODY" -> body end)
end

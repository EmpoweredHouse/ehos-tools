defmodule Mix.Tasks.EhosApp.ReviewTest do
  # Sets PULL_REQUEST_BODY, which the whole VM shares.
  use ExUnit.Case, async: false

  alias Mix.Tasks.EhosApp.Review

  setup do
    previous = System.get_env("PULL_REQUEST_BODY")
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      if previous,
        do: System.put_env("PULL_REQUEST_BODY", previous),
        else: System.delete_env("PULL_REQUEST_BODY")
    end)
  end

  test "pull_request passes a description that records the review" do
    System.put_env("PULL_REQUEST_BODY", "## What\n\nA fix.\n\n## Review\n\nNothing found.\n")

    assert Review.run(["pull_request"]) == :ok
    assert_received {:mix_shell, :info, ["The pull request's description records its review"]}
  end

  test "pull_request fails a description without a review, naming the skill" do
    System.put_env("PULL_REQUEST_BODY", "## What\n\nA fix.\n")

    error = assert_raise Mix.Error, fn -> Review.run(["pull_request"]) end
    assert error.message =~ "ehos-app:pre-pr-review"
  end

  test "pull_request fails when the workflow passes no description" do
    System.delete_env("PULL_REQUEST_BODY")

    assert_raise Mix.Error, ~r/no `## Review` section/, fn -> Review.run(["pull_request"]) end
  end

  test "says how to use it when given anything else" do
    assert_raise Mix.Error, ~r/Usage: mix ehos_app.review/, fn -> Review.run(["recrod"]) end
  end
end

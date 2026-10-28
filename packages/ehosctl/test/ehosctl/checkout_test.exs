defmodule Ehosctl.CheckoutTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.Checkout

  doctest Ehosctl.Checkout

  @moduletag :tmp_dir

  @now ~U[2026-10-27 12:00:00Z]

  # Reads a repository of its own with the real git: what git answers is what is tested.
  setup do
    stub_with(Ehosctl.RunnerMock, Ehosctl.RunnerImpl)
    :ok
  end

  # A repository of its own, with no hook, signing or configuration of the machine's.
  defp git!(dir, args, env \\ []) do
    env =
      [
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_AUTHOR_NAME", "Ada Lovelace"},
        {"GIT_AUTHOR_EMAIL", "ada@example.com"},
        {"GIT_COMMITTER_NAME", "Ada Lovelace"},
        {"GIT_COMMITTER_EMAIL", "ada@example.com"},
        {"GIT_COMMITTER_DATE", "2026-10-27T11:30:00+02:00"}
      ] ++ env

    {out, 0} = System.cmd("git", ["-C", dir | args], env: env, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit!(dir, message, env \\ []) do
    git!(dir, ["commit", "--allow-empty", "--allow-empty-message", "-q", "-m", message], env)
    git!(dir, ["rev-parse", "HEAD"])
  end

  defp repository!(dir) do
    git!(dir, ["init", "-q", "-b", "main"])
    dir
  end

  defp job(sha, extra \\ %{}),
    do: Map.merge(%{"GITHUB_ACTIONS" => "true", "GITHUB_SHA" => sha}, extra)

  test "outside a GitHub Actions job, states nothing, whatever the checkout holds",
       %{tmp_dir: tmp_dir} do
    dir = repository!(tmp_dir)
    sha = commit!(dir, "Lend a book for longer")

    assert Checkout.stated(%{"GITHUB_SHA" => sha}, dir, @now) == %{}
    assert Checkout.stated(%{"GITHUB_ACTIONS" => "false", "GITHUB_SHA" => sha}, dir, @now) == %{}
  end

  test "on a push, states the commit's first line, author and time, and the commits before it",
       %{tmp_dir: tmp_dir} do
    dir = repository!(tmp_dir)
    first = commit!(dir, "Start the ledger")
    second = commit!(dir, "Count the books\n\nWith a body that is not stated.")
    sha = commit!(dir, "Lend a book for longer", [{"GIT_AUTHOR_NAME", "Zoë Müller"}])

    assert Checkout.stated(job(sha), dir, @now) == %{
             "title" => "Lend a book for longer",
             "author" => "Zoë Müller",
             "committed_at" => "2026-10-27T09:30:00Z",
             "commits" => [
               %{"commit" => second, "title" => "Count the books"},
               %{"commit" => first, "title" => "Start the ledger"}
             ]
           }
  end

  test "follows first parents alone, at most 100 commits before it", %{tmp_dir: tmp_dir} do
    dir = repository!(tmp_dir)
    for n <- 1..101, do: commit!(dir, "Commit #{n}")
    git!(dir, ["checkout", "-q", "-b", "topic", "HEAD~1"])
    commit!(dir, "On the topic")
    git!(dir, ["checkout", "-q", "main"])
    git!(dir, ["merge", "-q", "--no-ff", "-m", "Merge the topic", "topic"])
    sha = git!(dir, ["rev-parse", "HEAD"])

    stated = Checkout.stated(job(sha), dir, @now)
    assert stated["title"] == "Merge the topic"
    assert length(stated["commits"]) == 100
    assert hd(stated["commits"])["title"] == "Commit 101"
    refute Enum.any?(stated["commits"], &(&1["title"] == "On the topic"))
  end

  test "on a pull request, states its number, head and title, and the head's commit",
       %{tmp_dir: tmp_dir} do
    dir = repository!(tmp_dir)
    base = commit!(dir, "Start the ledger")
    head = commit!(dir, "Lend a book for longer")
    git!(dir, ["checkout", "-q", "-b", "merge", base])
    merge = commit!(dir, "Merge #{head} into #{base}")

    event = Path.join(tmp_dir, "event.json")

    File.write!(
      event,
      JSON.encode!(%{
        "pull_request" => %{
          "number" => 42,
          "title" => "Lend a book \u202Efor longer",
          "head" => %{"sha" => head}
        }
      })
    )

    env = job(merge, %{"GITHUB_EVENT_NAME" => "pull_request", "GITHUB_EVENT_PATH" => event})

    assert Checkout.stated(env, dir, @now) == %{
             "title" => "Lend a book for longer",
             "author" => "Ada Lovelace",
             "committed_at" => "2026-10-27T09:30:00Z",
             "pull_request" => %{
               "number" => 42,
               "head" => head,
               "title" => "Lend a book for longer"
             },
             "commits" => [%{"commit" => base, "title" => "Start the ledger"}]
           }
  end

  test "on pull_request_target, states the base's commit, beside its pull request",
       %{tmp_dir: tmp_dir} do
    dir = repository!(tmp_dir)
    base = commit!(dir, "Start the ledger")
    git!(dir, ["checkout", "-q", "-b", "topic"])
    head = commit!(dir, "Lend a book for longer")
    event = Path.join(tmp_dir, "event.json")

    File.write!(
      event,
      JSON.encode!(%{
        "pull_request" => %{"number" => 42, "title" => "Lend", "head" => %{"sha" => head}}
      })
    )

    env = job(base, %{"GITHUB_EVENT_NAME" => "pull_request_target", "GITHUB_EVENT_PATH" => event})
    stated = Checkout.stated(env, dir, @now)
    assert stated["title"] == "Start the ledger"
    assert stated["pull_request"] == %{"number" => 42, "head" => head, "title" => "Lend"}
  end

  test "leaves out a time later than its clock, and stops the commits before one with no title",
       %{tmp_dir: tmp_dir} do
    dir = repository!(tmp_dir)
    first = commit!(dir, "Start the ledger")
    commit!(dir, "\u200F")
    second = commit!(dir, "Count the books")

    sha =
      commit!(dir, "Lend a book for longer", [{"GIT_COMMITTER_DATE", "2026-10-27T12:00:01Z"}])

    stated = Checkout.stated(job(sha), dir, @now)
    refute Map.has_key?(stated, "committed_at")
    assert stated["commits"] == [%{"commit" => second, "title" => "Count the books"}]
    refute first in Enum.map(stated["commits"], & &1["commit"])
  end

  test "states what it can read and nothing else, from a checkout without the commit or git",
       %{tmp_dir: tmp_dir} do
    dir = repository!(tmp_dir)
    commit!(dir, "Start the ledger")
    absent = String.duplicate("ab", 20)

    assert Checkout.stated(job(absent), dir, @now) == %{}
    assert Checkout.stated(job(absent), Path.join(tmp_dir, "none"), @now) == %{}
    assert Checkout.stated(job("HEAD"), dir, @now) == %{}

    event = Path.join(tmp_dir, "event.json")

    File.write!(
      event,
      ~s({"pull_request": {"number": 7, "title": "Fix it", "head": {"sha": "x"}}})
    )

    env = job(absent, %{"GITHUB_EVENT_NAME" => "pull_request", "GITHUB_EVENT_PATH" => event})

    assert Checkout.stated(env, dir, @now) == %{
             "pull_request" => %{"number" => 7, "title" => "Fix it"}
           }
  end
end

defmodule ReleaseWorkflowTest do
  # T-34, as eh-os D-197 does for its CI App: the release App's key can tag and push release
  # branches, and the environment `release-app` that holds it admits any workflow on `main`. So the
  # key stays with `ehos-release.yml` only while no other workflow names it, and is safe there only
  # while the jobs that name the environment run nothing but a checkout, git, gh, jq and GitHub's
  # token action, on inputs that reach them through `env:` alone, and check what they act on
  # before they mint the token. This holds against a mistake, not against a change to this test.
  use ExUnit.Case, async: true

  @workflows Path.expand("../../../.github/workflows", __DIR__)
  @release Path.join(@workflows, "ehos-release.yml")
  @pins Path.join(@workflows, "ehos-pins.yml")

  # Step 3 adds release-pull-request.yml, the one caller that passes the key.
  @naming_the_key ["ehos-release.yml"]

  # What the jobs that hold the key may use, and what their `run:` may not: a program that runs
  # other code, a shell started again, or a file of the checkout run as a program.
  @keyed_actions ~w(actions/checkout actions/download-artifact actions/create-github-app-token)
  @not_in_keyed_runs [
    ~r/\b(mix|changie|mise|elixir|erl|iex|node|npm|npx|python3?|pip|ruby|perl|curl|wget|eval|source|sudo|bash|sh|zsh|env|xargs|exec|docker|make|go|cargo|deno|bun)\b/,
    # A file run by its path, quoted or from a variable, or with the dot builtin.
    ~r/(^|[\s;|&("])\.{0,2}\/(?!dev\/null(?![\w.\/]))[\w.-]/m,
    ~r/(^|[;|&(]|\bthen|\bdo)\s*"?\$\{?\w+\}?\//m,
    ~r/^\s*[\w.-]+\/[\w.\/-]+/m,
    # (`. as $x` is jq's, not the shell's.)
    ~r/(^|[;|&(])\s*\.\s+(?!as\b)\S/m,
    # git and gh have ways of their own to run a program.
    ~r/\bgh\s+(extension|ext|alias)\b|\bgit\s+(config\b|-c\s+(alias|core)\.)/
  ]

  test "no workflow but ehos-release.yml names the release App's key or the environment release-app" do
    naming =
      for path <- Path.wildcard(Path.join(@workflows, "*.{yml,yaml}")),
          File.read!(path) =~ ~r/RELEASE_APP_|release-app/i,
          do: Path.basename(path)

    assert naming == @naming_the_key
  end

  test "no workflow passes every secret, which would pass the key unnamed" do
    for path <- Path.wildcard(Path.join(@workflows, "*.{yml,yaml}")) do
      # GitHub reads an expression's functions in any case.
      refute File.read!(path) =~ ~r/secrets:\s*["']?inherit|tojson\(\s*secrets\s*\)/i,
             Path.basename(path)
    end
  end

  test "the key's secrets are read by the token steps alone" do
    # `secrets.NAME` or `secrets['NAME']`.
    secret = ~r/secrets\s*[.\[]/

    for {name, job} <- jobs(@release), step <- job["steps"] do
      named = inspect(step) =~ secret
      token = action(step["uses"]) == "actions/create-github-app-token"
      assert named == token and (not named or inspect(step["with"]) =~ secret), "#{name}"
    end

    for {name, job} <- jobs(@release) do
      refute inspect(Map.delete(job, "steps")) =~ secret, "#{name} names a secret"
    end

    refute inspect(Map.delete(workflow(@release), "jobs")) |> String.replace("secrets:", "") =~
             secret
  end

  test "the jobs that name release-app are open and tag, which use a checkout, the artifact and " <>
         "the token action, and run no program that runs other code" do
    keyed = for {name, job} <- jobs(@release), environment(job) != nil, do: name
    assert Enum.map(keyed, &environment(jobs(@release)[&1])) |> Enum.uniq() == ["release-app"]
    assert Enum.sort(keyed) == ["open", "tag"]

    for name <- keyed, step <- jobs(@release)[name]["steps"] do
      if step["uses"],
        do: assert(action(step["uses"]) in @keyed_actions, "#{name}: #{step["uses"]}")

      if step["run"] do
        for pattern <- @not_in_keyed_runs,
            do:
              refute(
                step["run"] =~ pattern,
                "#{name} runs #{inspect(Regex.run(pattern, step["run"]))}"
              )
      end
    end
  end

  test "the open job checks the patch, and the tag job checks the pull request, before the token" do
    assert before_token("open") =~ "git apply --numstat"
    assert before_token("open") =~ "git apply --summary"

    tag = before_token("tag")

    for check <- ["merge_commit_sha", "merged_by", "collaborators/", "/files", "compare/main..."] do
      assert tag =~ check, "the tag job does not check #{check} before it mints the token"
    end
  end

  test "each job mints the App's token for the calling repository alone, with what it needs" do
    tokens =
      for {name, job} <- jobs(@release),
          step <- job["steps"],
          action(step["uses"]) == "actions/create-github-app-token",
          into: %{},
          do: {name, step["with"]}

    common = %{
      "client-id" => "${{ secrets.RELEASE_APP_CLIENT_ID }}",
      "private-key" => "${{ secrets.RELEASE_APP_PRIVATE_KEY }}",
      "repositories" => "${{ github.event.repository.name }}",
      "permission-contents" => "write"
    }

    assert tokens == %{
             "open" => Map.put(common, "permission-pull-requests", "write"),
             "tag" => common
           }
  end

  test "no job's own token may write but the refusal's, which opens an issue" do
    for {name, job} <- Map.to_list(jobs(@release)) ++ Map.to_list(jobs(@pins)) do
      writes = for {scope, "write"} <- Map.get(job, "permissions", %{}), do: scope
      expected = if name == "refuse", do: ["issues"], else: []
      assert writes == expected, "#{name} asks its token for #{inspect(writes)}"
    end

    assert workflow(@release)["permissions"] == %{}
    assert workflow(@pins)["permissions"] == %{}
  end

  test "every input reaches a step through env:, never through ${{ }} in a run" do
    for path <- [@release, @pins], {name, job} <- jobs(path), step <- job["steps"], step["run"] do
      refute step["run"] =~ ~r/\$\{\{/, "#{Path.basename(path)}: #{name} has ${{ }} in a run"
    end
  end

  test "every action is pinned by a commit, with its tag in a comment" do
    for path <- [@release, @pins],
        line <- String.split(File.read!(path), "\n"),
        line =~ ~r/^\s*(-\s+)?uses:/ do
      assert line =~ ~r/uses: [\w.-]+\/[\w.\/-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+$/,
             "#{Path.basename(path)}: #{String.trim(line)}"
    end
  end

  test "every checkout leaves no credentials behind" do
    for path <- [@release, @pins],
        {name, job} <- jobs(path),
        step <- job["steps"],
        action(step["uses"]) == "actions/checkout" do
      assert step["with"]["persist-credentials"] == false, "#{Path.basename(path)}: #{name}"
    end
  end

  test "the refusal's issue follows the tag job, and opens when that job fails too" do
    refuse = jobs(@release)["refuse"]
    assert refuse["needs"] == "tag"
    assert refuse["if"] =~ "!cancelled()"
    assert refuse["if"] =~ "needs.tag.result == 'failure'"
  end

  test "the check of pins names no secret and no environment" do
    refute File.read!(@pins) =~ ~r/secrets\.|environment:/
  end

  defp before_token(job) do
    jobs(@release)[job]["steps"]
    |> Enum.take_while(&(action(&1["uses"]) != "actions/create-github-app-token"))
    |> Enum.map_join("\n", &(&1["run"] || ""))
  end

  # GitHub takes an environment as a name, or as a map with one.
  defp environment(%{"environment" => %{"name" => name}}), do: name
  defp environment(%{"environment" => name}), do: name
  defp environment(_job), do: nil

  defp action(nil), do: nil
  defp action(uses), do: uses |> String.split("@") |> hd()

  defp jobs(path), do: workflow(path)["jobs"]

  defp workflow(path), do: YamlElixir.read_from_file!(path)
end

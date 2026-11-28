defmodule EhosApp.EhosContractReleaseTest do
  # T-11: the installer pins ehos_contract's release by the commit its tag names, not by the tag,
  # so this holds the commit to the tag, as it does for each plugin's commit. CI runs it
  # (`check (ehos_app)` in `.github/workflows/ci.yml`), and `mix check` leaves it out
  # (`test_helper.exs`), since it needs the network. Locally: `mix test --only ehos_contract`.
  # The test helper keeps the caller's git out of every test; this one gives the caller's
  # configuration (a proxy, a credential helper) back to its own `git ls-remote`.
  use ExUnit.Case, async: true

  @moduletag :ehos_contract

  @repository "https://github.com/EmpoweredHouse/ehos_contract.git"

  test "pins the commit ehos_contract's release tag names" do
    %{tag: tag, commit: commit} = Mix.Tasks.EhosApp.Install.ehos_contract_release()

    {output, status} =
      System.cmd("git", ["ls-remote", @repository, "refs/tags/#{tag}", "refs/tags/#{tag}^{}"],
        stderr_to_stdout: true,
        env: caller_git()
      )

    # A failure reaches CI's log: the token git was given in the URL is taken out.
    assert status == 0,
           "git ls-remote #{@repository} failed:\n" <>
             String.replace(output, ~r/x-access-token:[^@\s]+@/, "x-access-token:[token]@")

    refs =
      for line <- String.split(output, "\n", trim: true),
          [sha, ref] <- [String.split(line)],
          into: %{},
          do: {ref, sha}

    # An annotated tag lists its own object and, under `^{}`, the commit it names.
    tagged = refs["refs/tags/#{tag}^{}"] || refs["refs/tags/#{tag}"]
    assert tagged, "ehos_contract has no tag #{tag}"
    assert tagged == commit, "#{tag} names #{tagged}, and the installer pins #{commit}"
  end

  # Settings name the plugin's tag, never a commit (ehos-tools#134), and the tag rulesets keep it
  # where it is; this holds it to the commit the installer was written against, so a moved tag fails
  # CI.
  test "pins ehos_contract's plugin at a tag that names the commit the installer expects" do
    %{ref: ref, commit: commit} =
      Enum.find(Mix.Tasks.EhosApp.Install.plugins(), &(&1.name == "ehos-contract"))

    {output, status} =
      System.cmd("git", ["ls-remote", @repository, "refs/tags/#{ref}", "refs/tags/#{ref}^{}"],
        stderr_to_stdout: true,
        env: caller_git()
      )

    assert status == 0,
           "git ls-remote #{@repository} failed:\n" <>
             String.replace(output, ~r/x-access-token:[^@\s]+@/, "x-access-token:[token]@")

    refs =
      for line <- String.split(output, "\n", trim: true),
          [sha, name] <- [String.split(line)],
          into: %{},
          do: {name, sha}

    tagged = refs["refs/tags/#{ref}^{}"] || refs["refs/tags/#{ref}"]
    assert tagged, "ehos_contract has no tag #{ref}"
    assert tagged == commit, "#{ref} names #{tagged}, and the installer expects #{commit}"
  end

  # Codex installs the ehos-app plugin by the commit (`.codex/config.toml`), Claude Code by its
  # tag: this holds the commit to the tag, so both tools read the same marketplace.
  test "pins Codex's ehos-app plugin at the commit its release tag names" do
    %{ref: ref, commit: commit} =
      Enum.find(Mix.Tasks.EhosApp.Install.plugins(), &(&1.name == "ehos-app"))

    repository = "https://github.com/EmpoweredHouse/ehos-tools.git"

    {output, status} =
      System.cmd("git", ["ls-remote", repository, "refs/tags/#{ref}", "refs/tags/#{ref}^{}"],
        stderr_to_stdout: true,
        env: caller_git()
      )

    assert status == 0,
           "git ls-remote #{repository} failed:\n" <>
             String.replace(output, ~r/x-access-token:[^@\s]+@/, "x-access-token:[token]@")

    refs =
      for line <- String.split(output, "\n", trim: true),
          [sha, name] <- [String.split(line)],
          into: %{},
          do: {name, sha}

    tagged = refs["refs/tags/#{ref}^{}"] || refs["refs/tags/#{ref}"]
    assert tagged, "ehos-tools has no tag #{ref}"
    assert tagged == commit, "#{ref} names #{tagged}, and Codex is pinned at #{commit}"
  end

  defp caller_git, do: :persistent_term.get(:ehos_app_caller_git)
end

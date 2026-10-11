defmodule EhosApp.EhOsContractReleaseTest do
  # T-11: the installer pins eh-os-contract's release by the commit its tag names, not by the tag,
  # so this holds the commit to the tag. eh-os-contract is private: CI runs this with a token that
  # may read it (`check (ehos_app)` in `.github/workflows/ci.yml`), and `mix check` leaves it out
  # (`test_helper.exs`), since it needs the network and that token. Locally:
  # `mix test --only eh_os_contract`, with git able to read eh-os-contract.
  use ExUnit.Case, async: true

  @moduletag :eh_os_contract

  @repository "https://github.com/EmpoweredHouse/eh-os-contract.git"

  test "pins the commit eh-os-contract's release tag names" do
    %{tag: tag, commit: commit} = Mix.Tasks.EhosApp.Install.eh_os_contract_release()

    {output, status} =
      System.cmd("git", ["ls-remote", @repository, "refs/tags/#{tag}", "refs/tags/#{tag}^{}"],
        stderr_to_stdout: true
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
    assert tagged, "eh-os-contract has no tag #{tag}"
    assert tagged == commit, "#{tag} names #{tagged}, and the installer pins #{commit}"
  end
end

defmodule Mix.Tasks.EhosApp.InstallTest.FormerName do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # ehos_contract's release v0.15.1, under the library's name before 0.16.0, which 0.37.1 pinned.
  @former_ref "b4e5a82e17e19588bb6b312e5b154c24254632ea"
  @release_ref "aa9f396472f1208c5d6009c1818d135339a9c694"

  # The names 0.37 wrote, from the names this version writes.
  @former [
    {"EmpoweredHouse/ehos_contract", "EmpoweredHouse/eh-os-contract"},
    {"EhosContract", "EhOsContract"},
    {"ehos_contract", "eh_os_contract"},
    {"EHOS_CONTRACT", "EH_OS_CONTRACT"},
    {@release_ref, @former_ref},
    {"version: 7", "version: 6"},
    {"Auth.Migrations.up(version: 4)", "Auth.Migrations.up(version: 3)"},
    {"~> 0.18.0", "~> 0.15.0"},
    {"~> 0.19.0", "~> 0.16.0"}
  ]

  @old_names ~r/eh_os_contract|EhOsContract|eh-os-contract|EH_OS_CONTRACT/

  describe "a project an earlier version generated under the library's former name" do
    test "moves to ehos_contract: the pins, the code, the migrations, the lock and the plugin" do
      igniter = former_project() |> install_on(["--yes"])

      assert dep(igniter, :ehos_contract) ==
               {:ehos_contract, "~> 0.18.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract",
                ref: @release_ref,
                override: true}

      assert dep(igniter, :ehos_contract_auth) ==
               {:ehos_contract_auth, "~> 0.19.0",
                github: "EmpoweredHouse/ehos_contract",
                sparse: "packages/ehos_contract_auth",
                ref: @release_ref}

      assert dep(igniter, :eh_os_contract) == nil
      assert dep(igniter, :eh_os_contract_auth) == nil

      for source <- igniter.rewrite,
          path = Rewrite.Source.get(source, :path),
          path =~ ~r{\A(mix\.exs|config/|lib/|test/|priv/repo/)} do
        refute Rewrite.Source.get(source, :content) =~ @old_names, path
      end

      review = content(igniter, ".github/workflows/review.yml")
      refute review =~ @old_names
      assert review =~ "repositories: ehos_contract,ehos-tools"

      assert precommit(igniter) =~ "ehos_contract.check"
      assert content(igniter, "mix.exs") =~ ":ehos_contract]"

      # The migrations keep their files, so no second one makes the tables, which move to the
      # release's versions.
      assert migrations(igniter, "add_ehos_contract") == []
      assert migrations(igniter, "add_ehos_contract_auth") == []
      assert [_engine] = migrations(igniter, "upgrade_ehos_contract_to_v7")
      assert [_verifier] = migrations(igniter, "upgrade_ehos_contract_auth_to_v4")

      settings = igniter |> content(".claude/settings.json") |> JSON.decode!()
      assert settings["enabledPlugins"]["ehos-contract@ehos-contract"] == true
      refute Map.has_key?(settings["enabledPlugins"], "eh-os-contract@eh-os-contract")
      refute Map.has_key?(settings["extraKnownMarketplaces"], "eh-os-contract")

      assert settings["extraKnownMarketplaces"]["ehos-contract"]["source"] == %{
               "source" => "github",
               "repo" => "EmpoweredHouse/ehos_contract",
               "ref" => plugin("ehos-contract").ref
             }

      assert [renamed] = notices_about(igniter, "The contract library is ehos_contract")
      assert renamed =~ "set EHOS_CONTRACT_KEK to the same value"
    end

    test "renames the schema lock" do
      igniter =
        former_project()
        |> Igniter.create_new_file("eh_os_contract.lock", "%{}\n")
        |> install_on(["--yes"])

      assert igniter.moves == %{"eh_os_contract.lock" => "ehos_contract.lock"}
      assert precommit(igniter) =~ "ehos_contract.schema --check"
      assert [_moved] = notices_about(igniter, "eh_os_contract.lock is ehos_contract.lock")
    end

    test "renames the schema lock and the review workflow of a project moved to the new name by hand" do
      installed = installed()
      review = content(installed, ".github/workflows/review.yml")

      igniter =
        installed
        |> Igniter.create_new_file("eh_os_contract.lock", "%{}\n")
        |> with_file(".github/workflows/review.yml", former_review(review))
        |> install_on(["--yes"])

      assert igniter.moves == %{"eh_os_contract.lock" => "ehos_contract.lock"}
      assert precommit(igniter) =~ "ehos_contract.schema --check"
      assert [_moved] = notices_about(igniter, "eh_os_contract.lock is ehos_contract.lock")
      assert content(igniter, ".github/workflows/review.yml") == review
    end

    test "says nothing of the schema lock where it moved none" do
      igniter = former_project() |> install_on(["--yes"])

      assert igniter.moves == %{}
      refute Enum.any?(igniter.notices, &(&1 =~ "eh_os_contract.lock"))
    end

    test "is idempotent: a second run changes nothing" do
      former_project()
      |> install_again(["--yes"])
      |> Igniter.compose_task("ehos_app.install", ["--yes"])
      |> assert_unchanged()
    end

    test "changes nothing where the library is on a commit of the developer's own" do
      igniter =
        former_project()
        |> edit_file(
          "mix.exs",
          &String.replace(&1, @former_ref, "ffffffffffffffffffffffffffffffffffffffff")
        )
        |> install_on(["--yes"])

      assert [issue] = igniter.issues
      assert issue =~ "eh_os_contract and eh_os_contract_auth in mix.exs"
    end
  end

  # A project as 0.37.1 left it: this version's, with every name and version it writes as 0.37.1
  # wrote them, and the migrations under their files' names then.
  defp former_project do
    igniter = installed()

    igniter =
      Enum.reduce(igniter.rewrite, igniter, fn source, igniter ->
        path = Rewrite.Source.get(source, :path)
        content = Rewrite.Source.get(source, :content)
        former = former(content)

        if former == content,
          do: igniter,
          else: replace_file(igniter, path, former)
      end)

    igniter =
      igniter.rewrite
      |> Enum.map(&Rewrite.Source.get(&1, :path))
      |> Enum.filter(&(&1 =~ ~r|\Apriv/repo/migrations/\d{14}_add_ehos_contract(_auth)?\.exs\z|))
      |> Enum.reduce(igniter, fn path, igniter ->
        igniter
        |> Igniter.rm(path)
        |> Igniter.create_new_file(
          String.replace(path, "ehos_contract", "eh_os_contract"),
          content(igniter, path)
        )
      end)

    settings = content(igniter, ".claude/settings.json")

    settings =
      settings
      |> String.replace(~s("ehos-contract"), ~s("eh-os-contract"))
      |> String.replace("ehos-contract@ehos-contract", "eh-os-contract@eh-os-contract")
      |> String.replace("ehos-contract-plugin-v0.16.1", "eh-os-contract-plugin-v0.14.3")
      |> String.replace("EmpoweredHouse/ehos_contract", "EmpoweredHouse/eh-os-contract")

    # The review workflow as 0.37.1 wrote it, which names the repository alone.
    review = igniter |> content(".github/workflows/review.yml") |> former_review()

    igniter
    |> with_file(".claude/settings.json", settings)
    |> with_file(".github/workflows/review.yml", review)
  end

  defp former_review(review) do
    review
    |> former()
    |> String.replace("repositories: eh_os_contract,", "repositories: eh-os-contract,")
    |> String.replace("App that reads eh_os_contract and", "App that reads eh-os-contract and")
  end

  defp former(content) do
    Enum.reduce(@former, content, fn {new, old}, content -> String.replace(content, new, old) end)
  end

  defp migrations(igniter, name) do
    igniter.rewrite
    |> Enum.map(&Rewrite.Source.get(&1, :path))
    |> Enum.filter(&(&1 =~ ~r|\Apriv/repo/migrations/\d{14}_#{name}\.exs\z|))
  end
end

defmodule Ehosctl.ProjectTest do
  # eh-os D-91 (ehos-tools#97): what an application uses is read from its mix.lock, never by
  # evaluating it, and from the documents it gives EHOS.
  use Ehosctl.Case, async: true

  alias Ehosctl.Project

  doctest Project

  @moduletag :tmp_dir

  @contract "743e91d755bf30b9d4fa0ef0efb7d8f45a147b21"
  @app "e529ad4888c19be0fde298dc6f64de1dcbdf3de0"

  # As a generated application's lock has them (ehos-ledger's, 11 October 2026), and a Hex entry.
  @lock """
  %{
    "bandit": {:hex, :bandit, "1.8.0", "c2e93d7e3c5c794272fa4623124f827c6f24b643acc822be64c826f9447d92fb", [:mix], [{:hpax, "~> 1.0", [hex: :hpax, repo: "hexpm", optional: false]}], "hexpm", "8458ff4eed20ff2a2ea69d4854883a077c33ea42b51f6811b044ceee0fa15422"},
    "ehos_contract": {:git, "https://github.com/EmpoweredHouse/ehos_contract.git", "#{@contract}", [sparse: "packages/ehos_contract", branch: "main"]},
    "ehos_contract_auth": {:git, "https://github.com/EmpoweredHouse/ehos_contract.git", "#{@contract}", [sparse: "packages/ehos_contract_auth", branch: "main"]},
    "ehos_app": {:git, "https://github.com/EmpoweredHouse/ehos-tools.git", "#{@app}", [sparse: "packages/ehos_app", tag: "ehos_app-v0.2.0"]},
    "ehos_design": {:hex, :ehos_design, "0.3.0", "c2e93d7e3c5c794272fa4623124f827c6f24b643acc822be64c826f9447d92fb", [:mix], [], "hexpm", "8458ff4eed20ff2a2ea69d4854883a077c33ea42b51f6811b044ceee0fa15422"},
  }
  """

  test "reads each component's commit, branch, tag or version, and nothing else",
       %{tmp_dir: dir} do
    application(dir, %{
      "mix.exs" => "",
      "mix.lock" => @lock,
      "ehos.yaml" => "# What it needs\nschema: ehos.yaml/v1\n",
      "_build/ehos.manifest.json" => ~s({"schema": "ehos.manifest/v2"})
    })

    assert Project.read(dir) ==
             {:ok, %{deps: lock_deps(), ehos_yaml: "ehos.yaml/v1", manifest: "ehos.manifest/v2"}}
  end

  test "reads the contract library under its name before 0.16.0 as ehos_contract",
       %{tmp_dir: dir} do
    application(dir, %{
      "mix.exs" => "",
      "ehos.yaml" => "schema: ehos.yaml/v2\n",
      "mix.lock" => """
      %{"eh_os_contract": {:git, "https://github.com/EmpoweredHouse/eh-os-contract.git", "#{@contract}", [sparse: "packages/eh_os_contract", branch: "main"]},
        "eh_os_contract_auth": {:git, "https://github.com/EmpoweredHouse/eh-os-contract.git", "#{@contract}", [sparse: "packages/eh_os_contract_auth", branch: "main"]}}
      """
    })

    assert {:ok, %{deps: deps}} = Project.read(dir)
    assert deps |> Map.keys() |> Enum.sort() == ["ehos_contract", "ehos_contract_auth"]
    assert deps["ehos_contract"].url == "https://github.com/EmpoweredHouse/eh-os-contract.git"
  end

  test "reads the new name where the lock still has the old one beside it", %{tmp_dir: dir} do
    old = String.duplicate("b", 40)

    entries =
      for name <- ~w(eh_os_contract ehos_contract eh_os_contract_auth ehos_contract_auth) do
        commit = if String.starts_with?(name, "eh_os"), do: old, else: @contract

        ~s("#{name}": {:git, "https://github.com/EmpoweredHouse/ehos_contract.git", "#{commit}", []})
      end

    application(dir, %{
      "mix.exs" => "",
      "ehos.yaml" => "schema: ehos.yaml/v2\n",
      "mix.lock" => "%{" <> Enum.join(entries, ",\n") <> "}\n"
    })

    assert {:ok, %{deps: deps}} = Project.read(dir)
    assert deps["ehos_contract"].commit == @contract
    assert deps["ehos_contract_auth"].commit == @contract
  end

  test "a git entry whose options are not a keyword list is read without them",
       %{tmp_dir: dir} do
    application(dir, %{
      "mix.exs" => "",
      "ehos.yaml" => "schema: ehos.yaml/v2\n",
      "mix.lock" => """
      %{"ehos_app": {:git, "https://github.com/EmpoweredHouse/ehos-tools.git", "#{@app}", [:sparse, "x", {1, 2, 3}, tag: "ehos_app-v0.2.0"]}}
      """
    })

    assert Project.read(dir) ==
             {:ok,
              %{
                deps: %{
                  "ehos_app" => %{
                    scm: :git,
                    commit: @app,
                    branch: nil,
                    tag: "ehos_app-v0.2.0",
                    ref: nil,
                    url: "https://github.com/EmpoweredHouse/ehos-tools.git"
                  }
                },
                ehos_yaml: "ehos.yaml/v2",
                manifest: nil
              }}
  end

  test "a Mix project with ehos_app and no ehos.yaml is an application whose ehos.yaml is missing",
       %{tmp_dir: dir} do
    application(dir, %{"mix.exs" => "", "mix.lock" => @lock})

    assert Project.read(dir) == {:ok, %{deps: lock_deps(), ehos_yaml: :missing, manifest: nil}}
  end

  test "without ehos.yaml or a manifest, their schemas are unknown", %{tmp_dir: dir} do
    application(dir, %{
      "mix.exs" => "",
      "mix.lock" => "%{}\n",
      "ehos.yaml" => "schema: {as: ehos.yaml/v2}\n",
      "_build/ehos.manifest.json" => "not json"
    })

    assert Project.read(dir) == {:ok, %{deps: %{}, ehos_yaml: nil, manifest: nil}}
  end

  test "a Mix project that is no EHOS application's, without ehos.yaml or a component, is none",
       %{tmp_dir: dir} do
    application(dir, %{"mix.exs" => "", "mix.lock" => ~s(%{"jason": {:hex, :jason, "1.4.4"}}\n)})
    assert Project.read(dir) == :none

    File.write!(Path.join(dir, "ehos.yaml"), "schema: ehos.yaml/v2\n")
    assert Project.read(dir) == {:ok, %{deps: %{}, ehos_yaml: "ehos.yaml/v2", manifest: nil}}
  end

  # eh-os is a Mix project that depends on ehos_design, and is no application (ehos-tools#195).
  test "a Mix project with ehos_design, or ehos_contract, alone and no ehos.yaml is none",
       %{tmp_dir: dir} do
    design =
      ~s("ehos_design": {:git, "https://github.com/EmpoweredHouse/ehos-tools.git", "#{@app}", [sparse: "packages/ehos_design", ref: "#{@app}"]})

    contract =
      ~s("ehos_contract": {:git, "https://github.com/EmpoweredHouse/ehos_contract.git", "#{@contract}", [sparse: "packages/ehos_contract", branch: "main"]})

    application(dir, %{"mix.exs" => "", "mix.lock" => "%{#{design}, #{contract}}\n"})
    assert Project.read(dir) == :none
  end

  test "a directory without mix.exs and mix.lock is no application's", %{tmp_dir: dir} do
    assert Project.read(dir) == :none
    application(dir, %{"mix.exs" => ""})
    assert Project.read(dir) == :none
  end

  test "a lock that is not terms is refused without being run, and creates no atom",
       %{tmp_dir: dir} do
    marker = "ehosctl_never_an_atom_#{System.unique_integer([:positive])}"

    owned = Path.join(dir, "owned")

    for lock <- [
          ~s|%{"x" => File.write!("#{owned}", "")}|,
          ~s|%{"x" => {:git, "u", "c", [#{marker}: 1]}} ++ [1]|,
          "not elixir {"
        ] do
      application(dir, %{"mix.exs" => "", "mix.lock" => lock})

      assert Project.read(dir) ==
               {:error, "mix.lock holds something other than Elixir terms."}
    end

    refute File.exists?(owned)
    assert_raise ArgumentError, fn -> String.to_existing_atom(marker) end
  end

  test "a lock that is a link is not followed", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "elsewhere"), @lock)
    application(dir, %{"mix.exs" => ""})
    File.ln_s!(Path.join(dir, "elsewhere"), Path.join(dir, "mix.lock"))
    assert Project.read(dir) == :none
  end

  defp application(dir, files) do
    for {name, contents} <- files do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    dir
  end

  # What `@lock` gives of the components: the Hex entry that is not one is left out.
  defp lock_deps do
    %{
      "ehos_contract" => %{
        scm: :git,
        commit: @contract,
        branch: "main",
        tag: nil,
        ref: nil,
        url: "https://github.com/EmpoweredHouse/ehos_contract.git"
      },
      "ehos_contract_auth" => %{
        scm: :git,
        commit: @contract,
        branch: "main",
        tag: nil,
        ref: nil,
        url: "https://github.com/EmpoweredHouse/ehos_contract.git"
      },
      "ehos_app" => %{
        scm: :git,
        commit: @app,
        branch: nil,
        tag: "ehos_app-v0.2.0",
        ref: nil,
        url: "https://github.com/EmpoweredHouse/ehos-tools.git"
      },
      "ehos_design" => %{scm: :hex, version: "0.3.0"}
    }
  end
end

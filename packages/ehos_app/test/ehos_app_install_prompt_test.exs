defmodule Mix.Tasks.EhosApp.InstallPromptTest do
  # Answers the installer's question through `Mix.Shell.Process`, which is global: so this
  # module runs alone, after the asynchronous ones.
  use ExUnit.Case, async: false

  import Igniter.Test

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "changes nothing when moving eh-os-contract to its release is declined" do
    send(self(), {:mix_shell_input, :prompt, "n"})

    igniter =
      phx_test_project()
      |> Igniter.Project.Deps.add_dep(
        {:eh_os_contract_auth, "~> 0.1.0-dev",
         github: "EmpoweredHouse/eh-os-contract",
         sparse: "packages/eh_os_contract_auth",
         ref: "50eb7711c3235325834535d7d24239855c0e63d8"},
        yes?: true
      )
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])

    assert [issue] = igniter.issues
    assert issue =~ "eh_os_contract_auth was not moved"
  end

  test "asks before moving a project that follows main, and changes nothing when declined" do
    send(self(), {:mix_shell_input, :prompt, "n"})

    igniter =
      phx_test_project()
      |> Igniter.Project.Deps.add_dep(
        {:eh_os_contract_auth, "~> 0.1.0-dev",
         github: "EmpoweredHouse/eh-os-contract",
         sparse: "packages/eh_os_contract_auth",
         branch: "main"},
        yes?: true
      )
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])

    assert_received {:mix_shell, :prompt, [_question]}
    assert [issue] = igniter.issues
    assert issue =~ "eh_os_contract_auth was not moved to eh-os-contract's release v0.9.1"
  end
end

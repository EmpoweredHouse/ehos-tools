defmodule Mix.Tasks.EhosApp.InstallPromptTest do
  # The installer's question is answered on this test's own standard input, through
  # `capture_io/2`, which Mix's shell reads by the process's group leader.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Igniter.Test

  @declined """
  eh_os_contract_auth was not moved to eh-os-contract's release v0.14.1,
  which this ehos_app is written for, so nothing was changed. Run the installer again and
  accept the move, or pass --yes.
  """

  test "asks before moving a project that follows main, and changes nothing when declined" do
    {igniter, output} = declined(branch: "main")

    assert output == question(~s(branch: "main"))
    assert igniter.issues == [@declined]
  end

  test "changes nothing when moving eh-os-contract to its release is declined" do
    {igniter, output} = declined(ref: "50eb7711c3235325834535d7d24239855c0e63d8")

    assert output == question(~s(ref: "50eb7711c3235325834535d7d24239855c0e63d8"))
    assert igniter.issues == [@declined]
  end

  test "leaves ehos_design on an earlier version's commit when moving it is declined" do
    {igniter, _output} =
      with_io("n\n", fn ->
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_design, "~> 0.2.0",
           github: "EmpoweredHouse/ehos-tools",
           sparse: "packages/ehos_design",
           ref: "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6"},
          yes?: true
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
      end)

    assert {:ok, ~s|{:ehos_design, "~> 0.2.0",| <> _} =
             Igniter.Project.Deps.get_dep(igniter, :ehos_design)

    assert Enum.filter(igniter.warnings, &(&1 =~ "ehos_design was not moved")) == [
             """
             ehos_design was not moved from the commit an earlier ehos_app pinned to its release
             0.6.0, which this ehos_app is written for. Run the installer again and
             accept the move, or pass --yes.
             """
           ]
  end

  # The project's `eh_os_contract_auth` on `source`, a commit or branch of eh-os-contract an
  # earlier version pinned, the installer run on it, and its question answered no.
  defp declined(source) do
    with_io("n\n", fn ->
      phx_test_project()
      |> Igniter.Project.Deps.add_dep(
        {:eh_os_contract_auth, "~> 0.1.0-dev",
         [github: "EmpoweredHouse/eh-os-contract", sparse: "packages/eh_os_contract_auth"] ++
           source},
        yes?: true
      )
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
    end)
  end

  # Igniter's own question, which names the dependency the installer wants and the one found.
  defp question(found) do
    """
    Dependency eh_os_contract_auth is already in mix.exs. Should we replace it?

    Desired: `{:eh_os_contract_auth, "~> 0.13.0", [github: "EmpoweredHouse/eh-os-contract", \
    sparse: "packages/eh_os_contract_auth", ref: "7ca579a0f6efaad6f0aea2af2dfd2fae7f92557f"]}`
    Found: `{:eh_os_contract_auth, "~> 0.1.0-dev", [github: "EmpoweredHouse/eh-os-contract", \
    sparse: "packages/eh_os_contract_auth", #{found}]}`
     [Y/n] \
    """
  end
end

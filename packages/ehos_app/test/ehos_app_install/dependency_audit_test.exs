defmodule Mix.Tasks.EhosApp.InstallTest.DependencyAudit do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # The precommit alias of a project the installer wrote, the audit first.
  @precommit """
        precommit: [
          &hex_audit/1,
          "compile --warnings-as-errors",
          "deps.unlock --unused",
          "format",
          "test",
          "eh_os_contract.check",
          "credo"
        ]
  """

  # `mix deps.get` prints a locked package's advisories and exits 0, so nothing failed on them
  # (ehos-tools#507). As a task of the alias, `hex.audit` is not found after `compile`, which prunes
  # Hex from the code path, and a finding sets the exit status without stopping later steps.
  describe "the dependency audit" do
    test "runs first in precommit, as a function of mix.exs" do
      igniter = installed()

      assert precommit(igniter) == @precommit

      assert lines(content(igniter, "mix.exs"), "  defp hex_audit(_args) do", "  end") == ~S"""
               defp hex_audit(_args) do
                 Application.load(:hex)
                 hex = to_string(Application.spec(:hex, :vsn) || "0.0.0")

                 if Version.match?(hex, "< 2.5.1") do
                   Mix.raise(
                     "mix hex.audit needs Hex 2.5.1 or later for advisories, and this is #{hex}: run mix local.hex --force"
                   )
                 end

                 case Mix.shell().cmd("mix hex.audit", env: [{"MIX_ENV", to_string(Mix.env())}]) do
                   0 ->
                     :ok

                   status ->
                     Mix.raise("mix hex.audit exited with #{status}: see TESTING.md, Dependency advisories",
                       exit_status: status
                     )
                 end
               end
             """
    end

    # The audit as a project might have written it: a task of the alias, first or after compile.
    # Each alias has neither `deps.unlock --unused` nor `format`, so the result has neither.
    test "replaces a plain hex.audit in precommit, wherever it is" do
      for alias <- [
            ~s(precommit: ["hex.audit", "compile --warnings-as-errors", "test"]),
            ~s(precommit: ["compile --warnings-as-errors", "hex.audit", "test"]),
            ~s(precommit: ["hex.audit", "compile --warnings-as-errors", "hex.audit", "test"]),
            ~s(precommit: [&hex_audit/1, "compile --warnings-as-errors", "hex.audit", "test"])
          ] do
        igniter = phx_test_project() |> with_precommit(alias) |> install_again()

        assert precommit(igniter) == """
                     precommit: [
                       &hex_audit/1,
                       "compile --warnings-as-errors",
                       "test",
                       "eh_os_contract.check",
                       "credo"
                     ]
               """,
               alias
      end
    end

    test "leaves a hex_audit/1 the project defined as it is, private or public" do
      for own <- [
            ~s|  defp hex_audit(_args), do: Mix.shell().cmd("mix hex.audit --policy")|,
            ~s|  def hex_audit(_args), do: Mix.shell().cmd("mix hex.audit --policy")|
          ] do
        igniter = phx_test_project() |> with_function(own) |> install_again()

        assert hex_audit_heads(content(igniter, "mix.exs")) == [own]
        assert precommit(igniter) == @precommit
      end
    end
  end

  defp with_precommit(igniter, alias) do
    Igniter.update_file(igniter, "mix.exs", fn source ->
      Rewrite.Source.update(source, :content, fn mix_exs ->
        String.replace(mix_exs, ~r/precommit: \[[^\]]*\]/, alias)
      end)
    end)
  end

  defp with_function(igniter, function) do
    Igniter.update_file(igniter, "mix.exs", fn source ->
      Rewrite.Source.update(source, :content, fn mix_exs ->
        String.replace(mix_exs, ~r/\nend\s*\z/, "\n" <> function <> "\nend\n")
      end)
    end)
  end

  # Every line of mix.exs that starts a definition of `hex_audit`, private or public.
  defp hex_audit_heads(mix_exs) do
    for line <- String.split(mix_exs, "\n"), line =~ ~r/^\s*defp? hex_audit\(/, do: line
  end
end

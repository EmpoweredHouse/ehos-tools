defmodule Mix.Tasks.EhosApp.InstallTest.DependencyAudit do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # `mix deps.get` prints a locked package's advisories and exits 0, so nothing failed on them
  # (ehos-tools#507). As a task of the alias, `hex.audit` is not found after `compile`, which prunes
  # Hex from the code path, and a finding sets the exit status without stopping later steps.
  describe "the dependency audit" do
    defp precommit(igniter) do
      {:ok, {:defmodule, _, [_, [{_, {:__block__, _, defs}}]]}} =
        igniter |> content("mix.exs") |> Code.string_to_quoted()

      [aliases] = for {:defp, _, [{:aliases, _, _}, [do: aliases]]} <- defs, do: aliases
      Keyword.fetch!(aliases, :precommit)
    end

    test "runs first in precommit, as a function of mix.exs" do
      igniter = installed()

      assert [{:&, _, [{:/, _, [{:hex_audit, _, _}, 1]}]}, "compile --warnings-as-errors" | _] =
               precommit(igniter)

      assert content(igniter, "mix.exs") =~ """
               defp hex_audit(_args) do
                 Application.load(:hex)
                 hex = to_string(Application.spec(:hex, :vsn) || "0.0.0")

                 if Version.match?(hex, "< 2.5.1") do
                   Mix.raise(
                     "mix hex.audit needs Hex 2.5.1 or later for advisories, and this is \#{hex}: run mix local.hex --force"
                   )
                 end

                 case Mix.shell().cmd("mix hex.audit", env: [{"MIX_ENV", to_string(Mix.env())}]) do
                   0 ->
                     :ok

                   status ->
                     Mix.raise("mix hex.audit exited with \#{status}: see TESTING.md, Dependency advisories",
                       exit_status: status
                     )
                 end
               end
             """
    end

    # The audit as a project might have written it: a task of the alias, first or after compile.
    test "replaces a plain hex.audit in precommit, wherever it is" do
      for alias <- [
            ~s(precommit: ["hex.audit", "compile --warnings-as-errors", "test"]),
            ~s(precommit: ["compile --warnings-as-errors", "hex.audit", "test"]),
            ~s(precommit: ["hex.audit", "compile --warnings-as-errors", "hex.audit", "test"]),
            ~s(precommit: [&hex_audit/1, "compile --warnings-as-errors", "hex.audit", "test"])
          ] do
        igniter =
          phx_test_project()
          |> Igniter.update_file("mix.exs", fn source ->
            Rewrite.Source.update(source, :content, fn mix_exs ->
              String.replace(mix_exs, ~r/precommit: \[[^\]]*\]/, alias)
            end)
          end)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])
          |> apply_igniter!()

        assert [{:&, _, _}, "compile --warnings-as-errors", "test" | _] = precommit(igniter)
        assert length(String.split(content(igniter, "mix.exs"), "hex_audit/1")) == 2
      end
    end

    test "leaves a hex_audit/1 the project defined as it is, private or public" do
      for own <- [
            "  defp hex_audit(_args), do: Mix.shell().cmd(\"mix hex.audit --policy\")\n",
            "  def hex_audit(_args), do: Mix.shell().cmd(\"mix hex.audit --policy\")\n"
          ] do
        leaves_own_hex_audit(own)
      end
    end

    defp leaves_own_hex_audit(own) do
      igniter =
        phx_test_project()
        |> Igniter.update_file("mix.exs", fn source ->
          Rewrite.Source.update(source, :content, fn mix_exs ->
            String.replace(mix_exs, ~r/\nend\s*\z/, "\n" <> own <> "end\n")
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      mix_exs = content(igniter, "mix.exs")

      assert mix_exs =~ own
      assert length(String.split(mix_exs, ~r/defp? hex_audit\(/)) == 2
      assert [{:&, _, _} | _] = precommit(igniter)
    end
  end
end

defmodule Mix.Tasks.EhosApp.InstallTest.DependencyAudit do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # The precommit alias of a project the installer wrote, the audit first.
  @precommit """
        precommit: [
          &hex_audit/1,
          "compile --warnings-as-errors",
          "deps.unlock --unused",
          "format",
          "test --warnings-as-errors",
          "eh_os_contract.check",
          "credo"
        ]
  """

  # The `hex_audit/1` 0.22.0 to 0.24.0 wrote into a project's mix.exs, which accepted Hex 2.5.1,
  # whose audit passes when it cannot fetch a package's registry entry (ehos-tools#537).
  @hex_audit_0_24 ~S"""
    # `mix hex.audit`, first in `precommit`, as a process of its own: run as a task of the alias,
    # it is not found after `compile`, and a finding does not stop the steps after it. Hex before
    # 2.5 audits retirements alone, and passes a lock with advisories; 2.5.0 cannot acknowledge
    # one. The environment is passed on, since `preferred_envs` sets the alias's but does not
    # export it.
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

                 if Version.match?(hex, "< 2.6.0") do
                   Mix.raise(
                     "mix hex.audit needs Hex 2.6.0 or later, and this is #{hex}: run mix local.hex --force"
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
    # Each alias has neither `deps.unlock --unused` nor `format`, so the result has neither. One
    # test per alias, so each runs the installer within ExUnit's timeout for a test.
    for {where, precommit_alias} <- [
          {"first", ~s(precommit: ["hex.audit", "compile --warnings-as-errors", "test"])},
          {"after compile", ~s(precommit: ["compile --warnings-as-errors", "hex.audit", "test"])},
          {"listed twice",
           ~s(precommit: ["hex.audit", "compile --warnings-as-errors", "hex.audit", "test"])},
          {"beside the function's own call",
           ~s(precommit: [&hex_audit/1, "compile --warnings-as-errors", "hex.audit", "test"])}
        ] do
      test "replaces a plain hex.audit in precommit, #{where}" do
        igniter =
          phx_test_project() |> with_precommit(unquote(precommit_alias)) |> install_again()

        assert precommit(igniter) == """
                     precommit: [
                       &hex_audit/1,
                       "compile --warnings-as-errors",
                       "test --warnings-as-errors",
                       "eh_os_contract.check",
                       "credo"
                     ]
               """
      end
    end

    # One test per visibility, so each runs the installer within ExUnit's timeout for a test.
    for {visibility, own} <- [
          {"private", ~s|  defp hex_audit(_args), do: Mix.shell().cmd("mix hex.audit --policy")|},
          {"public", ~s|  def hex_audit(_args), do: Mix.shell().cmd("mix hex.audit --policy")|}
        ] do
      test "leaves a #{visibility} hex_audit/1 the project defined as it is" do
        igniter = phx_test_project() |> with_function(unquote(own)) |> install_again()

        assert hex_audit_heads(content(igniter, "mix.exs")) == [unquote(own)]
        assert precommit(igniter) == @precommit
      end
    end
  end

  describe "a project an earlier version gave the audit" do
    test "has the copy it was given raised to Hex 2.6.0, once" do
      igniter = phx_test_project() |> with_function(@hex_audit_0_24) |> install_again()

      assert hex_audit_heads(content(igniter, "mix.exs")) == ["  defp hex_audit(_args) do"]
      assert content(igniter, "mix.exs") =~ ~s[Version.match?(hex, "< 2.6.0")]
      refute content(igniter, "mix.exs") =~ "2.5.1"
      refute content(igniter, "mix.exs") =~ "2.5.0 cannot acknowledge"

      igniter |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    test "keeps a copy the developer changed, and says to raise its check" do
      changed = String.replace(@hex_audit_0_24, "mix local.hex --force", "mix local.hex")

      run = phx_test_project() |> with_function(changed) |> install_on()

      assert content(apply_igniter!(run), "mix.exs") =~ ~s[Version.match?(hex, "< 2.5.1")]

      assert notices_about(run, "hex_audit/1 in mix.exs accepts Hex 2.5.1") == [
               """
               hex_audit/1 in mix.exs accepts Hex 2.5.1, whose mix hex.audit passes when it cannot
               fetch a package's registry entry, without checking it. Raise its check to
               Version.match?(hex, "< 2.6.0"), and run mix local.hex --force.
               """
             ]
    end

    test "is told its tests now run with warnings as errors, where a new project is not" do
      run =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
        |> install_on()

      assert notices_about(run, "mix precommit now runs test --warnings-as-errors") != []
      assert notices_about(install(), "mix precommit now runs test --warnings-as-errors") == []
    end

    test "runs its tests with warnings as errors, and keeps a test step with options of its own" do
      plain = phx_test_project() |> with_precommit(~s(precommit: ["test"])) |> install_again()
      assert content(plain, "mix.exs") =~ ~s("test --warnings-as-errors")

      own =
        phx_test_project()
        |> with_precommit(~s(precommit: ["test --cover"]))
        |> install_again()

      assert content(own, "mix.exs") =~ ~s("test --cover")
      refute content(own, "mix.exs") =~ "test --warnings-as-errors"
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

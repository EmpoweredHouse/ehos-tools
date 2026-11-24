defmodule Ehosctl.VerifyTest do
  # `ehosctl verify` (eh-os#355, ehos-tools#93): an application checked as its CI checks it, then
  # by EHOS when an installation is chosen. Not async, through `Ehosctl.SignInCase`: its
  # `ehosctl/2` captures stderr, which every process shares.
  use Ehosctl.SignInCase

  alias Ehosctl.Verify

  @manifest ~s({"schema":"ehos.manifest/v2","application":"shop"})

  @gates [
    ~w(deps.get --only test --check-locked),
    ~w(hex.audit),
    ~w(format --check-formatted),
    ~w(compile --warnings-as-errors),
    ~w(test),
    ~w(ehos_contract.check),
    ~w(ehos_contract.manifest --output _build/ehos.manifest.json)
  ]

  # What every gate says on stderr, after it the warning that the lint was left out.
  @every_gate """
  ==> Gate 1 of 7: mix deps.get --only test --check-locked
    ==> jose
    Compiling 3 files (.ex)
    All deps
  ==> Gate 1 passed in 2 s.
  ==> Gate 2 of 7: mix hex.audit
  ==> Gate 2 passed in 2 s.
  ==> Gate 3 of 7: mix format --check-formatted
  ==> Gate 3 passed in 2 s.
  ==> Gate 4 of 7: mix compile --warnings-as-errors
  ==> Gate 4 passed in 2 s.
  ==> Gate 5 of 7: mix test
  ==> Gate 5 passed in 2 s.
  ==> Gate 6 of 7: mix ehos_contract.check
  ==> Gate 6 passed in 2 s.
  ==> Gate 7 of 7: mix ehos_contract.manifest --output _build/ehos.manifest.json
  ==> Gate 7 passed in 2 s.
  """

  @lint_skipped """
  ! ehosctl skipped the lint: Credo is not among the packages in mix.lock.
    To lint, add Credo to mix.exs with `only: [:dev, :test]`.
  """

  @gates_table """
    GATE                                                           RESULT     TIME
    mix deps.get --only test --check-locked                        ✓ passed   2 s
    mix hex.audit                                                  ✓ passed   2 s
    mix format --check-formatted                                   ✓ passed   2 s
    mix compile --warnings-as-errors                               ✓ passed   2 s
    mix credo                                                      · skipped  <none>
    mix test                                                       ✓ passed   2 s
    mix ehos_contract.check                                        ✓ passed   2 s
    mix ehos_contract.manifest --output _build/ehos.manifest.json  ✓ passed   2 s
  """

  @no_installation "! Every gate passed. EHOS did not check ehos.yaml and the manifest.\n\n" <>
                     @gates_table <>
                     """

                       EHOS   not asked: no installation is chosen

                     Next:
                       ehosctl login URL
                     """

  @hex_info """
  Hex:    2.6.0
  Elixir: 1.20.4
  OTP:    28.5.0.7

  Built with: Elixir 1.20.4 and OTP 28.5
  """

  @run_verify_there "Run `ehosctl verify` in the directory that holds mix.exs, ehos.yaml and " <>
                      ".tool-versions of the application, or in the directory of a utility " <>
                      "service, which holds ehos.yaml and no mix.exs.\n"

  setup %{tmp_dir: tmp_dir, opts: opts} do
    app = Path.join(tmp_dir, "shop")
    File.mkdir_p!(Path.join(app, "_build"))
    File.write!(Path.join(app, "mix.exs"), "")
    File.write!(Path.join(app, "ehos.yaml"), "schema: ehos.yaml/v2\n")
    File.write!(Path.join(app, ".tool-versions"), "erlang 28.5.0.7\nelixir 1.20.4-otp-28\n")

    # Each step passes; the manifest's gate writes the manifest, as Mix would.
    stub_runner(fn args ->
      if Enum.any?(~w(ehos_contract.manifest eh_os_contract.manifest), &(&1 in args)),
        do: write_manifest(app, @manifest)

      0
    end)

    stub(Ehosctl.OSMock, :find_executable, fn "mise" -> "/bin/mise" end)
    mock_hex_info({@hex_info, 0})
    stub_virtual_clock()
    %{app: app, opts: Keyword.put(opts, :dir, app)}
  end

  describe "steps/3" do
    test "runs CI's gates in CI's order, under the application's own toolchain" do
      assert Verify.steps("/bin/mise", "/src/shop") == steps("/src/shop", @gates)
    end

    test "checks the events' fields after the contract's rules, when asked" do
      {before, [manifest]} = Enum.split(@gates, -1)

      assert Verify.steps("/bin/mise", "/src/shop", schema?: true) ==
               steps("/src/shop", before ++ [~w(ehos_contract.schema --check), manifest])
    end

    test "lints after the compile and before the tests, when asked" do
      {before, later} = Enum.split(@gates, 4)

      assert Verify.steps("/bin/mise", "/src/shop", credo?: true) ==
               steps("/src/shop", before ++ [~w(credo)] ++ later)
    end

    test "writes the bundle in place of the manifest alone, when asked" do
      {before, [_manifest]} = Enum.split(@gates, -1)

      assert Verify.steps("/bin/mise", "/src/shop", bundle?: true) ==
               steps(
                 "/src/shop",
                 before ++ [~w(ehos_contract.bundle --output-dir _build/ehos.bundle)]
               )
    end

    test "runs the library's tasks under its name before 0.16.0, when asked" do
      gates =
        Enum.map(@gates, fn
          ["ehos_contract." <> task | args] -> ["eh_os_contract." <> task | args]
          gate -> gate
        end)

      assert gates != @gates

      assert Verify.steps("/bin/mise", "/src/shop", library: "eh_os_contract") ==
               steps("/src/shop", gates)
    end

    test "leaves out the tests when asked" do
      assert Verify.steps("/bin/mise", "/src/shop", test?: false) ==
               steps("/src/shop", @gates -- [~w(test)])
    end
  end

  describe "verify" do
    test "runs the tasks of an application whose lock has the library under its name before 0.16.0",
         %{app: app, opts: opts} do
      File.write!(
        Path.join(app, "mix.lock"),
        ~s(%{\n  "eh_os_contract": {:git, "https://github.com/EmpoweredHouse/eh-os-contract.git", "#{String.duplicate("a", 40)}", []},\n}\n)
      )

      assert {0, _out, _err} = ehosctl(["verify"], opts)

      assert ran() ==
               runs(
                 app,
                 Enum.map(@gates, fn
                   ["ehos_contract." <> task | args] -> ["eh_os_contract." <> task | args]
                   gate -> gate
                 end)
               )
    end

    test "runs every gate, and says EHOS's check was left out with no installation chosen",
         %{app: app, opts: opts} do
      assert ehosctl(["verify"], opts) ==
               {0, @no_installation, @every_gate <> @lint_skipped}

      assert ran() == runs(app, @gates)
    end

    test "leaves out EHOS's check in a job that names its installation by EHOSCTL_URL",
         %{provider: provider, opts: opts} do
      stub_env(%{
        "EHOSCTL_URL" => provider.issuer,
        "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.example/token",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "request-token"
      })

      assert ehosctl(["verify"], opts) ==
               {0,
                "! Every gate passed. EHOS did not check ehos.yaml and the manifest.\n\n" <>
                  @gates_table <>
                  """

                    EHOS   not asked: the credential of a GitHub Actions job can only deploy

                  Next:
                    ehosctl deploy --preview
                  """, @every_gate <> @lint_skipped}

      assert FakeProvider.requests(provider, "/oauth/token") == []

      # Outside a job, EHOSCTL_URL is refused as for any command that needs a credential.
      stub_env(%{"EHOSCTL_URL" => provider.issuer})

      assert ehosctl(["verify"], opts) ==
               {4, "",
                @every_gate <>
                  @lint_skipped <>
                  "ehosctl: EHOSCTL_URL names #{provider.issuer}. ehosctl uses this address only in a " <>
                  "GitHub Actions job, with the token of the job. On a terminal, unset " <>
                  "EHOSCTL_URL and run `ehosctl login #{provider.issuer}`.\n"}
    end

    # ehos_contract.lock (ehos-tools#274): an application keeps one from ehos_app 0.16.0, once it
    # has a contract; one before has no `ehos_contract.schema` task to run.
    test "checks the events' fields against ehos_contract.lock only where the application keeps one",
         %{app: app, opts: opts} do
      {0, _stdout, _stderr} = ehosctl(["verify"], opts)
      assert ran() == runs(app, @gates)

      # One that is not a regular file is refused, before anything runs, rather than taken for none.
      File.mkdir!(Path.join(app, "ehos_contract.lock"))

      assert ehosctl(["verify"], opts) ==
               {2, "", "ehosctl: ehos_contract.lock is not a regular file (directory).\n"}

      assert ran() == []

      File.rmdir!(Path.join(app, "ehos_contract.lock"))
      File.write!(Path.join(app, "ehos_contract.lock"), "%{}\n")
      {0, _stdout, _stderr} = ehosctl(["verify"], opts)
      {before, [manifest]} = Enum.split(@gates, -1)
      assert ran() == runs(app, before ++ [~w(ehos_contract.schema --check), manifest])
    end

    # ehos-tools#505: an application from an `ehos_app` before Credo has none, and is told the lint
    # was left out rather than failed.
    test "lints only where Credo is among mix.lock's packages", %{app: app, opts: opts} do
      assert ehosctl(["verify"], opts) ==
               {0, @no_installation, @every_gate <> @lint_skipped}

      assert ran() == runs(app, @gates)

      File.write!(Path.join(app, "mix.lock"), ~s(%{\n  "credo": {:hex, :credo, "1.7.12"},\n}\n))

      assert ehosctl(["verify"], opts) ==
               {0,
                """
                ! Every gate passed. EHOS did not check ehos.yaml and the manifest.

                  GATE                                                           RESULT    TIME
                  mix deps.get --only test --check-locked                        ✓ passed  2 s
                  mix hex.audit                                                  ✓ passed  2 s
                  mix format --check-formatted                                   ✓ passed  2 s
                  mix compile --warnings-as-errors                               ✓ passed  2 s
                  mix credo                                                      ✓ passed  2 s
                  mix test                                                       ✓ passed  2 s
                  mix ehos_contract.check                                        ✓ passed  2 s
                  mix ehos_contract.manifest --output _build/ehos.manifest.json  ✓ passed  2 s

                  EHOS   not asked: no installation is chosen

                Next:
                  ehosctl login URL
                """,
                """
                ==> Gate 1 of 8: mix deps.get --only test --check-locked
                  ==> jose
                  Compiling 3 files (.ex)
                  All deps
                ==> Gate 1 passed in 2 s.
                ==> Gate 2 of 8: mix hex.audit
                ==> Gate 2 passed in 2 s.
                ==> Gate 3 of 8: mix format --check-formatted
                ==> Gate 3 passed in 2 s.
                ==> Gate 4 of 8: mix compile --warnings-as-errors
                ==> Gate 4 passed in 2 s.
                ==> Gate 5 of 8: mix credo
                ==> Gate 5 passed in 2 s.
                ==> Gate 6 of 8: mix test
                ==> Gate 6 passed in 2 s.
                ==> Gate 7 of 8: mix ehos_contract.check
                ==> Gate 7 passed in 2 s.
                ==> Gate 8 of 8: mix ehos_contract.manifest --output _build/ehos.manifest.json
                ==> Gate 8 passed in 2 s.
                """}

      assert ran() == runs(app, with_credo(@gates))
    end

    # The lock is read as the map Mix evaluates, not line by line.
    test "finds Credo wherever the lock's map has it, and only as a package of its own",
         %{app: app, opts: opts} do
      File.write!(
        Path.join(app, "mix.lock"),
        ~s(%{"jason": {:hex, :jason}, "credo": {:hex, :credo}})
      )

      {0, _stdout, _stderr} = ehosctl(["verify"], opts)
      assert ran() == runs(app, with_credo(@gates))

      other =
        ~s(%{"tool": {:hex, :tool, "1.0.0", "h", [:mix], [{:credo, "~> 1.7", [hex: :credo]}]}})

      File.write!(Path.join(app, "mix.lock"), other)
      {0, _stdout, _stderr} = ehosctl(["verify"], opts)
      assert ran() == runs(app, @gates)

      for broken <- [~s(%{\n  "credo": {:hex,\n), ~s|%{"credo": "| <> <<0xFF>> <> ~s|"}|] do
        File.write!(Path.join(app, "mix.lock"), broken)
        {0, _stdout, _stderr} = ehosctl(["verify"], opts)
        assert ran() == runs(app, @gates)
      end
    end

    test "--no-test leaves out the tests", %{app: app, opts: opts} do
      {0, _stdout, _stderr} = ehosctl(["verify", "--no-test"], opts)
      assert ran() == runs(app, @gates -- [~w(test)])
    end

    # Credo in the lock may be kept for :dev alone, or removed from mix.exs and not yet unlocked: no
    # task under the gates' test dependencies. A lint that finds something is not that.
    test "Credo locked but no task here is told apart from a lint that finds something",
         %{app: app, opts: opts} do
      File.write!(Path.join(app, "mix.lock"), ~s(%{\n  "credo": {:hex, :credo, "1.7.12"},\n}\n))

      mock_no_credo_task()

      assert ehosctl(["verify"], opts) ==
               {1, "",
                passed(Enum.take(@gates, 4), 8) <>
                  """
                  ==> Gate 5 of 8: mix credo

                    GATE                                                           RESULT     TIME
                    mix deps.get --only test --check-locked                        ✓ passed   2 s
                    mix hex.audit                                                  ✓ passed   2 s
                    mix format --check-formatted                                   ✓ passed   2 s
                    mix compile --warnings-as-errors                               ✓ passed   2 s
                    mix credo                                                      ✗ failed   <none>
                    mix test                                                       · not run  <none>
                    mix ehos_contract.check                                        · not run  <none>
                    mix ehos_contract.manifest --output _build/ehos.manifest.json  · not run  <none>

                  ehosctl: Credo is in mix.lock, but it is not a task in the test environment: `mix help credo` exited with 1.
                  mix help credo printed:
                    ** (Mix) The task "credo" could not be found
                  What to do:
                    Give the dependency of Credo `only: [:dev, :test]` in mix.exs. If mix.exs no longer has Credo, unlock it:
                    mix deps.unlock --unused
                  """}

      assert ran() == runs(app, Enum.take(@gates, 4))

      # Asked as the gate would run, under the same mise, in the application, with `MIX_ENV=test`.
      assert_received {:help_credo, "/bin/mise", args, env: env}
      assert args == ["-C", app, "exec", "--", "mix", "help", "credo"]
      assert env == [{"MIX_ENV", "test"}, {"MISE_ACTIVATE_AGGRESSIVE", "1"}]

      mock_credo_findings()

      assert ehosctl(["verify"], opts) ==
               {1, "",
                passed(Enum.take(@gates, 4), 8) <>
                  """
                  ==> Gate 5 of 8: mix credo

                    GATE                                                           RESULT           TIME
                    mix deps.get --only test --check-locked                        ✓ passed         2 s
                    mix hex.audit                                                  ✓ passed         2 s
                    mix format --check-formatted                                   ✓ passed         2 s
                    mix compile --warnings-as-errors                               ✓ passed         2 s
                    mix credo                                                      ✗ exited with 2  2 s
                    mix test                                                       · not run        <none>
                    mix ehos_contract.check                                        · not run        <none>
                    mix ehos_contract.manifest --output _build/ehos.manifest.json  · not run        <none>

                  ehosctl: The gate `mix credo` exited with 2, or mise did when it started the gate.
                  What to do:
                    Correct what mix printed above, and run the command again.
                  """}
    end

    test "stops at the first gate that fails, with exit 1, and says what each gate found",
         %{app: app, opts: opts} do
      mock_gate_exits("compile", 3)

      assert ehosctl(["verify"], opts) ==
               {1, "",
                passed(Enum.take(@gates, 3), 7) <>
                  """
                  ==> Gate 4 of 7: mix compile --warnings-as-errors
                  ! ehosctl skipped the lint: Credo is not among the packages in mix.lock.
                    To lint, add Credo to mix.exs with `only: [:dev, :test]`.

                    GATE                                                           RESULT           TIME
                    mix deps.get --only test --check-locked                        ✓ passed         2 s
                    mix hex.audit                                                  ✓ passed         2 s
                    mix format --check-formatted                                   ✓ passed         2 s
                    mix compile --warnings-as-errors                               ✗ exited with 3  2 s
                    mix credo                                                      · skipped        <none>
                    mix test                                                       · not run        <none>
                    mix ehos_contract.check                                        · not run        <none>
                    mix ehos_contract.manifest --output _build/ehos.manifest.json  · not run        <none>

                  ehosctl: The gate `mix compile --warnings-as-errors` exited with 3, or mise did when it started the gate.
                  What to do:
                    Correct what mix printed above, and run the command again.
                  """}

      assert ran() == runs(app, Enum.take(@gates, 4))
    end

    test "gives a gate's time in seconds, and in minutes from 60 seconds, rounded",
         %{opts: opts} do
      for {ms, time} <- [{59_400, "59 s"}, {59_500, "1 min 0 s"}, {125_000, "2 min 5 s"}] do
        stub(Ehosctl.RunnerMock, :streamed, fn _cmd, args, _env, acc, _printed ->
          Ehosctl.Clock.current().sleep(ms)
          {if("hex.audit" in args, do: 1, else: 0), acc}
        end)

        {1, "", stderr} = ehosctl(["verify"], opts)

        assert stderr =~
                 "==> Gate 1 passed in #{time}.\n==> Gate 2 of 7: mix hex.audit\n"
      end
    end

    test "--json gives what each gate found in the error's object, and no table on stderr",
         %{opts: opts} do
      mock_gate_exits("compile", 3)

      {1, "", stderr} = ehosctl(["verify", "--json"], opts)

      [progress, error] =
        String.split(stderr, "==> Gate 4 of 7: mix compile --warnings-as-errors\n")

      assert progress == passed(Enum.take(@gates, 3), 7)

      gate = fn name, result, status, ms ->
        %{"gate" => name, "result" => result, "exit_status" => status, "milliseconds" => ms}
      end

      assert JSON.decode!(error) == %{
               "error" => %{
                 "kind" => "failed",
                 "message" =>
                   "The gate `mix compile --warnings-as-errors` exited with 3, or mise did when " <>
                     "it started the gate. Correct what mix printed above, and run the command " <>
                     "again.",
                 "gates" => [
                   gate.("mix deps.get --only test --check-locked", "passed", 0, 2_000),
                   gate.("mix hex.audit", "passed", 0, 2_000),
                   gate.("mix format --check-formatted", "passed", 0, 2_000),
                   gate.("mix compile --warnings-as-errors", "failed", 3, 2_000),
                   gate.("mix credo", "skipped", nil, nil),
                   gate.("mix test", "not_run", nil, nil),
                   gate.("mix ehos_contract.check", "not_run", nil, nil),
                   gate.(
                     "mix ehos_contract.manifest --output _build/ehos.manifest.json",
                     "not_run",
                     nil,
                     nil
                   )
                 ]
               }
             }
    end

    # Hex reports a finding by its exit status, and `mix deps.get` before it only prints one
    # (ehos-tools#507): the audit stops the gates before anything compiles.
    test "a retired or vulnerable package in the lock stops the gates before the compile",
         %{app: app, opts: opts} do
      mock_gate_exits("hex.audit", 1)

      assert ehosctl(["verify"], opts) ==
               {1, "",
                passed(Enum.take(@gates, 1), 7) <>
                  """
                  ==> Gate 2 of 7: mix hex.audit
                  """ <>
                  @lint_skipped <>
                  "\n" <>
                  gates_table_at_audit("✗ exited with 1", "2 s") <>
                  """

                  ehosctl: The gate `mix hex.audit` exited with 1, or mise did when it started the gate.
                  What to do:
                    A package in mix.lock is retired or has a security advisory, as mix printed above, or Hex could not reach its registry. Update the package. If the advisory does not reach the application, acknowledge it under `hex:` in mix.exs, with `ignore_advisories:` and the ID of the advisory, or `ignore_retirements:`. Without the network, HEX_OFFLINE=1 audits against the cache of Hex.
                  """}

      assert ran() == runs(app, Enum.take(@gates, 2))
    end

    # Hex before 2.6 passes an audit whose registry fetch failed, and before 2.5 audits
    # retirements alone: refused as `mix precommit` refuses it (ehos-tools#611, #537).
    test "asks which Hex the audit runs under, offline, through the same mise",
         %{app: app, opts: opts} do
      {0, _stdout, _stderr} = ehosctl(["verify"], opts)

      assert_received {:hex_info, "/bin/mise", args, env: env}
      assert args == ["-C", app, "exec", "--", "mix", "hex.info"]

      assert env == [
               {"HEX_OFFLINE", "1"},
               {"MIX_ENV", "test"},
               {"MISE_ACTIVATE_AGGRESSIVE", "1"}
             ]
    end

    test "refuses Hex before 2.6.0 before the audit runs", %{app: app, opts: opts} do
      mock_hex_info({String.replace(@hex_info, "2.6.0", "2.5.1"), 0})

      assert ehosctl(["verify"], opts) ==
               {1, "", hex_refused("2.6.0", "2.5.1")}

      assert ran() == runs(app, Enum.take(@gates, 1))
    end

    test "runs the audit under Hex 2.6.0", %{app: app, opts: opts} do
      {0, _stdout, _stderr} = ehosctl(["verify"], opts)

      assert ran() == runs(app, @gates)
    end

    # One minimum, kept in two packages that do not depend on each other: `verify` refuses just
    # below the one ehos_app's `hex_audit/1` keeps, and runs the audit at it. A pre-release is
    # below its version.
    test "keeps the Hex minimum of a generated project's `mix precommit`",
         %{app: app, opts: opts} do
      installer =
        File.read!(Path.expand("../../../ehos_app/lib/mix/tasks/ehos_app.install.ex", __DIR__))

      [minimum] =
        Regex.run(~r/Version\.match\?\(hex, "< (\S+)"\)/, installer, capture: :all_but_first)

      mock_hex_info({String.replace(@hex_info, "2.6.0", minimum <> "-dev"), 0})

      assert ehosctl(["verify"], opts) ==
               {1, "", hex_refused(minimum, minimum <> "-dev")}

      assert ran() == runs(app, Enum.take(@gates, 1))

      mock_hex_info({String.replace(@hex_info, "2.6.0", minimum), 0})
      {0, _stdout, _stderr} = ehosctl(["verify"], opts)

      assert ran() == runs(app, @gates)
    end

    test "stops when Hex's version cannot be told, with what `mix hex.info` printed",
         %{app: app, opts: opts} do
      for {{printed, _status} = answer, why} <- [
            {{"** (Mix) The task \"hex.info\" could not be found\n", 1}, "exited with 1"},
            {{"Elixir: 1.20.4\n", 0}, "said no version"},
            {{"Hex:    two\n", 0}, "said the version two"}
          ] do
        mock_hex_info(answer)

        assert ehosctl(["verify"], opts) ==
                 {1, "",
                  passed(Enum.take(@gates, 1), 7) <>
                    "==> Gate 2 of 7: mix hex.audit\n" <>
                    @lint_skipped <>
                    "\n" <>
                    gates_table_at_audit("✗ failed", "<none>") <>
                    "\nehosctl: ehosctl cannot tell which Hex `mix hex.audit` uses: `mix hex.info` " <>
                    "#{why}.\nmix hex.info printed:\n  #{String.trim_trailing(printed)}\n"}

        assert ran() == runs(app, Enum.take(@gates, 1))
      end
    end

    test "refuses a directory that is not an application's, before running anything",
         %{app: app, opts: opts} do
      File.rm!(Path.join(app, "ehos.yaml"))
      File.rm!(Path.join(app, ".tool-versions"))

      assert ehosctl(["verify"], opts) ==
               {2, "",
                "ehosctl: #{app} is not the directory of an application: it has no ehos.yaml and no " <>
                  ".tool-versions as a regular file. " <> @run_verify_there}

      assert ran() == []
    end

    test "runs in an application whose _build is a link, as Mix allows",
         %{app: app, opts: opts, tmp_dir: tmp_dir} do
      elsewhere = Path.join(tmp_dir, "build")
      File.mkdir_p!(elsewhere)
      File.rm_rf!(Path.join(app, "_build"))
      File.ln_s!(elsewhere, Path.join(app, "_build"))

      assert ehosctl(["verify"], opts) ==
               {0, @no_installation, @every_gate <> @lint_skipped}
    end

    test "a manifest the gate did not write fails, with no installation chosen", %{opts: opts} do
      mock_gates_write_nothing()

      assert ehosctl(["verify"], opts) ==
               {1, "",
                @every_gate <>
                  @lint_skipped <>
                  "ehosctl: _build/ehos.manifest.json cannot be read: no such file or directory.\n"}
    end

    test "an installation named and unknown is an error before any gate, not a check left out",
         %{opts: opts} do
      assert ehosctl(["verify", "--installation", "nowhere"], opts) ==
               {4, "",
                ~s(ehosctl: No installation is named "nowhere".\nWhat to do:\n  See the names, or sign in to a new installation with its address:\n  ehosctl installations list\n  ehosctl login URL\n)}

      stub_env(%{"EHOSCTL_INSTALLATION" => "elsewhere"})

      assert ehosctl(["verify"], opts) ==
               {4, "",
                ~s(ehosctl: No installation is named "elsewhere".\nWhat to do:\n  See the names, or sign in to a new installation with its address:\n  ehosctl installations list\n  ehosctl login URL\n)}

      assert ran() == []
    end
  end

  describe "verify, signed in" do
    setup %{provider: provider, opts: opts} do
      login!(provider, opts)
      :ok
    end

    test "asks EHOS to check ehos.yaml and the manifest, each as it is",
         %{provider: provider, opts: opts} do
      accept_both(provider)

      assert ehosctl(["verify"], opts) ==
               {0,
                "✓ Every gate passed, and EHOS accepts ehos.yaml and the manifest.\n\n" <>
                  @gates_table <>
                  """

                    EHOS            #{provider.issuer}
                    ehos.yaml       accepted as ehos.yaml/v1
                    Newest schema   ehos.yaml/v2
                    Manifest        accepted for shop, as ehos.manifest/v2
                  """, @every_gate <> @lint_skipped}

      assert FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check") == [
               check_request("schema: ehos.yaml/v2\n", "application/yaml"),
               check_request(@manifest, "application/json")
             ]
    end

    # ehos-tools#508: a script reads what each gate found, and what EHOS said, from stdout alone;
    # the gates' progress stays on stderr, and the warning is left out.
    test "--json gives what each gate found and what EHOS said",
         %{provider: provider, opts: opts} do
      accept_both(provider)

      {0, stdout, stderr} = ehosctl(["verify", "--json"], opts)
      assert stderr == @every_gate

      gate = fn name ->
        %{"gate" => name, "result" => "passed", "exit_status" => 0, "milliseconds" => 2_000}
      end

      assert JSON.decode!(stdout) == %{
               "gates" => [
                 gate.("mix deps.get --only test --check-locked"),
                 gate.("mix hex.audit"),
                 gate.("mix format --check-formatted"),
                 gate.("mix compile --warnings-as-errors"),
                 %{
                   "gate" => "mix credo",
                   "result" => "skipped",
                   "exit_status" => nil,
                   "milliseconds" => nil
                 },
                 gate.("mix test"),
                 gate.("mix ehos_contract.check"),
                 gate.("mix ehos_contract.manifest --output _build/ehos.manifest.json")
               ],
               "bundle" => nil,
               "ehos" => %{
                 "checked" => true,
                 "url" => provider.issuer,
                 "ehos_yaml" => %{"version" => "ehos.yaml/v1", "latest" => "ehos.yaml/v2"},
                 "manifest" => %{"application" => "shop", "version" => "ehos.manifest/v2"}
               }
             }
    end

    test "sends an empty ehos.yaml as it is", %{provider: provider, app: app, opts: opts} do
      accept_both(provider)
      File.write!(Path.join(app, "ehos.yaml"), "")

      {0, _stdout, _stderr} = ehosctl(["verify"], opts)

      assert FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check") == [
               check_request("", "application/yaml"),
               check_request(@manifest, "application/json")
             ]
    end

    test "writes the bundle where the application's ehos_contract has the task, and checks " <>
           "its manifest",
         %{provider: provider, app: app, opts: opts} do
      accept_both(provider)
      # As the compile gate builds it, from a sparse checkout whose sources are elsewhere.
      ebin = Path.join(app, "_build/test/lib/ehos_contract_auth/ebin")
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "Elixir.Mix.Tasks.EhosContract.Bundle.beam"), "")

      # What an earlier run left is removed, since the task writes only into an empty directory.
      stale = Path.join(app, "_build/ehos.bundle/graph/removed.json")
      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "{}")

      mock_bundle_task(app, stale)

      assert ehosctl(["verify"], opts) ==
               {0,
                """
                ✓ Every gate passed, and EHOS accepts ehos.yaml and the manifest.

                  GATE                                                      RESULT     TIME
                  mix deps.get --only test --check-locked                   ✓ passed   2 s
                  mix hex.audit                                             ✓ passed   2 s
                  mix format --check-formatted                              ✓ passed   2 s
                  mix compile --warnings-as-errors                          ✓ passed   2 s
                  mix credo                                                 · skipped  <none>
                  mix test                                                  ✓ passed   2 s
                  mix ehos_contract.check                                   ✓ passed   2 s
                  mix ehos_contract.bundle --output-dir _build/ehos.bundle  ✓ passed   2 s

                  EHOS            #{provider.issuer}
                  ehos.yaml       accepted as ehos.yaml/v1
                  Newest schema   ehos.yaml/v2
                  Manifest        accepted for shop, as ehos.manifest/v2
                  Bundle          _build/ehos.bundle

                Next:
                  ehosctl builds register _build/ehos.bundle --image IMAGE
                """, bundle_gates() <> @lint_skipped}

      assert_received {:stale?, false}

      assert FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check") == [
               check_request("schema: ehos.yaml/v2\n", "application/yaml"),
               check_request(@manifest, "application/json")
             ]

      # A bundle changed since it was written is not sent.
      mock_bundle_task_changing_it(app)

      assert ehosctl(["verify"], opts) ==
               {1, "",
                bundle_gates() <>
                  @lint_skipped <>
                  "ehosctl: #{app}/_build/ehos.bundle/ehos.manifest.json is not the file that " <>
                  "bundle.json names: its SHA-256 differs. The bundle changed after " <>
                  "it was written. ehosctl sent nothing.\n"}
    end

    test "says what EHOS refuses, where, and exits 1", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn _ ->
        {422,
         %{
           "valid" => false,
           "errors" => [
             %{"path" => "needs.database", "line" => 3, "message" => "is not one of …"},
             %{"path" => "", "line" => nil, "message" => "and 4 more"},
             %{"path" => "schema", "line" => nil, "message" => "say \e[2J"}
           ]
         }}
      end)

      assert ehosctl(["verify"], opts) ==
               {1, "",
                @every_gate <>
                  @lint_skipped <>
                  "ehosctl: EHOS refuses ehos.yaml:\n" <>
                  "  - needs.database (line 3): is not one of …\n" <>
                  "  - and 4 more\n" <> ~S(  - schema: "say \e[2J") <> "\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check") == [
               check_request("schema: ehos.yaml/v2\n", "application/yaml")
             ]
    end

    test "a refusal of another kind is EHOS's, with its exit code",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn _ ->
        {413,
         %{"error" => "too_large", "message" => "The document is larger than 1048576 bytes."}}
      end)

      assert ehosctl(["verify"], opts) ==
               {2, "",
                @every_gate <>
                  @lint_skipped <> "ehosctl: The document is larger than 1048576 bytes.\n"}
    end

    test "a credential EHOS refuses is an error, not a check left out",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn _ ->
        {401, %{"error" => "disabled", "message" => "This person is disabled."}}
      end)

      assert ehosctl(["verify"], opts) ==
               {4, "", @every_gate <> @lint_skipped <> "ehosctl: This person is disabled.\n"}
    end

    test "an answer of the other kind is not taken for acceptance",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn _ ->
        {200, %{"valid" => true, "application" => "shop", "version" => "ehos.manifest/v2"}}
      end)

      assert ehosctl(["verify"], opts) ==
               {1, "",
                @every_gate <>
                  @lint_skipped <>
                  "ehosctl: EHOS did not read ehos.yaml as an ehos.yaml. Make sure that the file is " <>
                  "an ehos.yaml.\n"}
    end

    test "refuses a manifest larger than EHOS takes, without sending anything",
         %{provider: provider, app: app, opts: opts} do
      accept_both(provider)
      mock_manifest_gate_writes(app, String.duplicate("x", 1_048_577))

      assert ehosctl(["verify"], opts) ==
               {1, "",
                @every_gate <>
                  @lint_skipped <>
                  "ehosctl: _build/ehos.manifest.json is larger than the 1048576 bytes EHOS takes.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check") == []
    end

    test "refuses a link where the bundle goes, before any gate",
         %{app: app, opts: opts, tmp_dir: tmp_dir} do
      File.ln_s!(tmp_dir, Path.join(app, "_build/ehos.bundle"))

      assert ehosctl(["verify"], opts) ==
               {2, "", "ehosctl: _build/ehos.bundle is not a directory (symlink).\n"}

      assert ran() == []
    end

    test "sends no file a link points to, and says so before any gate",
         %{provider: provider, app: app, opts: opts} do
      accept_both(provider)
      secret = Path.join(Path.dirname(app), "secret")
      File.write!(secret, "not for EHOS")
      File.rm!(Path.join(app, "ehos.yaml"))
      File.ln_s!(secret, Path.join(app, "ehos.yaml"))

      assert ehosctl(["verify"], opts) ==
               {2, "",
                "ehosctl: #{app} is not the directory of an application: it has no ehos.yaml as a " <>
                  "regular file. " <> @run_verify_there}

      assert ran() == []
      assert FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check") == []
    end

    test "refuses a link where the manifest goes, before the gate writes through it",
         %{app: app, opts: opts} do
      target = Path.join(Path.dirname(app), "rc")
      File.write!(target, "kept")
      File.ln_s!(target, Path.join(app, "_build/ehos.manifest.json"))

      assert ehosctl(["verify"], opts) ==
               {2, "", "ehosctl: _build/ehos.manifest.json is not a regular file (symlink).\n"}

      assert ran() == []
      assert File.read!(target) == "kept"
    end
  end

  # The steps `Verify.steps/3` gives for `gates`, each a Mix task's argv, in `dir`.
  defp steps(dir, gates) do
    for gate <- gates do
      %{
        cmd: "/bin/mise",
        args: ["-C", dir, "exec", "--", "mix" | gate],
        env: [{"MIX_ENV", "test"}, {"MISE_ACTIVATE_AGGRESSIVE", "1"}]
      }
    end
  end

  # What `gates`, each passing, print on stderr, numbered of `count`: `mix deps.get` prints what
  # `stub_runner/1` has it print.
  defp passed(gates, count) do
    gates
    |> Enum.with_index(1)
    |> Enum.map_join(fn {gate, number} ->
      printed =
        if "deps.get" in gate,
          do: "  ==> jose\n  Compiling 3 files (.ex)\n  All deps\n",
          else: ""

      "==> Gate #{number} of #{count}: mix #{Enum.join(gate, " ")}\n" <>
        printed <> "==> Gate #{number} passed in 2 s.\n"
    end)
  end

  # What `verify` says on stderr when Hex `found` is older than `minimum`, before the audit.
  defp hex_refused(minimum, found) do
    passed(Enum.take(@gates, 1), 7) <>
      "==> Gate 2 of 7: mix hex.audit\n" <>
      @lint_skipped <>
      "\n" <>
      gates_table_at_audit("✗ failed", "<none>") <>
      """

      ehosctl: `mix hex.audit` needs Hex #{minimum} or later, and this is #{found}. An older Hex passes an audit when it cannot fetch the registry, and does not check the packages.
      What to do:
        Update Hex in the directory of the application:
        mix local.hex --force
      """
  end

  # The table of the gates when the audit stops them with `result`, after `time`.
  defp gates_table_at_audit(result, time) do
    rows = [
      {"mix deps.get --only test --check-locked", "✓ passed", "2 s"},
      {"mix hex.audit", result, time},
      {"mix format --check-formatted", "· not run", "<none>"},
      {"mix compile --warnings-as-errors", "· not run", "<none>"},
      {"mix credo", "· skipped", "<none>"},
      {"mix test", "· not run", "<none>"},
      {"mix ehos_contract.check", "· not run", "<none>"},
      {"mix ehos_contract.manifest --output _build/ehos.manifest.json", "· not run", "<none>"}
    ]

    width = rows |> Enum.map(fn {_gate, result, _time} -> String.length(result) end) |> Enum.max()

    Enum.map_join([{"GATE", "RESULT", "TIME"} | rows], fn {gate, result, time} ->
      String.trim_trailing(
        "  " <>
          String.pad_trailing(gate, 61) <>
          "  " <>
          String.pad_trailing(result, width) <>
          "  " <> time
      ) <> "\n"
    end)
  end

  defp bundle_gates do
    {before, [_manifest]} = Enum.split(@gates, -1)
    passed(before ++ [~w(ehos_contract.bundle --output-dir _build/ehos.bundle)], 7)
  end

  # The programs `verify` runs for `gates`, in the application at `app`, as the runner gets them.
  defp runs(app, gates), do: Enum.map(steps(app, gates), &{&1.cmd, &1.args, &1.env})

  defp with_credo(gates) do
    {before, later} = Enum.split(gates, 4)
    before ++ [~w(credo)] ++ later
  end

  # The programs run since the last call, oldest first.
  defp ran do
    receive do
      {:ran, cmd, args, env} -> [{cmd, args, env} | ran()]
    after
      0 -> []
    end
  end

  defp write_manifest(app, contents),
    do: File.write!(Path.join(app, "_build/ehos.manifest.json"), contents)

  # Runs each program by `exit_code`, a function of its arguments, and records it for `ran/0`.
  # Each gate takes 2 seconds of the virtual clock; `mix deps.get` prints a dependency's compile,
  # its last line unfinished, as Mix prints it.
  defp stub_runner(exit_code) do
    test = self()

    stub(Ehosctl.RunnerMock, :streamed, fn cmd, args, env, acc, printed ->
      send(test, {:ran, cmd, args, env})
      Ehosctl.Clock.current().sleep(2_000)

      acc =
        if "deps.get" in args,
          do: Enum.reduce(["==> jose\nCompiling 3 fi", "les (.ex)\nAll deps"], acc, printed),
          else: acc

      {exit_code.(args), acc}
    end)
  end

  # `mix hex.info`'s output and exit status, and records each call.
  defp mock_hex_info(answer) do
    test = self()

    stub(Ehosctl.RunnerMock, :run, fn cmd, args, opts ->
      send(test, {:hex_info, cmd, args, opts})
      answer
    end)
  end

  defp mock_gate_exits(task, code),
    do: stub_runner(fn args -> if task in args, do: code, else: 0 end)

  defp mock_gates_write_nothing, do: stub_runner(fn _args -> 0 end)

  # `mix help credo` fails, as with no Credo in the test environment; Hex is 2.6.0.
  defp mock_no_credo_task do
    test = self()

    stub(Ehosctl.RunnerMock, :run, fn cmd, args, opts ->
      if "help" in args do
        send(test, {:help_credo, cmd, args, opts})
        {"** (Mix) The task \"credo\" could not be found\n", 1}
      else
        {@hex_info, 0}
      end
    end)
  end

  defp mock_credo_findings do
    mock_hex_info({@hex_info, 0})
    mock_gate_exits("credo", 2)
  end

  defp mock_manifest_gate_writes(app, contents) do
    stub_runner(fn args ->
      if Enum.any?(~w(ehos_contract.manifest eh_os_contract.manifest), &(&1 in args)),
        do: write_manifest(app, contents)

      0
    end)
  end

  # The bundle's task, which says whether `stale` was still there when it ran.
  defp mock_bundle_task(app, stale) do
    test = self()

    stub_runner(fn args ->
      if "ehos_contract.bundle" in args do
        send(test, {:stale?, File.exists?(stale)})
        Ehosctl.BundleFixture.write(Path.join(app, "_build/ehos.bundle"), @manifest, [])
      end

      0
    end)
  end

  defp mock_bundle_task_changing_it(app) do
    stub_runner(fn args ->
      if "ehos_contract.bundle" in args do
        dir = Path.join(app, "_build/ehos.bundle")
        Ehosctl.BundleFixture.write(dir, @manifest, [])
        File.write!(Path.join(dir, "ehos.manifest.json"), String.replace(@manifest, "v2", "v3"))
      end

      0
    end)
  end

  defp check_request(body, content_type),
    do: %{path: "/api/v1/ehos-yaml/check", query: %{}, body: body, content_type: content_type}

  defp accept_both(provider) do
    FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn %{body: body} ->
      if String.starts_with?(body, "{"),
        do: {200, %{"valid" => true, "application" => "shop", "version" => "ehos.manifest/v2"}},
        else: {200, %{"valid" => true, "version" => "ehos.yaml/v1", "latest" => "ehos.yaml/v2"}}
    end)
  end
end

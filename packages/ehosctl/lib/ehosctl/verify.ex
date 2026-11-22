defmodule Ehosctl.Verify do
  @moduledoc """
  `ehosctl verify [--no-test]`: an application checked as its CI checks it, and by EHOS
  (eh-os#355).

  In the application's directory it runs the gates the template's CI runs, in that order, and
  stops at the first that fails:

    1. `mix deps.get --only test --check-locked`, which fails when `mix.lock` is behind `mix.exs`,
       and fetches what is missing, as CI does: it needs the network and access to the
       application's git dependencies
    2. `mix hex.audit`, which fails on a package in `mix.lock` that is retired or has a security
       advisory, where `mix deps.get` only prints it (ehos-tools#507); it needs the network too.
       Hex before 2.6.0 is refused first, as `mix precommit` refuses it from the `ehos_app`
       after 0.24.0 (ehos-tools#611, #537): before 2.6 an audit whose registry fetch failed passed without checking the
       package, and before 2.5 it audited retirements alone. The version is what
       `mix hex.info` says, offline, under the same `mise exec`
    3. `mix format --check-formatted`
    4. `mix compile --warnings-as-errors`
    5. `mix credo`, when Credo is among `mix.lock`'s packages, after `mix help credo` says it is
       a task here: the application's `.credo.exs` decides what it checks. Without Credo, the
       gate is said as skipped, with a warning
    6. `mix test`, left out with `--no-test`
    7. `mix eh_os_contract.check`
    8. `mix eh_os_contract.schema --check`, when the application keeps an `eh_os_contract.lock`:
       every event still reads the rows the lock records
    9. `mix eh_os_contract.bundle`, into `_build/ehos.bundle/`, out of the source tree, when the
       application's `eh_os_contract` has that task: the manifest and the graph documents with
       their `bundle.json`, which `ehosctl builds register` and `ehosctl deploy --bundle` read
       (eh-os D-146). Its directory is emptied first, since the task writes only into an empty
       one, and the bundle is then read as those commands read it (`Ehosctl.Bundle`). An
       `eh_os_contract` before it has `mix eh_os_contract.manifest` alone, which writes
       `_build/ehos.manifest.json`, and that is run instead

  They run as CI runs them: under the application's own `.tool-versions`, through `mise exec`,
  and with `MIX_ENV=test`. They run the project's own code, as `mix test` by hand does: run
  `verify` only in a checkout you trust. Each gate is said on stderr, numbered, and what Mix
  prints follows it there, indented, as it prints it (`Ehosctl.Output.printed/2`), so Mix's own
  `==>` lines are not read as ehosctl's. The result ends with a table of what each gate found,
  and a gate that fails prints the table on stderr before the error; under `--json`, the gates
  are a list in the result, or, when a gate fails or the bundle's directory cannot be emptied,
  in the error's object.

  Then, when an installation is chosen (`--installation`, `EHOSCTL_INSTALLATION`, or the current
  one), EHOS checks the `ehos.yaml` and the manifest (`POST /api/v1/ehos-yaml/check`, once for each;
  eh-os [`docs/ehos-yaml.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ehos-yaml.md),
  "Checking a file"). With none, it says the check was left out. It submits nothing.

  In the directory of a utility service, which holds `ehos.yaml` and no `mix.exs` (eh-os
  [D-175](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0175-a-utility-service-is-an-application-with-no-contract-deployed-to-environments-as-any-other-and-another-application-reaches-it-only-once-the-service-s-side-agrees.md)),
  no gate runs: the service's language is its author's choice. `ehos.yaml` is read and checked
  against `ehos.yaml/v8` as EHOS reads it (`Ehosctl.ServiceYaml`), and the bundle is written from
  it into `_build/ehos.bundle/`: the manifest and no graph documents, and the repository's OpenAPI
  file as it is when the directory holds one, which makes it `ehos.bundle/v2`
  (`Ehosctl.Bundle.write/3`).
  The image is not run. When an installation is chosen, EHOS checks the file and the manifest as
  for an application, and `verify` reads the name's versions
  (`GET /api/v1/applications/:name/versions`) to say whether EHOS knows the name already, and
  refuses a name EHOS knows as an application's. When EHOS does not answer, it says so, and that
  the bundle is written.

  It is on the governed plane, since it may talk to EHOS (eh-os D-87, "the contacting half of
  `verify`"), and chooses its installation itself, as `login` does, so it also runs without one.
  The steps are plain commands, built first and then run, so what it would do is a value a test
  can read, as `init`'s are.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Bundle
  alias Ehosctl.Config
  alias Ehosctl.Failure
  alias Ehosctl.HTTP
  alias Ehosctl.Mise
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.ServiceYaml

  @manifest "_build/ehos.manifest.json"
  @bundle "_build/ehos.bundle"

  # What EHOS takes in one request (eh-os `EhosWeb.Plugs.RawBody`): a document past it is refused
  # here, rather than read whole and sent.
  @max_bytes 1_048_576

  @type step :: %{cmd: String.t(), args: [String.t()], env: [{String.t(), String.t()}]}

  @impl Ehosctl.Command
  def name, do: :verify

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :start

  @impl Ehosctl.Command
  def summary, do: "Check the application in this directory as its CI does."

  @impl Ehosctl.Command
  def chooses_installation?, do: true

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Check the application in this directory as its CI does. In the directory of a " <>
          "utility service, which has ehos.yaml and no mix.exs, check ehos.yaml and write the " <>
          "bundle. If an installation is chosen, EHOS then checks the ehos.yaml and the " <>
          "application manifest. ehosctl submits nothing.",
      flags:
        [
          no_test: [
            long: "--no-test",
            help: "Skip `mix test`, for a check without a database."
          ]
        ] ++ Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    dir = Keyword.get_lazy(opts, :dir, &File.cwd!/0)

    if service?(dir),
      do: service(dir, parsed, opts),
      else: application(dir, parsed, opts)
  end

  # A utility service's repository holds an `ehos.yaml` and no Elixir project (eh-os D-175). A
  # `mix.exs` that is there in any form, a link included, is an application's, refused as before.
  defp service?(dir),
    do:
      match?({:error, :enoent}, File.lstat(Path.join(dir, "mix.exs"))) and
        regular?(Path.join(dir, "ehos.yaml"))

  defp application(dir, parsed, opts) do
    json? = parsed.flags.json

    # The installation is chosen before the gates, so a name that is wrong is said at once, not
    # after the tests.
    with :ok <- application?(dir),
         {:ok, schema?} <- schema_lock(dir),
         credo? = credo?(dir),
         {:ok, installation} <- Config.chosen(parsed.options[:installation], opts),
         {:ok, mise} <- found(Mise.find()),
         gates = [test?: not parsed.flags.no_test, schema?: schema?, credo?: credo?],
         {:ok, ran} <-
           mise |> gated(dir, gates) |> lint_said(credo? or json?) |> gates_said(json?),
         {:ok, manifest} <- written(dir, ran.bundle?),
         {:ok, checked} <- checked_by_ehos(installation, dir, manifest, nil, opts) do
      {:ok,
       %{
         text: application_text(ran, checked),
         json: %{
           "gates" => Enum.map(ran.gates, &gate_json/1),
           "bundle" => if(ran.bundle?, do: @bundle),
           "ehos" => checked_json(checked)
         }
       }}
    end
  end

  # Said once the gates have run, whether they passed or not, before the table and the error.
  defp lint_said(result, true), do: result

  defp lint_said(result, false) do
    lint_skipped()
    result
  end

  defp lint_skipped,
    do:
      Output.warn(
        "ehosctl skipped the lint: Credo is not among the packages in mix.lock.",
        "To lint, add Credo to mix.exs with `only: [:dev, :test]`."
      )

  defp application_text(ran, checked) do
    Output.lines([
      Output.outcome(ending(checked), "Every gate passed" <> ehos_outcome(checked)),
      "",
      gates_table(ran.gates),
      "",
      Output.values(ehos_values(checked) ++ bundle_values(ran.bundle?)),
      "",
      Output.next(login_next(checked) ++ register_next(ran.bundle?) ++ job_next(checked))
    ])
  end

  defp ending({:checked, _said}), do: :done
  defp ending({:not_checked, _why}), do: :warning

  defp ehos_outcome({:checked, _said}), do: ", and EHOS accepts ehos.yaml and the manifest."
  defp ehos_outcome({:not_checked, _why}), do: ". EHOS did not check ehos.yaml and the manifest."

  defp bundle_values(true), do: [{"Bundle", @bundle}]
  defp bundle_values(false), do: []

  defp register_next(true), do: ["ehosctl builds register #{@bundle} --image IMAGE"]
  defp register_next(false), do: []

  defp login_next({:not_checked, :no_installation}), do: ["ehosctl login URL"]
  defp login_next(_checked), do: []

  defp job_next({:not_checked, :github_actions_job}), do: ["ehosctl deploy --preview"]
  defp job_next(_checked), do: []

  # What EHOS said of the files, as labelled values; why it was not asked, when it was not.
  defp ehos_values({:not_checked, :no_installation}),
    do: [{"EHOS", "not asked: no installation is chosen"}]

  defp ehos_values({:not_checked, :github_actions_job}),
    do: [{"EHOS", "not asked: the credential of a GitHub Actions job can only deploy"}]

  defp ehos_values({:checked, said}) do
    [
      {"EHOS", Refusal.shown(said.url)},
      {"ehos.yaml", "accepted as #{Refusal.shown(said.ehos_yaml.version)}"}
    ] ++
      newest(said.ehos_yaml) ++
      [{"Manifest", manifest_said(said.manifest)}] ++
      name_values(said[:name])
  end

  defp newest(%{latest: nil}), do: []
  defp newest(%{latest: latest}), do: [{"Newest schema", Refusal.shown(latest)}]

  defp manifest_said(%{application: application, version: nil}),
    do: "accepted for #{Refusal.shown(application)}"

  defp manifest_said(%{application: application, version: version}),
    do: "accepted for #{Refusal.shown(application)}, as #{Refusal.shown(version)}"

  defp name_values(nil), do: []
  defp name_values(:service), do: [{"Name", "a utility service in EHOS"}]

  defp name_values(:absent),
    do: [{"Name", "new: the first build EHOS registers makes it a utility service"}]

  defp name_values(:unknown),
    do: [{"Name", "EHOS has an application with this name, and does not say its kind"}]

  defp name_values(:unreadable), do: [{"Name", "unknown: ehosctl cannot read it"}]

  defp checked_json({:not_checked, why}),
    do: %{"checked" => false, "why" => Atom.to_string(why)}

  defp checked_json({:checked, said}) do
    %{
      "checked" => true,
      "url" => said.url,
      "ehos_yaml" => %{"version" => said.ehos_yaml.version, "latest" => said.ehos_yaml.latest},
      "manifest" => %{
        "application" => said.manifest.application,
        "version" => said.manifest.version
      }
    }
    |> maybe_put("name", said[:name] && Atom.to_string(said[:name]))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # D-175: no gate runs, since the service's language is its author's. The file is read and
  # checked as EHOS reads it, and the bundle written from it, before EHOS is asked, so a person
  # who cannot reach EHOS still has both.
  #
  # The bundle of an earlier run is removed first, so a file refused now leaves none behind to be
  # registered. The bytes read are the ones the manifest is written from and EHOS is sent.
  defp service(dir, parsed, opts) do
    with :ok <- build_dir(Path.join(dir, "_build")),
         :ok <- bundle_target(Path.join(dir, @bundle)),
         {:ok, installation} <- Config.chosen(parsed.options[:installation], opts),
         :ok <- emptied(dir),
         {:ok, ehos_yaml} <- document(dir, "ehos.yaml"),
         {:ok, service} <- service_read(ehos_yaml),
         {:ok, openapi} <- openapi(dir),
         :ok <- Bundle.write(Path.join(dir, @bundle), service.manifest, openapi),
         {:ok, _manifest} <- written(dir, true),
         {:ok, checked} <-
           checked_by_ehos(
             installation,
             dir,
             service.manifest,
             Map.put(service, :ehos_yaml, ehos_yaml),
             opts
           ) do
      if not parsed.flags.json, do: name_unreadable(checked, service.application)

      {:ok,
       %{
         text: service_text(service.application, openapi, checked),
         json: %{
           "service" => service.application,
           "schema" => ServiceYaml.Schema.version(),
           "openapi" => openapi && openapi.path,
           "bundle" => @bundle,
           "ehos" => checked_json(checked)
         }
       }}
    end
  end

  defp service_text(name, openapi, checked) do
    Output.lines([
      Output.outcome(
        ending(checked),
        "ehosctl found no error in the ehos.yaml of the utility service " <>
          Refusal.shown(name) <> ehos_outcome(checked)
      ),
      Output.values(
        [{"Schema", ServiceYaml.Schema.version()}] ++
          openapi_values(openapi) ++ bundle_values(true) ++ ehos_values(checked)
      ),
      more_rules(checked),
      "",
      Output.next(login_next(checked) ++ register_next(true) ++ job_next(checked))
    ])
  end

  defp openapi_values(nil), do: []

  defp openapi_values(%{path: path}),
    do: [{"OpenAPI file", "#{path}, as it is: EHOS does not check it"}]

  defp more_rules({:not_checked, _why}), do: ["\n", "EHOS checks more rules than the schema."]
  defp more_rules({:checked, _said}), do: nil

  defp name_unreadable({:checked, %{name: :unreadable}}, name),
    do:
      Output.warn(
        "ehosctl cannot tell if an application in EHOS has the name #{Refusal.shown(name)}.",
        "EHOS does not let you read the versions of #{Refusal.shown(name)}. To read them, you " <>
          "need ehos.application.register for #{Refusal.shown(name)}."
      )

  defp name_unreadable(_checked, _name), do: :ok

  # eh-os D-175: a utility service's description of its API, one OpenAPI file at the repository's
  # root under a name the bundle gives it, copied as it is: EHOS keeps it with the build and does
  # not read it. Two of them are refused rather than one chosen.
  defp openapi(dir) do
    case Enum.filter(Bundle.openapi_paths(), &match?({:ok, _}, File.lstat(Path.join(dir, &1)))) do
      [] ->
        {:ok, nil}

      [path] ->
        dir |> document(path) |> openapi_read(path)

      several ->
        {:error, :invalid,
         "This directory holds #{Enum.join(several, " and ")}. A utility service has one OpenAPI " <>
           "file: keep one of them. ehosctl wrote no bundle."}
    end
  end

  defp openapi_read({:ok, ""}, path),
    do:
      {:error, :invalid,
       "#{path} is empty. A bundle holds an OpenAPI file of 1 to #{@max_bytes} bytes. " <>
         "ehosctl wrote no bundle."}

  defp openapi_read({:ok, bytes}, path), do: {:ok, %{path: path, bytes: bytes}}

  defp openapi_read({:error, kind, message}, _path),
    do: {:error, kind, Failure.added(message, " ehosctl wrote no bundle.")}

  defp service_read(ehos_yaml) do
    case ServiceYaml.read(ehos_yaml) do
      {:ok, service} ->
        {:ok, service}

      {:error, reasons} ->
        {:error, :invalid,
         "ehosctl refuses ehos.yaml:\n" <>
           ServiceYaml.listed(reasons) <> "\nehosctl wrote no bundle."}
    end
  end

  # What EHOS said is the check's result, and when EHOS said nothing, what ehosctl did is.
  defp unchecked({:error, :unreachable, message}, :ehos_yaml, %{}),
    do:
      {:error, :unreachable,
       Failure.added(
         message,
         " EHOS did not check ehos.yaml. ehosctl checked it against its own copy of " <>
           "#{ServiceYaml.Schema.version()} and wrote the bundle in #{@bundle}."
       )}

  defp unchecked({:error, :unreachable, message}, :manifest, %{}),
    do:
      {:error, :unreachable,
       Failure.added(
         message,
         " EHOS accepted ehos.yaml and did not check the manifest. ehosctl wrote the bundle " <>
           "in #{@bundle}."
       )}

  defp unchecked(result, _kind, _service), do: result

  @doc """
  The gates, as the commands that run them in the application's directory `dir`, through `mise`.
  `test?: false` leaves out `mix test`; `schema?: true` adds `mix eh_os_contract.schema --check`;
  `credo?: true` adds `mix credo`; `bundle?: true` writes the bundle in place of the manifest
  alone.
  """
  @spec steps(Path.t(), Path.t(), keyword()) :: [step()]
  def steps(mise, dir, opts \\ []),
    do: for({gate, :run} <- plan(opts), do: step(mise, dir, gate))

  # Each gate in CI's order, with whether it runs: a gate left out by `--no-test`, or for want of
  # Credo, is still said, as skipped. The schema's is no gate at all without a lock to check.
  defp plan(opts) do
    [
      {~w(deps.get --only test --check-locked), :run},
      {~w(hex.audit), :run},
      {~w(format --check-formatted), :run},
      {~w(compile --warnings-as-errors), :run},
      {~w(credo), runs?(Keyword.get(opts, :credo?, false))},
      {~w(test), runs?(Keyword.get(opts, :test?, true))},
      {~w(eh_os_contract.check), :run},
      Keyword.get(opts, :schema?, false) && {~w(eh_os_contract.schema --check), :run},
      if(Keyword.get(opts, :bundle?, false),
        do: {~w(eh_os_contract.bundle --output-dir) ++ [@bundle], :run},
        else: {~w(eh_os_contract.manifest --output) ++ [@manifest], :run}
      )
    ]
    |> Enum.filter(& &1)
  end

  defp runs?(true), do: :run
  defp runs?(false), do: :skipped

  # `mise exec` with no tool named reads the directory's `.tool-versions`, the toolchain its CI
  # installs; `MIX_ENV=test` is CI's for every gate, so the compile is the one the tests use.
  defp step(mise, dir, gate),
    do: %{
      cmd: mise,
      args: ["-C", dir, "exec", "--", "mix" | gate],
      env: [{"MIX_ENV", "test"}, Mise.tools_first()]
    }

  # The gates, numbered, then the one that writes the manifest or the bundle: whether the
  # application's `eh_os_contract` writes a bundle can be told only once the gates fetched it.
  # What each found is kept for the table at the end, which a failure gives too.
  defp gated(mise, dir, gates) do
    {checks, [last]} = Enum.split(plan(gates), -1)
    count = Enum.count(checks, &match?({_gate, :run}, &1)) + 1
    run = %{mise: mise, dir: dir, count: count, number: 0, gates: []}

    with {:ok, run} <- run_gates(checks, run, [last]),
         bundle? = bundle_task?(dir),
         last = List.last(plan([bundle?: bundle?] ++ gates)),
         :ok <- emptied(dir) |> with_gates(run.gates, [last]),
         {:ok, run} <- run_gates([last], run, []) do
      {:ok, %{gates: Enum.reverse(run.gates), bundle?: bundle?}}
    end
  end

  defp run_gates([], run, _later), do: {:ok, run}

  defp run_gates([{gate, :skipped} | rest], run, later),
    do: run_gates(rest, %{run | gates: [%{gate: gate, result: :skipped} | run.gates]}, later)

  defp run_gates([{gate, :run} | rest], run, later) do
    number = run.number + 1
    step = step(run.mise, run.dir, gate)
    Output.progress("Gate #{number} of #{run.count}: #{name(gate)}")

    case gate_run(gate, step) do
      {:passed, ms} ->
        Output.progress("Gate #{number} passed in #{duration(ms)}.")
        found = %{gate: gate, result: :passed, status: 0, ms: ms}
        run_gates(rest, %{run | number: number, gates: [found | run.gates]}, later)

      {:failed, found, message} ->
        {:error, :failed, message}
        |> with_gates([Map.put(found, :gate, gate) | run.gates], rest ++ later)
    end
  end

  # A check before a gate that, when it fails, keeps the gate from running: which Hex audits,
  # and whether Credo is a task here.
  defp gate_run(gate, step) do
    with :ok <- before_gate(gate, step) do
      started = Ehosctl.Clock.current().monotonic()

      {status, printing} =
        Ehosctl.Runner.current().streamed(
          step.cmd,
          step.args,
          step.env,
          Output.printing(),
          &Output.printed/2
        )

      Output.printed_end(printing)
      exited(gate, status, Ehosctl.Clock.current().monotonic() - started)
    end
  end

  defp exited(_gate, 0, ms), do: {:passed, ms}

  defp exited(gate, status, ms),
    do:
      {:failed, %{result: :failed, status: status, ms: ms},
       Failure.new(
         "The gate `#{name(gate)}` exited with #{status}, or mise did when it started the gate.",
         advice: advice(gate)
       )}

  # `message`, an error, with what each gate found, the gates in `later` as not run or skipped.
  defp with_gates(:ok, _gates, _later), do: :ok

  defp with_gates({:error, kind, message}, gates, later),
    do: {:error, kind, message, {:gates, Enum.reverse(gates, Enum.map(later, &later_gate/1))}}

  defp later_gate({gate, :run}), do: %{gate: gate, result: :not_run}
  defp later_gate({gate, :skipped}), do: %{gate: gate, result: :skipped}

  # What each gate found, on stderr before the error, so that the error and what to do stay
  # last; under `--json`, in the error's object.
  defp gates_said({:error, kind, message, {:gates, gates}}, json?) do
    if not json?, do: Output.aside(["\n", gates_table(gates), "\n"])

    {:error, kind, message, %{"gates" => Enum.map(gates, &gate_json/1)}}
  end

  defp gates_said(result, _json?), do: result

  defp name(gate), do: Enum.join(["mix" | gate], " ")

  defp gates_table(gates) do
    gates
    |> Enum.map(&%{"GATE" => name(&1.gate), "RESULT" => result(&1), "TIME" => time(&1)})
    |> Output.table(~w(GATE RESULT TIME))
    |> String.split("\n")
    |> Enum.map_join("\n", &(" " <> &1))
  end

  defp result(%{result: :passed}), do: "✓ passed"
  defp result(%{result: :failed, status: status}), do: "✗ exited with #{status}"
  defp result(%{result: :failed}), do: "✗ failed"
  defp result(%{result: :skipped}), do: "· skipped"
  defp result(%{result: :not_run}), do: "· not run"

  defp time(%{ms: ms}), do: duration(ms)
  defp time(_gate), do: ""

  defp duration(ms), do: ms |> Kernel.+(500) |> div(1000) |> seconds()

  defp seconds(seconds) when seconds < 60, do: "#{seconds} s"
  defp seconds(seconds), do: "#{div(seconds, 60)} min #{rem(seconds, 60)} s"

  defp gate_json(gate) do
    %{
      "gate" => name(gate.gate),
      "result" => Atom.to_string(gate.result),
      "exit_status" => gate[:status],
      "milliseconds" => gate[:ms]
    }
  end

  # Hex before 2.6 passes an audit whose registry fetch failed, without checking the package,
  # and before 2.5 audits retirements alone. Refused as `mix precommit`'s `hex_audit/1` refuses
  # it (ehos-tools#611, #537). The Hex asked is the one the gate runs under, through the same
  # `mise exec`; offline, since only its version is wanted.
  @hex_with_advisories "2.6.0"

  defp before_gate(["hex.audit"], %{cmd: cmd, args: args, env: env}) do
    info = Enum.map(args, &if(&1 == "hex.audit", do: "hex.info", else: &1))
    {output, status} = Ehosctl.Runner.current().run(cmd, info, env: [{"HEX_OFFLINE", "1"} | env])
    hex_version(status, Regex.run(~r/^Hex:\s+(\S+)/m, output, capture: :all_but_first), output)
  end

  # The lock keeps every environment's packages, and one removed from `mix.exs` until it is
  # unlocked, while the gates fetch the test environment's alone: Credo in the lock may still be
  # no task here. `mix help credo` says which, so a lint that finds something is not taken for it.
  defp before_gate(["credo"], %{cmd: cmd, args: args, env: env}) do
    help = List.replace_at(args, -1, "help") ++ ["credo"]

    case Ehosctl.Runner.current().run(cmd, help, env: env) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:failed, %{result: :failed},
         Failure.new(
           "Credo is in mix.lock, but it is not a task in the test environment: " <>
             "`mix help credo` exited with #{status}.",
           tool_output: [{"mix help credo", output}],
           advice:
             "Give the dependency of Credo `only: [:dev, :test]` in mix.exs. If mix.exs no " <>
               "longer has Credo, unlock it:",
           to_do: ["mix deps.unlock --unused"]
         )}
    end
  end

  defp before_gate(_gate, _step), do: :ok

  defp hex_version(0, [version], output) do
    case Version.parse(version) do
      {:ok, parsed} -> hex_recent(parsed)
      :error -> hex_unknown("said the version #{Refusal.shown(version)}", output)
    end
  end

  defp hex_version(0, nil, output), do: hex_unknown("said no version", output)
  defp hex_version(status, _version, output), do: hex_unknown("exited with #{status}", output)

  defp hex_recent(version) do
    if Version.compare(version, @hex_with_advisories) == :lt,
      do:
        {:failed, %{result: :failed},
         Failure.new(
           "`mix hex.audit` needs Hex #{@hex_with_advisories} or later, and this is #{version}. " <>
             "An older Hex passes an audit when it cannot fetch the registry, and does not " <>
             "check the packages.",
           advice: "Update Hex in the directory of the application:",
           to_do: ["mix local.hex --force"]
         )},
      else: :ok
  end

  defp hex_unknown(why, output),
    do:
      {:failed, %{result: :failed},
       Failure.new(
         "ehosctl cannot tell which Hex `mix hex.audit` uses: `mix hex.info` #{why}.",
         tool_output: [{"mix hex.info", output}]
       )}

  # Hex reports a finding by the exit status alone, and 2.6 fails as well when it cannot reach
  # the registry, so the advice names both.
  defp advice(["hex.audit"]),
    do:
      "A package in mix.lock is retired or has a security advisory, as mix printed above, or " <>
        "Hex could not reach its registry. Update the package. If the advisory does not reach " <>
        "the application, acknowledge it under `hex:` in mix.exs, with `ignore_advisories:` " <>
        "and the ID of the advisory, or `ignore_retirements:`. Without the network, " <>
        "HEX_OFFLINE=1 audits against the cache of Hex."

  defp advice(_gate), do: "Correct what mix printed above, and run the command again."

  # `.tool-versions` too: without it the gates would run under whatever toolchain is on the
  # `PATH`, not the one CI installs. Each a regular file, not a link, said before anything runs:
  # a link would be refused only after the gates, when its target is read to be sent. Where the
  # manifest goes may not be a link either, or the manifest gate would write through it.
  defp application?(dir) do
    case Enum.reject(~w(mix.exs ehos.yaml .tool-versions), &regular?(Path.join(dir, &1))) do
      [] ->
        with :ok <- manifest_target(Path.join(dir, @manifest)),
             do: bundle_target(Path.join(dir, @bundle))

      missing ->
        {:error, :invalid,
         "#{Refusal.shown(dir)} is not the directory of an application: it has no " <>
           "#{Enum.join(missing, " and no ")} as a regular file. Run `ehosctl verify` in the " <>
           "directory that holds mix.exs, ehos.yaml and .tool-versions of the application, or " <>
           "in the directory of a utility service, which holds ehos.yaml and no mix.exs."}
    end
  end

  defp regular?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))

  # Whether the schema gate runs. An application from an `ehos_app` before 0.16.0 keeps no lock,
  # and its engine may have no `eh_os_contract.schema` task at all; one with no contract keeps
  # none either, since the engine refuses to record nothing. A lock that is not a regular file is
  # refused, as the application's other files are, rather than taken for none: `mix precommit`
  # would still check it.
  defp schema_lock(dir) do
    case File.lstat(Path.join(dir, "eh_os_contract.lock")) do
      {:ok, %{type: :regular}} ->
        {:ok, true}

      {:ok, %{type: type}} ->
        {:error, :invalid, "eh_os_contract.lock is not a regular file (#{type})."}

      {:error, _reason} ->
        {:ok, false}
    end
  end

  # Whether the lint runs. An application from an `ehos_app` before it added Credo has none, and
  # requiring it would fail every one of them; one that has added Credo, by the template or by
  # hand, has it in its lock. A lock that is not a regular file, or does not parse, says no Credo
  # here: the first gate judges the lock itself.
  # sobelow_skip ["Traversal.FileModule"]
  defp credo?(dir) do
    path = Path.join(dir, "mix.lock")

    # The parser raises on bytes that are not UTF-8, rather than answering an error.
    with {:ok, lock} <- regular?(path) && File.read(path),
         true <- String.valid?(lock),
         {:ok, {:%{}, _meta, packages}} <- locked(lock) do
      List.keymember?(packages, "credo", 0)
    else
      _none -> false
    end
  end

  # The lock is an Elixir map, which Mix evaluates; read as code, never evaluated, so a package is
  # found wherever the map has its key, on a line of its own or not, and never in another
  # package's dependencies. Its keys are kept as strings, so a lock makes no atoms, and the
  # parser's warnings about their quotes, which Mix writes, are not printed.
  defp locked(lock),
    do:
      Code.string_to_quoted(lock,
        static_atoms_encoder: fn name, _meta -> {:ok, name} end,
        emit_warnings: false
      )

  defp manifest_target(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, %{type: type}} -> {:error, :invalid, "#{@manifest} is not a regular file (#{type})."}
      {:error, _reason} -> :ok
    end
  end

  # A directory, emptied before the task writes into it, or nothing yet: a link there would be
  # emptied through, and written through.
  defp bundle_target(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, %{type: type}} -> {:error, :invalid, "#{@bundle} is not a directory (#{type})."}
      {:error, _reason} -> :ok
    end
  end

  # So would a link at `_build`, which a utility service's repository, with no Mix project, holds
  # as any other file. An application's `_build` may be a link of the developer's: its gates
  # write through it already.
  defp build_dir(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, %{type: type}} -> {:error, :invalid, "_build is not a directory (#{type})."}
      {:error, _reason} -> :ok
    end
  end

  # `mix eh_os_contract.bundle`, which an eh-os-contract before it lacks, as the compile gate
  # built it under `MIX_ENV=test`: its module, in whichever of the application's dependencies holds
  # it, however that dependency is fetched (a sparse git checkout keeps its sources under the
  # repository's own path). The built applications are listed, not globbed, so a directory whose
  # name a glob would read is still found.
  @bundle_task "ebin/Elixir.Mix.Tasks.EhOsContract.Bundle.beam"

  defp bundle_task?(dir) do
    built = Path.join(dir, "_build/test/lib")

    case File.ls(built) do
      {:ok, names} -> Enum.any?(names, &regular?(Path.join([built, &1, @bundle_task])))
      {:error, _reason} -> false
    end
  end

  # Emptied whichever is written, so a bundle of an earlier run is never left to be registered.
  defp emptied(dir) do
    path = Path.join(dir, @bundle)

    with :ok <- bundle_target(path) do
      case File.rm_rf(path) do
        {:ok, _removed} -> :ok
        {:error, reason, _file} -> unreadable(@bundle, reason)
      end
    end
  end

  defp written(dir, false), do: document(dir, @manifest)

  defp written(dir, true) do
    case Bundle.read(Path.join(dir, @bundle)) do
      {:ok, bundle} -> {:ok, bundle.manifest}
      {:error, _kind, message} -> {:error, :failed, message}
    end
  end

  defp found({:ok, mise}), do: {:ok, mise}
  defp found({:error, message}), do: {:error, :failed, message}

  defp checked_by_ehos(nil, _dir, _manifest, _service, _opts),
    do: {:ok, {:not_checked, :no_installation}}

  # T-18: a GitHub Actions job's credential is admitted only to make, deploy to and remove its
  # application's ephemeral environments, so in a job the check is left out and no token is
  # exchanged for it. Outside a job, EHOSCTL_URL is refused as for any command that needs a
  # credential.
  defp checked_by_ehos(
         {"EHOSCTL_URL", %{"via" => "EHOSCTL_URL"}} = installation,
         dir,
         manifest,
         service,
         opts
       ) do
    env = Ehosctl.SystemEnv.current().all()

    if Ehosctl.GitHubActions.job?(env),
      do: {:ok, {:not_checked, :github_actions_job}},
      else: checked_by_signed_in(installation, dir, manifest, service, opts)
  end

  defp checked_by_ehos(installation, dir, manifest, service, opts),
    do: checked_by_signed_in(installation, dir, manifest, service, opts)

  # A sign-in that has expired, or a credential EHOS refuses, is an error, not a check left out:
  # a person who is signed in expects EHOS's answer.
  # `service` is nil for an application, and for a utility service its name and the bytes of its
  # `ehos.yaml` already read.
  defp checked_by_signed_in({_name, %{"url" => url}} = installation, dir, manifest, service, opts) do
    with {:ok, ehos_yaml} <- ehos_yaml(dir, service),
         {:ok, yaml_said} <-
           installation |> check(:ehos_yaml, ehos_yaml, opts) |> unchecked(:ehos_yaml, service),
         {:ok, manifest_said} <-
           installation |> check(:manifest, manifest, opts) |> unchecked(:manifest, service),
         {:ok, name} <- kind(installation, service, opts) do
      {:ok,
       {:checked,
        maybe_put(%{url: url, ehos_yaml: yaml_said, manifest: manifest_said}, :name, name)}}
    end
  end

  defp ehos_yaml(dir, nil), do: document(dir, "ehos.yaml")
  defp ehos_yaml(_dir, %{ehos_yaml: ehos_yaml}), do: {:ok, ehos_yaml}

  # eh-os D-175: a name keeps the kind its first manifest gave it, so a utility service's manifest
  # under an application's name is refused when its build is registered. The versions of the name
  # say its kind, and nothing else does.
  defp kind(_installation, nil, _opts), do: {:ok, nil}

  defp kind(installation, %{application: service}, opts) do
    path = "/api/v1/applications/" <> Api.segment(service) <> "/versions"
    installation |> Api.answer(:get, path, nil, opts) |> kind_said(service, installation)
  end

  defp kind_said({:ok, %{status: 200, body: %{"kind" => "service"}}}, _service, _installation),
    do: {:ok, :service}

  defp kind_said({:ok, %{status: 200, body: %{"kind" => "application"}}}, service, _installation),
    do:
      {:error, :failed,
       "#{Refusal.shown(service)} is the name of an application in EHOS. EHOS refuses a " <>
         "utility service with the name of an application. Give the service another name in " <>
         "the application key of ehos.yaml."}

  defp kind_said({:ok, %{status: 200}}, _service, _installation), do: {:ok, :unknown}

  defp kind_said({:ok, %{status: 404, body: %{"error" => "not_found"}}}, _service, _installation),
    do: {:ok, :absent}

  # The warning that ehosctl cannot tell is printed with the result (`name_unreadable/2`).
  defp kind_said({:ok, %{status: 403}}, _service, _installation), do: {:ok, :unreadable}

  defp kind_said({:ok, answer}, _service, installation), do: Api.refusal(answer, installation)

  defp kind_said({:error, kind, message, :sent}, service, installation),
    do: kind_said({:error, kind, message}, service, installation)

  defp kind_said({:error, :unreachable, message}, _service, _installation),
    do:
      {:error, :unreachable,
       Failure.added(
         message,
         " EHOS accepted ehos.yaml and the manifest, and did not say if it knows the name. " <>
           "ehosctl wrote the bundle in #{@bundle}."
       )}

  defp kind_said(error, _service, _installation), do: error

  # A regular file and nothing else, not followed through a link, and read no further than EHOS
  # takes: a checkout could hold a link to a file of the person's, or to a device without end.
  # sobelow_skip ["Traversal.FileModule"]
  defp document(dir, file) do
    path = Path.join(dir, file)

    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, device} <- File.open(path, [:read, :binary]) do
      read = IO.binread(device, @max_bytes + 1)
      File.close(device)

      case read do
        bytes when is_binary(bytes) and byte_size(bytes) > @max_bytes ->
          {:error, :failed, "#{file} is larger than the #{@max_bytes} bytes EHOS takes."}

        bytes when is_binary(bytes) ->
          {:ok, bytes}

        :eof ->
          {:ok, ""}

        {:error, reason} ->
          unreadable(file, reason)
      end
    else
      {:ok, %{type: type}} -> {:error, :failed, "#{file} is not a regular file (#{type})."}
      {:error, reason} -> unreadable(file, reason)
    end
  end

  defp unreadable(file, reason),
    do: {:error, :failed, "#{file} cannot be read: #{:file.format_error(reason)}."}

  defp check(installation, kind, bytes, opts) do
    {file, type} =
      case kind do
        :ehos_yaml -> {"ehos.yaml", "application/yaml"}
        :manifest -> {"the manifest", "application/json"}
      end

    case Api.answer(installation, :post, "/api/v1/ehos-yaml/check", {:raw, type, bytes}, opts) do
      {:ok, %{status: 200, body: %{"valid" => true} = body}} ->
        accepted(kind, body)

      {:ok, %{status: 422, body: %{"valid" => false, "errors" => errors}}} when is_list(errors) ->
        {:error, :failed, "EHOS refuses #{file}:\n" <> Enum.map_join(errors, "\n", &error/1)}

      {:ok, answer} ->
        Api.refusal(answer, installation)

      {:error, _kind, _message, :sent} = unanswered ->
        HTTP.unanswered_read(unanswered)

      error ->
        error
    end
  end

  # EHOS tells a manifest from an `ehos.yaml` by its content, so each answer is checked to be of
  # the kind sent: an `ehos.yaml` that holds a manifest is not an `ehos.yaml` EHOS accepts.
  # The newest schema only when it is another than the file's.
  defp accepted(:ehos_yaml, %{"version" => "ehos.yaml/" <> _ = version} = body) do
    latest = if is_binary(body["latest"]) and body["latest"] != version, do: body["latest"]
    {:ok, %{version: version, latest: latest}}
  end

  defp accepted(:manifest, %{"application" => application} = body) when is_binary(application),
    do:
      {:ok,
       %{application: application, version: if(is_binary(body["version"]), do: body["version"])}}

  defp accepted(:ehos_yaml, _body),
    do:
      {:error, :failed,
       "EHOS did not read ehos.yaml as an ehos.yaml. Make sure that the file is an ehos.yaml."}

  defp accepted(:manifest, _body),
    do:
      {:error, :failed, "EHOS did not read the application manifest as an application manifest."}

  defp error(%{"message" => message} = error) when is_binary(message) do
    where =
      case {error["path"], error["line"]} do
        {path, line} when is_binary(path) and path != "" and is_integer(line) ->
          "#{Refusal.shown(path)} (line #{line}): "

        {path, _line} when is_binary(path) and path != "" ->
          "#{Refusal.shown(path)}: "

        {_path, line} when is_integer(line) ->
          "line #{line}: "

        _none ->
          ""
      end

    "  - " <> where <> Refusal.shown(message)
  end

  defp error(other), do: "  - " <> Refusal.shown(other)
end

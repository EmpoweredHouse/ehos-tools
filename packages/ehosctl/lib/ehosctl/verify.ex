defmodule Ehosctl.Verify do
  @moduledoc """
  `ehosctl verify [--no-test]`: an application checked as its CI checks it, and by EHOS (eh-os
  #355).

  In the application's directory it runs the gates the template's CI runs, in that order, and
  stops at the first that fails:

    1. `mix deps.get --only test --check-locked`, which fails when `mix.lock` is behind `mix.exs`,
       and fetches what is missing, as CI does: it needs the network and access to the
       application's git dependencies
    2. `mix hex.audit`, which fails on a package in `mix.lock` that is retired or has a security
       advisory, where `mix deps.get` only prints it (ehos-tools#507); it needs the network too
    3. `mix format --check-formatted`
    4. `mix compile --warnings-as-errors`
    5. `mix credo`, when Credo is among `mix.lock`'s packages, after `mix help credo` says it is
       a task here: the application's `.credo.exs` decides what it checks
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
  with `MIX_ENV=test`, and with the terminal's own output. They run the project's own code, as
  `mix test` by hand does: run `verify` only in a checkout you trust.

  Then, when an installation is chosen (`--installation`, `EHOSCTL_INSTALLATION`, or the current
  one), EHOS checks the `ehos.yaml` and the manifest (`POST /api/v1/ehos-yaml/check`, once for each;
  eh-os [`docs/ehos-yaml.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ehos-yaml.md),
  "Checking a file"). With none, it says the check was left out. It submits nothing.

  It is on the governed plane, since it may talk to EHOS (eh-os D-87, "the contacting half of
  `verify`"), and chooses its installation itself, as `login` does, so it also runs without one.
  The steps are plain commands, built first and then run, so what it would do is a value a test
  can read, as `init`'s are.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Bundle
  alias Ehosctl.Config
  alias Ehosctl.Mise
  alias Ehosctl.Refusal

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
  def chooses_installation?, do: true

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Check the application in this directory as its CI does, then ask EHOS to check its " <>
          "ehos.yaml and manifest when an installation is chosen. It submits nothing.",
      flags: [
        no_test: [
          long: "--no-test",
          help: "Leave out `mix test`, for a check without a database."
        ]
      ]
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    dir = Keyword.get_lazy(opts, :dir, &File.cwd!/0)

    # The installation is chosen before the gates, so a name that is wrong is said at once, not
    # after the tests.
    with :ok <- application?(dir),
         {:ok, schema?} <- schema_lock(dir),
         credo? = credo?(dir),
         {:ok, installation} <- Config.chosen(parsed.options[:installation], opts),
         {:ok, mise} <- found(Mise.find()),
         gates = [test?: not parsed.flags.no_test, schema?: schema?, credo?: credo?],
         {checks, _written} = Enum.split(steps(mise, dir, gates), -1),
         :ok <- run_steps(checks),
         # Once the gates fetched the dependencies, whether they write a bundle can be told.
         bundle? = bundle_task?(dir),
         :ok <- emptied(dir),
         :ok <- run_steps([List.last(steps(mise, dir, [bundle?: bundle?] ++ gates))]),
         {:ok, manifest} <- written(dir, bundle?),
         {:ok, checked} <- checked_by_ehos(installation, dir, manifest, opts) do
      {:ok,
       %{
         text: "Every gate passed.\n" <> linted(credo?) <> wrote(bundle?) <> checked,
         json: %{}
       }}
    end
  end

  @doc """
  The gates, as the commands that run them in the application's directory `dir`, through `mise`.
  `test?: false` leaves out `mix test`; `schema?: true` adds `mix eh_os_contract.schema --check`;
  `credo?: true` adds `mix help credo` and `mix credo`; `bundle?: true` writes the bundle in place
  of the manifest alone.
  """
  @spec steps(Path.t(), Path.t(), keyword()) :: [step()]
  def steps(mise, dir, opts \\ []) do
    [
      ~w(deps.get --only test --check-locked),
      ~w(hex.audit),
      ~w(format --check-formatted),
      ~w(compile --warnings-as-errors),
      Keyword.get(opts, :credo?, false) && ~w(help credo),
      Keyword.get(opts, :credo?, false) && ~w(credo),
      Keyword.get(opts, :test?, true) && ~w(test),
      ~w(eh_os_contract.check),
      Keyword.get(opts, :schema?, false) && ~w(eh_os_contract.schema --check),
      if(Keyword.get(opts, :bundle?, false),
        do: ~w(eh_os_contract.bundle --output-dir) ++ [@bundle],
        else: ~w(eh_os_contract.manifest --output) ++ [@manifest]
      )
    ]
    |> Enum.filter(& &1)
    |> Enum.map(fn gate ->
      # `mise exec` with no tool named reads the directory's `.tool-versions`, the toolchain its
      # CI installs; `MIX_ENV=test` is CI's for every gate, so the compile is the one the tests
      # use.
      %{
        cmd: mise,
        args: ["-C", dir, "exec", "--", "mix" | gate],
        env: [{"MIX_ENV", "test"}, Mise.tools_first()]
      }
    end)
  end

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
         "#{Refusal.shown(dir)} is not an application's directory: it has no " <>
           "#{Enum.join(missing, " and no ")} as a regular file. Run `ehosctl verify` where " <>
           "the application's mix.exs, ehos.yaml and .tool-versions are."}
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

  defp linted(true), do: ""

  defp linted(false),
    do:
      "The lint was left out: Credo is not among mix.lock's packages. Add it, " <>
        "`only: [:dev, :test]`, to have it.\n"

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

  defp wrote(true),
    do:
      "The bundle is in #{@bundle}: `ehosctl builds register #{@bundle} --image <image>` " <>
        "registers it with its image.\n"

  defp wrote(false), do: ""

  defp found({:ok, mise}), do: {:ok, mise}
  defp found({:error, message}), do: {:error, :failed, message}

  defp run_steps(steps) do
    Enum.reduce_while(steps, :ok, fn %{cmd: cmd, args: args, env: env}, :ok ->
      gate = args |> Enum.drop_while(&(&1 != "mix")) |> Enum.join(" ")
      IO.puts("==> #{gate}")

      case Ehosctl.Runner.current().interactive(cmd, args, env) do
        0 ->
          {:cont, :ok}

        status ->
          {:halt,
           {:error, :failed,
            "`#{gate}` exited with #{status} (it, or mise starting it); nothing after it ran." <>
              hint(gate)}}
      end
    end)
  end

  # The lock keeps every environment's packages, and one removed from `mix.exs` until it is
  # unlocked, while the gates fetch the test environment's alone: Credo in the lock may still be
  # no task here. `mix help credo` says which, so a lint that finds something is not taken for it.
  defp hint("mix help credo"),
    do:
      " Credo is in mix.lock but not a task in the test environment: give its dependency " <>
        "`only: [:dev, :test]`, or, if mix.exs no longer has it, run `mix deps.unlock --unused`."

  # Hex reports a finding by the exit status alone, and 2.6 fails as well when it cannot reach
  # the registry, so the hint names both.
  defp hint("mix hex.audit"),
    do:
      " Either a package in mix.lock is retired or has a security advisory, as listed above, or " <>
        "Hex could not reach its registry. Update the package, or acknowledge one that does not " <>
        "reach the application under `hex:` in mix.exs " <>
        "(`ignore_advisories:` by the advisory's ID, `ignore_retirements:`), which needs Hex " <>
        "2.5.1 or later. Without the network, HEX_OFFLINE=1 audits against Hex's cache."

  defp hint(_gate), do: ""

  defp checked_by_ehos(nil, _dir, _manifest, _opts),
    do:
      {:ok,
       "EHOS's check of ehos.yaml and the manifest was left out: no installation is chosen. " <>
         "Run `ehosctl login` to have it."}

  # T-18: a GitHub Actions job's credential is admitted only to make, deploy to and remove its
  # application's ephemeral environments, so in a job the check is left out and no token is
  # exchanged for it. Outside a job, EHOSCTL_URL is refused as for any command that needs a
  # credential.
  defp checked_by_ehos(
         {"EHOSCTL_URL", %{"via" => "EHOSCTL_URL"}} = installation,
         dir,
         manifest,
         opts
       ) do
    env = Ehosctl.SystemEnv.current().all()

    if Ehosctl.GitHubActions.job?(env),
      do:
        {:ok,
         "EHOS's check of ehos.yaml and the manifest was left out: a GitHub Actions job's " <>
           "credential may only deploy. `ehosctl deploy --preview` checks the manifest there."},
      else: checked_by_signed_in(installation, dir, manifest, opts)
  end

  defp checked_by_ehos(installation, dir, manifest, opts),
    do: checked_by_signed_in(installation, dir, manifest, opts)

  # A sign-in that has expired, or a credential EHOS refuses, is an error, not a check left out:
  # a person who is signed in expects EHOS's answer.
  defp checked_by_signed_in({_name, %{"url" => url}} = installation, dir, manifest, opts) do
    with {:ok, ehos_yaml} <- document(dir, "ehos.yaml"),
         {:ok, yaml_said} <- check(installation, :ehos_yaml, ehos_yaml, opts),
         {:ok, manifest_said} <- check(installation, :manifest, manifest, opts) do
      {:ok, "EHOS at #{Refusal.shown(url)}:\n" <> yaml_said <> "\n" <> manifest_said}
    end
  end

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

      {:error, kind, message, :sent} ->
        {:error, kind, message}

      error ->
        error
    end
  end

  # EHOS tells a manifest from an `ehos.yaml` by its content, so each answer is checked to be of
  # the kind sent: an `ehos.yaml` that holds a manifest is not an `ehos.yaml` EHOS accepts.
  defp accepted(:ehos_yaml, %{"version" => "ehos.yaml/" <> _ = version} = body) do
    newest =
      case body["latest"] do
        latest when is_binary(latest) and latest != version ->
          "; the newest schema is #{Refusal.shown(latest)}"

        _same ->
          ""
      end

    {:ok, "  accepts ehos.yaml, as #{Refusal.shown(version)}#{newest}."}
  end

  defp accepted(:manifest, %{"application" => application} = body) when is_binary(application) do
    as = if is_binary(body["version"]), do: ", as #{Refusal.shown(body["version"])}", else: ""
    {:ok, "  accepts the manifest of #{Refusal.shown(application)}#{as}."}
  end

  defp accepted(:ehos_yaml, _body),
    do: {:error, :failed, "EHOS did not read ehos.yaml as an ehos.yaml: is it one?"}

  defp accepted(:manifest, _body),
    do: {:error, :failed, "EHOS did not read the manifest as a manifest."}

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

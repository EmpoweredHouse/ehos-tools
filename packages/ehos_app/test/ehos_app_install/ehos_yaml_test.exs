defmodule Mix.Tasks.EhosApp.InstallTest.EhosYaml do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # A first install also removes Phoenix's favicon.ico (eh-os D-157), which these tests leave to
  # the design system's.
  @phoenix_icon "priv/static/favicon.ico"

  # The comment on top of the ehos.yaml this version writes.
  @ehos_yaml_header """
  # What this application needs from EHOS in order to run, and nothing about how EHOS provides
  # it. EHOS defines this format, https://github.com/empoweredhouse/eh-os/blob/main/docs/ehos-yaml.md
  # explains every field, and the schema below is EHOS's, as ehos_contract_auth carries it: an
  # editor finds it once `mix deps.get` has run. The application's name is its contract domain's,
  # so it is not written here.
  """

  # The comment on top of every ehos.yaml 0.2.0 to 0.8.1 wrote.
  @ehos_yaml_header_08 """
  # What this application needs from EHOS in order to run, and nothing about how EHOS provides
  # it. EHOS defines this format: the schema beside it, in .ehos/, is a copy of the one it
  # publishes, and https://github.com/empoweredhouse/eh-os/blob/main/docs/ehos-yaml.md explains
  # every field. The application's name is its contract domain's, so it is not written here.
  """

  # The module `needs.database.seed` names, as the installer writes it.
  @seed ~S'''
  defmodule Test.Seed do
    @moduledoc """
    Fills the application with sample data to try it on, in an ephemeral environment of EHOS only,
    never in production (`needs.database.seed` in `ehos.yaml`, eh-os D-98).

    EHOS runs `run/0` after the migration, from the application's image, as the schema's owner,
    with nothing of the application running: `/app/bin/test eval "Test.Seed.run()"`.
    It starts `Test.Repo` and an Oban that runs no queue, and runs `priv/repo/seeds.exs`,
    which `mix ecto.setup` runs on a development database too.

    - **A business fact**, an event a contract declares, is recorded through the contract's
      command: `add/2` issues each step of a profile as the system actor `:sample_data`, which the
      command's `by:` names. `/ehos-app:sample-data` drafts the steps and keeps them in step with
      every change to a contract.
    - **A row the application owns itself** is written by the script, with an upsert or
      `on_conflict: :nothing`, never into the engine's tables.
    - **It runs at every start of the workload**, so each step is keyed `sample:<step>` and a
      second run replays it, and the script adds what it adds once; both quickly, since each start
      waits for them.
    - **It ships in every image**, production's included, so it holds no real data, credentials
      or secrets, and refuses the environments `:production_environments` names; `run/0` also
      refuses where `EHOS_ENVIRONMENT` names none, as EHOS always names one.
    - **`EHOS_SEED_PROFILE` chooses what `add/2` adds**: `empty`, or `small`, the default.
    """

    alias EhosContract.{Actor, Receipt, Rejection}

    @app :test
    @profiles ["empty", "small"]

    # The commands a person may issue that no profile issues, with why: for example
    # `AddCustomer => "its event holds a personal field, which the seed cannot seal yet"`
    # (ehos-tools#646).
    @not_seeded %{}

    # Refusals that mean a step's fact is already there, under a key of its own: the seed done.
    @already []

    @doc "Runs the seed as EHOS does, with the application's configuration (`run/1`)."
    @spec run() :: :ok
    def run do
      Application.load(@app)
      run(config())
    end

    @doc """
    Runs `priv/repo/seeds.exs` with `Test.Repo` started, and Oban, which runs nothing
    here; both stop before it returns. Raises, before starting either, where `:environment` names no
    environment or one of `:production_environments`. `config` decides these refusals alone: the
    script's `add/2` reads the application's.
    """
    @spec run(keyword()) :: :ok
    def run(config) do
      named!(config[:environment])
      refuse_production!(config)
      script = Application.app_dir(@app, "priv/repo/seeds.exs")

      # Isolated: nothing here listens for a notification, so it holds no connection of its own.
      oban =
        @app
        |> Application.fetch_env!(Oban)
        |> Keyword.merge(
          queues: false,
          plugins: false,
          peer: false,
          notifier: Oban.Notifiers.Isolated
        )

      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(Test.Repo, fn _repo ->
          {:ok, _started} = Application.ensure_all_started(:oban)
          {:ok, pid} = Oban.start_link(oban)

          # Stopped before `with_repo` stops the repo, which its processes query.
          try do
            if File.exists?(script), do: Code.eval_file(script)
          after
            Supervisor.stop(pid)
          end
        end)

      :ok
    end

    @doc "The profile `EHOS_SEED_PROFILE` names, `small` when it names none."
    @spec profile() :: String.t()
    def profile, do: known(config()[:profile])

    @doc "The profiles the seed knows."
    @spec profiles() :: [String.t()]
    def profiles, do: @profiles

    @doc """
    Issues the profile's steps in order, and answers each step's key, its command and whether it
    was `:added` now or there `:already`. Raises where `:environment` is one of
    `:production_environments`, whatever calls it, on an unknown profile, and on a step refused for
    any reason but its fact being there already.
    """
    @spec add(String.t(), keyword()) :: [{String.t(), module(), :added | :already}]
    def add(profile, config \\ config()) do
      refuse_production!(config)
      EhosContract.Registry.load!()

      {added, _receipts} = Enum.map_reduce(steps(known(profile)), %{}, &step/2)
      added
    end

    @doc "The commands a person may issue that the seed leaves out on purpose."
    @spec not_seeded() :: [module()]
    def not_seeded, do: Map.keys(@not_seeded)

    # A step is `{key, contract, command}`. Its command is a struct, or a function of the receipts
    # of the steps before it, keyed by step, for an identity the engine generated:
    # `fn %{"company" => r} -> ... end`.
    defp steps("empty"), do: []

    defp steps("small"), do: []

    defp step({key, contract, build}, receipts) do
      command = command(build, receipts)

      {outcome, receipt} =
        contract
        |> EhosContract.dispatch(command,
          actor: Actor.system(:sample_data),
          idempotency_key: "sample:#{key}"
        )
        |> outcome(key)

      {{key, command.__struct__, outcome}, Map.put(receipts, key, receipt)}
    end

    defp command(build, receipts) when is_function(build, 1), do: build.(receipts)
    defp command(command, _receipts), do: command

    defp outcome({:ok, %Receipt{duplicate: false} = receipt}, _key), do: {:added, receipt}
    defp outcome({:ok, %Receipt{duplicate: true} = receipt}, _key), do: {:already, receipt}

    # Not `in`, which the compiler reads as always false while `@already` is empty.
    defp outcome({:error, %Rejection{invariant: invariant}}, key),
      do: refused(Enum.member?(@already, invariant), invariant, key)

    # An error by its kind alone: its detail can hold the command's values, which a log never does.
    defp outcome({:error, {kind, _detail}}, key) when is_atom(kind),
      do: raise("the sample step #{key} failed: #{kind}")

    defp outcome({:error, kind}, key) when is_atom(kind),
      do: raise("the sample step #{key} failed: #{kind}")

    defp outcome({:error, _reason}, key),
      do: raise("the sample step #{key} failed, for a reason this seed does not name")

    defp refused(true, _invariant, _key), do: {:already, nil}

    defp refused(false, invariant, key),
      do: raise("the sample step #{key} was refused #{invariant}")

    defp known(nil), do: "small"
    defp known(""), do: "small"
    defp known(profile) when profile in @profiles, do: profile

    defp known(profile),
      do: raise("no sample profile #{profile}: the seed knows #{Enum.join(@profiles, ", ")}")

    defp config, do: Application.fetch_env!(@app, __MODULE__)

    # EHOS names the environment it runs the seed in: one with no name was run some other way, and
    # could be pointed at any database.
    defp named!(environment) when environment in [nil, ""],
      do: raise("EHOS_ENVIRONMENT names no environment, so the seed does not run")

    defp named!(_environment), do: :ok

    defp refuse_production!(config),
      do: production!(config[:environment] in Keyword.fetch!(config, :production_environments))

    defp production!(false), do: :ok

    defp production!(true),
      do: raise("sample data is an ephemeral environment's, never production's")
  end
  '''

  # What a run says of an ehos.yaml it moves from an earlier version that only added keys.
  @moved_notice """
  ehos.yaml is ehos.yaml/v7 now, which EHOS 0.21 and later deploy; nothing else
  in it changed. It may now say the CPU and memory the workload asks for under
  `needs.compute`.
  """

  # What a run says to an ehos.yaml that declares no `sign_in`.
  @no_sign_in_warning """
  ehos.yaml declares no `sign_in`, so EHOS gives the application nothing to sign people in
  with: it starts, and signs nobody in to its pages. To sign people in, make it
  `schema: ehos.yaml/v7`, point its schema comment at
  deps/ehos_contract_auth/packages/ehos_contract_auth/priv/schemas/ehos.yaml/v7.json,
  and add `sign_in: {}` beside `serves:`.
  """

  # What a run says to an ehos.yaml that names the copy of the schema an earlier version wrote.
  @names_copy_warning """
  ehos.yaml names .ehos/ehos.yaml.v2.json, a copy of EHOS's schema an earlier version wrote, which is
  gone. An editor finds the same schema at deps/ehos_contract_auth/packages/ehos_contract_auth/priv/schemas/ehos.yaml/v2.json: point the comment
  `# yaml-language-server: $schema=` there.
  """

  describe "ehos.yaml" do
    # eh-os D-51's example.
    test "writes what the application needs, as EHOS's schema defines it" do
      igniter = installed()

      assert JSV.validate(ehos_yaml(igniter), schema(igniter)) == {:ok, ehos_yaml(igniter)}

      assert ehos_yaml(igniter) == %{
               "schema" => "ehos.yaml/v7",
               "needs" => %{
                 "database" => %{
                   "engine" => "postgres",
                   "version" => ">= 16",
                   "migrate" => ["/app/bin/migrate"],
                   # The release itself, so it needs no overlay of its own (eh-os D-98).
                   "seed" => ["/app/bin/test", "eval", "Test.Seed.run()"]
                 }
               },
               "serves" => [%{"name" => "web", "port" => 4000, "public" => true}],
               "sign_in" => %{},
               "health" => %{"port" => 4001, "ready" => "/health/ready", "live" => "/health/live"}
             }
    end

    # A release says it produces `EhosApp.ehos_yaml_version/0` (eh-os D-91): EHOS judges from it
    # whether it accepts what this version writes, so it has to be what the installer writes.
    test "writes the version a release says this ehos_app produces, which its schema is" do
      assert ehos_yaml(installed())["schema"] == EhosApp.ehos_yaml_version()
      assert schema_title() == EhosApp.ehos_yaml_version()
    end

    # The template names no compute and no utility service, and says how to ask for each (eh-os
    # D-143, D-175).
    test "asks for no compute and no utility service, and its comment says how to" do
      igniter = installed()

      assert Map.keys(ehos_yaml(igniter)["needs"]) == ["database"]

      assert igniter
             |> content("ehos.yaml")
             |> lines_between(~s|    seed: [/app/bin/test, eval, "Test.Seed.run()"]|, "serves:") ==
               [
                 "  # The CPU and memory its containers ask for. Without it each takes its environment's defaults;",
                 "  # a workload that needs more says so, and a deployment its environment's quota has no room for",
                 "  # is refused. `memory` is also the most a container may use.",
                 "  # compute:",
                 "  #   cpu: 250m",
                 "  #   memory: 1Gi",
                 "  # The utility services it calls, each an entry with the service's name. It takes",
                 "  # `schema: ehos.yaml/v8` and v8.json in the comment above, and EHOS 0.29.0 or later; the",
                 "  # address comes in EHOS_SERVICE_<NAME>_URL once a service agreement holds (ARCHITECTURE.md,",
                 "  # \"Calling a utility service\").",
                 "  # services:",
                 "  #   - name: invoice-converter"
               ]
    end

    test "points editors at the schema ehos_contract_auth carries, and copies none" do
      igniter = installed()

      assert Install.ehos_yaml_schema("v3") ==
               "deps/ehos_contract_auth/packages/ehos_contract_auth/priv/schemas/ehos.yaml/v3.json"

      assert igniter
             |> content("ehos.yaml")
             |> String.split("\n")
             |> Enum.filter(&String.starts_with?(&1, "# yaml-language-server:")) == [
               "# yaml-language-server: $schema=deps/ehos_contract_auth/packages/ehos_contract_auth/priv/schemas/ehos.yaml/v7.json"
             ]

      assert igniter.assigns.test_files
             |> Map.keys()
             |> Enum.filter(&String.starts_with?(&1, ".ehos/")) == []
    end

    test "writes the seed EHOS runs, which runs priv/repo/seeds.exs with the repo and Oban started" do
      assert installed() |> content("lib/test/seed.ex") == @seed
    end

    test "never serves the health port" do
      %{"serves" => serves, "health" => %{"port" => health}} = ehos_yaml(installed())

      assert Enum.filter(serves, &(&1["port"] == health)) == []
    end

    # An `ehos.yaml/v3` an earlier version wrote, with a key of the developer's own, moves to v7:
    # the seed beside `migrate:`, the schema comment's version, and nothing else.
    test "moves an ehos.yaml/v3 to v7, adding the seed beside migrate, and keeps the rest" do
      v3 = """
      # yaml-language-server: $schema=#{Install.ehos_yaml_schema("v3")}
      schema: ehos.yaml/v3
      needs:
        database:
          engine: postgres
          version: ">= 17"
          migrate: [/app/bin/migrate]
        people: read
      serves:
        - name: web
          port: 4000
          public: true
      sign_in: {}
      health:
        port: 4001
        ready: /health/ready
        live: /health/live
      """

      igniter = with_ehos_yaml(v3) |> Igniter.compose_task("ehos_app.install", ["--yes"])
      moved = igniter |> apply_igniter!() |> content("ehos.yaml")

      assert moved ==
               v3
               |> String.replace("ehos.yaml/v3", "ehos.yaml/v7")
               |> String.replace("v3.json", "v7.json")
               |> String.replace(
                 "    migrate: [/app/bin/migrate]\n",
                 "    migrate: [/app/bin/migrate]\n" <>
                   ~s|    seed: [/app/bin/test, eval, "Test.Seed.run()"]\n|
               )

      assert JSV.validate(YamlElixir.read_from_string!(moved), schema(igniter)) ==
               {:ok, YamlElixir.read_from_string!(moved)}

      assert messages_starting(igniter.notices, "ehos.yaml") == [
               """
               ehos.yaml is ehos.yaml/v7 now, which EHOS 0.21 and later deploy, and names
               `needs.database.seed`: Test.Seed.run/0, which runs priv/repo/seeds.exs in an
               ephemeral environment of EHOS only. /ehos-app:sample-data gives a seed the steps
               that record business facts through the contracts, and its test.
               """
             ]

      # The module the seed names is written with it, and a second run changes nothing. Its test
      # is not: a project made before may have commands no step issues yet (ehos-tools#476).
      applied = apply_igniter!(igniter)
      assert content(applied, "lib/test/seed.ex") == @seed
      refute Igniter.exists?(applied, "test/test/seed_test.exs")

      applied
      |> Igniter.compose_task("ehos_app.install", ["--yes"])
      |> assert_unchanged()
    end

    # A v4, v5 or v6 an earlier version wrote, or the developer moved to, keeps every key it has,
    # egress and mail included, and only its version and its schema comment's change (eh-os
    # D-143): each later version only added keys. No seed is added to one that names none.
    # One test per version, so each runs the installer within ExUnit's timeout for a test.
    for {from, needs} <- [
          {"v4", ""},
          {"v5", "  egress:\n    - host: api.example.com\n"},
          {"v6", "  mail:\n    level: internal\n    reply_domains: [reply.example.org]\n"}
        ] do
      test "moves an ehos.yaml/#{from} to v7, changing nothing but its version" do
        {from, needs} = {unquote(from), unquote(needs)}

        older = """
        # yaml-language-server: $schema=#{Install.ehos_yaml_schema(from)}
        # Our own note, which keeps its words: $schema=elsewhere/#{from}.json
        schema: ehos.yaml/#{from}
        needs:
          database:
            engine: postgres
            migrate: [/app/bin/migrate]
        #{needs}serves:
          - name: web
            port: 4000
            public: true
        sign_in: {}
        health:
          port: 4001
          ready: /health/ready
          live: /health/live
        """

        igniter = with_ehos_yaml(older) |> Igniter.compose_task("ehos_app.install", ["--yes"])
        applied = apply_igniter!(igniter)
        moved = content(applied, "ehos.yaml")

        assert moved ==
                 older
                 |> String.replace("schema: ehos.yaml/#{from}\n", "schema: ehos.yaml/v7\n")
                 |> String.replace(Install.ehos_yaml_schema(from), Install.ehos_yaml_schema("v7")),
               from

        assert JSV.validate(YamlElixir.read_from_string!(moved), schema(igniter)) ==
                 {:ok, YamlElixir.read_from_string!(moved)},
               from

        assert messages_starting(igniter.notices, "ehos.yaml") == [@moved_notice], from

        applied
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> assert_unchanged()
      end
    end

    # A `schema:` line with a comment after it, CRLF, and an editor comment pointing at a schema
    # of another name, which is the developer's and keeps its version.
    test "moves a v6 whose schema line carries a comment, with CRLF, and keeps another schema's comment" do
      v6 =
        "# yaml-language-server: $schema=https://example.org/schemas/mine-v6.json\r\n" <>
          "schema: ehos.yaml/v6 # mail since October\r\n" <>
          "sign_in: {}\r\nneeds:\r\n  database:\r\n    migrate: [/app/bin/migrate]\r\n"

      moved =
        with_ehos_yaml(v6)
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()
        |> content("ehos.yaml")

      assert moved == String.replace(v6, "schema: ehos.yaml/v6 #", "schema: ehos.yaml/v7 #")
    end

    test "seeds an ehos.yaml/v3 whose migrate is its last line, with no newline after it" do
      v3 =
        "schema: ehos.yaml/v3\nsign_in: {}\nneeds:\n  database:\n    migrate: [/app/bin/migrate]"

      moved =
        with_ehos_yaml(v3)
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()
        |> content("ehos.yaml")

      assert moved ==
               String.replace(v3, "ehos.yaml/v3", "ehos.yaml/v7") <>
                 ~s|\n    seed: [/app/bin/test, eval, "Test.Seed.run()"]|
    end

    test "keeps the seed an ehos.yaml/v3 names when it moves it to v7" do
      v3 = """
      schema: ehos.yaml/v3
      needs:
        database:
          engine: postgres
          migrate: [/app/bin/migrate]
          seed: [/app/bin/my_seed]
      serves:
        - name: web
          port: 4000
      sign_in: {}
      """

      moved =
        with_ehos_yaml(v3)
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()
        |> content("ehos.yaml")

      assert moved == String.replace(v3, "ehos.yaml/v3", "ehos.yaml/v7")
    end

    # 0.2.0 to 0.8.1 copied EHOS's schema into .ehos/, beside the version the file was in.
    test "removes a copy of the schema an earlier version wrote, and points the comment past it" do
      ehos_yaml =
        "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        with_ehos_yaml(ehos_yaml)
        |> with_schema_copy()
        |> Igniter.compose_task("ehos_app.install", [])

      assert igniter.rms -- [@phoenix_icon] == [".ehos/ehos.yaml.v2.json"]

      assert content(igniter, "ehos.yaml") ==
               "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\n" <>
                 "schema: ehos.yaml/v2\n"

      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "points a CRLF ehos.yaml past the copy, and gives it the header this version writes" do
      crlf = &String.replace(&1, "\n", "\r\n")
      body = "schema: ehos.yaml/v2\n# the developer's own comment, in .ehos/ too\n"

      igniter =
        crlf.(
          @ehos_yaml_header_08 <>
            "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\n" <> body
        )
        |> with_ehos_yaml()
        |> with_schema_copy()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") ==
               crlf.(
                 @ehos_yaml_header <>
                   "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\n" <> body
               )

      assert messages_starting(igniter.warnings, "ehos.yaml names") == []

      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "points a CRLF ehos.yaml past the copy 0.9 removed and left it naming" do
      crlf = &String.replace(&1, "\n", "\r\n")

      igniter =
        crlf.(
          @ehos_yaml_header_08 <>
            "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"
        )
        |> with_ehos_yaml()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") ==
               crlf.(
                 @ehos_yaml_header <>
                   "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\n" <>
                   "schema: ehos.yaml/v2\n"
               )
    end

    test "gives an ehos.yaml 0.9 left without a copy the header this version writes" do
      body =
        "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\nschema: ehos.yaml/v2\n"

      igniter =
        with_ehos_yaml(@ehos_yaml_header_08 <> body)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") == @ehos_yaml_header <> body
    end

    # A v7 is what this version writes: a run says nothing of it.
    test "leaves an ehos.yaml/v7 as it is, and says nothing of it" do
      project = installed() |> apply_igniter!()
      igniter = Igniter.compose_task(project, "ehos_app.install", ["--yes"])

      assert content(apply_igniter!(igniter), "ehos.yaml") == content(project, "ehos.yaml")
      assert messages_starting(igniter.notices ++ igniter.warnings, "ehos.yaml") == []
    end

    # Only a `migrate:` that is one flow sequence on its line, the form every version wrote, gets
    # the seed beside it: another form is said, and left valid YAML.
    test "moves an ehos.yaml/v3 whose migrate is a block sequence to v7, and says how to add the seed" do
      v3 = """
      schema: ehos.yaml/v3
      needs:
        database:
          engine: postgres
          migrate:
            - /app/bin/migrate
      serves:
        - name: web
          port: 4000
      sign_in: {}
      """

      igniter = with_ehos_yaml(v3) |> Igniter.compose_task("ehos_app.install", ["--yes"])
      applied = apply_igniter!(igniter)

      assert content(applied, "ehos.yaml") == String.replace(v3, "ehos.yaml/v3", "ehos.yaml/v7")

      assert igniter.warnings == [
               """
               ehos.yaml is ehos.yaml/v7 now, which EHOS 0.21 and later deploy, but
               names no seed, since its `migrate:` is not one sequence on one line. To seed its
               previews, add under `needs.database`: seed: [/app/bin/test, eval, "Test.Seed.run()"], and that module, as ehos_app's
               priv/templates/ehos_app.install/seed.ex.eex writes it; a later run writes neither.
               """
             ]

      # Nothing would run it, so no module is written for it.
      refute Igniter.exists?(applied, "lib/test/seed.ex")
    end

    # ehos_contract_auth on a commit the project chose may carry no v7 schema, and its manifest
    # task would then refuse the file: nothing is moved, and the developer is told.
    test "keeps an ehos.yaml/v6 while ehos_contract_auth is on a commit it does not know" do
      v6 =
        "schema: ehos.yaml/v6\nsign_in: {}\nneeds:\n  database:\n    migrate: [/app/bin/migrate]\n"

      igniter =
        v6
        |> with_ehos_yaml(&with_unknown_ehos_contract_auth/1)
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert igniter |> apply_igniter!() |> content("ehos.yaml") == v6

      assert messages_starting(igniter.warnings, "ehos.yaml") == [
               """
               ehos.yaml stays ehos.yaml/v6: ehos_contract_auth is on a source or a commit of
               ehos_contract this ehos_app does not know, which may carry no schema of
               ehos.yaml/v7. Once it does, from ehos_contract's release
               #{Install.ehos_contract_release().tag}, make it `schema: ehos.yaml/v7` and point its
               schema comment at deps/ehos_contract_auth/packages/ehos_contract_auth/priv/schemas/ehos.yaml/v7.json to say the CPU and memory the workload asks for
               under `needs.compute`, which only EHOS 0.21 and later deploy.
               """
             ]

      # A v3 still gets v4 and its seed, which every ehos_contract_auth since the seed reads.
      applied =
        v6
        |> String.replace("ehos.yaml/v6", "ehos.yaml/v3")
        |> with_ehos_yaml(&with_unknown_ehos_contract_auth/1)
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()

      assert content(applied, "ehos.yaml") ==
               String.replace(v6, "ehos.yaml/v6", "ehos.yaml/v4") <>
                 ~s|    seed: [/app/bin/test, eval, "Test.Seed.run()"]\n|

      assert content(applied, "lib/test/seed.ex") == @seed
    end

    # A module the developer removed from a project made with one is theirs to keep removed.
    test "brings back no seed module the developer removed" do
      applied =
        installed()
        |> Igniter.rm("lib/test/seed.ex")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()

      refute Igniter.exists?(applied, "lib/test/seed.ex")
    end

    test "keeps a copy of the schema that was changed, and the comment that names it" do
      ehos_yaml =
        "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        with_ehos_yaml(ehos_yaml)
        |> with_file(".ehos/ehos.yaml.v2.json", "{}\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert igniter.rms -- [@phoenix_icon] == []
      assert content(igniter, "ehos.yaml") == ehos_yaml
    end

    test "says where the schema is while ehos.yaml names a copy already gone" do
      ehos_yaml =
        "# yaml-language-server: $schema=./.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter = with_ehos_yaml(ehos_yaml) |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") == ehos_yaml
      assert messages_starting(igniter.warnings, "ehos.yaml names") == [@names_copy_warning]
    end

    test "removes the copy an ehos.yaml names in a form it leaves, and says where the schema is" do
      ehos_yaml =
        "# yaml-language-server: $schema=./.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        with_ehos_yaml(ehos_yaml)
        |> with_schema_copy()
        |> Igniter.compose_task("ehos_app.install", [])

      assert igniter.rms -- [@phoenix_icon] == [".ehos/ehos.yaml.v2.json"]
      assert content(igniter, "ehos.yaml") == ehos_yaml
      assert messages_starting(igniter.warnings, "ehos.yaml names") == [@names_copy_warning]
    end

    test "leaves a file without sign_in alone, and says what signing people in needs of it" do
      v1 = "schema: ehos.yaml/v1\nhealth:\n  port: 4001\n"

      igniter = with_ehos_yaml(v1) |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") == v1
      assert igniter.warnings == [@no_sign_in_warning]
      assert install().warnings == []
    end
  end

  # A test project with an ehos.yaml an earlier version wrote, or the developer changed, on disk.
  defp with_ehos_yaml(ehos_yaml, project \\ & &1) do
    phx_test_project()
    |> project.()
    |> Igniter.create_new_file("ehos.yaml", ehos_yaml)
    |> apply_igniter!()
  end

  # The copy of EHOS's schema 0.2.0 to 0.8.1 wrote, as it wrote it.
  defp with_schema_copy(igniter) do
    with_file(
      igniter,
      ".ehos/ehos.yaml.v2.json",
      File.read!("test/fixtures/schemas/ehos.yaml.v2.json")
    )
  end

  # ehos_contract_auth on a commit of the project's choosing, which this ehos_app does not know.
  defp with_unknown_ehos_contract_auth(igniter) do
    Igniter.Project.Deps.add_dep(
      igniter,
      {:ehos_contract_auth, "~> 0.8.0",
       github: "EmpoweredHouse/ehos_contract",
       sparse: "packages/ehos_contract_auth",
       ref: "ffffffffffffffffffffffffffffffffffffffff"},
      yes?: true
    )
  end

  # The lines of `content` after the line `first` and before the line `last`.
  defp lines_between(content, first, last) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != first))
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != last))
  end
end

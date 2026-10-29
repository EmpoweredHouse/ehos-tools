defmodule Mix.Tasks.EhosApp.InstallTest.EhosYaml do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "ehos.yaml" do
    test "is valid against the schema EHOS defines it by, and is D-51's example" do
      igniter = installed()

      assert {:ok, _} = JSV.validate(ehos_yaml(igniter), schema(igniter))

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
    test "is the version a release says this ehos_app produces, as is its schema" do
      assert ehos_yaml(installed())["schema"] == EhosApp.ehos_yaml_version()
      assert schema_title() == EhosApp.ehos_yaml_version()
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

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

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

      assert {:ok, _} = JSV.validate(YamlElixir.read_from_string!(moved), schema(igniter))
      assert Enum.any?(igniter.notices, &(&1 =~ "ehos.yaml is ehos.yaml/v7 now"))

      # The module the seed names is written with it, and a second run changes nothing.
      applied = apply_igniter!(igniter)
      assert content(applied, "lib/test/seed.ex") =~ "defmodule Test.Seed do"

      applied
      |> Igniter.compose_task("ehos_app.install", ["--yes"])
      |> assert_unchanged()
    end

    # A v4, v5 or v6 an earlier version wrote, or the developer moved to, keeps every key it has,
    # egress and mail included, and only its version and its schema comment's change (eh-os
    # D-143): each later version only added keys. No seed is added to one that names none.
    test "moves an ehos.yaml/v4, v5 or v6 to v7, changing nothing but its version" do
      for {from, needs} <- [
            {"v4", ""},
            {"v5", "  egress:\n    - host: api.example.com\n"},
            {"v6", "  mail:\n    level: internal\n    reply_domains: [reply.example.org]\n"}
          ] do
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

        igniter =
          phx_test_project()
          |> Igniter.create_new_file("ehos.yaml", older)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", ["--yes"])

        applied = apply_igniter!(igniter)
        moved = content(applied, "ehos.yaml")

        assert moved ==
                 older
                 |> String.replace("schema: ehos.yaml/#{from}\n", "schema: ehos.yaml/v7\n")
                 |> String.replace(Install.ehos_yaml_schema(from), Install.ehos_yaml_schema("v7")),
               from

        assert {:ok, _} = JSV.validate(YamlElixir.read_from_string!(moved), schema(igniter))

        assert Enum.any?(
                 igniter.notices,
                 &(&1 =~
                     "ehos.yaml is ehos.yaml/v7 now, which EHOS 0.21 and later deploy; nothing else")
               )

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
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v6)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()
        |> content("ehos.yaml")

      assert moved == String.replace(v6, "schema: ehos.yaml/v6 #", "schema: ehos.yaml/v7 #")
    end

    # A v7 is what this version writes: a run says nothing of it.
    test "leaves an ehos.yaml/v7 as it is, and says nothing of it" do
      project = installed() |> apply_igniter!()
      igniter = Igniter.compose_task(project, "ehos_app.install", ["--yes"])

      assert content(apply_igniter!(igniter), "ehos.yaml") == content(project, "ehos.yaml")

      refute Enum.any?(igniter.notices ++ igniter.warnings, &(&1 =~ "ehos.yaml is ehos.yaml/v7"))
    end

    # eh_os_contract_auth on a commit the project chose may carry no v7 schema, and its manifest
    # task would then refuse the file: nothing is moved, and the developer is told.
    test "keeps an ehos.yaml/v6 while eh_os_contract_auth is on a commit it does not know" do
      dep =
        {:eh_os_contract_auth, "~> 0.8.0",
         github: "EmpoweredHouse/eh-os-contract",
         sparse: "packages/eh_os_contract_auth",
         ref: "ffffffffffffffffffffffffffffffffffffffff"}

      v6 =
        "schema: ehos.yaml/v6\nsign_in: {}\nneeds:\n  database:\n    migrate: [/app/bin/migrate]\n"

      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(dep, yes?: true)
        |> Igniter.create_new_file("ehos.yaml", v6)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      assert igniter |> apply_igniter!() |> content("ehos.yaml") == v6
      assert Enum.any?(igniter.warnings, &(&1 =~ "ehos.yaml stays ehos.yaml/v6"))
      assert Enum.any?(igniter.warnings, &(&1 =~ "make it `schema: ehos.yaml/v7` and point"))

      # A v3 still gets v4 and its seed, which every eh_os_contract_auth since the seed reads.
      v3 = String.replace(v6, "ehos.yaml/v6", "ehos.yaml/v3")

      applied =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(dep, yes?: true)
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()

      assert content(applied, "ehos.yaml") ==
               String.replace(v6, "ehos.yaml/v6", "ehos.yaml/v4") <>
                 ~s|    seed: [/app/bin/test, eval, "Test.Seed.run()"]\n|

      assert content(applied, "lib/test/seed.ex") =~ "defmodule Test.Seed do"
    end

    # The template names no compute, and says how to ask for it (eh-os D-143).
    test "names no compute, and its comment says how to ask for it" do
      igniter = installed()

      refute Map.has_key?(ehos_yaml(igniter)["needs"], "compute")
      assert content(igniter, "ehos.yaml") =~ "  # compute:\n  #   cpu: 250m\n  #   memory: 1Gi\n"
    end

    test "seeds an ehos.yaml/v3 whose migrate is its last line, with no newline after it" do
      v3 =
        "schema: ehos.yaml/v3\nsign_in: {}\nneeds:\n  database:\n    migrate: [/app/bin/migrate]"

      moved =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
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
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])
        |> apply_igniter!()
        |> content("ehos.yaml")

      assert moved == String.replace(v3, "ehos.yaml/v3", "ehos.yaml/v7")
    end

    test "writes the seed EHOS runs, which runs priv/repo/seeds.exs with the project's repo started" do
      seed = installed() |> content("lib/test/seed.ex")

      assert seed =~ "defmodule Test.Seed do"
      assert seed =~ "Ecto.Migrator.with_repo(Test.Repo, fn _repo ->"
      assert seed =~ ~s|Application.app_dir(@app, "priv/repo/seeds.exs")|
      assert seed =~ "EHOS_SEED_PROFILE"
      assert seed =~ "no real data, no\n    credentials and no secrets"
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

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v3)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--yes"])

      applied = apply_igniter!(igniter)

      assert content(applied, "ehos.yaml") == String.replace(v3, "ehos.yaml/v3", "ehos.yaml/v7")
      assert Enum.any?(igniter.warnings, &(&1 =~ "names no seed, since its `migrate:`"))
      # Nothing would run it, so no module is written for it.
      refute Igniter.exists?(applied, "lib/test/seed.ex")
    end

    # A module the developer removed from a project made with one is theirs to keep removed.
    test "brings back no seed module the developer removed" do
      project = installed()

      project
      |> Igniter.rm("lib/test/seed.ex")
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", ["--yes"])
      |> apply_igniter!()
      |> then(&refute(Igniter.exists?(&1, "lib/test/seed.ex")))
    end

    test "points editors at the schema eh_os_contract_auth carries, and copies none" do
      igniter = installed()

      assert Install.ehos_yaml_schema("v3") ==
               "deps/eh_os_contract_auth/packages/eh_os_contract_auth/priv/schemas/ehos.yaml/v3.json"

      assert content(igniter, "ehos.yaml") =~
               "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v7")}\n"

      refute Enum.any?(Map.keys(igniter.assigns.test_files), &String.starts_with?(&1, ".ehos/"))
    end

    # 0.2.0 to 0.8.1 copied EHOS's schema into .ehos/, beside the version the file was in.
    test "removes a copy of the schema an earlier version wrote, and points the comment past it" do
      v2 = File.read!("test/fixtures/schemas/ehos.yaml.v2.json")

      ehos_yaml =
        "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", ehos_yaml)
        |> apply_igniter!()
        |> with_file(".ehos/ehos.yaml.v2.json", v2)
        |> Igniter.compose_task("ehos_app.install", [])

      assert ".ehos/ehos.yaml.v2.json" in igniter.rms

      assert content(igniter, "ehos.yaml") ==
               "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\n" <>
                 "schema: ehos.yaml/v2\n"

      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "keeps a copy of the schema that was changed, and the comment that names it" do
      ehos_yaml =
        "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", ehos_yaml)
        |> apply_igniter!()
        |> with_file(".ehos/ehos.yaml.v2.json", "{}\n")
        |> Igniter.compose_task("ehos_app.install", [])

      refute ".ehos/ehos.yaml.v2.json" in igniter.rms
      assert content(igniter, "ehos.yaml") == ehos_yaml
    end

    # The comment on top of every ehos.yaml 0.2.0 to 0.8.1 wrote.
    @ehos_yaml_header_08 """
    # What this application needs from EHOS in order to run, and nothing about how EHOS provides
    # it. EHOS defines this format: the schema beside it, in .ehos/, is a copy of the one it
    # publishes, and https://github.com/empoweredhouse/eh-os/blob/main/docs/ehos-yaml.md explains
    # every field. The application's name is its contract domain's, so it is not written here.
    """

    test "points a CRLF ehos.yaml past the copy, and gives it the header this version writes" do
      v2 = File.read!("test/fixtures/schemas/ehos.yaml.v2.json")

      [header, _] =
        installed() |> content("ehos.yaml") |> String.split("# yaml-language-server:", parts: 2)

      crlf = &String.replace(&1, "\n", "\r\n")
      body = "schema: ehos.yaml/v2\n# the developer's own comment, in .ehos/ too\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "ehos.yaml",
          crlf.(
            @ehos_yaml_header_08 <>
              "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\n" <> body
          )
        )
        |> apply_igniter!()
        |> with_file(".ehos/ehos.yaml.v2.json", v2)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") ==
               crlf.(
                 header <>
                   "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\n" <> body
               )

      refute Enum.any?(igniter.warnings, &(&1 =~ "ehos.yaml names"))

      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "points a CRLF ehos.yaml past the copy 0.9 removed and left it naming" do
      [header, _] =
        installed() |> content("ehos.yaml") |> String.split("# yaml-language-server:", parts: 2)

      crlf = &String.replace(&1, "\n", "\r\n")

      igniter =
        phx_test_project()
        |> Igniter.create_new_file(
          "ehos.yaml",
          crlf.(
            @ehos_yaml_header_08 <>
              "# yaml-language-server: $schema=.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") ==
               crlf.(
                 header <>
                   "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\n" <>
                   "schema: ehos.yaml/v2\n"
               )
    end

    test "gives an ehos.yaml 0.9 left without a copy the header this version writes" do
      [header, _] =
        installed() |> content("ehos.yaml") |> String.split("# yaml-language-server:", parts: 2)

      body =
        "# yaml-language-server: $schema=#{Install.ehos_yaml_schema("v2")}\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", @ehos_yaml_header_08 <> body)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") == header <> body
    end

    test "keeps saying so while ehos.yaml names a copy already gone" do
      ehos_yaml =
        "# yaml-language-server: $schema=./.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", ehos_yaml)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") == ehos_yaml
      assert_has_warning(igniter, &(&1 =~ "ehos.yaml names .ehos/ehos.yaml.v2.json"))
    end

    test "says so when ehos.yaml still names the copy it removed" do
      v2 = File.read!("test/fixtures/schemas/ehos.yaml.v2.json")

      ehos_yaml =
        "# yaml-language-server: $schema=./.ehos/ehos.yaml.v2.json\nschema: ehos.yaml/v2\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", ehos_yaml)
        |> apply_igniter!()
        |> with_file(".ehos/ehos.yaml.v2.json", v2)
        |> Igniter.compose_task("ehos_app.install", [])

      assert ".ehos/ehos.yaml.v2.json" in igniter.rms
      assert content(igniter, "ehos.yaml") == ehos_yaml

      assert_has_warning(
        igniter,
        &(&1 =~ "ehos.yaml names .ehos/ehos.yaml.v2.json" and
            &1 =~ Install.ehos_yaml_schema("v2"))
      )
    end

    test "leaves a file without sign_in alone, and says what signing people in needs of it" do
      v1 = "schema: ehos.yaml/v1\nhealth:\n  port: 4001\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", v1)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ehos.yaml") == v1
      assert Enum.any?(igniter.warnings, &(&1 =~ "add `sign_in: {}`"))
      refute Enum.any?(installed_with_warnings(), &(&1 =~ "sign_in"))
    end

    test "never serves the health port" do
      %{"serves" => serves, "health" => %{"port" => health}} = ehos_yaml(installed())
      refute health in Enum.map(serves, & &1["port"])
    end
  end

  defp installed_with_warnings, do: install() |> Map.fetch!(:warnings)
end

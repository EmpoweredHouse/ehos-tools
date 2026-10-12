defmodule Mix.Tasks.EhosApp.Install.Docs do
  @moduledoc false

  def short_doc, do: "Turns a Phoenix project into an application EHOS can govern"

  def example, do: "mix igniter.install ehos_app --example"

  def long_doc do
    """
    #{short_doc()}

    What it adds to the project:

      * `eh_os_contract` and `eh_os_contract_auth`, wired the way their READMEs prescribe:
        config, their migrations, the contract compiler, and supervision children after the
        repo and Oban (Oban through its own installer)
      * `eh_os_contract.check` in the `precommit` alias
      * the health endpoints EHOS probes, on a port of their own
      * `ehos.yaml`, what EHOS is asked for, in the newest version EHOS defines
      * configuration from the variables EHOS gives an application at start
      * `ehos_design`, the EmpoweredHouse design system, as the default look: its layer
        imported in `assets/css/app.css` in place of Phoenix's daisyUI themes, and its fonts
        served by the endpoint. Declined once, by the comment above its import, it is never
        added back
      * a release and a Dockerfile, through `mix phx.gen.release --docker`, which reads the
        private `eh_os_contract` and `ehos_design` through a BuildKit secret
      * a GitHub Actions workflow: the gates, then the image by digest and the manifest
      * `.tool-versions`, pinning the Erlang and Elixir the project was generated with
      * the agent harness: `AGENTS.md` (Phoenix's own moves to `docs/phoenix.md`), with
        nested ones for the contracts and the web layer, `VISION.md`, `ARCHITECTURE.md`,
        `TESTING.md`, a `README.md`, `.claude/settings.json` enabling the `ehos-app` plugin
        and its skills, a CodeRabbit configuration, a pull request template, and
        `test/harness_test.exs`, which keeps the docs honest

    ## Example

    ```sh
    #{example()}
    ```

    ## Options

      * `--example` - also generate an example domain and contract, served under `/api`,
        so the tests, `eh_os_contract.check` and the manifest have something to read on day
        one, and a page at `/design-system` that shows the design system
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.EhosApp.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias EhosApp.Toolchain

    require Igniter.Code.Function

    # T-11: both packages are pinned to eh-os-contract's release by the commit its tag names, not
    # the tag, which nothing here stops being moved, and a later release reaches a project with a
    # release of ehos_app. `test/eh_os_contract_release_test.exs` holds the commit to the tag.
    # They are not on Hex, and Igniter's `pkg@github:` spec has no `sparse:`, so the installer
    # adds them rather than the `igniter.new` command line. `eh_os_contract_auth` names the engine
    # by git without a ref, so the engine is overridden to the same one. The requirements are
    # checked against each package's own `mix.exs` when the project compiles (not by
    # `deps.get`).
    @eh_os_contract_release "v0.3.0"
    @eh_os_contract_ref "3304f355eb5d73058fa8fcf61813f9c0547f9fc6"
    # The first commit with the browser-session Plug that signs people in through EHOS
    # (https://github.com/EmpoweredHouse/eh-os-contract/issues/78): what a project on a commit
    # of its own needs at least.
    @eh_os_contract_minimum "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb"
    # The commits earlier versions pinned: 0.3.0's and 0.4.0's, the one before 0.2.0, and 0.2's.
    # A project on one of them, or on `main`, which 0.5.0 to 0.6.1 followed (T-05), is moved to
    # the release; a project on any other commit or branch chose it, and keeps it.
    @earlier_eh_os_contract_refs [
      "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb",
      "6df5bc7880bfecc4348ea33fdb080eeb4fdb7a4a",
      "50eb7711c3235325834535d7d24239855c0e63d8"
    ]
    # The requirements are EhosApp.requires/0's, which a release's `release.json` says too.
    @eh_os_contract {:eh_os_contract, Map.fetch!(EhosApp.requires(), "eh_os_contract"),
                     github: "EmpoweredHouse/eh-os-contract",
                     sparse: "packages/eh_os_contract",
                     ref: @eh_os_contract_ref,
                     override: true}
    @eh_os_contract_auth {:eh_os_contract_auth,
                          Map.fetch!(EhosApp.requires(), "eh_os_contract_auth"),
                          github: "EmpoweredHouse/eh-os-contract",
                          sparse: "packages/eh_os_contract_auth",
                          ref: @eh_os_contract_ref}

    # Where the contract DSL reference is inside the generated project. A `sparse:` git
    # dependency keeps its subdirectory under `deps/<name>/`, so the path follows it.
    @contract_docs Path.join([
                     "deps",
                     "eh_os_contract",
                     @eh_os_contract |> elem(2) |> Keyword.fetch!(:sparse),
                     "docs",
                     "contract.md"
                   ])

    # The ports the endpoints listen on and `ehos.yaml` declares. EHOS gives no `PORT`: it
    # reads these from `ehos.yaml` (eh-os D-56), so both come from here.
    @web_port 4000
    @health_port 4001

    # Where the other parts' docs are inside the generated project. `ehos_app` itself is a
    # `sparse:` git dependency of `packages/ehos_app` (`Ehosctl.Template`), in `:dev` only.
    @auth_readme Path.join([
                   "deps",
                   "eh_os_contract_auth",
                   @eh_os_contract_auth |> elem(2) |> Keyword.fetch!(:sparse),
                   "README.md"
                 ])
    @ehos_app_readme "deps/ehos_app/packages/ehos_app/README.md"

    # Where an editor finds the schema of `ehos.yaml`: in `eh_os_contract_auth`, which carries
    # every version EHOS defines, unchanged, and checks the file against it when it generates
    # the manifest. The project carries no copy, so a later version arrives with the release of
    # eh-os-contract a later `ehos_app` pins, and the comment names the version the file is in.
    @ehos_yaml_schemas Path.join([
                         "deps",
                         "eh_os_contract_auth",
                         @eh_os_contract_auth |> elem(2) |> Keyword.fetch!(:sparse),
                         "priv",
                         "schemas",
                         "ehos.yaml"
                       ])

    # The copies of EHOS's schema 0.2.0 to 0.8.1 wrote into `.ehos/`, by the SHA-256 of each:
    # EHOS never changes a released version, so a copy that is not one of these was changed
    # in the project, and stays.
    @ehos_yaml_schema_copies %{
      ".ehos/ehos.yaml.v1.json" =>
        "5dd7ad3491607ea9c8566740c7b7e182923b098dfee219c0be3f2372e36b515b",
      ".ehos/ehos.yaml.v2.json" =>
        "de533072d4c617aee4dfdaee71cf736feed2939a7446e8a52ee8d96879788c38"
    }

    # The EmpoweredHouse design system, the application's default look (eh-os D-72). It is
    # not on Hex, and lives in a subdirectory of ehos-tools, hence `sparse:`. Pinned to the
    # commit tagged `ehos_design-v0.2.0` rather than to the tag, which nothing stops being
    # moved, as eh_os_contract is (T-11). The
    # requirement is checked against the package's own
    # `mix.exs` when the project compiles (not by `deps.get`), so a commit of another minor
    # version fails there.
    @ehos_design {:ehos_design, Map.fetch!(EhosApp.requires(), "ehos_design"),
                  github: "EmpoweredHouse/ehos-tools",
                  sparse: "packages/ehos_design",
                  ref: "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6"}

    # Where the design system is inside the generated project. A `sparse:` git dependency
    # keeps its subdirectory under `deps/<name>/`, so the path follows it.
    @design_system Path.join([
                     "deps",
                     "ehos_design",
                     @ehos_design |> elem(2) |> Keyword.fetch!(:sparse)
                   ])

    # Where `assets/css/app.css` imports the design system's layer from, relative to itself.
    @design_system_css Path.join(["..", "..", @design_system, "priv", "css", "ehos_design.css"])

    # Where Tailwind reads the design system's components' templates from, for the utilities
    # they use (eh-os D-86), relative to `assets/css/app.css`.
    @design_system_lib Path.join(["..", "..", @design_system, "lib"])

    # The skills reach the project as the `ehos-app` plugin of ehos-tools' marketplace, which
    # `.claude/settings.json` enables at the tag of its release (T-15), so an upgrade of the
    # plugin reaches every project through that one line. A test holds the tag to the version in
    # `plugins/ehos-app/.claude-plugin/plugin.json`.
    @marketplace "ehos-tools"
    @plugin "ehos-app"
    @plugin_ref "ehos-app-v0.1.0"
    @plugin_repo "EmpoweredHouse/ehos-tools"
    @plugin_version @plugin_ref |> String.replace_prefix(@plugin <> "-v", "") |> Version.parse!()

    # The skills 0.3.0 to 0.8.1 copied into `.agents/skills/` and linked from `.claude/skills/`,
    # each file by the SHA-256 of every version of it they wrote. A copy that is still one of
    # them is the template's, and is removed now that the plugin carries the skills; one the
    # developer changed, and any file of their own beside it, is theirs, and stays.
    @released_skills %{
      "elixir-anti-patterns-review/LICENSE" => [
        "59899c6091b540582ed617e8eeaac4919dc985ccfc35459ee9752b699be5205b"
      ],
      "elixir-anti-patterns-review/SKILL.md" => [
        "d045321a33780d408cc2a69369977a814e7abebd61cb632342d8479f3b7e7d90"
      ],
      "elixir-anti-patterns-review/references/code.md" => [
        "c506ce81ad73a29f2b60a9d022ebf5c9c4d65c652b7168ef7ee57fdc6a7ee113"
      ],
      "elixir-anti-patterns-review/references/design.md" => [
        "6736bb359a8ceab88d178af3c307a2a211baa5c9267961098c65bea0cb1dec78"
      ],
      "elixir-anti-patterns-review/references/macros.md" => [
        "3662dfbaff0e049df5cae3e9b7f60af9a835410f95414a6665aead7ba9eaba63"
      ],
      "elixir-anti-patterns-review/references/process.md" => [
        "58479e403cbda52fa4eb7d3cc050c7726767dbd5249882b5ccaee2f1cd98a067"
      ],
      "plan/SKILL.md" => ["43aba2b02ad2b84c08a05946fff84e490a56909dbf031126555ecb2a9e8d2c94"],
      "review/SKILL.md" => ["cac936bfff7fc1abc17f7803bb53fbeea816492bae0cda554f4039775359691c"],
      "review/references/checklist.md" => [
        "e745d44926d72e8d922508c6a18386862c12cd70257531fb37e44ae98f80a334"
      ],
      "ship/SKILL.md" => [
        "ad1778acc80989d28c1b6eef6a885a910809f32a121b0a914f25e625b154effd",
        "be5c943a078ffdfbc94ec871dbaf8f8a2d35ef7c23c3c319aaab226255cc2712"
      ]
    }

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ehos,
        example: __MODULE__.Docs.example(),
        # Oban ships its own installer. Composing it keeps its config, migration and
        # supervision child Oban's to change, rather than a copy of them here.
        installs: [{:oban, "~> 2.20"}],
        schema: [example: :boolean],
        defaults: [example: false]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      # The repo is discovered rather than assumed to be `<App>.Repo`: on an existing
      # project it may be called anything, and a guessed name would configure the engine
      # with a module that does not exist and crash the application at boot.
      case Igniter.Libs.Ecto.select_repo(igniter,
             label: "Which repo should the contract engine use?"
           ) do
        {igniter, nil} ->
          Igniter.add_issue(igniter, """
          No Ecto repo found. ehos_app needs one: the contract engine keeps its event log
          in the application's database. Generate the project with a database, or add a repo,
          and run the installer again.
          """)

        {igniter, repo} ->
          install(igniter, repo)
      end
    end

    @doc "eh-os-contract's release the installer pins, and the commit its tag names (T-11)."
    @spec eh_os_contract_release() :: %{tag: String.t(), commit: String.t()}
    def eh_os_contract_release, do: %{tag: @eh_os_contract_release, commit: @eh_os_contract_ref}

    @doc "The contract DSL reference, relative to the generated project's root."
    @spec contract_docs() :: String.t()
    def contract_docs, do: @contract_docs

    @doc "Where the design system is, relative to the generated project's root."
    @spec design_system() :: String.t()
    def design_system, do: @design_system

    @doc "The ports of the web endpoint and of the health endpoints."
    @spec ports() :: %{web: pos_integer(), health: pos_integer()}
    def ports, do: %{web: @web_port, health: @health_port}

    @doc """
    Where, in the project, the schema of a version of `ehos.yaml` is: `"v3"` for
    `ehos.yaml/v3`.
    """
    @spec ehos_yaml_schema(String.t()) :: String.t()
    def ehos_yaml_schema(version), do: Path.join(@ehos_yaml_schemas, version <> ".json")

    @doc """
    The application's name in EHOS, which is its contract domain's name: the OTP
    application's name with dashes, since EHOS allows no underscore in it.
    """
    @spec ehos_name(atom()) :: String.t()
    def ehos_name(app), do: app |> to_string() |> String.replace("_", "-")

    defp install(igniter, repo) do
      app = Igniter.Project.Application.app_name(igniter)
      web = Igniter.Libs.Phoenix.web_module(igniter)
      health = Module.concat(web, Health)
      endpoint = Module.concat(web, Endpoint)
      name = ehos_name(app)

      # Read before the dependencies are raised or a migration generated.
      pins = contract_pins(igniter)
      upgrade? = verifier_behind?(igniter, repo)
      # Every version of the installer wrote `ehos.yaml`: a project with one was made before.
      generated? = Igniter.exists?(igniter, "ehos.yaml")

      igniter
      |> contract_deps(pins)
      |> installer_for_development_only()
      |> contract_compiler()
      |> Igniter.Project.Config.configure_new("config.exs", :eh_os_contract, [:applications], [
        app
      ])
      |> Igniter.Project.Config.configure_new("config.exs", :eh_os_contract, [:repo], repo)
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        :eh_os_contract,
        [:authorizer],
        EhOsContract.Auth
      )
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        app,
        [endpoint, :http, :port],
        @web_port
      )
      |> Igniter.Project.Config.configure_new("config.exs", app, [health, :port], @health_port)
      |> auth_config("dev.exs", "https://ehos.localhost", "#{name}/dev")
      |> auth_config("test.exs", "https://ehos.test", "#{name}/test")
      |> Igniter.Project.Config.configure_new("test.exs", :eh_os_contract_auth, [:pin_keys], true)
      |> Igniter.Project.Config.configure_new(
        "test.exs",
        :eh_os_contract,
        [:subscriptions],
        :manual
      )
      |> Igniter.Project.Config.configure_new("test.exs", app, [health, :server], false)
      |> runtime_config(app, repo)
      |> migrations(repo, upgrade?)
      |> oban_prefix(app)
      # At boot the engine writes the deployment row through the repo and reads the
      # handlers Oban runs, so it starts after both; the key store reads its table through
      # the engine's repo; and nothing is probed ready before both are up.
      |> Igniter.Project.Application.add_new_child(EhOsContract, after: [repo, Oban])
      |> Igniter.Project.Application.add_new_child(health, after: [EhOsContract])
      |> Igniter.Project.Application.add_new_child(
        {EhOsContract.Auth,
         {:code, quote(do: Application.get_env(unquote(app), EhOsContract.Auth, []))}},
        after: [EhOsContract]
      )
      |> sign_in(app, web, endpoint)
      |> endpoint_last(endpoint)
      |> Igniter.Project.TaskAliases.add_alias(:precommit, "eh_os_contract.check",
        if_exists: :append
      )
      |> create_module(health, "health.ex", module: health, app: app)
      |> create_test(health, "health_test.exs", module: health)
      |> write_template("ehos.yaml", "ehos.yaml",
        web_port: @web_port,
        health_port: @health_port,
        version: EhosApp.ehos_yaml_version(),
        schema: current_schema()
      )
      |> older_ehos_yaml()
      |> retire_schema_copies()
      |> write_template("rel_env.sh", "rel/env.sh.eex", [])
      |> license(generated?)
      |> ci_workflow()
      |> tool_versions()
      |> design_system(app, endpoint)
      |> harness(app, web, igniter.args.options[:example])
      |> example(igniter.args.options[:example], app, web)
      |> release()
      |> Igniter.add_notice("""
      EHOS: the project is ready. Start a database, then:

          mix ecto.setup
          mix precommit

      eh_os_contract and ehos_design are read from private repositories. Build the image
      with a GitHub token that can read both, as a build secret. Every dependency's mix.exs
      runs where the token is, so prefer a fine-grained token that can read those two
      repositories alone to the one `gh auth token` prints:

          GITHUB_TOKEN=<the token> docker build --secret id=github_token,env=GITHUB_TOKEN .

      The CI workflow reads them through a GitHub App installed on eh-os-contract and
      ehos-tools with read access to their contents. Give the repository the App's ID and
      private key:

          gh secret set EHOS_CI_APP_ID --body <the App's ID>
          gh secret set EHOS_CI_APP_PRIVATE_KEY < <the App's private key>.pem
      """)
    end

    defp auth_config(igniter, file, issuer, audience) do
      igniter
      |> Igniter.Project.Config.configure_new(file, :eh_os_contract_auth, [:issuer], issuer)
      |> Igniter.Project.Config.configure_new(file, :eh_os_contract_auth, [:audience], audience)
    end

    # `igniter.new --install` adds this package to the project it installs into. Nothing in
    # it runs in the application: it is needed only to run the installer again, which is how
    # a project takes a later version (ehos-tools T-02), so CI and the image never fetch it.
    defp installer_for_development_only(igniter) do
      if Igniter.Project.Deps.has_dep?(igniter, :ehos_app) do
        igniter
        |> Igniter.Project.Deps.set_dep_option(:ehos_app, :only, :dev)
        |> Igniter.Project.Deps.set_dep_option(:ehos_app, :runtime, false)
      else
        igniter
      end
    end

    # The rules between a contract, its domain and its siblings record no compile
    # dependency, so the engine checks them as a Mix compiler after Elixir's.
    defp contract_compiler(igniter) do
      Igniter.Project.MixProject.update(igniter, :project, [:compilers], fn
        nil ->
          {:ok, {:code, quote(do: Mix.compilers() ++ [:eh_os_contract])}}

        zipper ->
          compilers = Sourceror.Zipper.node(zipper)

          if Sourceror.to_string(compilers) =~ ":eh_os_contract" do
            {:ok, zipper}
          else
            {:ok, {:code, append_compiler(compilers)}}
          end
      end)
    end

    # `++` is right-associative, so the compiler goes at the end of its rightmost operand:
    # `[:phoenix_live_view] ++ Mix.compilers() ++ [:eh_os_contract]`, without parentheses.
    defp append_compiler({:++, meta, [left, right]}),
      do: {:++, meta, [left, append_compiler(right)]}

    defp append_compiler(compilers), do: quote(do: unquote(compilers) ++ [:eh_os_contract])

    defp runtime_config(igniter, app, repo) do
      path = "config/runtime.exs"

      if Igniter.exists?(igniter, path) do
        igniter
        |> drop_port(path)
        |> ehos_runtime(path, "EHOS_ISSUER", render("runtime_prod.exs", app: app, repo: repo))
        |> ehos_runtime(path, "EHOS_CLIENT_ID", render("runtime_sign_in.exs", app: app))
      else
        Igniter.add_warning(igniter, """
        config/runtime.exs was not found, so the application is not configured from the
        variables EHOS gives it at start. Add the block in
        #{Path.join(:code.priv_dir(:ehos_app), "templates/ehos_app.install/runtime_prod.exs.eex")}
        to its `config_env() == :prod` section.
        """)
      end
    end

    # Phoenix 1.8 reads the endpoint's port from `PORT` in every environment. EHOS gives
    # none, and the port is the one `ehos.yaml` declares, set in config.exs.
    defp drop_port(igniter, path) do
      Igniter.update_elixir_file(igniter, path, fn zipper ->
        case Igniter.Code.Function.move_to_function_call(zipper, :config, 3, &reads_port?/1) do
          {:ok, call} ->
            {:ok, Sourceror.Zipper.remove(call)}

          :error ->
            if Sourceror.to_string(Sourceror.Zipper.root(zipper)) =~ ~s|"PORT"|,
              do:
                {:warning,
                 "config/runtime.exs reads `PORT`, which EHOS does not set: the endpoint " <>
                   "listens on port #{@web_port}, the port `ehos.yaml` declares."},
              else: {:ok, zipper}
        end
      end)
    end

    defp reads_port?(zipper) do
      zipper |> Sourceror.Zipper.node() |> Sourceror.to_string() =~ ~s|System.get_env("PORT"|
    end

    # A block goes in once: `marker`, a variable it reads, says it is there.
    defp ehos_runtime(igniter, path, marker, block) do
      Igniter.update_elixir_file(igniter, path, fn zipper ->
        if Sourceror.to_string(Sourceror.Zipper.root(zipper)) =~ marker do
          {:ok, zipper}
        else
          zipper
          |> Igniter.Code.Common.move_to_cursor_match_in_scope([
            "if config_env() == :prod do\n  __cursor__()\nend"
          ])
          |> case do
            {:ok, zipper} ->
              {:ok,
               zipper
               |> Sourceror.Zipper.rightmost()
               |> Igniter.Code.Common.add_code(block, placement: :after)}

            :error ->
              {:warning,
               "config/runtime.exs has no `config_env() == :prod` block, so the " <>
                 "application is not configured from the variables EHOS gives it:\n\n" <> block}
          end
        end
      end)
    end

    # The verifier's tables at version 3, which holds the people signed in through EHOS. A new
    # project's migration names it, so a later version of the package adds a migration of its
    # own, as the package prescribes. A project whose migration went to an earlier version, or
    # to whichever was current when it ran (`up()`, as 0.2 wrote it), adds one for version 3.
    @verifier_version 3

    defp migrations(igniter, repo, upgrade?) do
      igniter
      |> migration(repo, "add_eh_os_contract", "EhOsContract.Migrations")
      |> migration(
        repo,
        "add_eh_os_contract_auth",
        "EhOsContract.Auth.Migrations",
        "version: #{@verifier_version}",
        ""
      )
      |> then(fn igniter ->
        if upgrade?,
          do:
            migration(
              igniter,
              repo,
              "upgrade_eh_os_contract_auth_to_v#{@verifier_version}",
              "EhOsContract.Auth.Migrations",
              "version: #{@verifier_version}",
              "version: #{@verifier_version}"
            ),
          else: igniter
      end)
    end

    defp migration(igniter, repo, name, module, up_args \\ "", down_args \\ "") do
      Igniter.Libs.Ecto.gen_migration(igniter, repo, name,
        body: """
        def up, do: #{module}.up(#{up_args})

        def down, do: #{module}.down(#{down_args})
        """,
        timestamp: migration_timestamp(igniter),
        on_exists: :skip
      )
    end

    # Oban's installer runs first and generates its migration in the same second, and
    # Ecto refuses two migrations with one version. The engine's jobs run on Oban's
    # tables, so its migration goes strictly after the newest one there is.
    defp migration_timestamp(igniter) do
      latest =
        igniter
        |> Igniter.include_glob("priv/*/migrations/*.exs")
        |> Map.fetch!(:rewrite)
        |> Enum.map(&Rewrite.Source.get(&1, :path))
        |> Enum.flat_map(&migration_version/1)
        |> Enum.max(NaiveDateTime, fn -> nil end)

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      if latest && NaiveDateTime.compare(latest, now) != :lt do
        latest |> NaiveDateTime.add(1) |> Calendar.strftime("%Y%m%d%H%M%S")
      else
        Calendar.strftime(now, "%Y%m%d%H%M%S")
      end
    end

    defp migration_version(path) do
      with <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "_",
             _::binary>> <- Path.basename(path),
           {:ok, version} <- NaiveDateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}") do
        [version]
      else
        _ -> []
      end
    end

    # Oban's migration names `public` in every statement unless given a prefix, and its
    # installer takes none. EHOS gives the application a schema of its own, which its owner
    # may use but not create (eh-os D-54), so the migration puts Oban's tables where Oban's
    # configuration will look for them.
    defp oban_prefix(igniter, app) do
      igniter = Igniter.include_glob(igniter, "priv/*/migrations/*_add_oban.exs")

      igniter.rewrite
      |> Enum.map(&Rewrite.Source.get(&1, :path))
      |> Enum.filter(&String.ends_with?(&1, "_add_oban.exs"))
      |> Enum.reduce(igniter, &prefix_oban_migration(&2, &1, app))
    end

    defp prefix_oban_migration(igniter, path, app) do
      content = igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)

      cond do
        content =~ "oban_prefix" ->
          igniter

        content =~ "Oban.Migration.up()" and content =~ "Oban.Migration.down(version: 1)" ->
          Igniter.update_file(igniter, path, fn source ->
            Rewrite.Source.update(source, :content, &with_oban_prefix(&1, app))
          end)

        true ->
          Igniter.add_warning(igniter, """
          #{path} is not the migration Oban's installer writes, so it was left alone. Oban's
          tables must go in the schema EHOS gives the application: pass
          `prefix: Application.fetch_env!(#{inspect(app)}, Oban)[:prefix] || "public"` and
          `create_schema: false` to `Oban.Migration.up/1` and `down/1`.
          """)
      end
    end

    defp with_oban_prefix(content, app) do
      content
      |> String.replace(
        "Oban.Migration.up()",
        "Oban.Migration.up(prefix: oban_prefix(), create_schema: false)"
      )
      |> String.replace(
        "Oban.Migration.down(version: 1)",
        "Oban.Migration.down(prefix: oban_prefix(), version: 1)"
      )
      |> String.replace(~r/\nend\s*\z/, """


        # Where Oban's configuration looks for its tables: the schema EHOS gives the
        # application, which exists already and which its owner may not create.
        defp oban_prefix, do: Application.fetch_env!(#{inspect(app)}, Oban)[:prefix] || "public"
      end
      """)
    end

    # The workflow as each earlier version wrote it, by SHA-256: 0.2.0's, 0.2.1's, 0.3.0's,
    # which 0.4.0 wrote too, 0.5.0's, which 0.5.1 and 0.6.0 wrote too, and 0.6.1's, which 0.7.0
    # wrote too. The template takes
    # no assigns, so a version wrote the same bytes into every project. A release that changes
    # `ci.yml.eex` adds the hash of what it replaces here, and that file to
    # test/fixtures/ci_workflows/.
    @earlier_ci_workflows [
      "4c1a95dfe62e3d2f429b260416d4b4e2b3266de0281ee351bf514f04c6320743",
      "0f26900d5726a2c9510365b943ac4246e57b81d80ac57dd434901bcd47733c61",
      "a337aee941927815d00b6ec4ab5a9e9b2420c4ecf9f16e850eaa4bbce2c8c96b",
      "e6f929d1710235d21f2bed3e3ff9a23cdd0a5dec1dc91b8d3eacc7359d16cad9",
      "c29bbb2630ad1b77dc173d1474b85bb014fe7ea6d0e69b0d5132120c4291d7e0"
    ]

    # The workflow is the developer's once they change it. One that is still, byte for byte,
    # what an earlier version wrote was never changed, so it is replaced by this version's
    # (T-02); 0.2's read eh-os-contract alone and checked the lock against half its
    # dependencies (#38). One the developer changed is left, with the diff to this version's.
    defp ci_workflow(igniter) do
      path = ".github/workflows/ci.yml"
      workflow = render("ci.yml", [])
      igniter = Igniter.include_existing_file(igniter, path)
      content = file_content(igniter, path)

      cond do
        not Igniter.exists?(igniter, path) ->
          Igniter.create_new_file(igniter, path, workflow)

        content == workflow ->
          igniter

        sha256(content) in @earlier_ci_workflows ->
          Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, workflow))

        # `TextDiff` comes with Igniter, through Rewrite, and Igniter prints its own diffs with it.
        true ->
          Igniter.add_notice(igniter, """
          #{path} is not what any version of ehos_app wrote, so it is the project's own and
          was left as it is. This is how it differs from what this version writes (- yours,
          + this version's); take what applies:

          #{TextDiff.format(content, workflow, color: false, line_numbers: false)}
          """)
      end
    end

    defp sha256(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    # `.tool-versions` rather than `mise.toml`: mise reads both, asdf only this one, and
    # a pin a developer's version manager ignores is not a pin.
    defp tool_versions(igniter) do
      case Toolchain.current() do
        {:ok, toolchain} ->
          write_template(igniter, "tool-versions", ".tool-versions", toolchain)

        :error ->
          Igniter.add_warning(igniter, """
          .tool-versions was not written: the full Erlang version of the running
          installation could not be read. Add it by hand, naming the Erlang and Elixir
          versions the project should use.
          """)
      end
    end

    # A task, not a patch: the release and the Dockerfile stay whatever the project's own
    # Phoenix version generates, which is what `fly launch` relies on as well. Only when
    # there is no Dockerfile yet: `phx.gen.release` would otherwise offer to overwrite one
    # the developer has since changed, and a second run of this installer must change
    # nothing. The Dockerfile it writes is then given the build secret by a second task,
    # since it does not exist until the first has run.
    defp release(igniter) do
      if Igniter.exists?(igniter, "Dockerfile") do
        Igniter.compose_task(igniter, "ehos_app.dockerfile")
      else
        igniter
        |> Igniter.add_task("phx.gen.release", ["--docker"])
        |> Igniter.add_task("ehos_app.dockerfile", ["--yes"])
      end
    end

    # The agent harness. A seed is written once and then the developer's; a managed section,
    # between two markers, is rewritten by every run, so what EHOS requires reaches an
    # application through an upgrade.
    defp harness(igniter, app, web, example?) do
      {igniter, moved?} = move_phoenix_rules(igniter)
      phoenix_rules? = Igniter.exists?(igniter, "docs/phoenix.md")
      {igniter, design_system, _content} = design_system_state(igniter)

      assigns = [
        app: app,
        module: inspect(Igniter.Project.Module.module_name_prefix(igniter)),
        web: inspect(web),
        example: example? == true,
        phoenix_rules: phoenix_rules?,
        contract_docs: @contract_docs,
        contract_dir: Path.dirname(@contract_docs),
        auth_readme: @auth_readme,
        ehos_app_readme: @ehos_app_readme,
        design_system: @design_system,
        design_system_declined: design_system == :declined,
        # The README names a LICENSE only where there is one: the installer writes it in a new
        # project alone, and a project may have its own, under any terms.
        license: Igniter.exists?(igniter, "LICENSE"),
        web_port: @web_port,
        health_port: @health_port,
        ehos_name: ehos_name(app)
      ]

      igniter
      |> managed("AGENTS.md", "agents", "agents.md", assigns,
        generated?: &(moved? and phoenix?(&1)),
        seed_section_alone?: true
      )
      |> phoenix_rules_notice(app)
      |> write_rendered("CLAUDE.md", "@AGENTS.md\n")
      |> managed("lib/#{app}/contracts/AGENTS.md", "contracts", "contracts_agents.md", assigns)
      |> write_rendered("lib/#{app}/contracts/CLAUDE.md", "@AGENTS.md\n")
      |> managed("lib/#{app}_web/AGENTS.md", "web", "web_agents.md", assigns)
      |> write_rendered("lib/#{app}_web/CLAUDE.md", "@AGENTS.md\n")
      |> managed("VISION.md", "vision", "vision.md", assigns)
      |> managed("README.md", "readme", "readme.md", assigns, generated?: &phoenix_readme?/1)
      |> managed_on_top("ARCHITECTURE.md", "architecture", assigns)
      |> managed_on_top("TESTING.md", "testing", assigns)
      |> managed("DEVELOPMENT.md", "development", "development.md", assigns)
      |> write_template("pull_request_template.md", ".github/pull_request_template.md", [])
      |> copy_file("priv/templates/ehos_app.install/coderabbit.yaml", ".coderabbit.yaml")
      # A module of its own name, so that Igniter's module location keeps it at the root of test/.
      |> write_template("harness_test.exs", "test/harness_test.exs", module: HarnessTest)
      |> retire_skills()
      |> claude_settings()
      |> ignore_plans()
    end

    # Phoenix 1.8 writes its rules for agents into `AGENTS.md`, about 450 lines of them. They
    # move to `docs/phoenix.md` as Phoenix wrote them, so that the root file stays short and
    # points to them. Returns whether they were moved.
    defp move_phoenix_rules(igniter) do
      igniter = Igniter.include_existing_file(igniter, "AGENTS.md")

      with false <- Igniter.exists?(igniter, "docs/phoenix.md"),
           {:ok, source} <- Rewrite.source(igniter.rewrite, "AGENTS.md"),
           content = Rewrite.Source.get(source, :content),
           true <- phoenix?(content) do
        {Igniter.create_new_file(igniter, "docs/phoenix.md", content), true}
      else
        _ -> {igniter, false}
      end
    end

    # A project from ehos_app 0.2 has the EHOS section on top of Phoenix's rules, and the rest
    # of that file may be the developer's by now, so the rules are left where they are.
    defp phoenix_rules_notice(igniter, app) do
      with {:ok, source} <- Rewrite.source(igniter.rewrite, "AGENTS.md"),
           content = Rewrite.Source.get(source, :content),
           true <-
             content =~ "<!-- ehos_app:agents -->" and content =~ "<!-- usage-rules-start -->",
           false <- Igniter.exists?(igniter, "docs/phoenix.md") do
        Igniter.add_notice(igniter, """
        AGENTS.md still holds the rules Phoenix wrote into it, below the EHOS section, and
        test/harness_test.exs holds AGENTS.md to 200 lines. Move them, from "This is a web
        application written using the Phoenix web framework." to <!-- usage-rules-end -->, into
        docs/phoenix.md, then run the installer again: lib/#{app}_web/AGENTS.md will point there,
        and an AGENTS.md left with the EHOS section alone gets the application's part below it.
        """)
      else
        _ -> igniter
      end
    end

    # The README `phx.new` writes, and nothing else, is replaced by the seed: its title, then
    # word for word the rest of Phoenix 1.8's template, copied into `phoenix_readme_body.md`,
    # with line endings and trailing spaces not counted. A README with any line of the
    # developer's in it, even one appended to Phoenix's, gets the section on top instead.
    @phoenix_readme_body "priv/templates/ehos_app.install/phoenix_readme_body.md"

    defp phoenix_readme?(content) do
      case content |> plain_lines() |> String.split("\n", parts: 2) do
        ["# " <> _title, body] ->
          body ==
            :ehos_app
            |> Application.app_dir(@phoenix_readme_body)
            |> File.read!()
            |> plain_lines()

        _other ->
          false
      end
    end

    defp plain_lines(text) do
      text
      |> String.replace(~r/[ \t]+(?=\r?\n|\z)/, "")
      |> String.replace("\r\n", "\n")
      |> String.trim_trailing()
    end

    defp phoenix?(content) do
      content =~ "<!-- usage-rules-start -->" and not (content =~ "<!-- ehos_app:agents -->")
    end

    # A file the installer keeps a section of, between `<!-- ehos_app:<name> -->` markers. With
    # no file, the seed, which holds the section. A section from an earlier version is replaced
    # in place. With `seed_section_alone?`, a file that holds the section and nothing else gets
    # the seed, as a new project does: the root `AGENTS.md` ehos_app 0.2 wrote was the section
    # alone once Phoenix's rules moved out, and the part below it never arrived. Only there: in
    # another file, a section alone is what the developer left. A start marker without its end
    # means the developer has edited the section, so it is left alone rather than added a
    # second time. A file `generated?` recognises as the one Phoenix generated is replaced by
    # the seed; any other file gets the section on top.
    # ARCHITECTURE.md and TESTING.md were the developer's once written before 0.9.0, which made
    # what the template knows a section of each. An earlier file gets the section on top, and is
    # told which of its parts the section now says.
    defp managed_on_top(igniter, path, name, assigns) do
      earlier? =
        Igniter.exists?(igniter, path) and
          not String.contains?(
            igniter |> Igniter.include_existing_file(path) |> file_content(path),
            "<!-- ehos_app:#{name} -->"
          )

      igniter = managed(igniter, path, name, String.downcase(path), assigns)

      if earlier?,
        do:
          Igniter.add_notice(igniter, """
          #{path} has a section of the template's on top now, between the markers
          <!-- ehos_app:#{name} --> and <!-- /ehos_app:#{name} -->, which an upgrade rewrites.
          The parts below it that an earlier version wrote say the same, and can be deleted: keep
          only what is this application's own.
          """),
        else: igniter
    end

    defp managed(igniter, path, name, template, assigns, opts \\ []) do
      generated? = Keyword.get(opts, :generated?, fn _ -> false end)
      seed_section_alone? = Keyword.get(opts, :seed_section_alone?, false)
      section = render("#{name}_section.md", assigns)
      seed = render(template, Keyword.put(assigns, :section, section))
      start = "<!-- ehos_app:#{name} -->"
      pattern = Regex.compile!("#{Regex.escape(start)}.*?<!-- /ehos_app:#{name} -->\\n?", "s")

      Igniter.create_or_update_file(igniter, path, seed, fn source ->
        Rewrite.Source.update(source, :content, fn content ->
          cond do
            seed_section_alone? and content =~ pattern and
                String.trim(String.replace(content, pattern, "")) == "" ->
              seed

            content =~ pattern ->
              String.replace(content, pattern, fn _ -> section end, global: false)

            String.contains?(content, start) ->
              content

            generated?.(content) ->
              seed

            true ->
              section <> "\n" <> content
          end
        end)
      end)
    end

    @doc "The plugin the project's `.claude/settings.json` enables, and the tag it is pinned to."
    @spec plugin() :: %{name: String.t(), marketplace: String.t(), ref: String.t()}
    def plugin, do: %{name: @plugin, marketplace: @marketplace, ref: @plugin_ref}

    # Enables the `ehos-app` plugin in the project's Claude Code settings, from ehos-tools'
    # marketplace at the plugin's tag. Settings of the developer's own are kept, key by key and
    # in their order: only the marketplace's entry and the plugin's are added. A marketplace an
    # earlier version pinned to an older tag of the plugin moves to this one; one pinned to
    # anything else, and a plugin the developer turned off, are theirs.
    defp claude_settings(igniter) do
      path = ".claude/settings.json"

      if Igniter.exists?(igniter, path) do
        igniter = Igniter.include_existing_file(igniter, path)
        content = file_content(igniter, path)

        with {:ok, %Jason.OrderedObject{} = settings} <-
               Jason.decode(content, objects: :ordered_objects),
             {settings, kept} when is_map(settings) <- with_plugin(settings) do
          igniter = if kept, do: Igniter.add_notice(igniter, kept), else: igniter
          updated = encode_settings(settings)

          if updated == content,
            do: igniter,
            else:
              Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, updated))
        else
          _ ->
            Igniter.add_warning(igniter, """
            #{path} is not JSON the installer can read: an object, whose
            extraKnownMarketplaces, its #{@marketplace}, that one's source, and enabledPlugins
            are objects too. The installer left it alone, and the #{@plugin} plugin is not
            enabled. Add to it:

            #{object([]) |> with_plugin() |> elem(0) |> encode_settings()}
            """)
        end
      else
        {settings, nil} = with_plugin(object([]))
        Igniter.create_new_file(igniter, path, encode_settings(settings))
      end
    end

    # The settings with the marketplace and the plugin, and a notice when a marketplace of the
    # developer's was kept; `{:error, :shape}` when a part the installer reads is not an object.
    defp with_plugin(settings) do
      marketplaces = with nil <- settings["extraKnownMarketplaces"], do: object([])
      plugins = with nil <- settings["enabledPlugins"], do: object([])
      existing = object?(marketplaces) && marketplaces[@marketplace]

      cond do
        not object?(marketplaces) or not object?(plugins) ->
          {:error, :shape}

        existing != nil and not readable_marketplace?(existing) ->
          {:error, :shape}

        true ->
          {marketplace, kept} = marketplace(existing)
          key = "#{@plugin}@#{@marketplace}"
          plugins = if plugins[key] == nil, do: put(plugins, key, true), else: plugins

          settings =
            settings
            |> put("extraKnownMarketplaces", put(marketplaces, @marketplace, marketplace))
            |> put("enabledPlugins", plugins)

          {settings, kept}
      end
    end

    # An object whose source is an object, and whose strings the installer reads are strings.
    defp readable_marketplace?(existing) do
      source = object?(existing) && existing["source"]

      object?(source) and
        Enum.all?(["source", "repo", "url", "ref"], &(source[&1] == nil or is_binary(source[&1])))
    end

    defp marketplace(nil),
      do: {object(source: object(source: "github", repo: @plugin_repo, ref: @plugin_ref)), nil}

    # A marketplace on this repository at an earlier release of the plugin is the template's,
    # and moves to this one. Any other, a later release or a fork included, is the developer's.
    defp marketplace(existing) do
      source = existing["source"]
      ref = source["ref"]

      ours? = source["source"] == "github" and String.downcase(source["repo"] || "") == repo()

      cond do
        ours? and ref == @plugin_ref ->
          {existing, nil}

        ours? and earlier_plugin?(ref) ->
          {put_in(existing, ["source", "ref"], @plugin_ref), nil}

        true ->
          {existing,
           """
           .claude/settings.json names the marketplace #{@marketplace} as
           #{source["repo"] || source["url"] || "another source"} at #{ref || "no ref"}, which is
           not an earlier release of the #{@plugin} plugin from #{@plugin_repo}, so the
           installer kept it. This version of ehos_app pins #{@plugin_ref}.
           """}
      end
    end

    defp earlier_plugin?(ref) when is_binary(ref) do
      with @plugin <> "-v" <> version <- ref,
           {:ok, version} <- Version.parse(version) do
        Version.compare(version, @plugin_version) == :lt
      else
        _ -> false
      end
    end

    defp earlier_plugin?(_ref), do: false

    defp repo, do: String.downcase(@plugin_repo)

    defp object?(value), do: match?(%Jason.OrderedObject{}, value)

    # Sets a key of an ordered object, in its place if it has one and else at the end.
    defp put(%Jason.OrderedObject{values: values} = object, key, value) do
      if List.keymember?(values, key, 0),
        do: %{object | values: List.keystore(values, key, 0, {key, value})},
        else: %{object | values: values ++ [{key, value}]}
    end

    defp object(pairs),
      do: %Jason.OrderedObject{
        values: Enum.map(pairs, fn {key, value} -> {to_string(key), value} end)
      }

    defp encode_settings(settings), do: Jason.encode!(settings, pretty: true) <> "\n"

    # The skills 0.3.0 to 0.8.1 copied into `.agents/skills/` are the plugin's now. A copy still
    # as a release wrote it is removed; the links to it in `.claude/skills/` are removed by a
    # task, since Igniter sees a linked directory as the files in it and cannot remove a link.
    # Scheduled only when a copy is removed: a second run schedules nothing.
    defp retire_skills(igniter) do
      {igniter, removed, kept} =
        Enum.reduce(@released_skills, {igniter, MapSet.new(), []}, fn {file, hashes},
                                                                      {igniter, removed, kept} ->
          path = Path.join(".agents/skills", file)
          [skill | _] = Path.split(file)

          igniter =
            if Igniter.exists?(igniter, path),
              do: Igniter.include_existing_file(igniter, path),
              else: igniter

          cond do
            not Igniter.exists?(igniter, path) ->
              {igniter, removed, kept}

            # Through a link, the file is another directory's, which other projects may share.
            through_link?(path) ->
              {igniter, removed, [path | kept]}

            sha256(file_content(igniter, path)) in hashes ->
              {Igniter.rm(igniter, path), MapSet.put(removed, skill), kept}

            true ->
              {igniter, removed, [path | kept]}
          end
        end)

      igniter =
        case Enum.sort(kept) do
          [] ->
            igniter

          kept ->
            Igniter.add_notice(igniter, """
            The skills are the #{@plugin} plugin's now, which .claude/settings.json enables:
            /#{@plugin}:plan, /#{@plugin}:ship, /#{@plugin}:review and
            /#{@plugin}:elixir-anti-patterns-review. The installer removed the copies an earlier
            version wrote, and kept these, which were changed since or are reached through a link
            to a directory other projects may share:

            #{Enum.map_join(kept, "\n", &"  * #{&1}")}

            Delete them to use the plugin's, or keep them as skills of the project's own.
            """)
        end

      if Enum.empty?(removed),
        do: igniter,
        else: Igniter.add_task(igniter, "ehos_app.unlink_skills")
    end

    # Apache-2.0, as ehos-tools and eh-os-contract are, in the name of the company that owns
    # EHOS's repositories, for a new project alone: one with a LICENSE of its own keeps it, and
    # one generated earlier without any is not licensed by an upgrade.
    @license_owner "Empowered House PSA"

    defp license(igniter, generated?) do
      if generated? or Igniter.exists?(igniter, "LICENSE") do
        igniter
      else
        igniter
        |> write_template("license", "LICENSE",
          year: Date.utc_today().year,
          owner: @license_owner
        )
        |> Igniter.add_notice("""
        LICENSE is the Apache License 2.0, in the name of #{@license_owner}. If the application
        belongs to someone else, or is to be licensed otherwise, change it before the first push.
        """)
      end
    end

    defp through_link?(path) do
      path
      |> Path.dirname()
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.any?(&match?({:ok, %{type: :symlink}}, File.lstat(&1)))
    end

    defp ignore_plans(igniter) do
      Igniter.create_or_update_file(igniter, ".gitignore", "/.plans/\n", fn source ->
        Rewrite.Source.update(source, :content, fn content ->
          if content =~ ~r{^/?\.plans/?$}m,
            do: content,
            else:
              String.trim_trailing(content) <>
                "\n\n# Working plans, which are history, not current truth.\n/.plans/\n"
        end)
      end)
    end

    # Igniter puts a child after the one that follows its last `after:` match, and in a project
    # `phx.new` generates, the endpoint follows `EhOsContract`: the key store, the health
    # endpoints and the sign-in's client would start after it, and requests be served before
    # they are up. The endpoint goes last. A list of another shape is left alone.
    defp endpoint_last(igniter, endpoint) do
      case Igniter.Project.Application.app_module(igniter) do
        nil ->
          igniter

        app ->
          app = with {module, _} <- app, do: module

          Igniter.Project.Module.find_and_update_module!(igniter, app, fn zipper ->
            with {:ok, zipper} <- children(zipper),
                 list = Igniter.Code.Common.maybe_move_to_single_child_block(zipper),
                 [_ | _] = items <- Sourceror.Zipper.node(list),
                 index when is_integer(index) <-
                   Enum.find_index(items, &endpoint?(&1, endpoint)),
                 true <- index < length(items) - 1,
                 {:ok, list} <- Igniter.Code.List.remove_index(list, index) do
              # The node itself, so the comments above it and its spelling go with it.
              Igniter.Code.List.append_to_list(list, Enum.at(items, index))
            else
              _ -> {:ok, zipper}
            end
          end)
      end
    end

    # The endpoint as a child: its module, or a tuple of its module and options.
    defp endpoint?(node, endpoint) do
      zipper = Sourceror.Zipper.zip(node)

      module =
        if Igniter.Code.Tuple.tuple?(zipper) do
          case Igniter.Code.Tuple.tuple_elem(zipper, 0) do
            {:ok, element} -> element
            :error -> nil
          end
        else
          zipper
        end

      module != nil and Igniter.Code.Common.nodes_equal?(module, endpoint)
    end

    defp children(zipper) do
      with {:ok, zipper} <- Igniter.Code.Function.move_to_def(zipper, :start, 2),
           {:ok, zipper} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :=,
               [2],
               fn call ->
                 Igniter.Code.Function.argument_matches_pattern?(
                   call,
                   0,
                   {:children, _, context} when is_atom(context)
                 ) && Igniter.Code.Function.argument_matches_pattern?(call, 1, v when is_list(v))
               end
             ) do
        Igniter.Code.Function.move_to_nth_argument(zipper, 1)
      end
    end

    # Which commit of eh-os-contract each package is on: none yet, the release this version
    # pins, `main` or a commit an earlier version wrote, or another the project chose, a path or
    # another branch included.
    defp contract_pins(igniter) do
      Map.new([:eh_os_contract, :eh_os_contract_auth], &{&1, contract_pin(igniter, &1)})
    end

    defp contract_pin(igniter, name) do
      case Igniter.Project.Deps.get_dep(igniter, name) do
        {:ok, dep} when is_binary(dep) ->
          opts = dep_opts(dep)

          cond do
            on_release?(opts) -> :current
            earlier?(opts) -> :earlier
            true -> :other
          end

        _none ->
          :none
      end
    end

    # A package on `main` or an earlier commit is asked before it is moved to the release, unless
    # `--yes`.
    # One on another commit keeps it: it may be later than any this version knows. Declined,
    # the move would leave the rest written against a commit without the verifier's version 3
    # or the sign-in's modules, so nothing is written.
    defp contract_deps(igniter, pins) do
      yes? = igniter.args.options[:yes]
      deps = [@eh_os_contract, @eh_os_contract_auth]
      {kept, moved} = Enum.split_with(deps, &(pins[elem(&1, 0)] == :other))

      igniter =
        Enum.reduce(moved, igniter, &Igniter.Project.Deps.add_dep(&2, &1, yes?: yes?))

      declined = Enum.reject(moved, &pinned_here?(igniter, elem(&1, 0)))
      from_commit = Enum.filter(moved, &(pins[elem(&1, 0)] == :earlier))

      if declined != [] do
        Igniter.add_issue(igniter, """
        #{names(declined)} not moved to eh-os-contract's release #{@eh_os_contract_release},
        which this ehos_app is written for, so nothing was changed. Run the installer again and
        accept the move, or pass --yes.
        """)
      else
        igniter
        |> then(&if(kept == [], do: &1, else: kept_warning(&1, kept)))
        |> then(&if(from_commit == [], do: &1, else: moved_notice(&1, from_commit)))
      end
    end

    defp kept_warning(igniter, kept) do
      Igniter.add_warning(igniter, """
      #{names(kept)} on a source or a commit of eh-os-contract that this version of ehos_app
      does not know, so it was left as it is. This ehos_app is written for eh-os-contract's
      release #{@eh_os_contract_release} (#{@eh_os_contract_ref}); signing people in through
      EHOS needs #{@eh_os_contract_minimum} or a later commit.
      """)
    end

    # Mix keeps a locked commit only while the lock's options match `mix.exs`, so the new `ref:`
    # makes the next `deps.get` take the release's commit.
    defp moved_notice(igniter, moved) do
      Igniter.add_notice(igniter, """
      #{names(moved)} moved from eh-os-contract's main, or the commit an earlier ehos_app
      pinned, to its release #{@eh_os_contract_release}, commit #{@eh_os_contract_ref}
      (ehos-tools' T-11). The next `mix deps.get` takes that commit into mix.lock, which may be
      older than the one main had locked: read the diff of mix.lock before committing it.
      """)
    end

    defp names(deps) do
      case Enum.map(deps, &elem(&1, 0)) do
        [one] -> "#{one} was"
        many -> Enum.join(many, " and ") <> " were"
      end
    end

    defp pinned_here?(igniter, name) do
      case Igniter.Project.Deps.get_dep(igniter, name) do
        {:ok, dep} when is_binary(dep) -> dep |> dep_opts() |> on_release?()
        _none -> false
      end
    end

    # A dependency's options, read as code from its text in `mix.exs`: a literal keyword list
    # last in the tuple, or none. A substring match would take a fork named
    # `eh-os-contract-fork`, or a comment, for eh-os-contract.
    defp dep_opts(dep) do
      case Code.string_to_quoted(dep, emit_warnings: false) do
        {:ok, {_name, opts}} when is_list(opts) -> literal_opts(opts)
        {:ok, {:{}, _, [_name, _requirement, opts]}} when is_list(opts) -> literal_opts(opts)
        _other -> []
      end
    end

    defp literal_opts(opts) do
      if Keyword.keyword?(opts), do: Enum.filter(opts, fn {_, v} -> is_binary(v) end), else: []
    end

    # By `github:`, or by a `git:` URL over HTTPS or SSH, with `.git` or without.
    defp eh_os_contract?(opts) do
      String.downcase(opts[:github] || "") == "empoweredhouse/eh-os-contract" or
        (opts[:git] || "") =~
          ~r{\Agit@github\.com:EmpoweredHouse/eh-os-contract(\.git)?\z|\Ahttps://github\.com/EmpoweredHouse/eh-os-contract(\.git)?\z}i
    end

    defp on_release?(opts), do: eh_os_contract?(opts) and opts[:ref] == @eh_os_contract_ref

    defp earlier?(opts) do
      eh_os_contract?(opts) and
        (opts[:branch] == "main" or opts[:ref] in @earlier_eh_os_contract_refs)
    end

    # Whether the project migrated the verifier's tables before this run, in the chosen repo's
    # migrations, and none of its migrations goes to this version's yet. A comment naming the
    # call is not a migration that makes it.
    defp verifier_behind?(igniter, repo) do
      dir = "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}/migrations/"
      igniter = Igniter.include_glob(igniter, dir <> "*.exs")

      sources =
        for source <- igniter.rewrite,
            path = Rewrite.Source.get(source, :path),
            String.starts_with?(path, dir),
            do: {path, Rewrite.Source.get(source, :content)}

      Enum.any?(sources, fn {path, _} ->
        String.ends_with?(path, "_add_eh_os_contract_auth.exs")
      end) and
        not Enum.any?(sources, fn {_path, content} -> to_verifier_version?(content) end)
    end

    # Whether a migration calls `EhOsContract.Auth.Migrations.up` with this version's, read as
    # code: however it is laid out, and never from a comment. A call through an alias or a pipe
    # is not recognised, which adds an upgrade migration that does nothing, since `up/1` leaves
    # a database already at the version alone. One that does not parse calls nothing.
    defp to_verifier_version?(content) do
      case Code.string_to_quoted(content, emit_warnings: false) do
        {:ok, quoted} ->
          quoted
          |> Macro.prewalk(false, fn
            {{:., _, [{:__aliases__, _, [:EhOsContract, :Auth, :Migrations]}, :up]}, _, [opts]} =
                node,
            found ->
              {node, found or (Keyword.keyword?(opts) and opts[:version] == @verifier_version)}

            node, found ->
              {node, found}
          end)
          |> elem(1)

        {:error, _} ->
          false
      end
    end

    # `ehos.yaml` is written once and then the developer's, so one from an earlier version
    # is left as it is, and the developer told what signing people in needs of it.
    # 0.2.0 to 0.8.1 wrote a copy of the schema into `.ehos/` and pointed `ehos.yaml`'s comment
    # at it. A copy that is still EHOS's is removed, and the comment that names it points at the
    # same version in `eh_os_contract_auth` instead; the file's `schema:` is the developer's, and
    # is not moved. A copy that was changed stays, and so does the comment.
    defp retire_schema_copies(igniter) do
      Enum.reduce(@ehos_yaml_schema_copies, igniter, fn {copy, hash}, igniter ->
        if Igniter.exists?(igniter, copy) do
          igniter = Igniter.include_existing_file(igniter, copy)

          if sha256(file_content(igniter, copy)) == hash,
            do: igniter |> Igniter.rm(copy) |> point_at_dependency(copy),
            else: igniter
        else
          igniter
        end
      end)
    end

    # The schema of the version of `ehos.yaml` this installer writes.
    defp current_schema,
      do: EhosApp.ehos_yaml_version() |> String.split("/") |> List.last() |> ehos_yaml_schema()

    defp point_at_dependency(igniter, copy) do
      "ehos.yaml." <> file = Path.basename(copy)
      comment = ~r/^(# yaml-language-server: \$schema=)#{Regex.escape(copy)}$/m
      schema = file |> Path.rootname() |> ehos_yaml_schema()

      if Igniter.exists?(igniter, "ehos.yaml") do
        Igniter.update_file(igniter, "ehos.yaml", fn source ->
          Rewrite.Source.update(source, :content, &Regex.replace(comment, &1, "\\1#{schema}"))
        end)
      else
        igniter
      end
    end

    defp older_ehos_yaml(igniter) do
      igniter = Igniter.include_existing_file(igniter, "ehos.yaml")

      with {:ok, source} <- Rewrite.source(igniter.rewrite, "ehos.yaml"),
           content = Rewrite.Source.get(source, :content),
           false <- content =~ ~r/^sign_in:/m do
        Igniter.add_warning(igniter, """
        ehos.yaml declares no `sign_in`, so EHOS gives the application no client: it starts,
        and signs nobody in to its pages. To sign people in, make it
        `schema: #{EhosApp.ehos_yaml_version()}`, point its schema comment at
        #{current_schema()},
        and add `sign_in: {}` beside `serves:`.
        """)
      else
        _ -> igniter
      end
    end

    # People sign in to the application's pages through EHOS (eh-os D-64), as
    # `eh_os_contract_auth`'s README prescribes: the client, started where it is configured;
    # an encrypted session, which holds the sign-in's state, nonce and PKCE verifier between
    # the redirect and the callback; the routes that sign in and out, behind the browser's
    # session and CSRF protection; a pipeline for the pages that need a person; and a way in
    # and out at the top of the root layout, on every page.
    defp sign_in(igniter, app, web, endpoint) do
      module = Igniter.Project.Module.module_name(igniter, "SignIn")

      igniter
      |> create_module(module, "sign_in.ex", module: module)
      |> Igniter.Project.Application.add_new_child(
        {module,
         {:code, quote(do: Application.get_env(unquote(app), EhOsContract.Auth.SignIn, []))}},
        after: [EhOsContract.Auth]
      )
      |> sign_in_pages(app, web, endpoint)
    end

    # Only where the project serves pages: an endpoint, and a router whose `:browser`
    # pipeline fetches the session and protects from forgery. An API alone has neither.
    defp sign_in_pages(igniter, app, web, endpoint) do
      {endpoint?, igniter} = Igniter.Project.Module.module_exists(igniter, endpoint)
      {igniter, router} = Igniter.Libs.Phoenix.select_router(igniter)
      {igniter, browser?} = browser_pipeline(igniter, router)

      if endpoint? and browser? do
        components = Module.concat(web, SignInComponents)
        # The way in and out is put on the root layout once, with its module: where the
        # developer moves it since is theirs.
        {placed?, igniter} = Igniter.Project.Module.module_exists(igniter, components)

        igniter
        |> encrypted_session(app, endpoint)
        |> sign_in_routes(router)
        |> then(fn igniter ->
          if placed?,
            do: igniter,
            else:
              create_module(igniter, components, "sign_in_components.ex",
                module: components,
                web: web
              )
        end)
        |> sign_in_placement(web, components, placed?)
        |> create_test(Module.concat(web, SignIn), "sign_in_test.exs",
          module: Module.concat(web, SignInTest),
          conn_case: Module.concat(web, ConnCase),
          layouts: Module.concat(web, Layouts),
          components: components
        )
      else
        Igniter.add_warning(igniter, """
        No Phoenix endpoint and router with a `:browser` pipeline were found, so nothing serves
        the pages people sign in to through EHOS. eh_os_contract_auth's README, "Signing
        people in", says what to add; until then, remove `sign_in` from ehos.yaml, which asks
        EHOS for a client the application cannot use.
        """)
      end
    end

    defp browser_pipeline(igniter, nil), do: {igniter, false}

    defp browser_pipeline(igniter, router),
      do: Igniter.Libs.Phoenix.has_pipeline(igniter, router, :browser)

    # The cookie is Secure in production itself, where the address is HTTPS, rather than only when
    # `force_ssl` has rewritten the scheme from a proxy's header. Like `force_ssl`, the setting is
    # read at compile time, from config/prod.exs.
    defp encrypted_session(igniter, app, endpoint) do
      igniter
      |> Igniter.Project.Config.configure_new("prod.exs", app, [endpoint, :secure_session], true)
      |> Igniter.Project.Module.find_and_update_module!(endpoint, fn zipper ->
        with {:ok, zipper} <- Igniter.Code.Common.move_to(zipper, &session_options?/1),
             {:ok, zipper} <- attribute_value(zipper),
             {:ok, zipper} <- encryption_salt(zipper),
             {:ok, zipper} <- secure_cookie(zipper, app) do
          {:ok, zipper}
        else
          _ ->
            {:warning,
             "#{inspect(endpoint)} has no `@session_options` list, so its cookie session was " <>
               "not encrypted. Give `Plug.Session` an `encryption_salt:`: signing in keeps " <>
               "its state, nonce and PKCE verifier there."}
        end
      end)
    end

    # A `secure:` already there is the project's, and stays, but for a literal `false`, which would
    # send the cookie over plain http in production too: it gets the production setting.
    defp secure_cookie(zipper, app) do
      secure =
        quote(do: Application.compile_env(unquote(app), [__MODULE__, :secure_session], false))

      code = Macro.to_string(secure)

      Igniter.Code.Keyword.set_keyword_key(zipper, :secure, secure, fn value ->
        case Sourceror.Zipper.node(value) do
          {:__block__, _meta, [false]} -> {:ok, Igniter.Code.Common.replace_code(value, code)}
          false -> {:ok, Igniter.Code.Common.replace_code(value, code)}
          _theirs -> {:ok, value}
        end
      end)
    end

    # A salt already there is the project's, and stays.
    defp encryption_salt(zipper),
      do: Igniter.Code.Keyword.set_keyword_key(zipper, :encryption_salt, salt(), &{:ok, &1})

    defp session_options?(zipper),
      do: match?({:@, _, [{:session_options, _, _}]}, Sourceror.Zipper.node(zipper))

    # From `@name value` to `value`.
    defp attribute_value(zipper) do
      with %Sourceror.Zipper{} = zipper <- Sourceror.Zipper.down(zipper),
           %Sourceror.Zipper{} = zipper <- Sourceror.Zipper.down(zipper) do
        {:ok, zipper}
      else
        nil -> :error
      end
    end

    # As Phoenix makes its signing salt.
    defp salt, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode64() |> binary_part(0, 8)

    defp sign_in_routes(igniter, router) do
      {:ok, {igniter, source, _zipper}} = Igniter.Project.Module.find_module(igniter, router)
      content = Rewrite.Source.get(source, :content)

      igniter
      |> then(fn igniter ->
        if content =~ "EhOsContract.Auth.SignIn.Router",
          do: igniter,
          else:
            Igniter.Libs.Phoenix.add_scope(
              igniter,
              "/auth",
              """
              pipe_through :browser

              forward "/ehos", EhOsContract.Auth.SignIn.Router
              """,
              router: router
            )
      end)
      |> then(fn igniter ->
        if content =~ "EhOsContract.Auth.Session",
          do: igniter,
          else:
            Igniter.Libs.Phoenix.add_pipeline(
              igniter,
              :signed_in,
              "plug EhOsContract.Auth.Session",
              router: router
            )
      end)
    end

    # The way in and out is at the top of the root layout's body, where Phoenix's own
    # `phx.gen.auth` puts its menu: every page renders that layout with the request's conn, a
    # LiveView's included, and a LiveView's own layout has none. 0.4 put it on Phoenix's home
    # page, which an application's first page of its own replaces, and the link with it
    # (#37). A home page with the line 0.4 wrote, where 0.4 wrote it, has it moved; one the
    # developer has moved stays where it is. A root that is not Phoenix's is the developer's:
    # they are told what to put on it.
    defp sign_in_placement(igniter, web, components, placed?) do
      dir = Path.join("lib", Macro.underscore(inspect(web)))
      home = Path.join(dir, "controllers/page_html/home.html.heex")
      root = Path.join(dir, "components/layouts/root.html.heex")
      call = "<#{inspect(components)}.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      igniter =
        igniter |> Igniter.include_existing_file(home) |> Igniter.include_existing_file(root)

      on_home? = file_content(igniter, home) =~ on_home(flash, call)
      root_content = file_content(igniter, root)
      # A call in a comment renders nothing: the root holds the way in and out only outside one,
      # HEEx's, HTML's or EEx's older `<%# %>`.
      active_root = Regex.replace(~r/<%!--.*?--%>|<!--.*?-->|<%#.*?%>/s, root_content, "")

      cond do
        placed? and not on_home? ->
          igniter

        # The root holds it already, put there by hand: 0.4's line on the home page would make
        # that page render two of it.
        active_root =~ call ->
          if on_home?,
            do: sign_in_off_home(igniter, home, flash, call, components),
            else: igniter

        # The developer commented it out on the root: what they turned off is not brought back,
        # and the home page keeps the only way in and out there is.
        root_content =~ call ->
          if on_home?,
            do:
              Igniter.add_notice(igniter, """
              The way in and out is on #{home}, and commented out on #{root}, so both were left as
              they are. An application's first page of its own replaces the home page, and the
              link with it: uncomment `#{call}` on #{root}, and the next run takes it off
              #{home}.
              """),
            else: igniter

        root_content =~ root_body() ->
          igniter
          |> Igniter.update_file(root, fn source ->
            Rewrite.Source.update(source, :content, fn content ->
              String.replace(content, root_body(), "\\0\\1  #{call}\\2", global: false)
            end)
          end)
          |> then(
            &if(on_home?, do: sign_in_off_home(&1, home, flash, call, components), else: &1)
          )

        placed? ->
          Igniter.add_notice(igniter, """
          The way in and out is still on #{home}, which the application's first page of its
          own replaces. Move `#{call}` to the top of the root layout's <body>, which every
          page renders, a LiveView's included.
          """)

        true ->
          Igniter.add_notice(igniter, """
          Put `#{call}` at the top of the root layout's <body>: it offers a visitor to sign
          in through EHOS, and a signed-in person to sign out, on every page.
          """)
      end
    end

    # The line 0.4 wrote under the home page's flash group, in the page's own line endings.
    defp on_home(flash, call) do
      ~r/(#{Regex.escape(String.trim_trailing(flash))}\r?\n)#{Regex.escape(call)}\r?\n/
    end

    # `<body>` as Phoenix writes it, in the layout's own line endings. A function, not a
    # module attribute: a compiled regex cannot be stored in one under OTP 28.
    defp root_body, do: ~r/^([ \t]*)<body[^>]*>(\r?\n)/m

    # Off the home page, and out of the corner 0.4 fixed it in, which on the root layout
    # would cover the header of Phoenix's `Layouts.app`.
    defp sign_in_off_home(igniter, home, flash, call, components) do
      # Wherever the developer keeps the module, which may not be its default file.
      {igniter, component} =
        case Igniter.Project.Module.find_module(igniter, components) do
          {:ok, {igniter, source, _zipper}} -> {igniter, Rewrite.Source.get(source, :path)}
          {:error, igniter} -> {igniter, nil}
        end

      igniter
      |> Igniter.update_file(home, fn source ->
        Rewrite.Source.update(
          source,
          :content,
          &Regex.replace(on_home(flash, call), &1, fn _line, flash_line -> flash_line end,
            global: false
          )
        )
      end)
      |> then(&if(component, do: corner_off(&1, component), else: &1))
    end

    # 0.4's component, as Igniter formatted it or not, is given what a new one has: the guard
    # for a conn whose session was never fetched, where `get_session/2` raises, which on the root
    # layout is an error page rendered with it; and a bar in the page's flow for the corner it
    # was fixed in, which would cover the header of `Layouts.app`. A component whose assign the
    # developer has changed gets no guard, its div no condition, and a notice saying what to add.
    defp corner_off(igniter, component) do
      content = file_content(igniter, component)

      newline = if content =~ "\r\n", do: "\r\n", else: "\n"

      guarded =
        Regex.replace(
          unguarded_assign(),
          content,
          fn _assign, indent -> guarded_assign(indent, newline) end,
          global: false
        )

      # The div reads `@session?` only where something assigns it, the guard this run added or
      # the developer's own, or every page would raise.
      assigned? = guarded != content or assigns_session?(content)
      condition = if assigned?, do: ":if={@session?} ", else: ""

      updated =
        String.replace(
          guarded,
          ~s|<div id="sign-in-or-out" class="fixed top-4 right-4 z-10">|,
          ~s|<div #{condition}id="sign-in-or-out" class="relative z-10 flex justify-end px-4 py-2 sm:px-6 lg:px-8">|
        )

      igniter =
        if updated == content,
          do: igniter,
          else:
            Igniter.update_file(
              igniter,
              component,
              &Rewrite.Source.update(&1, :content, updated)
            )

      if updated =~ ":plug_session" or not (updated =~ "get_session") do
        igniter
      else
        Igniter.add_notice(igniter, """
        #{component} calls `get_session/2`, which raises on a conn whose session was never
        fetched, and it was changed since 0.4 wrote it, so no guard was added. On the root
        layout it is rendered on every page, so if the project renders error pages with the
        root layout, guard it as a new project's component does:
        `Map.has_key?(assigns.conn.private, :plug_session)` first.
        """)
      end
    end

    # Whether `sign_in_or_out/1` itself assigns `session?`, read as code: another function of
    # the module doing so does not make it an assign this one's template has. A file that does
    # not parse assigns nothing.
    defp assigns_session?(content) do
      case Code.string_to_quoted(content, emit_warnings: false) do
        {:ok, quoted} ->
          quoted
          |> Macro.prewalk(false, fn
            {:def, _, [{:sign_in_or_out, _, _} | _]} = node, found ->
              {node, found or assigns_session_in?(node)}

            node, found ->
              {node, found}
          end)
          |> elem(1)

        {:error, _} ->
          false
      end
    end

    # `assign(assigns, :session?, …)`, `assign(:session?, …)` in a pipe, or `session?:` in a
    # keyword list given to `assign`: `:session?` as the key, never as a value.
    defp assigns_session_in?(function) do
      function
      |> Macro.prewalk(false, fn
        {:assign, _, args} = node, found when is_list(args) ->
          {node, found or assigns_session_key?(args)}

        node, found ->
          {node, found}
      end)
      |> elem(1)
    end

    defp assigns_session_key?([_assigns, :session?, _value]), do: true
    defp assigns_session_key?([:session?, _value]), do: true

    defp assigns_session_key?([_assigns, keyword]) when is_list(keyword),
      do: session_key?(keyword)

    defp assigns_session_key?([keyword]) when is_list(keyword), do: session_key?(keyword)
    defp assigns_session_key?(_args), do: false

    defp session_key?(keyword),
      do: Keyword.keyword?(keyword) and Keyword.has_key?(keyword, :session?)

    defp unguarded_assign do
      ~r/^([ \t]*)assigns =\s*assign\(\s*assigns,\s*:signed_in\?,\s*Plug\.Conn\.get_session\(assigns\.conn, Session\.session_key\(\)\) != nil\s*\)/m
    end

    defp guarded_assign(indent, newline) do
      Enum.map_join(
        [
          "# `get_session/2` raises on a conn whose session was never fetched.",
          "session? = Map.has_key?(assigns.conn.private, :plug_session)",
          "",
          "assigns =",
          "  assigns",
          "  |> assign(:session?, session?)",
          "  |> assign(",
          "    :signed_in?,",
          "    session? and Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "  )"
        ],
        newline,
        fn
          "" -> ""
          line -> indent <> line
        end
      )
      |> String.trim_leading()
      |> then(&(indent <> &1))
    end

    defp file_content(igniter, path) do
      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} -> Rewrite.Source.get(source, :content)
        {:error, _} -> ""
      end
    end

    # A domain named as the application is in EHOS, one contract on it, its implementation,
    # its route behind the credential check, and the tests that pin both.
    defp example(igniter, true, app, web) do
      name = ehos_name(app)
      domain = Igniter.Project.Module.module_name(igniter, "Domain")
      contract = Igniter.Project.Module.module_name(igniter, "Contracts.Entries")
      entry = Igniter.Project.Module.module_name(igniter, "Entries.Entry")
      {igniter, router} = Igniter.Libs.Phoenix.select_router(igniter)

      igniter
      |> create_module(domain, "domain.ex",
        module: domain,
        name: String.to_atom(name),
        contract_docs: @contract_docs
      )
      |> create_module(contract, "entries_contract.ex",
        module: contract,
        domain: domain,
        contract_docs: @contract_docs,
        id: "#{name}.entries",
        publication: "#{name}.entry.recorded.v1"
      )
      |> create_module(entry, "entry.ex", module: entry, contract: contract)
      |> create_test(Module.concat(web, EntriesApi), "entries_test.exs",
        module: Module.concat(web, EntriesApiTest),
        conn_case: Module.concat(web, ConnCase),
        contract: contract,
        name: name
      )
      |> commands_route(router, contract)
      |> design_system_page(router, app, web)
    end

    defp example(igniter, _, _app, _web), do: igniter

    defp commands_route(igniter, nil, _contract), do: igniter

    defp commands_route(igniter, router, contract) do
      {:ok, {igniter, source, _zipper}} = Igniter.Project.Module.find_module(igniter, router)

      if Rewrite.Source.get(source, :content) =~ "EhOsContract.Plug" do
        igniter
      else
        igniter
        |> Igniter.Libs.Phoenix.add_pipeline(
          :commands,
          """
          plug :accepts, ["json"]
          plug EhOsContract.Auth.Plug
          """,
          router: router
        )
        |> Igniter.Libs.Phoenix.add_scope(
          "/api",
          """
          pipe_through :commands

          forward "/", EhOsContract.Plug, contracts: [#{inspect(contract)}]
          """,
          router: router
        )
      end
    end

    @app_css "assets/css/app.css"
    @design_system_marker "ehos_app:design-system"
    @own_styles_marker "ehos_app:own-styles"

    # Whether the project has the design system: `:absent` before the first run, `:installed`
    # while app.css imports it, in a line no comment hides, and `:declined` once the import is
    # gone and either marker the installer wrote is still there: the one above the import, which
    # the comment asks the developer to keep, or the one on the application's own section, which
    # stays when the import goes with its comment. A declined design system is never brought
    # back, and nothing of it is touched again.
    defp design_system_state(igniter) do
      igniter = Igniter.include_existing_file(igniter, @app_css)

      content =
        if Igniter.exists?(igniter, @app_css),
          do: igniter.rewrite |> Rewrite.source!(@app_css) |> Rewrite.Source.get(:content),
          else: ""

      uncommented = String.replace(content, ~r{/\*.*?\*/}s, "")

      state =
        cond do
          uncommented =~ ~r/^\s*@import\s+"[^"]*ehos_design\.css"/m -> :installed
          content =~ @design_system_marker or content =~ @own_styles_marker -> :declined
          true -> :absent
        end

      {igniter, state, content}
    end

    defp design_system(igniter, app, endpoint) do
      case design_system_state(igniter) do
        {igniter, :declined, _content} ->
          igniter

        {igniter, state, content} ->
          # Hooks only with the version this run adds: one the project pinned may have none.
          had_dep? = Igniter.Project.Deps.has_dep?(igniter, :ehos_design)

          igniter
          |> design_system_dep()
          |> design_system_styles(state, content)
          |> design_system_fonts(endpoint)
          |> then(fn igniter ->
            # Only when this run imported the layer: a stylesheet without Tailwind's import is
            # left alone, and fonts it never uses would be preloaded on every page, and come
            # back on every run.
            case {state, design_system_state(igniter)} do
              {:absent, {igniter, :installed, _content}} ->
                igniter = design_system_preload(igniter, app)
                if had_dep?, do: igniter, else: design_system_hooks(igniter)

              {_state, {igniter, _now, _content}} ->
                igniter
            end
          end)
      end
    end

    # The two faces nearly every page sets its text in, asked for before the stylesheet is
    # parsed, so that a first visit does not lay text out in the fallback and then reflow it.
    # Only when the design system is first installed: a run on a project that has it leaves
    # the root layout alone, so links the developer removed do not come back. Written as
    # Phoenix's HEEx formatter writes them, so the project's `mix format --check-formatted`
    # passes.
    @font_preloads """
    <link
      rel="preload"
      href="/ehos_design/fonts/albert-sans-latin-400-normal.woff2"
      as="font"
      type="font/woff2"
      crossorigin
    />
    <link
      rel="preload"
      href="/ehos_design/fonts/albert-sans-latin-500-normal.woff2"
      as="font"
      type="font/woff2"
      crossorigin
    />
    """

    defp design_system_preload(igniter, app) do
      root = "lib/#{app}_web/components/layouts/root.html.heex"

      stylesheet =
        ~r/^([ \t]*)<link phx-track-static rel="stylesheet" href=\{~p"\/assets\/css\/app\.css"\}/m

      igniter = Igniter.include_existing_file(igniter, root)

      with true <- Igniter.exists?(igniter, root),
           {:ok, source} <- Rewrite.source(igniter.rewrite, root),
           content = Rewrite.Source.get(source, :content),
           false <- content =~ "ehos_design/fonts/",
           [_line, indent] <- Regex.run(stylesheet, content) do
        preloads = @font_preloads |> String.split("\n", trim: true) |> Enum.map(&(indent <> &1))

        Igniter.update_file(igniter, root, fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            # In the layout's own line endings, CRLF included.
            newline = if content =~ "\r\n", do: "\r\n", else: "\n"

            String.replace(content, stylesheet, Enum.join(preloads, newline) <> newline <> "\\0",
              global: false
            )
          end)
        end)
      else
        true ->
          igniter

        _no_layout ->
          Igniter.add_notice(igniter, """
          #{root} was not found, or has no stylesheet link where Phoenix writes it, so the
          design system's fonts are not preloaded. To preload them, add to its <head>, before
          the stylesheet:

          #{@font_preloads}
          """)
      end
    end

    @app_js "assets/js/app.js"
    @design_hooks_import ~s|import {hooks as designHooks} from "phoenix-colocated/ehos_design"\n|

    # The design system's components keep their keyboard in a colocated hook (eh-os D-86), which
    # the LiveSocket must be given beside the application's own: an import of the package's
    # hooks after Phoenix's import of the application's, and their spread after the
    # application's in `hooks:`. Only when this run installs the design system, as the font
    # preloads are: a project that has it already keeps the version it pinned, which may have no
    # hooks to import, and its script is its own. A script that is not Phoenix's is left alone,
    # with what to add, said once.
    defp design_system_hooks(igniter) do
      igniter = Igniter.include_existing_file(igniter, @app_js)

      with true <- Igniter.exists?(igniter, @app_js),
           {:ok, source} <- Rewrite.source(igniter.rewrite, @app_js),
           content = Rewrite.Source.get(source, :content),
           false <- content =~ "phoenix-colocated/ehos_design",
           [import] <- Regex.run(colocated_import(), content),
           true <- content =~ colocated_spread() do
        hooks = String.trim_trailing(@design_hooks_import) <> line_end(import)

        Igniter.update_file(igniter, @app_js, fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            content
            |> String.replace(import, import <> hooks, global: false)
            |> String.replace(colocated_spread(), "\\0, ...designHooks", global: false)
          end)
        end)
      else
        true ->
          igniter

        _not_phoenix ->
          Igniter.add_notice(igniter, """
          #{@app_js} was not found, or has no import of Phoenix's colocated hooks or no `hooks:`
          that spreads them, so the design system's components' hooks were not added. Their
          keyboard needs them, beside the application's:

          #{String.trim(@design_hooks_import)}

          and `...designHooks` in the LiveSocket's `hooks:`.
          """)
      end
    end

    # In the script's own line endings, CRLF included, and however `hooks:` is laid out.
    defp colocated_import,
      do: ~r/^import \{hooks as colocatedHooks\} from "phoenix-colocated\/[a-z0-9_]+";?\r?\n/m

    defp colocated_spread, do: ~r/hooks:\s*\{\s*\.\.\.colocatedHooks\b/

    # Phoenix 1.8's source for the application's own templates, in app.css.
    defp phoenix_lib_source, do: ~r/^@source "\.\.\/\.\.\/lib\/[a-z0-9_]+";\r?\n/m

    defp line_end(line), do: if(String.ends_with?(line, "\r\n"), do: "\r\n", else: "\n")

    # A version the developer has moved to is theirs: the dependency is added only when missing.
    defp design_system_dep(igniter) do
      if Igniter.Project.Deps.has_dep?(igniter, :ehos_design),
        do: igniter,
        else: Igniter.Project.Deps.add_dep(igniter, @ehos_design)
    end

    # The design system's layer goes right after Tailwind, and Phoenix's two daisyUI themes go:
    # they would set daisyUI's colours on `data-theme`, over the theme the layer writes from the
    # tokens. A stylesheet that is not Phoenix's is left alone, with what to add.
    defp design_system_styles(igniter, :installed, _content), do: igniter

    defp design_system_styles(igniter, :absent, content) do
      if content =~ tailwind_import() do
        styled = with_design_system(content)

        igniter
        |> Igniter.update_file(@app_css, &Rewrite.Source.update(&1, :content, fn _ -> styled end))
        |> theme_notice(styled)
        |> source_notice(styled)
      else
        Igniter.add_warning(igniter, design_system_warning(@app_css))
      end
    end

    # Regexes are functions, not module attributes: OTP 28 cannot store a compiled one there.
    defp tailwind_import, do: ~r/^@import "tailwindcss"[^\n]*\n/m

    # Phoenix 1.8 writes a comment on the theme plugin, then a theme named "dark" and one named
    # "light", from `../vendor/daisyui-theme` or, in later releases, from the `daisyui`
    # dependency. A block is removed only while it holds Phoenix's own colours: one the
    # developer has tuned is theirs, and is left, with a notice.
    defp phoenix_theme_comment, do: ~r{/\* daisyUI theme plugin\..*?\*/\n}s

    defp daisyui_theme,
      do: ~r/@plugin "[^"\n]*daisyui-theme" \{\n  name: "(?:dark|light)";\n.*?\n\}\n\n?/s

    # Every colour and size of Phoenix's two themes, as phx_new 1.8 writes them. A theme is
    # Phoenix's while it holds all of them; one changed value makes it the developer's.
    @phoenix_themes %{
      "dark" => [
        "--color-base-100: oklch(30.33% 0.016 252.42);",
        "--color-base-200: oklch(25.26% 0.014 253.1);",
        "--color-base-300: oklch(20.15% 0.012 254.09);",
        "--color-base-content: oklch(97.807% 0.029 256.847);",
        "--color-primary: oklch(58% 0.233 277.117);",
        "--color-primary-content: oklch(96% 0.018 272.314);",
        "--color-secondary: oklch(58% 0.233 277.117);",
        "--color-secondary-content: oklch(96% 0.018 272.314);",
        "--color-accent: oklch(60% 0.25 292.717);",
        "--color-accent-content: oklch(96% 0.016 293.756);",
        "--color-neutral: oklch(37% 0.044 257.287);",
        "--color-neutral-content: oklch(98% 0.003 247.858);",
        "--color-info: oklch(58% 0.158 241.966);",
        "--color-info-content: oklch(97% 0.013 236.62);",
        "--color-success: oklch(60% 0.118 184.704);",
        "--color-success-content: oklch(98% 0.014 180.72);",
        "--color-warning: oklch(66% 0.179 58.318);",
        "--color-warning-content: oklch(98% 0.022 95.277);",
        "--color-error: oklch(58% 0.253 17.585);",
        "--color-error-content: oklch(96% 0.015 12.422);",
        "--radius-selector: 0.25rem;",
        "--radius-field: 0.25rem;",
        "--radius-box: 0.5rem;",
        "--size-selector: 0.21875rem;",
        "--size-field: 0.21875rem;",
        "--border: 1.5px;",
        "--depth: 1;",
        "--noise: 0;"
      ],
      "light" => [
        "--color-base-100: oklch(98% 0 0);",
        "--color-base-200: oklch(96% 0.001 286.375);",
        "--color-base-300: oklch(92% 0.004 286.32);",
        "--color-base-content: oklch(21% 0.006 285.885);",
        "--color-primary: oklch(70% 0.213 47.604);",
        "--color-primary-content: oklch(98% 0.016 73.684);",
        "--color-secondary: oklch(55% 0.027 264.364);",
        "--color-secondary-content: oklch(98% 0.002 247.839);",
        "--color-accent: oklch(0% 0 0);",
        "--color-accent-content: oklch(100% 0 0);",
        "--color-neutral: oklch(44% 0.017 285.786);",
        "--color-neutral-content: oklch(98% 0 0);",
        "--color-info: oklch(62% 0.214 259.815);",
        "--color-info-content: oklch(97% 0.014 254.604);",
        "--color-success: oklch(70% 0.14 182.503);",
        "--color-success-content: oklch(98% 0.014 180.72);",
        "--color-warning: oklch(66% 0.179 58.318);",
        "--color-warning-content: oklch(98% 0.022 95.277);",
        "--color-error: oklch(58% 0.253 17.585);",
        "--color-error-content: oklch(96% 0.015 12.422);",
        "--radius-selector: 0.25rem;",
        "--radius-field: 0.25rem;",
        "--radius-box: 0.5rem;",
        "--size-selector: 0.21875rem;",
        "--size-field: 0.21875rem;",
        "--border: 1.5px;",
        "--depth: 1;",
        "--noise: 0;"
      ]
    }

    defp phoenix_theme?(block) do
      with [name] <- Regex.run(~r/name: "(dark|light)";/, block, capture: :all_but_first) do
        declarations =
          block
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, "--"))

        declarations == Map.fetch!(@phoenix_themes, name)
      else
        _ -> false
      end
    end

    defp with_design_system(content) do
      content
      |> String.replace(phoenix_theme_comment(), "")
      |> String.replace(daisyui_theme(), fn block ->
        if phoenix_theme?(block), do: "", else: block
      end)
      |> String.replace(
        tailwind_import(),
        fn import ->
          import <>
            render("design_system.css",
              design_system_css: @design_system_css,
              marker: @design_system_marker
            )
        end,
        global: false
      )
      # After Phoenix's own sources, not right after the import: no rule may come before
      # Phoenix's second `@import`.
      |> String.replace(
        phoenix_lib_source(),
        fn source -> source <> ~s|@source "#{@design_system_lib}";| <> line_end(source) end,
        global: false
      )
      |> String.trim_trailing()
      |> Kernel.<>("\n\n" <> render("design_system_own.css", marker: @own_styles_marker))
    end

    # The components' templates are a source only after Phoenix's own; a stylesheet without
    # Phoenix's line is told what to add.
    defp source_notice(igniter, styled) do
      if styled =~ ~s|@source "#{@design_system_lib}";|,
        do: igniter,
        else:
          Igniter.add_notice(igniter, """
          #{@app_css} has no `@source` of Phoenix's for the application's templates, so the design
          system's components' templates were not named as a source for Tailwind. Their
          utilities need it, after the stylesheet's other sources:

              @source "#{@design_system_lib}";
          """)
    end

    defp theme_notice(igniter, styled) do
      if styled =~ "daisyui-theme" do
        Igniter.add_notice(igniter, """
        #{@app_css} keeps a daisyUI theme of the project's own, which sets daisyUI's colours over
        the design system's. Remove it to take the design system's look, or keep it, and the
        design system's tokens and fonts, under it.
        """)
      else
        igniter
      end
    end

    defp design_system_warning(path) do
      """
      #{path} has no `@import "tailwindcss"` line, so the design system was not imported. To
      use it, import its layer after Tailwind's, keep daisyUI's own themes off, and remove any
      daisyui-theme:

          @import "#{@design_system_css}";

      #{@design_system}/README.md says more.
      """
    end

    # The fonts the layer names, served by the application from the package: the page loads
    # nothing from another origin.
    defp design_system_fonts(igniter, endpoint) do
      case Igniter.Project.Module.find_module(igniter, endpoint) do
        {:ok, {igniter, source, _zipper}} ->
          if Rewrite.Source.get(source, :content) =~ "from: {:ehos_design" do
            igniter
          else
            Igniter.Project.Module.find_and_update_module!(igniter, endpoint, &serve_fonts/1)
          end

        {:error, igniter} ->
          Igniter.add_warning(igniter, fonts_warning(endpoint))
      end
    end

    @serve_fonts """
    # The design system's fonts, which assets/css/app.css names under /ehos_design/fonts/. Their
    # paths carry no version, so they are cached for a day and then revalidated.
    plug Plug.Static,
      at: "/",
      from: {:ehos_design, "priv/static"},
      gzip: false,
      only: ~w(ehos_design),
      cache_control_for_etags: "public, max-age=86400"
    """

    defp serve_fonts(zipper) do
      case Igniter.Code.Function.move_to_function_call_in_current_scope(
             zipper,
             :plug,
             2,
             &Igniter.Code.Function.argument_equals?(&1, 0, Plug.Static)
           ) do
        {:ok, zipper} ->
          {:ok, Igniter.Code.Common.add_code(zipper, @serve_fonts, placement: :after)}

        :error ->
          {:warning, "The endpoint has no `plug Plug.Static`. Add:\n\n" <> @serve_fonts}
      end
    end

    defp fonts_warning(endpoint) do
      "#{inspect(endpoint)} was not found, so the design system's fonts are not served. Add " <>
        "to the endpoint:\n\n" <> @serve_fonts
    end

    # A page that shows the design system, in the browser pipeline Phoenix generates, where
    # Phoenix puts a LiveView: `lib/<app>_web/live/`, whether or not the project has Igniter's
    # Phoenix extension, which `proper_location/2` would need to choose that folder. Written once:
    # a module that exists, wherever it is, is the developer's.
    defp design_system_page(igniter, nil, _app, _web), do: igniter

    defp design_system_page(igniter, router, app, web) do
      live = Module.concat(web, DesignSystemLive)
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, live)

      case design_system_state(igniter) do
        {igniter, :declined, _content} ->
          igniter

        {igniter, _state, _content} when exists? ->
          design_system_route(igniter, router, web)

        {igniter, _state, _content} ->
          igniter
          |> write_template(
            "design_system_live.ex",
            "lib/#{app}_web/live/design_system_live.ex",
            module: live,
            web: web
          )
          |> write_template(
            "design_system_live_test.exs",
            "test/#{app}_web/live/design_system_live_test.exs",
            module: Module.concat(web, DesignSystemLiveTest),
            conn_case: Module.concat(web, ConnCase)
          )
          |> design_system_route(router, web)
      end
    end

    # A route to the page at any path is the developer's, and is kept; a mention of the module
    # elsewhere, in a comment say, is not a route.
    defp design_system_route(igniter, router, web) do
      {:ok, {igniter, source, _zipper}} = Igniter.Project.Module.find_module(igniter, router)

      routed? =
        source
        |> Rewrite.Source.get(:content)
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
        |> Enum.any?(&(&1 =~ ~r/\blive\(?\s*"[^"]*",\s*(?:\w+\.)*DesignSystemLive\b/))

      if routed? do
        igniter
      else
        Igniter.Libs.Phoenix.append_to_scope(
          igniter,
          "/",
          ~s|live "/design-system", DesignSystemLive|,
          arg2: web,
          with_pipelines: [:browser],
          router: router
        )
      end
    end

    defp create_module(igniter, module, template, assigns) do
      path = Igniter.Project.Module.proper_location(igniter, module)
      write_rendered(igniter, path, render(template, assigns))
    end

    defp create_test(igniter, module, template, assigns) do
      path = Igniter.Project.Module.proper_location(igniter, module, :test)
      write_rendered(igniter, path, render(template, assigns))
    end

    defp write_template(igniter, template, target, assigns) do
      write_rendered(igniter, target, render(template, assigns))
    end

    # A file that exists is the developer's, and is left out before anything is created.
    # `create_new_file/4` with `on_exists: :skip` is not enough: for a file Igniter has not read
    # yet, it reads it, puts the new content over it, and writes that.
    defp write_rendered(igniter, target, content) do
      if Igniter.exists?(igniter, target),
        do: igniter,
        else: Igniter.create_new_file(igniter, target, content)
    end

    defp copy_file(igniter, source, target) do
      write_rendered(igniter, target, :ehos_app |> Application.app_dir(source) |> File.read!())
    end

    defp render(template, assigns) do
      :ehos_app
      |> Application.app_dir(Path.join("priv/templates/ehos_app.install", template <> ".eex"))
      |> EEx.eval_file(assigns: assigns)
    end
  end
else
  defmodule Mix.Tasks.EhosApp.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ehos_app.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installing-igniter
      """)

      exit({:shutdown, 1})
    end
  end
end

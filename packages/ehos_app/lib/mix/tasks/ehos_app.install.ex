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
      * `ehos.yaml`, what EHOS is asked for, with a copy of the schema EHOS defines it by
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
        `TESTING.md`, a `README.md`, skills in `.agents/skills/` linked from
        `.claude/skills/`, a CodeRabbit configuration, a pull request template, and
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

    # One commit of eh-os-contract for both packages. It is not on Hex, and Igniter's
    # `pkg@github:` spec has no `sparse:`, so the installer adds them rather than the
    # `igniter.new` command line. `eh_os_contract_auth` names the engine by git without a
    # ref, so the engine is overridden to the same commit. The requirements are checked
    # against each package's own `mix.exs`, so a ref that moves to an incompatible version
    # fails `deps.get` instead of compiling. Move to a tag once eh-os-contract releases 0.3.0.
    # This commit is the first with the browser-session Plug that signs people in through EHOS
    # (https://github.com/EmpoweredHouse/eh-os-contract/issues/78).
    @eh_os_contract_ref "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb"
    # The commits earlier versions pinned. A project on one of them is moved to this one; a
    # project on any other commit chose it, and keeps it.
    @earlier_eh_os_contract_refs [
      "6df5bc7880bfecc4348ea33fdb080eeb4fdb7a4a",
      "50eb7711c3235325834535d7d24239855c0e63d8"
    ]
    @eh_os_contract {:eh_os_contract, "~> 0.3.0-dev",
                     github: "EmpoweredHouse/eh-os-contract",
                     sparse: "packages/eh_os_contract",
                     ref: @eh_os_contract_ref,
                     override: true}
    @eh_os_contract_auth {:eh_os_contract_auth, "~> 0.1.0-dev",
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

    # The copy of EHOS's schema the project carries, unchanged, and where it came from: the
    # commit that last changed it. `ehos.yaml/v2` is the first version whose `sign_in` signs
    # people in (eh-os D-69); eh-os freezes it in the release after 0.3.0.
    @ehos_yaml_schema "priv/schemas/ehos.yaml/v2.json"
    @ehos_yaml_schema_copy ".ehos/ehos.yaml.v2.json"
    @ehos_yaml_schema_source "https://github.com/EmpoweredHouse/eh-os/blob/99e036b0b1113be5f5ee3770d852d80260796748/priv/schemas/ehos.yaml/v2.json"

    # Where the other parts' docs are inside the generated project. `ehos_app` itself is a
    # `sparse:` git dependency of `packages/ehos_app` (`Ehosctl.Template`), in `:dev` only.
    @auth_readme Path.join([
                   "deps",
                   "eh_os_contract_auth",
                   @eh_os_contract_auth |> elem(2) |> Keyword.fetch!(:sparse),
                   "README.md"
                 ])
    @ehos_app_readme "deps/ehos_app/packages/ehos_app/README.md"

    # The EmpoweredHouse design system, the application's default look (eh-os D-72). It is
    # not on Hex, and lives in a subdirectory of ehos-tools, hence `sparse:`. Pinned to the
    # commit tagged `ehos_design-v0.1.0` rather than to the tag, which nothing stops being
    # moved, as eh_os_contract is pinned. The requirement is checked against the package's own
    # `mix.exs`, so a commit of another version fails `deps.get` instead of building.
    @ehos_design {:ehos_design, "~> 0.1.0",
                  github: "EmpoweredHouse/ehos-tools",
                  sparse: "packages/ehos_design",
                  ref: "a65b9c86d920b5566f1c085b2286a44da77505c9"}

    # Where the design system is inside the generated project. A `sparse:` git dependency
    # keeps its subdirectory under `deps/<name>/`, so the path follows it.
    @design_system Path.join([
                     "deps",
                     "ehos_design",
                     @ehos_design |> elem(2) |> Keyword.fetch!(:sparse)
                   ])

    # Where `assets/css/app.css` imports the design system's layer from, relative to itself.
    @design_system_css Path.join(["..", "..", @design_system, "priv", "css", "ehos_design.css"])

    # The skills, copied into `.agents/skills/` and linked from `.claude/skills/`.
    @skills "priv/templates/ehos_app.install/skills"

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

    @doc "The contract DSL reference, relative to the generated project's root."
    @spec contract_docs() :: String.t()
    def contract_docs, do: @contract_docs

    @doc "Where the design system is, relative to the generated project's root."
    @spec design_system() :: String.t()
    def design_system, do: @design_system

    @doc "The ports of the web endpoint and of the health endpoints."
    @spec ports() :: %{web: pos_integer(), health: pos_integer()}
    def ports, do: %{web: @web_port, health: @health_port}

    @doc "Where the copy of EHOS's `ehos.yaml` schema was taken from."
    @spec ehos_yaml_schema_source() :: String.t()
    def ehos_yaml_schema_source, do: @ehos_yaml_schema_source

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
      |> write_template("ehos.yaml", "ehos.yaml", web_port: @web_port, health_port: @health_port)
      |> older_ehos_yaml()
      |> copy_file(@ehos_yaml_schema, @ehos_yaml_schema_copy)
      |> write_template("rel_env.sh", "rel/env.sh.eex", [])
      |> write_template("ci.yml", ".github/workflows/ci.yml", [])
      |> ci_reads_ehos_tools()
      |> tool_versions()
      |> design_system(endpoint)
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
    # it runs in the application: it is needed for `mix igniter.upgrade` alone, so CI and the
    # image never fetch it.
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

    # The workflow is the developer's once written, so one from ehos_app 0.2, whose token reads
    # eh-os-contract alone, is not changed: it is told what ehos_design needs.
    defp ci_reads_ehos_tools(igniter) do
      path = ".github/workflows/ci.yml"
      igniter = Igniter.include_existing_file(igniter, path)

      with true <- Igniter.exists?(igniter, path),
           {:ok, source} <- Rewrite.source(igniter.rewrite, path),
           content = Rewrite.Source.get(source, :content),
           true <- content =~ "EmpoweredHouse/eh-os-contract",
           false <- content =~ "EmpoweredHouse/ehos-tools" do
        Igniter.add_notice(igniter, """
        #{path} reads eh-os-contract alone, and ehos_design is read from ehos-tools, which is
        private too. In each job, name both repositories where the GitHub App's token is
        minted (`repositories: eh-os-contract,ehos-tools`), and give the `mix deps.get` step a
        second rewrite beside eh-os-contract's:

            GIT_CONFIG_COUNT: "2"
            GIT_CONFIG_KEY_1: url.https://x-access-token:<the token>@github.com/EmpoweredHouse/ehos-tools.insteadOf
            GIT_CONFIG_VALUE_1: https://github.com/EmpoweredHouse/ehos-tools
        """)
      else
        _ -> igniter
      end
    end

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
        web_port: @web_port,
        health_port: @health_port
      ]

      igniter
      |> managed("AGENTS.md", "agents", "agents.md", assigns, &(moved? and phoenix?(&1)))
      |> phoenix_rules_notice(app)
      |> write_rendered("CLAUDE.md", "@AGENTS.md\n")
      |> managed("lib/#{app}/contracts/AGENTS.md", "contracts", "contracts_agents.md", assigns)
      |> write_rendered("lib/#{app}/contracts/CLAUDE.md", "@AGENTS.md\n")
      |> managed("lib/#{app}_web/AGENTS.md", "web", "web_agents.md", assigns)
      |> write_rendered("lib/#{app}_web/CLAUDE.md", "@AGENTS.md\n")
      |> managed("VISION.md", "vision", "vision.md", assigns)
      |> managed(
        "README.md",
        "readme",
        "readme.md",
        assigns,
        &(&1 =~ "To start your Phoenix server")
      )
      |> write_template("architecture.md", "ARCHITECTURE.md", assigns)
      |> write_template("testing.md", "TESTING.md", assigns)
      |> write_template("pull_request_template.md", ".github/pull_request_template.md", [])
      |> copy_file("priv/templates/ehos_app.install/coderabbit.yaml", ".coderabbit.yaml")
      # A module of its own name, so that Igniter's module location keeps it at the root of test/.
      |> write_template("harness_test.exs", "test/harness_test.exs", module: HarnessTest)
      |> skills()
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
        docs/phoenix.md, then run the installer again: lib/#{app}_web/AGENTS.md will point there.
        """)
      else
        _ -> igniter
      end
    end

    defp phoenix?(content) do
      content =~ "<!-- usage-rules-start -->" and not (content =~ "<!-- ehos_app:agents -->")
    end

    # A file the installer keeps a section of, between `<!-- ehos_app:<name> -->` markers. With
    # no file, the seed, which holds the section. A section from an earlier version is replaced
    # in place. A start marker without its end means the developer has edited the section, so
    # it is left alone rather than added a second time. A file `generated?` recognises as the
    # one Phoenix generated is replaced by the seed; any other file gets the section on top.
    defp managed(igniter, path, name, template, assigns, generated? \\ fn _ -> false end) do
      section = render("#{name}_section.md", assigns)
      seed = render(template, Keyword.put(assigns, :section, section))
      start = "<!-- ehos_app:#{name} -->"
      pattern = Regex.compile!("#{Regex.escape(start)}.*?<!-- /ehos_app:#{name} -->\\n?", "s")

      Igniter.create_or_update_file(igniter, path, seed, fn source ->
        Rewrite.Source.update(source, :content, fn content ->
          cond do
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

    # Igniter writes files and cannot make a symlink, so the links into `.agents/skills/` are a
    # task's, scheduled only while one is missing: a second run must schedule nothing.
    defp skills(igniter) do
      source = Application.app_dir(:ehos_app, @skills)

      files =
        source
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, source))

      igniter =
        Enum.reduce(files, igniter, fn file, igniter ->
          copy_file(igniter, Path.join(@skills, file), Path.join(".agents/skills", file))
        end)

      linked? =
        files
        |> Enum.map(&(&1 |> Path.split() |> hd()))
        |> Enum.uniq()
        |> Enum.all?(&Igniter.exists?(igniter, Path.join([".claude/skills", &1, "SKILL.md"])))

      if linked?, do: igniter, else: Igniter.add_task(igniter, "ehos_app.link_skills")
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

    # Which commit of eh-os-contract each package is on: none yet, this version's, one an
    # earlier version pinned, or another the project chose, a path or a branch included.
    defp contract_pins(igniter) do
      Map.new([:eh_os_contract, :eh_os_contract_auth], &{&1, contract_pin(igniter, &1)})
    end

    defp contract_pin(igniter, name) do
      case Igniter.Project.Deps.get_dep(igniter, name) do
        {:ok, dep} when is_binary(dep) ->
          cond do
            dep =~ @eh_os_contract_ref -> :current
            Enum.any?(@earlier_eh_os_contract_refs, &(dep =~ &1)) -> :earlier
            true -> :other
          end

        _none ->
          :none
      end
    end

    # A package on an earlier commit is asked before it is moved to this one, unless `--yes`.
    # One on another commit keeps it: it may be later than this version's. Declined, the move
    # would leave the rest written against a commit without the verifier's version 3 or the
    # sign-in's modules, so nothing is written.
    defp contract_deps(igniter, pins) do
      yes? = igniter.args.options[:yes]
      deps = [@eh_os_contract, @eh_os_contract_auth]
      {kept, moved} = Enum.split_with(deps, &(pins[elem(&1, 0)] == :other))

      igniter =
        Enum.reduce(moved, igniter, &Igniter.Project.Deps.add_dep(&2, &1, yes?: yes?))

      declined = Enum.reject(moved, &pinned_here?(igniter, elem(&1, 0)))

      cond do
        declined != [] ->
          Igniter.add_issue(igniter, """
          #{names(declined)} not moved to eh-os-contract's #{@eh_os_contract_ref}, which signing
          people in through EHOS needs, so nothing was changed. Run the installer again and
          accept the move, or pass --yes.
          """)

        kept != [] ->
          Igniter.add_warning(igniter, """
          #{names(kept)} on a commit of eh-os-contract that this version of ehos_app does not
          know, so it was left as it is. Signing people in through EHOS needs
          #{@eh_os_contract_ref} or a later one.
          """)

        true ->
          igniter
      end
    end

    defp names(deps) do
      case Enum.map(deps, &elem(&1, 0)) do
        [one] -> "#{one} was"
        many -> Enum.join(many, " and ") <> " were"
      end
    end

    defp pinned_here?(igniter, name) do
      case Igniter.Project.Deps.get_dep(igniter, name) do
        {:ok, dep} when is_binary(dep) -> dep =~ @eh_os_contract_ref
        _none -> false
      end
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
    defp older_ehos_yaml(igniter) do
      igniter = Igniter.include_existing_file(igniter, "ehos.yaml")

      with {:ok, source} <- Rewrite.source(igniter.rewrite, "ehos.yaml"),
           content = Rewrite.Source.get(source, :content),
           false <- content =~ ~r/^sign_in:/m do
        Igniter.add_warning(igniter, """
        ehos.yaml declares no `sign_in`, so EHOS gives the application no client: it starts,
        and signs nobody in to its pages. To sign people in, make it `schema: ehos.yaml/v2`,
        point its schema comment at #{@ehos_yaml_schema_copy}, and add `sign_in: {}` beside
        `serves:`.
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
    # and out on the root, where EHOS returns a sign-out.
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
        # The way in and out is put on the root once, with its module: where the developer
        # moves it since is theirs.
        {placed?, igniter} = Igniter.Project.Module.module_exists(igniter, components)

        igniter
        |> encrypted_session(app, endpoint)
        |> sign_in_routes(router)
        |> create_module(components, "sign_in_components.ex", module: components, web: web)
        |> then(&if(placed?, do: &1, else: sign_in_on_home(&1, web, components)))
        |> create_test(Module.concat(web, SignIn), "sign_in_test.exs",
          module: Module.concat(web, SignInTest),
          conn_case: Module.concat(web, ConnCase)
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

    # The root Phoenix generates shows the way in and out, top right. Any other root is the
    # developer's: they are told what to put on it.
    defp sign_in_on_home(igniter, web, components) do
      path =
        Path.join([
          "lib",
          Macro.underscore(inspect(web)),
          "controllers/page_html/home.html.heex"
        ])

      call = "<#{inspect(components)}.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"
      igniter = Igniter.include_existing_file(igniter, path)

      with {:ok, source} <- Rewrite.source(igniter.rewrite, path),
           content = Rewrite.Source.get(source, :content),
           false <- content =~ call,
           true <- content =~ flash do
        Igniter.update_file(igniter, path, fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, flash, flash <> call <> "\n", global: false)
          )
        end)
      else
        true ->
          igniter

        _ ->
          Igniter.add_notice(igniter, """
          Put `#{call}` on the application's root: it offers a visitor to sign in through
          EHOS, and a signed-in person to sign out. EHOS returns a sign-out to the root.
          """)
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
        publication: publication(name)
      )
      |> publication_warning(name)
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

    # eh_os_contract names a publication under the domain's name, in segments that allow no
    # dash, and EHOS names an application with dashes, never an underscore. A name with a
    # dash, from an OTP application with an underscore, can therefore publish nothing until
    # https://github.com/EmpoweredHouse/eh-os-contract/issues/50 is fixed.
    defp publication(name) do
      unless String.contains?(name, "-"), do: "#{name}.entry.recorded.v1"
    end

    defp publication_warning(igniter, name) do
      if publication(name) do
        igniter
      else
        Igniter.add_warning(igniter, """
        The example contract publishes nothing: its domain is named #{name}, as EHOS names
        the application, and eh_os_contract allows no dash in a publication's name
        (https://github.com/EmpoweredHouse/eh-os-contract/issues/50).
        `eh_os_contract.check` warns that `:recorded` has no consumer.
        """)
      end
    end

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

    defp design_system(igniter, endpoint) do
      case design_system_state(igniter) do
        {igniter, :declined, _content} ->
          igniter

        {igniter, state, content} ->
          igniter
          |> design_system_dep()
          |> design_system_styles(state, content)
          |> design_system_fonts(endpoint)
      end
    end

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
      |> String.trim_trailing()
      |> Kernel.<>("\n\n" <> render("design_system_own.css", marker: @own_styles_marker))
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

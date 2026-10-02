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
      * a release and a Dockerfile, through `mix phx.gen.release --docker`, which reads the
        private `eh_os_contract` through a BuildKit secret
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
        so the tests, `eh_os_contract.check` and the manifest have something to read on day one
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.EhosApp.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias EhosApp.Toolchain

    # One commit of eh-os-contract for both packages. It is not on Hex, and Igniter's
    # `pkg@github:` spec has no `sparse:`, so the installer adds them rather than the
    # `igniter.new` command line. `eh_os_contract_auth` names the engine by git without a
    # ref, so the engine is overridden to the same commit. The requirements are checked
    # against each package's own `mix.exs`, so a ref that moves to an incompatible version
    # fails `deps.get` instead of compiling. Move to a tag once eh-os-contract releases 0.3.0.
    @eh_os_contract_ref "50eb7711c3235325834535d7d24239855c0e63d8"
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

    # The copy of EHOS's schema the project carries, unchanged, and where it came from.
    # eh-os freezes `ehos.yaml/v1` when it releases 0.3.0; replace the copy with the
    # release's then.
    @ehos_yaml_schema "priv/schemas/ehos.yaml/v1.json"
    @ehos_yaml_schema_source "https://github.com/EmpoweredHouse/eh-os/blob/eeb732ae175ef0e0b9a9e30a1d693924c5785a7c/priv/schemas/ehos.yaml/v1.json"

    # Where the other parts' docs are inside the generated project. `ehos_app` itself is a
    # `sparse:` git dependency of `packages/ehos_app` (`Ehosctl.Template`), in `:dev` only.
    @auth_readme Path.join([
                   "deps",
                   "eh_os_contract_auth",
                   @eh_os_contract_auth |> elem(2) |> Keyword.fetch!(:sparse),
                   "README.md"
                 ])
    @ehos_app_readme "deps/ehos_app/packages/ehos_app/README.md"

    # Where the EmpoweredHouse design system will be. Only managed sections name it, so a real
    # path reaches every application through an upgrade, without touching a file of its own.
    @design_system "path/to/design-system"

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

    @doc "Where the design system will be, as the managed sections of the harness name it."
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

      igniter
      |> Igniter.Project.Deps.add_dep(@eh_os_contract)
      |> Igniter.Project.Deps.add_dep(@eh_os_contract_auth)
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
      |> migrations(repo)
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
      |> Igniter.Project.TaskAliases.add_alias(:precommit, "eh_os_contract.check",
        if_exists: :append
      )
      |> create_module(health, "health.ex", module: health, app: app)
      |> create_test(health, "health_test.exs", module: health)
      |> write_template("ehos.yaml", "ehos.yaml", web_port: @web_port, health_port: @health_port)
      |> copy_file(@ehos_yaml_schema, ".ehos/ehos.yaml.v1.json")
      |> write_template("rel_env.sh", "rel/env.sh.eex", [])
      |> write_template("ci.yml", ".github/workflows/ci.yml", [])
      |> tool_versions()
      |> harness(app, web, igniter.args.options[:example])
      |> example(igniter.args.options[:example], app, web)
      |> release()
      |> Igniter.add_notice("""
      EHOS: the project is ready. Start a database, then:

          mix ecto.setup
          mix precommit

      eh_os_contract is read from a private repository. Build the image with a GitHub
      token that can read it, as a build secret:

          GITHUB_TOKEN=$(gh auth token) docker build --secret id=github_token,env=GITHUB_TOKEN .

      The CI workflow reads it through a GitHub App installed on eh-os-contract with read
      access to its contents. Give the repository the App's ID and private key:

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
        |> ehos_runtime(path, render("runtime_prod.exs", app: app, repo: repo))
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

    defp ehos_runtime(igniter, path, block) do
      Igniter.update_elixir_file(igniter, path, fn zipper ->
        if Sourceror.to_string(Sourceror.Zipper.root(zipper)) =~ "EHOS_ISSUER" do
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

    defp migrations(igniter, repo) do
      igniter
      |> migration(repo, "add_eh_os_contract", "EhOsContract.Migrations")
      |> migration(repo, "add_eh_os_contract_auth", "EhOsContract.Auth.Migrations")
    end

    defp migration(igniter, repo, name, module) do
      Igniter.Libs.Ecto.gen_migration(igniter, repo, name,
        body: """
        def up, do: #{module}.up()

        def down, do: #{module}.down()
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

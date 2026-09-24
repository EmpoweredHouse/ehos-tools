defmodule Mix.Tasks.EhosApp.Install.Docs do
  @moduledoc false

  def short_doc, do: "Turns a Phoenix project into an application EHOS can govern"

  def example, do: "mix igniter.install ehos_app --example"

  def long_doc do
    """
    #{short_doc()}

    What it adds to the project:

      * `eh_os_contract`, wired the way its README prescribes: config, a migration,
        and a supervision child after the repo and Oban (Oban through its own installer)
      * `eh_os_contract.check` in the `precommit` alias
      * `ehos.yaml`, the declaration EHOS reads
      * `.tool-versions`, pinning the Erlang and Elixir the project was generated with
      * the agent harness: an EHOS section in `AGENTS.md` and a `CLAUDE.md` that loads it
      * a release and a Dockerfile, through `mix phx.gen.release --docker`

    ## Example

    ```sh
    #{example()}
    ```

    ## Options

      * `--example` - also generate an example contract, so `eh_os_contract.check`
        and the conformance report have something to read on day one
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.EhosApp.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias EhosApp.Toolchain

    # The engine is not on Hex, and Igniter's `pkg@github:` spec has no `sparse:`, so it
    # cannot be named on the `igniter.new` command line. The installer adds it instead,
    # pinned to a tag: `mix.lock` then pins the commit. The requirement next to the git
    # source is checked against the package's own `mix.exs`, so a tag that moves to an
    # incompatible version fails `deps.get` instead of compiling.
    @eh_os_contract {:eh_os_contract, "~> 0.2.1",
                     github: "EmpoweredHouse/eh-os-contract",
                     sparse: "packages/eh_os_contract",
                     tag: "v0.2.1"}

    # Where the contract DSL reference is inside the generated project. A `sparse:` git
    # dependency keeps its subdirectory under `deps/<name>/`, so the path follows it.
    @contract_docs Path.join([
                     "deps",
                     "eh_os_contract",
                     @eh_os_contract |> elem(2) |> Keyword.fetch!(:sparse),
                     "docs",
                     "contract.md"
                   ])

    # The EHOS section of `AGENTS.md` sits between these, so a later version of the
    # installer can replace it without touching the rest of the file.
    @agents_section ~r/<!-- ehos_app:agents -->.*?<!-- \/ehos_app:agents -->\n?/s
    @agents_start "<!-- ehos_app:agents -->"

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

    defp install(igniter, repo) do
      app = Igniter.Project.Application.app_name(igniter)

      igniter
      |> Igniter.Project.Deps.add_dep(@eh_os_contract)
      |> Igniter.Project.Config.configure_new("config.exs", :eh_os_contract, [:applications], [
        app
      ])
      |> Igniter.Project.Config.configure_new("config.exs", :eh_os_contract, [:repo], repo)
      |> Igniter.Libs.Ecto.gen_migration(repo, "add_eh_os_contract",
        body: """
        def up, do: EhOsContract.Migrations.up()

        def down, do: EhOsContract.Migrations.down()
        """,
        timestamp: migration_timestamp(igniter),
        on_exists: :skip
      )
      # At boot the engine writes the deployment row through the repo and reads the
      # handlers Oban runs, so it starts after both and before the endpoint.
      |> Igniter.Project.Application.add_new_child(EhOsContract, after: [repo, Oban])
      |> Igniter.Project.TaskAliases.add_alias(:precommit, "eh_os_contract.check",
        if_exists: :append
      )
      |> write_template("ehos.yaml", "ehos.yaml", app: app)
      |> tool_versions()
      |> harness()
      |> example_contract(igniter.args.options[:example])
      |> release()
      |> Igniter.add_notice("""
      EHOS: the project is ready. Start a database, then:

          mix ecto.setup
          mix precommit
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

    # A task, not a patch: the release and the Dockerfile stay whatever the project's own
    # Phoenix version generates, which is what `fly launch` relies on as well. Only when
    # there is no Dockerfile yet: `phx.gen.release` would otherwise offer to overwrite one
    # the developer has since changed, and a second run of this installer must change
    # nothing.
    defp release(igniter) do
      if Igniter.exists?(igniter, "Dockerfile") do
        igniter
      else
        Igniter.add_task(igniter, "phx.gen.release", ["--docker"])
      end
    end

    defp harness(igniter) do
      section = render("agents_section.md", contract_docs: @contract_docs)

      igniter
      |> Igniter.create_or_update_file("AGENTS.md", section, fn source ->
        Rewrite.Source.update(source, :content, &with_agents_section(&1, section))
      end)
      |> Igniter.create_new_file("CLAUDE.md", "@AGENTS.md\n", on_exists: :skip)
    end

    # A section from an earlier version is replaced in place. A start marker without its
    # end means the developer has edited the section, so it is left alone rather than
    # added a second time.
    defp with_agents_section(content, section) do
      cond do
        content =~ @agents_section ->
          String.replace(content, @agents_section, section, global: false)

        String.contains?(content, @agents_start) ->
          content

        true ->
          section <> "\n" <> content
      end
    end

    defp example_contract(igniter, true) do
      module = Igniter.Project.Module.module_name(igniter, "Contracts.CaseHandling")

      contents = render("example_contract.ex", contract_docs: @contract_docs)
      Igniter.Project.Module.create_module(igniter, module, contents, on_exists: :skip)
    end

    defp example_contract(igniter, _), do: igniter

    defp write_template(igniter, template, target, assigns) do
      Igniter.create_new_file(igniter, target, render(template, assigns), on_exists: :skip)
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

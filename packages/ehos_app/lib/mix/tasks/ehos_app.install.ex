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
      * `mix hex.audit` first in the `precommit` alias, through a function in `mix.exs` that
        stops the alias on a retired package or a security advisory in `mix.lock`
      * `eh_os_contract.check` in the `precommit` alias, and `eh_os_contract.schema --check`
        once the project has a contract or a lock; a new project's `eh_os_contract.lock` is
        recorded by the engine after the files are written
      * the health endpoints EHOS probes, on a port of their own
      * `ehos.yaml`, what EHOS is asked for, in the newest version EHOS defines
      * configuration from the variables EHOS gives an application at start
      * `ehos_design`, the EmpoweredHouse design system, as the default look: its layer
        imported in `assets/css/app.css` in place of Phoenix's daisyUI themes, and its fonts
        served by the endpoint. Declined once, by the comment above its import, it is never
        added back
      * a release and a Dockerfile, through `mix phx.gen.release --docker`, which reads the
        private `eh_os_contract` and `ehos_design` through a BuildKit secret and fetches
        Tailwind with curl
      * a GitHub Actions workflow: the gates, then the image by digest and the manifest
      * `.tool-versions`, pinning the Erlang and Elixir the project was generated with
      * the agent harness: `AGENTS.md` (Phoenix's own moves to `docs/phoenix.md`), with
        nested ones for the contracts and the web layer, `VISION.md`, `ARCHITECTURE.md`,
        `TESTING.md`, `docs/elixir.md` (how Elixir is written), a `README.md`, `.claude/settings.json` enabling the `ehos-app` plugin
        and its skills, `docs/platform-issues.md` (what the application asked of the platform),
        a CodeRabbit configuration, a pull request template, and
        `test/harness_test.exs`, which keeps the docs honest
      * the review gate: a hook in `.claude/settings.json` that refuses to open a pull request
        from a commit `mix ehos_app.review record` has not marked as reviewed, and a workflow,
        `review.yml`, that fails a pull request whose description does not record its review

    ## Running it again

    A project takes a later `ehos_app` by moving its dependency to it and running the installer
    again (ehos-tools T-02). What the project still has as an earlier version wrote it is
    brought to this version's. What the developer changed is theirs and is left as it is, except
    a section between a file's `<!-- ehos_app:<name> -->` and `<!-- /ehos_app:<name> -->`
    markers, which every run rewrites while both markers are there; where that leaves the
    project without something this version needs, a notice or a warning says what to do. A
    second run on a project this version made changes nothing.

    ## When it writes nothing

    It stops with an issue, and writes no file, when the project has no Ecto repo, which the
    contract engine keeps its event log in, and when the developer declines to move
    `eh_os_contract` and `eh_os_contract_auth` from `main`, or from a commit an earlier version
    pinned, to the release this version is written for.

    ## Example

    ```sh
    #{example()}
    ```

    ## Options

      * `--example` - also generate an example domain and contract, served under `/api`,
        so the tests, `eh_os_contract.check` and the manifest have something to read on day
        one, a page at `/entries/new` that records an entry as the person signed in, where the
        router has the `:browser` and `:signed_in` pipelines, does not name `/entries` and the
        project has no `EntryLive` or `Entries` of its own, and a page at `/design-system` that
        shows the design system
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
    @eh_os_contract_release "v0.13.1"
    @eh_os_contract_ref "3fab6550dc42664113cfb2a5ce9d907c8f9f4105"
    # The first commit with the browser-session Plug that signs people in through EHOS
    # (https://github.com/EmpoweredHouse/eh-os-contract/issues/78): what a project on a commit
    # of its own needs at least.
    @eh_os_contract_minimum "da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb"
    # The commits earlier versions of ehos_app pinned: eh-os-contract's release 0.12.0, which
    # 0.22.0 to 0.26.0 pinned; its release 0.10.0, which 0.21.0 pinned; its release 0.9.1, which
    # 0.20.0 pinned; its release 0.9.0, which 0.19.0 pinned; its release 0.7.0, which 0.16.0 to
    # 0.18.0 pinned; its release 0.6.0, which 0.15.0 pinned; its release 0.3.0, which 0.7.0 to
    # 0.14.0 pinned; ehos_app 0.3.0's and 0.4.0's; the one before 0.2.0; and 0.2's. A project on
    # one of them, or on `main`, which 0.5.0 to 0.6.1 followed (T-05), is moved to the release; a
    # project on any other commit or branch chose it, and keeps it.
    @earlier_eh_os_contract_refs [
      "190105d1fe87a7418cd1b92eadd29dba27edb3b3",
      "eb39d9903e48fc48a1504ceafdcf3aa27b222857",
      "ad4a7befc97b4902a1fda3959ce9ac20e4470bd9",
      "00cc0626828b5dc499932593c29689f3c259f5f2",
      "ad9b2b060e8c3583fd9b2a2b15ba14244c70e583",
      "01ef7aae7cee04b3d76bcfc4696b4084be77cb1a",
      "3304f355eb5d73058fa8fcf61813f9c0547f9fc6",
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

    # The record of every event's fields the engine keeps beside `mix.lock`.
    @schema_lock "eh_os_contract.lock"

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
    # commit tagged `ehos_design-v0.5.0` rather than to the tag, which nothing stops being
    # moved, as eh_os_contract is (T-11). The requirement is checked against the package's own
    # `mix.exs` when the project compiles (not by `deps.get`), so a commit of another minor
    # version fails there.
    @ehos_design_release EhosApp.requires()
                         |> Map.fetch!("ehos_design")
                         |> String.trim_leading("~> ")
    @ehos_design_ref "8b2de14f3c6f7768c5ddb9f74f0595ec44acddd0"
    @ehos_design {:ehos_design, Map.fetch!(EhosApp.requires(), "ehos_design"),
                  github: "EmpoweredHouse/ehos-tools",
                  sparse: "packages/ehos_design",
                  ref: @ehos_design_ref}
    # The commits earlier versions of ehos_app pinned, each with the requirement written beside
    # it: `ehos_design-v0.2.0`'s, which 0.6.0 to 0.23.0 pinned, and `ehos_design-v0.1.0`'s, which
    # 0.3.0 to 0.5.0 pinned. A project on one of them, written as they wrote it, is moved to this
    # version's; one on any other source chose it, and keeps it. A version that moves
    # `@ehos_design_ref` adds the one it replaces here.
    @earlier_ehos_design %{
      "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6" => "~> 0.2.0",
      "a65b9c86d920b5566f1c085b2286a44da77505c9" => "~> 0.1.0"
    }
    # 0.1.0's, whose projects ehos_app 0.3.0 to 0.5.0 gave neither the components' templates as a
    # source for Tailwind nor their hooks, which 0.2.0 and later need.
    @ehos_design_without_assets "a65b9c86d920b5566f1c085b2286a44da77505c9"

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

    # The skills reach the project as Claude Code plugins, which `.claude/settings.json` enables,
    # each from its repository's marketplace at the tag of its release (T-15), so an upgrade of a
    # plugin reaches every project through one line: `ehos-app`, the template's own skills, from
    # ehos-tools, and `eh-os-contract`, the skills for writing contracts, from eh-os-contract.
    # `ehos-app` comes from a marketplace of its own name, `ehos-app`, which ehos-tools publishes
    # from the file at `path:` beside its `ehos-tools` marketplace (T-16): Claude Code keeps one
    # copy of a marketplace per name for a user, and EHOS's own repositories pin `ehos-tools` at
    # another tag. 0.9 named it `ehos-tools`, `formerly:`, which an upgrade renames. A
    # test holds `ehos-app`'s tag to the version in `plugins/ehos-app/.claude-plugin/plugin.json`,
    # and another, with the network, `eh-os-contract`'s tag to the commit named here: settings
    # take a tag, never a commit (ehos-tools#134), so a moved tag is caught in CI. The skills there
    # describe the engine `@eh_os_contract_release` pins: a later plugin tag is taken with the
    # release of eh-os-contract its skills were written for.
    @plugin "ehos-app"
    @plugins [
               %{
                 name: @plugin,
                 marketplace: @plugin,
                 formerly: "ehos-tools",
                 repo: "EmpoweredHouse/ehos-tools",
                 path: ".claude-plugin/ehos-app.json",
                 tag: @plugin <> "-v",
                 version: "0.7.0"
               },
               %{
                 name: "eh-os-contract",
                 marketplace: "eh-os-contract",
                 repo: "EmpoweredHouse/eh-os-contract",
                 tag: "eh-os-contract-plugin-v",
                 version: "0.14.3",
                 commit: "f9242abf83d33bea76f2db52b28bbaba584769a8"
               }
             ]
             |> Enum.map(&Map.put(&1, :ref, &1.tag <> to_string(Version.parse!(&1.version))))

    # The skills 0.3.0 to 0.8.1 copied into `.agents/skills/` and linked from `.claude/skills/`,
    # each file by the SHA-256 of every version of it they wrote. A copy that is still one of
    # them is the template's, and is removed now that the plugin carries the skills; one the
    # developer changed, and any file of their own beside it, is theirs, and stays.
    @released_skills %{
      # Released with no newline at its end, and written into a project with one.
      "elixir-anti-patterns-review/LICENSE" => [
        "59899c6091b540582ed617e8eeaac4919dc985ccfc35459ee9752b699be5205b",
        "a6cba85bc92e0cff7a450b1d873c0eaa2e9fc96bf472df0247a26bec77bf3ff9"
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

    @doc """
    The release of eh-os-contract the installer pins `eh_os_contract` and `eh_os_contract_auth`
    to: its tag, and the commit that tag names, which is what the project's `mix.exs` gets, since
    a tag can be moved (ehos-tools T-11). A test with the network holds the two together.
    """
    @spec eh_os_contract_release() :: %{tag: String.t(), commit: String.t()}
    def eh_os_contract_release, do: %{tag: @eh_os_contract_release, commit: @eh_os_contract_ref}

    @doc """
    Where, relative to the project's root, the reference of the contract DSL is once the
    project's dependencies are fetched, which the docs and the example contract the installer
    writes point at.

        iex> Mix.Tasks.EhosApp.Install.contract_docs()
        "deps/eh_os_contract/packages/eh_os_contract/docs/contract.md"
    """
    @spec contract_docs() :: String.t()
    def contract_docs, do: @contract_docs

    @doc """
    Where, relative to the project's root, `ehos_design` is once the project's dependencies are
    fetched: `assets/css/app.css` imports its layer, and Tailwind reads its components, from
    there.

        iex> Mix.Tasks.EhosApp.Install.design_system()
        "deps/ehos_design/packages/ehos_design"
    """
    @spec design_system() :: String.t()
    def design_system, do: @design_system

    @doc """
    The ports the project's web endpoint and its health endpoints listen on, which its
    `ehos.yaml` declares: EHOS gives an application no `PORT`, and reads them from there
    (eh-os D-56).

        iex> Mix.Tasks.EhosApp.Install.ports()
        %{web: 4000, health: 4001}
    """
    @spec ports() :: %{web: pos_integer(), health: pos_integer()}
    def ports, do: %{web: @web_port, health: @health_port}

    @doc """
    Where, relative to the project's root, the JSON Schema of a version of `ehos.yaml` is once
    the project's dependencies are fetched, `version` being the part after the slash: `"v7"` for
    `ehos.yaml/v7`. `eh_os_contract_auth` carries every version EHOS defines, and the comment at
    the top of `ehos.yaml` points an editor at this path. A version it does not carry gives a
    path to no file.

        iex> Mix.Tasks.EhosApp.Install.ehos_yaml_schema("v7")
        "deps/eh_os_contract_auth/packages/eh_os_contract_auth/priv/schemas/ehos.yaml/v7.json"
    """
    @spec ehos_yaml_schema(String.t()) :: String.t()
    def ehos_yaml_schema(version), do: Path.join(@ehos_yaml_schemas, version <> ".json")

    @doc """
    The application's name in EHOS, which is its contract domain's name: the OTP
    application's name with dashes, since EHOS allows no underscore in it.

        iex> Mix.Tasks.EhosApp.Install.ehos_name(:my_shop)
        "my-shop"
    """
    @spec ehos_name(atom()) :: String.t()
    def ehos_name(app), do: app |> to_string() |> String.replace("_", "-")

    defp install(igniter, repo) do
      app = Igniter.Project.Application.app_name(igniter)
      web = Igniter.Libs.Phoenix.web_module(igniter)
      health = Module.concat(web, Health)
      endpoint = Module.concat(web, Endpoint)
      seed = Igniter.Project.Module.module_name(igniter, "Seed")
      name = ehos_name(app)

      # Read before the dependencies are raised or a migration generated.
      pins = contract_pins(igniter)
      upgrade? = verifier_behind?(igniter, repo)
      engine_behind? = engine_behind?(igniter, repo)
      # Every version of the installer wrote `ehos.yaml`: a project with one was made before.
      generated? = Igniter.exists?(igniter, "ehos.yaml")
      # A new project: phx.new's, untouched. Anything else has code of its own, which a check
      # that asks something of code may already fail.
      fresh? = not generated? and phoenix_home?(igniter, app)

      igniter
      |> contract_deps(pins)
      |> installer_for_development_only()
      |> contract_compiler()
      |> boundary_setup(fresh?)
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
      # HTTP/1.1 alone, as EHOS serves (eh-os#492): TLS ends at EHOS's ingress, which speaks
      # HTTP/1.1 to the pod, and Bandit's HTTP/2 stack has an advisory with no fix yet
      # (EEF-CVE-2026-105659), which a pod beside it could otherwise reach as h2c.
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        app,
        [endpoint, :http, :http_2_options],
        enabled: false
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
      |> telemetry(app, repo)
      |> log_redaction()
      |> migrations(repo, upgrade?, engine_behind?)
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
      |> without_phoenix_title(app)
      |> endpoint_last(endpoint)
      |> Igniter.Project.TaskAliases.add_alias(:precommit, "eh_os_contract.check",
        if_exists: :append
      )
      |> dependency_audit()
      |> test_warnings(fresh?)
      |> create_module(health, "health.ex", module: health, app: app)
      |> create_test(health, "health_test.exs", module: health)
      |> write_template("ehos.yaml", "ehos.yaml",
        web_port: @web_port,
        health_port: @health_port,
        version: EhosApp.ehos_yaml_version(),
        schema: current_schema(),
        app: app,
        seed: inspect(seed)
      )
      |> older_ehos_yaml()
      |> then(fn igniter ->
        # A new project's ehos.yaml names the seed, as one moved from v3 does; any other is the
        # developer's, and gets no module nothing runs, nor one they removed.
        if generated?,
          do: ehos_yaml_current(igniter, app, seed, repo, pins.eh_os_contract_auth != :other),
          else: seed(igniter, seed, app, repo, igniter.args.options[:example] == true, true)
      end)
      |> retire_schema_copies()
      |> write_template("rel_env.sh", "rel/env.sh.eex", [])
      |> license(generated?)
      |> ci_workflow()
      |> tool_versions()
      |> design_system(app, endpoint)
      # Before the harness, whose docs name the clock where the project has it.
      |> elixir_tools(app, web, repo, fresh?)
      |> callback_docs(app, fresh?)
      |> harness(app, web, igniter.args.options[:example])
      |> example(igniter.args.options[:example], app, web)
      |> boundaries(web, repo)
      |> release()
      |> schema_lock(generated? or pins.eh_os_contract != :none)
      # Last among precommit's steps, after the contract's checks, which the steps above add; only
      # where this run added Credo, which only a new project with no mocks module of its own gets.
      |> then(
        &if(&1.assigns[:ehos_app_credo?],
          do: Igniter.Project.TaskAliases.add_alias(&1, :precommit, "credo", if_exists: :append),
          else: &1
        )
      )
      |> Igniter.add_notice("""
      EHOS: the project is ready. Start a database, then:

          mix ecto.setup
          mix precommit

      eh_os_contract and ehos_design are read from private repositories. Build the image
      with a GitHub token that can read both, as a build secret. Every dependency's mix.exs
      runs where the token is, so prefer a fine-grained token that can read those two
      repositories alone to the one `gh auth token` prints. Set GITHUB_TOKEN from where you
      keep it rather than typing it, which leaves it in the shell's history, then:

          docker build --secret id=github_token,env=GITHUB_TOKEN .

      The CI workflow reads them through a GitHub App installed on eh-os-contract and
      ehos-tools with read access to their contents. Give the repository the App's ID and
      private key:

          gh secret set EHOS_CI_APP_ID --body <the App's ID>
          gh secret set EHOS_CI_APP_PRIVATE_KEY < <the App's private key>.pem
      """)
    end

    # `mix hex.audit` fails on a retired package or a security advisory in `mix.lock`, which
    # `mix deps.get` only prints (ehos-tools#507). Run as a task of the alias it would neither
    # run nor stop: after `compile`, which prunes the code paths that are not the project's,
    # Hex's archive among them (Elixir 1.20's `Mix.Tasks.Compile.All`), it is not found; and
    # Hex reports a finding by the status the VM halts with, not by raising, so every step
    # after it still runs and the alias ends green below the finding. So it runs first, as a
    # process of its own, from a function `mix.exs` defines. A plain "hex.audit" a project put
    # in the alias is replaced by it; a `hex_audit/1` the project defined, private or public, is
    # its own.
    @hex_audit Sourceror.parse_string!("&hex_audit/1")

    @hex_audit_function """
    # `mix hex.audit`, first in `precommit`, as a process of its own: run as a task of the alias,
    # it is not found after `compile`, and a finding does not stop the steps after it. Hex before
    # 2.6 passed an audit whose registry fetch failed, without checking the package, and before 2.5
    # audited retirements alone. The environment is passed on, since `preferred_envs` sets the
    # alias's but does not export it.
    defp hex_audit(_args) do
      Application.load(:hex)
      hex = to_string(Application.spec(:hex, :vsn) || "0.0.0")

      if Version.match?(hex, "< 2.6.0") do
        Mix.raise("mix hex.audit needs Hex 2.6.0 or later, and this is \#{hex}: run mix local.hex --force")
      end

      case Mix.shell().cmd("mix hex.audit", env: [{"MIX_ENV", to_string(Mix.env())}]) do
        0 ->
          :ok

        status ->
          Mix.raise("mix hex.audit exited with \#{status}: see TESTING.md, Dependency advisories",
            exit_status: status
          )
      end
    end
    """

    # The copy 0.22.0 to 0.24.0 wrote, which accepted Hex 2.5.1 (ehos-tools#537). One the
    # developer has not changed is replaced by the one above; one they changed is theirs, with a
    # notice.
    @hex_audit_function_2_5 """
    # `mix hex.audit`, first in `precommit`, as a process of its own: run as a task of the alias,
    # it is not found after `compile`, and a finding does not stop the steps after it. Hex before
    # 2.5 audits retirements alone, and passes a lock with advisories; 2.5.0 cannot acknowledge
    # one. The environment is passed on, since `preferred_envs` sets the alias's but does not
    # export it.
    defp hex_audit(_args) do
      Application.load(:hex)
      hex = to_string(Application.spec(:hex, :vsn) || "0.0.0")

      if Version.match?(hex, "< 2.5.1") do
        Mix.raise("mix hex.audit needs Hex 2.5.1 or later for advisories, and this is \#{hex}: run mix local.hex --force")
      end

      case Mix.shell().cmd("mix hex.audit", env: [{"MIX_ENV", to_string(Mix.env())}]) do
        0 ->
          :ok

        status ->
          Mix.raise("mix hex.audit exited with \#{status}: see TESTING.md, Dependency advisories",
            exit_status: status
          )
      end
    end
    """

    defp dependency_audit(igniter) do
      igniter
      |> Igniter.Project.TaskAliases.modify_existing_alias(:precommit, &audited_first/1)
      |> Igniter.update_elixir_file("mix.exs", &with_hex_audit/1)
      |> hex_floor_notice()
    end

    # A `hex_audit/1` the developer changed keeps what they wrote; where it still accepts the Hex
    # an earlier version did, they are told to raise it.
    defp hex_floor_notice(igniter) do
      if file_content(igniter, "mix.exs") =~ ~s[Version.match?(hex, "< 2.5.1")],
        do:
          Igniter.add_notice(igniter, """
          hex_audit/1 in mix.exs accepts Hex 2.5.1, whose mix hex.audit passes when it cannot
          fetch a package's registry entry, without checking it. Raise its check to
          Version.match?(hex, "< 2.6.0"), and run mix local.hex --force.
          """),
        else: igniter
    end

    # The tests compile with warnings as errors in `precommit` too, as `compile` does: a test
    # that warns (an unused variable, a deprecated call) fails the gate rather than scrolling
    # past. A plain "test" step is replaced; one with options of the project's own is kept.
    defp test_warnings(igniter, fresh?) do
      before = file_content(igniter, "mix.exs")

      igniter =
        Igniter.Project.TaskAliases.modify_existing_alias(igniter, :precommit, fn zipper ->
          zipper = Igniter.Code.Common.maybe_move_to_single_child_block(zipper)
          {:ok, test_step_warnings(zipper, Igniter.Code.List.list?(zipper))}
        end)

      if fresh? or file_content(igniter, "mix.exs") == before,
        do: igniter,
        else:
          Igniter.add_notice(igniter, """
          mix precommit now runs test --warnings-as-errors, so a test that compiles with a
          warning fails it, as code does: run it, and fix what it reports.
          """)
    end

    defp test_step_warnings(zipper, false = _list?), do: zipper

    defp test_step_warnings(zipper, true) do
      case Igniter.Code.List.replace_in_list(
             zipper,
             &(Sourceror.to_string(&1.node) == ~s("test")),
             Sourceror.parse_string!(~s("test --warnings-as-errors"))
           ) do
        {:ok, replaced} -> replaced
        :error -> zipper
      end
    end

    # Compared as source: Igniter's `nodes_equal?/2` does not match a parsed capture with the
    # one in the file, which would add it again on every run.
    defp audited_first(zipper) do
      zipper = Igniter.Code.Common.maybe_move_to_single_child_block(zipper)
      audited_first(zipper, Igniter.Code.List.list?(zipper) and audits(zipper.node))
    end

    # The function first and no other audit already; or not a list, which the contract check's
    # step makes it.
    defp audited_first(_zipper, at) when at in [[{0, "&hex_audit/1"}], false], do: :error

    defp audited_first(zipper, _at) do
      with {:ok, zipper} <- Igniter.Code.List.remove_from_list(zipper, &audit?/1),
           do: Igniter.Code.List.prepend_to_list(zipper, @hex_audit)
    end

    # Where the alias runs an audit, and which: the function or a plain task.
    defp audits(steps) do
      for {step, i} <- Enum.with_index(steps), audit?(step), do: {i, Sourceror.to_string(step)}
    end

    defp audit?(%Sourceror.Zipper{node: node}), do: audit?(node)
    defp audit?(node), do: Sourceror.to_string(node) in [~s("hex.audit"), "&hex_audit/1"]

    defp with_hex_audit(zipper) do
      with :error <- earlier_hex_audit(zipper),
           :error <- Igniter.Code.Function.move_to_defp(zipper, :hex_audit, 1),
           :error <- Igniter.Code.Function.move_to_def(zipper, :hex_audit, 1),
           {:ok, zipper} <- Igniter.Code.Module.move_to_defmodule(zipper),
           {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
        {:ok, Igniter.Code.Common.add_code(zipper, @hex_audit_function)}
      else
        {:replaced, zipper} ->
          {:ok, zipper}

        {:ok, _defined} ->
          {:ok, zipper}

        :error ->
          {:warning,
           """
           mix.exs defines no module, so `hex_audit/1`, which `precommit` runs first, was not
           added to it. Define it as TESTING.md, "Dependency advisories", says.
           """}
      end
    end

    # `{:replaced, zipper}` with the earlier copy replaced, where `mix.exs` holds it as written;
    # `:error` otherwise, for `with_hex_audit/1` to go on.
    defp earlier_hex_audit(zipper) do
      with {:ok, body} <- Igniter.Code.Function.move_to_defp(zipper, :hex_audit, 1),
           true <- Sourceror.to_string(body.node) == hex_audit_body(@hex_audit_function_2_5),
           %Sourceror.Zipper{} = defp <- defp_of(body) do
        {:replaced, Sourceror.Zipper.replace(defp, Sourceror.parse_string!(@hex_audit_function))}
      else
        _ -> :error
      end
    end

    # The body of the one function `source` defines, as source, which a defp's zipper is moved to.
    defp hex_audit_body(source) do
      {:ok, body} =
        source
        |> Sourceror.parse_string!()
        |> Sourceror.Zipper.zip()
        |> Igniter.Code.Function.move_to_defp(:hex_audit, 1)

      Sourceror.to_string(body.node)
    end

    # The `defp` whose body `zipper` is: its leading comment goes with it when it is replaced.
    defp defp_of(nil), do: nil
    defp defp_of(%{node: {:defp, _, _}} = zipper), do: zipper
    defp defp_of(zipper), do: defp_of(Sourceror.Zipper.up(zipper))

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

    # Boundary holds the areas apart at compile time: the web reaches only what the
    # application's root exports, and each context only the siblings it lists. A new project,
    # one still on Phoenix's welcome page byte for byte, is given it, its compiler first;
    # `boundaries/3` places the declarations once the run has written the modules they name.
    # Any other project, made before or a Phoenix project of its own, is told how to adopt it
    # instead, since its code may already cross what the boundaries would forbid. A project
    # that has Boundary already keeps its own declarations, and the templates declare theirs.
    @boundary_deps [{:boundary, "~> 0.12", runtime: false}]

    defp boundary_setup(igniter, fresh?) do
      cond do
        Igniter.Project.Deps.has_dep?(igniter, :boundary) ->
          Igniter.assign(igniter, :ehos_app_boundary_own?, true)

        not fresh? ->
          Igniter.add_notice(igniter, """
          docs/elixir.md's areas are held by Boundary in a new project: the web reaches only
          what the application's root module exports, and each context only the siblings it
          lists. The installer does not add it to a project with code of its own, which may
          already cross them; to adopt it, add {:boundary, "~> 0.12", runtime: false}, put
          :boundary first in the project's compilers, and `use Boundary` in the root, web,
          application and repo modules as the `ehos-app:elixir` skill shows, then fix what
          `mix compile --warnings-as-errors` reports.
          """)

        true ->
          boundary(igniter)
      end
    end

    defp boundary(igniter) do
      igniter
      |> add_deps(@boundary_deps)
      |> Igniter.Project.MixProject.update(:project, [:compilers], fn
        nil ->
          {:ok, {:code, quote(do: [:boundary] ++ Mix.compilers())}}

        zipper ->
          compilers = zipper |> Sourceror.Zipper.node() |> Sourceror.to_string()

          cond do
            compilers =~ ":boundary" ->
              {:ok, zipper}

            String.starts_with?(compilers, "[") ->
              {:ok, {:code, "[:boundary, " <> String.slice(compilers, 1..-1//1)}}

            true ->
              {:ok, {:code, "[:boundary] ++ " <> compilers}}
          end
      end)
      |> Igniter.assign(:ehos_app_boundary?, true)
    end

    # The root exports what the application and the web call of it, the web its endpoint, and
    # the application, which starts both, is a boundary of its own above them. The repo is a
    # sub-boundary, so the web cannot reach it and a context lists it to; `ConnCase` is
    # outside every boundary, since a test's case sets up what the data's case does. A module
    # the run cannot find, or that already uses Boundary, is left as it is, with a notice for
    # the former.
    defp boundaries(igniter, web, repo) do
      if igniter.assigns[:ehos_app_boundary?] do
        prefix = Igniter.Project.Module.module_name_prefix(igniter)

        exports =
          [
            igniter.assigns[:ehos_app_access?] && "Access",
            # The example's context, which its page calls.
            igniter.assigns[:ehos_app_entries?] && "Entries",
            "LogRedaction"
          ]
          |> Enum.filter(& &1)
          |> Enum.join(", ")

        [
          {prefix, "use Boundary, deps: [], exports: [#{exports}]", :after_use},
          {web, "use Boundary, deps: [#{inspect(prefix)}], exports: [Endpoint]", :after_use},
          {Module.concat(prefix, Application),
           "use Boundary, top_level?: true, deps: [#{inspect(prefix)}, #{inspect(web)}]",
           :after_use},
          {repo, "use Boundary", :after_use},
          # Before the case's own `use`, which the run has put its setup after.
          {Module.concat(web, ConnCase),
           "# Outside every boundary: a test's case sets up what the data's case does.\n" <>
             "use Boundary, top_level?: true, check: [in: false, out: false]", :first}
        ]
        |> Enum.reduce(igniter, fn {module, line, at}, igniter ->
          use_boundary(igniter, module, line, at)
        end)
      else
        igniter
      end
    end

    defp use_boundary(igniter, module, line, at) do
      case Igniter.Project.Module.find_and_update_module(
             igniter,
             module,
             &put_use_boundary(&1, line, at)
           ) do
        {:ok, igniter} ->
          igniter

        {:error, igniter} ->
          Igniter.add_notice(igniter, """
          #{inspect(module)} was not found, so it does not declare its boundary. Add to it:

              #{line}
          """)
      end
    end

    # After the module's own `use`s, or its moduledoc, or first; once. Never before a `use`
    # (Igniter finds a repo by the first `use` in its module, as other installers do theirs),
    # unless `at` is `:first`, which goes after the moduledoc.
    defp put_use_boundary(zipper, line, at) do
      body = Sourceror.Zipper.node(zipper)

      nodes =
        case body do
          {:__block__, _, nodes} when is_list(nodes) -> nodes
          _ -> [body]
        end

      uses = if at == :after_use, do: last_index(nodes, &match?({:use, _, _}, &1))
      moduledoc = last_index(nodes, &match?({:@, _, [{:moduledoc, _, _}]}, &1))

      cond do
        Enum.any?(nodes, &boundary_use?/1) ->
          {:ok, zipper}

        nodes == [] ->
          {:ok, Sourceror.Zipper.replace(zipper, Sourceror.parse_string!(line))}

        uses != nil ->
          {:ok, add_after(zipper, nodes, uses, line)}

        moduledoc != nil ->
          {:ok, add_after(zipper, nodes, moduledoc, line)}

        true ->
          {:ok,
           Igniter.Code.Common.add_code(nth_child(zipper, nodes, 0), line, placement: :before)}
      end
    end

    # A `use Boundary` the module declares, read as code: one a moduledoc mentions is not.
    defp boundary_use?({:use, _, [{:__aliases__, _, [:Boundary]} | _]}), do: true
    defp boundary_use?(_node), do: false

    defp add_after(zipper, nodes, at, line),
      do: Igniter.Code.Common.add_code(nth_child(zipper, nodes, at), line, placement: :after)

    defp last_index(nodes, fun) do
      nodes
      |> Enum.with_index()
      |> Enum.filter(&fun.(elem(&1, 0)))
      |> List.last()
      |> then(&(&1 && elem(&1, 1)))
    end

    # A single expression is the body itself; a block's nth expression is reached from its first.
    defp nth_child(zipper, [_], 0), do: zipper

    defp nth_child(zipper, _nodes, at),
      do:
        Enum.reduce(1..at//1, Sourceror.Zipper.down(zipper), fn _, z ->
          Sourceror.Zipper.right(z)
        end)

    defp runtime_config(igniter, app, repo) do
      path = "config/runtime.exs"

      if Igniter.exists?(igniter, path) do
        igniter
        |> drop_port(path)
        |> ehos_runtime(path, "EHOS_ISSUER", render("runtime_prod.exs", app: app, repo: repo))
        |> ehos_runtime(
          path,
          ["EHOS_SIGN_IN_APPLICATIONS", "EHOS_CLIENT_ID"],
          render("runtime_sign_in.exs", app: app)
        )
        |> sign_in_limit(path)
        |> sign_in_condition(path)
      else
        Igniter.add_warning(igniter, """
        config/runtime.exs was not found, so the application is not configured from the
        variables EHOS gives it at start. Add the block in
        #{Path.join(:code.priv_dir(:ehos_app), "templates/ehos_app.install/runtime_prod.exs.eex")}
        to its `config_env() == :prod` section.
        """)
      end
    end

    # eh-os D-93 (Stage 15, eh-os#485): each line one JSON object, as EHOS writes its own, with the
    # request, its trace and its span, and the business work's correlation, which the engine puts
    # in the Logger's metadata (eh-os-contract#298); and the application's traces sent over OTLP
    # to the collector EHOS names, and nowhere when it names none, as on a laptop and in CI.
    # Phoenix 1.8 serves through Bandit, whose instrumentation gives a request the span Phoenix's
    # and Ecto's hang from.
    @logging_deps [{:logger_json, "~> 7.0"}]
    @tracing_deps [
      # Before the SDK, which looks for its exporter when it starts.
      {:opentelemetry_exporter, "~> 1.11"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_api, "~> 1.5"},
      # A 0.x minor may change `setup/1`'s options.
      {:opentelemetry_bandit, "~> 0.3.0"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"}
    ]

    # What a line's metadata never shows, whatever code put it there.
    @redacted_keys ~w(password secret token authorization cookie)

    @doc """
    The packages the installer adds to the project's `mix.exs` for its logs and traces (eh-os
    D-93), each with the requirement it writes: the JSON logger first, then OpenTelemetry's.
    """
    @spec telemetry_deps() :: [{atom(), String.t()}]
    def telemetry_deps, do: @logging_deps ++ @tracing_deps

    # The line the installer puts above its tracing calls in `start/2`, by which a later run knows
    # the tracing for its own.
    @tracing_marker "# eh-os D-93: a trace of each request and query, sent where EHOS says, if it says."

    # A project that already chose how it logs, or traces, keeps that choice whole: what it has is
    # read before anything is added, and the run adds the other part alone, saying what it left.
    # What an earlier run of the installer set up is not such a choice, and is set up again.
    defp telemetry(igniter, app, repo) do
      {igniter, formatters} = logger_formatters(igniter)

      own_logging? =
        Enum.any?(formatters, &(&1 != {"config/prod.exs", LoggerJSON.Formatters.Elastic})) or
          (formatters == [] and Igniter.Project.Deps.has_dep?(igniter, :logger_json))

      application = application_source(igniter)

      # Bandit's instrumentation set up by the project counts as its tracing too, even without the
      # SDK: setting the rest up beside it would leave its call as it is, taking a caller's trace.
      own_tracing? =
        (Igniter.Project.Deps.has_dep?(igniter, :opentelemetry) or
           calls?(application, OpentelemetryBandit, :setup)) and
          not (application =~ @tracing_marker)

      igniter
      |> then(&if(own_logging?, do: logging_notice(&1), else: json_logging(&1)))
      |> then(&if(own_tracing?, do: tracing_notice(&1), else: tracing(&1, app, repo)))
    end

    # Each formatter of the default handler a config file names, wherever in it: at the top or in
    # a block, such as runtime.exs's `if config_env() == :prod do`. Read as code, so a comment
    # naming one counts for nothing. A formatter named by a module alone, or by a variable, is
    # `nil`, which is still the project's own.
    defp logger_formatters(igniter) do
      ~w(config/config.exs config/prod.exs config/runtime.exs)
      |> Enum.filter(&Igniter.exists?(igniter, &1))
      |> Enum.reduce({igniter, []}, fn path, {igniter, found} ->
        igniter = Igniter.include_existing_file(igniter, path)

        formatters =
          case Code.string_to_quoted(file_content(igniter, path), emit_warnings: false) do
            {:ok, ast} -> ast |> configured_formatters() |> Enum.map(&{path, &1})
            {:error, _} -> []
          end

        {igniter, found ++ formatters}
      end)
    end

    defp configured_formatters(ast) do
      {_, found} =
        Macro.prewalk(ast, [], fn
          {:config, _, [:logger, :default_handler, options]} = node, found ->
            {node, formatter(options, found)}

          {:config, _, [:logger, options]} = node, found when is_list(options) ->
            if Keyword.keyword?(options) and Keyword.has_key?(options, :default_handler),
              do: {node, formatter(options[:default_handler], found)},
              else: {node, found}

          node, found ->
            {node, found}
        end)

      found
    end

    # Options the code computes, such as a variable, may name a formatter, so they count as one
    # of the project's own.
    defp formatter(options, found) when not is_list(options), do: [nil | found]

    defp formatter(options, found) do
      if Keyword.keyword?(options) and Keyword.has_key?(options, :formatter),
        do: [formatter_module(options[:formatter]) | found],
        else: found
    end

    defp formatter_module({{:__aliases__, _, parts}, _}) do
      if Enum.all?(parts, &is_atom/1), do: Module.concat(parts)
    end

    defp formatter_module(_other), do: nil

    defp application_source(igniter) do
      with app when not is_nil(app) <- Igniter.Project.Application.app_module(igniter),
           module = with({module, _} <- app, do: module),
           {:ok, {_igniter, source, _zipper}} <-
             Igniter.Project.Module.find_module(igniter, module) do
        Rewrite.Source.get(source, :content)
      else
        _ -> ""
      end
    end

    defp json_logging(igniter) do
      igniter
      |> add_deps(@logging_deps)
      |> Igniter.Project.Config.configure_new(
        "prod.exs",
        :logger,
        [:default_handler, :formatter],
        # Parsed from text: Igniter writes a quoted tuple that holds a keyword list wrongly.
        {:code,
         Sourceror.parse_string!("""
         {LoggerJSON.Formatters.Elastic,
          metadata: [:request_id, :correlation_id],
          redactors: [{LoggerJSON.Redactors.RedactKeys, #{inspect(@redacted_keys)}}]}
         """)}
      )
    end

    defp tracing(igniter, app, repo) do
      igniter
      |> add_deps(@tracing_deps)
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        :opentelemetry,
        [:traces_exporter],
        :none
      )
      |> then(fn igniter ->
        if Igniter.exists?(igniter, "config/runtime.exs") do
          ehos_runtime(
            igniter,
            "config/runtime.exs",
            "OTEL_EXPORTER_OTLP_ENDPOINT",
            render("runtime_traces.exs", [])
          )
        else
          Igniter.add_warning(igniter, """
          config/runtime.exs was not found, so the application sends no traces, even where EHOS
          names a collector. Add this block to its `config_env() == :prod` section:

          #{render("runtime_traces.exs", [])}
          """)
        end
      end)
      |> instrumented(repo)
      |> sdk_temporary(app)
    end

    # Each prepended, so they end in the order given.
    defp add_deps(igniter, deps) do
      yes? = igniter.args.options[:yes]

      deps
      |> Enum.reverse()
      |> Enum.reduce(igniter, &Igniter.Project.Deps.add_dep(&2, &1, on_exists: :skip, yes?: yes?))
    end

    defp logging_notice(igniter) do
      Igniter.add_notice(igniter, """
      EHOS: the project already chose how it logs, so its logging was left as it is. For EHOS's
      console and `ehosctl logs` to show a line's level and fields, log one JSON object a line in
      production, for instance with logger_json's formatter in config/prod.exs:

          config :logger, :default_handler,
            formatter:
              {LoggerJSON.Formatters.Elastic,
               metadata: [:request_id, :correlation_id],
               redactors: [{LoggerJSON.Redactors.RedactKeys, #{inspect(@redacted_keys)}}]}
      """)
    end

    defp tracing_notice(igniter) do
      Igniter.add_notice(igniter, """
      EHOS: the project already has `opentelemetry`, so its tracing was left as it is. For EHOS
      to take its traces:

      - export them over OTLP only when OTEL_EXPORTER_OTLP_ENDPOINT is set, which EHOS sets to
        its collector's address: `traces_exporter: :none` in config/config.exs, and
        `config :opentelemetry, traces_exporter: :otlp` in config/runtime.exs when it is set;
      - take no caller's trace as a request's parent: OpentelemetryBandit.setup(public_endpoint: true),
        or the same option of the instrumentation the project serves through.
      """)
    end

    # The instrumentations attach to telemetry events before anything emits them, at the top of
    # the application's `start/2`. Bandit's takes no trace a caller sends as its parent: a
    # `traceparent` from the internet would otherwise put a trace id of the caller's choosing on
    # the application's lines.
    defp instrumented(igniter, repo) do
      prefix = repo |> Module.split() |> Enum.map(&String.to_atom(Macro.underscore(&1)))

      setup = """
      #{@tracing_marker}
      OpentelemetryBandit.setup(public_endpoint: true)
      OpentelemetryPhoenix.setup(adapter: :bandit)
      OpentelemetryEcto.setup(#{inspect(prefix)})
      """

      at_start(igniter, OpentelemetryBandit, :setup, setup)
    end

    # Whether the code calls `module.fun`: read as code, so a comment naming it counts for nothing.
    defp calls?(code, module, fun) do
      parts = module |> Module.split() |> Enum.map(&String.to_atom/1)

      quoted =
        case Code.string_to_quoted(code, emit_warnings: false) do
          {:ok, quoted} -> quoted
          {:error, _} -> nil
        end

      {_, found?} =
        Macro.prewalk(quoted, false, fn
          {{:., _, [{:__aliases__, _, ^parts}, ^fun]}, _, _} = node, _found? -> {node, true}
          node, found? -> {node, found?}
        end)

      found?
    end

    # ehos-tools#234: what a crashed process held stays out of its report, which whoever may read
    # the application's logs in EHOS reads: its state and last message inspected as `%{...}`, and a
    # filter, put first at the top of `start/2`, that leaves a stack frame its arity in place of
    # its arguments.
    defp log_redaction(igniter) do
      module = Module.concat(Igniter.Project.Module.module_name_prefix(igniter), LogRedaction)

      igniter
      |> create_module(module, "log_redaction.ex", module: module)
      |> create_test(module, "log_redaction_test.exs", module: module)
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        :logger,
        [:translator_inspect_opts],
        limit: 0,
        printable_limit: 0
      )
      |> at_start(module, :install, """
      # #{inspect(module)}: a crashed process's report keeps out what it held.
      #{inspect(module)}.install()
      """)
    end

    # `code` at the top of the application's `start/2`, unless it already calls `module.fun`.
    defp at_start(igniter, module, fun, code) do
      case Igniter.Project.Application.app_module(igniter) do
        nil ->
          igniter

        app ->
          app = with {app_module, _} <- app, do: app_module

          Igniter.Project.Module.find_and_update_module!(
            igniter,
            app,
            &start_with(&1, module, fun, code)
          )
      end
    end

    defp start_with(zipper, module, fun, code) do
      with {:ok, start} <- Igniter.Code.Function.move_to_def(zipper, :start, 2),
           false <-
             start |> Sourceror.Zipper.node() |> Sourceror.to_string() |> calls?(module, fun) do
        {:ok, Igniter.Code.Common.add_code(first_expression(start), code, placement: :before)}
      else
        _ -> {:ok, zipper}
      end
    end

    defp first_expression(start) do
      case Sourceror.Zipper.node(start) do
        {:__block__, _, [_ | _]} -> Sourceror.Zipper.down(start)
        _single -> start
      end
    end

    # The SDK started `:temporary`, as its documentation advises: if it stops, the application
    # serves on without its traces, rather than the release stopping with it (eh-os FM-10). Only
    # in the release named after the application, and only when the project names no other: a
    # second release would make `mix release` ask which one.
    defp sdk_temporary(igniter, app) do
      Igniter.Project.MixProject.update(igniter, :project, [:releases], fn
        nil ->
          {:ok, {:code, quote(do: [{unquote(app), [applications: [opentelemetry: :temporary]]}])}}

        releases ->
          {:ok, sdk_temporary_in(releases, app)}
      end)
    end

    # What the release already says of the SDK stays. Options the code computes, such as
    # `[app: release_options()]`, cannot be written into, and stay as they are.
    defp sdk_temporary_in(releases, app) do
      with true <- Igniter.Code.Keyword.keyword_has_path?(releases, [app]),
           {:ok, releases} <-
             Igniter.Code.Keyword.put_in_keyword(
               releases,
               [app, :applications, :opentelemetry],
               :temporary,
               &{:ok, &1}
             ) do
        releases
      else
        _ -> releases
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
            port_warning(zipper)
        end
      end)
    end

    defp port_warning(zipper) do
      if Sourceror.to_string(Sourceror.Zipper.root(zipper)) =~ ~s|"PORT"|,
        do:
          {:warning,
           "config/runtime.exs reads `PORT`, which EHOS does not set: the endpoint " <>
             "listens on port #{@web_port}, the port `ehos.yaml` declares."},
        else: {:ok, zipper}
    end

    defp reads_port?(zipper) do
      zipper |> Sourceror.Zipper.node() |> Sourceror.to_string() =~ ~s|System.get_env("PORT"|
    end

    # A block goes in once: `markers`, variables it reads, say it is there, read as code; any one
    # of them is enough. The sign-in block's are both the variable it is keyed on and the client
    # an earlier version keyed it on, so a block the developer changed or removed, beside code of
    # their own that reads the client, is not added again.
    defp ehos_runtime(igniter, path, markers, block) do
      Igniter.update_elixir_file(igniter, path, fn zipper ->
        root = Sourceror.Zipper.root(zipper)

        if Enum.any?(List.wrap(markers), &names?(root, &1)),
          do: {:ok, zipper},
          else: in_prod_block(zipper, block)
      end)
    end

    defp in_prod_block(zipper, block) do
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

    # eh_os_contract_auth 0.4.0 ends a session when EHOS ends the person's, from the limit EHOS
    # gives as `EHOS_SIGN_IN_ABSOLUTE` (eh-os D-113); without it, a session lasts twelve hours
    # whatever the installation sets. A new project's block reads it. One an earlier version
    # wrote is the developer's code by now, so the line is said rather than added.
    defp sign_in_limit(igniter, path) do
      with {:ok, source} <- Rewrite.source(igniter.rewrite, path),
           ast = source |> Rewrite.Source.get(:content) |> Sourceror.parse_string!(),
           true <-
             names?(ast, "EHOS_SIGN_IN_APPLICATIONS") and not names?(ast, "EHOS_SIGN_IN_ABSOLUTE") do
        Igniter.add_notice(igniter, """
        #{path} signs people in without `absolute_limit`, so a session lasts twelve hours
        whatever EHOS's installation sets (eh-os D-113). Add it to the `sign_in:` list there, as
        #{@auth_readme} says:

            absolute_limit: String.to_integer(System.get_env("EHOS_SIGN_IN_ABSOLUTE", "43200"))
        """)
      else
        _ -> igniter
      end
    end

    # EHOS gives `EHOS_CLIENT_ID` to a workload that reads the people (eh-os D-81) or sends mail
    # (eh-os D-140) as well as to one that signs people in, and `EHOS_SIGN_IN_APPLICATIONS` only to
    # the last. A block an earlier version wrote signs people in wherever the first is given; it
    # is the developer's code by now, so the condition is said rather than changed.
    defp sign_in_condition(igniter, path) do
      with {:ok, source} <- Rewrite.source(igniter.rewrite, path),
           zipper =
             source
             |> Rewrite.Source.get(:content)
             |> Sourceror.parse_string!()
             |> Sourceror.Zipper.zip(),
           {:ok, _call} <-
             Igniter.Code.Function.move_to_function_call(zipper, :if, 2, &signs_in_on_client?/1) do
        Igniter.add_notice(igniter, """
        #{path} signs people in wherever EHOS gives `EHOS_CLIENT_ID`, which it gives as well to
        an application that reads the people or sends mail without declaring `sign_in` in
        ehos.yaml. Such an application would start signing people in. Make the block's condition
        the variable EHOS gives only with `sign_in`:

            if ehos_sign_in_applications = System.get_env("EHOS_SIGN_IN_APPLICATIONS") do

        with `client_id: System.fetch_env!("EHOS_CLIENT_ID")` and
        `applications: Jason.decode!(ehos_sign_in_applications)` in its `sign_in:` list.
        """)
      else
        _ -> igniter
      end
    end

    # An `if` whose condition reads `EHOS_CLIENT_ID` but not `EHOS_SIGN_IN_APPLICATIONS`, and
    # which configures `sign_in:`, read as code. The whole call is read, since its body alone does
    # not parse.
    defp signs_in_on_client?(call) do
      Igniter.Code.Function.argument_matches_predicate?(call, 0, fn condition ->
        condition = Sourceror.Zipper.node(condition)
        names?(condition, "EHOS_CLIENT_ID") and not names?(condition, "EHOS_SIGN_IN_APPLICATIONS")
      end) and call |> Sourceror.Zipper.node() |> configures?(:sign_in)
    end

    # Whether the code holds the keyword `key`, as `config :eh_os_contract_auth, sign_in: […]` does.
    defp configures?(ast, key) do
      {:ok, quoted} = ast |> Sourceror.to_string() |> Code.string_to_quoted(emit_warnings: false)

      {_, found?} =
        Macro.prewalk(quoted, false, fn
          {^key, _value} = node, _found? -> {node, true}
          node, found? -> {node, found?}
        end)

      found?
    end

    # Whether the code holds the string `name`, as `System.get_env("NAME")` does: read as code, so
    # a comment naming it counts for nothing.
    defp names?(ast, name) do
      {:ok, quoted} = ast |> Sourceror.to_string() |> Code.string_to_quoted(emit_warnings: false)

      {_, found?} =
        Macro.prewalk(quoted, false, fn
          ^name = node, _found? -> {node, true}
          node, found? -> {node, found?}
        end)

      found?
    end

    # The verifier's tables at version 3, which holds the people signed in through EHOS. A new
    # project's migration names it, so a later version of the package adds a migration of its
    # own, as the package prescribes. A project whose migration went to an earlier version, or
    # to whichever was current when it ran (`up()`, as 0.2 wrote it), adds one for version 3.
    @verifier_version 3

    # The engine's tables at version 4, which records each deployment's words beside its
    # agreement (eh-os-contract 0.5.0): the engine refuses to start on version 3. A new project's
    # migration names it, as the verifier's does; one that migrated them before, with `up()` as
    # earlier versions wrote it, adds a migration for version 4, as the package prescribes.
    @engine_version 4

    defp migrations(igniter, repo, upgrade?, engine_behind?) do
      igniter
      |> migration(
        repo,
        "add_eh_os_contract",
        "EhOsContract.Migrations",
        "version: #{@engine_version}",
        ""
      )
      |> then(fn igniter ->
        if engine_behind?,
          do:
            migration(
              igniter,
              repo,
              "upgrade_eh_os_contract_to_v#{@engine_version}",
              "EhOsContract.Migrations",
              "version: #{@engine_version}",
              "version: #{@engine_version}"
            ),
          else: igniter
      end)
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

    defp migration(igniter, repo, name, module, up_args, down_args) do
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
    # which 0.4.0 wrote too, 0.5.0's, which 0.5.1 and 0.6.0 wrote too, 0.6.1's, which 0.7.0
    # wrote too, 0.8.0's, which every version to 0.14.0 wrote too, 0.15.0's, 0.16.0's, 0.17.0's,
    # 0.18.0's, 0.19.0's, which 0.20.0 and 0.21.0 wrote too, 0.22.0's, 0.23.0's, which 0.24.0
    # wrote too, and 0.25.0's. The template takes no assigns, so a version wrote the same bytes
    # into every project. A release that changes `ci.yml.eex` adds the hash of what it replaces
    # here, and that file to test/fixtures/ci_workflows/.
    @earlier_ci_workflows [
      "4c1a95dfe62e3d2f429b260416d4b4e2b3266de0281ee351bf514f04c6320743",
      "0f26900d5726a2c9510365b943ac4246e57b81d80ac57dd434901bcd47733c61",
      "a337aee941927815d00b6ec4ab5a9e9b2420c4ecf9f16e850eaa4bbce2c8c96b",
      "e6f929d1710235d21f2bed3e3ff9a23cdd0a5dec1dc91b8d3eacc7359d16cad9",
      "c29bbb2630ad1b77dc173d1474b85bb014fe7ea6d0e69b0d5132120c4291d7e0",
      "6c1b9402a89d7b42a210d86ecb56cea0878d00592c48de74e4bce002bb63c3e5",
      "74bf8da3f096b1568ba559a25b8cd437158242b6b8f5edf843ee1049469fba9c",
      "766daa369320dcefd1224c37a85c87db2ec1b44aa5ec34899c0ec3bb1125c6c2",
      "a871cae57fa84413671b92939b58dc39344ba36c52f5c7028ef2a29b6d6162f2",
      "22c63221a445ed24f87bdf0bda35d0776d9297f073a221bf8da6984689d2e8e6",
      "ffba821598256b9b22d90a2810dfa14533a577246cb50a5ec97f5b138ec4d015",
      "4f41977ec707ace0c5dda8c0caa3b91caf028c05c44dddcdb64d4eca2fc5f0f2",
      "ce9d57c85b5d5c6869ac92053559419134e101911a76f09e89fa6ca9e6325125",
      "74f5aa3a3a11f825d49823fa7a094e894635b4a41f9cdff6a4e1f0d376bf1407"
    ]

    # The workflow is the developer's once they change it. One that is still, byte for byte,
    # what an earlier version wrote was never changed, so it is replaced by this version's
    # (T-02); 0.2's read eh-os-contract alone and checked the lock against half its
    # dependencies (ehos-tools#38). One the developer changed is left, with the diff to this
    # version's.
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
    # nothing. The Dockerfile it writes is then given the build secret and Tailwind's fetch
    # by a second task, since it does not exist until the first has run.
    defp release(igniter) do
      if Igniter.exists?(igniter, "Dockerfile") do
        Igniter.compose_task(igniter, "ehos_app.dockerfile")
      else
        igniter
        |> Igniter.add_task("phx.gen.release", ["--docker"])
        |> Igniter.add_task("ehos_app.dockerfile", ["--yes"])
      end
    end

    # eh-os-contract 0.7.0's `eh_os_contract.lock` records every event's fields, and
    # `mix eh_os_contract.schema --check` fails on a change old rows would not read
    # (ehos-tools#274). The lock is worth something only when it is recorded before any event
    # changes, and `--check` fails while there is none, so a new project's is recorded by the engine
    # once the files are written, rather than by its first `mix precommit`. A project that had the
    # engine before this run, one an earlier version made or one that added it by hand, is told to
    # record it instead: the task compiles the project, whose contracts may not compile on this
    # engine yet, and a task that fails ends the run before Igniter prints its notices. So the
    # task records only contracts this run wrote. A lock already there is the project's, and is
    # never recorded over. The engine refuses to record a project with no contract, which then
    # gets neither until a run finds one.
    defp schema_lock(igniter, earlier?) do
      if Igniter.exists?(igniter, @schema_lock) do
        add_schema_check(igniter)
      else
        case contracts?(igniter) do
          {igniter, false} ->
            Igniter.add_notice(igniter, """
            No module under lib/ uses EhOsContract.Contract, so the project keeps no
            eh_os_contract.lock, and `mix precommit` does not run
            `mix eh_os_contract.schema --check`. Once it has a contract, before any of its events
            changes, run `mix eh_os_contract.schema`, commit eh_os_contract.lock, and run the
            installer again: it adds the check.
            """)

          {igniter, true} when earlier? ->
            igniter
            |> add_schema_check()
            |> Igniter.add_notice("""
            eh_os_contract.lock records every event's fields, and `mix precommit` now runs
            `mix eh_os_contract.schema --check`, which fails until the project has one. Once the
            project compiles, run `mix eh_os_contract.schema` and commit eh_os_contract.lock,
            before any event changes.
            """)

          {igniter, true} ->
            igniter
            |> add_schema_check()
            |> Igniter.add_task("eh_os_contract.schema")
        end
      end
    end

    # Whether a module under `lib/` uses `EhOsContract.Contract`: the contracts the engine finds
    # in every environment, since `test/support` is compiled in the test one alone. `glob` narrows
    # where it looks, for a run that asks before it has read the project's other files.
    defp contracts?(igniter, glob \\ "lib/**/*.ex") do
      igniter = Igniter.include_glob(igniter, glob)
      pattern = glob |> GlobEx.compile!()

      found? =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.filter(&GlobEx.match?(pattern, Rewrite.Source.get(&1, :path)))
        |> Enum.any?(&defines_contract?/1)

      {igniter, found?}
    end

    defp defines_contract?(source) do
      source
      |> Rewrite.Source.get(:quoted)
      |> Sourceror.Zipper.zip()
      |> Sourceror.Zipper.traverse_while(false, fn zipper, false ->
        if contract?(zipper), do: {:halt, zipper, true}, else: {:cont, zipper, false}
      end)
      |> elem(1)
    end

    defp contract?(zipper) do
      with {:defmodule, _, [_, _]} <- zipper.node,
           {:ok, body} <- Igniter.Code.Common.move_to_do_block(zipper),
           {:ok, _use} <- Igniter.Code.Module.move_to_use(body, EhOsContract.Contract) do
        true
      else
        _ -> false
      end
    end

    defp add_schema_check(igniter) do
      Igniter.Project.TaskAliases.add_alias(igniter, :precommit, "eh_os_contract.schema --check",
        if_exists: :append
      )
    end

    # The agent harness. A seed is written once and then the developer's; a managed section,
    # between two markers, is rewritten by every run, so what EHOS requires reaches an
    # application through an upgrade.
    defp harness(igniter, app, web, example?) do
      {igniter, moved?} = move_phoenix_rules(igniter)
      phoenix_rules? = Igniter.exists?(igniter, "docs/phoenix.md")
      {igniter, design_system, _content} = design_system_state(igniter)
      # What the sections say of the access page follows the page, which a project keeps or
      # removes, and which only a project whose home page was Phoenix's was given.
      {access_page?, igniter} =
        Igniter.Project.Module.module_exists(igniter, Module.concat(web, AccessController))

      {entry_page?, igniter} = entry_page?(igniter, web, example?)

      assigns = [
        app: app,
        module: inspect(Igniter.Project.Module.module_name_prefix(igniter)),
        web: inspect(web),
        # A managed section is rendered on every run, and a seed again on an upgrade, and a later
        # run has no `--example`: what they say of the example follows its contract and its
        # test, which a project keeps or removes.
        example: example?(igniter, example?),
        example_api_test: example_api_test(igniter, web, example?),
        phoenix_rules: phoenix_rules?,
        contract_docs: @contract_docs,
        contract_dir: Path.dirname(@contract_docs),
        auth_readme: @auth_readme,
        ehos_app_readme: @ehos_app_readme,
        design_system: @design_system,
        design_system_declined: design_system == :declined,
        # `:absent` once the installer has run: `app.css` had no Tailwind import to put it after.
        design_system_imported: design_system == :installed,
        # A project that declined it may have removed the dependency too.
        design_system_dep: Igniter.Project.Deps.has_dep?(igniter, :ehos_design),
        # The README names a LICENSE only where there is one: the installer writes it in a new
        # project alone, and a project may have its own, under any terms.
        license: Igniter.exists?(igniter, "LICENSE"),
        web_port: @web_port,
        health_port: @health_port,
        ehos_name: ehos_name(app),
        seed: Igniter.Project.Module.module_name(igniter, "Seed"),
        access_page: access_page?,
        entry_page: entry_page?,
        # What the docs name of the test tools, where the project has them as the template
        # wrote them: an earlier project gets none of the three.
        clock: mocks_declare_clock?(igniter),
        credo: Igniter.Project.Deps.has_dep?(igniter, :credo),
        conventions: Igniter.exists?(igniter, "test/conventions_test.exs"),
        callback_docs: Igniter.exists?(igniter, "test/callback_docs_test.exs"),
        boundary: Igniter.Project.Deps.has_dep?(igniter, :boundary)
      ]

      igniter
      |> managed("AGENTS.md", "agents", "agents.md", assigns,
        generated?: &(moved? and phoenix?(&1)),
        seed_section_alone?: true
      )
      |> phoenix_rules_notice(app)
      |> where_to_read_notices()
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
      |> managed("docs/elixir.md", "elixir", "elixir.md", assigns)
      |> pull_request_template()
      |> write_template("review.yml", ".github/workflows/review.yml", [])
      |> copy_file("priv/templates/ehos_app.install/coderabbit.yaml", ".coderabbit.yaml")
      |> copy_file(
        "priv/templates/ehos_app.install/platform_issues.md",
        "docs/platform-issues.md"
      )
      # A module of its own name, so that Igniter's module location keeps it at the root of test/.
      |> write_template("harness_test.exs", "test/harness_test.exs", module: HarnessTest)
      |> retire_skills()
      |> claude_settings()
      |> ignore_plans()
    end

    # The pull request template as earlier versions wrote it, by SHA-256: 0.3.0 to 0.14.0, then
    # 0.15.0 to 0.21.0. It takes no assigns, so every project got the same bytes.
    @earlier_pull_request_templates [
      "76b40653afb893f7db4876c5f8c224e8d03852c83b3a6fb73e6a7074f7793f8b",
      "6018270c7658e8aca944491e981079c9f490d510449153144ddb0ddb4dc94531"
    ]

    # The template is the developer's once they change it. One still as an earlier version wrote
    # it is replaced, so that it has the `## Review` section the `review` workflow asks for; one
    # the developer changed that has none is left, with a notice.
    defp pull_request_template(igniter) do
      path = ".github/pull_request_template.md"
      template = render("pull_request_template.md", [])
      igniter = Igniter.include_existing_file(igniter, path)
      content = file_content(igniter, path)

      cond do
        not Igniter.exists?(igniter, path) ->
          Igniter.create_new_file(igniter, path, template)

        sha256(content) in @earlier_pull_request_templates ->
          Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, template))

        # Read as the workflow reads a description: a heading in a comment is not the section.
        not EhosApp.Review.review_section?(content) ->
          Igniter.add_notice(igniter, """
          #{path} is the project's own, and has no `## Review` section. The review workflow,
          .github/workflows/review.yml, fails a pull request whose description has none, so add
          one at its end, after every other section:

          ## Review

          <!-- What /ehos-app:pre-pr-review found, in each of its reviews, with the skills each
          invoked, and what became of each finding. Or that the change is documentation alone. -->
          """)

        true ->
          igniter
      end
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

    # The test that holds docs/elixir.md's `@doc` on every `@callback` (T-20), written once, in a
    # project made before too: it fails only where a callback says nothing, which a line of
    # `@doc` fixes, so the run says so instead of leaving it out.
    defp callback_docs(igniter, app, fresh?) do
      path = "test/callback_docs_test.exs"

      cond do
        Igniter.exists?(igniter, path) ->
          igniter

        not fresh? ->
          igniter
          |> write_template("callback_docs_test.exs", path, app: app)
          |> Igniter.add_notice("""
          test/callback_docs_test.exs now holds docs/elixir.md's rule that every @callback of the
          application's behaviours has a @doc: run mix test, and give each callback it lists one
          saying what it does, what it answers and how it fails.
          """)

        true ->
          write_template(igniter, "callback_docs_test.exs", path, app: app)
      end
    end

    # The test tools docs/elixir.md's rules assume (ehos-tools#504). Hammox and ExMachina, the
    # mocks and factories modules and the cases' calls to them change nothing an application
    # already does, so a project that has no `test/support/mocks.ex` yet gets them, once: one
    # with a mocks module of its own keeps its way, and what a developer removed later is not
    # brought back. Credo, the conventions test and the clock ask something of the code, so
    # they are a new project's (`fresh?` in `install/2`): any other gets a notice instead, since
    # its first `mix precommit` would fail on what its code already is.
    @hammox {:hammox, "~> 1.0", only: :test}
    @test_deps [@hammox, {:ex_machina, "~> 2.8", only: :test}]
    @lint_deps [{:credo, "~> 1.7", only: [:dev, :test], runtime: false}]

    defp elixir_tools(igniter, app, web, repo, fresh?) do
      module = Igniter.Project.Module.module_name_prefix(igniter)
      mocks = Module.concat(module, Mocks)
      factories = Module.concat(module, Factories)

      access? = igniter.assigns[:ehos_app_access?] == true

      if Igniter.exists?(igniter, "test/support/mocks.ex") do
        if access?,
          do: igniter |> add_deps([@hammox]) |> access_mock(module, mocks),
          else: igniter
      else
        # The clock is a new project's, and only where it has none of its own.
        clock? = fresh? and not Igniter.exists?(igniter, "lib/#{app}/clock.ex")

        igniter
        |> add_deps(@test_deps)
        |> write_template("mocks.ex", "test/support/mocks.ex",
          module: inspect(module),
          clock: clock?,
          access: access?
        )
        |> write_template("factories.ex", "test/support/factories.ex",
          module: inspect(module),
          repo: inspect(repo)
        )
        |> case_hooks(Module.concat(module, DataCase), mocks, factories)
        |> case_hooks(Module.concat(web, ConnCase), mocks, factories)
        |> then(&if(clock?, do: clock(&1, app, module), else: &1))
        |> then(&if(fresh?, do: lint(&1), else: lint_notice(&1)))
      end
    end

    # A project made before, whose mocks module the template wrote or the developer did, and
    # which this run gave the access page: its mock goes at the module's end, once. One whose
    # module cannot be found is told what to add.
    defp access_mock(igniter, module, mocks) do
      access_mock = Module.concat(module, AccessMock)

      line =
        "Hammox.defmock(#{inspect(access_mock)}, for: #{inspect(Module.concat(module, Access))})"

      igniter
      |> Igniter.Project.Module.find_and_update_module(
        mocks,
        &{:ok, Igniter.Code.Common.add_code(&1, line)}
      )
      |> case do
        {:ok, igniter} ->
          igniter

        {:error, igniter} ->
          Igniter.add_notice(igniter, """
          The access page reads #{inspect(Module.concat(module, Access))}, which config/test.exs
          names #{inspect(access_mock)} in tests, but test/support/mocks.ex defines no
          #{inspect(mocks)} to declare it in. Declare it where the project's mocks are:

              #{line}
          """)
      end
    end

    defp clock(igniter, app, module) do
      clock = Module.concat(module, Clock)

      igniter
      |> create_module(clock, "clock.ex",
        module: inspect(module),
        app: app,
        boundary:
          igniter.assigns[:ehos_app_boundary?] == true or
            igniter.assigns[:ehos_app_boundary_own?] == true
      )
      |> create_test(clock, "clock_test.exs", module: inspect(module))
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        app,
        [clock, :impl],
        Module.concat(module, ClockImpl)
      )
      |> Igniter.Project.Config.configure_new(
        "test.exs",
        app,
        [clock, :impl],
        Module.concat(module, ClockMock)
      )
    end

    defp lint(igniter) do
      igniter
      |> add_deps(@lint_deps)
      |> copy_file("priv/templates/ehos_app.install/credo.exs", ".credo.exs")
      # A module of its own name, as HarnessTest is, so that Igniter keeps it at test/'s root.
      |> write_template("conventions_test.exs", "test/conventions_test.exs", [])
      |> Igniter.assign(:ehos_app_credo?, true)
    end

    # The template brings these to a new project alone, so for any other this is how it is
    # adopted, when the team chooses: not a fork of something an upgrade would bring.
    defp lint_notice(igniter) do
      if Igniter.Project.Deps.has_dep?(igniter, :credo),
        do: igniter,
        else:
          Igniter.add_notice(igniter, """
          docs/elixir.md's rules are held by Credo and test/conventions_test.exs in a new project.
          Neither was added here: the installer adds them only where it finds Phoenix's welcome
          page untouched and no ehos.yaml, since other code may already break them. To adopt
          them, add {:credo, "~> 1.7", only: [:dev, :test], runtime: false}, append "credo" to the
          precommit alias, and fix what `mix credo` finds. ehosctl verify runs Credo, from 0.28.0,
          once mix.lock has it. The two files are in ehos_app's priv/templates/ehos_app.install/
          (credo.exs and conventions_test.exs.eex, as test/conventions_test.exs): list in the test
          the modules that already use Ecto.Query outside a table's owner.
          """)
    end

    # The case calls `setup_mocks/1` for every test and imports the factories, each once, read as
    # code. A case with a factory module of its own imported gets no second one; a case reshaped
    # so that either cannot be placed is left alone, with a notice.
    defp case_hooks(igniter, case_module, mocks, factories) do
      setup = "setup {#{inspect(mocks)}, :setup_mocks}"
      import = "import #{inspect(factories)}"
      has_setup? = &mentions?(&1, mocks, :setup_mocks)

      case quoted_module(igniter, case_module) do
        {igniter, nil} ->
          case_notice(igniter, case_module, [setup, import], :missing)

        {igniter, quoted} ->
          {igniter, unplaced} =
            {igniter, []}
            |> hook(
              case_module,
              has_setup?.(quoted),
              &setup_mocks_call(&1, setup),
              has_setup?,
              setup
            )
            |> hook(
              case_module,
              imports_factories?(quoted),
              &import_factories(&1, import),
              &imports_factories?/1,
              import
            )

          if unplaced == [],
            do: igniter,
            else: case_notice(igniter, case_module, Enum.reverse(unplaced), :reshaped)
      end
    end

    # Placed unless it is there already, then read back as code; what did not land is returned.
    defp hook(acc, _case_module, true = _present?, _edit, _there?, _line), do: acc

    defp hook({igniter, unplaced}, case_module, false, edit, there?, line) do
      igniter = Igniter.Project.Module.find_and_update_module!(igniter, case_module, edit)

      case quoted_module(igniter, case_module) do
        {igniter, quoted} when quoted != nil ->
          if there?.(quoted), do: {igniter, unplaced}, else: {igniter, [line | unplaced]}

        {igniter, nil} ->
          {igniter, [line | unplaced]}
      end
    end

    # The module as plain Elixir AST, in which a two-tuple and an atom are themselves.
    defp quoted_module(igniter, module) do
      case Igniter.Project.Module.find_module(igniter, module) do
        {:ok, {igniter, _source, zipper}} ->
          {igniter,
           zipper
           |> Sourceror.Zipper.node()
           |> Sourceror.to_string()
           |> Code.string_to_quoted!(emit_warnings: false)}

        {:error, igniter} ->
          {igniter, nil}
      end
    end

    defp setup_mocks_call(zipper, setup) do
      case Igniter.Code.Function.move_to_function_call_in_current_scope(
             zipper,
             :use,
             [1, 2],
             &Igniter.Code.Function.argument_equals?(&1, 0, ExUnit.CaseTemplate)
           ) do
        {:ok, use} -> {:ok, Igniter.Code.Common.add_code(use, setup, placement: :after)}
        _ -> {:ok, zipper}
      end
    end

    defp import_factories(zipper, import) do
      with {:ok, using} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :using, [1, 2]),
           {:ok, body} <- Igniter.Code.Common.move_to_do_block(using),
           {:ok, quote} <- Igniter.Code.Function.move_to_function_call(body, :quote, [1, 2]),
           {:ok, quoted} <- Igniter.Code.Common.move_to_do_block(quote) do
        {:ok, Igniter.Code.Common.add_code(quoted, import)}
      else
        _ -> {:ok, zipper}
      end
    end

    # `{Mocks, :setup_mocks}` as a setup, or `Mocks.setup_mocks(tags)` in one, by its full name.
    defp mentions?(quoted, module, fun) do
      parts = module |> Module.split() |> Enum.map(&String.to_atom/1)

      {_, found?} =
        Macro.prewalk(quoted, false, fn
          {{:__aliases__, _, ^parts}, ^fun} = node, _found? -> {node, true}
          {{:., _, [{:__aliases__, _, ^parts}, ^fun]}, _, _} = node, _found? -> {node, true}
          node, found? -> {node, found?}
        end)

      found?
    end

    # An import, in what `using` gives a test, of a module named as ExMachina's are, `Factory` or
    # `Factories`: one in the case's own body serves its helpers, not the tests.
    defp imports_factories?(quoted) do
      {_, using} =
        Macro.prewalk(quoted, nil, fn
          {:using, _, _} = node, nil -> {node, node}
          node, acc -> {node, acc}
        end)

      {_, found?} =
        Macro.prewalk(using, false, fn
          {:import, _, [{:__aliases__, _, parts} | _]} = node, found? ->
            {node, found? or to_string(List.last(parts)) in ["Factory", "Factories"]}

          node, found? ->
            {node, found?}
        end)

      found?
    end

    defp case_notice(igniter, case_module, lines, why) do
      subject =
        if why == :missing,
          do: "The project has no #{inspect(case_module)}",
          else: "#{inspect(case_module)} is not as Phoenix wrote it"

      Igniter.add_notice(igniter, """
      #{subject}, so the installer placed none of the lines below.
      For the mocks and factories TESTING.md describes, a test case carries each once:

      #{Enum.map_join(lines, "\n\n", &("    # " <> where(&1) <> "\n    " <> &1))}
      """)
    end

    defp where("setup " <> _), do: "after `use ExUnit.CaseTemplate`"
    defp where("import " <> _), do: "inside the quote of `using`"

    # Read from the project, not only from what this run wrote: a later run skips the tools, and
    # has not read the file otherwise.
    defp mocks_declare_clock?(igniter) do
      path = "test/support/mocks.ex"

      Igniter.exists?(igniter, path) and
        igniter |> Igniter.include_existing_file(path) |> file_content(path) =~ "ClockMock, for:"
    end

    # The docs a later version added to the seed's "Where to read", each with the notice that says
    # to add its row.
    @where_to_read [
      {"docs/elixir.md",
       """
       docs/elixir.md says how this application's Elixir and tests are written, and AGENTS.md's
       section asks for it before writing any. Add it to AGENTS.md's "Where to read", below
       the section:

           | Writing Elixir and its tests | [docs/elixir.md](docs/elixir.md) |
       """},
      {"docs/platform-issues.md",
       """
       docs/platform-issues.md lists what this application asked of the platform, and AGENTS.md's
       section has /ehos-app:retro keep it. Add it to AGENTS.md's "Where to read", below the
       section:

           | What this application asked of the platform, and what changes here once it is fixed | [docs/platform-issues.md](docs/platform-issues.md) |
       """}
    ]

    # AGENTS.md's part below the section is the application's once written, so a project from an
    # earlier version gets no row for a doc a later version added to its "Where to read": it is told
    # to add one. Only a row under the seed's heading counts: the section names each doc too, and
    # the application's own text may name one without listing it. A project that renamed the
    # heading is told on each run.
    defp where_to_read_notices(igniter) do
      own = igniter |> file_content("AGENTS.md") |> String.replace(section_pattern("agents"), "")
      rows = where_to_read(own)

      @where_to_read
      |> Enum.reject(fn {doc, _notice} -> own == "" or String.contains?(rows, doc) end)
      |> Enum.reduce(igniter, fn {_doc, notice}, igniter ->
        Igniter.add_notice(igniter, notice)
      end)
    end

    # The "Where to read" part of the application's AGENTS.md, up to its next heading, or nothing.
    defp where_to_read(own) do
      case Regex.run(~r/^## Where to read[ \t]*\r?\n.*?(?=^##? |\z)/ms, own) do
        [part] -> part
        nil -> ""
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

    # ARCHITECTURE.md and TESTING.md were the developer's once written before 0.9.0, which made
    # what the template knows a section of each. A file still as an earlier version wrote it is
    # replaced by the seed, as a new project gets it; any other earlier file gets the section on
    # top, and is told which of its parts the section now says.
    defp managed_on_top(igniter, path, name, assigns) do
      content =
        if Igniter.exists?(igniter, path),
          do: igniter |> Igniter.include_existing_file(path) |> file_content(path)

      earlier? = is_binary(content) and not String.contains?(content, "<!-- ehos_app:#{name} -->")

      # 0.9 put the section on top of such a file, so what is below it is compared too.
      untouched? =
        is_binary(content) and
          content
          |> String.replace(section_pattern(name), "", global: false)
          |> earlier_seed?(name, assigns)

      igniter =
        managed(igniter, path, name, String.downcase(path), assigns,
          generated?: fn _content -> untouched? end
        )

      if earlier? and not untouched?,
        do:
          Igniter.add_notice(igniter, """
          #{path} has a section of the template's on top now, between the markers
          <!-- ehos_app:#{name} --> and <!-- /ehos_app:#{name} -->, which an upgrade rewrites.
          The parts below it that an earlier version wrote say the same, or what is no longer so
          (a copy of the schema in .ehos/, skills in .agents/skills/), and can be deleted: keep
          only what is this application's own. AGENTS.md's part below its section may name those
          two as well.
          """),
        else: igniter
    end

    # The ARCHITECTURE.md and TESTING.md 0.3.0 to 0.8.1 wrote, each version of each template as
    # it was released, under `earlier/`. They were rendered with the project's names, so a file
    # is compared with each rendered for this project, with and without the example, since a
    # later run cannot tell whether the first had `--example`; line endings and trailing spaces
    # are not counted.
    @earlier_seeds %{
      "architecture" => ["0.3.0", "0.5.0", "0.7.0"],
      "testing" => ["0.3.0", "0.8.0"]
    }

    defp earlier_seed?(content, name, assigns) do
      content = content |> plain_lines() |> String.trim_leading()

      Enum.any?(Map.fetch!(@earlier_seeds, name), fn version ->
        Enum.any?([true, false], fn example ->
          "earlier/#{name}-#{version}.md"
          |> render(Keyword.put(assigns, :example, example))
          |> plain_lines() == content
        end)
      end)
    end

    defp section_pattern(name),
      do: Regex.compile!("<!-- ehos_app:#{name} -->.*?<!-- /ehos_app:#{name} -->\\n?", "s")

    # A file the installer keeps a section of, between `<!-- ehos_app:<name> -->` markers. With
    # no file, the seed, which holds the section. A section from an earlier version is replaced
    # in place. With `seed_section_alone?`, a file that holds the section and nothing else gets
    # the seed, as a new project does: the root `AGENTS.md` ehos_app 0.2 wrote was the section
    # alone once Phoenix's rules moved out, and the part below it never arrived. Only there: in
    # another file, a section alone is what the developer left. A start marker without its end
    # means the developer has edited the section, so it is left alone rather than added a
    # second time. A file `generated?` recognises as one a generator wrote and nobody changed
    # since, Phoenix or an earlier version of this installer, is replaced by the seed, whatever
    # sections it holds; any other file gets the section on top.
    defp managed(igniter, path, name, template, assigns, opts \\ []) do
      generated? = Keyword.get(opts, :generated?, fn _ -> false end)
      seed_section_alone? = Keyword.get(opts, :seed_section_alone?, false)
      section = render("#{name}_section.md", assigns)
      seed = render(template, Keyword.put(assigns, :section, section))
      start = "<!-- ehos_app:#{name} -->"
      pattern = section_pattern(name)

      parts = %{
        seed: seed,
        section: section,
        start: start,
        pattern: pattern,
        generated?: generated?,
        seed_section_alone?: seed_section_alone?
      }

      Igniter.create_or_update_file(igniter, path, seed, fn source ->
        Rewrite.Source.update(source, :content, &managed_content(&1, parts))
      end)
    end

    defp managed_content(content, %{seed: seed, section: section, pattern: pattern} = parts) do
      cond do
        parts.generated?.(content) ->
          seed

        parts.seed_section_alone? and content =~ pattern and
            String.trim(String.replace(content, pattern, "")) == "" ->
          seed

        content =~ pattern ->
          String.replace(content, pattern, fn _ -> section end, global: false)

        String.contains?(content, parts.start) ->
          content

        true ->
          section <> "\n" <> content
      end
    end

    @doc """
    The template's own Claude Code plugin, `ehos-app`, as `plugins/0` describes it: the one whose
    skills are the template's, from the marketplace of its own name (ehos-tools T-15, T-16).
    """
    @spec plugin() :: map()
    def plugin, do: Enum.find(@plugins, &(&1.name == @plugin))

    @doc """
    Every Claude Code plugin the project's `.claude/settings.json` enables, as a map: its
    `:name`, its `:marketplace`, the GitHub `:repo` that publishes it, the `:version` pinned and
    its `:ref`, the tag of that version. `ehos-app`'s also has the `:path` of its marketplace's
    file and the marketplace's former name, `:formerly`, which an upgrade renames;
    `eh-os-contract`'s has the `:commit` its tag names, which a test with the network checks.
    """
    @spec plugins() :: [map()]
    def plugins, do: @plugins

    # Enables the plugins in the project's Claude Code settings, each from its marketplace at the
    # plugin's tag, and sets up the review gate's hook. Settings of the developer's own are kept,
    # key by key and in their order: only the marketplaces' entries, the plugins' and the hook are
    # added. A marketplace an earlier version pinned to an older tag of its plugin moves to this
    # one; one pinned to anything else, and a plugin the developer turned off, are theirs. A
    # plugin's marketplace under the name an earlier version gave it, at a tag that version
    # pinned, takes the new name in its place, and the plugin's entry with it.
    defp claude_settings(igniter) do
      path = ".claude/settings.json"

      if Igniter.exists?(igniter, path) do
        igniter = Igniter.include_existing_file(igniter, path)
        content = file_content(igniter, path)

        with {:ok, %Jason.OrderedObject{} = original} <-
               Jason.decode(content, objects: :ordered_objects),
             {settings, kept} when is_map(settings) <- with_template(original) do
          kept
          |> Enum.reduce(igniter, &Igniter.add_notice(&2, &1))
          |> settings_written(path, original, settings, content)
        else
          _ ->
            Igniter.add_warning(igniter, """
            #{path} is not JSON the installer can read: an object, whose
            extraKnownMarketplaces, each marketplace there, its source, and enabledPlugins are
            objects too, and whose hooks are an object whose PreToolUse is a list of objects. The
            installer left it alone, so the plugins #{Enum.map_join(@plugins, " and ", & &1.name)}
            are not enabled and the review gate is not set up. Add to it:

            #{object([]) |> with_template() |> elem(0) |> encode_settings()}
            """)
        end
      else
        {settings, []} = with_template(object([]))
        Igniter.create_new_file(igniter, path, encode_settings(settings))
      end
    end

    defp settings_written(igniter, _path, settings, settings, _content), do: igniter

    defp settings_written(igniter, path, _original, settings, content) do
      Igniter.update_file(
        igniter,
        path,
        &Rewrite.Source.update(&1, :content, encode_settings(settings, content))
      )
    end

    # The settings with the plugins and the review gate's hook.
    defp with_template(settings) do
      with {settings, kept} when is_map(settings) <- with_plugins(settings),
           %Jason.OrderedObject{} = settings <- with_review_gate(settings) do
        {settings, kept}
      end
    end

    # The review gate (`mix ehos_app.review gate`, T-17), as a PreToolUse hook on Bash.
    # Most commands do not name gh's pull request commands, so the shell lets them through
    # before Mix starts; the gate reads the rest. `ehos_app` is a dependency in `:dev` alone,
    # hence `MIX_ENV=dev`. Exit status 2 is the gate's refusal; any other but 0 means it could not
    # run (the dependencies not fetched yet, say), and refuses too, since a gate that fails open
    # stops nothing. The one way it fails open is Claude Code's timeout, past which the command
    # runs: the first gate in a checkout compiles every development dependency before the task
    # exists, which can take minutes, hence ten of them. A release that changes this hook will
    # have to tell an earlier version's, which `runs_review_gate?/1` now keeps as the developer's,
    # from one the developer wrote, by its command, as `@earlier_ci_workflows` does a workflow.
    @review_gate "mix ehos_app.review gate"
    @review_gate_hook %Jason.OrderedObject{
      values: [
        {"type", "command"},
        {"command",
         "input=$(cat) || { echo 'The review gate could not read the hook input, so the command is refused.' >&2; exit 2; }; " <>
           ~s(case "$input" in *gh*pr*create*|*gh*pr*new*\) ;; *\) exit 0 ;; esac; ) <>
           ~s(cd "$CLAUDE_PROJECT_DIR" && printf '%s' "$input" | MIX_ENV=dev #{@review_gate}; rc=$?; ) <>
           ~s(if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then exit "$rc"; fi; ) <>
           "echo 'The review gate (MIX_ENV=dev #{@review_gate}) failed to run, so the pull request is refused. Fix the error above and try again.' >&2; exit 2"},
        {"timeout", 600},
        {"statusMessage", "Checking that this change was reviewed"}
      ]
    }

    @doc """
    The Claude Code `PreToolUse` hook the installer adds to the project's `.claude/settings.json`,
    in the order its keys are written: for a Bash command that names `gh`, `pr` and `create` or
    `new`, it runs `MIX_ENV=dev mix ehos_app.review gate` in the project, which refuses a pull
    request from a commit not marked as reviewed (`EhosApp.Review.gate/2`). It refuses the
    command too when the gate cannot read the hook's input or fails to run, with one exception:
    past the hook's `timeout`, 600 seconds, Claude Code runs the command without its answer.
    """
    @spec review_gate_hook() :: Jason.OrderedObject.t()
    def review_gate_hook, do: @review_gate_hook

    # Adds the hook, unless a PreToolUse hook already runs the gate: the template's, or one the
    # developer wrote around it, which is theirs. `{:error, :shape}` when `hooks` is not an object,
    # or its PreToolUse not a list of objects.
    defp with_review_gate(settings) do
      hooks = with nil <- settings["hooks"], do: object([])
      pre_tool_use = object?(hooks) && with(nil <- hooks["PreToolUse"], do: [])

      cond do
        not is_list(pre_tool_use) or not Enum.all?(pre_tool_use, &object?/1) ->
          {:error, :shape}

        Enum.any?(pre_tool_use, &runs_review_gate?/1) ->
          settings

        true ->
          entry = object(matcher: "Bash", hooks: [@review_gate_hook])
          put(settings, "hooks", put(hooks, "PreToolUse", pre_tool_use ++ [entry]))
      end
    end

    defp runs_review_gate?(entry) do
      is_list(entry["hooks"]) and
        Enum.any?(entry["hooks"], fn hook ->
          object?(hook) and is_binary(hook["command"]) and
            String.contains?(hook["command"], @review_gate)
        end)
    end

    # The settings with every marketplace and plugin, and a notice for each marketplace of the
    # developer's that was kept; `{:error, :shape}` when a part the installer reads is not an
    # object.
    defp with_plugins(settings) do
      Enum.reduce_while(@plugins, {settings, []}, fn plugin, {settings, kept} ->
        case with_plugin(settings, plugin) do
          {:error, :shape} -> {:halt, {:error, :shape}}
          {settings, notices} -> {:cont, {settings, kept ++ notices}}
        end
      end)
    end

    defp with_plugin(settings, plugin) do
      {settings, moved} = former(settings, plugin)
      marketplaces = with nil <- settings["extraKnownMarketplaces"], do: object([])
      plugins = with nil <- settings["enabledPlugins"], do: object([])
      existing = object?(marketplaces) && marketplaces[plugin.marketplace]

      cond do
        not object?(marketplaces) or not object?(plugins) ->
          {:error, :shape}

        existing != nil and not readable_marketplace?(existing) ->
          {:error, :shape}

        true ->
          {marketplace, kept} = marketplace(existing, plugin)
          key = "#{plugin.name}@#{plugin.marketplace}"
          # A plugin the developer turned off under its former marketplace stays off.
          off? = plugin[:formerly] && plugins["#{plugin.name}@#{plugin.formerly}"] == false
          plugins = if plugins[key] == nil, do: put(plugins, key, !off?), else: plugins

          settings =
            settings
            |> put("extraKnownMarketplaces", put(marketplaces, plugin.marketplace, marketplace))
            |> put("enabledPlugins", plugins)

          {settings, Enum.reject([moved, kept], &is_nil/1)}
      end
    end

    # The plugin's marketplace under the name an earlier version gave it, `formerly:`. One on the
    # plugin's repository at a tag no later than this one's is the template's: it takes the new
    # name in its place, or goes where the template's marketplace already has that name, and the
    # plugin's entry moves with it. Where another plugin is enabled from it, it stays for that one
    # and the plugin's entry alone moves; where a marketplace of the developer's has the new name,
    # both are theirs. Any other under the former name is the developer's, and stays.
    # Returns the settings and a notice, or nil.
    defp former(settings, %{formerly: former} = plugin) do
      marketplaces = settings["extraKnownMarketplaces"]
      plugins = with nil <- settings["enabledPlugins"], do: object([])
      existing = object?(marketplaces) && marketplaces[former]
      target = object?(marketplaces) && marketplaces[plugin.marketplace]
      from = "#{plugin.name}@#{former}"
      to = "#{plugin.name}@#{plugin.marketplace}"

      cond do
        not object?(plugins) or not readable_marketplace?(existing) ->
          {settings, nil}

        not template_marketplace?(existing, plugin) ->
          developers_former(settings, plugins, existing, from, to)

        true ->
          templates_former(settings, plugins, target, plugin)
      end
    end

    defp former(settings, _plugin), do: {settings, nil}

    # The template's marketplace under the former name, and the plugin's entry from it.
    defp templates_former(settings, plugins, target, %{formerly: former} = plugin) do
      marketplaces = settings["extraKnownMarketplaces"]
      from = "#{plugin.name}@#{former}"
      to = "#{plugin.name}@#{plugin.marketplace}"

      cond do
        # A marketplace of the developer's under the new name: theirs to reconcile.
        target != nil and
            not (readable_marketplace?(target) and template_marketplace?(target, plugin)) ->
          {settings, nil}

        enabled_from?(plugins, former, from) ->
          {put(settings, "enabledPlugins", move(plugins, from, to)), nil}

        target == nil ->
          {settings
           |> put("extraKnownMarketplaces", rename(marketplaces, former, plugin.marketplace))
           |> put("enabledPlugins", move(plugins, from, to)), nil}

        true ->
          {settings
           |> put("extraKnownMarketplaces", delete(marketplaces, former))
           |> put("enabledPlugins", move(plugins, from, to)), nil}
      end
    end

    # Whether a plugin other than this one is enabled from the marketplace.
    defp enabled_from?(plugins, marketplace, except) do
      Enum.any?(plugins.values, fn {key, value} ->
        key != except and value == true and String.ends_with?(key, "@" <> marketplace)
      end)
    end

    # A plugin enabled from the developer's own marketplace under the former name is not enabled a
    # second time from the template's.
    defp developers_former(settings, plugins, existing, from, to) do
      if plugins[from] == true and plugins[to] == nil do
        source = existing["source"]

        {put(settings, "enabledPlugins", put(plugins, to, false)),
         """
         .claude/settings.json enables #{from}, from
         #{source["repo"] || source["url"] || "another source"} at #{source["ref"] || "no ref"},
         which is not the template's, so the installer kept it and turned #{to} off. To take the
         template's plugin, turn #{to} on and remove #{from}.
         """}
      else
        {settings, nil}
      end
    end

    defp template_marketplace?(existing, plugin) do
      ref = existing["source"]["ref"]
      ours?(existing, plugin) and (ref == plugin.ref or earlier_plugin?(ref, plugin))
    end

    # An object whose source is an object, and whose strings the installer reads are strings.
    defp readable_marketplace?(existing) do
      source = object?(existing) && existing["source"]

      object?(source) and
        Enum.all?(
          ["source", "repo", "url", "ref", "path"],
          &(source[&1] == nil or is_binary(source[&1]))
        )
    end

    defp ours?(existing, plugin) do
      source = existing["source"]

      source["source"] == "github" and
        String.downcase(source["repo"] || "") == String.downcase(plugin.repo)
    end

    defp marketplace(nil, plugin),
      do:
        {object(
           source:
             object(
               [source: "github", repo: plugin.repo, ref: plugin.ref] ++
                 if(plugin[:path], do: [path: plugin.path], else: [])
             )
         ), nil}

    # A marketplace on the plugin's repository at an earlier release of it is the template's,
    # and moves to this one. Any other, a later release or a fork included, is the developer's.
    defp marketplace(existing, plugin) do
      source = existing["source"]
      ref = source["ref"]

      # A `path` is set only where there was none: the marketplace 0.9 named `ehos-tools`. A
      # version that moves `path:` counts the one before as the template's, as it does tags.
      if template_marketplace?(existing, plugin) do
        source = put(source, "ref", plugin.ref)

        source =
          if plugin[:path] && source["path"] == nil,
            do: put(source, "path", plugin.path),
            else: source

        {put(existing, "source", source), nil}
      else
        {existing,
         """
         .claude/settings.json names the marketplace #{plugin.marketplace} as
         #{source["repo"] || source["url"] || "another source"} at #{ref || "no ref"}, which is
         not an earlier release of the #{plugin.name} plugin from #{plugin.repo}, so the
         installer kept it: #{plugin.name}@#{plugin.marketplace}, where it is enabled, comes
         from there. This version of ehos_app pins #{plugin.ref}.
         """}
      end
    end

    defp earlier_plugin?(ref, %{tag: tag, version: pinned}) when is_binary(ref) do
      with true <- String.starts_with?(ref, tag),
           {:ok, version} <- ref |> String.replace_prefix(tag, "") |> Version.parse() do
        Version.compare(version, Version.parse!(pinned)) == :lt
      else
        _ -> false
      end
    end

    defp earlier_plugin?(_ref, _plugin), do: false

    defp object?(value), do: match?(%Jason.OrderedObject{}, value)

    # Sets a key of an ordered object, in its place if it has one and else at the end.
    defp put(%Jason.OrderedObject{values: values} = object, key, value) do
      if List.keymember?(values, key, 0),
        do: %{object | values: List.keystore(values, key, 0, {key, value})},
        else: %{object | values: values ++ [{key, value}]}
    end

    # Moves a plugin's entry to its new key, in its place; where the new key is already there, the
    # old one goes, and the plugin stays on if it was on under either.
    defp move(%Jason.OrderedObject{values: values} = object, from, to) do
      cond do
        not List.keymember?(values, to, 0) -> rename(object, from, to)
        object[from] == true -> object |> put(to, true) |> delete(from)
        true -> delete(object, from)
      end
    end

    defp delete(%Jason.OrderedObject{values: values} = object, key),
      do: %{object | values: List.keydelete(values, key, 0)}

    # Renames a key of an ordered object in its place, while the new one is not taken.
    defp rename(%Jason.OrderedObject{values: values} = object, from, to) do
      if List.keymember?(values, to, 0),
        do: object,
        else: %{
          object
          | values:
              Enum.map(values, fn {key, value} -> {if(key == from, do: to, else: key), value} end)
        }
    end

    defp object(pairs),
      do: %Jason.OrderedObject{
        values: Enum.map(pairs, fn {key, value} -> {to_string(key), value} end)
      }

    defp encode_settings(settings), do: Jason.encode!(settings, pretty: true) <> "\n"

    # Settings of the developer's, written the way their file was: its indent, its line ends, and
    # whether it ends with one. No library edits JSON in place in Elixir, so a file is encoded
    # again; what else of its layout differs from Jason's printer (an array kept on one line,
    # say) is lost, once, when the installer has something to add.
    defp encode_settings(settings, previous) do
      newline = if previous =~ "\r\n", do: "\r\n", else: "\n"

      indent =
        case Regex.run(~r/\A[^\n]*\r?\n([ \t]+)\S/, previous) do
          [_, indent] -> indent
          nil -> "  "
        end

      encoded = Jason.encode!(settings, pretty: [indent: indent, line_separator: newline])

      if previous =~ ~r/\r?\n\z/, do: encoded <> newline, else: encoded
    end

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

    # Whether the example's contract and its implementation, which `AGENTS.md` names, are there,
    # or this run writes them.
    defp example?(igniter, example?) do
      example? == true or
        Enum.all?(["Contracts.Entries", "Entries.Entry"], fn name ->
          module = Igniter.Project.Module.module_name(igniter, name)
          Igniter.exists?(igniter, Igniter.Project.Module.proper_location(igniter, module))
        end)
    end

    # Whether the project has the example's page that issues a command, wherever it is, or this
    # run writes it, as `entry_page/5` decides. A router is asked for only on a run that may
    # write it.
    defp entry_page?(igniter, web, example?) do
      case entry_live(igniter, web) do
        {:example, igniter} ->
          {true, igniter}

        {_own_or_none, igniter} when example? != true ->
          {false, igniter}

        {_own_or_none, igniter} ->
          igniter |> Igniter.Libs.Phoenix.select_router() |> entry_page_written?(web)
      end
    end

    defp entry_page_written?({igniter, nil}, _web), do: {false, igniter}

    defp entry_page_written?({igniter, router}, web) do
      {state, igniter} = entry_page_state(igniter, router, web)
      {state == :write, igniter}
    end

    # Where the example's API test is, while there is one or this run writes it; else nil.
    defp example_api_test(igniter, web, example?) do
      path =
        Igniter.Project.Module.proper_location(igniter, Module.concat(web, EntriesApiTest), :test)

      if example? == true or Igniter.exists?(igniter, path), do: path
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
        Rewrite.Source.update(source, :content, &with_plans_ignored/1)
      end)
    end

    defp with_plans_ignored(content) do
      if content =~ ~r{^/?\.plans/?$}m,
        do: content,
        else:
          String.trim_trailing(content) <>
            "\n\n# Working plans, which are history, not current truth.\n/.plans/\n"
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

          Igniter.Project.Module.find_and_update_module!(
            igniter,
            app,
            &with_endpoint_last(&1, endpoint)
          )
      end
    end

    defp with_endpoint_last(zipper, endpoint) do
      with {:ok, zipper} <- children(zipper),
           list = Igniter.Code.Common.maybe_move_to_single_child_block(zipper),
           [_ | _] = items <- Sourceror.Zipper.node(list),
           index when is_integer(index) <- Enum.find_index(items, &endpoint?(&1, endpoint)),
           true <- index < length(items) - 1,
           {:ok, list} <- Igniter.Code.List.remove_index(list, index) do
        # The node itself, so the comments above it and its spelling go with it.
        Igniter.Code.List.append_to_list(list, Enum.at(items, index))
      else
        _ -> {:ok, zipper}
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

      From 0.3.0, eh-os-contract's 0.4.0 to 0.7.0 change what a project must do (their release
      notes say how): the engine's tables move to version 4, through the migration this run adds,
      and the release before them must be stopped before they move, since it does not refuse the
      newer tables; every contract's version moves once, and read models are marked stale; a
      contract's own `process`, stage groups and `terminal:` no longer compile, and a run is a
      module of its own, `use EhOsContract.Process`; a duration longer than 100 years no longer
      compiles; and eh_os_contract.lock holds every event's fields, recorded before any event
      changes.
      """)
      |> contracts_before_processes()
    end

    # A contract that still declares its own `process` or an event `terminal:`, which
    # eh-os-contract 0.4.0 and later refuse to compile: the developer's to change, so it is said
    # rather than edited.
    defp contracts_before_processes(igniter) do
      igniter = Igniter.include_glob(igniter, "lib/*/contracts/**/*.ex")

      old =
        for source <- igniter.rewrite,
            path = Rewrite.Source.get(source, :path),
            path =~ ~r{^lib/[^/]+/contracts/},
            content = Rewrite.Source.get(source, :content),
            content =~ ~r/^\s*process\s+:\w+/m or content =~ ~r/\bterminal:\s*true\b/,
            do: path

      if old == [],
        do: igniter,
        else:
          Igniter.add_warning(igniter, """
          #{Enum.join(Enum.sort(old), ", ")} declares a `process` of its own or an event
          `terminal:`, which eh-os-contract #{@eh_os_contract_release} refuses to compile. Remove
          them, and write the run as a module of its own, `use EhOsContract.Process`, as
          deps/eh_os_contract/packages/eh_os_contract/docs/process.md says.
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

    # Whether the project migrated the engine's tables before this run, and none of its
    # migrations goes to `@engine_version` yet: read as `verifier_behind?/2` reads the verifier's.
    defp engine_behind?(igniter, repo) do
      sources = migration_sources(igniter, repo)

      Enum.any?(sources, fn {path, _} -> String.ends_with?(path, "_add_eh_os_contract.exs") end) and
        not Enum.any?(sources, fn {_path, content} ->
          migrates_to?(content, [:EhOsContract, :Migrations], @engine_version)
        end)
    end

    defp migration_sources(igniter, repo) do
      dir = "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}/migrations/"
      igniter = Igniter.include_glob(igniter, dir <> "*.exs")

      for source <- igniter.rewrite,
          path = Rewrite.Source.get(source, :path),
          String.starts_with?(path, dir),
          do: {path, Rewrite.Source.get(source, :content)}
    end

    # Whether the project migrated the verifier's tables before this run, in the chosen repo's
    # migrations, and none of its migrations goes to this version's yet. A comment naming the
    # call is not a migration that makes it.
    defp verifier_behind?(igniter, repo) do
      sources = migration_sources(igniter, repo)

      Enum.any?(sources, fn {path, _} ->
        String.ends_with?(path, "_add_eh_os_contract_auth.exs")
      end) and
        not Enum.any?(sources, fn {_path, content} ->
          migrates_to?(content, [:EhOsContract, :Auth, :Migrations], @verifier_version)
        end)
    end

    # Whether a migration calls `module.up/1` with `version`, read as code: however it is laid
    # out, and never from a comment. A call through an alias or a pipe is not recognised, which
    # adds an upgrade migration that does nothing, since `up/1` leaves a database already at the
    # version alone. One that does not parse calls nothing.
    defp migrates_to?(content, module, version) do
      case Code.string_to_quoted(content, emit_warnings: false) do
        {:ok, quoted} ->
          quoted
          |> Macro.prewalk(false, fn
            {{:., _, [{:__aliases__, _, ^module}, :up]}, _, [opts]} = node, found ->
              {node, found or (Keyword.keyword?(opts) and opts[:version] == version)}

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
    # is not moved. A copy that was changed stays, and so does the comment. A comment that names a
    # copy already gone is pointed past it too, and once no copy is left the header that described
    # one is this version's: 0.9 removed the copies, and left the comment of a file with CRLF line
    # ends, and every file's header, as they were.
    defp retire_schema_copies(igniter) do
      @ehos_yaml_schema_copies
      |> Enum.reduce(igniter, &retire_schema_copy/2)
      |> current_header()
    end

    defp retire_schema_copy({copy, hash}, igniter) do
      cond do
        Igniter.exists?(igniter, copy) ->
          igniter = Igniter.include_existing_file(igniter, copy)

          if sha256(file_content(igniter, copy)) == hash,
            do: igniter |> Igniter.rm(copy) |> point_at_dependency(copy),
            else: igniter

        String.contains?(file_content(igniter, "ehos.yaml"), copy) ->
          point_at_dependency(igniter, copy)

        true ->
          igniter
      end
    end

    defp current_header(igniter) do
      if Igniter.exists?(igniter, "ehos.yaml") and
           not Enum.any?(Map.keys(@ehos_yaml_schema_copies), &Igniter.exists?(igniter, &1)) do
        Igniter.update_file(igniter, "ehos.yaml", fn source ->
          Rewrite.Source.update(source, :content, &with_current_header/1)
        end)
      else
        igniter
      end
    end

    # The schema of the version of `ehos.yaml` this installer writes.
    defp current_schema,
      do: EhosApp.ehos_yaml_version() |> String.split("/") |> List.last() |> ehos_yaml_schema()

    # The comment 0.2.0 to 0.8.1 wrote on top of `ehos.yaml`, which names the copy in `.ehos/`.
    # Once the copy is gone it becomes the one this version writes, while it is still word for
    # word that comment.
    @ehos_yaml_header_08 """
    # What this application needs from EHOS in order to run, and nothing about how EHOS provides
    # it. EHOS defines this format: the schema beside it, in .ehos/, is a copy of the one it
    # publishes, and https://github.com/empoweredhouse/eh-os/blob/main/docs/ehos-yaml.md explains
    # every field. The application's name is its contract domain's, so it is not written here.
    """

    defp point_at_dependency(igniter, copy) do
      "ehos.yaml." <> file = Path.basename(copy)
      schema = file |> Path.rootname() |> ehos_yaml_schema()

      if Igniter.exists?(igniter, "ehos.yaml") do
        igniter =
          Igniter.update_file(igniter, "ehos.yaml", fn source ->
            Rewrite.Source.update(source, :content, &point_at(&1, copy, schema))
          end)

        if String.contains?(file_content(igniter, "ehos.yaml"), copy),
          do:
            Igniter.add_warning(igniter, """
            ehos.yaml names #{copy}, a copy of EHOS's schema an earlier version wrote, which is
            gone. An editor finds the same schema at #{schema}: point the comment
            `# yaml-language-server: $schema=` there.
            """),
          else: igniter
      else
        igniter
      end
    end

    defp point_at(content, copy, schema) do
      comment = ~r/^(# yaml-language-server: \$schema=)#{Regex.escape(copy)}(\r?)$/m
      Regex.replace(comment, content, "\\1#{schema}\\2")
    end

    defp with_current_header(content) do
      newline = if content =~ "\r\n", do: "\r\n", else: "\n"
      old_header = String.replace(@ehos_yaml_header_08, "\n", newline)

      new_header =
        "ehos.yaml"
        |> render(
          web_port: @web_port,
          health_port: @health_port,
          version: "",
          schema: "",
          app: "",
          seed: ""
        )
        |> String.split("# yaml-language-server:", parts: 2)
        |> hd()
        |> String.replace("\n", newline)

      String.replace(content, old_header, new_header, global: false)
    end

    defp older_ehos_yaml(igniter) do
      igniter = Igniter.include_existing_file(igniter, "ehos.yaml")

      with {:ok, source} <- Rewrite.source(igniter.rewrite, "ehos.yaml"),
           content = Rewrite.Source.get(source, :content),
           false <- content =~ ~r/^sign_in:/m do
        Igniter.add_warning(igniter, """
        ehos.yaml declares no `sign_in`, so EHOS gives the application nothing to sign people in
        with: it starts, and signs nobody in to its pages. To sign people in, make it
        `schema: #{EhosApp.ehos_yaml_version()}`, point its schema comment at
        #{current_schema()},
        and add `sign_in: {}` beside `serves:`.
        """)
      else
        _ -> igniter
      end
    end

    # An `ehos.yaml/v3` to `v6` moves to the version this installer writes, v7, which may say the
    # CPU and memory the workload asks for (eh-os D-143): its `schema:` and the schema comment's
    # version. Each later version only added keys, so the file means what it meant. A v3 also
    # gets v4's seed beside `migrate:` when the file names none (eh-os D-98), written there only
    # after a `migrate:` whose value is one flow sequence on its line, the form every version
    # wrote. Every other key and comment stays as the developer left it, and a file whose
    # `migrate:` has another form is told how to add the seed. An older version is
    # `older_ehos_yaml/1`'s to warn of. A file is moved back to v7 at every run, as the template
    # writes it (eh-os D-143). With `eh_os_contract_auth` on a source of the project's own, which
    # may carry no v7 schema, so that its manifest task could not read the file, a v3 moves to v4
    # with its seed, as before v7, and a v4 to v6 stays; the developer is told.
    defp ehos_yaml_current(igniter, app, seed, repo, move?) do
      igniter = Igniter.include_existing_file(igniter, "ehos.yaml")
      line = ~s|seed: [/app/bin/#{app}, eval, "#{inspect(seed)}.run()"]|
      migrate = ~r/^([ \t]+)(migrate:[ \t]*\[[^\]\r\n]*\][ \t]*(?:#[^\r\n]*)?)(\r?\n|\z)/m

      with {:ok, source} <- Rewrite.source(igniter.rewrite, "ehos.yaml"),
           content = Rewrite.Source.get(source, :content),
           [_line, from] <-
             Regex.run(~r/^schema: ehos\.yaml\/(v[3-6])(?=[ \t]*(?:#[^\r\n]*)?\r?$)/m, content),
           true <- move? or from == "v3" or kept_ehos_yaml(igniter, from) do
        {current, deploy} =
          if move?, do: {EhosApp.ehos_yaml_version(), "0.21"}, else: {"ehos.yaml/v4", "0.9"}

        "ehos.yaml/" <> current_file = current
        seeded? = from != "v3" or content =~ ~r/^[ \t]+seed:/m

        move = %{
          from: from,
          current: current,
          current_file: current_file,
          adds?: not seeded? and content =~ migrate,
          migrate: migrate,
          line: line,
          content: content,
          now: "ehos.yaml is #{current} now, which EHOS #{deploy} and later deploy",
          seed: seed,
          app: app,
          repo: repo
        }

        igniter
        |> Igniter.update_file(
          "ehos.yaml",
          &Rewrite.Source.update(&1, :content, moved_ehos_yaml(move))
        )
        |> ehos_yaml_notice(move)
      else
        {:kept, igniter} -> igniter
        _ -> igniter
      end
    end

    defp moved_ehos_yaml(%{content: content, from: from} = move) do
      content
      # The `schema:` line and the editor's schema comment alone, each the first of its
      # kind: a `$schema=` the developer wrote anywhere else is theirs. The comment's path is
      # matched lazily within its line, so a long line costs no more than its length.
      |> String.replace(
        ~r/^schema: ehos\.yaml\/#{from}(?=[ \t]*(?:#[^\r\n]*)?\r?$)/m,
        "schema: " <> move.current,
        global: false
      )
      |> String.replace(
        ~r/^(#[ \t]*yaml-language-server:[ \t]*\$schema=\S*?ehos\.yaml\/)#{from}\.json(?=[ \t]*\r?$)/m,
        "\\1#{move.current_file}.json",
        global: false
      )
      |> with_seed(move)
    end

    defp with_seed(content, %{adds?: false}), do: content

    defp with_seed(content, move) do
      Regex.replace(move.migrate, content, &seed_after(&1, &2, &3, &4, move.line), global: false)
    end

    defp seed_after(_all, indent, key, newline, line) do
      ends = if newline == "", do: "\n", else: newline
      indent <> key <> ends <> indent <> line <> newline
    end

    defp ehos_yaml_notice(igniter, move) do
      cond do
        move.from != "v3" ->
          Igniter.add_notice(igniter, """
          #{move.now}; nothing else
          in it changed. It may now say the CPU and memory the workload asks for under
          `needs.compute`.
          """)

        move.adds? ->
          igniter
          |> seed(move.seed, move.app, move.repo, false, false)
          |> Igniter.add_notice("""
          #{move.now}, and names
          `needs.database.seed`: #{inspect(move.seed)}.run/0, which runs priv/repo/seeds.exs in an
          ephemeral environment of EHOS only. /ehos-app:sample-data gives a seed the steps
          that record business facts through the contracts, and its test.
          """)

        move.content =~ ~r/^[ \t]+seed:/m ->
          Igniter.add_notice(igniter, """
          #{move.now}; its `seed:` is kept as it is.
          """)

        true ->
          Igniter.add_warning(igniter, """
          #{move.now}, but
          names no seed, since its `migrate:` is not one sequence on one line. To seed its
          previews, add under `needs.database`: #{move.line}, and that module, as ehos_app's
          priv/templates/ehos_app.install/seed.ex.eex writes it; a later run writes neither.
          """)
      end
    end

    defp kept_ehos_yaml(igniter, from) do
      {:kept,
       Igniter.add_warning(igniter, """
       ehos.yaml stays ehos.yaml/#{from}: eh_os_contract_auth is on a source or a commit of
       eh-os-contract this ehos_app does not know, which may carry no schema of
       #{EhosApp.ehos_yaml_version()}. Once it does, from eh-os-contract's release
       #{@eh_os_contract_release}, make it `schema: #{EhosApp.ehos_yaml_version()}` and point its
       schema comment at #{current_schema()} to say the CPU and memory the workload asks for
       under `needs.compute`, which only EHOS 0.21 and later deploy.
       """)}
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
        |> sign_in_components(placed?, components, web)
        |> sign_in_placement(web, components, placed?)
        |> home_and_access(app, web, router)
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

    defp sign_in_components(igniter, true, _components, _web), do: igniter

    defp sign_in_components(igniter, false, components, web) do
      create_module(igniter, components, "sign_in_components.ex", module: components, web: web)
    end

    # The way in and out is at the top of the root layout's body, where Phoenix's own
    # `phx.gen.auth` puts its menu: every page renders that layout with the request's conn, a
    # LiveView's included, and a LiveView's own layout has none. 0.4 put it on Phoenix's home
    # page, which an application's first page of its own replaces, and the link with it
    # (ehos-tools#37). A home page with the line 0.4 wrote, where 0.4 wrote it, has it moved; one
    # the developer has moved stays where it is. A root that is not Phoenix's is the developer's:
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
          off_home(igniter, on_home?, home, flash, call, components)

        # The developer commented it out on the root: what they turned off is not brought back,
        # and the home page keeps the only way in and out there is.
        root_content =~ call ->
          commented_out_on_root(igniter, on_home?, home, root, call)

        root_content =~ root_body() ->
          igniter
          |> Igniter.update_file(root, &Rewrite.Source.update(&1, :content, on_root(&1, call)))
          |> off_home(on_home?, home, flash, call, components)

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

    defp commented_out_on_root(igniter, false, _home, _root, _call), do: igniter

    defp commented_out_on_root(igniter, true, home, root, call) do
      Igniter.add_notice(igniter, """
      The way in and out is on #{home}, and commented out on #{root}, so both were left as
      they are. An application's first page of its own replaces the home page, and the
      link with it: uncomment `#{call}` on #{root}, and the next run takes it off
      #{home}.
      """)
    end

    defp off_home(igniter, false, _home, _flash, _call, _components), do: igniter

    defp off_home(igniter, true, home, flash, call, components),
      do: sign_in_off_home(igniter, home, flash, call, components)

    defp on_root(source, call) do
      source
      |> Rewrite.Source.get(:content)
      |> String.replace(root_body(), "\\0\\1  #{call}\\2", global: false)
    end

    # The line 0.4 wrote under the home page's flash group, in the page's own line endings.
    defp on_home(flash, call) do
      ~r/(#{Regex.escape(String.trim_trailing(flash))}\r?\n)#{Regex.escape(call)}\r?\n/
    end

    # Phoenix's welcome page, as `phx.new` writes it, by the SHA-256 of its bytes with LF line
    # endings: 1.8.14's, the version `ehosctl` has pinned since its first release (and what
    # `Igniter.Test.phx_test_project/1` writes). It names no application, so every project
    # `ehosctl init` makes gets the same bytes; `phx.new` with other options may not. A page that
    # is not one of these is the developer's, and stays. A later `phx_new` pin adds its page's
    # hash here: until then its welcome page is left with a notice, which says so, and a project
    # it makes is not read as new (`fresh?` in `install/2`), so it is not given Boundary, Credo,
    # the conventions test or the clock either.
    @phoenix_home_pages ["c570aada5253aa7eaa49f26420ab3b573017169d367ced7516f23af34c758f0f"]
    @phoenix_tagline "Peace of mind from prototype to production"

    # An application opens on a page of its own rather than Phoenix's welcome page (ehos-tools#198):
    # its name, what it is, and a way to the page that shows a signed-in person their access, which
    # sits behind `:signed_in`, so a visitor is sent to sign in through EHOS and comes back to
    # it. Only while the home page is still Phoenix's, byte for byte, as a CI workflow is
    # replaced only while it is an earlier version's: that is a new project, or one from an
    # earlier version whose home page nobody has touched. Once replaced, the home page is not
    # Phoenix's any more, so a later run changes nothing, and a page the developer deletes is
    # not brought back. The access page is written with it, each file once, at `/access`, with
    # `<App>.Access`, the behaviour that says what the person may do, mocked in tests (T-20). A
    # project with an `AccessController`, `AccessHTML` or `<App>.Access` of its own, or a route at
    # `/access` already, keeps Phoenix's page: the new one links to `~p"/access"`, which must be
    # this page.
    defp home_and_access(igniter, app, web, router) do
      home = "lib/#{app}_web/controllers/page_html/home.html.heex"
      igniter = Igniter.include_existing_file(igniter, home)
      content = file_content(igniter, home)

      cond do
        phoenix_home?(igniter, app) ->
          home_and_access(igniter, app, web, router, home, content)

        content =~ @phoenix_tagline ->
          Igniter.add_notice(igniter, """
          #{home} still says "#{@phoenix_tagline}", but is not the Phoenix welcome page
          this version of ehos_app recognises, so it was left as it is. Give the application's
          home page its own content; ehos_app's CHANGELOG says how to add the access page a new
          project links to from there.
          """)

        true ->
          igniter
      end
    end

    # Phoenix's welcome page, byte for byte: a project phx.new made and nobody has touched.
    defp phoenix_home?(igniter, app) do
      home = "lib/#{app}_web/controllers/page_html/home.html.heex"
      igniter = Igniter.include_existing_file(igniter, home)
      content = file_content(igniter, home)
      sha256(String.replace(content, "\r\n", "\n")) in @phoenix_home_pages
    end

    defp home_and_access(igniter, app, web, router, home, content) do
      access = Module.concat(web, AccessController)
      access_html = Module.concat(web, AccessHTML)
      prefix = Igniter.Project.Module.module_name_prefix(igniter)
      behaviour = Module.concat(prefix, Access)
      {igniter, signed_in?} = Igniter.Libs.Phoenix.has_pipeline(igniter, router, :signed_in)
      {access?, igniter} = Igniter.Project.Module.module_exists(igniter, access)
      {access_html?, igniter} = Igniter.Project.Module.module_exists(igniter, access_html)
      {behaviour?, igniter} = Igniter.Project.Module.module_exists(igniter, behaviour)
      {igniter, taken?} = path_taken?(igniter, router, ["/access"])

      cond do
        not signed_in? ->
          Igniter.add_notice(igniter, """
          #{home} is still Phoenix's welcome page. It was left as it is because the router has
          no `:signed_in` pipeline, which the page that replaces it links to. Add
          `pipeline :signed_in do plug EhOsContract.Auth.Session end` to the router and run the
          installer again.
          """)

        access? or access_html? or behaviour? or taken? ->
          Igniter.add_notice(igniter, """
          #{home} is still Phoenix's welcome page. It was left as it is because the project
          already has #{inspect(access)}, #{inspect(access_html)}, #{inspect(behaviour)} or a
          route at /access, which the page that replaces it would need for its own. Give the
          application's home page its own content.
          """)

        true ->
          name = inspect(prefix)

          boundary? =
            igniter.assigns[:ehos_app_boundary?] == true or
              igniter.assigns[:ehos_app_boundary_own?] == true

          assigns = [
            web: web,
            name: name,
            ehos_name: ehos_name(app),
            app: app,
            boundary: boundary?
          ]

          page = render("home.html.heex", assigns)
          # In the page's own line endings.
          page = if content =~ "\r\n", do: String.replace(page, "\n", "\r\n"), else: page

          igniter
          |> Igniter.update_file(home, &Rewrite.Source.update(&1, :content, page))
          |> phoenix_home_test(app, web)
          # Where Igniter puts a module, as it does `SignIn`: a project generated by `igniter.new`
          # moves a module written elsewhere there when the run is applied. So the page's
          # template is inside `AccessHTML`, which `embed_templates` would look for beside it.
          |> create_module(access, "access_controller.ex", Keyword.put(assigns, :module, access))
          |> create_module(
            access_html,
            "access_html.ex",
            Keyword.put(assigns, :module, access_html)
          )
          |> create_test(
            access,
            "access_controller_test.exs",
            Keyword.merge(assigns,
              module: Module.concat(web, AccessControllerTest),
              conn_case: Module.concat(web, ConnCase)
            )
          )
          |> access_route(router, web)
          |> access_behaviour(prefix, behaviour, assigns)
      end
    end

    # What the access page shows is `<App>.Access`'s to say: a behaviour, chosen in the
    # configuration, with its own test. Its mock is declared where the project's mocks are, by
    # `elixir_tools/5`, which runs after this and reads the assign.
    defp access_behaviour(igniter, prefix, behaviour, assigns) do
      igniter
      |> create_module(behaviour, "access.ex", assigns)
      |> create_test(behaviour, "access_test.exs", assigns)
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        assigns[:app],
        [behaviour, :impl],
        Module.concat(prefix, AccessImpl)
      )
      |> Igniter.Project.Config.configure_new(
        "test.exs",
        assigns[:app],
        [behaviour, :impl],
        Module.concat(prefix, AccessMock)
      )
      |> Igniter.assign(:ehos_app_access?, true)
      |> then(
        &if(&1.assigns[:ehos_app_boundary_own?], do: export_access_notice(&1, prefix), else: &1)
      )
    end

    # The project's boundaries are its own: the run does not edit its root's exports.
    defp export_access_notice(igniter, prefix) do
      Igniter.add_notice(igniter, """
      The access page calls #{inspect(prefix)}.Access, a boundary of its own, which the web can
      reach only once #{inspect(prefix)}'s `use Boundary` lists Access in its exports. Add it there.
      """)
    end

    # Phoenix's test of its welcome page asserts its tagline, so it goes with the page. One the
    # developer has changed stays, with a notice.
    defp phoenix_home_test(igniter, app, web) do
      path = "test/#{app}_web/controllers/page_controller_test.exs"
      igniter = Igniter.include_existing_file(igniter, path)
      content = file_content(igniter, path)

      phoenix = """
      defmodule #{inspect(web)}.PageControllerTest do
        use #{inspect(web)}.ConnCase

        test "GET /", %{conn: conn} do
          conn = get(conn, ~p"/")
          assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
        end
      end
      """

      ours =
        render("page_controller_test.exs",
          module: Module.concat(web, PageControllerTest),
          conn_case: Module.concat(web, ConnCase)
        )

      cond do
        plain_lines(content) == plain_lines(phoenix) ->
          Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, ours))

        content =~ @phoenix_tagline ->
          Igniter.add_notice(igniter, """
          The home page is the application's own now, and #{path} still looks for Phoenix's
          welcome page: assert what the new page shows instead, as a new project's test does.
          """)

        true ->
          igniter
      end
    end

    # Whether the router serves anything at one of `paths` already: a scope or a route whose path
    # is that literal, read as code, so a comment does not count. A router that does not parse is
    # taken as serving it, and left alone.
    defp path_taken?(igniter, router, paths) do
      {:ok, {igniter, source, _zipper}} = Igniter.Project.Module.find_module(igniter, router)

      taken? =
        case Code.string_to_quoted(Rewrite.Source.get(source, :content), emit_warnings: false) do
          {:ok, quoted} ->
            quoted
            |> Macro.prewalk(false, fn
              {call, _, [path | _]} = node, found when is_atom(call) and is_binary(path) ->
                {node, found or path in paths}

              node, found ->
                {node, found}
            end)
            |> elem(1)

          {:error, _} ->
            true
        end

      {igniter, taken?}
    end

    # A scope of its own path: a later `append_to_scope/4` for "/" and `:browser`, the design
    # system's page for one, takes the first scope that pipes through `:browser`, and would put
    # its route behind `:signed_in` too.
    defp access_route(igniter, router, web) do
      Igniter.Libs.Phoenix.add_scope(
        igniter,
        "/access",
        """
        pipe_through [:browser, :signed_in]

        get "/", AccessController, :show
        """,
        arg2: web,
        router: router
      )
    end

    # The tab's title names the application alone: Phoenix's root layout adds " · Phoenix
    # Framework" to every page's. Only that literal goes; a suffix of the application's own stays.
    defp without_phoenix_title(igniter, app) do
      # `phx.new` names the folder after the application, whatever `--module` names the modules.
      root = "lib/#{app}_web/components/layouts/root.html.heex"

      igniter = Igniter.include_existing_file(igniter, root)

      if file_content(igniter, root) =~ phoenix_title_suffix() do
        Igniter.update_file(igniter, root, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, phoenix_title_suffix(), ""))
        end)
      else
        igniter
      end
    end

    defp phoenix_title_suffix, do: ~r/[ \t]+suffix=" · Phoenix Framework"/

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

    # The seed EHOS runs in an ephemeral environment (eh-os D-98): the module, the configuration
    # it reads, and its call in `priv/repo/seeds.exs`, written with the module or not at all,
    # wherever a seed the developer has lives, since it is theirs. The example's steps only where
    # this run writes the example, whose contract names `:sample_data` (ehos-tools#476). Its test
    # only where `test?` and `lib/<app>/contracts/` has no contract yet, the example's written after:
    # a contract it has may have commands no step issues, which the test would fail on.
    defp seed(igniter, seed, app, repo, example?, test?) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, seed)
      # Where the template's AGENTS.md has a contract written: reading every file this early
      # makes the rest of the run slower (ehos-tools#662).
      {igniter, contracts?} = contracts?(igniter, "lib/*/contracts/**/*.ex")
      test? = test? and not contracts?

      if exists? do
        igniter
      else
        assigns = [
          module: seed,
          app: app,
          repo: repo,
          example: example?,
          contract: Igniter.Project.Module.module_name(igniter, "Contracts.Entries"),
          data_case: Igniter.Project.Module.module_name(igniter, "DataCase")
        ]

        igniter
        |> create_module(seed, "seed.ex", assigns)
        |> then(&if(test?, do: create_test(&1, seed, "seed_test.exs", assigns), else: &1))
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          app,
          [seed, :production_environments],
          ["production"]
        )
        |> Igniter.Project.Config.configure_new(
          "runtime.exs",
          app,
          [seed, :profile],
          {:code, Sourceror.parse_string!(~s|System.get_env("EHOS_SEED_PROFILE")|)}
        )
        |> Igniter.Project.Config.configure_new(
          "runtime.exs",
          app,
          [seed, :environment],
          {:code, Sourceror.parse_string!(~s|System.get_env("EHOS_ENVIRONMENT")|)}
        )
        |> seeds_script(seed)
      end
    end

    # `phx.new`'s `priv/repo/seeds.exs` holds comments alone, so the seed's call goes under them,
    # for `mix ecto.setup` and EHOS alike; a script with code of its own is the developer's.
    defp seeds_script(igniter, seed) do
      path = "priv/repo/seeds.exs"
      call = "#{inspect(seed)}.add(#{inspect(seed)}.profile())\n"

      if Igniter.exists?(igniter, path) do
        igniter = Igniter.include_existing_file(igniter, path)
        seeds_call(igniter, path, call, comments_only?(file_content(igniter, path)))
      else
        Igniter.create_new_file(igniter, path, call)
      end
    end

    defp seeds_call(igniter, path, call, true = _comments_only?) do
      Igniter.update_file(
        igniter,
        path,
        &Rewrite.Source.update(&1, :content, fn content ->
          String.trim_trailing(content) <> "\n\n" <> call
        end)
      )
    end

    defp seeds_call(igniter, path, call, false = _comments_only?) do
      Igniter.add_notice(igniter, """
      #{path} has code of its own, so it was left alone. For the seed to record the
      sample data of `EHOS_SEED_PROFILE`, add to it: #{String.trim(call)}
      """)
    end

    defp comments_only?(content) do
      content
      |> String.split("\n")
      |> Enum.all?(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
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
        contract_docs: @contract_docs,
        seed: inspect(Igniter.Project.Module.module_name(igniter, "Seed"))
      )
      |> create_module(contract, "entries_contract.ex",
        module: contract,
        domain: domain,
        contract_docs: @contract_docs,
        id: "#{name}.entries",
        publication: "#{name}.entry.recorded.v1",
        flagged_publication: "#{name}.entry.flagged.v1"
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
      |> entry_page(router, app, web, contract)
    end

    defp example(igniter, _, _app, _web), do: igniter

    # The pattern of a page that issues a command as the person signed in (ehos-tools#700): a
    # context that calls `EhOsContract.call/3` with the person's actor, a LiveView behind
    # `:signed_in` that asks for the actor on each submit, and a test that signs in. Only where
    # the router has the pipelines the route sits behind, `:browser` and `:signed_in`, which the
    # run gives a project with a browser pipeline. Each file is written once, and the route added
    # once: a module or a route that exists is the developer's. A project with an `EntryLive` or
    # an `<App>.Entries` of its own, or whose router names `/entries`, gets none of it, with a
    # notice.
    defp entry_page(igniter, nil, _app, _web, _contract), do: igniter

    defp entry_page(igniter, router, app, web, contract) do
      case entry_page_state(igniter, router, web) do
        {:exists, igniter} -> entry_route(igniter, router, web)
        {:write, igniter} -> write_entry_page(igniter, router, app, web, contract)
        {:taken, igniter} -> entries_taken_notice(igniter, web)
        {:path_taken, igniter} -> entries_path_notice(igniter)
        {:none, igniter} -> igniter
      end
    end

    # `:none` without the pipelines the page sits behind, whether or not the project has it, so
    # no route goes through a pipeline the router lacks; `:exists` once the project has the page,
    # wherever it is; `:taken` where the project has a page or a context of the page's names of
    # its own; `:path_taken` where the router names `/entries` already; `:write` where the run
    # can write it.
    defp entry_page_state(igniter, router, web) do
      context = Igniter.Project.Module.module_name(igniter, "Entries")
      {live, igniter} = entry_live(igniter, web)
      {context?, igniter} = Igniter.Project.Module.module_exists(igniter, context)
      {igniter, path_taken?} = path_taken?(igniter, router, ["/entries", "/entries/new"])
      {igniter, browser?} = Igniter.Libs.Phoenix.has_pipeline(igniter, router, :browser)
      {igniter, signed_in?} = Igniter.Libs.Phoenix.has_pipeline(igniter, router, :signed_in)

      cond do
        not (browser? and signed_in?) -> {:none, igniter}
        live == :example -> {:exists, igniter}
        live == :own or context? -> {:taken, igniter}
        path_taken? -> {:path_taken, igniter}
        true -> {:write, igniter}
      end
    end

    # What `<Web>.EntryLive` is: `:example` where it calls the example's context, as the page the
    # template writes does, wherever the developer moved it; `:own` where it is a page of the
    # project's own of that name; `:none` without one.
    defp entry_live(igniter, web) do
      case Igniter.Project.Module.find_module(igniter, Module.concat(web, EntryLive)) do
        {:ok, {igniter, source, _zipper}} ->
          example? = Rewrite.Source.get(source, :content) =~ "Entries.record_entry("
          {if(example?, do: :example, else: :own), igniter}

        {:error, igniter} ->
          {:none, igniter}
      end
    end

    defp write_entry_page(igniter, router, app, web, contract) do
      context = Igniter.Project.Module.module_name(igniter, "Entries")
      live = Module.concat(web, EntryLive)
      name = ehos_name(app)

      assigns = [
        web: web,
        context: context,
        contract: contract,
        live: live,
        name: name,
        contract_dir: Path.dirname(@contract_docs),
        # Where the run declared the boundaries; a project's own may not export the context.
        boundary: igniter.assigns[:ehos_app_boundary?] == true
      ]

      igniter
      |> create_module(context, "entries.ex", Keyword.put(assigns, :module, context))
      |> write_template(
        "entry_live.ex",
        "lib/#{app}_web/live/entry_live.ex",
        Keyword.put(assigns, :module, live)
      )
      |> write_template(
        "entry_live_test.exs",
        "test/#{app}_web/live/entry_live_test.exs",
        module: Module.concat(web, EntryLiveTest),
        conn_case: Module.concat(web, ConnCase),
        repo: Igniter.Project.Module.module_name(igniter, "Repo"),
        name: name
      )
      |> entry_route(router, web)
      |> Igniter.assign(:ehos_app_entries?, true)
      |> then(
        &if(&1.assigns[:ehos_app_boundary_own?], do: export_entries_notice(&1, context), else: &1)
      )
    end

    # The project's boundaries are its own: the run does not edit its root's exports.
    defp export_entries_notice(igniter, context) do
      prefix = Igniter.Project.Module.module_name_prefix(igniter)

      Igniter.add_notice(igniter, """
      The page that records an entry calls #{inspect(context)}, which the web can reach only once
      #{inspect(prefix)}'s `use Boundary` lists Entries in its exports. Add it there.
      """)
    end

    defp entries_taken_notice(igniter, web) do
      live = Module.concat(web, EntryLive)
      context = Igniter.Project.Module.module_name(igniter, "Entries")

      {found, igniter} =
        case entry_live(igniter, web) do
          {:own, igniter} ->
            {"a page #{inspect(live)} of its own", igniter}

          {_none, igniter} ->
            {"a module #{inspect(context)} and no page #{inspect(live)}", igniter}
        end

      Igniter.add_notice(igniter, """
      The project has #{found}, so the example's page that records an entry was not written.
      """)
    end

    defp entries_path_notice(igniter) do
      Igniter.add_notice(igniter, """
      The router names /entries already, or could not be read, so the example's page that records
      an entry, which it would serve at /entries/new, was not written.
      """)
    end

    # A route to the page at any path is the developer's, as the design system's page's is.
    defp entry_route(igniter, router, web) do
      {routed?, igniter} = live_routed?(igniter, router, "EntryLive")

      if routed? do
        igniter
      else
        # A scope of its own path, as the access page's, so a later route for "/" stays public.
        Igniter.Libs.Phoenix.add_scope(
          igniter,
          "/entries",
          """
          pipe_through [:browser, :signed_in]

          live "/new", EntryLive
          """,
          arg2: web,
          router: router
        )
      end
    end

    # Whether the router routes a LiveView named `name` at any path, outside a comment.
    defp live_routed?(igniter, router, name) do
      {:ok, {igniter, source, _zipper}} = Igniter.Project.Module.find_module(igniter, router)

      routed? =
        source
        |> Rewrite.Source.get(:content)
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
        # The module itself, not one under it: `EntryLive.Form` is no route to `EntryLive`.
        |> Enum.any?(&(&1 =~ ~r/\blive\(?\s*"[^"]*",\s*(?:\w+\.)*#{name}\b(?!\.)/))

      {routed?, igniter}
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

    defp design_system(igniter, app, endpoint) do
      case design_system_state(igniter) do
        {igniter, :declined, _content} ->
          igniter

        {igniter, state, content} ->
          # Hooks only with the version this run adds: one the project pinned may have none.
          pin = design_system_pin(igniter)
          from = design_system_ref(igniter)
          igniter = design_system_dep(igniter, pin)

          moved = design_system_move(igniter, pin, from)

          igniter
          |> design_system_styles(state, content)
          |> design_system_fonts(endpoint)
          |> design_system_first_install(state, app, pin != :none)
          |> design_system_moved(moved)
      end
    end

    # What became of an earlier version's commit: moved from it, the move declined, or kept as
    # the project's own; `nil` for any other pin.
    defp design_system_move(igniter, :earlier, from) do
      if design_system_pin(igniter) == :current, do: {:moved, from}, else: :declined
    end

    defp design_system_move(_igniter, :earlier_own, from), do: {:kept, from}
    defp design_system_move(_igniter, _pin, _from), do: nil

    # Which `ehos_design` the project has: none yet, the commit this version pins, the commit an
    # earlier version pinned, written as it wrote it, or another source the project chose: a
    # path, a tag, a `git:` URL, or an option of its own beside an earlier commit
    # (`override:`, `only:`), which the move would drop.
    defp design_system_pin(igniter) do
      case Igniter.Project.Deps.get_dep(igniter, :ehos_design) do
        {:ok, dep} when is_binary(dep) -> design_system_pin(dep, dep_opts(dep))
        _none -> :none
      end
    end

    defp design_system_pin(dep, opts) do
      cond do
        not ehos_design?(opts) -> :other
        opts[:ref] == @ehos_design_ref -> :current
        as_written?(dep, @earlier_ehos_design[opts[:ref]]) -> :earlier
        Map.has_key?(@earlier_ehos_design, opts[:ref]) -> :earlier_own
        true -> :other
      end
    end

    defp design_system_ref(igniter) do
      case Igniter.Project.Deps.get_dep(igniter, :ehos_design) do
        {:ok, dep} when is_binary(dep) -> dep_opts(dep)[:ref]
        _none -> nil
      end
    end

    defp ehos_design?(opts) do
      String.downcase(opts[:github] || "") == "empoweredhouse/ehos-tools" and
        opts[:sparse] == "packages/ehos_design"
    end

    # With exactly the requirement and the options an earlier version wrote, read as code.
    defp as_written?(_dep, nil), do: false

    defp as_written?(dep, requirement) do
      case Code.string_to_quoted(dep, emit_warnings: false) do
        {:ok, {:{}, _, [_name, ^requirement, opts]}} when is_list(opts) ->
          Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:github, :ref, :sparse]

        _other ->
          false
      end
    end

    # A project moved from 0.1.0's commit gets what the versions since need of its stylesheet
    # and script, which it was never given: the components' templates as a source for Tailwind
    # and their hooks. One moved from 0.2.0's was given both, so one it lacks was removed, and
    # stays removed. A declined move changes neither.
    defp design_system_moved(igniter, {:moved, from}) do
      igniter =
        case {from, design_system_state(igniter)} do
          {@ehos_design_without_assets, {igniter, :installed, content}} ->
            igniter |> design_system_source(content) |> design_system_hooks()

          {_from, {igniter, _state, _content}} ->
            igniter
        end

      Igniter.add_notice(igniter, """
      ehos_design moved from the commit an earlier ehos_app pinned to its release
      #{@ehos_design_release}, commit #{@ehos_design_ref}. The next `mix deps.get` takes it into
      mix.lock with premailex and Floki, which it depends on from 0.4.0: commit mix.lock with it,
      and drop `only: :test` from a Floki of the project's own. From 0.3.0, a module that imports
      EhosDesign.Components beside a `badge/1` of its own no longer compiles where it calls
      `<.badge>`: remove the project's own, or import the components with `except: [badge: 1]`.
      daisyUI's `.badge` takes the design system's look: `badge-success` is the live badge, and
      every other colour and size the neutral one. The package's CHANGELOG.md, in
      #{@design_system}/, says what else changed.
      """)
    end

    defp design_system_moved(igniter, :declined) do
      Igniter.add_warning(igniter, """
      ehos_design was not moved from the commit an earlier ehos_app pinned to its release
      #{@ehos_design_release}, which this ehos_app is written for. Run the installer again and
      accept the move, or pass --yes.
      """)
    end

    defp design_system_moved(igniter, {:kept, from}) do
      Igniter.add_warning(igniter, """
      ehos_design is on the commit an earlier ehos_app pinned, with a requirement or an option of
      the project's own, so it was left as it is. This ehos_app is written for its release
      #{@ehos_design_release}, commit #{@ehos_design_ref}: move the `ref:` and the requirement
      by hand, keeping the rest.#{if from == @ehos_design_without_assets, do: without_assets_hint()}
      """)
    end

    defp design_system_moved(igniter, nil), do: igniter

    # After Phoenix's own source, as a first install writes it.
    defp design_system_source(igniter, content) do
      line = ~s|@source "#{@design_system_lib}";|

      cond do
        content =~ line ->
          igniter

        content =~ phoenix_lib_source() ->
          Igniter.update_file(
            igniter,
            @app_css,
            &Rewrite.Source.update(&1, :content, fn css -> with_source(css, line) end)
          )

        true ->
          source_notice(igniter, content)
      end
    end

    defp with_source(css, line),
      do: String.replace(css, phoenix_lib_source(), &(&1 <> line <> line_end(&1)), global: false)

    # Only when this run imported the layer: a stylesheet without Tailwind's import is left
    # alone, and fonts it never uses would be preloaded on every page, and come back on every
    # run.
    defp design_system_first_install(igniter, state, app, had_dep?) do
      case {state, design_system_state(igniter)} do
        {:absent, {igniter, :installed, _content}} ->
          igniter = design_system_preload(igniter, app)
          if had_dep?, do: igniter, else: design_system_hooks(igniter)

        {_state, {igniter, _now, _content}} ->
          igniter
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
          Rewrite.Source.update(source, :content, &with_preloads(&1, stylesheet, preloads))
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

    # In the layout's own line endings, CRLF included.
    defp with_preloads(content, stylesheet, preloads) do
      newline = if content =~ "\r\n", do: "\r\n", else: "\n"

      String.replace(content, stylesheet, Enum.join(preloads, newline) <> newline <> "\\0",
        global: false
      )
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
          Rewrite.Source.update(source, :content, &with_design_hooks(&1, import, hooks))
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

    # What a project on 0.1.0's commit adds by hand when it moves: a later run finds the pin
    # current, and adds neither.
    defp without_assets_hint do
      " 0.1.0's projects were not given the components' templates as a source for Tailwind " <>
        ~s|or their hooks: add `@source "#{@design_system_lib}";` after Phoenix's own in | <>
        "#{@app_css}, and `#{String.trim(@design_hooks_import)}` with `...designHooks` in " <>
        "the LiveSocket's `hooks:` in #{@app_js}."
    end

    defp with_design_hooks(content, import, hooks) do
      content
      |> String.replace(import, import <> hooks, global: false)
      |> String.replace(colocated_spread(), "\\0, ...designHooks", global: false)
    end

    # In the script's own line endings, CRLF included, and however `hooks:` is laid out.
    defp colocated_import,
      do: ~r/^import \{hooks as colocatedHooks\} from "phoenix-colocated\/[a-z0-9_]+";?\r?\n/m

    defp colocated_spread, do: ~r/hooks:\s*\{\s*\.\.\.colocatedHooks\b/

    # Phoenix 1.8's source for the application's own templates, in app.css.
    defp phoenix_lib_source, do: ~r/^@source "\.\.\/\.\.\/lib\/[a-z0-9_]+";\r?\n/m

    defp line_end(line), do: if(String.ends_with?(line, "\r\n"), do: "\r\n", else: "\n")

    # A version the developer has moved to is theirs: the dependency is added when missing, and
    # moved only from a commit an earlier version pinned.
    # Moving one asks first, unless `--yes`, as eh-os-contract's move does.
    defp design_system_dep(igniter, :none),
      do: Igniter.Project.Deps.add_dep(igniter, @ehos_design)

    defp design_system_dep(igniter, :earlier),
      do: Igniter.Project.Deps.add_dep(igniter, @ehos_design, yes?: igniter.args.options[:yes])

    defp design_system_dep(igniter, _pin), do: igniter

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
      case Regex.run(~r/name: "(dark|light)";/, block, capture: :all_but_first) do
        [name] -> declarations(block) == Map.fetch!(@phoenix_themes, name)
        _ -> false
      end
    end

    defp declarations(block) do
      block
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "--"))
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
      The installer found no line in #{path} starting `@import "tailwindcss"` to put the
      design system's import after, so the design system was not imported. To use it, import
      its layer after Tailwind's, keep daisyUI's own themes off, and remove any daisyui-theme:

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
      {routed?, igniter} = live_routed?(igniter, router, "DesignSystemLive")

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

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ehos_app.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installing-igniter
      """)

      exit({:shutdown, 1})
    end
  end
end

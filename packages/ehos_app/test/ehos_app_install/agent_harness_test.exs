defmodule Mix.Tasks.EhosApp.InstallTest.AgentHarness do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "the agent harness" do
    defp with_file(path, content) do
      phx_test_project()
      |> Igniter.create_or_update_file(path, content, fn source ->
        Rewrite.Source.update(source, :content, fn _ -> content end)
      end)
      |> apply_igniter!()
    end

    # Phoenix 1.8's AGENTS.md, as `phx.new` assembles it: its own lines, then the usage rules of
    # the packages it uses between markers.
    @phoenix_agents """
    This is a web application written using the Phoenix web framework.

    ## Project guidelines

    - Use `mix precommit` alias when you are done with all changes and fix any pending issues

    <!-- usage-rules-start -->
    <!-- phoenix:elixir-start -->
    ## Elixir guidelines
    <!-- phoenix:elixir-end -->
    <!-- usage-rules-end -->
    """

    # What the installer writes and never rewrites, and what it keeps a section of.
    @seeds [
      "CLAUDE.md",
      "lib/test/contracts/CLAUDE.md",
      "lib/test_web/CLAUDE.md",
      ".coderabbit.yaml",
      ".github/pull_request_template.md",
      ".github/workflows/review.yml",
      "test/harness_test.exs"
    ]
    @managed [
      {"AGENTS.md", "agents"},
      {"README.md", "readme"},
      {"VISION.md", "vision"},
      {"lib/test/contracts/AGENTS.md", "contracts"},
      {"lib/test_web/AGENTS.md", "web"},
      {"ARCHITECTURE.md", "architecture"},
      {"TESTING.md", "testing"},
      {"DEVELOPMENT.md", "development"},
      {"docs/elixir.md", "elixir"}
    ]

    # The line budgets `test/harness_test.exs` holds the managed files to.
    @budgets %{
      "ARCHITECTURE.md" => 400,
      "DEVELOPMENT.md" => 400,
      "TESTING.md" => 300,
      "docs/elixir.md" => 400
    }

    defp section(name), do: ~r/<!-- ehos_app:#{name} -->.*?<!-- \/ehos_app:#{name} -->\n?/s

    test "moves Phoenix's AGENTS.md to docs/phoenix.md, as Phoenix wrote it, and writes a lean one" do
      igniter =
        with_file("AGENTS.md", @phoenix_agents) |> Igniter.compose_task("ehos_app.install", [])

      agents = content(igniter, "AGENTS.md")

      assert content(igniter, "docs/phoenix.md") == @phoenix_agents
      assert agents =~ ~r/\A<!-- ehos_app:agents -->/
      refute agents =~ "usage-rules-start"
      assert agents =~ "[docs/phoenix.md](docs/phoenix.md)"
      assert content(igniter, "lib/test_web/AGENTS.md") =~ "(../../docs/phoenix.md)"
      assert agents |> String.split("\n") |> length() <= 200
    end

    test "puts the EHOS section on top of an AGENTS.md of the project's own" do
      igniter =
        with_file("AGENTS.md", "# Our rules\n") |> Igniter.compose_task("ehos_app.install", [])

      agents = content(igniter, "AGENTS.md")

      assert agents =~ ~r/\A<!-- ehos_app:agents -->/
      assert agents =~ ~r/<!-- \/ehos_app:agents -->\n\n# Our rules\n\z/
      refute Igniter.exists?(igniter, "docs/phoenix.md")
      refute content(igniter, "lib/test_web/AGENTS.md") =~ "docs/phoenix.md"
    end

    test "replaces the EHOS section an earlier version wrote, and keeps the rest" do
      igniter =
        with_file(
          "AGENTS.md",
          "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n\n# Phoenix rules\n"
        )
        |> Igniter.compose_task("ehos_app.install", [])

      content = content(igniter, "AGENTS.md")

      refute content =~ "Old rules"
      assert content =~ "# EHOS application"
      assert content =~ ~r/<!-- \/ehos_app:agents -->\n\n# Phoenix rules\n\z/
    end

    test "says how to move Phoenix's rules out of an AGENTS.md from ehos_app 0.2" do
      agents =
        "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n\n" <> @phoenix_agents

      igniter = with_file("AGENTS.md", agents) |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "AGENTS.md") =~ @phoenix_agents
      refute Igniter.exists?(igniter, "docs/phoenix.md")
      assert Enum.any?(igniter.notices, &(&1 =~ "into\ndocs/phoenix.md"))
      refute installed() |> Map.fetch!(:notices) |> Enum.any?(&(&1 =~ "docs/phoenix.md"))
    end

    test "gives an AGENTS.md that holds the EHOS section alone, as 0.2 wrote it, the application's part" do
      agents = "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n"
      igniter = with_file("AGENTS.md", agents) |> Igniter.compose_task("ehos_app.install", [])

      content = content(igniter, "AGENTS.md")

      refute content =~ "Old rules"
      assert content =~ ~r/\A<!-- ehos_app:agents -->/
      assert content =~ ~r/<!-- \/ehos_app:agents -->\n+# Test\n/
      assert content =~ "## Where to read"
      assert content =~ "## Nested AGENTS.md files"
      assert content == content(installed(), "AGENTS.md")
    end

    test "leaves a nested AGENTS.md the developer cut down to the EHOS section as it is" do
      igniter = installed()
      web = content(igniter, "lib/test_web/AGENTS.md")
      [section] = Regex.run(section("web"), web)

      again =
        igniter
        |> Igniter.update_file("lib/test_web/AGENTS.md", fn source ->
          Rewrite.Source.update(source, :content, fn _ -> section end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(again, "lib/test_web/AGENTS.md") == section
    end

    test "leaves an EHOS section alone when its end marker is gone" do
      agents = "<!-- ehos_app:agents -->\nRules the developer rewrote\n\n# Phoenix rules\n"
      igniter = with_file("AGENTS.md", agents) |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "AGENTS.md") == agents
    end

    # The README phx.new writes, rendered from the template of the phx_new this package tests
    # against, so that a change to it in a later Phoenix fails here rather than in a project.
    defp phoenix_readme do
      Mix.Project.deps_paths()
      |> Map.fetch!(:phx_new)
      |> Path.join("templates/phx_single/README.md.eex")
      |> File.read!()
      |> EEx.eval_string(assigns: [app_module: "Test"])
    end

    test "replaces the README Phoenix generates, and keeps one of the project's own" do
      for phoenix <- [
            phoenix_readme(),
            phoenix_readme() |> String.replace("\n", " \r\n"),
            phoenix_readme() |> String.replace("\n", "\t\n")
          ] do
        readme = with_file("README.md", phoenix) |> Igniter.compose_task("ehos_app.install", [])

        assert content(readme, "README.md") =~ ~r/\A# Test\n\n<!-- One sentence/
        assert content(readme, "README.md") =~ "## Quick start"
        refute content(readme, "README.md") =~ "To start your Phoenix server"
      end

      own = with_file("README.md", "# Ours\n") |> Igniter.compose_task("ehos_app.install", [])

      assert content(own, "README.md") =~ ~r/\A<!-- ehos_app:readme -->.*\n# Ours\n\z/s
    end

    test "keeps a README of the project's own that still quotes Phoenix's sentence" do
      for readme <- [
            "# Shop\n\nWhat it does.\n\n## Running it\n\nTo start your Phoenix server:\n\n* `mix setup`\n",
            "# Shop\n\nTo start your Phoenix server:\n\n" <> String.duplicate("Our notes.\n", 40),
            # Phoenix's own, with a few lines of the developer's at the end.
            String.replace(phoenix_readme(), "# Test", "# Shop") <>
              "\n## Deploying\n\nfly deploy\n"
          ] do
        igniter = with_file("README.md", readme) |> Igniter.compose_task("ehos_app.install", [])

        assert content(igniter, "README.md") =~
                 ~r/\A<!-- ehos_app:readme -->.*<!-- \/ehos_app:readme -->\n\n# Shop\n/s

        assert content(igniter, "README.md") =~ readme
      end
    end

    test "writes every seed, and never overwrites one" do
      igniter = installed()

      for path <- @seeds, do: assert(Igniter.exists?(igniter, path), "#{path} was not written")

      mine =
        Enum.reduce(@seeds, phx_test_project(), fn path, igniter ->
          Igniter.create_or_update_file(igniter, path, "# mine\n", fn source ->
            Rewrite.Source.update(source, :content, fn _ -> "# mine\n" end)
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      for path <- @seeds, do: assert(content(mine, path) == "# mine\n", "#{path} was overwritten")
    end

    test "keeps a section in each managed file, on top of what the developer wrote" do
      igniter =
        Enum.reduce(@managed, phx_test_project(), fn {path, _}, igniter ->
          Igniter.create_or_update_file(igniter, path, "# mine\n", fn source ->
            Rewrite.Source.update(source, :content, fn _ -> "# mine\n" end)
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      for {path, name} <- @managed do
        assert content(igniter, path) =~ ~r/\A<!-- ehos_app:#{name} -->.*\n# mine\n\z/s, path
      end
    end

    # ehos-tools#504: the rules for code that is not a contract's part, in a doc of the template's
    # and as rules in the section every agent reads first.
    test "says how Elixir is written, in docs/elixir.md and as rules in AGENTS.md" do
      igniter = installed(["--example"])
      elixir = content(igniter, "docs/elixir.md")
      agents = content(igniter, "AGENTS.md")

      for heading <- [
            "# How Elixir is written",
            "## Ways out",
            "## Data",
            "## Pages and controllers",
            "## Control flow and style",
            "## This application's rules"
          ],
          do: assert(elixir =~ heading, heading)

      # The example's decider shows a contract's part needs no behaviour of its own.
      assert elixir =~ "`lib/test/entries/entry.ex`"
      refute installed() |> content("docs/elixir.md") =~ "entries/entry.ex"

      [section] = Regex.run(section("agents"), agents)
      assert section =~ "## How Elixir is written"
      assert section =~ "Load `/ehos-app:elixir` and read [docs/elixir.md](docs/elixir.md)"
      assert section =~ "## Execution discipline"
      assert section =~ "read the `git log` of the files it lives in"
      assert agents =~ "| Writing Elixir and its tests | [docs/elixir.md](docs/elixir.md) |"

      # Where the platform documents itself moved to ARCHITECTURE.md, to keep AGENTS.md short.
      refute section =~ "## Where the platform documents itself"
      assert content(igniter, "ARCHITECTURE.md") =~ "## Where the platform documents itself"

      assert content(igniter, "lib/test_web/AGENTS.md") =~
               "**A LiveView or a controller orchestrates**"

      testing = content(igniter, "TESTING.md")
      assert testing =~ "## Doubles"
      assert testing =~ "`Hammox.defmock/2` in `test/support/mocks.ex`"
      refute testing =~ "`async` test never changes `Application` env"
    end

    test "tells a project whose own AGENTS.md has no row for docs/elixir.md to add one" do
      notice = &String.contains?(&1, "Add it to AGENTS.md's \"Where to read\"")

      refute install() |> Map.fetch!(:notices) |> Enum.any?(notice)

      igniter =
        with_file("AGENTS.md", "# Our rules\n") |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, notice)
    end

    test "explains EHOS at the top of VISION.md, and points to it from the README" do
      igniter = installed()
      vision = content(igniter, "VISION.md")

      assert vision =~ ~r/\A# Test\n/
      assert vision =~ "## Where this application sits"
      assert vision =~ "The principles it inherits"
      assert content(igniter, "README.md") =~ "[VISION.md](VISION.md) says what that means"
    end

    test "says how a change is made, contract first, and how it is run, built and deployed" do
      development = installed() |> content("DEVELOPMENT.md")

      for heading <- [
            "## The cycle: contract first",
            "### 2. Change the contract",
            "### 3. Check the contract before writing code",
            "## Running it locally",
            "## Building",
            "## Deploying",
            "## Who deploys, and joining the team",
            "## Keeping it current"
          ],
          do: assert(development =~ heading, heading)

      # A developer who deploys is given a role for this application alone, never the operator's
      # keys.
      assert development =~
               "ehosctl role-bindings bind ehos.application_administrator --to <email> --app test"

      # A candidate in an ephemeral environment, promoted by the process owner: EHOS refuses a
      # deployment straight to production since 0.9.0 (eh-os D-105).
      assert development =~ "ehosctl env create test-try --app test"
      assert development =~ "ehosctl deploy test --env test-try"
      assert development =~ "**Promote to production**"
      refute development =~ "ehosctl deploy test --env production"
      # A first promotion puts the application's authority in force in production, so its approver
      # also registers it there (eh-os D-119).
      assert development =~
               "ehosctl role-bindings bind ehos.registrar --to <email> --app test --env production"

      # `ehosctl deploy --preview` refuses an `--image`.
      refute development =~ ~r/--image[^\n]*--preview/
      # A preview's credential cannot register the application, and EHOS refuses to trust a
      # repository for one it does not know: a person registers it once, first.
      [previews] = Regex.run(~r/## Previews of pull requests.*?(?=\n## )/s, development)

      {register, _} =
        :binary.match(
          previews,
          "ehosctl apps register _build/deploy/ehos.bundle/ehos.manifest.json"
        )

      {trust, _} = :binary.match(previews, "ehosctl trust add")
      assert register < trust

      # The trust a repository starts with accepts pull requests alone (eh-os D-121); `main` is
      # added only once a ruleset protects it, which the trust cannot require (eh-os#1056).
      assert previews =~
               "ehosctl trust add --app test --repo <owner>/<repository> --ref 'refs/pull/*/merge'\n"

      refute previews =~ "--ref refs/heads/main"
      assert previews =~ "first protect `main` with a ruleset"

      # By hand, a candidate is the newest build of `main`.
      assert development =~
               "ehosctl deploy test --env test-try --build latest --ref refs/heads/main"

      # Every download goes where git ignores it, so `git add .` commits no manifest
      # (ehos-tools#295).
      downloads =
        Regex.scan(~r/-n ehos-deployment -D (\S+)/, development, capture: :all_but_first)

      assert downloads != [] and Enum.all?(downloads, &(&1 == ["_build/deploy"]))
      refute development =~ ~r/[ (]deploy\/(ehos\.manifest\.json|image)/
      assert installed() |> content(".gitignore") =~ ~r{^/_build/$}m

      assert development =~ "mix eh_os_contract.check"
      assert installed() |> content("README.md") =~ "ehosctl verify"
    end

    test "names the application in commands as EHOS does, with dashes" do
      igniter =
        phx_test_project(app_name: :my_shop)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "DEVELOPMENT.md") =~ "ehosctl deploy my-shop --env my-shop-try"
      assert content(igniter, "README.md") =~ "ehosctl deploy my-shop --env"
    end

    # Before 0.9.0, ARCHITECTURE.md and TESTING.md were written once and never again.
    test "puts its section on top of an ARCHITECTURE.md an earlier version wrote, and says so" do
      igniter =
        with_file("ARCHITECTURE.md", "# Architecture\n\nOurs.\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ARCHITECTURE.md") =~
               ~r/\A<!-- ehos_app:architecture -->.*<!-- \/ehos_app:architecture -->\n\n# Architecture\n\nOurs\.\n\z/s

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "ARCHITECTURE.md has a section of the template's")
             )

      refute Enum.any?(install().notices, &(&1 =~ "has a section of the template's"))
    end

    # The file as 0.3.0 to 0.8.1 wrote it for this project, from that version's template.
    defp earlier_seed(name, version, example) do
      EEx.eval_file("priv/templates/ehos_app.install/earlier/#{name}-#{version}.md.eex",
        assigns: [
          app: :test,
          module: "Test",
          web: "TestWeb",
          web_port: 4000,
          health_port: 4001,
          example: example
        ]
      )
    end

    test "replaces an ARCHITECTURE.md or a TESTING.md still as an earlier version wrote it with the seed" do
      new_project = installed()

      for {path, name, version, example, newline} <- [
            {"ARCHITECTURE.md", "architecture", "0.3.0", false, "\n"},
            {"ARCHITECTURE.md", "architecture", "0.7.0", true, "\r\n"},
            {"TESTING.md", "testing", "0.3.0", true, "\n"},
            {"TESTING.md", "testing", "0.8.0", false, "\r\n"}
          ] do
        earlier = name |> earlier_seed(version, example) |> String.replace("\n", newline)

        igniter =
          with_file(path, earlier)
          |> Igniter.compose_task("ehos_app.install", [])

        assert content(igniter, path) == content(new_project, path),
               "#{path} as #{version} wrote it was not replaced"

        refute Enum.any?(igniter.notices, &(&1 =~ "has a section of the template's"))
      end
    end

    # 0.9 put its section on top of the file, untouched below it.
    test "replaces an ARCHITECTURE.md 0.9 put its section on top of, still as before below it" do
      new_project = installed()
      [section] = Regex.run(section("architecture"), content(new_project, "ARCHITECTURE.md"))
      upgraded_by_09 = section <> "\n" <> earlier_seed("architecture", "0.5.0", false)

      igniter =
        with_file("ARCHITECTURE.md", upgraded_by_09)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ARCHITECTURE.md") == content(new_project, "ARCHITECTURE.md")
    end

    test "keeps an ARCHITECTURE.md an earlier version wrote once the developer changed a line" do
      changed = earlier_seed("architecture", "0.7.0", false) <> "\nOurs.\n"

      igniter =
        with_file("ARCHITECTURE.md", changed)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "ARCHITECTURE.md") =~
               ~r/<!-- \/ehos_app:architecture -->\n\n#{Regex.escape(changed)}\z/

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "ARCHITECTURE.md has a section of the template's")
             )
    end

    # 0.2 wrote the root AGENTS.md as its section alone, which a later run makes the seed again.
    test "keeps the seed's sentence on the example when it writes the seed again without --example" do
      igniter = installed(["--example"])
      agents = content(igniter, "AGENTS.md")
      [alone] = Regex.run(section("agents"), agents)

      again =
        igniter
        |> replace_file("AGENTS.md", alone)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(again, "AGENTS.md") == agents
      assert agents =~ "The example is"
      refute content(installed(), "AGENTS.md") =~ "The example is"
    end

    test "writes the contract rules without --example too" do
      contracts = installed() |> content("lib/test/contracts/AGENTS.md")
      dir = Path.dirname(Install.contract_docs())

      for doc <- ["contract.md", "rules.md", "authorization.md", "dsl/contract-dsl.md"] do
        assert contracts =~ "#{dir}/#{doc}"
      end
    end

    test "points agents at the contract reference where the sparse dependency puts it" do
      docs = Install.contract_docs()
      assert docs == "deps/eh_os_contract/packages/eh_os_contract/docs/contract.md"

      igniter = installed(["--example"])

      for path <- [
            "AGENTS.md",
            "README.md",
            "lib/test/domain.ex",
            "lib/test/contracts/entries.ex"
          ] do
        assert content(igniter, path) =~ docs
      end
    end

    test "enables the ehos-app and eh-os-contract plugins in .claude/settings.json, at their tags, and the review gate" do
      %{ref: app} = plugin("ehos-app")
      %{ref: contract} = plugin("eh-os-contract")
      igniter = installed()
      written = content(igniter, ".claude/settings.json")

      # The hook's command is long; its parts are the next test's.
      [plugins, gate] = String.split(written, "\n  \"hooks\": ", parts: 2)

      assert JSON.decode!(~s({"hooks": ) <> gate)["hooks"] == %{
               "PreToolUse" => [
                 %{
                   "matcher" => "Bash",
                   "hooks" => [Install.review_gate_hook() |> Jason.encode!() |> JSON.decode!()]
                 }
               ]
             }

      assert plugins <> "\n" == """
             {
               "extraKnownMarketplaces": {
                 "ehos-app": {
                   "source": {
                     "source": "github",
                     "repo": "EmpoweredHouse/ehos-tools",
                     "ref": "#{app}",
                     "path": ".claude-plugin/ehos-app.json"
                   }
                 },
                 "eh-os-contract": {
                   "source": {
                     "source": "github",
                     "repo": "EmpoweredHouse/eh-os-contract",
                     "ref": "#{contract}"
                   }
                 }
               },
               "enabledPlugins": {
                 "ehos-app@ehos-app": true,
                 "eh-os-contract@eh-os-contract": true
               },
             """

      refute Enum.any?(Map.keys(igniter.assigns.test_files), &String.starts_with?(&1, ".agents/"))
    end

    # The gate's own behaviour is EhosApp.Review's, tested there; this is the hook that runs it.
    test "runs the review gate before gh opens a pull request, refusing whenever it cannot run" do
      %{"command" => command, "timeout" => timeout} =
        Install.review_gate_hook() |> Jason.encode!() |> JSON.decode!()

      assert command =~ ~s(case "$input" in *gh*pr*create*|*gh*pr*new*\) ;; *\) exit 0 ;; esac)

      assert command =~
               ~s(cd "$CLAUDE_PROJECT_DIR" && printf '%s' "$input" | MIX_ENV=dev mix ehos_app.review gate)

      # Exit status 2 is the gate's refusal; any other failure refuses as well.
      assert command =~ ~s(if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then exit "$rc"; fi)
      assert String.ends_with?(command, "exit 2")
      # Past it Claude Code runs the command, and a first gate compiles every dependency.
      assert timeout >= 600
    end

    test "adds the review gate beside the developer's own hooks, once" do
      settings = """
      {
        "hooks": {
          "PreToolUse": [
            {"matcher": "Edit", "hooks": [{"type": "command", "command": "mix format"}]}
          ],
          "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
        }
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      hooks = igniter |> content(".claude/settings.json") |> JSON.decode!() |> Map.fetch!("hooks")

      assert [%{"matcher" => "Edit"}, %{"matcher" => "Bash", "hooks" => [gate]}] =
               hooks["PreToolUse"]

      assert gate == Install.review_gate_hook() |> Jason.encode!() |> JSON.decode!()
      assert hooks["Stop"] == [%{"hooks" => [%{"type" => "command", "command" => "say done"}]}]

      igniter |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    # The section comes last and says nothing, so the review workflow fails a pull request
    # opened from the template until its author fills it in.
    test "ends the pull request template with a Review section the author has to fill in" do
      template = installed() |> content(".github/pull_request_template.md")

      assert template =~ ~r/\n## Review\n\n<!--[^#]*-->\n\z/
      assert {:error, message} = EhosApp.Review.pull_request_body(template)
      assert message =~ "section is empty"

      assert EhosApp.Review.pull_request_body(template <> "\nNothing found.\n") == :ok
    end

    test "replaces the pull request template an earlier version wrote, and leaves one the developer changed" do
      earlier = File.read!("test/fixtures/pull_request_template_0.14.0.md")
      path = ".github/pull_request_template.md"

      for version <- ["0.14.0", "0.21.0"] do
        upgraded =
          phx_test_project()
          |> with_file(path, File.read!("test/fixtures/pull_request_template_#{version}.md"))
          |> Igniter.compose_task("ehos_app.install", [])

        assert content(upgraded, path) == installed() |> content(path), "from #{version}"
      end

      edited =
        File.read!("test/fixtures/pull_request_template_0.21.0.md") <>
          "- [ ] Screenshots attached\n"

      assert phx_test_project()
             |> with_file(path, edited)
             |> Igniter.compose_task("ehos_app.install", [])
             |> content(path) == edited

      changed = earlier <> "- [ ] Screenshots attached\n"

      kept =
        phx_test_project()
        |> with_file(path, changed)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(kept, path) == changed

      assert Enum.any?(
               kept.notices,
               &(&1 =~ "#{path} is the project's own, and has no `## Review`")
             )
    end

    # The workflow reads a heading in a comment or in code as no section at all.
    test "reads the project's own pull request template as the review workflow reads a description" do
      path = ".github/pull_request_template.md"

      for {template, notice?} <- [
            {"## What\n\n<!--\n## Review\n-->\n", true},
            {"## What\n\n```md\n## Review\n```\n", true},
            {"## What\n\n## Review\n\n<!-- Fill this in. -->\n", false}
          ] do
        igniter =
          phx_test_project()
          |> with_file(path, template)
          |> Igniter.compose_task("ehos_app.install", [])

        assert Enum.any?(igniter.notices, &(&1 =~ "has no `## Review` section")) == notice?,
               template
      end
    end

    test "keeps a hook of the developer's that runs the review gate, without adding the template's" do
      settings = """
      {
        "hooks": {
          "PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "cd app && MIX_ENV=dev mix ehos_app.review gate"}]}
          ]
        }
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])

      hooks = igniter |> content(".claude/settings.json") |> JSON.decode!() |> Map.fetch!("hooks")

      assert [%{"hooks" => [%{"command" => "cd app && MIX_ENV=dev mix ehos_app.review gate"}]}] =
               hooks["PreToolUse"]
    end

    # The plugin is released by the tag the installer pins, so the two move together (T-15).
    test "pins the plugin by the tag of the version its plugin.json says" do
      %{name: name, ref: ref} = Install.plugin()

      version =
        "../../plugins/#{name}/.claude-plugin/plugin.json"
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("version")

      assert ref == "#{name}-v#{version}"
    end

    # Claude Code registers a marketplace under the name in its file, which has to be the key the
    # settings give it (T-16).
    test "names a marketplace file in ehos-tools that publishes the plugin under its marketplace's name" do
      %{name: name, marketplace: marketplace, path: path} = Install.plugin()
      manifest = "../../#{path}" |> File.read!() |> JSON.decode!()

      assert manifest["name"] == marketplace
      assert [%{"name" => ^name, "source" => source}] = manifest["plugins"]
      assert source == "./plugins/#{name}"
    end

    test "keeps the developer's settings in their order, and moves an earlier tag of the plugin" do
      settings = """
      {
        "permissions": {"allow": ["Bash(mix test:*)"]},
        "extraKnownMarketplaces": {
          "ehos-app": {
            "source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.0.1"}
          }
        }
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      written = content(igniter, ".claude/settings.json")
      decoded = JSON.decode!(written)

      assert written =~ ~r/\A\{\n  "permissions".*"extraKnownMarketplaces".*"enabledPlugins"/s
      assert decoded["permissions"] == %{"allow" => ["Bash(mix test:*)"]}

      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"] == %{
               "source" => "github",
               "repo" => "EmpoweredHouse/ehos-tools",
               "ref" => Install.plugin().ref,
               "path" => ".claude-plugin/ehos-app.json"
             }

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => true,
               "eh-os-contract@eh-os-contract" => true
             }

      igniter |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    # 0.9 named the plugin's marketplace ehos-tools, which EHOS's own repositories pin at another
    # tag (T-16).
    test "renames the marketplace 0.9 named ehos-tools to ehos-app, in its place" do
      written_by_09 =
        installed()
        |> content(".claude/settings.json")
        |> String.replace(~s|"ehos-app": {|, ~s|"ehos-tools": {|)
        |> String.replace(Install.plugin().ref, "ehos-app-v0.1.0")
        |> String.replace(~s|,\n        "path": ".claude-plugin/ehos-app.json"|, "")
        |> String.replace("ehos-app@ehos-app", "ehos-app@ehos-tools")

      assert written_by_09 =~ ~s|"ehos-tools": {|
      refute written_by_09 =~ "path"

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", written_by_09)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, ".claude/settings.json") ==
               installed() |> content(".claude/settings.json")

      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "keeps an ehos-tools marketplace of the developer's, and a plugin turned off there" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-dev-v0.4.0"}}
        },
        "enabledPlugins": {"ehos-dev@ehos-tools": true, "ehos-app@ehos-tools": false}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert decoded["extraKnownMarketplaces"]["ehos-tools"]["source"]["ref"] == "ehos-dev-v0.4.0"

      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["ref"] ==
               Install.plugin().ref

      assert decoded["enabledPlugins"] == %{
               "ehos-dev@ehos-tools" => true,
               "ehos-app@ehos-tools" => false,
               "ehos-app@ehos-app" => false,
               "eh-os-contract@eh-os-contract" => true
             }
    end

    test "turns the plugin off from ehos-app where the developer enables it from an ehos-tools of their own" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "MyOrg/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": true}
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])

      decoded = igniter |> content(".claude/settings.json") |> JSON.decode!()

      assert decoded["extraKnownMarketplaces"]["ehos-tools"]["source"]["repo"] ==
               "MyOrg/ehos-tools"

      assert decoded["enabledPlugins"]["ehos-app@ehos-tools"] == true
      assert decoded["enabledPlugins"]["ehos-app@ehos-app"] == false

      assert_has_notice(
        igniter,
        &(&1 =~ "MyOrg/ehos-tools" and &1 =~ "turn ehos-app@ehos-app on")
      )
    end

    test "keeps the marketplace 0.9 named ehos-tools for another plugin enabled from it" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": true, "ehos-dev@ehos-tools": true}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert decoded["extraKnownMarketplaces"]["ehos-tools"]["source"]["ref"] == "ehos-app-v0.1.0"

      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["ref"] ==
               Install.plugin().ref

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => true,
               "ehos-dev@ehos-tools" => true,
               "eh-os-contract@eh-os-contract" => true
             }
    end

    test "keeps a path the developer gave the ehos-app marketplace" do
      settings =
        ~s|{"extraKnownMarketplaces": {"ehos-app": {"source": {"source": "github", | <>
          ~s|"repo": "EmpoweredHouse/ehos-tools", "ref": "#{Install.plugin().ref}", | <>
          ~s|"path": ".claude-plugin/marketplace.json"}}}}\n|

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["path"] ==
               ".claude-plugin/marketplace.json"
    end

    test "drops the plugin's entry under ehos-tools where one under ehos-app is already there" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": false, "ehos-app@ehos-app": false}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert Map.keys(decoded["extraKnownMarketplaces"]) |> Enum.sort() == [
               "eh-os-contract",
               "ehos-app"
             ]

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => false,
               "eh-os-contract@eh-os-contract" => true
             }
    end

    test "renames the marketplace 0.9 named ehos-tools where a plugin turned off is the other one there" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": true, "ehos-dev@ehos-tools": false}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      refute Map.has_key?(decoded["extraKnownMarketplaces"], "ehos-tools")
      assert decoded["enabledPlugins"]["ehos-app@ehos-app"] == true
    end

    test "removes the marketplace 0.9 named ehos-tools where the template's ehos-app is there too" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}},
          "ehos-app": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "#{Install.plugin().ref}", "path": ".claude-plugin/ehos-app.json"}}
        }
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert Map.keys(decoded["extraKnownMarketplaces"]) |> Enum.sort() == [
               "eh-os-contract",
               "ehos-app"
             ]

      assert decoded["enabledPlugins"]["ehos-app@ehos-app"] == true
    end

    test "keeps the plugin on where it was on under ehos-tools and off under ehos-app" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-app-v0.1.0"}}
        },
        "enabledPlugins": {"ehos-app@ehos-tools": true, "ehos-app@ehos-app": false}
      }
      """

      decoded =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> content(".claude/settings.json")
        |> JSON.decode!()

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => true,
               "eh-os-contract@eh-os-contract" => true
             }
    end

    test "writes the developer's settings with their own indent and line ends" do
      settings = "{\r\n\t\"permissions\": {\r\n\t\t\"allow\": []\r\n\t}\r\n}\r\n"

      written =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content(".claude/settings.json")

      assert written =~
               ~r/\A\{\r\n\t"permissions": \{\r\n\t\t"allow": \[\]\r\n\t\},\r\n\t"extraKnownMarketplaces": \{\r\n\t\t"ehos-app"/

      refute written =~ ~r/[^\r]\n/
      assert String.ends_with?(written, "}\r\n")
    end

    test "leaves settings that already enable every plugin as they are, however they are laid out" do
      igniter = installed()

      compact =
        igniter
        |> content(".claude/settings.json")
        |> Jason.decode!(objects: :ordered_objects)
        |> Jason.encode!()

      again =
        igniter
        |> replace_file(".claude/settings.json", compact)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(again, ".claude/settings.json") == compact
    end

    # 0.9.0's settings name eh-os-contract's plugin at a tag a later version moves.
    test "moves an earlier tag of eh-os-contract's plugin, and keeps a later one" do
      for {ref, moved?} <- [
            {"eh-os-contract-plugin-v0.0.1", true},
            {"eh-os-contract-plugin-v99.0.0", false}
          ] do
        settings =
          ~s|{"extraKnownMarketplaces": {"eh-os-contract": {"source": | <>
            ~s|{"source": "github", "repo": "EmpoweredHouse/eh-os-contract", "ref": "#{ref}"}}}}\n|

        igniter =
          phx_test_project()
          |> with_file(".claude/settings.json", settings)
          |> Igniter.compose_task("ehos_app.install", [])

        decoded = igniter |> content(".claude/settings.json") |> JSON.decode!()
        kept? = Enum.any?(igniter.notices, &(&1 =~ "the marketplace eh-os-contract as"))
        assert kept? == not moved?

        %{ref: pinned} = plugin("eh-os-contract")
        expected = if moved?, do: pinned, else: ref
        assert decoded["extraKnownMarketplaces"]["eh-os-contract"]["source"]["ref"] == expected
      end
    end

    test "keeps a marketplace pinned to another ref, and a plugin the developer turned off" do
      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-app": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "main"}}
        },
        "enabledPlugins": {"ehos-app@ehos-app": false}
      }
      """

      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", settings)
        |> Igniter.compose_task("ehos_app.install", [])

      decoded = igniter |> content(".claude/settings.json") |> JSON.decode!()
      assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["ref"] == "main"

      assert decoded["enabledPlugins"] == %{
               "ehos-app@ehos-app" => false,
               "eh-os-contract@eh-os-contract" => true
             }

      assert Enum.any?(igniter.notices, &(&1 =~ "EmpoweredHouse/ehos-tools at main"))
    end

    test "keeps a later release of the plugin, and a marketplace on another repository" do
      for {repo, ref} <- [
            {"EmpoweredHouse/ehos-tools", "ehos-app-v99.0.0"},
            {"someone/ehos-tools", "ehos-app-v0.0.1"}
          ] do
        settings =
          ~s|{"extraKnownMarketplaces": {"ehos-app": {"source": | <>
            ~s|{"source": "github", "repo": "#{repo}", "ref": "#{ref}"}}}}\n|

        igniter =
          phx_test_project()
          |> with_file(".claude/settings.json", settings)
          |> Igniter.compose_task("ehos_app.install", [])

        decoded = igniter |> content(".claude/settings.json") |> JSON.decode!()
        assert decoded["extraKnownMarketplaces"]["ehos-app"]["source"]["ref"] == ref
        assert Enum.any?(igniter.notices, &(&1 =~ "so the\ninstaller kept it"))
      end
    end

    test "leaves settings of another shape alone, and says what to add" do
      for settings <- [
            ~s|{"extraKnownMarketplaces": false}\n|,
            ~s|{"extraKnownMarketplaces": {"ehos-app": {"source": {"ref": {"tag": "x"}}}}}\n|,
            ~s|{"extraKnownMarketplaces": []}\n|,
            ~s|{"extraKnownMarketplaces": {"ehos-app": "x"}}\n|,
            ~s|{"enabledPlugins": true}\n|,
            ~s|{"extraKnownMarketplaces": {"eh-os-contract": {"source": {"ref": 1}}}}\n|,
            ~s|{"hooks": []}\n|,
            ~s|{"hooks": {"PreToolUse": {}}}\n|,
            ~s|{"hooks": {"PreToolUse": ["x"]}}\n|
          ] do
        igniter =
          phx_test_project()
          |> with_file(".claude/settings.json", settings)
          |> Igniter.compose_task("ehos_app.install", [])

        assert content(igniter, ".claude/settings.json") == settings
        assert Enum.any?(igniter.warnings, &(&1 =~ ~s|"ehos-app@ehos-app": true|))
      end
    end

    test "leaves settings that are not a JSON object alone, and says what to add" do
      igniter =
        phx_test_project()
        |> with_file(".claude/settings.json", "[]\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, ".claude/settings.json") == "[]\n"
      assert Enum.any?(igniter.warnings, &(&1 =~ ~s|"ehos-app@ehos-app": true|))
    end

    # 0.3.0 to 0.8.1 copied the skills into .agents/skills and linked them from .claude/skills.
    test "removes the skills an earlier version copied, unless changed, and unlinks them" do
      fixtures = "test/fixtures/skills_0.8.1"

      project =
        fixtures
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&String.ends_with?(&1, "/plan/SKILL.md"))
        |> Enum.reduce(phx_test_project(), fn file, igniter ->
          path = Path.join(".agents/skills", Path.relative_to(file, fixtures))
          with_file(igniter, path, File.read!(file))
        end)
        |> with_file(".agents/skills/plan/SKILL.md", "# Our plan\n")
        |> with_file(".agents/skills/ship/notes.md", "# Ours\n")

      igniter = Igniter.compose_task(project, "ehos_app.install", [])

      for file <- [
            "ship/SKILL.md",
            "review/references/checklist.md",
            "elixir-anti-patterns-review/LICENSE"
          ],
          do: assert(".agents/skills/#{file}" in igniter.rms)

      refute ".agents/skills/plan/SKILL.md" in igniter.rms
      refute ".agents/skills/ship/notes.md" in igniter.rms
      assert {"ehos_app.unlink_skills", []} in igniter.tasks
      assert Enum.any?(igniter.notices, &(&1 =~ "* .agents/skills/plan/SKILL.md"))

      again = igniter |> apply_igniter!() |> Igniter.compose_task("ehos_app.install", [])
      refute {"ehos_app.unlink_skills", []} in again.tasks
    end

    # The LICENSE was released with no newline at its end; a project has it with one.
    test "removes the skill's LICENSE as a project has it, with a newline at its end" do
      license = File.read!("test/fixtures/skills_0.8.1/elixir-anti-patterns-review/LICENSE")
      refute String.ends_with?(license, "\n")

      igniter =
        phx_test_project()
        |> with_file(".agents/skills/elixir-anti-patterns-review/LICENSE", license <> "\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert ".agents/skills/elixir-anti-patterns-review/LICENSE" in igniter.rms
    end

    test "writes an Apache-2.0 LICENSE in the company's name, and keeps one of the project's own" do
      igniter = install()
      license = content(igniter, "LICENSE")

      assert license =~ ~r/\A\s+Apache License\n\s+Version 2\.0, January 2004\n/
      assert license =~ "Copyright #{Date.utc_today().year} Empowered House PSA\n"
      assert Enum.any?(igniter.notices, &(&1 =~ "LICENSE is the Apache License 2.0"))
      assert content(igniter, "README.md") =~ "See [LICENSE](LICENSE)."

      own = with_file("LICENSE", "MIT\n") |> Igniter.compose_task("ehos_app.install", [])
      assert content(own, "LICENSE") == "MIT\n"
      refute Enum.any?(own.notices, &(&1 =~ "LICENSE is the Apache License 2.0"))
    end

    test "licenses no project an earlier version generated without a LICENSE" do
      igniter =
        with_file("ehos.yaml", "schema: ehos.yaml/v2\n")
        |> Igniter.compose_task("ehos_app.install", [])

      refute Igniter.exists?(igniter, "LICENSE")
      refute content(igniter, "README.md") =~ "LICENSE"
    end

    test "ignores .plans/, once" do
      igniter =
        with_file(".gitignore", "/_build/\n")
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, ".gitignore") =~
               ~r/\A\/_build\/\n\n# Working plans.*\n\/\.plans\/\n\z/
    end

    test "names the design system in managed sections alone" do
      igniter = installed(["--example"])

      paths =
        Enum.map(@managed, &elem(&1, 0)) ++
          ["ARCHITECTURE.md", "TESTING.md", ".github/pull_request_template.md"]

      named =
        for path <- paths,
            content = content(igniter, path),
            unmanaged =
              Enum.reduce(@managed, content, &String.replace(&2, section(elem(&1, 1)), "")),
            content =~ Install.design_system(),
            do: {path, unmanaged =~ Install.design_system()}

      assert {"AGENTS.md", false} in named
      assert {"lib/test_web/AGENTS.md", false} in named
      assert Enum.all?(named, &(elem(&1, 1) == false))
    end

    test "writes docs whose relative links resolve in the project" do
      igniter = installed(["--example"])
      files = Map.keys(igniter.assigns.test_files)

      dangling =
        for doc <- files,
            String.ends_with?(doc, ".md"),
            [_, target] <- Regex.scan(~r/\]\(([^)\s]+)\)/, content(igniter, doc)),
            not String.match?(target, ~r/\A(https?|mailto):|\A#/),
            path = target |> String.split("#") |> hd() |> Path.expand("/" <> Path.dirname(doc)),
            path = String.trim_leading(path, "/"),
            not Enum.any?(files, &(&1 == path or String.starts_with?(&1, path <> "/"))),
            do: "#{doc} -> #{target}"

      assert dangling == []
    end

    test "keeps each guide within the budget the harness test holds it to" do
      igniter = installed(["--example"])

      for {path, _} <- @managed do
        lines = igniter |> content(path) |> String.split("\n") |> length()
        budget = Map.get(@budgets, path, 200)
        assert lines <= budget, "#{path}: #{lines} lines (budget #{budget})"
      end
    end
  end
end

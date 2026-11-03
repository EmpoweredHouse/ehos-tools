defmodule Mix.Tasks.EhosApp.InstallTest.AgentHarness do
  use Mix.Tasks.EhosApp.InstallCase, async: true

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
    "docs/platform-issues.md",
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

  # The row of AGENTS.md's "Where to read" for the web layer, without Phoenix's rules and with.
  @web_row "| The web layer | [lib/test_web/AGENTS.md](lib/test_web/AGENTS.md) |"
  @web_row_with_phoenix "| The web layer | [lib/test_web/AGENTS.md](lib/test_web/AGENTS.md), " <>
                          "and Phoenix's rules in [docs/phoenix.md](docs/phoenix.md) |"

  @pull_request_template ".github/pull_request_template.md"

  @phoenix_rules_notice """
  AGENTS.md still holds the rules Phoenix wrote into it, below the EHOS section, and
  test/harness_test.exs holds AGENTS.md to 200 lines. Move them, from "This is a web
  application written using the Phoenix web framework." to <!-- usage-rules-end -->, into
  docs/phoenix.md, then run the installer again: lib/test_web/AGENTS.md will point there,
  and an AGENTS.md left with the EHOS section alone gets the application's part below it.
  """

  @elixir_doc_notice """
  docs/elixir.md says how this application's Elixir and tests are written, and AGENTS.md's
  section asks for it before writing any. Add it to AGENTS.md's "Where to read", below
  the section:

      | Writing Elixir and its tests | [docs/elixir.md](docs/elixir.md) |
  """

  @platform_issues_notice """
  docs/platform-issues.md lists what this application asked of the platform, and AGENTS.md's
  section has /ehos-app:retro keep it. Add it to AGENTS.md's "Where to read", below the
  section:

      | What this application asked of the platform, and what changes here once it is fixed | [docs/platform-issues.md](docs/platform-issues.md) |
  """

  @architecture_notice """
  ARCHITECTURE.md has a section of the template's on top now, between the markers
  <!-- ehos_app:architecture --> and <!-- /ehos_app:architecture -->, which an upgrade rewrites.
  The parts below it that an earlier version wrote say the same, or what is no longer so
  (a copy of the schema in .ehos/, skills in .agents/skills/), and can be deleted: keep
  only what is this application's own. AGENTS.md's part below its section may name those
  two as well.
  """

  @review_notice """
  .github/pull_request_template.md is the project's own, and has no `## Review` section. The review workflow,
  .github/workflows/review.yml, fails a pull request whose description has none, so add
  one at its end, after every other section:

  ## Review

  <!-- What /ehos-app:pre-pr-review found, in each of its reviews, with the skills each
  invoked, and what became of each finding. Or that the change is documentation alone. -->
  """

  @license_notice """
  LICENSE is the Apache License 2.0, in the name of Empowered House PSA. If the application
  belongs to someone else, or is to be licensed otherwise, change it before the first push.
  """

  # A new project, with the installer's notices before they are applied and its files after,
  # and one with the example.
  setup_all do
    install = install()
    %{install: install, new_project: apply_igniter!(install), example: installed(["--example"])}
  end

  describe "the agent harness" do
    test "moves Phoenix's AGENTS.md to docs/phoenix.md, as Phoenix wrote it, and writes a lean one",
         %{new_project: new_project} do
      igniter = project_with("AGENTS.md", @phoenix_agents) |> run_installer()

      assert content(igniter, "docs/phoenix.md") == @phoenix_agents

      assert content(igniter, "AGENTS.md") ==
               new_project
               |> content("AGENTS.md")
               |> String.replace(@web_row, @web_row_with_phoenix)

      assert item(content(igniter, "lib/test_web/AGENTS.md"), "**Phoenix's rules**") == """
             - **Phoenix's rules** for the version this project was generated with are in
               [docs/phoenix.md](../../docs/phoenix.md). Read them before changing a template, a component, a
               LiveView or a route.\
             """
    end

    test "puts the EHOS section on top of an AGENTS.md of the project's own",
         %{new_project: new_project} do
      igniter = project_with("AGENTS.md", "# Our rules\n") |> run_installer()

      assert content(igniter, "AGENTS.md") ==
               section_of(content(new_project, "AGENTS.md"), "agents") <> "\n# Our rules\n"

      refute Igniter.exists?(igniter, "docs/phoenix.md")

      assert content(igniter, "lib/test_web/AGENTS.md") ==
               content(new_project, "lib/test_web/AGENTS.md")
    end

    test "replaces the EHOS section an earlier version wrote, and keeps the rest",
         %{new_project: new_project} do
      igniter =
        project_with(
          "AGENTS.md",
          "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n\n# Phoenix rules\n"
        )
        |> run_installer()

      assert content(igniter, "AGENTS.md") ==
               section_of(content(new_project, "AGENTS.md"), "agents") <> "\n# Phoenix rules\n"
    end

    test "gives an AGENTS.md that holds the EHOS section alone, as 0.2 wrote it, the application's part",
         %{new_project: new_project} do
      agents = "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n"
      igniter = project_with("AGENTS.md", agents) |> run_installer()

      assert content(igniter, "AGENTS.md") == content(new_project, "AGENTS.md")
    end

    # Where a behaviour has several cases, as here, each case is a test of its own, so each
    # runs the installer within ExUnit's timeout for a test.
    for {how, line_end} <- [
          {"", "\n"},
          {", with a space and CRLF ending each line", " \r\n"},
          {", with a tab ending each line", "\t\n"}
        ] do
      test "replaces the README Phoenix generates#{how}", %{new_project: new_project} do
        phoenix = String.replace(phoenix_readme(), "\n", unquote(line_end))
        readme = project_with("README.md", phoenix) |> run_installer()

        assert content(readme, "README.md") == content(new_project, "README.md")
      end
    end

    test "keeps a README of the project's own below the template's section",
         %{new_project: new_project} do
      own = project_with("README.md", "# Ours\n") |> run_installer()

      assert content(own, "README.md") ==
               section_of(content(new_project, "README.md"), "readme") <> "\n# Ours\n"
    end

    test "writes every seed, and never overwrites one", %{new_project: new_project} do
      assert Enum.filter(@seeds, &Igniter.exists?(new_project, &1)) == @seeds

      mine =
        @seeds
        |> Enum.reduce(phx_test_project(), &developers_file(&2, &1, "# mine\n"))
        |> apply_igniter!()
        |> run_installer()

      assert Map.new(@seeds, &{&1, content(mine, &1)}) == Map.new(@seeds, &{&1, "# mine\n"})
    end

    test "keeps a section in each managed file, on top of what the developer wrote",
         %{new_project: new_project} do
      igniter =
        @managed
        |> Enum.reduce(phx_test_project(), fn {path, _}, igniter ->
          developers_file(igniter, path, "# mine\n")
        end)
        |> apply_igniter!()
        |> run_installer()

      assert Map.new(@managed, fn {path, _} -> {path, content(igniter, path)} end) ==
               Map.new(@managed, fn {path, name} ->
                 {path, section_of(content(new_project, path), name) <> "\n# mine\n"}
               end)
    end

    # ehos-tools#504: the rules for code that is not a contract's part, in a doc of the template's
    # and as rules in the section every agent reads first.
    test "says how Elixir is written, in docs/elixir.md and as rules in AGENTS.md",
         %{example: example, new_project: new_project} do
      elixir = content(example, "docs/elixir.md")
      agents = content(example, "AGENTS.md")
      section = section_of(agents, "agents")

      assert headings(elixir) == [
               "# How Elixir is written",
               "## Behaviours",
               "## Data",
               "## Pages and controllers",
               "## Control flow and style",
               "## Tests",
               "## This application's rules"
             ]

      # The example's decider shows a contract's part needs no behaviour of its own.
      assert lines_with(elixir, "entries/entry.ex") == [
               "  `lib/test/entries/entry.ex` implements the example's, and its test is the contract's"
             ]

      assert lines_with(content(new_project, "docs/elixir.md"), "entries/entry.ex") == []

      # Where the platform documents itself moved to ARCHITECTURE.md, to keep AGENTS.md short.
      assert headings(section) == [
               "# EHOS application",
               "## Essentials",
               "## Before you change anything",
               "## How a change is made: contract first",
               "## EHOS's rules come first",
               "## Safety",
               "## How Elixir is written",
               "## Execution discipline",
               "## Docs rules",
               "## The gate and pull requests",
               "## The platform is ours"
             ]

      assert subsection(section, "## How Elixir is written") == """
             ## How Elixir is written

             Load `/ehos-app:elixir` and read [docs/elixir.md](docs/elixir.md) before writing Elixir or a test.
             In short: a collaborator a test replaces is a behaviour, mocked with Hammox, and a contract's part
             gets none; a page or controller makes one context call and renders
             (`lib/test_web/AGENTS.md`); no `case` or `with` inside another.
             """

      assert subsection(section, "## Safety") == """
             ## Safety

             What a mistake here costs someone outside this repository.

             - **A deployed contract is production.** Other applications read its publications, and its log
               holds every event it recorded: never rename or remove an event or a field without saying what
               it does to stored events, and change a publication only as a new version.
             - **Every command arrives with a credential EHOS issued.** `EhOsContract.Auth.Plug` verifies it in
               front of `EhOsContract.Plug`, and a page issues a command with `EhOsContract.call/3` and the
               actor `EhOsContract.Auth.Session.actor/2` gives; never add a way to a command that skips both.
             - **No secret in the code, `ehos.yaml`, a log or a chat.** EHOS gives the application its secrets
               as variables, which `config/runtime.exs` reads. Log ids and kinds, never content: an event's or
               a request's id, never its payload, a person's details or a parameter's value
               (`LogRedaction` keeps a crashed process's state out of its report).
             - **Never read another application's data.** A fact another application needs leaves this one as
               an event a contract publishes.
             - **No DDL while the application runs, and no hand on an environment's data.** Only the
               migrations, run before the new release starts, change a table, so a column is dropped in two
               deploys; data changes through a command or a migration, never a console.
             """

      assert subsection(section, "## Essentials") =~ "`mix precommit`"

      # The rules T-20 added to the ways out: what gets no behaviour, and the environment.
      assert item(elixir, "**None for a contract's part**") =~
               "**None for an Oban worker**: it calls each collaborator through the collaborator's\n  `current()`"

      assert item(elixir, "**The clock, randomness, generated ids and the process environment") =~
               "through `Test.Env`, a behaviour of the application's own"

      assert item(content(example, "lib/test_web/AGENTS.md"), "**What goes over the wire") ==
               """
               - **What goes over the wire is shaped by the `*JSON` or `*HTML` module**: a JSON answer's field
                 names, a date as ISO 8601, a URL. The controller hands `render/3` what the context answered, as
                 it is.\
               """

      assert subsection(section, "## Execution discipline") == """
             ## Execution discipline

             - **Beyond a small fix, a plan in phases** before any code (`/ehos-app:plan`, in gitignored
               `.plans/`, never committed), and a stop after each phase for the user's go or no-go.
             - **A commit after every finished step**, each green under `mix precommit`, each small enough to
               review on its own.
             - **Before changing an established pattern, read the `git log` of the files it lives in.** The
               design is often deliberate, and the commits say why.
             """

      assert lines_with(agents, "| Writing Elixir") == [
               "| Writing Elixir and its tests | [docs/elixir.md](docs/elixir.md) |"
             ]

      assert lines_with(content(example, "ARCHITECTURE.md"), "## Where the platform") == [
               "## Where the platform documents itself"
             ]

      assert item(content(example, "lib/test_web/AGENTS.md"), "**A LiveView or a controller") ==
               """
               - **A LiveView or a controller orchestrates**: params in, one context call, render. It neither
                 composes domain calls nor reshapes domain data for its template; each of those is a context
                 function, or a function component's job. Its test runs the real context, or mocks the function
                 it calls, and goes through the real sign-in.\
               """

      testing = content(example, "TESTING.md")

      assert headings(testing) == [
               "# Testing",
               "## Running",
               "## Dependency advisories",
               "## The loop",
               "## Testing a contract",
               "## Tests the template wrote",
               "## Doubles",
               "## Rules",
               "## This application's tests"
             ]

      assert item(testing, "**A mock per behaviour**") == """
             - **A mock per behaviour**, declared with `Hammox.defmock/2` in `test/support/mocks.ex` and named in
               `config/test.exs`. Hammox checks each `expect` and `stub` against the behaviour's types; a
               default from `stub_with/2` is not checked.
               `Test.ClockMock` is one, and `test/test/clock_test.exs` holds the real clock to its
               behaviour with `Hammox.Protect`. A test
               never swaps an implementation with `Application.put_env/3` or `System.put_env/2`, and is never
               made non-async for it.\
             """

      refute testing =~ "`async` test never changes `Application` env"
    end

    # ehos-tools#706: what gets in the way is fixed where the platform is, and listed where the
    # application keeps it, which an upgrade never rewrites.
    test "says the platform is ours, and lists what the application asked of it",
         %{new_project: new_project} do
      agents = content(new_project, "AGENTS.md")

      section = section_of(agents, "agents")

      assert lines_with(section, "/ehos-app:retro") == [
               "way, fix it at its source, and have any workaround here name its issue, which `/ehos-app:retro`"
             ]

      # A workaround the platform's defect needs is allowed, named by its issue, not forbidden.
      assert lines_with(section, "workaround") == [
               "way, fix it at its source, and have any workaround here name its issue, which `/ehos-app:retro`"
             ]

      # The rule on plans, merged into one line to keep the section's length, says they are history.
      assert lines_with(section, "shipped plan") == [
               "- A change in behaviour, or a shipped plan (history), updates the area's topic doc in its PR."
             ]

      assert lines_with(agents, "docs/platform-issues.md") == [
               "drafts after a pull request and lists in [docs/platform-issues.md](docs/platform-issues.md).",
               "| What this application asked of the platform, and what changes here once it is fixed | " <>
                 "[docs/platform-issues.md](docs/platform-issues.md) |"
             ]

      assert lines_with(content(new_project, "DEVELOPMENT.md"), "/ehos-app:retro") == [
               "| 5 | after the pull request, or a workaround | `/ehos-app:retro` |",
               "workflow checks that section. After the pull request, `/ehos-app:retro` files what got in the way"
             ]

      assert content(new_project, "docs/platform-issues.md") == """
             # Platform issues

             What this application asked of the platform it runs on (`AGENTS.md`, "The platform is ours"), and
             what changes here once each is fixed. `/ehos-app:retro` keeps it. It holds what an issue means
             here, not its state: `gh issue view <link>` says that.

             A row that ends with one of this repository's pull requests, in italics, names a workaround that
             pull request brings: true once it merges.

             ## Open

             | Issue | What is wrong | What changes here when it is fixed |
             | --- | --- | --- |

             ## Done

             | Issue | What changed here |
             | --- | --- |
             """
    end

    test "explains EHOS at the top of VISION.md, and points to it from the README",
         %{new_project: new_project} do
      vision = content(new_project, "VISION.md")

      assert headings(vision) == [
               "# Test",
               "## Where this application sits",
               "## The process it owns",
               "## Who it is for",
               "## Principles",
               "## What it will not do",
               "## Where it is heading"
             ]

      assert lines_with(vision, "The principles it inherits") == [
               "The principles it inherits, from"
             ]

      assert lines_with(content(new_project, "README.md"), "[VISION.md](VISION.md) says") == [
               "taken through it is authorised and recorded. [VISION.md](VISION.md) says what that means for this"
             ]
    end

    test "says how a change is made, contract first, and how it is run, built and deployed",
         %{new_project: new_project} do
      development = content(new_project, "DEVELOPMENT.md")

      assert headings(development) == [
               "# Development",
               "## The cycle: contract first",
               "### 1. Find what the change does to the contract",
               "### 2. Change the contract",
               "### 3. Check the contract before writing code",
               "### 4. Implement",
               "### 5. Gate and pull request",
               "## Running it locally",
               "## Building",
               "## Previews of pull requests",
               "### Data to try a preview on",
               "## Deploying",
               "## Who deploys, and joining the team",
               "## Keeping it current",
               "## This application's notes"
             ]

      # A developer who deploys is given a role for this application alone, never the operator's
      # keys.
      assert code_blocks(subsection(development, "## Who deploys, and joining the team")) == [
               """
                  ehosctl role-bindings bind ehos.application_administrator --to <email> --app test --installation <installation>
                  ehosctl role-bindings bind test.<actor> --to <email> --app test --env production --installation <installation>
               """,
               """
                  ehosctl role-bindings bind ehos.process_owner --to <email> --app test --installation <installation>
                  ehosctl role-bindings bind ehos.registrar --to <email> --app test --env production --installation <installation>
               """
             ]

      # A candidate in an ephemeral environment, promoted by the process owner: EHOS refuses a
      # deployment straight to production since 0.9.0 (eh-os D-105). By hand, a candidate is the
      # newest build of `main`.
      assert code_blocks(subsection(development, "## Deploying")) == [
               """
               ehosctl login https://<installation>        # once per installation; opens the browser
               rm -rf _build/deploy
               gh run download <run> -n ehos-deployment -D _build/deploy
               ehosctl apps register _build/deploy/ehos.bundle/ehos.manifest.json   # the first time
               ehosctl env create test-try --app test   # once, while it lives
               ehosctl deploy test --env test-try --manifest _build/deploy/ehos.bundle/ehos.manifest.json --preview
               ehosctl deploy test --env test-try --build latest --ref refs/heads/main
               """
             ]

      assert lines_with(development, "**Promote to production**") == [
               "**Promote to production**. The process owner, someone the administrator bound"
             ]

      refute development =~ "ehosctl deploy test --env production"

      # A first promotion puts the application's authority in force in production, so its approver
      # also registers it there (eh-os D-119).
      assert lines_with(development, "ehosctl role-bindings bind ehos.registrar") == [
               "`ehosctl role-bindings bind ehos.registrar --to <email> --app test --env production --installation <installation>`.",
               "   ehosctl role-bindings bind ehos.registrar --to <email> --app test --env production --installation <installation>"
             ]

      # `ehosctl deploy --preview` refuses an `--image`.
      refute development =~ ~r/--image[^\n]*--preview/

      # A preview's credential cannot register the application, and EHOS refuses to trust a
      # repository for one it does not know: a person registers it once, first. The trust a
      # repository starts with accepts pull requests alone (eh-os D-121); `main` is added only
      # once a ruleset protects it, which the trust cannot require (eh-os#1056).
      previews = subsection(development, "## Previews of pull requests")

      assert code_blocks(previews) == [
               """
               ehosctl login https://<installation>        # once per installation; opens the browser
               run=$(gh run list -w ci.yml -e push -b main -s success -L 1 --json databaseId -q '.[0].databaseId')
               rm -rf _build/deploy
               gh run download "$run" -n ehos-deployment -D _build/deploy
               ehosctl apps register _build/deploy/ehos.bundle/ehos.manifest.json
               ehosctl trust add --app test --repo <owner>/<repository> --ref 'refs/pull/*/merge'
               gh variable set EHOSCTL_URL --body https://<installation>
               gh variable set EHOSCTL_CA_PEM < <the installation's ca.crt>   # only if it has its own CA
               """
             ]

      refute previews =~ "--ref refs/heads/main"

      assert lines_with(previews, "first protect `main`") == [
               "first protect `main` with a ruleset that lets nothing onto it but a merged pull request and that no"
             ]

      # Every download goes where git ignores it, so `git add .` commits no manifest
      # (ehos-tools#295).
      assert lines_with(development, "-n ehos-deployment") == [
               ~s(gh run download "$run" -n ehos-deployment -D _build/deploy),
               "gh run download <run> -n ehos-deployment -D _build/deploy"
             ]

      refute development =~ ~r/[ (]deploy\/(ehos\.manifest\.json|image)/
      assert lines_with(content(new_project, ".gitignore"), "_build") == ["/_build/"]

      assert lines_with(development, "mix eh_os_contract.check") == [
               "mix eh_os_contract.check           # the whole-program rules, each finding named in rules.md",
               "test. `mix eh_os_contract.check` names what the contract declares and nothing implements yet: that"
             ]

      assert lines_with(content(new_project, "README.md"), "ehosctl verify") == [
               "| Check what CI checks, and have EHOS check `ehos.yaml` and the manifest | `ehosctl verify` |"
             ]
    end

    test "names the application in commands as EHOS does, with dashes" do
      igniter = phx_test_project(app_name: :my_shop) |> run_installer()

      assert lines_with(content(igniter, "DEVELOPMENT.md"), "ehosctl deploy my-shop") == [
               "ehosctl deploy my-shop --env my-shop-try --manifest _build/deploy/ehos.bundle/ehos.manifest.json --preview",
               "ehosctl deploy my-shop --env my-shop-try --build latest --ref refs/heads/main"
             ]

      assert lines_with(content(igniter, "README.md"), "ehosctl deploy my-shop") == [
               "| Deploy a build | `ehosctl deploy my-shop --env <env> --image <image> --manifest <file> [--graph <file>]…` |"
             ]
    end

    # Before 0.9.0, ARCHITECTURE.md and TESTING.md were written once and never again.
    test "puts its section on top of an ARCHITECTURE.md an earlier version wrote, and says so",
         %{install: install, new_project: new_project} do
      igniter = project_with("ARCHITECTURE.md", "# Architecture\n\nOurs.\n") |> run_installer()

      assert content(igniter, "ARCHITECTURE.md") ==
               section_of(content(new_project, "ARCHITECTURE.md"), "architecture") <>
                 "\n# Architecture\n\nOurs.\n"

      assert notices_with(igniter, "has a section of the template's") == [@architecture_notice]
      assert notices_with(install, "has a section of the template's") == []
    end

    for {path, name, version, example, newline} <- [
          {"ARCHITECTURE.md", "architecture", "0.3.0", false, "\n"},
          {"ARCHITECTURE.md", "architecture", "0.7.0", true, "\r\n"},
          {"TESTING.md", "testing", "0.3.0", true, "\n"},
          {"TESTING.md", "testing", "0.8.0", false, "\r\n"}
        ] do
      test "replaces #{path} still as #{version} wrote it " <>
             "#{if example, do: "with", else: "without"} --example, " <>
             "in #{if newline == "\r\n", do: "CRLF", else: "LF"}, with the seed",
           %{new_project: new_project} do
        earlier =
          unquote(name)
          |> earlier_seed(unquote(version), unquote(example))
          |> String.replace("\n", unquote(newline))

        igniter = project_with(unquote(path), earlier) |> run_installer()

        assert content(igniter, unquote(path)) == content(new_project, unquote(path))
        assert notices_with(igniter, "has a section of the template's") == []
      end
    end

    # 0.9 put its section on top of the file, untouched below it.
    test "replaces an ARCHITECTURE.md 0.9 put its section on top of, still as before below it",
         %{new_project: new_project} do
      upgraded_by_09 =
        section_of(content(new_project, "ARCHITECTURE.md"), "architecture") <>
          "\n" <> earlier_seed("architecture", "0.5.0", false)

      igniter = project_with("ARCHITECTURE.md", upgraded_by_09) |> run_installer()

      assert content(igniter, "ARCHITECTURE.md") == content(new_project, "ARCHITECTURE.md")
    end

    # 0.2 wrote the root AGENTS.md as its section alone, which a later run makes the seed again.
    test "keeps the seed's sentence on the example when it writes the seed again without --example",
         %{example: example, new_project: new_project} do
      agents = content(example, "AGENTS.md")

      again =
        example
        |> replace_file("AGENTS.md", section_of(agents, "agents"))
        |> apply_igniter!()
        |> run_installer()

      assert content(again, "AGENTS.md") == agents

      assert item(agents, "**A command**") == """
             - **A command** is declared in a contract, decided by its implementation, and dispatched by the
               engine, which appends what was decided to the event log. The example is
               `lib/test/contracts/entries.ex`, implemented by `lib/test/entries/entry.ex` and
               served under `/api`.\
             """

      assert item(content(new_project, "AGENTS.md"), "**A command**") == """
             - **A command** is declared in a contract, decided by its implementation, and dispatched by the
               engine, which appends what was decided to the event log.\
             """
    end

    test "writes the contract rules without --example too", %{new_project: new_project} do
      contracts = content(new_project, "lib/test/contracts/AGENTS.md")
      dir = Path.dirname(Install.contract_docs())

      assert lines_with(contracts, dir) == [
               "- `#{dir}/getting-started.md`: the whole loop, from a contract to a command",
               "- `#{dir}/contract.md`: how to write a domain and a contract;",
               "- `#{dir}/refusals.md`: what will not compile, each refusal by its code;",
               "- `#{dir}/rules.md`: what `mix eh_os_contract.check` reports, each finding by name;",
               "- `#{dir}/authorization.md`: how `by:` becomes the capabilities EHOS grants;",
               "- `#{dir}/dsl/contract-dsl.md` and `dsl/domain-dsl.md` beside it: every key of both"
             ]
    end

    test "points agents at the contract reference where the sparse dependency puts it",
         %{example: example} do
      docs = Install.contract_docs()
      assert docs == "deps/eh_os_contract/packages/eh_os_contract/docs/contract.md"

      paths = ["AGENTS.md", "README.md", "lib/test/domain.ex", "lib/test/contracts/entries.ex"]

      assert Map.new(paths, &{&1, lines_with(content(example, &1), docs)}) == %{
               "AGENTS.md" => [
                 "  one; the engine's reference is `#{docs}`. `emit` refuses anything a contract"
               ],
               "README.md" => [
                 "| [`eh_os_contract`](https://github.com/EmpoweredHouse/eh-os-contract) | " <>
                   "The contract engine: the domain and contract DSLs, dispatch, the event log | " <>
                   "`#{docs}`, and the rest of `docs/` beside it |"
               ],
               "lib/test/domain.ex" => [
                 "  and its roles `test.<actor>`. The vocabulary is in `#{docs}`."
               ],
               "lib/test/contracts/entries.ex" => [
                 "  `#{docs}`. A run of the business across contracts is a module of its own, `use"
               ]
             }
    end

    test "writes an Apache-2.0 LICENSE in the company's name, and keeps one of the project's own",
         %{install: install} do
      license = content(install, "LICENSE")

      assert license |> String.split("\n") |> Enum.take(2) == [
               "                                 Apache License",
               "                           Version 2.0, January 2004"
             ]

      assert lines_with(license, "Copyright #{Date.utc_today().year}") == [
               "   Copyright #{Date.utc_today().year} Empowered House PSA"
             ]

      assert notices_with(install, "LICENSE is the Apache License 2.0") == [@license_notice]
      assert lines_with(content(install, "README.md"), "LICENSE") == ["See [LICENSE](LICENSE)."]

      own = project_with("LICENSE", "MIT\n") |> run_installer()
      assert content(own, "LICENSE") == "MIT\n"
      assert notices_with(own, "LICENSE is the Apache License 2.0") == []
    end

    test "ignores .plans/, once" do
      igniter =
        project_with(".gitignore", "/_build/\n")
        |> run_installer()
        |> apply_igniter!()
        |> run_installer()

      assert content(igniter, ".gitignore") ==
               "/_build/\n\n# Working plans, which are history, not current truth.\n/.plans/\n"
    end

    test "names the design system in managed sections alone", %{example: example} do
      paths =
        Enum.map(@managed, &elem(&1, 0)) ++
          ["ARCHITECTURE.md", "TESTING.md", @pull_request_template]

      naming = Enum.filter(paths, &(content(example, &1) =~ Install.design_system()))

      outside_sections =
        Enum.filter(naming, &(unmanaged(content(example, &1)) =~ Install.design_system()))

      assert naming == ["AGENTS.md", "README.md", "lib/test_web/AGENTS.md"]
      assert outside_sections == []
    end

    test "writes docs whose relative links resolve in the project", %{example: example} do
      files = Map.keys(example.assigns.test_files)

      dangling =
        for doc <- files,
            String.ends_with?(doc, ".md"),
            [_, target] <- Regex.scan(~r/\]\(([^)\s]+)\)/, content(example, doc)),
            not String.match?(target, ~r/\A(https?|mailto):|\A#/),
            path = target |> String.split("#") |> hd() |> Path.expand("/" <> Path.dirname(doc)),
            path = String.trim_leading(path, "/"),
            not Enum.any?(files, &(&1 == path or String.starts_with?(&1, path <> "/"))),
            do: "#{doc} -> #{target}"

      assert dangling == []
    end

    test "keeps each guide within the budget the harness test holds it to", %{example: example} do
      over =
        for {path, _} <- @managed,
            lines = example |> content(path) |> String.split("\n") |> length(),
            budget = Map.get(@budgets, path, 200),
            lines > budget,
            do: "#{path}: #{lines} lines (budget #{budget})"

      assert over == []
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

      igniter = run_installer(project)

      assert Enum.sort(igniter.rms) == [
               ".agents/skills/elixir-anti-patterns-review/LICENSE",
               ".agents/skills/elixir-anti-patterns-review/SKILL.md",
               ".agents/skills/elixir-anti-patterns-review/references/code.md",
               ".agents/skills/elixir-anti-patterns-review/references/design.md",
               ".agents/skills/elixir-anti-patterns-review/references/macros.md",
               ".agents/skills/elixir-anti-patterns-review/references/process.md",
               ".agents/skills/review/SKILL.md",
               ".agents/skills/review/references/checklist.md",
               ".agents/skills/ship/SKILL.md"
             ]

      assert unlink_tasks(igniter) == [{"ehos_app.unlink_skills", []}]

      assert notices_with(igniter, "* .agents/skills/") == [
               """
               The skills are the ehos-app plugin's now, which .claude/settings.json enables:
               /ehos-app:plan, /ehos-app:ship, /ehos-app:review and
               /ehos-app:elixir-anti-patterns-review. The installer removed the copies an earlier
               version wrote, and kept these, which were changed since or are reached through a link
               to a directory other projects may share:

                 * .agents/skills/plan/SKILL.md

               Delete them to use the plugin's, or keep them as skills of the project's own.
               """
             ]

      again = igniter |> apply_igniter!() |> run_installer()
      assert unlink_tasks(again) == []
    end

    # The LICENSE was released with no newline at its end; a project has it with one.
    test "removes the skill's LICENSE as a project has it, with a newline at its end" do
      license = File.read!("test/fixtures/skills_0.8.1/elixir-anti-patterns-review/LICENSE")
      refute String.ends_with?(license, "\n")

      igniter =
        phx_test_project()
        |> with_file(".agents/skills/elixir-anti-patterns-review/LICENSE", license <> "\n")
        |> run_installer()

      assert igniter.rms == [".agents/skills/elixir-anti-patterns-review/LICENSE"]
    end

    test "enables the ehos-app and eh-os-contract plugins in .claude/settings.json, at their tags, and the review gate",
         %{new_project: new_project} do
      %{ref: app} = plugin("ehos-app")
      %{ref: contract} = plugin("eh-os-contract")
      written = content(new_project, ".claude/settings.json")

      # The hook's command is long; its parts are the next test's.
      [plugins, gate] = String.split(written, "\n  \"hooks\": ", parts: 2)

      assert JSON.decode!(~s({"hooks": ) <> gate)["hooks"] == review_hooks()

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

      assert Enum.filter(Map.keys(new_project.assigns.test_files), &(&1 =~ ~r/\A\.agents\//)) ==
               []
    end

    # The gate's own behaviour is EhosApp.Review's, tested there; this is the hook that runs it.
    # Exit status 2 is the gate's refusal; any other failure refuses as well. Past its timeout
    # Claude Code runs the command, and a first gate compiles every dependency.
    test "runs the review gate before gh opens a pull request, refusing whenever it cannot run" do
      assert gate_hook() == %{
               "type" => "command",
               "command" =>
                 "input=$(cat) || { echo 'The review gate could not read the hook input, " <>
                   "so the command is refused.' >&2; exit 2; }; " <>
                   ~s(case "$input" in *gh*pr*create*|*gh*pr*new*\) ;; *\) exit 0 ;; esac; ) <>
                   ~s(cd "$CLAUDE_PROJECT_DIR" && printf '%s' "$input" | ) <>
                   "MIX_ENV=dev mix ehos_app.review gate; rc=$?; " <>
                   ~s(if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then exit "$rc"; fi; ) <>
                   "echo 'The review gate (MIX_ENV=dev mix ehos_app.review gate) failed to run, " <>
                   "so the pull request is refused. Fix the error above and try again.' >&2; exit 2",
               "timeout" => 600,
               "statusMessage" => "Checking that this change was reviewed"
             }
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

      igniter = settings |> with_settings() |> apply_igniter!()

      assert settings(igniter)["hooks"] == %{
               "PreToolUse" => [
                 %{
                   "matcher" => "Edit",
                   "hooks" => [%{"type" => "command", "command" => "mix format"}]
                 },
                 %{"matcher" => "Bash", "hooks" => [gate_hook()]}
               ],
               "Stop" => [%{"hooks" => [%{"type" => "command", "command" => "say done"}]}]
             }

      igniter |> run_installer() |> assert_unchanged()
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

      assert Enum.map(manifest["plugins"], &Map.take(&1, ["name", "source"])) == [
               %{"name" => name, "source" => "./plugins/#{name}"}
             ]
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

      igniter = settings |> with_settings() |> apply_igniter!()
      written = content(igniter, ".claude/settings.json")

      assert written
             |> Jason.decode!(objects: :ordered_objects)
             |> Map.fetch!(:values)
             |> Enum.map(&elem(&1, 0)) ==
               ["permissions", "extraKnownMarketplaces", "enabledPlugins", "hooks"]

      assert JSON.decode!(written) == %{
               "permissions" => %{"allow" => ["Bash(mix test:*)"]},
               "extraKnownMarketplaces" => %{
                 "ehos-app" => app_marketplace(),
                 "eh-os-contract" => contract_marketplace()
               },
               "enabledPlugins" => %{
                 "ehos-app@ehos-app" => true,
                 "eh-os-contract@eh-os-contract" => true
               },
               "hooks" => review_hooks()
             }

      igniter |> run_installer() |> assert_unchanged()
    end

    # 0.9 named the plugin's marketplace ehos-tools, which EHOS's own repositories pin at another
    # tag (T-16).
    test "renames the marketplace 0.9 named ehos-tools to ehos-app, in its place",
         %{new_project: new_project} do
      new_settings = content(new_project, ".claude/settings.json")

      written_by_09 =
        new_settings
        |> String.replace(~s|"ehos-app": {|, ~s|"ehos-tools": {|)
        |> String.replace(Install.plugin().ref, "ehos-app-v0.1.0")
        |> String.replace(~s|,\n        "path": ".claude-plugin/ehos-app.json"|, "")
        |> String.replace("ehos-app@ehos-app", "ehos-app@ehos-tools")

      assert Map.take(JSON.decode!(written_by_09), ["extraKnownMarketplaces", "enabledPlugins"]) ==
               %{
                 "extraKnownMarketplaces" => %{
                   "ehos-tools" => %{
                     "source" => %{
                       "source" => "github",
                       "repo" => "EmpoweredHouse/ehos-tools",
                       "ref" => "ehos-app-v0.1.0"
                     }
                   },
                   "eh-os-contract" => contract_marketplace()
                 },
                 "enabledPlugins" => %{
                   "ehos-app@ehos-tools" => true,
                   "eh-os-contract@eh-os-contract" => true
                 }
               }

      igniter = with_settings(written_by_09)

      assert content(igniter, ".claude/settings.json") == new_settings

      igniter
      |> apply_igniter!()
      |> run_installer()
      |> assert_unchanged()
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

      assert settings |> with_settings() |> settings() == %{
               "extraKnownMarketplaces" => %{
                 "ehos-app" => app_marketplace(),
                 "eh-os-contract" => contract_marketplace()
               },
               "enabledPlugins" => %{
                 "ehos-app@ehos-app" => false,
                 "eh-os-contract@eh-os-contract" => true
               },
               "hooks" => review_hooks()
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

      assert settings |> with_settings() |> settings() == %{
               "extraKnownMarketplaces" => %{
                 "ehos-app" => app_marketplace(),
                 "eh-os-contract" => contract_marketplace()
               },
               "enabledPlugins" => %{
                 "ehos-app@ehos-app" => true,
                 "ehos-dev@ehos-tools" => false,
                 "eh-os-contract@eh-os-contract" => true
               },
               "hooks" => review_hooks()
             }
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

      assert settings |> with_settings() |> settings() == %{
               "extraKnownMarketplaces" => %{
                 "ehos-app" => app_marketplace(),
                 "eh-os-contract" => contract_marketplace()
               },
               "enabledPlugins" => %{
                 "ehos-app@ehos-app" => true,
                 "eh-os-contract@eh-os-contract" => true
               },
               "hooks" => review_hooks()
             }
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

      assert settings |> with_settings() |> settings() == %{
               "extraKnownMarketplaces" => %{
                 "ehos-app" => app_marketplace(),
                 "eh-os-contract" => contract_marketplace()
               },
               "enabledPlugins" => %{
                 "ehos-app@ehos-app" => true,
                 "eh-os-contract@eh-os-contract" => true
               },
               "hooks" => review_hooks()
             }
    end

    test "writes the developer's settings with their own indent and line ends",
         %{new_project: new_project} do
      settings = "{\r\n\t\"permissions\": {\r\n\t\t\"allow\": []\r\n\t}\r\n}\r\n"

      written =
        settings |> with_settings() |> apply_igniter!() |> content(".claude/settings.json")

      # The template's settings, after the developer's, indented by tabs, with CRLF line ends.
      assert written ==
               new_project
               |> content(".claude/settings.json")
               |> String.replace("{\n", ~s({\n  "permissions": {\n    "allow": []\n  },\n),
                 global: false
               )
               |> String.replace(~r/^(?:  )+/m, &String.duplicate("\t", div(byte_size(&1), 2)))
               |> String.replace("\n", "\r\n")
    end

    # 0.9.0's settings name eh-os-contract's plugin at a tag a later version moves.
    test "moves an earlier tag of eh-os-contract's plugin" do
      igniter = with_settings(contract_settings("eh-os-contract-plugin-v0.0.1"))

      assert settings(igniter)["extraKnownMarketplaces"]["eh-os-contract"] ==
               contract_marketplace()

      assert notices_with(igniter, "the marketplace eh-os-contract as") == []
    end

    test "keeps a later tag of eh-os-contract's plugin, and says so" do
      later = "eh-os-contract-plugin-v99.0.0"
      igniter = with_settings(contract_settings(later))

      assert settings(igniter)["extraKnownMarketplaces"]["eh-os-contract"] == %{
               "source" => %{
                 "source" => "github",
                 "repo" => "EmpoweredHouse/eh-os-contract",
                 "ref" => later
               }
             }

      assert notices_with(igniter, "the marketplace eh-os-contract as") == [
               kept_notice(plugin("eh-os-contract"), "EmpoweredHouse/eh-os-contract", later)
             ]
    end

    test "says how to move Phoenix's rules out of an AGENTS.md from ehos_app 0.2",
         %{install: install, new_project: new_project} do
      agents =
        "<!-- ehos_app:agents -->\nOld rules\n<!-- /ehos_app:agents -->\n\n" <> @phoenix_agents

      igniter = project_with("AGENTS.md", agents) |> run_installer()

      assert content(igniter, "AGENTS.md") ==
               section_of(content(new_project, "AGENTS.md"), "agents") <> "\n" <> @phoenix_agents

      refute Igniter.exists?(igniter, "docs/phoenix.md")
      assert notices_with(igniter, "into\ndocs/phoenix.md") == [@phoenix_rules_notice]
      assert notices_with(install, "docs/phoenix.md") == []
    end

    test "leaves a nested AGENTS.md the developer cut down to the EHOS section as it is",
         %{new_project: new_project} do
      section = section_of(content(new_project, "lib/test_web/AGENTS.md"), "web")

      again =
        new_project
        |> replace_file("lib/test_web/AGENTS.md", section)
        |> apply_igniter!()
        |> run_installer()

      assert content(again, "lib/test_web/AGENTS.md") == section
    end

    test "leaves an EHOS section alone when its end marker is gone" do
      agents = "<!-- ehos_app:agents -->\nRules the developer rewrote\n\n# Phoenix rules\n"
      igniter = project_with("AGENTS.md", agents) |> run_installer()

      assert content(igniter, "AGENTS.md") == agents
    end

    for {how, readme} <- [
          {"in a section of its own",
           "# Shop\n\nWhat it does.\n\n## Running it\n\nTo start your Phoenix server:\n\n* `mix setup`\n"},
          {"above notes of its own",
           "# Shop\n\nTo start your Phoenix server:\n\n" <> String.duplicate("Our notes.\n", 40)}
        ] do
      test "keeps a README of the project's own that still quotes Phoenix's sentence #{how}",
           %{new_project: new_project} do
        section = section_of(content(new_project, "README.md"), "readme")
        igniter = project_with("README.md", unquote(readme)) |> run_installer()

        assert content(igniter, "README.md") == section <> "\n" <> unquote(readme)
      end
    end

    test "keeps Phoenix's README with a few lines of the developer's at the end",
         %{new_project: new_project} do
      section = section_of(content(new_project, "README.md"), "readme")

      readme =
        String.replace(phoenix_readme(), "# Test", "# Shop") <> "\n## Deploying\n\nfly deploy\n"

      igniter = project_with("README.md", readme) |> run_installer()

      assert content(igniter, "README.md") == section <> "\n" <> readme
    end

    test "tells a project whose own AGENTS.md has no row for docs/elixir.md to add one",
         %{install: install} do
      igniter = project_with("AGENTS.md", "# Our rules\n") |> run_installer()

      assert notices_with(igniter, "docs/elixir.md says") == [@elixir_doc_notice]
      assert notices_with(install, "Add it to AGENTS.md's \"Where to read\"") == []
    end

    # ehos-tools#706: the file and the section's link reach an earlier project, the row does not.
    test "tells a project whose own AGENTS.md has no row for docs/platform-issues.md to add one",
         %{install: install} do
      igniter = project_with("AGENTS.md", "# Our rules\n") |> run_installer()

      assert notices_with(igniter, "docs/platform-issues.md lists") == [@platform_issues_notice]
      assert Igniter.exists?(igniter, "docs/platform-issues.md")
      assert notices_with(install, "docs/platform-issues.md lists") == []

      # Named in the application's own text, but not listed: it is still told to add the row.
      named =
        project_with(
          "AGENTS.md",
          "# Our rules\n\n[docs/platform-issues.md](docs/platform-issues.md)\n"
        )
        |> run_installer()

      assert notices_with(named, "docs/platform-issues.md lists") == [@platform_issues_notice]

      listed =
        project_with("AGENTS.md", """
        # Our rules

        ## Where to read

        | Area | Doc |
        | --- | --- |
        | What we asked of the platform | [docs/platform-issues.md](docs/platform-issues.md) |

        ## Gotchas
        """)
        |> run_installer()

      assert notices_with(listed, "docs/platform-issues.md lists") == []

      # A table last in the file, written with CRLF and a space after its heading, still counts.
      crlf =
        project_with(
          "AGENTS.md",
          "# Our rules\r\n\r\n## Where to read \r\n\r\n" <>
            "| Ours | [docs/platform-issues.md](docs/platform-issues.md) |\r\n"
        )
        |> run_installer()

      assert notices_with(crlf, "docs/platform-issues.md lists") == []
    end

    test "keeps an ARCHITECTURE.md an earlier version wrote once the developer changed a line",
         %{new_project: new_project} do
      changed = earlier_seed("architecture", "0.7.0", false) <> "\nOurs.\n"
      igniter = project_with("ARCHITECTURE.md", changed) |> run_installer()

      assert content(igniter, "ARCHITECTURE.md") ==
               section_of(content(new_project, "ARCHITECTURE.md"), "architecture") <>
                 "\n" <> changed

      assert notices_with(igniter, "has a section of the template's") == [@architecture_notice]
    end

    # The section comes last and says nothing, so the review workflow fails a pull request
    # opened from the template until its author fills it in.
    test "ends the pull request template with a Review section the author has to fill in",
         %{new_project: new_project} do
      template = content(new_project, @pull_request_template)

      assert [_, review] = String.split(template, "\n## Review\n")

      assert review == """

             <!-- What each of the two reviews of the pre-pr-review skill found, with the skills each invoked,
             and what became of each finding: fixed, no change needed (why), or a follow-up issue. Or that the
             change is documentation alone. CI's `review section` check fails while this section is empty. -->
             """

      assert EhosApp.Review.pull_request_body(template) ==
               {:error,
                "the pull request's `## Review` section is empty: say what each review found " <>
                  "and what became of each finding, or that the change is documentation alone. " <>
                  "Then edit the description: re-running the job reads the description it had."}

      assert EhosApp.Review.pull_request_body(template <> "\nNothing found.\n") == :ok
    end

    for version <- ["0.14.0", "0.21.0", "0.27.0"] do
      test "replaces the pull request template #{version} wrote", %{new_project: new_project} do
        upgraded =
          phx_test_project()
          |> with_file(
            @pull_request_template,
            File.read!("test/fixtures/pull_request_template_#{unquote(version)}.md")
          )
          |> run_installer()

        assert content(upgraded, @pull_request_template) ==
                 content(new_project, @pull_request_template)
      end
    end

    test "leaves a pull request template 0.27.0 wrote once the developer changed it" do
      edited =
        File.read!("test/fixtures/pull_request_template_0.27.0.md") <>
          "- [ ] Screenshots attached\n"

      kept = phx_test_project() |> with_file(@pull_request_template, edited) |> run_installer()

      assert content(kept, @pull_request_template) == edited
    end

    test "leaves a pull request template 0.14.0 wrote once the developer changed it, and says to add a Review section" do
      changed =
        File.read!("test/fixtures/pull_request_template_0.14.0.md") <>
          "- [ ] Screenshots attached\n"

      kept = phx_test_project() |> with_file(@pull_request_template, changed) |> run_installer()

      assert content(kept, @pull_request_template) == changed
      assert notices_with(kept, "has no `## Review` section") == [@review_notice]
    end

    # The workflow reads a heading in a comment or in code as no section at all.
    for {how, template, notices} <- [
          {"in a comment as no section", "## What\n\n<!--\n## Review\n-->\n", [@review_notice]},
          {"in a code block as no section", "## What\n\n```md\n## Review\n```\n",
           [@review_notice]},
          {"of its own as the section", "## What\n\n## Review\n\n<!-- Fill this in. -->\n", []}
        ] do
      test "reads a Review heading #{how}, as the review workflow reads a description" do
        igniter =
          phx_test_project()
          |> with_file(@pull_request_template, unquote(template))
          |> run_installer()

        assert notices_with(igniter, "has no `## Review` section") == unquote(notices)
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

      assert settings(with_settings(settings))["hooks"] == %{
               "PreToolUse" => [
                 %{
                   "matcher" => "Bash",
                   "hooks" => [
                     %{
                       "type" => "command",
                       "command" => "cd app && MIX_ENV=dev mix ehos_app.review gate"
                     }
                   ]
                 }
               ]
             }
    end

    test "keeps an ehos-tools marketplace of the developer's, and a plugin turned off there" do
      developers = %{
        "source" => %{
          "source" => "github",
          "repo" => "EmpoweredHouse/ehos-tools",
          "ref" => "ehos-dev-v0.4.0"
        }
      }

      settings = """
      {
        "extraKnownMarketplaces": {
          "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-dev-v0.4.0"}}
        },
        "enabledPlugins": {"ehos-dev@ehos-tools": true, "ehos-app@ehos-tools": false}
      }
      """

      assert settings |> with_settings() |> settings() == %{
               "extraKnownMarketplaces" => %{
                 "ehos-tools" => developers,
                 "ehos-app" => app_marketplace(),
                 "eh-os-contract" => contract_marketplace()
               },
               "enabledPlugins" => %{
                 "ehos-dev@ehos-tools" => true,
                 "ehos-app@ehos-tools" => false,
                 "ehos-app@ehos-app" => false,
                 "eh-os-contract@eh-os-contract" => true
               },
               "hooks" => review_hooks()
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

      igniter = with_settings(settings)

      assert settings(igniter) == %{
               "extraKnownMarketplaces" => %{
                 "ehos-tools" => %{
                   "source" => %{
                     "source" => "github",
                     "repo" => "MyOrg/ehos-tools",
                     "ref" => "ehos-app-v0.1.0"
                   }
                 },
                 "ehos-app" => app_marketplace(),
                 "eh-os-contract" => contract_marketplace()
               },
               "enabledPlugins" => %{
                 "ehos-app@ehos-tools" => true,
                 "ehos-app@ehos-app" => false,
                 "eh-os-contract@eh-os-contract" => true
               },
               "hooks" => review_hooks()
             }

      assert notices_with(igniter, "turn ehos-app@ehos-app on") == [
               """
               .claude/settings.json enables ehos-app@ehos-tools, from
               MyOrg/ehos-tools at ehos-app-v0.1.0,
               which is not the template's, so the installer kept it and turned ehos-app@ehos-app off. To take the
               template's plugin, turn ehos-app@ehos-app on and remove ehos-app@ehos-tools.
               """
             ]
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

      assert settings |> with_settings() |> settings() == %{
               "extraKnownMarketplaces" => %{
                 "ehos-tools" => %{
                   "source" => %{
                     "source" => "github",
                     "repo" => "EmpoweredHouse/ehos-tools",
                     "ref" => "ehos-app-v0.1.0"
                   }
                 },
                 "ehos-app" => app_marketplace(),
                 "eh-os-contract" => contract_marketplace()
               },
               "enabledPlugins" => %{
                 "ehos-app@ehos-app" => true,
                 "ehos-dev@ehos-tools" => true,
                 "eh-os-contract@eh-os-contract" => true
               },
               "hooks" => review_hooks()
             }
    end

    test "keeps a path the developer gave the ehos-app marketplace" do
      settings =
        ~s|{"extraKnownMarketplaces": {"ehos-app": {"source": {"source": "github", | <>
          ~s|"repo": "EmpoweredHouse/ehos-tools", "ref": "#{Install.plugin().ref}", | <>
          ~s|"path": ".claude-plugin/marketplace.json"}}}}\n|

      assert settings(with_settings(settings))["extraKnownMarketplaces"]["ehos-app"] == %{
               "source" => %{
                 "source" => "github",
                 "repo" => "EmpoweredHouse/ehos-tools",
                 "ref" => Install.plugin().ref,
                 "path" => ".claude-plugin/marketplace.json"
               }
             }
    end

    test "leaves settings that already enable every plugin as they are, however they are laid out",
         %{new_project: new_project} do
      compact =
        new_project
        |> content(".claude/settings.json")
        |> Jason.decode!(objects: :ordered_objects)
        |> Jason.encode!()

      again =
        new_project
        |> replace_file(".claude/settings.json", compact)
        |> apply_igniter!()
        |> run_installer()

      assert content(again, ".claude/settings.json") == compact
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

      igniter = with_settings(settings)

      assert settings(igniter) == %{
               "extraKnownMarketplaces" => %{
                 "ehos-app" => %{
                   "source" => %{
                     "source" => "github",
                     "repo" => "EmpoweredHouse/ehos-tools",
                     "ref" => "main"
                   }
                 },
                 "eh-os-contract" => contract_marketplace()
               },
               "enabledPlugins" => %{
                 "ehos-app@ehos-app" => false,
                 "eh-os-contract@eh-os-contract" => true
               },
               "hooks" => review_hooks()
             }

      assert notices_with(igniter, "the marketplace ehos-app as") == [
               kept_notice(Install.plugin(), "EmpoweredHouse/ehos-tools", "main")
             ]
    end

    for {what, repo, ref} <- [
          {"a later release of the plugin", "EmpoweredHouse/ehos-tools", "ehos-app-v99.0.0"},
          {"a marketplace on another repository", "someone/ehos-tools", "ehos-app-v0.0.1"}
        ] do
      test "keeps #{what}" do
        settings =
          ~s|{"extraKnownMarketplaces": {"ehos-app": {"source": | <>
            ~s|{"source": "github", "repo": "#{unquote(repo)}", "ref": "#{unquote(ref)}"}}}}\n|

        igniter = with_settings(settings)

        assert settings(igniter)["extraKnownMarketplaces"]["ehos-app"] == %{
                 "source" => %{
                   "source" => "github",
                   "repo" => unquote(repo),
                   "ref" => unquote(ref)
                 }
               }

        assert notices_with(igniter, "so the\ninstaller kept it") == [
                 kept_notice(Install.plugin(), unquote(repo), unquote(ref))
               ]
      end
    end

    # One test per shape, so each runs the installer once within ExUnit's timeout for a test.
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
      test "leaves settings of another shape alone, and says what to add: #{String.trim(settings)}",
           %{new_project: new_project} do
        igniter = with_settings(unquote(settings))

        assert content(igniter, ".claude/settings.json") == unquote(settings)
        assert warnings_with(igniter, ".claude/settings.json") == [settings_warning(new_project)]
      end
    end

    test "leaves settings that are not a JSON object alone, and says what to add",
         %{new_project: new_project} do
      igniter = with_settings("[]\n")

      assert content(igniter, ".claude/settings.json") == "[]\n"
      assert warnings_with(igniter, ".claude/settings.json") == [settings_warning(new_project)]
    end

    test "licenses no project an earlier version generated without a LICENSE" do
      igniter = project_with("ehos.yaml", "schema: ehos.yaml/v2\n") |> run_installer()

      refute Igniter.exists?(igniter, "LICENSE")
      assert lines_with(content(igniter, "README.md"), "LICENSE") == []
    end
  end

  # The test project with a file the developer has, written through Igniter and applied.
  defp project_with(path, content) do
    phx_test_project() |> developers_file(path, content) |> apply_igniter!()
  end

  defp developers_file(igniter, path, content) do
    Igniter.create_or_update_file(igniter, path, content, fn source ->
      Rewrite.Source.update(source, :content, fn _ -> content end)
    end)
  end

  defp run_installer(igniter), do: Igniter.compose_task(igniter, "ehos_app.install", [])

  # The installer run on the test project with `.claude/settings.json` as the developer has it.
  defp with_settings(settings) do
    phx_test_project() |> with_file(".claude/settings.json", settings) |> run_installer()
  end

  defp settings(igniter), do: igniter |> content(".claude/settings.json") |> JSON.decode!()

  defp gate_hook, do: Install.review_gate_hook() |> Jason.encode!() |> JSON.decode!()

  defp review_hooks, do: %{"PreToolUse" => [%{"matcher" => "Bash", "hooks" => [gate_hook()]}]}

  defp app_marketplace do
    %{
      "source" => %{
        "source" => "github",
        "repo" => "EmpoweredHouse/ehos-tools",
        "ref" => Install.plugin().ref,
        "path" => ".claude-plugin/ehos-app.json"
      }
    }
  end

  defp contract_settings(ref) do
    ~s|{"extraKnownMarketplaces": {"eh-os-contract": {"source": | <>
      ~s|{"source": "github", "repo": "EmpoweredHouse/eh-os-contract", "ref": "#{ref}"}}}}\n|
  end

  defp contract_marketplace do
    %{
      "source" => %{
        "source" => "github",
        "repo" => "EmpoweredHouse/eh-os-contract",
        "ref" => plugin("eh-os-contract").ref
      }
    }
  end

  # What the installer says when it keeps a marketplace that is not its plugin's earlier release.
  defp kept_notice(plugin, repo, ref) do
    """
    .claude/settings.json names the marketplace #{plugin.marketplace} as
    #{repo} at #{ref}, which is
    not an earlier release of the #{plugin.name} plugin from #{plugin.repo}, so the
    installer kept it: #{plugin.name}@#{plugin.marketplace}, where it is enabled, comes
    from there. This version of ehos_app pins #{plugin.ref}.
    """
  end

  # What the installer says when it cannot read the settings: what to add, as a new project has it.
  defp settings_warning(new_project) do
    """
    .claude/settings.json is not JSON the installer can read: an object, whose
    extraKnownMarketplaces, each marketplace there, its source, and enabledPlugins are
    objects too, and whose hooks are an object whose PreToolUse is a list of objects. The
    installer left it alone, so the plugins ehos-app and eh-os-contract
    are not enabled and the review gate is not set up. Add to it:

    """ <> content(new_project, ".claude/settings.json") <> "\n"
  end

  defp notices_with(igniter, fragment), do: Enum.filter(igniter.notices, &(&1 =~ fragment))

  defp warnings_with(igniter, fragment), do: Enum.filter(igniter.warnings, &(&1 =~ fragment))

  defp unlink_tasks(igniter),
    do: Enum.filter(igniter.tasks, &(elem(&1, 0) == "ehos_app.unlink_skills"))

  defp section(name), do: ~r/<!-- ehos_app:#{name} -->.*?<!-- \/ehos_app:#{name} -->\n?/s

  # The section of the template's named `name`, between its markers, as written in `content`.
  defp section_of(content, name) do
    [section] = Regex.run(section(name), content)
    section
  end

  # What is left of a file without the template's sections.
  defp unmanaged(content) do
    Enum.reduce(@managed, content, fn {_, name}, rest ->
      String.replace(rest, section(name), "")
    end)
  end

  # The list item of `doc` whose first line holds `fragment`, with the lines it continues on.
  defp item(doc, fragment) do
    {_, [first | rest]} =
      doc |> String.split("\n") |> Enum.split_while(&(not String.contains?(&1, fragment)))

    Enum.join([first | Enum.take_while(rest, &String.starts_with?(&1, "  "))], "\n")
  end

  # The headings of a Markdown document, in order, leaving out lines in fenced code.
  defp headings(doc) do
    {headings, _fenced?} =
      doc
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {headings, fenced?} ->
        cond do
          String.starts_with?(String.trim_leading(line), "```") -> {headings, not fenced?}
          not fenced? and line =~ ~r/\A#+ / -> {[line | headings], fenced?}
          true -> {headings, fenced?}
        end
      end)

    Enum.reverse(headings)
  end

  # From `heading` to the next heading of its level or above.
  defp subsection(doc, heading) do
    [level] = Regex.run(~r/\A#+/, heading)
    {_, [^heading | rest]} = doc |> String.split("\n") |> Enum.split_while(&(&1 != heading))
    next = ~r/\A\#{1,#{byte_size(level)}} /

    Enum.join([heading | Enum.take_while(rest, &(not (&1 =~ next)))], "\n")
  end

  # The contents of each fenced code block of `doc`, as written, indentation included.
  defp code_blocks(doc) do
    ~r/^ *```[a-z]*\n(.*?)^ *```$/ms
    |> Regex.scan(doc, capture: :all_but_first)
    |> List.flatten()
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
end

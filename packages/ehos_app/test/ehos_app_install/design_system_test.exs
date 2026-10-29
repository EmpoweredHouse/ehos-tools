defmodule Mix.Tasks.EhosApp.InstallTest.DesignSystem do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "the design system" do
    test "adds ehos_design from ehos-tools, pinned to the commit of its release" do
      assert installed() |> content("mix.exs") =~
               ~r/\{:ehos_design, "~> 0\.2\.0",\s+github: "EmpoweredHouse\/ehos-tools",\s+sparse: "packages\/ehos_design",\s+ref: "[0-9a-f]{40}"\}/
    end

    test "imports its layer right after Tailwind, in place of Phoenix's two daisyUI themes" do
      css = installed() |> content("assets/css/app.css")

      assert css =~
               ~r/@import "tailwindcss" source\(none\);\n\n\/\* ehos_app:design-system: the EmpoweredHouse design system.*?\*\/\n@import "\.\.\/\.\.\/deps\/ehos_design\/packages\/ehos_design\/priv\/css\/ehos_design\.css";\n/s

      refute css =~ "daisyui-theme"
      refute css =~ "daisyUI theme plugin"
      assert css =~ ~r/@plugin "[^"]*daisyui" \{\s+themes: false;\s+\}/
      assert css =~ ~r/\/\* ehos_app:own-styles: this application's own styles\..*\*\/\n\z/s
    end

    # eh-os D-86: the components render utilities Tailwind finds only in their templates. After
    # Phoenix's own sources, since no rule may come before Phoenix's second `@import`.
    test "names the design system's components' templates as a source for Tailwind" do
      css = installed() |> content("assets/css/app.css")

      assert css =~
               ~r|@source "\.\./\.\./lib/test_web";\n@source "\.\./\.\./deps/ehos_design/packages/ehos_design/lib";\n|
    end

    # eh-os D-86: the components' keyboard is a colocated hook of the package's.
    test "gives the LiveSocket the design system's hooks beside the application's own" do
      js = installed() |> content("assets/js/app.js")

      assert js =~
               ~s|import {hooks as colocatedHooks} from "phoenix-colocated/test"\n| <>
                 ~s|import {hooks as designHooks} from "phoenix-colocated/ehos_design"\n|

      assert js =~ "hooks: {...colocatedHooks, ...designHooks}"
    end

    test "gives no hooks to a project that pinned the design system itself, at its own version" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep({:ehos_design, "~> 0.1.0", path: "../ehos_design"})
        |> Igniter.compose_task("ehos_app.install", [])

      refute content(igniter, "assets/js/app.js") =~ "phoenix-colocated/ehos_design"
    end

    test "says where to name the components' templates when Phoenix's source is not there" do
      igniter =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", fn source ->
          Rewrite.Source.update(source, :content, fn css ->
            String.replace(css, ~r/^@source "\.\.\/\.\.\/lib\/[a-z_]+";\n/m, "")
          end)
        end)
        |> Igniter.compose_task("ehos_app.install", [])

      refute content(igniter, "assets/css/app.css") =~ "packages/ehos_design/lib"
      assert Enum.any?(igniter.notices, &(&1 =~ "were not named as a source for Tailwind"))
    end

    test "leaves a script that is not Phoenix's alone, and says what to add" do
      igniter =
        phx_test_project()
        |> replace_file("assets/js/app.js", "console.log(\"mine\")\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "assets/js/app.js") == "console.log(\"mine\")\n"

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "design system's components' hooks were not added")
             )
    end

    # A project that has the design system keeps the version it pinned, which may have no hooks.
    test "gives a project that has the design system already no hooks" do
      installed = installed()

      js =
        installed
        |> content("assets/js/app.js")
        |> String.replace(
          ~s|import {hooks as designHooks} from "phoenix-colocated/ehos_design"\n|,
          ""
        )
        |> String.replace(", ...designHooks", "")

      again =
        phx_test_project()
        |> replace_file("assets/css/app.css", content(installed, "assets/css/app.css"))
        |> replace_file("assets/js/app.js", js)
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(again, "assets/js/app.js") == js
    end

    @root_layout "lib/test_web/components/layouts/root.html.heex"

    test "preloads the two faces of Albert Sans the text is set in, before the stylesheet" do
      root = installed() |> content(@root_layout)

      # As Phoenix's HEEx formatter writes them, indented as the stylesheet's link is.
      preload = fn weight ->
        """
            <link
              rel="preload"
              href="/ehos_design/fonts/albert-sans-latin-#{weight}-normal.woff2"
              as="font"
              type="font/woff2"
              crossorigin
            />
        """
      end

      assert root =~
               preload.(400) <>
                 preload.(500) <>
                 ~s|    <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />|

      for file <- ["albert-sans-latin-400-normal.woff2", "albert-sans-latin-500-normal.woff2"] do
        assert File.exists?(Path.join(["../ehos_design/priv/static/ehos_design/fonts", file]))
      end
    end

    test "leaves the root layout alone once the design system is installed" do
      igniter = installed()
      root = content(igniter, @root_layout)
      without = String.replace(root, ~r{\n *<link\n *rel="preload".*?/>}s, "")

      again =
        igniter
        |> Igniter.update_file(
          @root_layout,
          &Rewrite.Source.update(&1, :content, fn _ -> without end)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert without != root
      assert content(again, @root_layout) == without
    end

    test "says how to preload the fonts when the root layout is not Phoenix's" do
      igniter =
        phx_test_project()
        |> Igniter.update_file(
          @root_layout,
          &Rewrite.Source.update(&1, :content, fn _ -> "<html><head></head></html>\n" end)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, @root_layout) == "<html><head></head></html>\n"
      assert Enum.any?(igniter.notices, &(&1 =~ "fonts are not preloaded"))
    end

    test "preloads nothing when the design system was not imported, on any run" do
      project =
        phx_test_project()
        |> Igniter.update_file(
          "assets/css/app.css",
          &Rewrite.Source.update(&1, :content, fn _ -> "body { margin: 0; }\n" end)
        )
        |> apply_igniter!()

      # What the run changes in the root layout besides the preloads: the way in and out, and
      # the title without Phoenix's suffix.
      root_before =
        project
        |> content(@root_layout)
        |> String.replace(
          "  <body>\n",
          "  <body>\n    <TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\n"
        )
        |> String.replace(~s| suffix=" · Phoenix Framework"|, "")

      roots =
        for run <- [1, 2] do
          installed =
            Enum.reduce(1..run, project, fn _run, igniter ->
              igniter |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()
            end)

          root = content(installed, @root_layout)
          refute root =~ "ehos_design/fonts/", "run #{run}"
          root
        end

      assert roots == [root_before, root_before]
    end

    test "writes the preloads in a CRLF layout's own line endings" do
      igniter =
        phx_test_project()
        |> Igniter.update_file(
          @root_layout,
          &Rewrite.Source.update(&1, :content, fn content ->
            String.replace(content, "\n", "\r\n")
          end)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      root = content(igniter, @root_layout)

      assert root =~ "albert-sans-latin-400-normal.woff2"
      assert root =~ "<body>\r\n    <TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\r\n"
      refute root =~ ~r/[^\r]\n/
    end

    test "points the import at the stylesheet where the sparse dependency puts it" do
      assert Path.join([Install.design_system(), "priv/css/ehos_design.css"]) ==
               "deps/ehos_design/packages/ehos_design/priv/css/ehos_design.css"
    end

    test "keeps a daisyUI theme of the developer's own" do
      own = """
      @plugin "daisyui/packages/bundle/daisyui-theme" {
        name: "brand";
        default: true;
      }
      """

      css =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", fn source ->
          Rewrite.Source.update(source, :content, &(&1 <> "\n" <> own))
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("assets/css/app.css")

      assert css =~ own
      refute css =~ ~s|name: "dark"|
    end

    test "leaves a stylesheet without Tailwind's import alone, and says what to add" do
      install =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", fn source ->
          Rewrite.Source.update(source, :content, fn _ -> "body { margin: 0; }\n" end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert_has_warning(install, &(&1 =~ "so the design system was not imported"))

      installed = apply_igniter!(install)
      assert content(installed, "assets/css/app.css") == "body { margin: 0; }\n"

      development = content(installed, "DEVELOPMENT.md")
      assert development =~ "which `assets/css/app.css` does not import yet"
      refute development =~ "only imports it"

      assert development =~
               "CI reads the private `eh_os_contract` and `ehos_design`, and installs"

      architecture = content(installed, "ARCHITECTURE.md")

      assert architecture =~
               ~s|the installer found no line there starting `@import "tailwindcss"`|

      assert architecture =~ "which hooks to register in `assets/js/app.js`"
      refute architecture =~ "registers its components' hooks"
      refute content(installed, "lib/test_web/AGENTS.md") =~ "`assets/css/app.css` imports it"
    end

    # eh-os D-135: Req reads none of the variables EHOS gives for a host outside the installation.
    test "says how a host outside the installation is named and reached" do
      architecture = content(installed(), "ARCHITECTURE.md")

      assert architecture =~ "| `EHOS_EGRESS_PROXY`, `HTTPS_PROXY`, `NO_PROXY` |"
      assert architecture =~ "A host is named under `needs.egress`"
      assert architecture =~ "|> EhOsContract.Auth.Egress.attach()"
    end

    # eh-os D-140: an application asks for mail, is agreed it, and sends it as itself.
    test "says how the application asks for mail, sends it, and reads the answers" do
      architecture = content(installed(), "ARCHITECTURE.md")

      assert architecture =~
               "under `needs.mail` in `ehos.yaml`, which takes it from `schema: ehos.yaml/v6`"

      assert architecture =~ "`ehos.mail.manage`"
      assert architecture =~ "EhOsContract.Auth.Mail.deliver("
      assert architecture =~ "EHOS receives no mail."
    end

    test "says the design system is imported where it is" do
      igniter = installed()

      assert content(igniter, "DEVELOPMENT.md") =~ "and `assets/css/app.css` only imports it"

      assert content(igniter, "ARCHITECTURE.md") =~
               "after Tailwind, and `assets/js/app.js` registers its components' hooks"

      refute content(igniter, "ARCHITECTURE.md") =~ "does not import it yet"
      assert content(igniter, "lib/test_web/AGENTS.md") =~ "`assets/css/app.css` imports it"
    end

    test "serves its fonts from the application's own origin, after Phoenix's static files" do
      endpoint = installed() |> content("lib/test_web/endpoint.ex")

      assert endpoint =~
               ~r/plug\(?Plug\.Static,\s+at: "\/",\s+from: :test,.*?only: TestWeb\.static_paths\(\),[^)]*\)?\n\n.*?plug\(?Plug\.Static,\s+at: "\/",\s+from: \{:ehos_design, "priv\/static"\},\s+gzip: false,\s+only: ~w\(ehos_design\),\s+cache_control_for_etags: "public, max-age=86400"\)?/s
    end

    test "with --example, shows itself on a page of its own, in the browser pipeline, tested" do
      igniter = installed(["--example"])

      assert content(igniter, "lib/test_web/live/design_system_live.ex") =~
               "use TestWeb, :live_view"

      assert content(igniter, "test/test_web/live/design_system_live_test.exs") =~
               "use TestWeb.ConnCase, async: true"

      assert content(igniter, "lib/test_web/router.ex") =~
               ~r/scope "\/", TestWeb do\s+pipe_through\(?:browser\)?\s+get\(?"\/", PageController, :home\)?\s+live\(?"\/design-system", DesignSystemLive\)?/
    end

    # Declined as the comment says, and as the comment is likely to go: with the import, with the
    # comment above it, or by commenting the import out. Each time the developer also removes the
    # dependency and the fonts' plug, and restores Phoenix's light theme.
    for {how, kind} <- [
          {"removing the import", :import},
          {"removing the import and the comment above it", :import_and_comment},
          {"commenting the import out", :comment_out}
        ] do
      test "never brings back a design system the developer declined by #{how}" do
        igniter = installed(["--example"])
        css = content(igniter, "assets/css/app.css")

        declined =
          decline(css, unquote(kind)) <>
            """

            @plugin "daisyui/packages/bundle/daisyui-theme" {
              name: "light";
              default: true;
              --color-base-100: oklch(98% 0 0);
            }
            """

        assert decline(css, unquote(kind)) != css, "the test's own edit did not apply"
        refute declined =~ ~r/^@import "[^"]*ehos_design\.css";$/m

        again =
          igniter
          |> Igniter.update_file(
            "assets/css/app.css",
            &Rewrite.Source.update(&1, :content, fn _ -> declined end)
          )
          |> Igniter.update_file("mix.exs", fn source ->
            Rewrite.Source.update(
              source,
              :content,
              &String.replace(&1, ~r/\{:ehos_design,.*?\},\n/s, "")
            )
          end)
          |> Igniter.update_file("lib/test_web/endpoint.ex", fn source ->
            Rewrite.Source.update(
              source,
              :content,
              &String.replace(&1, "{:ehos_design", "{:somewhere_else")
            )
          end)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", ["--example"])
          |> apply_igniter!()

        assert content(again, "assets/css/app.css") == declined
        refute content(again, "mix.exs") =~ ":ehos_design"
        refute content(again, "lib/test_web/endpoint.ex") =~ "{:ehos_design"

        assert content(again, "lib/test_web/AGENTS.md") =~
                 "declined the EmpoweredHouse design system"

        refute content(again, "lib/test_web/AGENTS.md") =~ "bg-surface-1"

        development = content(again, "DEVELOPMENT.md")
        assert development =~ "CI reads the private `eh_os_contract`, and installs `ehosctl`"
        assert development =~ "a fine-grained token that reads eh-os-contract alone"
      end
    end

    test "keeps a Phoenix theme the developer changed in one colour alone" do
      branded = fn css ->
        String.replace(
          css,
          "--color-primary: oklch(70% 0.213 47.604);",
          "--color-primary: oklch(55% 0.2 140);"
        )
      end

      css =
        phx_test_project()
        |> Igniter.update_file(
          "assets/css/app.css",
          &Rewrite.Source.update(&1, :content, branded)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("assets/css/app.css")

      assert css =~ "--color-primary: oklch(55% 0.2 140);"
      assert css =~ ~s|name: "light"|
      refute css =~ ~s|name: "dark"|
    end

    test "keeps a dark or light theme the developer has tuned, and says it covers the design system" do
      tuned = fn css ->
        String.replace(
          css,
          "--color-base-100: oklch(30.33% 0.016 252.42);",
          "--color-base-100: oklch(20% 0 0);"
        )
      end

      install =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", &Rewrite.Source.update(&1, :content, tuned))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      css = install |> apply_igniter!() |> content("assets/css/app.css")

      assert css =~ "--color-base-100: oklch(20% 0 0);"
      refute css =~ "--color-base-100: oklch(98% 0 0);"
      assert Enum.any?(install.notices, &(&1 =~ "keeps a daisyUI theme of the project's own"))
    end

    test "keeps the version of ehos_design the developer has moved to" do
      mix =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep(
          {:ehos_design, "~> 0.2.0",
           github: "EmpoweredHouse/ehos-tools",
           sparse: "packages/ehos_design",
           tag: "ehos_design-v0.2.0"}
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("mix.exs")

      assert mix =~ ~s|tag: "ehos_design-v0.2.0"|
      refute mix =~ ~r/ehos_design.*ref:/s
    end

    test "writes the page once, and leaves one the developer has alone, wherever it is" do
      moved =
        phx_test_project()
        |> Igniter.create_new_file("lib/test_web/design_system_live.ex", """
        defmodule TestWeb.DesignSystemLive do
          use TestWeb, :live_view
        end
        """)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--example"])
        |> apply_igniter!()

      # Igniter's test project moves a module to its proper location, so it is found by name.
      defining =
        for {path, source} <- moved.assigns.test_files,
            String.ends_with?(path, ".ex"),
            source =~ "defmodule TestWeb.DesignSystemLive do",
            do: source

      assert [ours] = defining
      refute ours =~ "@moduledoc"
      assert content(moved, "lib/test_web/router.ex") =~ "DesignSystemLive"
    end

    test "routes the page although the router mentions it in a comment, and keeps a route of the developer's" do
      with_router = fn edit ->
        phx_test_project()
        |> Igniter.update_file(
          "lib/test_web/router.ex",
          &Rewrite.Source.update(&1, :content, edit)
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", ["--example"])
        |> apply_igniter!()
        |> content("lib/test_web/router.ex")
      end

      commented =
        with_router.(
          &String.replace(
            &1,
            "  pipeline :browser do",
            "  # DesignSystemLive goes here.\n  pipeline :browser do"
          )
        )

      assert commented =~ ~r/live\(?"\/design-system", DesignSystemLive\)?/

      # The in-memory project formats without Phoenix's `locals_without_parens`.
      moved =
        with_router.(
          &Regex.replace(
            ~r/^(\s*)get\(?"\/", PageController, :home\)?$/m,
            &1,
            ~s|\\0\n\\1live "/look", DesignSystemLive|
          )
        )

      assert moved =~ "/look", "the test's own edit did not apply"

      assert moved =~ ~r/live\(?"\/look", DesignSystemLive\)?/
      refute moved =~ "/design-system"
    end

    test "without --example, adds no page" do
      igniter = installed()

      refute Igniter.exists?(igniter, "lib/test_web/live/design_system_live.ex")
      refute content(igniter, "lib/test_web/router.ex") =~ "DesignSystemLive"
    end
  end

  # The three ways a developer is likely to decline the design system in app.css.
  defp decline(css, :import),
    do: String.replace(css, ~r/^@import "[^"]*ehos_design\.css";\n/m, "")

  defp decline(css, :import_and_comment),
    do:
      String.replace(
        css,
        ~r{/\* ehos_app:design-system:.*?\*/\n@import "[^"]*ehos_design\.css";\n}s,
        ""
      )

  defp decline(css, :comment_out),
    do: String.replace(css, ~r/^(@import "[^"]*ehos_design\.css";)$/m, "/* \\1 */")
end

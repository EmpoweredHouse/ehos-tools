defmodule Mix.Tasks.EhosApp.InstallTest.DesignSystem do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  @root_layout "lib/test_web/components/layouts/root.html.heex"

  # What a run says of an earlier version's commit kept beside a choice of the project's own.
  @kept_earlier """
  ehos_design is on the commit an earlier ehos_app pinned, with a requirement or an option of
  the project's own, so it was left as it is. This ehos_app is written for its release
  0.5.0, commit 8b2de14f3c6f7768c5ddb9f74f0595ec44acddd0: move the `ref:` and the requirement
  by hand, keeping the rest.
  """

  # `ehos_design-v0.5.0`'s commit, as this version pins it.
  @current_ehos_design {:ehos_design, "~> 0.5.0",
                        [
                          github: "EmpoweredHouse/ehos-tools",
                          sparse: "packages/ehos_design",
                          ref: "8b2de14f3c6f7768c5ddb9f74f0595ec44acddd0"
                        ]}

  # The end of `assets/css/app.css`, where the application's own styles go.
  @own_styles """
  /* ehos_app:own-styles: this application's own styles. A token of the design system is overridden
     here, after it, on :root; one that differs between the themes is overridden wherever the
     tokens set it (deps/ehos_design/packages/ehos_design/README.md, "Changing the look"):

     :root { --lime: #7dd3fc; } */
  """

  # Phoenix's own `@plugin` lines, once its two daisyUI themes are gone.
  @phoenix_plugins [
    ~s|@plugin "../vendor/heroicons";|,
    ~s|@plugin "daisyui/packages/bundle/daisyui" {|
  ]

  describe "the design system" do
    test "adds ehos_design from ehos-tools, pinned to the commit of its release" do
      assert dep(installed(), :ehos_design) == @current_ehos_design
    end

    test "imports its layer right after Tailwind, in place of Phoenix's two daisyUI themes" do
      css = installed() |> content("assets/css/app.css")

      assert lines_through(
               css,
               ~s|@import "tailwindcss" source(none);|,
               ~s|@import "../../deps/ehos_design/packages/ehos_design/priv/css/ehos_design.css";|
             ) == """
             @import "tailwindcss" source(none);

             /* ehos_app:design-system: the EmpoweredHouse design system, this application's default look. Its
                tokens, their Tailwind utilities (bg-surface-1, text-fg-secondary, border-line-faint, …), one
                daisyUI theme made of them, and its fonts, which the endpoint serves. Override a token at the
                end of this file. For a look of your own, remove the import below and keep this comment, which
                tells ehos_app's installer not to add it back; then turn daisyUI's themes back on, remove the
                endpoint's Plug.Static for ehos_design, the two font preloads in the root layout, the
                @source of its templates below, the import of its hooks and ...designHooks in
                assets/js/app.js, and the dependency, and delete the page at /design-system, if there is one,
                which shows the design system. */
             @import "../../deps/ehos_design/packages/ehos_design/priv/css/ehos_design.css";
             """

      refute css =~ "daisyui-theme"
      refute css =~ "daisyUI theme plugin"

      assert lines_through(css, ~s|@plugin "daisyui/packages/bundle/daisyui" {|, "}") == """
             @plugin "daisyui/packages/bundle/daisyui" {
               themes: false;
             }
             """

      assert lines_through(css, hd(String.split(@own_styles, "\n")), :end) == @own_styles
    end

    # eh-os D-86: the components render utilities Tailwind finds only in their templates. After
    # Phoenix's own sources, since no rule may come before Phoenix's second `@import`.
    test "names the design system's components' templates as a source for Tailwind" do
      css = installed() |> content("assets/css/app.css")

      assert lines_through(
               css,
               ~s|@source "../../lib/test_web";|,
               ~s|@source "../../deps/ehos_design/packages/ehos_design/lib";|
             ) == """
             @source "../../lib/test_web";
             @source "../../deps/ehos_design/packages/ehos_design/lib";
             """
    end

    # eh-os D-86: the components' keyboard is a colocated hook of the package's.
    test "gives the LiveSocket the design system's hooks beside the application's own" do
      install()
      |> assert_has_patch("assets/js/app.js", """
        |import {hooks as colocatedHooks} from "phoenix-colocated/test"
      + |import {hooks as designHooks} from "phoenix-colocated/ehos_design"
        |import topbar from "../vendor/topbar"
      """)
      |> assert_has_patch("assets/js/app.js", """
      - |  hooks: {...colocatedHooks},
      + |  hooks: {...colocatedHooks, ...designHooks},
      """)
    end

    test "serves its fonts from the application's own origin, after Phoenix's static files" do
      endpoint = installed() |> content("lib/test_web/endpoint.ex")

      assert lines_through(
               endpoint,
               "  plug(Plug.Static,",
               ~s|    cache_control_for_etags: "public, max-age=86400"|
             ) == """
               plug(Plug.Static,
                 at: "/",
                 from: :test,
                 gzip: not code_reloading?,
                 only: TestWeb.static_paths(),
                 raise_on_missing_only: code_reloading?
               )

               # The design system's fonts, which assets/css/app.css names under /ehos_design/fonts/. Their
               # paths carry no version, so they are cached for a day and then revalidated.
               plug(Plug.Static,
                 at: "/",
                 from: {:ehos_design, "priv/static"},
                 gzip: false,
                 only: ~w(ehos_design),
                 cache_control_for_etags: "public, max-age=86400"
             """
    end

    test "preloads the two faces of Albert Sans the text is set in, before the stylesheet" do
      root = installed() |> content(@root_layout)

      # As Phoenix's HEEx formatter writes them, indented as the stylesheet's link is.
      assert lines_through(
               root,
               "    <link",
               ~s|    <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />|
             ) == """
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
                 <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />
             """

      for file <- ["albert-sans-latin-400-normal.woff2", "albert-sans-latin-500-normal.woff2"] do
        assert File.exists?(Path.join(["../ehos_design/priv/static/ehos_design/fonts", file]))
      end
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

      assert content(igniter, @root_layout) ==
               installed() |> content(@root_layout) |> String.replace("\n", "\r\n")
    end

    test "points the import at the stylesheet where the sparse dependency puts it" do
      assert Path.join([Install.design_system(), "priv/css/ehos_design.css"]) ==
               "deps/ehos_design/packages/ehos_design/priv/css/ehos_design.css"
    end

    test "says the design system is imported where it is" do
      igniter = installed()

      assert passage(content(igniter, "DEVELOPMENT.md"), "**Assets**") == """
             - **Assets** are Phoenix's: `assets/` holds the application's stylesheet and script, which
               esbuild and Tailwind build from Mix. The design system comes from the `ehos_design` dependency,
               and `assets/css/app.css` only imports it ([ARCHITECTURE.md](ARCHITECTURE.md)).
             """

      assert passage(content(igniter, "ARCHITECTURE.md"), "The EmpoweredHouse design system") ==
               """
               `assets/` is Phoenix's asset pipeline: `app.css` and `app.js`, built by Tailwind and esbuild,
               which Mix installs and runs (`mix assets.build`), into `priv/static/`.
               The EmpoweredHouse design system is not copied there: it is the `ehos_design` dependency, whose
               fonts the endpoint serves from `/ehos_design/fonts/`. `assets/css/app.css` imports it right
               after Tailwind, and `assets/js/app.js` registers its components' hooks.
               A token is overridden at the end of `app.css`, and a later version arrives by moving the
               dependency.
               """

      assert passage(content(igniter, "lib/test_web/AGENTS.md"), "**The UI follows") == """
             - **The UI follows the EmpoweredHouse design system** by default, from the `ehos_design`
               dependency: `assets/css/app.css` imports it, and the endpoint serves its fonts. Build on
               `core_components.ex`, which it styles, and on its utilities (`bg-surface-1`,
               `text-fg-secondary`, `border-line-faint`) rather than Tailwind's own colours. Override a token
               at the end of `app.css`; `deps/ehos_design/packages/ehos_design/README.md` says how to replace the look.
             """
    end

    # eh-os D-135: Req reads none of the variables EHOS gives for a host outside the installation.
    test "says how a host outside the installation is named and reached" do
      architecture = content(installed(), "ARCHITECTURE.md")

      assert passage(architecture, "| `EHOS_EGRESS_PROXY`") == """
             | `EHOS_EGRESS_PROXY`, `HTTPS_PROXY`, `NO_PROXY` | The application's proxy to the hosts outside the installation it names, and the names it reaches directly; given only when `ehos.yaml` names such a host |
             """

      assert passage(architecture, "A host is named under `needs.egress`") == """
             The application reaches nothing outside the installation but the hosts its `ehos.yaml` names,
             and those only through a proxy of its own, which EHOS gives it as `EHOS_EGRESS_PROXY`, from EHOS
             0.19.0. A host is named under `needs.egress`, with its port, 443 unless said, which `ehos.yaml`
             takes from `schema: ehos.yaml/v5`. The proxy
             admits TLS alone, to those names alone, checked in the request and in the TLS handshake; every
             other connection out is refused. Naming a host is part of what the application may do: a
             deployment or a promotion that adds, removes or changes one needs the right to register the
             application, and only a deployment changes the hosts in force.
             """

      assert passage(architecture, "|> EhOsContract.Auth.Egress.attach()") == """
             ```elixir
             Req.new(base_url: "https://registry.example.org")
             |> EhOsContract.Auth.Egress.attach()
             |> Req.get!(url: "/companies/123")
             ```
             """
    end

    # eh-os D-140: an application asks for mail, is agreed it, and sends it as itself.
    test "says how the application asks for mail, sends it, and reads the answers" do
      architecture = content(installed(), "ARCHITECTURE.md")

      assert passage(architecture, "under `needs.mail`") == """
             The application sends mail through EHOS, as itself, over the company's own relay, from EHOS 0.20.0.
             It asks under `needs.mail` in `ehos.yaml`, which takes it from `schema: ehos.yaml/v6`:
             """

      assert passage(architecture, "`ehos.mail.manage`") == """
             Asking grants nothing. Someone who holds `ehos.mail.manage` agrees per environment, on EHOS's
             Installation page or with `ehosctl mail agree`, at a level no wider than the one asked for and for
             the reply domains named; a new environment, such as a preview, has no agreement, and a withdrawal
             refuses the next message. Every message leaves from the installation's sending address under the
             application's name.
             """

      assert passage(architecture, "EhOsContract.Auth.Mail.deliver(") == """
             ```elixir
             EhOsContract.Auth.Mail.deliver(
               to: [{:person, person_id}],
               subject: "A document waits for your approval",
               text: "Open it at https://office.example.org/d/42."
             )
             ```
             """

      assert passage(architecture, "EHOS receives no mail.") == """
             **Reading the answers.** EHOS receives no mail. The application points the MX record of one of its
             `reply_domains` at a mail provider's inbound routing, and pulls the stored messages from the
             provider's HTTPS API through its egress proxy, with the provider's host under `needs.egress` and
             its key as a secret. Not through a webhook: that would be a public route that carries no credential
             EHOS issued. Threading ties an answer to what it answers: `reply_to:` an address in a reply domain
             that names the task, and `in_reply_to:` and `references:` the ids of the messages before. Anyone
             can write to a reply domain and forge a sender, so what arrives there is untrusted input: the token
             in the reply address is one no one can guess, random or signed, never the task's number.
             """
    end

    test "with --example, shows itself on a page of its own, in the browser pipeline, tested" do
      igniter = installed(["--example"])

      assert lines_starting(content(igniter, "lib/test_web/live/design_system_live.ex"), "  use ") ==
               ["  use TestWeb, :live_view"]

      assert igniter
             |> content("test/test_web/live/design_system_live_test.exs")
             |> lines_starting("  use ") == ["  use TestWeb.ConnCase, async: true"]

      # The in-memory project formats without Phoenix's `locals_without_parens`.
      assert lines_through(
               content(igniter, "lib/test_web/router.ex"),
               ~s|  scope "/", TestWeb do|,
               "  end"
             ) ==
               """
                 scope "/", TestWeb do
                   pipe_through(:browser)

                   get("/", PageController, :home)
                   live("/design-system", DesignSystemLive)
                 end
               """
    end

    test "routes the page although the router mentions it in a comment, and keeps a route of the developer's" do
      commented =
        with_router(
          &String.replace(
            &1,
            "  pipeline :browser do",
            "  # DesignSystemLive goes here.\n  pipeline :browser do"
          )
        )

      assert lines_through(commented, ~s|  scope "/", TestWeb do|, "  end") == """
               scope "/", TestWeb do
                 pipe_through(:browser)

                 get("/", PageController, :home)
                 live("/design-system", DesignSystemLive)
               end
             """

      # The in-memory project formats without Phoenix's `locals_without_parens`.
      moved =
        with_router(
          &Regex.replace(
            ~r/^(\s*)get\(?"\/", PageController, :home\)?$/m,
            &1,
            ~s|\\0\n\\1live "/look", DesignSystemLive|
          )
        )

      assert lines_through(moved, ~s|  scope "/", TestWeb do|, "  end") == """
               scope "/", TestWeb do
                 pipe_through(:browser)

                 get("/", PageController, :home)

                 live("/look", DesignSystemLive)
               end
             """

      refute moved =~ "/design-system"
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

      assert defining == [
               """
               defmodule TestWeb.DesignSystemLive do
                 use TestWeb, :live_view
               end
               """
             ]

      assert lines_starting(content(moved, "lib/test_web/router.ex"), "    live(") == [
               ~s|    live("/design-system", DesignSystemLive)|
             ]
    end

    test "gives no hooks to a project that pinned the design system itself, at its own version" do
      phx_test_project()
      |> Igniter.Project.Deps.add_dep({:ehos_design, "~> 0.1.0", path: "../ehos_design"})
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged("assets/js/app.js")
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

    test "says where to name the components' templates when Phoenix's source is not there" do
      igniter =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", fn source ->
          Rewrite.Source.update(source, :content, fn css ->
            String.replace(css, ~r/^@source "\.\.\/\.\.\/lib\/[a-z_]+";\n/m, "")
          end)
        end)
        |> Igniter.compose_task("ehos_app.install", [])

      assert lines_starting(content(igniter, "assets/css/app.css"), "@source ") == [
               ~s|@source "../css";|,
               ~s|@source "../js";|,
               ~s|@source "../../_build/dev/phoenix-colocated/test/*/";|
             ]

      assert notice(igniter, "were not named as a source for Tailwind") == """
             assets/css/app.css has no `@source` of Phoenix's for the application's templates, so the design
             system's components' templates were not named as a source for Tailwind. Their
             utilities need it, after the stylesheet's other sources:

                 @source "../../deps/ehos_design/packages/ehos_design/lib";
             """
    end

    test "leaves a script that is not Phoenix's alone, and says what to add" do
      igniter =
        phx_test_project()
        |> replace_file("assets/js/app.js", "console.log(\"mine\")\n")
        |> Igniter.compose_task("ehos_app.install", [])

      assert content(igniter, "assets/js/app.js") == "console.log(\"mine\")\n"

      assert notice(igniter, "design system's components' hooks were not added") == """
             assets/js/app.js was not found, or has no import of Phoenix's colocated hooks or no `hooks:`
             that spreads them, so the design system's components' hooks were not added. Their
             keyboard needs them, beside the application's:

             import {hooks as designHooks} from "phoenix-colocated/ehos_design"

             and `...designHooks` in the LiveSocket's `hooks:`.
             """
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

      assert notice(igniter, "fonts are not preloaded") == """
             lib/test_web/components/layouts/root.html.heex was not found, or has no stylesheet link where Phoenix writes it, so the
             design system's fonts are not preloaded. To preload them, add to its <head>, before
             the stylesheet:

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

          content(installed, @root_layout)
        end

      assert roots == [root_before, root_before]
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

      assert lines_through(css, ~s|@plugin "daisyui/packages/bundle/daisyui-theme" {|, :end) ==
               own <> "\n" <> @own_styles

      assert lines_starting(css, "  name: ") == [~s|  name: "brand";|]
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

      assert lines_starting(css, "@plugin ") ==
               @phoenix_plugins ++ [~s|@plugin "daisyui/packages/bundle/daisyui-theme" {|]

      assert lines_starting(css, "  name: ") == [~s|  name: "light";|]

      assert lines_starting(css, "  --color-primary: ") == [
               "  --color-primary: oklch(55% 0.2 140);"
             ]
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

      assert lines_starting(css, "  --color-base-100: ") == [
               "  --color-base-100: oklch(20% 0 0);"
             ]

      assert notice(install, "keeps a daisyUI theme of the project's own") == """
             assets/css/app.css keeps a daisyUI theme of the project's own, which sets daisyUI's colours over
             the design system's. Remove it to take the design system's look, or keep it, and the
             design system's tokens and fonts, under it.
             """
    end

    test "keeps the version of ehos_design the developer has moved to" do
      igniter =
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

      assert dep(igniter, :ehos_design) ==
               {:ehos_design, "~> 0.2.0",
                [
                  github: "EmpoweredHouse/ehos-tools",
                  sparse: "packages/ehos_design",
                  tag: "ehos_design-v0.2.0"
                ]}
    end

    # `ehos_design-v0.2.0`'s commit, which 0.6.0 to 0.23.0 pinned, and `ehos_design-v0.1.0`'s,
    # which 0.3.0 to 0.5.0 pinned.
    for {release, ref} <- [
          {"0.2.0", "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6"},
          {"0.1.0", "a65b9c86d920b5566f1c085b2286a44da77505c9"}
        ] do
      test "moves ehos_design from #{release}'s commit, which an earlier version pinned" do
        install = installed() |> on_ehos_design(unquote(release), unquote(ref)) |> move()

        assert dep(apply_igniter!(install), :ehos_design) == @current_ehos_design

        assert notices_about(install, "ehos_design moved") == [
                 """
                 ehos_design moved from the commit an earlier ehos_app pinned to its release
                 0.5.0, commit 8b2de14f3c6f7768c5ddb9f74f0595ec44acddd0. The next `mix deps.get` takes it into
                 mix.lock with premailex and Floki, which it depends on from 0.4.0: commit mix.lock with it,
                 and drop `only: :test` from a Floki of the project's own. From 0.3.0, a module that imports
                 EhosDesign.Components beside a `badge/1` of its own no longer compiles where it calls
                 `<.badge>`: remove the project's own, or import the components with `except: [badge: 1]`.
                 daisyUI's `.badge` takes the design system's look: `badge-success` is the live badge, and
                 every other colour and size the neutral one. The package's CHANGELOG.md, in
                 deps/ehos_design/packages/ehos_design/, says what else changed.
                 """
               ]
      end
    end

    test "changes nothing on a second run after moving ehos_design" do
      moved =
        installed()
        |> on_ehos_design("0.2.0", "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6")
        |> move()
        |> apply_igniter!()

      again = move(moved)

      assert_unchanged(again)
      assert notices_about(again, "ehos_design moved") == []
    end

    # 0.1.0's projects were given neither the components' templates as a source nor their hooks.
    test "gives a project it moves from 0.1.0's commit the components' source and hooks" do
      installed = installed()
      source = ~s|@source "../../deps/ehos_design/packages/ehos_design/lib";\n|
      hooks = ~s|import {hooks as designHooks} from "phoenix-colocated/ehos_design"\n|

      css = installed |> content("assets/css/app.css") |> String.replace(source, "")

      js =
        installed
        |> content("assets/js/app.js")
        |> String.replace(hooks, "")
        |> String.replace(", ...designHooks", "")

      again =
        installed
        |> replace_file("assets/css/app.css", css)
        |> replace_file("assets/js/app.js", js)
        |> on_ehos_design("0.1.0", "a65b9c86d920b5566f1c085b2286a44da77505c9")
        |> move()
        |> apply_igniter!()

      assert content(again, "assets/css/app.css") == content(installed, "assets/css/app.css")
      assert content(again, "assets/js/app.js") == content(installed, "assets/js/app.js")
    end

    # 0.2.0's projects were given both, so one that lacks them removed them.
    test "brings back no source or hooks removed from a project it moves from 0.2.0's commit" do
      installed = installed()
      source = ~s|@source "../../deps/ehos_design/packages/ehos_design/lib";\n|
      hooks = ~s|import {hooks as designHooks} from "phoenix-colocated/ehos_design"\n|
      css = installed |> content("assets/css/app.css") |> String.replace(source, "")

      js =
        installed
        |> content("assets/js/app.js")
        |> String.replace(hooks, "")
        |> String.replace(", ...designHooks", "")

      again =
        installed
        |> replace_file("assets/css/app.css", css)
        |> replace_file("assets/js/app.js", js)
        |> on_ehos_design("0.2.0", "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6")
        |> move()
        |> apply_igniter!()

      assert dep(again, :ehos_design) == @current_ehos_design
      assert content(again, "assets/css/app.css") == css
      assert content(again, "assets/js/app.js") == js
    end

    test "says what to add by hand when it keeps 0.1.0's commit beside a choice of the project's own" do
      own =
        {:ehos_design, "~> 0.1",
         [
           github: "EmpoweredHouse/ehos-tools",
           sparse: "packages/ehos_design",
           ref: "a65b9c86d920b5566f1c085b2286a44da77505c9"
         ]}

      install = installed() |> Igniter.Project.Deps.add_dep(own, yes?: true) |> move()

      assert dep(apply_igniter!(install), :ehos_design) == own

      assert install.warnings == [
               """
               ehos_design is on the commit an earlier ehos_app pinned, with a requirement or an option of
               the project's own, so it was left as it is. This ehos_app is written for its release
               0.5.0, commit 8b2de14f3c6f7768c5ddb9f74f0595ec44acddd0: move the `ref:` and the requirement
               by hand, keeping the rest. 0.1.0's projects were not given the components' templates as a source for Tailwind or their hooks: add `@source "../../deps/ehos_design/packages/ehos_design/lib";` after Phoenix's own in assets/css/app.css, and `import {hooks as designHooks} from "phoenix-colocated/ehos_design"` with `...designHooks` in the LiveSocket's `hooks:` in assets/js/app.js.
               """
             ]
    end

    test "keeps an earlier commit beside an option of the project's own, which a move would drop" do
      own =
        {:ehos_design, "~> 0.2.0",
         [
           github: "EmpoweredHouse/ehos-tools",
           sparse: "packages/ehos_design",
           ref: "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6",
           override: true
         ]}

      install = installed() |> Igniter.Project.Deps.add_dep(own, yes?: true) |> move()

      assert dep(apply_igniter!(install), :ehos_design) == own
      assert notices_about(install, "ehos_design moved") == []
      assert install.warnings == [@kept_earlier]
    end

    test "keeps an earlier commit beside a requirement of the project's own" do
      own =
        {:ehos_design, ">= 0.0.0",
         [
           github: "EmpoweredHouse/ehos-tools",
           sparse: "packages/ehos_design",
           ref: "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6"
         ]}

      install = installed() |> Igniter.Project.Deps.add_dep(own, yes?: true) |> move()

      assert dep(apply_igniter!(install), :ehos_design) == own
      assert install.warnings == [@kept_earlier]
    end

    test "keeps a commit of ehos_design the project chose, and says nothing of a move" do
      own =
        {:ehos_design, "~> 0.4.0",
         [
           github: "EmpoweredHouse/ehos-tools",
           sparse: "packages/ehos_design",
           ref: "0000000000000000000000000000000000000000"
         ]}

      install = installed() |> Igniter.Project.Deps.add_dep(own, yes?: true) |> move()

      assert dep(apply_igniter!(install), :ehos_design) == own
      assert notices_about(install, "ehos_design moved") == []
    end

    test "leaves a stylesheet without Tailwind's import alone, and says what to add" do
      install =
        phx_test_project()
        |> Igniter.update_file("assets/css/app.css", fn source ->
          Rewrite.Source.update(source, :content, fn _ -> "body { margin: 0; }\n" end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert install.warnings == [
               """
               The installer found no line in assets/css/app.css starting `@import "tailwindcss"` to put the
               design system's import after, so the design system was not imported. To use it, import
               its layer after Tailwind's, keep daisyUI's own themes off, and remove any daisyui-theme:

                   @import "../../deps/ehos_design/packages/ehos_design/priv/css/ehos_design.css";

               deps/ehos_design/packages/ehos_design/README.md says more.
               """
             ]

      installed = apply_igniter!(install)
      assert content(installed, "assets/css/app.css") == "body { margin: 0; }\n"

      development = content(installed, "DEVELOPMENT.md")

      assert passage(development, "**Assets**") == """
             - **Assets** are Phoenix's: `assets/` holds the application's stylesheet and script, which
               esbuild and Tailwind build from Mix. The design system comes from the `ehos_design` dependency,
               which `assets/css/app.css` does not import yet ([ARCHITECTURE.md](ARCHITECTURE.md)).
             """

      assert passage(development, "CI reads the private") == """
             CI reads the private `eh_os_contract` and `ehos_design`, and installs `ehosctl` from ehos-tools,
             with tokens of the GitHub App *ehos-tools CI*, installed on eh-os-contract and ehos-tools: the
             repository needs the secrets `EHOS_CI_APP_ID` and `EHOS_CI_APP_PRIVATE_KEY`, and its first run says
             so when they are missing. To build the image yourself, give Docker a
             GitHub token as a build secret, which reaches no layer of the image:
             """

      assert passage(content(installed, "ARCHITECTURE.md"), "The EmpoweredHouse design system") ==
               """
               `assets/` is Phoenix's asset pipeline: `app.css` and `app.js`, built by Tailwind and esbuild,
               which Mix installs and runs (`mix assets.build`), into `priv/static/`.
               The EmpoweredHouse design system is not copied there: it is the `ehos_design` dependency, whose
               fonts the endpoint serves from `/ehos_design/fonts/`. `assets/css/app.css` does
               not import it yet: the installer found no line there starting `@import "tailwindcss"` to put the
               import after. `deps/ehos_design/packages/ehos_design/README.md` says what to add to `app.css`,
               and which hooks to register in `assets/js/app.js`.
               A token is overridden at the end of `app.css`, and a later version arrives by moving the
               dependency.
               """

      assert passage(content(installed, "lib/test_web/AGENTS.md"), "**The UI follows") == """
             - **The UI follows the EmpoweredHouse design system** by default, from the `ehos_design`
               dependency: `assets/css/app.css` is to import it ([ARCHITECTURE.md](../../ARCHITECTURE.md)), and the endpoint serves its fonts. Build on
               `core_components.ex`, which it styles, and on its utilities (`bg-surface-1`,
               `text-fg-secondary`, `border-line-faint`) rather than Tailwind's own colours. Override a token
               at the end of `app.css`; `deps/ehos_design/packages/ehos_design/README.md` says how to replace the look.
             """
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
        assert dep(again, :ehos_design) == nil
        refute content(again, "lib/test_web/endpoint.ex") =~ "{:ehos_design"

        agents = content(again, "lib/test_web/AGENTS.md")

        assert passage(agents, "declined the EmpoweredHouse design system") == """
               - **The UI's look is this application's own**: it declined the EmpoweredHouse design system,
                 and `assets/css/app.css` says so above where its import was. Build on `core_components.ex` and
                 this application's own styles.
               """

        refute agents =~ "bg-surface-1"

        development = content(again, "DEVELOPMENT.md")

        assert passage(development, "CI reads the private") == """
               CI reads the private `eh_os_contract`, and installs `ehosctl` from ehos-tools,
               with tokens of the GitHub App *ehos-tools CI*, installed on eh-os-contract and ehos-tools: the
               repository needs the secrets `EHOS_CI_APP_ID` and `EHOS_CI_APP_PRIVATE_KEY`, and its first run says
               so when they are missing. To build the image yourself, give Docker a
               GitHub token as a build secret, which reaches no layer of the image:
               """

        assert passage(development, "a fine-grained token") == """
               `GITHUB_TOKEN` is best a fine-grained token that reads eh-os-contract alone, since
               every dependency's `mix.exs` runs where it is. Set it from where you keep it, a password manager's
               command line for one, rather than typing it, which leaves it in the shell's history.
               """
      end
    end

    test "without --example, adds no page" do
      igniter = installed()

      refute Igniter.exists?(igniter, "lib/test_web/live/design_system_live.ex")

      assert lines_through(
               content(igniter, "lib/test_web/router.ex"),
               ~s|  scope "/", TestWeb do|,
               "  end"
             ) ==
               """
                 scope "/", TestWeb do
                   pipe_through(:browser)

                   get("/", PageController, :home)
                 end
               """
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

  # The router after the installer runs with --example on Phoenix's, changed by `edit` first.
  defp with_router(edit) do
    phx_test_project()
    |> Igniter.update_file("lib/test_web/router.ex", &Rewrite.Source.update(&1, :content, edit))
    |> apply_igniter!()
    |> Igniter.compose_task("ehos_app.install", ["--example"])
    |> apply_igniter!()
    |> content("lib/test_web/router.ex")
  end

  # The notice that says `words`, whole.
  defp notice(igniter, words), do: Enum.find(igniter.notices, &String.contains?(&1, words))

  # The paragraph, list item, table row or code block of a Markdown file that holds `words`.
  defp passage(markdown, words) do
    markdown
    |> String.split("\n\n")
    |> Enum.flat_map(&String.split(&1, ~r/\n(?=- |\| )/))
    |> Enum.find(&String.contains?(&1, words))
    |> String.trim_trailing("\n")
    |> Kernel.<>("\n")
  end

  # The lines of `text` from the first that is `first` through the next that is `last`, or
  # through the end of `text` with `:end`.
  defp lines_through(text, first, last) do
    [^first | rest] = text |> String.split("\n") |> Enum.drop_while(&(&1 != first))
    Enum.join([first | through(rest, last)], "\n")
  end

  defp through(rest, :end), do: rest

  defp through(rest, last) do
    {inside, [^last | _]} = Enum.split_while(rest, &(&1 != last))
    inside ++ [last, ""]
  end

  # The project's `ehos_design` as an earlier ehos_app wrote it.
  defp on_ehos_design(igniter, release, ref) do
    Igniter.Project.Deps.add_dep(
      igniter,
      {:ehos_design, "~> #{release}",
       github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_design", ref: ref},
      yes?: true
    )
  end

  # The installer run again, its question about moving a dependency answered by `--yes`.
  defp move(igniter) do
    igniter
    |> apply_igniter!()
    |> Igniter.compose_task("ehos_app.install", ["--yes"])
  end
end

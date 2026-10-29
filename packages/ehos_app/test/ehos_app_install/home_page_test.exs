defmodule Mix.Tasks.EhosApp.InstallTest.HomePage do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "the home page and the access page" do
    @home "lib/test_web/controllers/page_html/home.html.heex"
    @page_test "test/test_web/controllers/page_controller_test.exs"
    @root "lib/test_web/components/layouts/root.html.heex"
    # Where Igniter puts the modules in its test project, which has its Phoenix extension; a
    # project `igniter.new` makes without one has them in `lib/<app>_web/` itself.
    @access_files [
      "lib/test_web/controllers/access_controller.ex",
      "lib/test_web/controllers/access_html.ex",
      "test/test_web/controllers/access_controller_test.exs"
    ]

    defp access_scopes(router),
      do:
        Regex.scan(
          ~r/scope "\/access", TestWeb do\s+pipe_through\(\[:browser, :signed_in\]\)\s+get\("\/", AccessController, :show\)\s+end/,
          router
        )

    defp edit(igniter, path, fun),
      do: Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, fun))

    test "replaces Phoenix's welcome page with the application's own, which leads to the access page" do
      home = installed() |> content(@home)

      refute home =~ "Peace of mind from prototype to production"
      assert home =~ ~s|<h1 class="eh-section-title">Test</h1>|
      assert home =~ ~s|known there as <span class="eh-record">test</span>|
      assert home =~ ~s|<.button id="home-access" href={~p"/access"} variant="primary">|
      # The way in and out stays where it is, at the top of the root layout, and only there.
      refute home =~ "sign_in_or_out"
      refute home =~ "/auth/ehos"
    end

    test "writes the access page behind :signed_in, in a scope of its own, with its test" do
      igniter = installed(["--example"])
      router = content(igniter, "lib/test_web/router.ex")

      assert [_one] = access_scopes(router)
      # The design system's page, appended to the scope for "/" later in the run, stays public.
      assert router =~
               ~r/pipe_through\(:browser\)\s+get\("\/", PageController, :home\)\s+live\("\/design-system", DesignSystemLive\)/

      controller = content(igniter, "lib/test_web/controllers/access_controller.ex")
      assert controller =~ "defmodule TestWeb.AccessController do"
      assert controller =~ "Session.actor(conn)"
      assert controller =~ ~s|put_resp_header("cache-control", "no-store")|

      # The page is inside the module, since no template file would follow it to where it is.
      html = content(igniter, "lib/test_web/controllers/access_html.ex")
      assert html =~ "def show(assigns) do"
      assert html =~ "What EHOS lets you do in Test"
      refute html =~ "embed_templates"

      test = content(igniter, "test/test_web/controllers/access_controller_test.exs")
      assert test =~ "defmodule TestWeb.AccessControllerTest do"
      assert test =~ ~s|"/auth/ehos/sign-in?return_to=%2Faccess"|
      assert test =~ ~s|"test.example"|
    end

    test "replaces Phoenix's test of its welcome page with one of the application's page" do
      test = installed() |> content(@page_test)

      assert test =~ "defmodule TestWeb.PageControllerTest do"
      refute test =~ "Peace of mind"
      assert test =~ ~s|a#home-access[href="/access"]|
    end

    test "names the application alone in the tab's title" do
      root = installed() |> content(@root)

      assert root =~ ~s|<.live_title default="Test" phx-no-format>|
      refute root =~ "Phoenix Framework"
    end

    test "keeps a title suffix of the application's own" do
      root =
        phx_test_project()
        |> edit(@root, &String.replace(&1, " · Phoenix Framework", " · Shop"))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content(@root)

      assert root =~ ~s|suffix=" · Shop"|
    end

    test "changes nothing on a second run, and brings back no access page the developer removed" do
      igniter = installed()

      igniter
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()

      removed =
        igniter
        |> then(
          &Enum.reduce(@access_files, &1, fn path, igniter -> Igniter.rm(igniter, path) end)
        )
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(&1, ~r/\n  scope "\/access".*?\n  end\n/s, "\n")
        )
        |> apply_igniter!()

      upgraded = removed |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      for path <- @access_files, do: refute(Igniter.exists?(upgraded, path), path)
      assert access_scopes(content(upgraded, "lib/test_web/router.ex")) == []
    end

    test "gives a project from an earlier version whose home page is still Phoenix's the new pages" do
      # Every earlier version wrote ehos.yaml; nothing else of theirs decides this.
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(igniter, @home) =~ "Peace of mind"
      assert [_one] = access_scopes(content(igniter, "lib/test_web/router.ex"))
    end

    test "leaves a home page the developer has changed, and adds no access page" do
      igniter =
        phx_test_project()
        |> edit(@home, &String.replace(&1, "Peace of mind", "Peace of mind, always,"))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(igniter, @home) =~ "Peace of mind, always,"
      assert content(igniter, @page_test) =~ "Peace of mind from prototype to production"
      for path <- @access_files, do: refute(Igniter.exists?(igniter, path), path)
      assert access_scopes(content(igniter, "lib/test_web/router.ex")) == []

      # The sections the installer keeps say nothing of a page the project does not have.
      for doc <- ["DEVELOPMENT.md", "ARCHITECTURE.md", "TESTING.md", "lib/test_web/AGENTS.md"],
          do: refute(content(igniter, doc) =~ "/access", doc)
    end

    test "says in the sections it keeps what the two pages are" do
      igniter = installed()

      assert content(igniter, "DEVELOPMENT.md") =~ "`/` is the application's home page"
      assert content(igniter, "ARCHITECTURE.md") =~ "pages that need a person, /access:"
      assert content(igniter, "TESTING.md") =~ "`TestWeb.AccessControllerTest`"

      assert content(igniter, "lib/test_web/AGENTS.md") =~
               "`AccessController`, which the template routed at `/access`"
    end

    test "keeps a test of the home page the developer has changed, and says what it looks for" do
      igniter =
        phx_test_project()
        |> edit(@page_test, &String.replace(&1, ~s|test "GET /"|, ~s|test "the home page"|))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "still looks for Phoenix's\nwelcome page"))
      assert igniter |> apply_igniter!() |> content(@page_test) =~ ~s|test "the home page"|
    end

    test "keeps a route the developer gave the access page" do
      router =
        installed()
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(
            &1,
            ~s|get("/", AccessController, :show)|,
            ~s|get("/me", AccessController, :show)|
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test_web/router.ex")

      assert [_one] = Regex.scan(~r/AccessController/, router)
    end

    # The new home page links to `~p"/access"`, which has to be the access page for the project
    # to compile with warnings as errors, and to lead anywhere.
    test "keeps Phoenix's page where the router serves /access already, read as code" do
      with_route = fn route ->
        phx_test_project()
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(
            &1,
            ~s|    get("/", PageController, :home)\n|,
            ~s|    get("/", PageController, :home)\n#{route}\n|
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
      end

      # A route split over lines counts; one at another path, or in a comment, does not.
      taken = with_route.(~s|    get "/access",\n      ReportController,\n      :index|)
      assert Enum.any?(taken.notices, &(&1 =~ "or a route at /access"))
      applied = apply_igniter!(taken)
      assert content(applied, @home) =~ "Peace of mind"
      assert access_scopes(content(applied, "lib/test_web/router.ex")) == []

      for route <- [~s|    get "/me", ReportController, :index|, ~s|    # get "/access", X, :y|] do
        applied = route |> with_route.() |> apply_igniter!()
        refute content(applied, @home) =~ "Peace of mind", route
        assert [_one] = access_scopes(content(applied, "lib/test_web/router.ex")), route
      end
    end

    # A project 0.5 to 0.10 made and nobody touched: the sign-in pipeline, the way in and out on
    # the root layout and Phoenix's welcome page, but no access page.
    test "gives a project an earlier version made, on Phoenix's page, both pages, once" do
      phoenix_home = phx_test_project() |> content(@home)
      phoenix_test = phx_test_project() |> content(@page_test)

      earlier =
        installed()
        |> then(
          &Enum.reduce(@access_files, &1, fn path, igniter -> Igniter.rm(igniter, path) end)
        )
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(&1, ~r/\n  scope "\/access".*?\n  end\n/s, "\n")
        )
        |> edit(@home, fn _ -> phoenix_home end)
        |> edit(@page_test, fn _ -> phoenix_test end)
        |> edit(
          @root,
          &String.replace(
            &1,
            ~s|default="Test"|,
            ~s|default="Test" suffix=" · Phoenix Framework"|
          )
        )
        |> apply_igniter!()

      assert content(earlier, "lib/test_web/router.ex") =~ "pipeline :signed_in"
      assert content(earlier, @root) =~ "sign_in_or_out"

      upgraded = earlier |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      refute content(upgraded, @home) =~ "Peace of mind"
      refute content(upgraded, @page_test) =~ "Peace of mind"
      refute content(upgraded, @root) =~ "Phoenix Framework"
      for path <- @access_files, do: assert(Igniter.exists?(upgraded, path), path)
      assert [_one] = access_scopes(content(upgraded, "lib/test_web/router.ex"))

      upgraded |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    test "replaces a CRLF copy of Phoenix's page, in its own line endings" do
      home =
        phx_test_project()
        |> edit(@home, &String.replace(&1, "\n", "\r\n"))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content(@home)

      refute home =~ "Peace of mind"
      assert home =~ ~s|id="home-access"|
      refute home =~ ~r/[^\r]\n/
    end

    test "says so when the home page has Phoenix's tagline but is not a page it knows" do
      igniter =
        phx_test_project()
        |> edit(@home, &(&1 <> "<p>Ours.</p>\n"))
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "is not the Phoenix welcome page"))
      assert igniter |> apply_igniter!() |> content(@home) =~ "<p>Ours.</p>"
    end

    test "keeps Phoenix's page where the project has an AccessController of its own" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("lib/test_web/somewhere/access.ex", """
        defmodule TestWeb.AccessController do
        end
        """)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "already has TestWeb.AccessController")
             )

      applied = apply_igniter!(igniter)
      assert content(applied, @home) =~ "Peace of mind"
      # Igniter keeps the developer's module where it puts modules; it is still theirs.
      for path <- Enum.drop(@access_files, 1), do: refute(Igniter.exists?(applied, path), path)
      refute content(applied, hd(@access_files)) =~ "Session.actor"
    end

    test "routes the page where another module of the same last name is routed" do
      router =
        phx_test_project()
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(
            &1,
            ~s|    get("/", PageController, :home)\n|,
            ~s|    get("/", PageController, :home)\n    get "/admin/access", Admin.AccessController, :show\n|
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test_web/router.ex")

      assert [_one] = access_scopes(router)
    end

    test "leaves Phoenix's welcome page, with a notice, where the router has no :signed_in pipeline" do
      # The session's plug is in a pipeline of the developer's name, so none is added.
      igniter =
        phx_test_project()
        |> edit(
          "lib/test_web/router.ex",
          &String.replace(
            &1,
            "  pipeline :api do",
            "  pipeline :person do\n    plug(EhOsContract.Auth.Session)\n  end\n\n  pipeline :api do"
          )
        )
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "still Phoenix's welcome page"))
      assert igniter |> apply_igniter!() |> content(@home) =~ "Peace of mind"
    end
  end
end

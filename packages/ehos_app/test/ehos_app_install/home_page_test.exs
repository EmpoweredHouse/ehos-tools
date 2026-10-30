defmodule Mix.Tasks.EhosApp.InstallTest.HomePage do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  @home "lib/test_web/controllers/page_html/home.html.heex"
  @page_test "test/test_web/controllers/page_controller_test.exs"
  @root "lib/test_web/components/layouts/root.html.heex"
  @router "lib/test_web/router.ex"
  # Where Igniter puts the modules in its test project, which has its Phoenix extension; a
  # project `igniter.new` makes without one has them in `lib/<app>_web/` itself.
  @access_files [
    "lib/test_web/controllers/access_controller.ex",
    "lib/test_web/controllers/access_html.ex",
    "test/test_web/controllers/access_controller_test.exs"
  ]

  # What the page reads, as a behaviour of the application's (T-20), with its test.
  @behaviour_files ["lib/test/access.ex", "test/test/access_test.exs"]

  # The application's own home page, which leads to the access page. The way in and out is not
  # on it: it is at the top of the root layout, and only there.
  @application_home ~S"""
  <Layouts.flash_group flash={@flash} />
  <%!--
    The application's home page, which ehos_app wrote in place of Phoenix's welcome page. It is the
    application's own: say what it does for the people who open it. The way in and out, signing in
    through EHOS and signing out, is at the top of the root layout, on every page.
  --%>
  <main id="home" class="px-4 py-20 sm:px-6 lg:px-8">
    <div class="mx-auto max-w-2xl space-y-6">
      <p class="eh-eyebrow">An application on EHOS</p>
      <h1 class="eh-section-title">Test</h1>
      <p class="eh-lede text-fg-secondary">
        Test runs on EHOS, known there as <span class="eh-record">test</span>.
        People sign in to it through EHOS, and what each of them may do here is what the roles
        bound to them in EHOS grant.
      </p>
      <p class="eh-body text-fg-secondary">
        Sign in with the button at the top of the page. Your access shows who you are signed in as
        and what you may do here; EHOS asks you to sign in first if you have not.
      </p>
      <div class="flex flex-wrap gap-3">
        <.button id="home-access" href={~p"/access"} variant="primary">Your access</.button>
      </div>
    </div>
  </main>
  """

  @application_page_test ~S"""
  defmodule TestWeb.PageControllerTest do
    use TestWeb.ConnCase, async: true

    test "the home page is the application's own, and leads to the access page", %{conn: conn} do
      document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query(~s|a#home-access[href="/access"]|) |> Enum.any?()
      refute document |> LazyHTML.query("title") |> LazyHTML.text() =~ "Phoenix Framework"
    end
  end
  """

  @access_scope """
    scope "/access", TestWeb do
      pipe_through([:browser, :signed_in])

      get("/", AccessController, :show)
    end
  """

  @title ~s|    <.live_title default="Test" phx-no-format>{assigns[:page_title]}</.live_title>|

  describe "the home page and the access page" do
    test "replaces Phoenix's welcome page with the application's own, which leads to the access page" do
      assert installed() |> content(@home) == @application_home
    end

    test "writes the access page behind :signed_in, in a scope of its own, with its test" do
      igniter = installed(["--example"])
      router = content(igniter, @router)

      assert access_scopes(router) == [@access_scope]

      # The design system's page, appended to the scope for "/" later in the run, stays public.
      assert sections(router, ~s|  scope "/", TestWeb do|, "  end") == [
               """
                 scope "/", TestWeb do
                   pipe_through(:browser)

                   get("/", PageController, :home)
                   live("/design-system", DesignSystemLive)
                 end
               """
             ]

      controller = content(igniter, "lib/test_web/controllers/access_controller.ex")
      assert lines_with(controller, "defmodule") == ["defmodule TestWeb.AccessController do"]
      assert lines_with(controller, "Session.actor(") == ["    case Session.actor(conn) do"]

      assert lines_with(controller, "cache-control") == [
               ~s/        |> put_resp_header("cache-control", "no-store")/
             ]

      # The page is inside the module, since no template file would follow it to where it is.
      html = content(igniter, "lib/test_web/controllers/access_html.ex")
      assert lines_with(html, "def show(") == ["  def show(assigns) do"]

      assert lines_with(html, "What EHOS lets you do") == [
               "            What EHOS lets you do in Test, by the roles bound to you there."
             ]

      refute html =~ "embed_templates"

      test = content(igniter, "test/test_web/controllers/access_controller_test.exs")
      assert lines_with(test, "defmodule") == ["defmodule TestWeb.AccessControllerTest do"]

      assert lines_with(test, "return_to=%2Faccess") == [
               ~s|    assert redirected_to(conn, 302) == "/auth/ehos/sign-in?return_to=%2Faccess"|
             ]

      assert lines_with(test, ~s|"test.example"|) == [~s|      name: "test.example",|]
    end

    test "has the page say what the person may do through Test.Access, a behaviour mocked in tests" do
      igniter = installed()

      controller = content(igniter, "lib/test_web/controllers/access_controller.ex")

      assert lines_with(controller, "Access.current()") == [
               "        |> render(:show, Access.current().of(actor))"
             ]

      refute controller =~ "def access("

      access = content(igniter, "lib/test/access.ex")

      assert lines_with(access, "defmodule") == [
               "defmodule Test.Access do",
               "defmodule Test.AccessImpl do"
             ]

      assert lines_with(access, "@callback") == ["  @callback of(actor :: %Actor{}) :: t()"]

      assert lines_with(content(igniter, "test/test/access_test.exs"), "Hammox.Protect") == [
               "  use Hammox.Protect, module: Test.AccessImpl, behaviour: Test.Access"
             ]

      assert lines_with(content(igniter, "config/config.exs"), "Test.Access,") == [
               "config :test, Test.Access, impl: Test.AccessImpl"
             ]

      assert lines_with(content(igniter, "config/test.exs"), "Test.Access,") == [
               "config :test, Test.Access, impl: Test.AccessMock"
             ]

      assert lines_with(content(igniter, "test/support/mocks.ex"), "AccessMock") == [
               "  Hammox.defmock(Test.AccessMock, for: Test.Access)"
             ]
    end

    test "keeps Phoenix's page where the project has a Test.Access of its own" do
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("lib/test/access.ex", """
        defmodule Test.Access do
        end
        """)
        |> install_on()
        |> apply_igniter!()

      assert content(igniter, @home) == content(phx_test_project(), @home)
      assert content(igniter, "lib/test/access.ex") == "defmodule Test.Access do\nend\n"
      refute Igniter.exists?(igniter, "lib/test_web/controllers/access_controller.ex")
      refute content(igniter, "test/support/mocks.ex") =~ "AccessMock"
    end

    test "replaces Phoenix's test of its welcome page with one of the application's page" do
      assert installed() |> content(@page_test) == @application_page_test
    end

    test "names the application alone in the tab's title" do
      assert installed() |> content(@root) |> lines_with("<.live_title") == [@title]
    end

    test "gives a project from an earlier version whose home page is still Phoenix's the new pages" do
      # Every earlier version wrote ehos.yaml; nothing else of theirs decides this.
      igniter =
        phx_test_project()
        |> Igniter.create_new_file("ehos.yaml", "schema: ehos.yaml/v2\n")
        |> install_on()
        |> apply_igniter!()

      assert content(igniter, @home) == @application_home
      assert igniter |> content(@router) |> access_scopes() == [@access_scope]
    end

    # A project 0.5 to 0.10 made and nobody touched: the sign-in pipeline, the way in and out on
    # the root layout and Phoenix's welcome page, but no access page.
    test "gives a project an earlier version made, on Phoenix's page, both pages, once" do
      phoenix = phx_test_project()

      earlier =
        installed()
        |> without_access_page()
        |> replace_file(@home, content(phoenix, @home))
        |> replace_file(@page_test, content(phoenix, @page_test))
        |> edit_file(
          @root,
          &String.replace(
            &1,
            ~s|default="Test"|,
            ~s|default="Test" suffix=" · Phoenix Framework"|
          )
        )
        |> apply_igniter!()

      assert earlier |> content(@router) |> lines_with("pipeline :signed_in") == [
               "  pipeline :signed_in do"
             ]

      assert earlier |> content(@root) |> lines_with("sign_in_or_out") == [
               "    <TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
             ]

      upgraded = earlier |> Igniter.compose_task("ehos_app.install", []) |> apply_igniter!()

      assert content(upgraded, @home) == @application_home
      assert content(upgraded, @page_test) == @application_page_test
      assert upgraded |> content(@root) |> lines_with("<.live_title") == [@title]

      for path <- @access_files ++ @behaviour_files,
          do: assert(Igniter.exists?(upgraded, path), path)

      assert upgraded |> content(@router) |> access_scopes() == [@access_scope]

      # Its mocks module is its own: the access page's mock goes at its end.
      assert upgraded |> content("test/support/mocks.ex") |> lines_with("AccessMock") == [
               "  Hammox.defmock(Test.AccessMock, for: Test.Access)"
             ]

      assert upgraded
             |> content("test/support/mocks.ex")
             |> String.ends_with?("""
               Hammox.defmock(Test.AccessMock, for: Test.Access)
             end
             """)

      upgraded |> Igniter.compose_task("ehos_app.install", []) |> assert_unchanged()
    end

    test "replaces a CRLF copy of Phoenix's page, in its own line endings" do
      home =
        phx_test_project()
        |> edit_file(@home, &String.replace(&1, "\n", "\r\n"))
        |> install_on()
        |> apply_igniter!()
        |> content(@home)

      assert home == String.replace(@application_home, "\n", "\r\n")
    end

    test "says in the sections it keeps what the two pages are" do
      igniter = installed()

      assert igniter |> content("DEVELOPMENT.md") |> lines_with("is the application's home page") ==
               [
                 "  behind `:signed_in` cannot be reached. `/` is the application's home page, which the template"
               ]

      assert igniter |> content("ARCHITECTURE.md") |> lines_with("pages that need a person") == [
               "          │ pages that need a person, /access: pipeline :signed_in ── EhOsContract.Auth.Session"
             ]

      assert igniter |> content("TESTING.md") |> lines_with("`TestWeb.AccessControllerTest`") ==
               [
                 "- `TestWeb.AccessControllerTest`: `/access` sends a visitor to sign in",
                 "  `TestWeb.AccessControllerTest` goes through the real sign-in, a visitor's case included."
               ]

      assert igniter |> content("lib/test_web/AGENTS.md") |> lines_with("`AccessController`") == [
               "  `AccessController`, which the template routed at `/access`, is such a page."
             ]
    end

    test "routes the page where another module of the same last name is routed" do
      router =
        phx_test_project()
        |> edit_file(
          @router,
          &String.replace(
            &1,
            ~s|    get("/", PageController, :home)\n|,
            ~s|    get("/", PageController, :home)\n    get "/admin/access", Admin.AccessController, :show\n|
          )
        )
        |> install_on()
        |> apply_igniter!()
        |> content(@router)

      assert access_scopes(router) == [@access_scope]
    end

    test "keeps a title suffix of the application's own" do
      root =
        phx_test_project()
        |> edit_file(@root, &String.replace(&1, " · Phoenix Framework", " · Shop"))
        |> install_on()
        |> apply_igniter!()
        |> content(@root)

      assert lines_with(root, "<.live_title") == [
               ~s|    <.live_title default="Test" suffix=" · Shop" phx-no-format>{assigns[:page_title]}</.live_title>|
             ]
    end

    test "changes nothing on a second run, and brings back no access page the developer removed" do
      igniter = installed()

      igniter
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()

      upgraded = igniter |> without_access_page() |> install_on() |> apply_igniter!()

      for path <- @access_files, do: refute(Igniter.exists?(upgraded, path), path)
      assert upgraded |> content(@router) |> access_scopes() == []
    end

    test "leaves a home page the developer has changed, and adds no access page" do
      theirs =
        phx_test_project()
        |> edit_file(@home, &String.replace(&1, "Peace of mind", "Peace of mind, always,"))

      igniter = theirs |> install_on() |> apply_igniter!()

      assert content(igniter, @home) == content(theirs, @home)
      assert content(igniter, @page_test) == content(theirs, @page_test)
      for path <- @access_files, do: refute(Igniter.exists?(igniter, path), path)
      assert igniter |> content(@router) |> access_scopes() == []

      # The sections the installer keeps say nothing of a page the project does not have.
      for doc <- ["DEVELOPMENT.md", "ARCHITECTURE.md", "TESTING.md", "lib/test_web/AGENTS.md"],
          do: refute(content(igniter, doc) =~ "/access", doc)
    end

    test "keeps a route the developer gave the access page" do
      router =
        installed()
        |> edit_file(
          @router,
          &String.replace(
            &1,
            ~s|get("/", AccessController, :show)|,
            ~s|get("/me", AccessController, :show)|
          )
        )
        |> install_on()
        |> apply_igniter!()
        |> content(@router)

      assert lines_with(router, "AccessController") == [
               ~s|    get("/me", AccessController, :show)|
             ]
    end

    # The new home page links to `~p"/access"`, which has to be the access page for the project
    # to compile with warnings as errors, and to lead anywhere.
    test "keeps Phoenix's page where the router serves /access already, read as code" do
      phoenix_home = phx_test_project() |> content(@home)

      # A route split over lines counts; one at another path, or in a comment, does not.
      taken = with_route(~s|    get "/access",\n      ReportController,\n      :index|)

      assert notices_about(taken, "route at /access, which") == [
               """
               #{@home} is still Phoenix's welcome page. It was left as it is because the project
               already has TestWeb.AccessController, TestWeb.AccessHTML, Test.Access or a
               route at /access, which the page that replaces it would need for its own. Give the
               application's home page its own content.
               """
             ]

      applied = apply_igniter!(taken)
      assert content(applied, @home) == phoenix_home
      assert applied |> content(@router) |> access_scopes() == []

      for route <- [~s|    get "/me", ReportController, :index|, ~s|    # get "/access", X, :y|] do
        applied = route |> with_route() |> apply_igniter!()
        assert content(applied, @home) == @application_home, route
        assert applied |> content(@router) |> access_scopes() == [@access_scope], route
      end
    end

    test "keeps Phoenix's page where the project has an AccessController of its own" do
      phoenix_home = phx_test_project() |> content(@home)

      igniter =
        phx_test_project()
        |> Igniter.create_new_file("lib/test_web/somewhere/access.ex", """
        defmodule TestWeb.AccessController do
        end
        """)
        |> install_on()

      assert notices_about(igniter, "already has TestWeb.AccessController") == [
               """
               #{@home} is still Phoenix's welcome page. It was left as it is because the project
               already has TestWeb.AccessController, TestWeb.AccessHTML, Test.Access or a
               route at /access, which the page that replaces it would need for its own. Give the
               application's home page its own content.
               """
             ]

      applied = apply_igniter!(igniter)
      assert content(applied, @home) == phoenix_home
      # Igniter keeps the developer's module where it puts modules; it is still theirs.
      for path <- Enum.drop(@access_files, 1), do: refute(Igniter.exists?(applied, path), path)

      assert content(applied, hd(@access_files)) == """
             defmodule TestWeb.AccessController do
             end
             """
    end

    test "keeps a test of the home page the developer has changed, and says what it looks for" do
      theirs =
        phx_test_project()
        |> edit_file(@page_test, &String.replace(&1, ~s|test "GET /"|, ~s|test "the home page"|))

      igniter = install_on(theirs)

      assert notices_about(igniter, "still looks for Phoenix's") == [
               """
               The home page is the application's own now, and #{@page_test} still looks for Phoenix's
               welcome page: assert what the new page shows instead, as a new project's test does.
               """
             ]

      assert igniter |> apply_igniter!() |> content(@page_test) == content(theirs, @page_test)
    end

    test "says so when the home page has Phoenix's tagline but is not a page it knows" do
      theirs = phx_test_project() |> edit_file(@home, &(&1 <> "<p>Ours.</p>\n"))
      igniter = install_on(theirs)

      assert notices_about(igniter, "is not the Phoenix welcome page") == [
               """
               #{@home} still says "Peace of mind from prototype to production", but is not the Phoenix welcome page
               this version of ehos_app recognises, so it was left as it is. Give the application's
               home page its own content; ehos_app's CHANGELOG says how to add the access page a new
               project links to from there.
               """
             ]

      assert igniter |> apply_igniter!() |> content(@home) == content(theirs, @home)
    end

    test "leaves Phoenix's welcome page, with a notice, where the router has no :signed_in pipeline" do
      phoenix_home = phx_test_project() |> content(@home)

      # The session's plug is in a pipeline of the developer's name, so none is added.
      igniter =
        phx_test_project()
        |> edit_file(
          @router,
          &String.replace(
            &1,
            "  pipeline :api do",
            "  pipeline :person do\n    plug(EhOsContract.Auth.Session)\n  end\n\n  pipeline :api do"
          )
        )
        |> install_on()

      assert notices_about(igniter, "still Phoenix's welcome page") == [
               """
               #{@home} is still Phoenix's welcome page. It was left as it is because the router has
               no `:signed_in` pipeline, which the page that replaces it links to. Add
               `pipeline :signed_in do plug EhOsContract.Auth.Session end` to the router and run the
               installer again.
               """
             ]

      assert igniter |> apply_igniter!() |> content(@home) == phoenix_home
    end
  end

  # A project an earlier version made, from `igniter` as the installer wrote it: no access page,
  # no test of it and no route to it.
  defp without_access_page(igniter) do
    without_access =
      &String.replace(
        &1,
        ~r/\n *(config :test, Test\.Access,|Hammox\.defmock\(Test\.AccessMock).*\n/,
        "\n"
      )

    (@access_files ++ @behaviour_files)
    |> Enum.reduce(igniter, &Igniter.rm(&2, &1))
    |> edit_file(@router, &String.replace(&1, ~r/\n  scope "\/access".*?\n  end\n/s, "\n"))
    |> edit_file("config/config.exs", without_access)
    |> edit_file("config/test.exs", without_access)
    |> edit_file("test/support/mocks.ex", without_access)
  end

  # The installer run on Phoenix's project with `route` under its route for "/".
  defp with_route(route) do
    phx_test_project()
    |> edit_file(
      @router,
      &String.replace(
        &1,
        ~s|    get("/", PageController, :home)\n|,
        ~s|    get("/", PageController, :home)\n#{route}\n|
      )
    )
    |> install_on()
  end

  defp access_scopes(router), do: sections(router, ~s|  scope "/access"|, "  end")
end

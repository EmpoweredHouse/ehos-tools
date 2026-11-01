defmodule Mix.Tasks.EhosApp.InstallTest.SignIn do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # The way in and out as 0.4 generated it, for `TestWeb`, formatted as Igniter writes it. Not
  # `.ex`, which `mix test` would warn matches no test file.
  @sign_in_components_04 File.read!("test/fixtures/sign_in_components_0.4.ex.txt")

  @endpoint "lib/test_web/endpoint.ex"
  @router "lib/test_web/router.ex"
  @root "lib/test_web/components/layouts/root.html.heex"
  @home "lib/test_web/controllers/page_html/home.html.heex"
  @components "lib/test_web/sign_in_components.ex"
  @call "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
  @flash "<Layouts.flash_group flash={@flash} />\n"

  # The root layout's body with the way in and out at its top, as a new project has it.
  @body_with_call """
    <body>
      <TestWeb.SignInComponents.sign_in_or_out conn={@conn} />
      {@inner_content}
    </body>
  """

  @body_without_call """
    <body>
      {@inner_content}
    </body>
  """

  # The component's div out of 0.4's corner, rendered whether or not the session was fetched,
  # and the same div rendered only where it was.
  @div ~s|    <div id="sign-in-or-out" class="relative z-10 flex justify-end px-4 py-2 sm:px-6 lg:px-8">|
  @guarded_div ~s|    <div :if={@session?} id="sign-in-or-out" class="relative z-10 flex justify-end px-4 py-2 sm:px-6 lg:px-8">|
  @developers_guard "        Map.has_key?(assigns.conn.private, :plug_session) and"

  # The way in and out as a new project renders it, guarded against a conn whose session was
  # never fetched.
  @guarded_sign_in_or_out ~S'''
    def sign_in_or_out(assigns) do
      # `get_session/2` raises on a conn whose session was never fetched.
      session? = Map.has_key?(assigns.conn.private, :plug_session)

      assigns =
        assigns
        |> assign(:session?, session?)
        |> assign(
          :signed_in?,
          session? and Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil
        )

      ~H"""
      <div :if={@session?} id="sign-in-or-out" class="relative z-10 flex justify-end px-4 py-2 sm:px-6 lg:px-8">
        <.form :if={@signed_in?} id="sign-out" for={%{}} action="/auth/ehos/sign-out" method="post">
          <button type="submit" class="btn btn-sm">Sign out</button>
        </.form>
        <.link :if={!@signed_in?} id="sign-in" href="/auth/ehos/sign-in" class="btn btn-sm btn-primary">
          Sign in
        </.link>
      </div>
      """
    end
  '''

  describe "signing people in through EHOS" do
    test "starts the client only where it is configured, so development and tests start none" do
      sign_in = installed() |> content("lib/test/sign_in.ex")

      assert sections(sign_in, "  def child_spec(opts) do", "  end") == [
               """
                 def child_spec(opts) do
                   if Application.get_env(:eh_os_contract_auth, :sign_in) do
                     EhOsContract.Auth.SignIn.child_spec(opts)
                   else
                     %{id: EhOsContract.Auth.SignIn, start: {__MODULE__, :start_link, [opts]}}
                   end
                 end
               """
             ]

      # Unconfigured, as in ehos_app's own tests, the child starts nothing. The package is not a
      # dependency here, so the compiler's warning that its module is missing is kept quiet.
      {[{module, _}], _missing_package} =
        Code.with_diagnostics(fn -> Code.compile_string(sign_in) end)

      assert module.child_spec([]) ==
               %{id: EhOsContract.Auth.SignIn, start: {module, :start_link, [[]]}}

      assert module.start_link([]) == :ignore
    end

    test "encrypts the cookie session, which holds the sign-in's state between redirect and callback" do
      [options] = installed() |> content(@endpoint) |> sections("  @session_options [", "  ]")

      # Both salts are random; the encryption salt is eight characters, as Phoenix's own.
      [[signing_salt], [encryption_salt]] =
        Regex.scan(~r/_salt: "(.*)"/, options, capture: :all_but_first)

      assert encryption_salt =~ ~r/\A[A-Za-z0-9+\/]{8}\z/

      assert options == """
               @session_options [
                 store: :cookie,
                 key: "_test_key",
                 signing_salt: "#{signing_salt}",
                 same_site: "Lax",
                 encryption_salt: "#{encryption_salt}",
                 secure: Application.compile_env(:test, [__MODULE__, :secure_session], false)
               ]
             """
    end

    @tag :tmp_dir
    test "marks the session cookie Secure in production, whatever scheme reaches the endpoint", %{
      tmp_dir: tmp_dir
    } do
      igniter = installed()

      assert igniter |> content(@endpoint) |> lines_with("secure:") == [
               "    secure: Application.compile_env(:test, [__MODULE__, :secure_session], false)"
             ]

      assert get_in(read_config(igniter, :prod, tmp_dir), [
               :test,
               TestWeb.Endpoint,
               :secure_session
             ]) ==
               true

      assert get_in(read_config(igniter, :dev, tmp_dir), [
               :test,
               TestWeb.Endpoint,
               :secure_session
             ]) ==
               nil
    end

    # One test per case, so each runs the installer once within ExUnit's timeout for a test.
    for {what, theirs, secure} <- [
          {"replaces a session cookie set never to be Secure", "false",
           "Application.compile_env(:test, [__MODULE__, :secure_session], false)"},
          {"keeps a session cookie set always to be Secure", "true", "true"},
          {"keeps a session cookie made Secure by an expression of the project's own",
           ~s|System.get_env("X") == "1"|, ~s|System.get_env("X") == "1"|}
        ] do
      test what do
        endpoint =
          phx_test_project()
          |> edit_file(
            @endpoint,
            &String.replace(
              &1,
              ~s|same_site: "Lax"|,
              ~s|same_site: "Lax",\n    secure: #{unquote(theirs)}|
            )
          )
          |> install_on()
          |> apply_igniter!()
          |> content(@endpoint)

        assert lines_with(endpoint, "secure:") == ["    secure: #{unquote(secure)},"]
      end
    end

    test "serves signing in and out under /auth/ehos, behind the browser's session and CSRF protection" do
      router = installed() |> content(@router)

      assert sections(router, ~s|  scope "/auth" do|, "  end") == [
               """
                 scope "/auth" do
                   pipe_through(:browser)

                   forward("/ehos", EhOsContract.Auth.SignIn.Router)
                 end
               """
             ]

      assert sections(router, "  pipeline :signed_in do", "  end") == [
               """
                 pipeline :signed_in do
                   plug(EhOsContract.Auth.Session)
                 end
               """
             ]
    end

    test "offers a way in and out at the top of the root layout, which every page renders, and tests it" do
      igniter = installed()

      assert body(igniter) == [@body_with_call]
      refute content(igniter, @home) =~ "sign_in_or_out"

      components = content(igniter, @components)
      assert lines_with(components, "defmodule") == ["defmodule TestWeb.SignInComponents do"]

      # Out of the corner 0.4 fixed it in, in the page's flow.
      assert sections(components, "    <div", "    </div>") == [
               """
               #{@guarded_div}
                     <.form :if={@signed_in?} id="sign-out" for={%{}} action="/auth/ehos/sign-out" method="post">
                       <button type="submit" class="btn btn-sm">Sign out</button>
                     </.form>
                     <.link :if={!@signed_in?} id="sign-in" href="/auth/ehos/sign-in" class="btn btn-sm btn-primary">
                       Sign in
                     </.link>
                   </div>
               """
             ]

      test = content(igniter, "test/test_web/sign_in_test.exs")
      assert lines_with(test, "defmodule") == ["defmodule TestWeb.SignInTest do"]
      assert lines_with(test, "  use ") == ["  use TestWeb.ConnCase, async: true"]

      # It renders the root layout, not a page, so replacing the home page leaves it as it is.
      assert sections(test, "  defp root_layout(conn) do", "  end") == [
               """
                 defp root_layout(conn) do
                   render_component(&TestWeb.Layouts.root/1, conn: conn, inner_content: "")
                   |> LazyHTML.from_document()
                 end
               """
             ]

      refute test =~ ~s|get(~p"/")|
    end

    test "moves the way in and out from the home page 0.4 put it on to the root layout" do
      installed = installed()
      home = content(installed, @home)
      as_04 = at_04(installed, @sign_in_components_04)

      assert body(as_04) == [@body_without_call]

      upgraded =
        as_04
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert body(upgraded) == [@body_with_call]
      assert content(upgraded, @home) == home

      # 0.4's component is given the new one's guard and its place in the page's flow; what
      # else it says is left as it was.
      [sign_in_or_out_04] =
        sections(@sign_in_components_04, "  def sign_in_or_out(assigns) do", "  end")

      component = content(upgraded, @components)

      assert component ==
               String.replace(@sign_in_components_04, sign_in_or_out_04, @guarded_sign_in_or_out)

      assert {:ok, _} = Code.string_to_quoted(component)

      upgraded
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "takes 0.4's line off the home page when the developer has put the call on the root too" do
      installed = installed()
      home = content(installed, @home)

      upgraded =
        installed
        |> edit_file(@home, &String.replace(&1, @flash, @flash <> @call <> "\n"))
        |> replace_file(@components, @sign_in_components_04)
        |> install_on()
        |> apply_igniter!()

      assert body(upgraded) == [@body_with_call]
      assert content(upgraded, @home) == home

      # 0.4's component, now on every page, gets the guard here too.
      assert upgraded |> content(@components) |> sections("  def sign_in_or_out", "  end") ==
               [@guarded_sign_in_or_out]

      upgraded
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "moves the line 0.4 wrote from a CRLF home page too" do
      installed = installed()
      home = content(installed, @home)

      upgraded =
        installed
        |> edit_file(@root, &String.replace(&1, "    " <> @call <> "\n", ""))
        |> edit_file(@home, fn content ->
          content
          |> String.replace(@flash, @flash <> @call <> "\n")
          |> String.replace("\n", "\r\n")
        end)
        |> install_on()
        |> apply_igniter!()

      assert body(upgraded) == [@body_with_call]
      assert content(upgraded, @home) == String.replace(home, "\n", "\r\n")
    end

    test "conditions 0.4's div on the session? its own function assigns, in a pipe" do
      own =
        String.replace(
          @sign_in_components_04,
          ~r/assigns =\s*assign\(\s*assigns,\s*:signed_in\?,[^)]*\)\) != nil\s*\)/,
          """
          session? = Map.has_key?(assigns.conn.private, :plug_session)

              assigns =
                assigns
                |> assign(:session?, session?)
                |> assign(:signed_in?, session? and Plug.Conn.get_session(assigns.conn, :ehos) != nil)\
          """
        )

      assert own != @sign_in_components_04

      component = own |> as_04() |> apply_igniter!() |> content(@components)

      assert lines_with(component, "<div") == [@guarded_div]
    end

    test "guards a CRLF 0.4 component in its own line endings" do
      component =
        @sign_in_components_04
        |> String.replace("\n", "\r\n")
        |> as_04()
        |> apply_igniter!()
        |> content(@components)

      assert sections(component, "  def sign_in_or_out(assigns) do", "  end") ==
               [String.replace(@guarded_sign_in_or_out, "\n", "\r\n")]

      refute component =~ ~r/[^\r]\n/
    end

    test "keeps an encryption salt the project has" do
      endpoint =
        phx_test_project()
        |> edit_file(
          @endpoint,
          &String.replace(
            &1,
            ~s|same_site: "Lax"|,
            ~s|same_site: "Lax",\n    encryption_salt: "theirs00"|
          )
        )
        |> install_on()
        |> apply_igniter!()
        |> content(@endpoint)

      assert lines_with(endpoint, "encryption_salt:") == [~s|    encryption_salt: "theirs00",|]
    end

    test "puts the way in and out on the root layout once, and leaves it where the developer moves it" do
      moved =
        installed()
        |> edit_file(@root, &String.replace(&1, "    " <> @call <> "\n", ""))
        |> install_on()
        |> apply_igniter!()

      assert body(moved) == [@body_without_call]
      refute content(moved, @home) =~ @call
    end

    test "leaves a 0.4 component the developer guarded their own way out of the corner alone" do
      own =
        String.replace(
          @sign_in_components_04,
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Map.has_key?(assigns.conn.private, :plug_session) and\n" <>
            "          Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil"
        )

      igniter = installed() |> at_04(own) |> Igniter.compose_task("ehos_app.install", [])
      component = igniter |> apply_igniter!() |> content(@components)

      # Moved out of the corner, and the developer's guard kept, with no `@session?` of the
      # installer's beside it.
      assert lines_with(component, "<div") == [@div]
      assert lines_with(component, "plug_session") == [@developers_guard]
      assert lines_with(component, "session?") == []
      assert notices_about(igniter, "guard it as a new project's") == []
    end

    test "does not take another function's session? for the one 0.4's component renders" do
      elsewhere =
        @sign_in_components_04
        |> String.replace(
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Plug.Conn.get_session(assigns.conn, :ehos) != nil"
        )
        |> String.replace(
          ~r/\nend\s*\z/,
          "\n\n  def other(assigns), do: assigns |> assign(:session?, true)\nend\n"
        )

      refute elsewhere =~ "Session.session_key()) != nil"

      assert lines_with(elsewhere, "def other") == [
               "  def other(assigns), do: assigns |> assign(:session?, true)"
             ]

      component = elsewhere |> as_04() |> apply_igniter!() |> content(@components)

      assert lines_with(component, "<div") == [@div]
    end

    test "does not take :session? given as a value for an assign of it" do
      as_value =
        String.replace(
          @sign_in_components_04,
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Plug.Conn.get_session(assigns.conn, :ehos) != nil) |> assign(:mode, :session?"
        )

      assert as_value != @sign_in_components_04

      component = as_value |> as_04() |> apply_igniter!() |> content(@components)

      assert lines_with(component, "<div") == [@div]
    end

    # One test per comment, so each runs the installer once within ExUnit's timeout for a test.
    for {how, commented} <- [
          {"a HEEx comment", "<%!-- #{@call} --%>"},
          {"an HTML comment", "<!-- #{@call} -->"},
          {"an EEx comment", "<%# #{@call} %>"}
        ] do
      test "keeps 0.4's line on the home page when the root holds the call in #{how} alone" do
        commented = unquote(commented)

        igniter =
          installed()
          |> edit_file(@root, &String.replace(&1, @call, commented))
          |> edit_file(@home, &String.replace(&1, @flash, @flash <> @call <> "\n"))
          |> install_on()

        assert notices_about(igniter, "commented out") == [
                 """
                 The way in and out is on #{@home}, and commented out on #{@root}, so both were left as
                 they are. An application's first page of its own replaces the home page, and the
                 link with it: uncomment `#{@call}` on #{@root}, and the next run takes it off
                 #{@home}.
                 """
               ],
               commented

        applied = apply_igniter!(igniter)
        assert applied |> content(@home) |> lines_with(@call) == [@call], commented

        assert body(applied) == ["  <body>\n    #{commented}\n    {@inner_content}\n  </body>\n"],
               commented
      end
    end

    test "says what to guard in a 0.4 component the developer changed, when it moves it" do
      changed =
        String.replace(
          @sign_in_components_04,
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Plug.Conn.get_session(assigns.conn, :ehos) != nil"
        )

      igniter = as_04(changed)

      assert notices_about(igniter, "guard it as a new project's") == [
               """
               #{@components} calls `get_session/2`, which raises on a conn whose session was never
               fetched, and it was changed since 0.4 wrote it, so no guard was added. On the root
               layout it is rendered on every page, so if the project renders error pages with the
               root layout, guard it as a new project's component does:
               `Map.has_key?(assigns.conn.private, :plug_session)` first.
               """
             ]

      component = igniter |> apply_igniter!() |> content(@components)

      assert lines_with(component, ":ehos) != nil") == [
               "        Plug.Conn.get_session(assigns.conn, :ehos) != nil"
             ]

      # Out of the corner, but reading no `@session?` that nothing assigns.
      assert lines_with(component, "<div") == [@div]
    end

    test "says the way in and out is still on 0.4's home page when the root layout is not Phoenix's" do
      igniter =
        installed()
        |> replace_file(@root, "<html>{@inner_content}</html>\n")
        |> edit_file(@home, &String.replace(&1, @flash, @flash <> @call <> "\n"))
        |> install_on()

      assert notices_about(igniter, "is still on #{@home}") == [
               """
               The way in and out is still on #{@home}, which the application's first page of its
               own replaces. Move `#{@call}` to the top of the root layout's <body>, which every
               page renders, a LiveView's included.
               """
             ]

      assert igniter |> apply_igniter!() |> content(@home) |> lines_with(@call) == [@call]
    end

    test "says where the way in and out goes when the root layout is not Phoenix's" do
      igniter = phx_test_project() |> Igniter.rm(@root) |> install_on()

      assert notices_about(igniter, "at the top of the root layout's <body>") == [
               """
               Put `#{@call}` at the top of the root layout's <body>: it offers a visitor to sign
               in through EHOS, and a signed-in person to sign out, on every page.
               """
             ]
    end

    test "wires no pages into a project that serves none" do
      igniter =
        phx_test_project()
        |> Igniter.update_elixir_file(@router, fn zipper ->
          with {:ok, pipeline} <-
                 Igniter.Code.Function.move_to_function_call(zipper, :pipeline, 2, fn call ->
                   Igniter.Code.Function.argument_equals?(call, 0, :browser)
                 end) do
            {:ok, Sourceror.Zipper.remove(pipeline)}
          end
        end)
        |> install_on()

      assert igniter.warnings == [
               """
               No Phoenix endpoint and router with a `:browser` pipeline were found, so nothing serves
               the pages people sign in to through EHOS. eh_os_contract_auth's README, "Signing
               people in", says what to add; until then, remove `sign_in` from ehos.yaml, which asks
               EHOS for a client the application cannot use.
               """
             ]

      assert igniter |> content(@router) |> sections(~s|  scope "/auth"|, "  end") == []
      refute Igniter.exists?(igniter, @components)
    end
  end

  # A project as 0.4 left it, from `igniter` as the installer wrote it: the call under the home
  # page's flash group, the root layout without it, and `component` as its sign-in component.
  defp at_04(igniter, component) do
    igniter
    |> edit_file(@root, &String.replace(&1, "    " <> @call <> "\n", ""))
    |> edit_file(@home, &String.replace(&1, @flash, @flash <> @call <> "\n"))
    |> replace_file(@components, component)
    |> apply_igniter!()
  end

  # The installer run on a 0.4 project whose sign-in component is `component`.
  defp as_04(component) do
    installed()
    |> at_04(component)
    |> Igniter.compose_task("ehos_app.install", [])
  end

  defp body(igniter), do: igniter |> content(@root) |> sections("  <body>", "  </body>")
end

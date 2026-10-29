defmodule Mix.Tasks.EhosApp.InstallTest.SignIn do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # The way in and out as 0.4 generated it, for `TestWeb`, formatted as Igniter writes it. Not
  # `.ex`, which `mix test` would warn matches no test file.
  @sign_in_components_04 File.read!("test/fixtures/sign_in_components_0.4.ex.txt")

  describe "signing people in through EHOS" do
    test "starts the client only where it is configured, so development and tests start none" do
      igniter = installed()
      sign_in = content(igniter, "lib/test/sign_in.ex")

      assert sign_in =~ "Application.get_env(:eh_os_contract_auth, :sign_in)"
      assert sign_in =~ "EhOsContract.Auth.SignIn.child_spec(opts)"

      # Unconfigured, as in ehos_app's own tests, the child starts nothing. The package is not a
      # dependency here, so the compiler's warning that its module is missing is kept quiet.
      {[{module, _}], _missing_package} =
        Code.with_diagnostics(fn -> Code.compile_string(sign_in) end)

      assert %{id: EhOsContract.Auth.SignIn, start: {^module, :start_link, [[]]}} =
               module.child_spec([])

      assert module.start_link([]) == :ignore
    end

    test "encrypts the cookie session, which holds the sign-in's state between redirect and callback" do
      endpoint = installed() |> content("lib/test_web/endpoint.ex")

      assert endpoint =~ ~r/@session_options \[[^\]]*encryption_salt: "[A-Za-z0-9+\/]{8}"/
    end

    test "marks the session cookie Secure in production, whatever scheme reaches the endpoint" do
      igniter = installed()

      assert content(igniter, "lib/test_web/endpoint.ex") =~
               "secure: Application.compile_env(:test, [__MODULE__, :secure_session], false)"

      assert get_in(read_config(igniter, :prod), [:test, TestWeb.Endpoint, :secure_session])
      refute get_in(read_config(igniter, :dev), [:test, TestWeb.Endpoint, :secure_session])
    end

    test "replaces a session cookie set never to be Secure, and keeps any other choice" do
      for {theirs, kept?} <- [
            {"false", false},
            {"true", true},
            {~s|System.get_env("X") == "1"|, true}
          ] do
        endpoint =
          phx_test_project()
          |> Igniter.update_file("lib/test_web/endpoint.ex", fn source ->
            Rewrite.Source.update(source, :content, fn content ->
              String.replace(
                content,
                ~s|same_site: "Lax"|,
                ~s|same_site: "Lax",\n    secure: #{theirs}|
              )
            end)
          end)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])
          |> apply_igniter!()
          |> content("lib/test_web/endpoint.ex")

        assert String.contains?(endpoint, "secure: #{theirs}") == kept?, "secure: #{theirs}"

        assert String.contains?(endpoint, "secure: Application.compile_env") != kept?,
               "secure: #{theirs}"
      end
    end

    test "keeps an encryption salt the project has" do
      endpoint =
        phx_test_project()
        |> Igniter.update_file("lib/test_web/endpoint.ex", fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            String.replace(
              content,
              ~s|same_site: "Lax"|,
              ~s|same_site: "Lax",\n    encryption_salt: "theirs00"|
            )
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()
        |> content("lib/test_web/endpoint.ex")

      assert endpoint =~ ~s|encryption_salt: "theirs00"|
      assert length(String.split(endpoint, "encryption_salt:")) == 2
    end

    test "serves signing in and out under /auth/ehos, behind the browser's session and CSRF protection" do
      router = installed() |> content("lib/test_web/router.ex")

      assert router =~
               ~r/scope "\/auth" do\s+pipe_through\(:browser\)\s+forward\("\/ehos", EhOsContract.Auth.SignIn.Router\)/

      assert router =~ ~r/pipeline :signed_in do\s+plug\(EhOsContract.Auth.Session\)/
    end

    test "offers a way in and out at the top of the root layout, which every page renders, and tests it" do
      igniter = installed()

      assert content(igniter, "lib/test_web/components/layouts/root.html.heex") =~
               "  <body>\n    <TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\n"

      refute content(igniter, "lib/test_web/controllers/page_html/home.html.heex") =~
               "sign_in_or_out"

      components = content(igniter, "lib/test_web/sign_in_components.ex")
      assert components =~ "defmodule TestWeb.SignInComponents do"
      assert components =~ ~s|href="/auth/ehos/sign-in"|
      assert components =~ ~s|action="/auth/ehos/sign-out" method="post"|
      refute components =~ "fixed"

      test = content(igniter, "test/test_web/sign_in_test.exs")
      assert test =~ "defmodule TestWeb.SignInTest do"
      assert test =~ "use TestWeb.ConnCase"
      assert test =~ "&TestWeb.Layouts.root/1"
      refute test =~ ~s|get(~p"/")|
    end

    test "puts the way in and out on the root layout once, and leaves it where the developer moves it" do
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />\n"

      moved =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, call, ""))
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      refute content(moved, root) =~ call
      refute content(moved, "lib/test_web/controllers/page_html/home.html.heex") =~ call
    end

    test "moves the way in and out from the home page 0.4 put it on to the root layout" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      components = "lib/test_web/sign_in_components.ex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      # A project as 0.4 left it: the call under the home page's flash group, the control in
      # the corner, and the root layout without it.
      as_04 =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, "    " <> call <> "\n", ""))
        end)
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, flash, flash <> call <> "\n")
          )
        end)
        |> Igniter.update_file(components, fn source ->
          Rewrite.Source.update(source, :content, fn _ -> @sign_in_components_04 end)
        end)
        |> apply_igniter!()

      refute content(as_04, root) =~ call

      upgraded =
        as_04
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(upgraded, root) =~ "  <body>\n    #{call}\n"
      refute content(upgraded, home) =~ call
      assert content(upgraded, home) =~ flash
      # 0.4's component is given the new one's guard and its place in the page's flow; what
      # else it says is left as it was.
      component = content(upgraded, components)
      assert component =~ "session? = Map.has_key?(assigns.conn.private, :plug_session)"

      assert component =~
               "session? and Plug.Conn.get_session(assigns.conn, Session.session_key())"

      assert component =~ ~s|<div :if={@session?} id="sign-in-or-out" class="relative z-10|
      refute component =~ "fixed top-4 right-4"
      assert {:ok, _} = Code.string_to_quoted(component)

      upgraded
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    # A 0.4 project as the installer finds it: the call under the home page's flash group, the
    # root layout without it, and `component` as its sign-in component.
    defp as_04(component) do
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      installed()
      |> Igniter.update_file("lib/test_web/components/layouts/root.html.heex", fn source ->
        Rewrite.Source.update(source, :content, &String.replace(&1, "    " <> call <> "\n", ""))
      end)
      |> Igniter.update_file("lib/test_web/controllers/page_html/home.html.heex", fn source ->
        Rewrite.Source.update(source, :content, &String.replace(&1, flash, flash <> call <> "\n"))
      end)
      |> Igniter.update_file("lib/test_web/sign_in_components.ex", fn source ->
        Rewrite.Source.update(source, :content, fn _ -> component end)
      end)
      |> apply_igniter!()
      |> Igniter.compose_task("ehos_app.install", [])
    end

    test "leaves a 0.4 component the developer guarded their own way out of the corner alone" do
      own =
        String.replace(
          @sign_in_components_04,
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Map.has_key?(assigns.conn.private, :plug_session) and\n" <>
            "          Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil"
        )

      igniter = as_04(own)
      component = igniter |> apply_igniter!() |> content("lib/test_web/sign_in_components.ex")

      assert component =~ ~s|<div id="sign-in-or-out" class="relative z-10|
      refute component =~ "@session?"
      refute Enum.any?(igniter.notices, &(&1 =~ "guard it as a new project's"))
    end

    test "takes 0.4's line off the home page when the developer has put the call on the root too" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      upgraded =
        installed()
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, flash, flash <> call <> "\n")
          )
        end)
        |> Igniter.update_file("lib/test_web/sign_in_components.ex", fn source ->
          Rewrite.Source.update(source, :content, fn _ -> @sign_in_components_04 end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert [_once] = Regex.scan(~r/#{Regex.escape(call)}/, content(upgraded, root))
      refute content(upgraded, home) =~ call
      assert content(upgraded, home) =~ flash

      # 0.4's component, now on every page, gets the guard here too.
      component = content(upgraded, "lib/test_web/sign_in_components.ex")
      assert component =~ "session? = Map.has_key?(assigns.conn.private, :plug_session)"
      assert component =~ ~s|<div :if={@session?} id="sign-in-or-out" class="relative z-10|

      upgraded
      |> Igniter.compose_task("ehos_app.install", [])
      |> assert_unchanged()
    end

    test "keeps 0.4's line on the home page when the root holds the call in a comment alone" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      for commented <- ["<%!-- #{call} --%>", "<!-- #{call} -->", "<%# #{call} %>"] do
        igniter =
          installed()
          |> Igniter.update_file(root, fn source ->
            Rewrite.Source.update(source, :content, &String.replace(&1, call, commented))
          end)
          |> Igniter.update_file(home, fn source ->
            Rewrite.Source.update(
              source,
              :content,
              &String.replace(&1, flash, flash <> call <> "\n")
            )
          end)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])

        assert Enum.any?(igniter.notices, &(&1 =~ "commented out")), commented

        applied = apply_igniter!(igniter)
        assert [_once] = Regex.scan(~r/#{Regex.escape(call)}/, content(applied, home)), commented
        assert content(applied, root) =~ commented, commented
        assert [_once] = Regex.scan(~r/#{Regex.escape(call)}/, content(applied, root))
      end
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
      assert elsewhere =~ "def other(assigns)"

      component =
        elsewhere |> as_04() |> apply_igniter!() |> content("lib/test_web/sign_in_components.ex")

      assert component =~ ~s|<div id="sign-in-or-out" class="relative z-10|
      refute component =~ ":if={@session?}"
    end

    test "does not take :session? given as a value for an assign of it" do
      as_value =
        String.replace(
          @sign_in_components_04,
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Plug.Conn.get_session(assigns.conn, :ehos) != nil) |> assign(:mode, :session?"
        )

      refute as_value == @sign_in_components_04

      component =
        as_value |> as_04() |> apply_igniter!() |> content("lib/test_web/sign_in_components.ex")

      refute component =~ ":if={@session?}"
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

      refute own == @sign_in_components_04

      component =
        own |> as_04() |> apply_igniter!() |> content("lib/test_web/sign_in_components.ex")

      assert component =~ ~s|<div :if={@session?} id="sign-in-or-out"|
    end

    test "guards a CRLF 0.4 component in its own line endings" do
      component =
        @sign_in_components_04
        |> String.replace("\n", "\r\n")
        |> as_04()
        |> apply_igniter!()
        |> content("lib/test_web/sign_in_components.ex")

      assert component =~ ":plug_session"
      assert component =~ ":if={@session?}"
      refute component =~ ~r/[^\r]\n/
    end

    test "says what to guard in a 0.4 component the developer changed, when it moves it" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      components = "lib/test_web/sign_in_components.ex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      changed =
        String.replace(
          @sign_in_components_04,
          "Plug.Conn.get_session(assigns.conn, Session.session_key()) != nil",
          "Plug.Conn.get_session(assigns.conn, :ehos) != nil"
        )

      igniter =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, "    " <> call <> "\n", ""))
        end)
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, flash, flash <> call <> "\n")
          )
        end)
        |> Igniter.update_file(components, fn source ->
          Rewrite.Source.update(source, :content, fn _ -> changed end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "guard it as a new project's"))

      component = igniter |> apply_igniter!() |> content(components)
      assert component =~ ":ehos) != nil"
      # Out of the corner, but reading no `@session?` that nothing assigns.
      assert component =~ ~s|<div id="sign-in-or-out" class="relative z-10|
      refute component =~ "@session?"
    end

    test "moves the line 0.4 wrote from a CRLF home page too" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />"

      upgraded =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, &String.replace(&1, "    " <> call <> "\n", ""))
        end)
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(source, :content, fn content ->
            content
            |> String.replace(flash <> "\n", flash <> "\n" <> call <> "\n")
            |> String.replace("\n", "\r\n")
          end)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      assert content(upgraded, root) =~ call
      refute content(upgraded, home) =~ call
      assert content(upgraded, home) =~ flash <> "\r\n"
    end

    test "says the way in and out is still on 0.4's home page when the root layout is not Phoenix's" do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      root = "lib/test_web/components/layouts/root.html.heex"
      call = "<TestWeb.SignInComponents.sign_in_or_out conn={@conn} />"
      flash = "<Layouts.flash_group flash={@flash} />\n"

      igniter =
        installed()
        |> Igniter.update_file(root, fn source ->
          Rewrite.Source.update(source, :content, fn _ -> "<html>{@inner_content}</html>\n" end)
        end)
        |> Igniter.update_file(home, fn source ->
          Rewrite.Source.update(
            source,
            :content,
            &String.replace(&1, flash, flash <> call <> "\n")
          )
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "is still on #{home}"))
      assert igniter |> apply_igniter!() |> content(home) =~ call
    end

    test "says where the way in and out goes when the root layout is not Phoenix's" do
      igniter =
        phx_test_project()
        |> Igniter.rm("lib/test_web/components/layouts/root.html.heex")
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "at the top of the root layout's <body>"))
    end

    test "wires no pages into a project that serves none" do
      igniter =
        phx_test_project()
        |> Igniter.update_elixir_file("lib/test_web/router.ex", fn zipper ->
          with {:ok, pipeline} <-
                 Igniter.Code.Function.move_to_function_call(zipper, :pipeline, 2, fn call ->
                   Igniter.Code.Function.argument_equals?(call, 0, :browser)
                 end) do
            {:ok, Sourceror.Zipper.remove(pipeline)}
          end
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      refute content(igniter, "lib/test_web/router.ex") =~ "EhOsContract.Auth.SignIn.Router"
      refute Igniter.exists?(igniter, "lib/test_web/sign_in_components.ex")
      assert Enum.any?(igniter.warnings, &(&1 =~ "`:browser` pipeline"))
    end
  end
end

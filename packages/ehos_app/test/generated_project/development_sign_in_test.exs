defmodule EhosApp.GeneratedProject.DevelopmentSignInTest do
  # eh-os D-166: a project the template generated signs a person in on a developer's computer,
  # through ehos_contract_auth's development mode, and nowhere else. These run against a real
  # project, the one `EHOS_APP_GENERATED_PROJECT` names, with its dependencies fetched and its
  # development database set up: CI's `e2e` job, after `ehosctl init shop` and `mix ecto.setup`.
  # `mix check` leaves them out (`test_helper.exs`). Locally, from a project the installer
  # generated: `EHOS_APP_GENERATED_PROJECT=<its path> mix test --only generated_project`.
  #
  # The mode's own refusals, check by check, and its guard, request by request, are
  # ehos_contract_auth's tests. These hold the template to what it wires: the switch in
  # config/dev.exs, the child after the keys, and the router's forward.
  use ExUnit.Case, async: false

  @moduletag :generated_project
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  setup do
    project = System.fetch_env!("EHOS_APP_GENERATED_PROJECT")
    %{project: project, app: app(project)}
  end

  # Binds `token`, the token the mode printed when the application started, which `run/3` reads
  # from the terminal and gives back on standard input, as a developer copies it; `endpoint`;
  # `role`, the domain's role whose name ends in `suffix`; and `request`, which sends a request
  # from this computer.
  @started """
  token = "" |> IO.gets() |> String.trim()

  endpoint = Module.concat([Macro.camelize(to_string(Mix.Project.config()[:app])) <> "Web", "Endpoint"])

  role = fn suffix ->
    Enum.find_value(EhosContract.Auth.Development.actors(), &(String.ends_with?(&1.role, suffix) && &1.role))
  end

  request = fn conn, method, path, params ->
    Phoenix.ConnTest.dispatch(%{conn | host: "localhost"}, endpoint, method, path, params)
  end
  """

  @sign_in @started <>
             """
             opened = request.(Phoenix.ConnTest.build_conn(), :get, "/dev/sign-in?token=" <> token, nil)
             {303, [address]} = {opened.status, Plug.Conn.get_resp_header(opened, "location")}
             page = opened |> Phoenix.ConnTest.recycle() |> request.(:get, address, nil)
             [_, csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, page.resp_body)

             signed_in =
               page
               |> Phoenix.ConnTest.recycle()
               |> request.(:post, "/dev/sign-in", %{
                 "_csrf_token" => csrf,
                 "subject" => "u-dev",
                 "actors" => [role.(".clerk")],
                 "return_to" => "/access"
               })

             access = fn ->
               conn = signed_in |> Phoenix.ConnTest.recycle() |> request.(:get, "/access", nil)
               {conn.status, conn.resp_body =~ "record_entry"}
             end

             later = DateTime.add(DateTime.utc_now(), 11 * 60)

             %{
               opened: {opened.status, address},
               page: page.status,
               signed_in: {signed_in.status, Plug.Conn.get_resp_header(signed_in, "location")},
               access: access.(),
               renewed: EhosContract.Clock.at(later, access)
             }
             """

  @command @started <>
             """
             credential =
               Phoenix.ConnTest.build_conn()
               |> Plug.Conn.put_req_header("x-dev-sign-in-token", token)
               |> Plug.Conn.put_req_header("content-type", "application/json")
               |> request.(:post, "/dev/credential", Jason.encode!(%{"subject" => "u-dev", "actors" => [role.(".clerk")]}))

             %{"credential" => bearer} = Jason.decode!(credential.resp_body)

             command = fn name, params ->
               Phoenix.ConnTest.build_conn()
               |> Plug.Conn.put_req_header("authorization", "Bearer " <> bearer)
               |> Plug.Conn.put_req_header("content-type", "application/json")
               |> request.(:post, "/api/commands/" <> String.replace(role.(".clerk"), ".clerk", "." <> name), Jason.encode!(params))
             end

             entry = Ecto.UUID.generate()

             %{
               credential: credential.status,
               granted: command.("record_entry", %{entry_id: entry, amount: 10}).status in 200..299,
               refused: command.("flag_entry", %{entry_id: entry}).status
             }
             """

  # A release carries config.exs and dev.exs when it is built with `MIX_ENV=dev`, so the switch
  # is set there, and with `:mix` added Mix is started too: the release's variables and the
  # Mix project it has not loaded still refuse the mode. The project is copied, so that its
  # `mix.exs` and `_build` stay as they were.
  test "a release built for development, with Mix in it, refuses to start the mode",
       %{project: project, app: app, tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    copy = Path.join(dir, "project")
    {_, 0} = System.cmd("cp", ["-Rp", project, copy])

    mix_exs = Path.join(copy, "mix.exs")
    source = File.read!(mix_exs)
    assert source =~ "deps: deps()"

    File.write!(
      mix_exs,
      String.replace(
        source,
        "deps: deps()",
        "deps: deps(), releases: [#{app}: [applications: [mix: :permanent]]]",
        global: false
      )
    )

    {output, status} =
      System.cmd("mix", ["release", "--overwrite"],
        cd: copy,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}]
      )

    assert status == 0, output

    {output, status} = start(Path.join(copy, "_build/dev/rel/#{app}/bin/#{app}"))

    assert status != 0
    assert output =~ "the development mode refuses to start here"
    assert output =~ "RELEASE_NAME is set"
    assert output =~ "no Mix project is loaded"
    # Mix is started in this release, as the case needs.
    refute output =~ "the :mix application is not started"
  end

  # `mix run`, as `mix phx.server` starts the application, without the server: the requests go
  # through the endpoint in the script's own process, so `EhosContract.Clock.at/2` moves the
  # time a credential expires by. From ehos_contract_auth 0.16, the address with the token keeps
  # the token's hash in the session and sends the browser to the page without it, so the form
  # comes from the second request.
  test "a person signed in at /dev/sign-in opens a page behind the session, after its credential expires too",
       %{project: project, tmp_dir: dir} do
    assert run(project, dir, @sign_in) == %{
             opened: {303, "/dev/sign-in"},
             page: 200,
             signed_in: {303, ["/access"]},
             access: {200, true},
             renewed: {200, true}
           }
  end

  test "a command the chosen actors' capabilities do not cover is refused",
       %{project: project, tmp_dir: dir} do
    assert run(project, dir, @command) == %{credential: 200, granted: true, refused: 403}
  end

  # Runs `body` in the project with `mix run`, in `:dev`, gives it the token the mode prints at
  # start, and answers the value it ends with.
  defp run(project, dir, body) do
    script = Path.join(dir, "script.exs")
    result = Path.join(dir, "result")

    File.write!(script, """
    result = (
    #{body}
    )
    File.write!(#{inspect(result)}, :erlang.term_to_binary(result))
    """)

    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["run", script],
        cd: project,
        env: [{~c"MIX_ENV", ~c"dev"}, {~c"EHOS_ISSUER", false}, {~c"EHOS_AUDIENCE", false}]
      ])

    {output, status} = answer_token(port, deadline(300_000), "", false)
    assert status == 0, output
    result |> File.read!() |> :erlang.binary_to_term()
  end

  # The token is sent once its line has ended: the port may cut the output anywhere.
  defp answer_token(port, deadline, output, answered?) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data
        token = Regex.run(~r{/dev/sign-in\?token=(\S+)\s}, output, capture: :all_but_first)

        if token && !answered? do
          Port.command(port, hd(token) <> "\n")
          answer_token(port, deadline, output, true)
        else
          answer_token(port, deadline, output, answered?)
        end

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      left(deadline) ->
        kill(port)
        flunk("mix run did not end in 5 minutes:\n" <> output)
    end
  end

  defp app(project) do
    [_, app] = Regex.run(~r/app: :(\w+)/, File.read!(Path.join(project, "mix.exs")))
    app
  end

  # The release's own `start`, which runs until the node stops; one that has not stopped in a
  # minute started the mode, and is stopped.
  defp start(bin) do
    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["start"],
        env: [
          {~c"MIX_ENV", false},
          {~c"EHOS_ISSUER", false},
          {~c"EHOS_AUDIENCE", false},
          {~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}
        ]
      ])

    collect(port, deadline(60_000), "")
  end

  defp collect(port, deadline, output) do
    receive do
      {^port, {:data, data}} -> collect(port, deadline, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      left(deadline) ->
        kill(port)
        flunk("the release did not stop, so it started the development mode:\n" <> output)
    end
  end

  # A wait of `ms` in all, however much output comes before it ends.
  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # The release's `stop` needs distribution, which the project's rel/env.sh turns off.
  # A port that closed as the wait ended has no process left to kill.
  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid), do: System.cmd("kill", [to_string(pid)])
  end
end

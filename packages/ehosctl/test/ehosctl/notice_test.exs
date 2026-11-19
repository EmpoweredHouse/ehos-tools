defmodule Ehosctl.NoticeTest do
  # The update notice (eh-os D-91, ehos-tools#97): at most once a day, after a command, on
  # stderr; never in CI, under --json, without a terminal, or when switched off; never in the
  # command's way. Not async, through Ehosctl.SignInCase: each test compares stderr whole, which
  # capture_io(:stderr) captures for every process.
  use Ehosctl.SignInCase

  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP
  alias Ehosctl.Notice

  @now ~U[2026-10-11 09:00:00Z]
  @env %{"GITHUB_TOKEN" => "ghp_test"}

  @described %{
    "component" => "ehos",
    "version" => "0.5.0",
    "commit" => nil,
    "produces" => ["ehos.api/v1"],
    "accepts" => [],
    "requires" => %{"ehosctl" => ">= 100.0.0"},
    "routes" => []
  }

  setup %{opts: opts, tmp_dir: tmp_dir} do
    github = FakeGitHub.start()
    test = self()

    # ehosctl 99.0.0, newer than any build of this one; each list of releases is reported.
    FakeHTTP.stub(github, "GET", "/repos/EmpoweredHouse/ehos-tools/releases", fn conn ->
      send(test, :github_asked)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!([
          %{
            "tag_name" => "v99.0.0",
            "draft" => false,
            "prerelease" => false,
            "html_url" => "https://github.com/EmpoweredHouse/ehos-tools/releases/tag/v99.0.0",
            "body" => "",
            "assets" => []
          }
        ])
      )
    end)

    cache_dir = Path.join(tmp_dir, "cache")
    stub_env(@env)
    stub_now(@now)
    mock_error_terminal(true)

    notice = [cache_dir: cache_dir]

    %{github: github, notice: notice, cache_dir: cache_dir, opts: opts}
  end

  test "says a newer ehosctl is released, once a day", %{notice: notice} do
    assert noticed(context(), notice) == released()
    assert asked()

    # Within the day: neither said again nor asked again.
    stub_now(DateTime.add(@now, 23 * 3600))
    assert noticed(context(), notice) == ""
    refute asked()

    # A day later, asked and said again.
    stub_now(DateTime.add(@now, 25 * 3600))
    assert noticed(context(), notice) == released()
    assert asked()
  end

  test "stays silent, asks nothing and writes nothing, whenever it should",
       %{notice: notice, cache_dir: cache_dir} do
    silent = [
      {context(), %{"CI" => "true"}, true},
      {context(), %{"CI" => "1", "GITHUB_TOKEN" => "x"}, true},
      {context(), %{"EHOSCTL_NO_UPDATE_NOTICE" => ""}, true},
      {context(), %{"EHOSCTL_NO_UPDATE_NOTICE" => "1"}, true},
      {context(%{json?: true}), @env, true},
      {context(), @env, false},
      {context(%{command: :versions}), @env, true},
      {context(%{command: :changelog}), @env, true}
    ]

    for {context, env, tty?} <- silent do
      stub_env(env)
      mock_error_terminal(tty?)
      assert noticed(context, notice) == "", inspect({env, tty?})
      refute asked(), inspect({env, tty?})
      refute File.exists?(cache_dir)
    end

    # `CI` set to nothing is not CI.
    mock_error_terminal(true)
    stub_env(Map.put(@env, "CI", ""))
    assert noticed(context(), notice) == released()
  end

  test "with a cache it cannot write, asks nothing and says nothing, command after command",
       %{notice: notice, tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "a-file"), "")

    for unusable <- [Path.join([tmp_dir, "a-file", "cache"]), read_only(tmp_dir)],
        _command <- 1..2 do
      assert noticed(context(), Keyword.put(notice, :cache_dir, unusable)) == ""
      refute asked()
    end
  end

  test "offline, says nothing, and asks again only the next day",
       %{github: github, notice: notice} do
    FakeHTTP.down(github)
    assert noticed(context(), notice) == ""

    FakeHTTP.up(github)
    stub_now(DateTime.add(@now, 3600))
    assert noticed(context(), notice) == ""
    refute asked()
  end

  test "gives GitHub two seconds, and goes on without its answer", %{
    github: github,
    notice: notice
  } do
    github_never_answers(github)

    # The wait is real time: the notice gives up on its own timeout.
    {microseconds, stderr} = :timer.tc(fn -> noticed(context(), notice) end)
    assert stderr == ""
    assert_received :github_asked
    assert microseconds >= 2_000_000 and microseconds < 3_000_000
  end

  test "reads a cache it cannot trust as empty", %{notice: notice, cache_dir: cache_dir} do
    File.mkdir_p!(cache_dir)

    for contents <- [
          "not json",
          ~s({"version": 2, "ehosctl": {"checked_at": "2026-10-11T08:00:00Z", "newest": "0.1.0"}}),
          ~s({"version": 1, "ehosctl": {"checked_at": "yesterday", "newest": "0.1.0"}}),
          ~s({"version": 1, "ehosctl": {"checked_at": "2026-10-11T08:00:00Z", "newest": "\\u001b[2J"}}),
          ~s({"version": 1, "noticed_at": 3, "installations": {"x": {"checked_at": 1}}})
        ] do
      File.write!(Path.join(cache_dir, "notice.json"), contents)
      assert noticed(context(), notice) == released(), contents
      assert asked(), contents
    end
  end

  test "keeps what it learned in the cache, and reads it back", %{notice: notice, cache_dir: dir} do
    noticed(context(), notice)

    assert Notice.read(dir) == %{
             noticed_at: @now,
             ehosctl: %{checked_at: @now, newest: "99.0.0"},
             installations: %{}
           }

    assert File.stat!(Path.join(dir, "notice.json")).mode |> Bitwise.band(0o077) == 0
  end

  describe "after a command that used an installation" do
    setup %{provider: provider, opts: opts} do
      login!(provider, opts)
      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ -> {200, @described} end)
      :ok
    end

    test "says when the installation no longer accepts this ehosctl, and leaves the " <>
           "command's output and exit code as they were",
         %{provider: provider, opts: opts, notice: notice} do
      FakeProvider.put_me(provider, roles: [])

      {0, plain, announced} = ehosctl(["roles"], opts)
      assert announced == announced(provider)

      # The command names its installation first, at a terminal as here (`notice`'s setup).
      assert ehosctl(["roles"], Keyword.put(opts, :notice, notice)) ==
               {0, plain, announced(provider) <> released() <> refused()}
    end

    test "a command that fails keeps its exit code", %{
      provider: provider,
      opts: opts,
      notice: notice
    } do
      FakeProvider.stub_api(provider, "GET", "/api/v1/installation", fn _ ->
        {403, %{"error" => "forbidden", "message" => "Not yours."}}
      end)

      assert ehosctl(["status"], Keyword.put(opts, :notice, notice)) ==
               {3, "",
                announced(provider) <>
                  "\e[31mehosctl:\e[0m Not yours.\n" <>
                  released() <> refused()}
    end

    test "after verify, judges the installation verify chose", %{
      opts: opts,
      notice: notice,
      tmp_dir: tmp_dir
    } do
      dir = Path.join(tmp_dir, "not-an-application")
      opts = Keyword.put(opts, :dir, dir)

      assert ehosctl(["verify"], Keyword.put(opts, :notice, notice)) ==
               {2, "",
                "\e[31mehosctl:\e[0m #{dir} is not the directory of an application: it has no mix.exs and " <>
                  "no ehos.yaml and no .tool-versions as a regular file. Run `ehosctl verify` in " <>
                  "the directory that holds mix.exs, ehos.yaml and .tool-versions of the " <>
                  "application, or in the directory of a utility service, which holds ehos.yaml " <>
                  "and no mix.exs.\n" <>
                  released() <> refused()}
    end

    test "never under --json", %{opts: opts, notice: notice} do
      {0, json, ""} = ehosctl(["roles", "--json"], opts)
      assert ehosctl(["roles", "--json"], Keyword.put(opts, :notice, notice)) == {0, json, ""}
    end
  end

  # The notice's warning for ehosctl 99.0.0, at a terminal, as each test here is.
  defp released do
    "\e[33m! ehosctl 99.0.0 is released, and this ehosctl is #{Ehosctl.version()}.\e[0m\n" <>
      "  Run `mise use -g github:EmpoweredHouse/ehos-tools@99.0.0`, and `ehosctl changelog " <>
      "ehosctl` to see what changed.\n"
  end

  # The notice's warning for the installation `@described` describes.
  defp refused do
    "\e[33m! local runs EHOS 0.5.0, which does not accept this ehosctl " <>
      "(#{Ehosctl.version()}): this installation requires ehosctl >= 100.0.0.\e[0m\n" <>
      "  `ehosctl versions` says whether it accepts the newest release.\n"
  end

  defp context(fields \\ %{}),
    do: Map.merge(%{command: :roles, json?: false, installation: nil}, fields)

  defp noticed(context, notice) do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert Notice.after_command(context, notice) == :ok
    end)
  end

  defp asked do
    receive do
      :github_asked -> true
    after
      0 -> false
    end
  end

  defp read_only(tmp_dir) do
    dir = Path.join(tmp_dir, "read-only")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)
    dir
  end

  # GitHub takes the request and never answers it.
  defp github_never_answers(github) do
    test = self()

    FakeHTTP.stub(github, "GET", "/repos/EmpoweredHouse/ehos-tools/releases", fn _conn ->
      send(test, :github_asked)
      Process.sleep(:infinity)
    end)
  end

  defp mock_error_terminal(tty?), do: stub(Ehosctl.TerminalMock, :error_terminal?, fn -> tty? end)

  defp announced(provider), do: "Installation: local (#{provider.issuer})\n"
end

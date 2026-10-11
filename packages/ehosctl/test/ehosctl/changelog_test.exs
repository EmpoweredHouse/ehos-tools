defmodule Ehosctl.ChangelogTest do
  # `ehosctl changelog` (eh-os D-91, ehos-tools#97): the notes of each release newer than the
  # version in use, or than --since, newest first.
  use Ehosctl.SignInCase

  alias Ehosctl.FakeGitHub

  @contract_commit "3304f355eb5d73058fa8fcf61813f9c0547f9fc6"

  setup %{opts: opts, tmp_dir: tmp_dir} do
    {github, github_opts} = FakeGitHub.start()

    FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
      {"v0.1.1",
       %{"body" => "### Fixed\n\n- 0.1.1's fix.", "published_at" => "2026-10-06T10:00:00Z"}},
      {"v0.10.0", %{"body" => "### Added\n\n- 0.10.0's command."}},
      {"v0.2.0", %{"body" => "### Changed\n\n- 0.2.0's change."}},
      {"v0.1.0", %{"body" => "First."}},
      {"ehos_app-v0.7.0", %{"body" => "ehos_app 0.7.0's notes."}},
      {"ehos_app-v0.6.0", %{"body" => "ehos_app 0.6.0's notes."}}
    ])

    FakeGitHub.releases(
      github,
      "EmpoweredHouse/eh-os-contract",
      [
        {"v0.3.0",
         %{
           "body" => "The notes are in notes.md, attached.",
           "assets" => %{
             "notes.md" => "## eh_os_contract 0.3.0\n\n### Added\n\n- The second DSL.",
             "release.json" => %{"component" => "eh_os_contract", "commit" => @contract_commit}
           }
         }},
        {"v0.2.1", %{"body" => "## eh_os_contract 0.2.1\n\n- A fix."}}
      ],
      30
    )

    FakeGitHub.releases(
      github,
      "EmpoweredHouse/eh-os",
      [{"v0.5.0", %{"body" => "EHOS 0.5.0."}}],
      50
    )

    opts =
      opts
      |> Keyword.merge(github_opts)
      |> Keyword.merge(
        env: %{"GITHUB_TOKEN" => "ghp_test"},
        dir: Path.join(tmp_dir, "nowhere")
      )

    %{github: github, opts: opts}
  end

  defp application(tmp_dir, lock) do
    dir = Path.join(tmp_dir, "ledger")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "")
    File.write!(Path.join(dir, "mix.lock"), lock)
    dir
  end

  test "prints the notes of each release newer than --since, newest first by version",
       %{opts: opts} do
    {0, stdout, ""} = ehosctl(["changelog", "ehosctl", "--since", "0.1.0"], opts)

    assert [
             "# ehosctl 0.10.0 (2026-10-09)",
             "# ehosctl 0.2.0 (2026-10-09)",
             "# ehosctl 0.1.1 (2026-10-06)"
           ] = Regex.scan(~r/^# .*$/m, stdout) |> List.flatten()

    assert stdout =~ "https://github.com/EmpoweredHouse/ehos-tools/releases/tag/v0.10.0"
    assert stdout =~ "- 0.2.0's change."
    refute stdout =~ "First."
    refute stdout =~ "ehos_app"
  end

  test "--since takes a leading v", %{opts: opts} do
    {0, stdout, ""} = ehosctl(["changelog", "ehosctl", "--since", "v0.2.0"], opts)
    assert stdout =~ "# ehosctl 0.10.0"
    refute stdout =~ "# ehosctl 0.2.0"
  end

  test "a release's notes are its notes.md when it has one, else its description",
       %{opts: opts} do
    {0, stdout, ""} = ehosctl(["changelog", "eh_os_contract", "--since", "0.2.0"], opts)

    assert stdout =~ "- The second DSL."
    refute stdout =~ "The notes are in notes.md"
    assert stdout =~ "## eh_os_contract 0.2.1\n\n- A fix."
  end

  test "without --since, ehosctl's own version is the one in use", %{opts: opts} do
    {0, stdout, ""} = ehosctl(["changelog", "ehosctl"], opts)

    newer =
      ~w(0.10.0 0.2.0 0.1.1)
      |> Enum.filter(&(Version.compare(&1, Ehosctl.version()) == :gt))

    for version <- newer, do: assert(stdout =~ "# ehosctl #{version}")

    if newer == [],
      do:
        assert(stdout =~ "Nothing newer than #{Ehosctl.version()}: the newest ehosctl is 0.10.0.")
  end

  test "without --since, an application's component is the version its lock is",
       %{opts: opts, tmp_dir: tmp_dir} do
    tagged =
      application(tmp_dir, """
      %{"ehos_app": {:git, "https://github.com/EmpoweredHouse/ehos-tools.git", "e529ad4888c19be0fde298dc6f64de1dcbdf3de0", [sparse: "packages/ehos_app", tag: "ehos_app-v0.6.0"]}}
      """)

    {0, stdout, ""} = ehosctl(["changelog", "ehos_app"], Keyword.put(opts, :dir, tagged))
    assert stdout =~ "# ehos_app 0.7.0"
    refute stdout =~ "# ehos_app 0.6.0"
  end

  test "a locked commit is matched to the release whose release.json names it",
       %{opts: opts, tmp_dir: tmp_dir} do
    dir =
      application(tmp_dir, """
      %{"eh_os_contract": {:git, "https://github.com/EmpoweredHouse/eh-os-contract.git", "#{@contract_commit}", [sparse: "packages/eh_os_contract", ref: "#{@contract_commit}"]}}
      """)

    {0, stdout, ""} = ehosctl(["changelog", "eh_os_contract"], Keyword.put(opts, :dir, dir))
    assert stdout == "Nothing newer than 0.3.0: the newest eh_os_contract is 0.3.0.\n"
  end

  test "a version in use that cannot be found asks for --since, and says why",
       %{opts: opts, tmp_dir: tmp_dir} do
    {2, "", stderr} = ehosctl(["changelog", "ehos_app"], opts)
    assert stderr =~ "is not an application's directory"
    assert stderr =~ "--since"

    dir =
      application(tmp_dir, """
      %{"eh_os_contract": {:git, "https://github.com/EmpoweredHouse/eh-os-contract.git", "743e91d755bf30b9d4fa0ef0efb7d8f45a147b21", [sparse: "packages/eh_os_contract", branch: "main"]}}
      """)

    {2, "", stderr} = ehosctl(["changelog", "eh_os_contract"], Keyword.put(opts, :dir, dir))
    assert stderr =~ "locks it at 743e91d, which is no release's"

    {2, "", stderr} = ehosctl(["changelog", "ehos"], opts)
    assert stderr =~ "no installation is chosen"
  end

  test "for ehos, the version the installation says it runs", %{provider: provider, opts: opts} do
    login!(provider, opts)

    FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ ->
      {200,
       %{
         "component" => "ehos",
         "version" => "0.4.0",
         "commit" => nil,
         "produces" => ["ehos.api/v1"],
         "accepts" => [],
         "requires" => %{},
         "routes" => []
       }}
    end)

    {0, stdout, ""} = ehosctl(["changelog", "ehos"], opts)
    assert stdout =~ "# ehos 0.5.0"
    assert stdout =~ "EHOS 0.5.0."
  end

  test "--web opens the newest release's page and prints its address", %{opts: opts} do
    test = self()
    opts = Keyword.put(opts, :open_browser, &send(test, {:opened, &1}))

    {0, stdout, ""} = ehosctl(["changelog", "ehosctl", "--web"], opts)
    url = "https://github.com/EmpoweredHouse/ehos-tools/releases/tag/v0.10.0"
    assert stdout == url <> "\n"
    assert_received {:opened, ^url}
  end

  test "--json gives the releases as data", %{opts: opts} do
    {0, json, ""} = ehosctl(["changelog", "eh_os_contract", "--since", "0.2.1", "--json"], opts)

    assert %{
             "component" => "eh_os_contract",
             "since" => "0.2.1",
             "releases" => [
               %{
                 "version" => "0.3.0",
                 "tag" => "v0.3.0",
                 "notes" => "## eh_os_contract 0.3.0\n\n### Added\n\n- The second DSL.",
                 "unread" => nil
               }
             ]
           } = JSON.decode!(json)
  end

  test "a line a terminal would act on is printed quoted", %{github: github, opts: opts} do
    FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
      {"v0.3.0", %{"body" => "- fine\n- \e[2Jcleared"}}
    ])

    {0, stdout, ""} = ehosctl(["changelog", "ehosctl", "--since", "0.2.0"], opts)
    assert stdout =~ "- fine\n"
    assert stdout =~ ~S("- \e[2Jcleared")
    refute stdout =~ "\e"
  end

  test "refuses a component or a version it does not know, with exit 2", %{opts: opts} do
    {2, "", stderr} = ehosctl(["changelog", "kubernetes"], opts)
    assert stderr =~ "is not a component"

    {2, "", stderr} = ehosctl(["changelog", "ehosctl", "--since", "latest"], opts)
    assert stderr =~ "is not a version"
  end

  test "without a token, says a token is what is missing", %{github: github, opts: opts} do
    FakeGitHub.refuse(github, "EmpoweredHouse/ehos-tools", 404)

    {1, "", stderr} = ehosctl(["changelog", "ehosctl"], Keyword.put(opts, :env, %{}))
    assert stderr =~ "without a token"
  end
end

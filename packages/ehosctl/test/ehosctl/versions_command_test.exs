defmodule Ehosctl.VersionsCommandTest do
  # `ehosctl versions` (eh-os D-91, ehos-tools#97): each component in use, the newest release,
  # whether the installation accepts each, and the command that moves to it; each source can
  # fail alone. (`versions_test.exs` is `ehosctl apps`' versions of an application.)
  use Ehosctl.SignInCase

  alias Ehosctl.FakeGitHub

  doctest Ehosctl.Acceptance

  @app_commit "e529ad4888c19be0fde298dc6f64de1dcbdf3de0"
  @app_next "9c97894557018811ae3e71c0f25d51f3c382e758"
  @contract_release "3304f355eb5d73058fa8fcf61813f9c0547f9fc6"
  @contract_main "743e91d755bf30b9d4fa0ef0efb7d8f45a147b21"
  @design_commit "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6"

  @described %{
    "component" => "ehos",
    "version" => "0.5.0-dev",
    "commit" => "1a000cc4e50fd1e75558dfb1638c8b08286fe0bd",
    "produces" => ["ehos.api/v1", "ehos.credential/v1"],
    "accepts" => ["ehos.yaml/v1", "ehos.yaml/v2", "ehos.manifest/v2", "ehos.manifest/v3"],
    "requires" => %{"ehosctl" => ">= 0.3.0-dev"},
    "routes" => []
  }

  defp release_json(component, version, commit, fields),
    do:
      Map.merge(
        %{
          "schema" => "ehos.release/v1",
          "component" => component,
          "version" => version,
          "commit" => commit,
          "produces" => [],
          "accepts" => [],
          "requires" => %{}
        },
        fields
      )

  setup %{opts: opts, tmp_dir: tmp_dir} do
    {github, github_opts} = FakeGitHub.start()

    FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
      {"v99.0.0",
       %{
         "assets" => %{
           "release.json" =>
             release_json("ehosctl", "99.0.0", "1111111111111111111111111111111111111111", %{
               "accepts" => ["ehos.api/v1", "eh_os_contract.api/v1"]
             })
         }
       }},
      {"v0.2.0", %{}},
      {"ehos_app-v0.7.0",
       %{
         "assets" => %{
           "release.json" =>
             release_json("ehos_app", "0.7.0", @app_next, %{"produces" => ["ehos.yaml/v3"]})
         }
       }},
      {"ehos_app-v0.6.0",
       %{
         "assets" => %{
           "release.json" =>
             release_json("ehos_app", "0.6.0", @app_commit, %{"produces" => ["ehos.yaml/v2"]})
         }
       }},
      {"ehos_design-v0.3.0",
       %{
         "assets" => %{
           "release.json" =>
             release_json("ehos_design", "0.3.0", "2222222222222222222222222222222222222222", %{})
         }
       }}
    ])

    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [{"v0.4.0", %{}}], 20)

    FakeGitHub.releases(
      github,
      "EmpoweredHouse/eh-os-contract",
      [
        {"v0.3.0",
         %{
           "assets" => %{
             "release.json" =>
               release_json("eh_os_contract", "0.3.0", @contract_release, %{
                 "produces" => ["ehos.manifest/v2", "ehos.manifest/v3", "eh_os_contract.api/v1"]
               })
           }
         }}
      ],
      30
    )

    FakeGitHub.compare(
      github,
      "EmpoweredHouse/eh-os-contract",
      @contract_release,
      @contract_main,
      %{"status" => "behind", "ahead_by" => 0, "behind_by" => 738}
    )

    opts =
      Keyword.merge(opts, github_opts)
      |> Keyword.merge(env: %{"GITHUB_TOKEN" => "ghp_test"}, dir: Path.join(tmp_dir, "nowhere"))

    %{github: github, opts: opts}
  end

  defp described(provider, described \\ @described),
    do: FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ -> {200, described} end)

  defp application(tmp_dir, lock, ehos_yaml \\ "schema: ehos.yaml/v2\n") do
    dir = Path.join(tmp_dir, "ledger")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "")
    File.write!(Path.join(dir, "ehos.yaml"), ehos_yaml)

    File.write!(
      Path.join(dir, "mix.lock"),
      "%{\n" <>
        Enum.map_join(lock, ",\n", fn {name, entry} -> ~s(  "#{name}": #{entry}) end) <> "\n}\n"
    )

    dir
  end

  defp git(repository, commit, opts),
    do: ~s({:git, "https://github.com/EmpoweredHouse/#{repository}.git", "#{commit}", #{opts}})

  defp row(stdout, component) do
    stdout
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&String.starts_with?(&1, component <> " "))
    |> String.split(~r/\s{2,}/, trim: true)
  end

  describe "with no installation chosen" do
    test "shows the releases alone, says none is chosen, and exits 0", %{opts: opts} do
      {0, stdout, ""} = ehosctl(["versions"], opts)

      assert stdout =~ "No installation is chosen"
      assert row(stdout, "ehosctl") == ["ehosctl", version_said(), "unknown", "99.0.0", "unknown"]
      assert row(stdout, "ehos") == ["ehos", "not known", "n/a", "0.4.0", "n/a"]
      assert stdout =~ "ehosctl to 99.0.0: mise upgrade ehosctl"
      refute stdout =~ "ehos_app"
    end
  end

  describe "with an installation that answers" do
    setup %{provider: provider, opts: opts} do
      login!(provider, opts)
      described(provider)
      :ok
    end

    test "says what it runs, and accepts this ehosctl when its requirement is met",
         %{opts: opts} do
      {0, stdout, ""} = ehosctl(["versions"], opts)

      assert stdout =~ "EHOS 0.5.0-dev (1a000cc)"
      assert ["ehosctl", _, "yes", "99.0.0", "yes"] = row(stdout, "ehosctl")
      assert ["ehos", "0.5.0-dev (1a000cc)", "n/a", "0.4.0", "n/a"] = row(stdout, "ehos")
      assert stdout =~ "ehosctl to 99.0.0: mise upgrade ehosctl"
      refute stdout =~ "ehos to 0.4.0"
    end

    test "a requirement this ehosctl does not meet is a no, with why, and nothing moves to a " <>
           "release it refuses",
         %{provider: provider, opts: opts} do
      described(provider, %{@described | "requires" => %{"ehosctl" => ">= 100.0.0"}})

      {0, stdout, ""} = ehosctl(["versions"], opts)
      assert ["ehosctl", _, "no", "99.0.0", "no"] = row(stdout, "ehosctl")
      assert stdout =~ "ehosctl: this installation requires ehosctl >= 100.0.0."
      refute stdout =~ "mise upgrade ehosctl"
    end

    test "an API this ehosctl does not read is a no", %{provider: provider, opts: opts} do
      described(provider, %{@described | "produces" => ["ehos.api/v2"]})

      {0, stdout, ""} = ehosctl(["versions"], opts)
      assert ["ehosctl", _, "no" | _] = row(stdout, "ehosctl")
      assert stdout =~ "it reads ehos.api/v1, and this installation's API is ehos.api/v2"
    end

    test "a release without release.json is newer but its acceptance unknown",
         %{github: github, opts: opts} do
      FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [{"v99.0.0", %{}}])

      {0, stdout, ""} = ehosctl(["versions"], opts)
      assert ["ehosctl", _, "yes", "99.0.0", "unknown"] = row(stdout, "ehosctl")
      assert stdout =~ "ehosctl 99.0.0: its release has no release.json to say what it accepts."
      assert stdout =~ "mise upgrade ehosctl"
    end

    test "a release.json that is another component's is not used, and says why",
         %{github: github, opts: opts} do
      FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
        {"v99.0.0",
         %{
           "assets" => %{
             "release.json" =>
               release_json(
                 "eh_os_contract",
                 "99.0.0",
                 "1111111111111111111111111111111111111111",
                 %{
                   "accepts" => ["ehos.api/v1"]
                 }
               )
           }
         }}
      ])

      {0, stdout, ""} = ehosctl(["versions"], opts)
      assert ["ehosctl", _, "yes", "99.0.0", "unknown"] = row(stdout, "ehosctl")
      assert stdout =~ "ehosctl 99.0.0: its release.json is not used: "
      assert stdout =~ "names eh_os_contract"
    end

    test "without a GitHub token, shows the installation and says the token is missing",
         %{github: github, opts: opts} do
      for repository <- ~w(ehos-tools eh-os eh-os-contract),
          do: FakeGitHub.refuse(github, "EmpoweredHouse/#{repository}", 404)

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :env, %{}))
      assert [_once] = Regex.scan(~r/GitHub was not read: .* without a token/, stdout)
      assert stdout =~ "Set MISE_GITHUB_TOKEN or GITHUB_TOKEN"
      assert ["ehosctl", _, "yes", "not known"] = row(stdout, "ehosctl")
      assert stdout =~ "EHOS 0.5.0-dev (1a000cc)"
    end

    test "offline from GitHub, shows the installation", %{github: github, opts: opts} do
      Bypass.down(github)

      {0, stdout, ""} = ehosctl(["versions"], opts)
      assert stdout =~ "GitHub was not read:"
      assert stdout =~ "did not answer"
      assert ["ehosctl", _, "yes", "not known" | _] = row(stdout, "ehosctl")
    end

    test "in an application, judges each component and its documents",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      FakeGitHub.compare(
        github,
        "EmpoweredHouse/ehos-tools",
        "2222222222222222222222222222222222222222",
        @design_commit,
        %{"status" => "ahead", "ahead_by" => 3, "behind_by" => 0}
      )

      dir =
        application(tmp_dir, [
          {"ehos_app",
           git(
             "ehos-tools",
             @app_commit,
             ~s([sparse: "packages/ehos_app", tag: "ehos_app-v0.6.0"])
           )},
          {"eh_os_contract",
           git(
             "eh-os-contract",
             @contract_main,
             ~s([sparse: "packages/eh_os_contract", branch: "main"])
           )},
          {"ehos_design",
           git(
             "ehos-tools",
             @design_commit,
             ~s([sparse: "packages/ehos_design", ref: "#{@design_commit}"])
           )}
        ])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      # The locked commit is ehos_app 0.6.0's; 0.7.0 writes an ehos.yaml/v3 this installation
      # does not accept, so nothing moves to it.
      assert row(stdout, "ehos_app") == [
               "ehos_app",
               "0.6.0 (e529ad4)",
               "yes",
               "0.7.0",
               "no"
             ]

      assert stdout =~
               "ehos_app 0.7.0: it writes ehos.yaml/v3, and this installation accepts " <>
                 "ehos.yaml/v1 and ehos.yaml/v2."

      refute stdout =~ "ehos_app to 0.7.0"

      # Following main, 738 commits behind the release: moved with deps.update.
      assert [
               "eh_os_contract",
               "main at 743e91d, 738 commits behind 0.3.0",
               "unknown",
               "0.3.0",
               "yes"
             ] = row(stdout, "eh_os_contract")

      assert stdout =~
               "eh_os_contract to 0.3.0: mix deps.update eh_os_contract eh_os_contract_auth"

      # A commit that is no release's is said as a commit.
      assert ["ehos_design", "ca48a79, 3 commits past 0.3.0", "n/a", "0.3.0", "n/a"] =
               row(stdout, "ehos_design")

      refute stdout =~ "ehos_design to"
      assert row(stdout, "ehos.yaml") == ["ehos.yaml", "ehos.yaml/v2", "yes"]
    end

    test "moves ehos_app to the commit its newest release names", %{
      provider: provider,
      opts: opts,
      tmp_dir: tmp_dir
    } do
      described(provider, %{@described | "accepts" => ["ehos.yaml/v2", "ehos.yaml/v3"]})

      dir =
        application(
          tmp_dir,
          [
            {"ehos_app",
             git(
               "ehos-tools",
               @app_commit,
               ~s([sparse: "packages/ehos_app", tag: "ehos_app-v0.6.0"])
             )}
          ],
          "schema: ehos.yaml/v1\n"
        )

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))
      assert ["ehos_app", "0.6.0 (e529ad4)", "yes", "0.7.0", "yes"] = row(stdout, "ehos_app")

      assert stdout =~
               ~s(ehos_app to 0.7.0: In mix.exs, set :ehos_app's `ref:` to "#{@app_next}" ) <>
                 ~s|(ehos_app-v0.7.0) and its requirement to "== 0.7.0"|

      assert stdout =~ "mix ehos_app.install"
      assert row(stdout, "ehos.yaml") == ["ehos.yaml", "ehos.yaml/v1", "no"]
      assert stdout =~ "ehos.yaml: this installation accepts ehos.yaml/v2 and ehos.yaml/v3."

      assert row(stdout, "eh_os_contract") == [
               "eh_os_contract",
               "not a dependency",
               "n/a",
               "0.3.0",
               "no"
             ]
    end

    test "judges eh_os_contract by the manifest the application writes",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      described(provider, %{@described | "accepts" => ["ehos.yaml/v2", "ehos.manifest/v2"]})

      dir =
        application(tmp_dir, [
          {"eh_os_contract",
           git(
             "eh-os-contract",
             @contract_release,
             ~s([sparse: "packages/eh_os_contract", ref: "#{@contract_release}"])
           )}
        ])

      File.mkdir_p!(Path.join(dir, "_build"))
      File.write!(Path.join(dir, "_build/ehos.manifest.json"), ~s({"schema": "ehos.manifest/v3"}))

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      assert ["eh_os_contract", "0.3.0 (3304f35)", "no", "0.3.0", "no"] =
               row(stdout, "eh_os_contract")

      assert stdout =~
               "eh_os_contract: this application writes ehos.manifest/v3, and this " <>
                 "installation accepts ehos.manifest/v2."

      assert row(stdout, "manifest") == ["manifest", "ehos.manifest/v3", "no"]
    end

    test "two components released under the same tag in two repositories keep their own " <>
           "release.json",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      # ehosctl's v0.3.0 in ehos-tools and eh_os_contract's v0.3.0 in eh-os-contract.
      FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
        {"v0.3.0",
         %{
           "assets" => %{
             "release.json" =>
               release_json("ehosctl", "0.3.0", "1111111111111111111111111111111111111111", %{
                 "accepts" => ["ehos.api/v1", "eh_os_contract.api/v1"]
               })
           }
         }}
      ])

      dir =
        application(tmp_dir, [
          {"eh_os_contract",
           git(
             "eh-os-contract",
             @contract_release,
             ~s([sparse: "packages/eh_os_contract", ref: "#{@contract_release}"])
           )}
        ])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))
      assert ["ehosctl", _, "yes", "0.3.0", "yes"] = row(stdout, "ehosctl")

      assert ["eh_os_contract", "0.3.0 (3304f35)", "yes", "0.3.0", "yes"] =
               row(stdout, "eh_os_contract")
    end

    test "a mix.lock it cannot read is said, and the rest is shown",
         %{opts: opts, tmp_dir: tmp_dir} do
      dir = application(tmp_dir, [])
      File.write!(Path.join(dir, "mix.lock"), ~s|%{"x" => System.halt()}|)

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))
      assert stdout =~ "The application's mix.lock was not read: mix.lock is not one ehosctl"
      assert ["ehosctl" | _] = row(stdout, "ehosctl")
      refute stdout =~ "ehos_app"
    end

    test "--json gives every row with its verdicts and reasons", %{opts: opts} do
      {0, json, ""} = ehosctl(["versions", "--json"], opts)
      report = JSON.decode!(json)

      assert report["installation"]["described"]["version"] == "0.5.0-dev"
      assert report["installation"]["unknown"] == nil

      assert [ehosctl, ehos] = report["components"]
      assert ehosctl["component"] == "ehosctl"
      assert ehosctl["accepted"] == %{"verdict" => "yes", "why" => nil}
      assert ehosctl["newest"]["version"] == "99.0.0"
      assert ehosctl["move"] == "mise upgrade ehosctl"
      assert ehos["in_use"]["said"] == "0.5.0-dev (1a000cc)"
      assert ehos["accepted"]["verdict"] == "not_applicable"
    end
  end

  test "an installation that predates GET /api/v1 is said to, and the rest is shown",
       %{provider: provider, opts: opts} do
    login!(provider, opts)

    FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ ->
      {404, %{"errors" => %{"detail" => "Not Found"}}}
    end)

    {0, stdout, ""} = ehosctl(["versions"], opts)
    assert stdout =~ "has no GET /api/v1, which says what it accepts"
    assert ["ehosctl", _, "unknown", "99.0.0", "unknown"] = row(stdout, "ehosctl")
  end

  test "an installation that refuses is said to, and the rest is shown",
       %{provider: provider, opts: opts} do
    login!(provider, opts)
    described(provider)
    FakeProvider.answer_api(provider, 401, %{"error" => "expired"})

    {0, stdout, ""} = ehosctl(["versions"], opts)
    assert stdout =~ "did not say what it accepts: Your sign-in has expired"
    assert ["ehos", "not known" | _] = row(stdout, "ehos")
  end

  test "an installation it does not know is a usage error", %{opts: opts} do
    {4, "", stderr} = ehosctl(["versions", "--installation", "nope"], opts)
    assert stderr =~ ~s(no installation is named "nope")
  end

  defp version_said do
    version = Ehosctl.version()

    case {Version.parse!(version), Ehosctl.commit()} do
      {%Version{pre: [_ | _]}, commit} when is_binary(commit) ->
        "#{version} (#{String.slice(commit, 0, 7)})"

      _release ->
        version
    end
  end
end

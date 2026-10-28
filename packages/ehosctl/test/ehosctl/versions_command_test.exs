defmodule Ehosctl.VersionsCommandTest do
  # `ehosctl versions` (eh-os D-91, ehos-tools#97): each component in use, the newest release,
  # whether the installation accepts each, and the command that moves to it; each source can
  # fail alone. (`versions_test.exs` is `ehosctl apps`' versions of an application.)
  use Ehosctl.SignInCase

  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP

  doctest Ehosctl.Acceptance

  @app_commit "e529ad4888c19be0fde298dc6f64de1dcbdf3de0"
  @app_next "9c97894557018811ae3e71c0f25d51f3c382e758"
  @contract_release "3304f355eb5d73058fa8fcf61813f9c0547f9fc6"
  @contract_main "743e91d755bf30b9d4fa0ef0efb7d8f45a147b21"
  @design_commit "ca48a79808e1a05a07bd4c0794cd535eb6cf9eb6"
  # ehos_app 0.5.0's, a tag with no GitHub release, as every ehos_app release before 0.7.0 is.
  @app_tagged "9f3cfd231f79519a33ff19f26ca26d13d11599b2"
  @app_newest "6e304254d66c36ec5770615573aaa280f6ccb4e1"

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

    FakeGitHub.tags(github, "EmpoweredHouse/ehos-tools", [
      {"ehos_app-v0.7.0", @app_next},
      {"ehos_app-v0.6.0", @app_commit},
      {"ehos_app-v0.5.0", @app_tagged},
      {"ehos_design-v0.3.0", "2222222222222222222222222222222222222222"}
    ])

    FakeGitHub.tags(github, "EmpoweredHouse/eh-os-contract", [{"v0.3.0", @contract_release}])

    opts =
      Keyword.merge(opts, github_opts)
      |> Keyword.merge(dir: Path.join(tmp_dir, "nowhere"))

    stub_env(%{"GITHUB_TOKEN" => "ghp_test"})

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

  defp app_release(version, commit, fields),
    do:
      {"ehos_app-v" <> version,
       %{
         "assets" => %{
           "release.json" =>
             release_json(
               "ehos_app",
               version,
               commit,
               Map.merge(%{"produces" => ["ehos.yaml/v2"]}, fields)
             )
         }
       }}

  defp app_dep(commit),
    do:
      {"ehos_app", git("ehos-tools", commit, ~s([sparse: "packages/ehos_app", ref: "#{commit}"]))}

  defp contract_on_main,
    do:
      {"eh_os_contract",
       git(
         "eh-os-contract",
         @contract_main,
         ~s([sparse: "packages/eh_os_contract", branch: "main"])
       )}

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
      assert stdout =~ "ehosctl to 99.0.0: mise use -g github:EmpoweredHouse/ehos-tools@99.0.0"
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
      assert stdout =~ "ehosctl to 99.0.0: mise use -g github:EmpoweredHouse/ehos-tools@99.0.0"
      refute stdout =~ "ehos to 0.4.0"
    end

    test "a requirement this ehosctl does not meet is a no, with why, and nothing moves to a " <>
           "release it refuses",
         %{provider: provider, opts: opts} do
      described(provider, %{@described | "requires" => %{"ehosctl" => ">= 100.0.0"}})

      {0, stdout, ""} = ehosctl(["versions"], opts)
      assert ["ehosctl", _, "no", "99.0.0", "no"] = row(stdout, "ehosctl")
      assert stdout =~ "ehosctl: this installation requires ehosctl >= 100.0.0."
      refute stdout =~ "mise use -g"
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
      assert stdout =~ "mise use -g github:EmpoweredHouse/ehos-tools@99.0.0"
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

      stub_env(%{})
      {0, stdout, ""} = ehosctl(["versions"], opts)
      assert [_once] = Regex.scan(~r/GitHub was not read: .* without a token/, stdout)
      assert stdout =~ "Set MISE_GITHUB_TOKEN or GITHUB_TOKEN"
      assert ["ehosctl", _, "yes", "not known"] = row(stdout, "ehosctl")
      assert stdout =~ "EHOS 0.5.0-dev (1a000cc)"
    end

    test "offline from GitHub, shows the installation", %{github: github, opts: opts} do
      FakeHTTP.down(github)

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

      # Following main, 738 commits behind the release: it moves with ehos_app (T-11).
      assert [
               "eh_os_contract",
               "main at 743e91d, 738 commits behind 0.3.0",
               "unknown",
               "0.3.0",
               "yes"
             ] = row(stdout, "eh_os_contract")

      assert stdout =~
               "eh_os_contract to 0.3.0: it moves with ehos_app (ehos-tools' T-11): once a " <>
                 "release of ehos_app pins eh_os_contract 0.3.0, move :ehos_app to it and run " <>
                 "`mix ehos_app.install` again"

      refute stdout =~ "deps.update"

      # A commit that is no release's is said as a commit.
      assert ["ehos_design", "ca48a79, 3 commits past 0.3.0", "n/a", "0.3.0", "n/a"] =
               row(stdout, "ehos_design")

      refute stdout =~ "ehos_design to"
      assert row(stdout, "ehos.yaml") == ["ehos.yaml", "ehos.yaml/v2", "yes"]
    end

    # What ehos_app's installer keeps (T-11), a commit of the project's own, another branch, a
    # tag or a fork's main, moves by hand: both packages and their requirements.
    test "moves an eh_os_contract the installer keeps by hand", %{opts: opts, tmp_dir: tmp_dir} do
      for {repository, pin, pinned_by} <- [
            {"eh-os-contract", ~s(ref: "#{@contract_main}"), "ref:"},
            {"eh-os-contract", ~s(branch: "feature-x"), "branch:"},
            {"eh-os-contract", ~s(tag: "v0.2.1"), "tag:"},
            {"eh-os-contract-fork", ~s(branch: "main"), "branch:"}
          ] do
        dir =
          application(tmp_dir, [
            {"eh_os_contract",
             git(repository, @contract_main, ~s([sparse: "packages/eh_os_contract", #{pin}]))}
          ])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

        assert stdout =~
                 ~s|eh_os_contract to 0.3.0: In mix.exs, set the `ref:` of :eh_os_contract | <>
                   ~s|and :eh_os_contract_auth to "#{@contract_release}" (v0.3.0) in place of | <>
                   "their `#{pinned_by}`, and their requirements",
               "#{repository} with #{pin}"

        refute stdout =~ "mix ehos_app.install"
      end
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

    # ehos-tools#122: ehos_app's releases before 0.7.0 are tags with no GitHub release.
    test "a locked commit a tag of the component names is that version, judged unknown",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      described(provider, %{@described | "accepts" => ["ehos.yaml/v2", "ehos.yaml/v3"]})
      dir = application(tmp_dir, [app_dep(@app_tagged)])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      # Known by its tag, it needs no comparison: none is stubbed.
      assert ["ehos_app", "0.5.0 (9f3cfd2)", "unknown", "0.7.0", "yes"] =
               row(stdout, "ehos_app")

      assert stdout =~
               "ehos_app: ehos_app-v0.5.0 has no GitHub release, so no release.json says " <>
                 "what it writes."

      assert stdout =~
               ~s(ehos_app to 0.7.0: In mix.exs, set :ehos_app's `ref:` to "#{@app_next}")

      {0, json, ""} = ehosctl(["versions", "--json"], Keyword.put(opts, :dir, dir))
      app = Enum.find(JSON.decode!(json)["components"], &(&1["component"] == "ehos_app"))

      assert app["in_use"] == %{
               "version" => "0.5.0",
               "commit" => @app_tagged,
               "said" => "0.5.0 (9f3cfd2)"
             }
    end

    test "a tag whose GitHub release has a release.json is judged by it, or says why not",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      dir = application(tmp_dir, [app_dep(@app_tagged)])

      # Older than the 30 newest releases `versions` reads to find the one a commit is.
      newer = for minor <- 39..10//-1, do: {"ehos_app-v0.#{minor}.0", %{}}

      FakeGitHub.releases(
        github,
        "EmpoweredHouse/ehos-tools",
        newer ++ [app_release("0.5.0", @app_tagged, %{"produces" => ["ehos.yaml/v2"]})]
      )

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))
      assert ["ehos_app", "0.5.0 (9f3cfd2)", "yes", "0.39.0", _] = row(stdout, "ehos_app")

      for {release, why} <- [
            {{"ehos_app-v0.5.0", %{"assets" => %{"release.json" => "not JSON"}}},
             "its release.json is not used: The release.json of ehos_app-v0.5.0 is not a " <>
               "JSON object."},
            {{"ehos_app-v0.5.0", %{}}, "its release has no release.json to say what it writes."},
            {app_release("0.5.0", @app_next, %{}),
             "the release.json of ehos_app-v0.5.0 names another commit than its tag."},
            {{"ehos_app-v0.5.0",
              %{
                "assets" => %{
                  "release.json" =>
                    Map.delete(release_json("ehos_app", "0.5.0", @app_next, %{}), "commit")
                }
              }}, "the release.json of ehos_app-v0.5.0 names no commit."}
          ] do
        FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [release])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))
        assert ["ehos_app", "0.5.0 (9f3cfd2)", "unknown" | _] = row(stdout, "ehos_app")
        assert stdout =~ "ehos_app: " <> why
      end
    end

    test "lists a repository's tags once for all its dependencies no release.json names",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      test = self()

      FakeHTTP.stub(github, "GET", "/repos/EmpoweredHouse/ehos-tools/tags", fn conn ->
        send(test, :tags_listed)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!([%{"name" => "ehos_app-v0.5.0", "commit" => %{"sha" => @app_tagged}}])
        )
      end)

      FakeGitHub.compare(
        github,
        "EmpoweredHouse/ehos-tools",
        "2222222222222222222222222222222222222222",
        @design_commit,
        %{"status" => "ahead", "ahead_by" => 3, "behind_by" => 0}
      )

      dir =
        application(tmp_dir, [
          app_dep(@app_tagged),
          {"ehos_design",
           git(
             "ehos-tools",
             @design_commit,
             ~s([sparse: "packages/ehos_design", ref: "#{@design_commit}"])
           )}
        ])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))
      assert ["ehos_app", "0.5.0 (9f3cfd2)" | _] = row(stdout, "ehos_app")
      assert ["ehos_design", "ca48a79, 3 commits past 0.3.0" | _] = row(stdout, "ehos_design")
      assert_received :tags_listed
      refute_received :tags_listed
    end

    test "a locked commit is said as a commit when GitHub does not list the tags, and why",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
      described(provider, %{@described | "accepts" => ["ehos.yaml/v2", "ehos.yaml/v3"]})

      FakeHTTP.stub(github, "GET", "/repos/EmpoweredHouse/ehos-tools/tags", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.resp(403, "{}")
      end)

      FakeGitHub.compare(github, "EmpoweredHouse/ehos-tools", @app_next, @app_tagged, %{
        "status" => "behind",
        "ahead_by" => 0,
        "behind_by" => 12
      })

      dir = application(tmp_dir, [app_dep(@app_tagged)])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      assert ["ehos_app", "9f3cfd2, 12 commits behind 0.7.0", "unknown", "0.7.0", "yes"] =
               row(stdout, "ehos_app")

      assert stdout =~
               "GitHub's tags of EmpoweredHouse/ehos-tools were not read, so a locked commit " <>
                 "only a tag names is said as a commit: GitHub's rate limit is used up"

      assert stdout =~ "ehos_app: it is no release ehosctl knows"
      assert stdout =~ "ehos_app to 0.7.0: In mix.exs"

      {0, json, ""} = ehosctl(["versions", "--json"], Keyword.put(opts, :dir, dir))

      assert [%{"repository" => "EmpoweredHouse/ehos-tools", "message" => message}] =
               JSON.decode!(json)["unread"]["github_tags"]

      assert message =~ "rate limit is used up"
    end

    test "tags GitHub listed only in part are said to be",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      FakeHTTP.stub(github, "GET", "/repos/EmpoweredHouse/ehos-tools/tags", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        page = String.to_integer(conn.query_params["page"] || "1")

        conn
        |> Plug.Conn.put_resp_header(
          "link",
          ~s(<#{opts[:github_api]}/repos/EmpoweredHouse/ehos-tools/tags?page=#{page + 1}>; rel="next")
        )
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "[]")
      end)

      FakeGitHub.compare(github, "EmpoweredHouse/ehos-tools", @app_next, @app_tagged, %{
        "status" => "behind",
        "ahead_by" => 0,
        "behind_by" => 12
      })

      dir = application(tmp_dir, [app_dep(@app_tagged)])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      assert stdout =~
               "GitHub listed only the first 1000 tags of EmpoweredHouse/ehos-tools; a locked " <>
                 "commit only a tag past them names is said as a commit."

      assert ["ehos_app", "9f3cfd2, 12 commits behind 0.7.0" | _] = row(stdout, "ehos_app")

      {0, json, ""} = ehosctl(["versions", "--json"], Keyword.put(opts, :dir, dir))
      assert JSON.decode!(json)["tags_listed_in_part"] == ["EmpoweredHouse/ehos-tools"]
    end

    test "names the ehos_app release that moves an eh_os_contract off main",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
        app_release("0.8.0", @app_newest, %{"requires" => %{"eh_os_contract" => "~> 0.3.0"}}),
        app_release("0.7.0", @app_next, %{"requires" => %{"eh_os_contract" => "~> 0.3.0"}})
      ])

      dir = application(tmp_dir, [contract_on_main()])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      assert stdout =~
               "eh_os_contract to 0.3.0: it moves with ehos_app (ehos-tools' T-11): move " <>
                 ":ehos_app to 0.8.0, whose release.json admits eh_os_contract 0.3.0, and run " <>
                 "`mix ehos_app.install` again, which moves :eh_os_contract and " <>
                 ":eh_os_contract_auth off main to the release that ehos_app pins."

      # A newest ehos_app the installation refuses is not named, nor one whose range leaves the
      # release out: the next that requires it is, among the release.json files already read.
      FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
        app_release("0.9.0", "3333333333333333333333333333333333333333", %{
          "produces" => ["ehos.yaml/v3"],
          "requires" => %{"eh_os_contract" => "~> 0.3.0"}
        }),
        app_release("0.8.0", @app_newest, %{"requires" => %{"eh_os_contract" => "~> 0.4.0"}}),
        app_release("0.7.0", @app_next, %{"requires" => %{"eh_os_contract" => "~> 0.3.0"}})
      ])

      dir = application(tmp_dir, [app_dep(@app_tagged), contract_on_main()])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))
      assert stdout =~ "move :ehos_app to 0.7.0, whose release.json admits eh_os_contract 0.3.0"
    end

    test "names no ehos_app release that is not newer than the one in use",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      # 0.9.0 writes an ehos.yaml/v3 the installation refuses.
      refused =
        app_release("0.9.0", "3333333333333333333333333333333333333333", %{
          "produces" => ["ehos.yaml/v3"],
          "requires" => %{"eh_os_contract" => "~> 0.3.0"}
        })

      admitting =
        app_release("0.7.0", @app_next, %{"requires" => %{"eh_os_contract" => "~> 0.3.0"}})

      past = "4444444444444444444444444444444444444444"

      FakeGitHub.compare(github, "EmpoweredHouse/ehos-tools", @app_newest, past, %{
        "status" => "ahead",
        "ahead_by" => 2,
        "behind_by" => 0
      })

      for {releases, in_use} <- [
            # Only an older one admits it: nothing moves back to it.
            {[
               refused,
               app_release("0.8.0", @app_newest, %{
                 "requires" => %{"eh_os_contract" => "~> 0.4.0"}
               }),
               admitting
             ], @app_newest},
            # A commit past the newest release.
            {[
               app_release("0.8.0", @app_newest, %{
                 "requires" => %{"eh_os_contract" => "~> 0.3.0"}
               })
             ], past}
          ] do
        FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", releases)
        dir = application(tmp_dir, [app_dep(in_use), contract_on_main()])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

        assert stdout =~
                 "eh_os_contract to 0.3.0: it moves with ehos_app (ehos-tools' T-11): once a " <>
                   "release of ehos_app pins eh_os_contract 0.3.0",
               "#{in_use} of #{inspect(Enum.map(releases, &elem(&1, 0)))}"
      end
    end

    test "an ehos_app in use whose release.json admits it only needs its installer run again",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      in_use =
        app_release("0.8.0", @app_newest, %{"requires" => %{"eh_os_contract" => "~> 0.3.0"}})

      # 0.9.0 writes an ehos.yaml/v3 the installation refuses.
      refused =
        app_release("0.9.0", "3333333333333333333333333333333333333333", %{
          "produces" => ["ehos.yaml/v3"],
          "requires" => %{"eh_os_contract" => "~> 0.3.0"}
        })

      for releases <- [[in_use], [refused, in_use]] do
        FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", releases)
        dir = application(tmp_dir, [app_dep(@app_newest), contract_on_main()])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

        assert stdout =~
                 "eh_os_contract to 0.3.0: it moves with ehos_app (ehos-tools' T-11): ehos_app " <>
                   "0.8.0, in use, has a release.json that admits eh_os_contract 0.3.0: run " <>
                   "`mix ehos_app.install` again, which moves :eh_os_contract and " <>
                   ":eh_os_contract_auth off main to the release that ehos_app pins.",
               inspect(Enum.map(releases, &elem(&1, 0)))

        refute stdout =~ "move :ehos_app to"
      end
    end

    test "a requires.eh_os_contract that is no range names no ehos_app release",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      for requirement <- ["~> nonsense", 3, nil] do
        FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
          app_release("0.8.0", @app_newest, %{"requires" => %{"eh_os_contract" => requirement}})
        ])

        dir = application(tmp_dir, [contract_on_main()])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))
        assert stdout =~ "once a release of ehos_app pins eh_os_contract 0.3.0"
      end
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

    test "a release is judged the other way too: what the installation produces against " <>
           "what it accepts, and what it requires of EHOS",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
        {"ehos_app-v0.7.0",
         %{
           "assets" => %{
             "release.json" =>
               release_json("ehos_app", "0.7.0", @app_next, %{
                 "produces" => ["ehos.yaml/v2"],
                 "requires" => %{"ehos" => ">= 0.6.0", "eh_os_contract" => "~> 0.3.0"}
               })
           }
         }}
      ])

      FakeGitHub.releases(
        github,
        "EmpoweredHouse/eh-os-contract",
        [
          {"v0.3.0",
           %{
             "assets" => %{
               "release.json" =>
                 release_json("eh_os_contract", "0.3.0", @contract_release, %{
                   "produces" => ["ehos.manifest/v2"],
                   "accepts" => ["ehos.credential/v2"]
                 })
             }
           }}
        ],
        30
      )

      FakeGitHub.compare(github, "EmpoweredHouse/ehos-tools", @app_next, @app_commit, %{
        "status" => "behind",
        "ahead_by" => 0,
        "behind_by" => 4
      })

      dir =
        application(tmp_dir, [
          {"ehos_app",
           git(
             "ehos-tools",
             @app_commit,
             ~s([sparse: "packages/ehos_app", ref: "#{@app_commit}"])
           )},
          {"eh_os_contract",
           git(
             "eh-os-contract",
             @contract_release,
             ~s([sparse: "packages/eh_os_contract", ref: "#{@contract_release}"])
           )}
        ])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      assert ["eh_os_contract", _, "no", "0.3.0", "no"] = row(stdout, "eh_os_contract")

      assert stdout =~
               "eh_os_contract 0.3.0: it reads ehos.credential/v2, and this installation " <>
                 "produces ehos.credential/v1."

      assert ["ehos_app", _, _, "0.7.0", "no"] = row(stdout, "ehos_app")

      assert stdout =~
               "ehos_app 0.7.0: it requires ehos >= 0.6.0, and this installation runs 0.5.0-dev."
    end

    test "a comparison GitHub cannot give leaves how far a commit is unknown, and the row stays",
         %{github: github, opts: opts, tmp_dir: tmp_dir} do
      FakeHTTP.stub(
        github,
        "GET",
        "/repos/EmpoweredHouse/eh-os-contract/compare/#{@contract_release}...#{@contract_main}",
        &Plug.Conn.resp(&1, 200, String.duplicate("x", 9 * 1024 * 1024))
      )

      dir =
        application(tmp_dir, [
          {"eh_os_contract",
           git(
             "eh-os-contract",
             @contract_main,
             ~s([sparse: "packages/eh_os_contract", branch: "main"])
           )}
        ])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))
      assert ["eh_os_contract", "main at 743e91d", _, "0.3.0", _] = row(stdout, "eh_os_contract")
    end

    test "a release list GitHub cut short is said to be", %{github: github, opts: opts} do
      FakeHTTP.stub(github, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        page = String.to_integer(conn.query_params["page"] || "1")

        conn
        |> Plug.Conn.put_resp_header(
          "link",
          ~s(<#{opts[:github_api]}/repos/EmpoweredHouse/eh-os/releases?page=#{page + 1}>; rel="next")
        )
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "[]")
      end)

      {0, stdout, ""} = ehosctl(["versions"], opts)
      assert stdout =~ "GitHub listed only the first 1000 releases of EmpoweredHouse/eh-os"

      # Read, if only in part: not among what GitHub did not answer.
      {0, json, ""} = ehosctl(["versions", "--json"], opts)
      report = JSON.decode!(json)
      assert report["listed_in_part"] == ["EmpoweredHouse/eh-os"]
      assert report["unread"]["github"] == []
    end

    # eh-os itself is a Mix project that depends on ehos_design (#195).
    test "a Mix project with no ehos.yaml and no ehos_app is no application, and has no rows",
         %{opts: opts, tmp_dir: tmp_dir} do
      dir =
        application(tmp_dir, [
          {"ehos_design",
           git(
             "ehos-tools",
             @design_commit,
             ~s([sparse: "packages/ehos_design", ref: "#{@design_commit}"])
           )}
        ])

      File.rm!(Path.join(dir, "ehos.yaml"))

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      refute stdout =~ "Application:"
      assert ["ehosctl" | _] = row(stdout, "ehosctl")
      assert ["ehos" | _] = row(stdout, "ehos")

      for component <- ~w(ehos_app eh_os_contract ehos_design ehos.yaml),
          do: refute(stdout =~ component)
    end

    test "an application with ehos_app and no ehos.yaml says it has none",
         %{opts: opts, tmp_dir: tmp_dir} do
      dir =
        application(tmp_dir, [
          {"ehos_app",
           git(
             "ehos-tools",
             @app_commit,
             ~s([sparse: "packages/ehos_app", tag: "ehos_app-v0.6.0"])
           )}
        ])

      File.rm!(Path.join(dir, "ehos.yaml"))

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      assert stdout =~ "Application: #{dir}"
      assert row(stdout, "ehos.yaml") == ["ehos.yaml", "no ehos.yaml", "unknown"]
      assert stdout =~ "ehos.yaml: the application has no ehos.yaml."
      refute stdout =~ "no schema ehosctl reads"

      {0, json, ""} = ehosctl(["versions", "--json"], Keyword.put(opts, :dir, dir))
      report = JSON.decode!(json)

      assert report["application"]["ehos_yaml"] == nil

      assert [%{"document" => "ehos.yaml", "schema" => nil, "accepted" => accepted}] =
               report["documents"]

      assert accepted == %{"verdict" => "unknown", "why" => "the application has no ehos.yaml"}
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
      assert ehosctl["move"] == "mise use -g github:EmpoweredHouse/ehos-tools@99.0.0"
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

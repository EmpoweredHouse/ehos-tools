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

  # The row of the installation's EHOS when it answers, and GitHub lists its releases.
  @ehos_row ["ehos", "0.5.0-dev (1a000cc)", "n/a", "0.4.0", "n/a"]

  @ehosctl_move "ehosctl to 99.0.0: mise use -g github:EmpoweredHouse/ehos-tools@99.0.0"

  setup %{opts: opts, tmp_dir: tmp_dir} do
    github = FakeGitHub.start()

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
      Keyword.merge(opts, dir: Path.join(tmp_dir, "nowhere"))

    stub_env(%{"GITHUB_TOKEN" => "ghp_test"})

    %{github: github, opts: opts}
  end

  describe "versions with no installation chosen" do
    test "shows the releases alone, says none is chosen, and exits 0", %{opts: opts} do
      {0, stdout, ""} = ehosctl(["versions"], opts)

      table =
        table([
          ["ehosctl", version_said(), "unknown", "99.0.0", "unknown"],
          ["ehos", "not known", "n/a", "0.4.0", "n/a"]
        ])

      assert stdout == """
             No installation is chosen, so ehosctl cannot show what an installation accepts. Run `ehosctl login`, or name an installation with --installation.

             #{table}
             To move:
               #{@ehosctl_move}
             """
    end
  end

  describe "versions with an installation that answers" do
    setup %{provider: provider, opts: opts} do
      login!(provider, opts)
      described(provider)
      :ok
    end

    test "says what it runs, and accepts this ehosctl when its requirement is met",
         %{provider: provider, opts: opts} do
      {0, stdout, ""} = ehosctl(["versions"], opts)

      table = table([["ehosctl", version_said(), "yes", "99.0.0", "yes"], @ehos_row])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)

             #{table}
             To move:
               #{@ehosctl_move}
             """
    end

    test "a requirement this ehosctl does not meet is a no, with why, and nothing moves to a " <>
           "release it refuses",
         %{provider: provider, opts: opts} do
      described(provider, %{@described | "requires" => %{"ehosctl" => ">= 100.0.0"}})

      {0, stdout, ""} = ehosctl(["versions"], opts)

      table = table([["ehosctl", version_said(), "no", "99.0.0", "no"], @ehos_row])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)

             #{table}
             Why:
               ehosctl: this installation requires ehosctl >= 100.0.0.
               ehosctl 99.0.0: this installation requires ehosctl >= 100.0.0.
             """
    end

    test "an API this ehosctl does not read is a no", %{provider: provider, opts: opts} do
      described(provider, %{@described | "produces" => ["ehos.api/v2"]})

      {0, stdout, ""} = ehosctl(["versions"], opts)

      table = table([["ehosctl", version_said(), "no", "99.0.0", "no"], @ehos_row])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)

             #{table}
             Why:
               ehosctl: it reads ehos.api/v1, and this installation's API is ehos.api/v2.
               ehosctl 99.0.0: it reads ehos.api/v1, and this installation's API is ehos.api/v2.
             """
    end

    test "a release without release.json is newer but its acceptance unknown",
         %{github: github, provider: provider, opts: opts} do
      FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [{"v99.0.0", %{}}])

      {0, stdout, ""} = ehosctl(["versions"], opts)

      table = table([["ehosctl", version_said(), "yes", "99.0.0", "unknown"], @ehos_row])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)

             #{table}
             Why:
               ehosctl 99.0.0: its release has no release.json to say what it accepts.

             To move:
               #{@ehosctl_move}
             """
    end

    test "a release.json that is another component's is not used, and says why",
         %{github: github, provider: provider, opts: opts} do
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

      table = table([["ehosctl", version_said(), "yes", "99.0.0", "unknown"], @ehos_row])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)

             #{table}
             Why:
               ehosctl 99.0.0: its release.json is not used: The release.json of v99.0.0 names eh_os_contract, not ehosctl.

             To move:
               #{@ehosctl_move}
             """
    end

    test "without a GitHub token, shows the installation and says the token is missing",
         %{github: github, provider: provider, opts: opts} do
      for repository <- ~w(ehos-tools eh-os eh-os-contract),
          do: FakeGitHub.refuse(github, "EmpoweredHouse/#{repository}", 404)

      stub_env(%{})
      {0, stdout, ""} = ehosctl(["versions"], opts)

      # Said once, for every repository.
      assert stdout ==
               """
               Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
               ehosctl could not read GitHub: GitHub does not show the releases of EHOS without a token, because their repositories are private. Set MISE_GITHUB_TOKEN or GITHUB_TOKEN, for example to the output of `gh auth token`.

               """ <>
                 table([
                   ["ehosctl", version_said(), "yes", "not known"],
                   ["ehos", "0.5.0-dev (1a000cc)", "n/a", "not known"]
                 ])
    end

    test "offline from GitHub, shows the installation",
         %{github: github, provider: provider, opts: opts} do
      FakeHTTP.down(github)

      {0, stdout, ""} = ehosctl(["versions"], opts)

      assert stdout ==
               """
               Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
               ehosctl could not read GitHub: https://api.github.com did not answer.

               """ <>
                 table([
                   ["ehosctl", version_said(), "yes", "not known"],
                   ["ehos", "0.5.0-dev (1a000cc)", "n/a", "not known"]
                 ])
    end

    test "in an application, judges each component and its documents",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
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
      # does not accept, so nothing moves to it. eh_os_contract follows main, 738 commits behind
      # the release: it moves with ehos_app (T-11). ehos_design's commit is no release's, so it
      # is said as a commit.
      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          @ehos_row,
          ["ehos_app", "0.6.0 (e529ad4)", "yes", "0.7.0", "no"],
          [
            "eh_os_contract",
            "main at 743e91d, 738 commits behind 0.3.0",
            "unknown",
            "0.3.0",
            "yes"
          ],
          ["ehos_design", "ca48a79, 3 commits past 0.3.0", "n/a", "0.3.0", "n/a"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               ehos_app 0.7.0: it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 and ehos.yaml/v2.
               eh_os_contract: it is no release ehosctl knows, so what it writes is not known.

             To move:
               #{@ehosctl_move}
               eh_os_contract to 0.3.0: it moves with ehos_app. When a release of ehos_app pins eh_os_contract 0.3.0, move :ehos_app to it. Then run `mix ehos_app.install` again: it moves :eh_os_contract and :eh_os_contract_auth off main to the release that ehos_app pins.
             """
    end

    # What ehos_app's installer keeps (T-11), a commit of the project's own, another branch, a
    # tag or a fork's main, moves by hand: both packages and their requirements.
    test "moves an eh_os_contract the installer keeps by hand",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      for {repository, pin, pinned_by, in_use} <- [
            {"eh-os-contract", ~s(ref: "#{@contract_main}"), "ref:",
             "743e91d, 738 commits behind 0.3.0"},
            {"eh-os-contract", ~s(branch: "feature-x"), "branch:",
             "feature-x at 743e91d, 738 commits behind 0.3.0"},
            {"eh-os-contract", ~s(tag: "v0.2.1"), "tag:",
             "743e91d (tag v0.2.1), 738 commits behind 0.3.0"},
            {"eh-os-contract-fork", ~s(branch: "main"), "branch:",
             "main at 743e91d, 738 commits behind 0.3.0"}
          ] do
        dir =
          application(tmp_dir, [
            {"eh_os_contract",
             git(repository, @contract_main, ~s([sparse: "packages/eh_os_contract", #{pin}]))}
          ])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

        table =
          table([
            ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
            @ehos_row,
            ["ehos_app", "not a dependency", "n/a", "0.7.0", "no"],
            ["eh_os_contract", in_use, "unknown", "0.3.0", "yes"],
            ["ehos_design", "not a dependency", "n/a", "0.3.0", "n/a"],
            ["ehos.yaml", "ehos.yaml/v2", "yes"]
          ])

        assert {repository, pin, stdout} ==
                 {repository, pin,
                  """
                  Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
                  Application: #{dir}

                  #{table}
                  Why:
                    ehos_app 0.7.0: it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 and ehos.yaml/v2.
                    eh_os_contract: it is no release ehosctl knows, so what it writes is not known.

                  To move:
                    #{@ehosctl_move}
                    eh_os_contract to 0.3.0: In mix.exs, set the `ref:` of :eh_os_contract and :eh_os_contract_auth to "#{@contract_release}" (v0.3.0) in place of their `#{pinned_by}`, and their requirements to that release's versions, then run `mix deps.get`.
                  """}
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

      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          @ehos_row,
          ["ehos_app", "0.6.0 (e529ad4)", "yes", "0.7.0", "yes"],
          ["eh_os_contract", "not a dependency", "n/a", "0.3.0", "no"],
          ["ehos_design", "not a dependency", "n/a", "0.3.0", "n/a"],
          ["ehos.yaml", "ehos.yaml/v1", "no"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               eh_os_contract 0.3.0: it writes ehos.manifest/v2 and ehos.manifest/v3, and this installation accepts no ehos.manifest.
               ehos.yaml: this installation accepts ehos.yaml/v2 and ehos.yaml/v3.

             To move:
               #{@ehosctl_move}
               ehos_app to 0.7.0: In mix.exs, set :ehos_app's `ref:` to "#{@app_next}" (ehos_app-v0.7.0) and its requirement to "== 0.7.0" in place of its `tag:`, run `mix deps.get`, then `mix ehos_app.install` again.
             """
    end

    # ehos-tools#122: ehos_app's releases before 0.7.0 are tags with no GitHub release.
    test "a locked commit a tag of the component names is that version, judged unknown",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      accepts = ["ehos.yaml/v2", "ehos.yaml/v3"]
      described(provider, %{@described | "accepts" => accepts})
      dir = application(tmp_dir, [app_dep(@app_tagged)])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      # Known by its tag, it needs no comparison: none is stubbed.
      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          @ehos_row,
          ["ehos_app", "0.5.0 (9f3cfd2)", "unknown", "0.7.0", "yes"],
          ["eh_os_contract", "not a dependency", "n/a", "0.3.0", "no"],
          ["ehos_design", "not a dependency", "n/a", "0.3.0", "n/a"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      move =
        ~s|In mix.exs, set :ehos_app's `ref:` to "#{@app_next}" (ehos_app-v0.7.0) and its | <>
          ~s|requirement to "== 0.7.0" in place of its `ref:`, run `mix deps.get`, then | <>
          "`mix ehos_app.install` again."

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               ehos_app: ehos_app-v0.5.0 has no GitHub release, so no release.json says what it writes.
               eh_os_contract 0.3.0: it writes ehos.manifest/v2 and ehos.manifest/v3, and this installation accepts no ehos.manifest.

             To move:
               #{@ehosctl_move}
               ehos_app to 0.7.0: #{move}
             """

      {0, json, ""} = ehosctl(["versions", "--json"], Keyword.put(opts, :dir, dir))

      assert JSON.decode!(json) ==
               report(provider, accepts, %{
                 "application" => application_json(dir, "ehos.yaml/v2"),
                 "components" => [
                   ehosctl_json(),
                   ehos_json(),
                   component_json("ehos_app", %{
                     "in_use" => %{
                       "version" => "0.5.0",
                       "commit" => @app_tagged,
                       "said" => "0.5.0 (9f3cfd2)"
                     },
                     "accepted" =>
                       verdict(
                         "unknown",
                         "ehos_app-v0.5.0 has no GitHub release, so no release.json says " <>
                           "what it writes"
                       ),
                     "newest" => newest("ehos-tools", "ehos_app-v0.7.0", "0.7.0"),
                     "newest_accepted" => verdict("yes"),
                     "move" => move
                   }),
                   component_json("eh_os_contract", %{
                     "newest" => newest("eh-os-contract", "v0.3.0", "0.3.0"),
                     "newest_accepted" =>
                       verdict(
                         "no",
                         "it writes ehos.manifest/v2 and ehos.manifest/v3, and this " <>
                           "installation accepts no ehos.manifest"
                       )
                   }),
                   ehos_design_json()
                 ],
                 "documents" => [ehos_yaml_json("ehos.yaml/v2", verdict("yes"))]
               })
    end

    test "a tag whose GitHub release has a release.json is judged by it, or says why not",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
      dir = application(tmp_dir, [app_dep(@app_tagged)])

      # Older than the 30 newest releases `versions` reads to find the one a commit is.
      newer = for minor <- 39..10//-1, do: {"ehos_app-v0.#{minor}.0", %{}}

      FakeGitHub.releases(
        github,
        "EmpoweredHouse/ehos-tools",
        newer ++ [app_release("0.5.0", @app_tagged, %{"produces" => ["ehos.yaml/v2"]})]
      )

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      table =
        table([
          ["ehosctl", version_said(), "yes", "none released"],
          @ehos_row,
          ["ehos_app", "0.5.0 (9f3cfd2)", "yes", "0.39.0", "unknown"],
          ["eh_os_contract", "not a dependency", "n/a", "0.3.0", "yes"],
          ["ehos_design", "not a dependency", "n/a", "none released"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               ehos_app 0.39.0: its release has no release.json to say which ehos.yaml it writes.

             To move:
               ehos_app to 0.39.0: In mix.exs, set :ehos_app's `ref:` to the commit ehos_app-v0.39.0 names (`git ls-remote https://github.com/EmpoweredHouse/ehos-tools refs/tags/ehos_app-v0.39.0^{}`, or the tag itself for a lightweight tag) and its requirement to "== 0.39.0" in place of its `ref:`, run `mix deps.get`, then `mix ehos_app.install` again.
             """

      not_json =
        "its release.json is not used: The release.json of ehos_app-v0.5.0 is not a JSON object."

      for {release, newest_accepted, why} <- [
            {{"ehos_app-v0.5.0", %{"assets" => %{"release.json" => "not JSON"}}}, "unknown",
             ["ehos_app: #{not_json}", "ehos_app 0.5.0: #{not_json}"]},
            {{"ehos_app-v0.5.0", %{}}, "unknown",
             [
               "ehos_app: its release has no release.json to say what it writes.",
               "ehos_app 0.5.0: its release has no release.json to say which ehos.yaml it writes."
             ]},
            {app_release("0.5.0", @app_next, %{}), "yes",
             ["ehos_app: the release.json of ehos_app-v0.5.0 names another commit than its tag."]},
            {{"ehos_app-v0.5.0",
              %{
                "assets" => %{
                  "release.json" =>
                    Map.delete(release_json("ehos_app", "0.5.0", @app_next, %{}), "commit")
                }
              }}, "unknown",
             [
               "ehos_app: the release.json of ehos_app-v0.5.0 names no commit.",
               "ehos_app 0.5.0: its release.json names no ehos.yaml it writes."
             ]}
          ] do
        FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [release])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

        table =
          table([
            ["ehosctl", version_said(), "yes", "none released"],
            @ehos_row,
            ["ehos_app", "0.5.0 (9f3cfd2)", "unknown", "0.5.0", newest_accepted],
            ["eh_os_contract", "not a dependency", "n/a", "0.3.0", "yes"],
            ["ehos_design", "not a dependency", "n/a", "none released"],
            ["ehos.yaml", "ehos.yaml/v2", "yes"]
          ])

        assert {release, stdout} ==
                 {release,
                  """
                  Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
                  Application: #{dir}

                  #{table}
                  Why:
                  #{Enum.map_join(why, "\n", &"  #{&1}")}
                  """}
      end
    end

    test "lists a repository's tags once for all its dependencies no release.json names",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
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

      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          @ehos_row,
          ["ehos_app", "0.5.0 (9f3cfd2)", "unknown", "0.7.0", "no"],
          ["eh_os_contract", "not a dependency", "n/a", "0.3.0", "yes"],
          ["ehos_design", "ca48a79, 3 commits past 0.3.0", "n/a", "0.3.0", "n/a"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               ehos_app: ehos_app-v0.5.0 has no GitHub release, so no release.json says what it writes.
               ehos_app 0.7.0: it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 and ehos.yaml/v2.

             To move:
               #{@ehosctl_move}
             """

      assert_received :tags_listed
      refute_received :tags_listed
    end

    test "a locked commit is said as a commit when GitHub does not list the tags, and why",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
      accepts = ["ehos.yaml/v2", "ehos.yaml/v3"]
      described(provider, %{@described | "accepts" => accepts})

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

      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          @ehos_row,
          ["ehos_app", "9f3cfd2, 12 commits behind 0.7.0", "unknown", "0.7.0", "yes"],
          ["eh_os_contract", "not a dependency", "n/a", "0.3.0", "no"],
          ["ehos_design", "not a dependency", "n/a", "0.3.0", "n/a"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      move =
        ~s|In mix.exs, set :ehos_app's `ref:` to "#{@app_next}" (ehos_app-v0.7.0) and its | <>
          ~s|requirement to "== 0.7.0" in place of its `ref:`, run `mix deps.get`, then | <>
          "`mix ehos_app.install` again."

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}
             ehosctl could not read the tags of EmpoweredHouse/ehos-tools on GitHub, so it shows a locked commit that only a tag names as a commit: GitHub refused the request because the limit of requests is reached (HTTP 403). Try again later.

             #{table}
             Why:
               ehos_app: it is no release ehosctl knows, so what it writes is not known.
               eh_os_contract 0.3.0: it writes ehos.manifest/v2 and ehos.manifest/v3, and this installation accepts no ehos.manifest.

             To move:
               #{@ehosctl_move}
               ehos_app to 0.7.0: #{move}
             """

      {0, json, ""} = ehosctl(["versions", "--json"], Keyword.put(opts, :dir, dir))

      assert JSON.decode!(json) ==
               report(provider, accepts, %{
                 "application" => application_json(dir, "ehos.yaml/v2"),
                 "components" => [
                   ehosctl_json(),
                   ehos_json(),
                   component_json("ehos_app", %{
                     "in_use" => %{
                       "version" => nil,
                       "commit" => @app_tagged,
                       "said" => "9f3cfd2, 12 commits behind 0.7.0"
                     },
                     "accepted" =>
                       verdict(
                         "unknown",
                         "it is no release ehosctl knows, so what it writes is not known"
                       ),
                     "newest" => newest("ehos-tools", "ehos_app-v0.7.0", "0.7.0"),
                     "newest_accepted" => verdict("yes"),
                     "move" => move
                   }),
                   component_json("eh_os_contract", %{
                     "newest" => newest("eh-os-contract", "v0.3.0", "0.3.0"),
                     "newest_accepted" =>
                       verdict(
                         "no",
                         "it writes ehos.manifest/v2 and ehos.manifest/v3, and this " <>
                           "installation accepts no ehos.manifest"
                       )
                   }),
                   ehos_design_json()
                 ],
                 "documents" => [ehos_yaml_json("ehos.yaml/v2", verdict("yes"))],
                 "unread" => %{
                   "application" => nil,
                   "github" => [],
                   "github_tags" => [
                     %{
                       "repository" => "EmpoweredHouse/ehos-tools",
                       "message" =>
                         "GitHub refused the request because the limit of requests is reached (HTTP 403). Try again later."
                     }
                   ]
                 }
               })
    end

    test "tags GitHub listed only in part are said to be",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
      FakeHTTP.stub(github, "GET", "/repos/EmpoweredHouse/ehos-tools/tags", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        page = String.to_integer(conn.query_params["page"] || "1")

        conn
        |> Plug.Conn.put_resp_header(
          "link",
          ~s(<#{github.origin}/repos/EmpoweredHouse/ehos-tools/tags?page=#{page + 1}>; rel="next")
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

      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          @ehos_row,
          ["ehos_app", "9f3cfd2, 12 commits behind 0.7.0", "unknown", "0.7.0", "no"],
          ["eh_os_contract", "not a dependency", "n/a", "0.3.0", "yes"],
          ["ehos_design", "not a dependency", "n/a", "0.3.0", "n/a"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}
             GitHub listed only the first 1000 tags of EmpoweredHouse/ehos-tools. ehosctl shows a locked commit that only a later tag names as a commit.

             #{table}
             Why:
               ehos_app: it is no release ehosctl knows, so what it writes is not known.
               ehos_app 0.7.0: it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 and ehos.yaml/v2.

             To move:
               #{@ehosctl_move}
             """

      {0, json, ""} = ehosctl(["versions", "--json"], Keyword.put(opts, :dir, dir))

      assert JSON.decode!(json) ==
               report(provider, @described["accepts"], %{
                 "application" => application_json(dir, "ehos.yaml/v2"),
                 "components" => [
                   ehosctl_json(),
                   ehos_json(),
                   component_json("ehos_app", %{
                     "in_use" => %{
                       "version" => nil,
                       "commit" => @app_tagged,
                       "said" => "9f3cfd2, 12 commits behind 0.7.0"
                     },
                     "accepted" =>
                       verdict(
                         "unknown",
                         "it is no release ehosctl knows, so what it writes is not known"
                       ),
                     "newest" => newest("ehos-tools", "ehos_app-v0.7.0", "0.7.0"),
                     "newest_accepted" =>
                       verdict(
                         "no",
                         "it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 " <>
                           "and ehos.yaml/v2"
                       )
                   }),
                   component_json("eh_os_contract", %{
                     "newest" => newest("eh-os-contract", "v0.3.0", "0.3.0"),
                     "newest_accepted" => verdict("yes")
                   }),
                   ehos_design_json()
                 ],
                 "documents" => [ehos_yaml_json("ehos.yaml/v2", verdict("yes"))],
                 "tags_listed_in_part" => ["EmpoweredHouse/ehos-tools"]
               })
    end

    test "names the ehos_app release that moves an eh_os_contract off main",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
      FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
        app_release("0.8.0", @app_newest, %{"requires" => %{"eh_os_contract" => "~> 0.3.0"}}),
        app_release("0.7.0", @app_next, %{"requires" => %{"eh_os_contract" => "~> 0.3.0"}})
      ])

      dir = application(tmp_dir, [contract_on_main()])

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      table =
        table([
          ["ehosctl", version_said(), "yes", "none released"],
          @ehos_row,
          ["ehos_app", "not a dependency", "n/a", "0.8.0", "yes"],
          [
            "eh_os_contract",
            "main at 743e91d, 738 commits behind 0.3.0",
            "unknown",
            "0.3.0",
            "yes"
          ],
          ["ehos_design", "not a dependency", "n/a", "none released"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               eh_os_contract: it is no release ehosctl knows, so what it writes is not known.

             To move:
               eh_os_contract to 0.3.0: it moves with ehos_app. Move :ehos_app to 0.8.0, whose release.json admits eh_os_contract 0.3.0. Then run `mix ehos_app.install` again: it moves :eh_os_contract and :eh_os_contract_auth off main to the release that ehos_app pins.
             """

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

      table =
        table([
          ["ehosctl", version_said(), "yes", "none released"],
          @ehos_row,
          ["ehos_app", "0.5.0 (9f3cfd2)", "unknown", "0.9.0", "no"],
          [
            "eh_os_contract",
            "main at 743e91d, 738 commits behind 0.3.0",
            "unknown",
            "0.3.0",
            "yes"
          ],
          ["ehos_design", "not a dependency", "n/a", "none released"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               ehos_app: ehos_app-v0.5.0 has no GitHub release, so no release.json says what it writes.
               ehos_app 0.9.0: it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 and ehos.yaml/v2.
               eh_os_contract: it is no release ehosctl knows, so what it writes is not known.

             To move:
               eh_os_contract to 0.3.0: it moves with ehos_app. Move :ehos_app to 0.7.0, whose release.json admits eh_os_contract 0.3.0. Then run `mix ehos_app.install` again: it moves :eh_os_contract and :eh_os_contract_auth off main to the release that ehos_app pins.
             """
    end

    test "names no ehos_app release that is not newer than the one in use",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
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

      for {releases, in_use, ehos_app_row, ehos_app_why} <- [
            # Only an older one admits it: nothing moves back to it.
            {[
               refused,
               app_release("0.8.0", @app_newest, %{
                 "requires" => %{"eh_os_contract" => "~> 0.4.0"}
               }),
               admitting
             ], @app_newest, ["ehos_app", "0.8.0 (6e30425)", "yes", "0.9.0", "no"],
             "ehos_app 0.9.0: it writes ehos.yaml/v3, and this installation accepts " <>
               "ehos.yaml/v1 and ehos.yaml/v2."},
            # A commit past the newest release.
            {[
               app_release("0.8.0", @app_newest, %{
                 "requires" => %{"eh_os_contract" => "~> 0.3.0"}
               })
             ], past, ["ehos_app", "4444444, 2 commits past 0.8.0", "unknown", "0.8.0", "yes"],
             "ehos_app: it is no release ehosctl knows, so what it writes is not known."}
          ] do
        FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", releases)
        dir = application(tmp_dir, [app_dep(in_use), contract_on_main()])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

        table =
          table([
            ["ehosctl", version_said(), "yes", "none released"],
            @ehos_row,
            ehos_app_row,
            [
              "eh_os_contract",
              "main at 743e91d, 738 commits behind 0.3.0",
              "unknown",
              "0.3.0",
              "yes"
            ],
            ["ehos_design", "not a dependency", "n/a", "none released"],
            ["ehos.yaml", "ehos.yaml/v2", "yes"]
          ])

        assert {in_use, stdout} ==
                 {in_use,
                  """
                  Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
                  Application: #{dir}

                  #{table}
                  Why:
                    #{ehos_app_why}
                    eh_os_contract: it is no release ehosctl knows, so what it writes is not known.

                  To move:
                    eh_os_contract to 0.3.0: it moves with ehos_app. When a release of ehos_app pins eh_os_contract 0.3.0, move :ehos_app to it. Then run `mix ehos_app.install` again: it moves :eh_os_contract and :eh_os_contract_auth off main to the release that ehos_app pins.
                  """}
      end
    end

    test "an ehos_app in use whose release.json admits it only needs its installer run again",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
      in_use =
        app_release("0.8.0", @app_newest, %{"requires" => %{"eh_os_contract" => "~> 0.3.0"}})

      # 0.9.0 writes an ehos.yaml/v3 the installation refuses.
      refused =
        app_release("0.9.0", "3333333333333333333333333333333333333333", %{
          "produces" => ["ehos.yaml/v3"],
          "requires" => %{"eh_os_contract" => "~> 0.3.0"}
        })

      for {releases, ehos_app_row, why} <- [
            {[in_use], ["ehos_app", "0.8.0 (6e30425)", "yes", "0.8.0", "yes"], ""},
            {[refused, in_use], ["ehos_app", "0.8.0 (6e30425)", "yes", "0.9.0", "no"],
             "  ehos_app 0.9.0: it writes ehos.yaml/v3, and this installation accepts " <>
               "ehos.yaml/v1 and ehos.yaml/v2.\n"}
          ] do
        FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", releases)
        dir = application(tmp_dir, [app_dep(@app_newest), contract_on_main()])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

        table =
          table([
            ["ehosctl", version_said(), "yes", "none released"],
            @ehos_row,
            ehos_app_row,
            [
              "eh_os_contract",
              "main at 743e91d, 738 commits behind 0.3.0",
              "unknown",
              "0.3.0",
              "yes"
            ],
            ["ehos_design", "not a dependency", "n/a", "none released"],
            ["ehos.yaml", "ehos.yaml/v2", "yes"]
          ])

        # Nothing says to move :ehos_app.
        assert {releases, stdout} ==
                 {releases,
                  """
                  Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
                  Application: #{dir}

                  #{table}
                  Why:
                  #{why}  eh_os_contract: it is no release ehosctl knows, so what it writes is not known.

                  To move:
                    eh_os_contract to 0.3.0: it moves with ehos_app. The release.json of ehos_app 0.8.0, in use, admits eh_os_contract 0.3.0. Run `mix ehos_app.install` again: it moves :eh_os_contract and :eh_os_contract_auth off main to the release that ehos_app pins.
                  """}
      end
    end

    test "a requires.eh_os_contract that is no range names no ehos_app release",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
      for requirement <- ["~> nonsense", 3, nil] do
        FakeGitHub.releases(github, "EmpoweredHouse/ehos-tools", [
          app_release("0.8.0", @app_newest, %{"requires" => %{"eh_os_contract" => requirement}})
        ])

        dir = application(tmp_dir, [contract_on_main()])

        {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

        table =
          table([
            ["ehosctl", version_said(), "yes", "none released"],
            @ehos_row,
            ["ehos_app", "not a dependency", "n/a", "0.8.0", "yes"],
            [
              "eh_os_contract",
              "main at 743e91d, 738 commits behind 0.3.0",
              "unknown",
              "0.3.0",
              "yes"
            ],
            ["ehos_design", "not a dependency", "n/a", "none released"],
            ["ehos.yaml", "ehos.yaml/v2", "yes"]
          ])

        assert {requirement, stdout} ==
                 {requirement,
                  """
                  Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
                  Application: #{dir}

                  #{table}
                  Why:
                    eh_os_contract: it is no release ehosctl knows, so what it writes is not known.

                  To move:
                    eh_os_contract to 0.3.0: it moves with ehos_app. When a release of ehos_app pins eh_os_contract 0.3.0, move :ehos_app to it. Then run `mix ehos_app.install` again: it moves :eh_os_contract and :eh_os_contract_auth off main to the release that ehos_app pins.
                  """}
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

      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          @ehos_row,
          ["ehos_app", "not a dependency", "n/a", "0.7.0", "no"],
          ["eh_os_contract", "0.3.0 (3304f35)", "no", "0.3.0", "no"],
          ["ehos_design", "not a dependency", "n/a", "0.3.0", "n/a"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"],
          ["manifest", "ehos.manifest/v3", "no"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               ehos_app 0.7.0: it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v2.
               eh_os_contract: this application writes ehos.manifest/v3, and this installation accepts ehos.manifest/v2.
               eh_os_contract 0.3.0: this application writes ehos.manifest/v3, and this installation accepts ehos.manifest/v2.
               manifest: this installation accepts ehos.manifest/v2.

             To move:
               #{@ehosctl_move}
             """
    end

    test "two components released under the same tag in two repositories keep their own " <>
           "release.json",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
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

      assert stdout ==
               """
               Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
               Application: #{dir}

               """ <>
                 table([
                   ["ehosctl", version_said(), "yes", "0.3.0", "yes"],
                   @ehos_row,
                   ["ehos_app", "not a dependency", "n/a", "none released"],
                   ["eh_os_contract", "0.3.0 (3304f35)", "yes", "0.3.0", "yes"],
                   ["ehos_design", "not a dependency", "n/a", "none released"],
                   ["ehos.yaml", "ehos.yaml/v2", "yes"]
                 ])
    end

    test "a release is judged the other way too: what the installation produces against " <>
           "what it accepts, and what it requires of EHOS",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
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

      table =
        table([
          ["ehosctl", version_said(), "yes", "none released"],
          @ehos_row,
          ["ehos_app", "0.6.0 (e529ad4)", "unknown", "0.7.0", "no"],
          ["eh_os_contract", "0.3.0 (3304f35)", "no", "0.3.0", "no"],
          ["ehos_design", "not a dependency", "n/a", "none released"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               ehos_app: ehos_app-v0.6.0 has no GitHub release, so no release.json says what it writes.
               ehos_app 0.7.0: it requires ehos >= 0.6.0, and this installation runs 0.5.0-dev.
               eh_os_contract: it reads ehos.credential/v2, and this installation produces ehos.credential/v1.
               eh_os_contract 0.3.0: it reads ehos.credential/v2, and this installation produces ehos.credential/v1.
             """
    end

    test "a comparison GitHub cannot give leaves how far a commit is unknown, and the row stays",
         %{github: github, provider: provider, opts: opts, tmp_dir: tmp_dir} do
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

      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          @ehos_row,
          ["ehos_app", "not a dependency", "n/a", "0.7.0", "no"],
          ["eh_os_contract", "main at 743e91d", "unknown", "0.3.0", "yes"],
          ["ehos_design", "not a dependency", "n/a", "0.3.0", "n/a"],
          ["ehos.yaml", "ehos.yaml/v2", "yes"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               ehos_app 0.7.0: it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 and ehos.yaml/v2.
               eh_os_contract: it is no release ehosctl knows, so what it writes is not known.

             To move:
               #{@ehosctl_move}
             """
    end

    test "a release list GitHub cut short is said to be",
         %{github: github, provider: provider, opts: opts} do
      FakeHTTP.stub(github, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        page = String.to_integer(conn.query_params["page"] || "1")

        conn
        |> Plug.Conn.put_resp_header(
          "link",
          ~s(<#{github.origin}/repos/EmpoweredHouse/eh-os/releases?page=#{page + 1}>; rel="next")
        )
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "[]")
      end)

      {0, stdout, ""} = ehosctl(["versions"], opts)

      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          ["ehos", "0.5.0-dev (1a000cc)", "n/a", "none released"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             GitHub listed only the first 1000 releases of EmpoweredHouse/eh-os, the newest it published. ehosctl does not show older ones.

             #{table}
             To move:
               #{@ehosctl_move}
             """

      # Read, if only in part: not among what GitHub did not answer.
      {0, json, ""} = ehosctl(["versions", "--json"], opts)

      assert JSON.decode!(json) ==
               report(provider, @described["accepts"], %{
                 "components" => [
                   ehosctl_json(),
                   Map.merge(ehos_json(), %{"newest" => nil, "newest_accepted" => nil})
                 ],
                 "listed_in_part" => ["EmpoweredHouse/eh-os"]
               })
    end

    # eh-os itself is a Mix project that depends on ehos_design (ehos-tools#195).
    test "a Mix project with no ehos.yaml and no ehos_app is no application, and has no rows",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
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

      table = table([["ehosctl", version_said(), "yes", "99.0.0", "yes"], @ehos_row])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)

             #{table}
             To move:
               #{@ehosctl_move}
             """
    end

    test "an application with ehos_app and no ehos.yaml says it has none",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
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

      table =
        table([
          ["ehosctl", version_said(), "yes", "99.0.0", "yes"],
          @ehos_row,
          ["ehos_app", "0.6.0 (e529ad4)", "yes", "0.7.0", "no"],
          ["eh_os_contract", "not a dependency", "n/a", "0.3.0", "yes"],
          ["ehos_design", "not a dependency", "n/a", "0.3.0", "n/a"],
          ["ehos.yaml", "no ehos.yaml", "unknown"]
        ])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             Application: #{dir}

             #{table}
             Why:
               ehos_app 0.7.0: it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 and ehos.yaml/v2.
               ehos.yaml: the application has no ehos.yaml.

             To move:
               #{@ehosctl_move}
             """

      {0, json, ""} = ehosctl(["versions", "--json"], Keyword.put(opts, :dir, dir))

      assert JSON.decode!(json) ==
               report(provider, @described["accepts"], %{
                 "application" => application_json(dir, nil),
                 "components" => [
                   ehosctl_json(),
                   ehos_json(),
                   component_json("ehos_app", %{
                     "in_use" => %{
                       "version" => "0.6.0",
                       "commit" => @app_commit,
                       "said" => "0.6.0 (e529ad4)"
                     },
                     "accepted" => verdict("yes"),
                     "newest" => newest("ehos-tools", "ehos_app-v0.7.0", "0.7.0"),
                     "newest_accepted" =>
                       verdict(
                         "no",
                         "it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 " <>
                           "and ehos.yaml/v2"
                       )
                   }),
                   component_json("eh_os_contract", %{
                     "newest" => newest("eh-os-contract", "v0.3.0", "0.3.0"),
                     "newest_accepted" => verdict("yes")
                   }),
                   ehos_design_json()
                 ],
                 "documents" => [
                   ehos_yaml_json(nil, verdict("unknown", "the application has no ehos.yaml"))
                 ]
               })
    end

    test "a mix.lock it cannot read is said, and the rest is shown",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      dir = application(tmp_dir, [])
      File.write!(Path.join(dir, "mix.lock"), ~s|%{"x" => System.halt()}|)

      {0, stdout, ""} = ehosctl(["versions"], Keyword.put(opts, :dir, dir))

      table = table([["ehosctl", version_said(), "yes", "99.0.0", "yes"], @ehos_row])

      assert stdout == """
             Installation: local (#{provider.issuer}), EHOS 0.5.0-dev (1a000cc)
             ehosctl could not read the mix.lock of the application: mix.lock holds something other than Elixir terms.

             #{table}
             To move:
               #{@ehosctl_move}
             """
    end

    test "--json gives every row with its verdicts and reasons",
         %{provider: provider, opts: opts} do
      {0, json, ""} = ehosctl(["versions", "--json"], opts)

      assert JSON.decode!(json) ==
               report(provider, @described["accepts"], %{
                 "components" => [ehosctl_json(), ehos_json()]
               })
    end
  end

  test "an installation that predates GET /api/v1 is said to, and the rest is shown",
       %{provider: provider, opts: opts} do
    login!(provider, opts)

    FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ ->
      {404, %{"errors" => %{"detail" => "Not Found"}}}
    end)

    {0, stdout, ""} = ehosctl(["versions"], opts)

    table =
      table([
        ["ehosctl", version_said(), "unknown", "99.0.0", "unknown"],
        ["ehos", "not known", "n/a", "0.4.0", "n/a"]
      ])

    assert stdout == """
           Installation: local (#{provider.issuer}). Local has no GET /api/v1, which says what it accepts: its EHOS is older than this ehosctl.

           #{table}
           To move:
             #{@ehosctl_move}
           """
  end

  test "an installation that refuses is said to, and the rest is shown",
       %{provider: provider, opts: opts} do
    login!(provider, opts)
    described(provider)
    FakeProvider.answer_api(provider, 401, %{"error" => "expired"})

    {0, stdout, ""} = ehosctl(["versions"], opts)

    table =
      table([
        ["ehosctl", version_said(), "unknown", "99.0.0", "unknown"],
        ["ehos", "not known", "n/a", "0.4.0", "n/a"]
      ])

    assert stdout == """
           Installation: local (#{provider.issuer}). Local did not say what it accepts: Your sign-in has expired. Run `ehosctl login`.

           #{table}
           To move:
             #{@ehosctl_move}
           """
  end

  test "an installation it does not know is a usage error", %{opts: opts} do
    assert ehosctl(["versions", "--installation", "nope"], opts) ==
             {4, "",
              ~s(ehosctl: No installation is named "nope". Run `ehosctl installations list` to see the names, or `ehosctl login URL` to sign in to a new installation.\n)}
  end

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

  # The table of components as `versions` prints it under its header: each row after a space,
  # each column as wide as its widest cell and two spaces from the next, no space at a line's end.
  defp table(rows) do
    rows = [["COMPONENT", "IN USE", "ACCEPTED", "NEWEST", "NEWEST ACCEPTED"] | rows]

    widths =
      for column <- 0..4,
          do: rows |> Enum.map(&String.length(Enum.at(&1, column, ""))) |> Enum.max()

    Enum.map_join(rows, fn row ->
      line =
        row
        |> Enum.zip(widths)
        |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)

      String.trim_trailing(" " <> line) <> "\n"
    end)
  end

  # This ehosctl's version, as `versions` says it: with its commit while it is a `-dev`.
  defp version_said do
    version = Ehosctl.version()

    case {Version.parse!(version), Ehosctl.commit()} do
      {%Version{pre: [_ | _]}, commit} when is_binary(commit) ->
        "#{version} (#{String.slice(commit, 0, 7)})"

      _release ->
        version
    end
  end

  # `versions --json`'s report: the installation answering with what it accepts, and `fields`
  # over the rest of a report that reads no application.
  defp report(provider, accepts, fields) do
    Map.merge(
      %{
        "installation" => %{
          "name" => "local",
          "url" => provider.issuer,
          "unknown" => nil,
          "described" => %{@described | "accepts" => accepts}
        },
        "application" => nil,
        "components" => [],
        "documents" => [],
        "unread" => %{"application" => nil, "github" => [], "github_tags" => []},
        "listed_in_part" => [],
        "tags_listed_in_part" => []
      },
      fields
    )
  end

  defp application_json(dir, ehos_yaml),
    do: %{"dir" => dir, "manifest" => nil, "ehos_yaml" => ehos_yaml}

  defp ehos_yaml_json(schema, accepted),
    do: %{"document" => "ehos.yaml", "schema" => schema, "accepted" => accepted}

  # A component's row in `--json`, one the application does not use unless `fields` say so.
  defp component_json(component, fields) do
    Map.merge(
      %{
        "component" => component,
        "in_use" => nil,
        "accepted" => verdict("not_applicable"),
        "newest" => nil,
        "newest_accepted" => nil,
        "move" => nil
      },
      fields
    )
  end

  defp ehosctl_json do
    version = Ehosctl.version()

    component_json("ehosctl", %{
      "in_use" => %{
        "version" => version,
        "commit" => if(Version.parse!(version).pre != [], do: Ehosctl.commit()),
        "said" => version_said()
      },
      "accepted" => verdict("yes"),
      "newest" => newest("ehos-tools", "v99.0.0", "99.0.0"),
      "newest_accepted" => verdict("yes"),
      "move" => "mise use -g github:EmpoweredHouse/ehos-tools@99.0.0"
    })
  end

  defp ehos_json do
    component_json("ehos", %{
      "in_use" => %{
        "version" => "0.5.0-dev",
        "commit" => @described["commit"],
        "said" => "0.5.0-dev (1a000cc)"
      },
      "newest" => newest("eh-os", "v0.4.0", "0.4.0"),
      "newest_accepted" => verdict("not_applicable")
    })
  end

  defp ehos_design_json do
    component_json("ehos_design", %{
      "newest" => newest("ehos-tools", "ehos_design-v0.3.0", "0.3.0"),
      "newest_accepted" => verdict("not_applicable")
    })
  end

  defp newest(repository, tag, version),
    do: %{
      "tag" => tag,
      "version" => version,
      "url" => "https://github.com/EmpoweredHouse/#{repository}/releases/tag/#{tag}"
    }

  defp verdict(verdict, why \\ nil), do: %{"verdict" => verdict, "why" => why}
end

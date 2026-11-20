defmodule Ehosctl.VersionsTest do
  # `ehosctl apps register | show | review` (eh-os#340), and no `apps activate` (eh-os D-154).
  # Not async, through Ehosctl.SignInCase: each test compares stderr whole, which
  # capture_io(:stderr) captures for every process.
  use Ehosctl.SignInCase

  @new "sha256:" <> String.duplicate("ab", 32)
  @old "sha256:" <> String.duplicate("cd", 32)
  @manifest ~s({"schema": "ehos.manifest/v3",\n  "application": "ledger", "capabilities": []}\n)

  @clerk %{
    "name" => "ledger.clerk",
    "label" => "Clerk",
    "capabilities" => [
      %{
        "name" => "ledger.record_entry",
        "label" => "Record an entry",
        "kind" => "command",
        "principals" => ["person"]
      }
    ]
  }

  @versions %{
    "application" => "ledger",
    "versions" => [
      %{
        "digest" => @new,
        "authority_digest" => "sha256:" <> String.duplicate("ef", 32),
        "submitted_at" => "2026-10-10T12:00:00Z",
        "roles" => [@clerk]
      },
      %{"digest" => @old, "submitted_at" => "2026-10-01T12:00:00Z", "roles" => []}
    ],
    "environments" => [
      %{"name" => "staging", "in_force" => @old},
      %{"name" => "production", "in_force" => nil}
    ]
  }

  # `@versions`'s versions as `apps show --json` prints them: with no hosts outside the
  # installation, and no role a role may grant.
  @printed_versions [
    %{
      "digest" => @new,
      "authority_digest" => "sha256:" <> String.duplicate("ef", 32),
      "submitted_at" => "2026-10-10T12:00:00Z",
      "egress" => [],
      "roles" => [Map.put(@clerk, "may_grant", [])]
    },
    %{"digest" => @old, "submitted_at" => "2026-10-01T12:00:00Z", "egress" => [], "roles" => []}
  ]

  # `@versions`'s versions as `apps show` prints them.
  @shown_versions """
  Versions, newest first:
   VERSION              SUBMITTED             ROLES
   sha256:abababababab  2026-10-10T12:00:00Z  ledger.clerk
   sha256:cdcdcdcdcdcd  2026-10-01T12:00:00Z
  """

  @review %{
    "application" => "ledger",
    "environment" => "staging",
    "version" => @new,
    "in_force" => @old,
    "authority" => "changed",
    "diff" => %{
      "capabilities_added" => ["ledger.close_month"],
      "capabilities_removed" => [],
      "roles_added" => [],
      "roles_removed" => [],
      "roles_grown" => %{"ledger.clerk" => ["ledger.close_month"]},
      "roles_shrunk" => %{}
    },
    "described" => %{
      "capabilities" => %{},
      "roles_added" => [],
      "redescribed" => [],
      "grants_changed" => []
    }
  }

  # `@review` as `apps review --json` prints it: what it does not carry is printed empty, and
  # what a review is not said to hold is left out.
  @printed_review %{
    "application" => "ledger",
    "environment" => "staging",
    "version" => @new,
    "in_force" => @old,
    "authority" => "changed",
    "diff" => %{
      "capabilities_added" => ["ledger.close_month"],
      "capabilities_removed" => [],
      "roles_added" => [],
      "roles_removed" => [],
      "roles_grown" => %{"ledger.clerk" => ["ledger.close_month"]},
      "roles_shrunk" => %{},
      "egress_added" => [],
      "egress_removed" => [],
      "grants_widened" => %{},
      "grants_narrowed" => %{}
    },
    "described" => %{
      "roles_added" => [],
      "redescribed" => [],
      "grants_changed" => [],
      "grantable_grown" => []
    }
  }

  # `@review` as `apps review` prints it.
  @reviewed """
  What version sha256:abababababab of ledger in staging changes, compared with sha256:cdcdcdcdcdcd in force:
    capabilities added: ledger.close_month
    roles that grow, giving everyone bound to them more: ledger.clerk (ledger.close_month)
  """

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "apps register" do
    setup %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "manifest.json")
      File.write!(file, @manifest)
      %{manifest: file}
    end

    test "sends the manifest as it is, and says whether it was new",
         %{provider: provider, opts: opts, manifest: file} do
      answer = %{"application" => "ledger", "version" => "v-1", "digest" => @new}

      api(
        provider,
        "POST",
        "/api/v1/applications/manifests",
        201,
        Map.put(answer, "outcome", "created")
      )

      assert ehosctl(["apps", "register", file], opts) ==
               {0,
                """
                ✓ Registered a version of ledger. No environment runs it yet.
                  Version   #{@new}

                Next:
                  ehosctl apps review ledger #{@new} --env ENVIRONMENT --installation local
                """, ""}

      assert FakeProvider.requests(provider, "POST /api/v1/applications/manifests") == [
               %{
                 path: "/api/v1/applications/manifests",
                 query: %{},
                 body: @manifest,
                 content_type: "application/json"
               }
             ]

      api(
        provider,
        "POST",
        "/api/v1/applications/manifests",
        200,
        Map.put(answer, "outcome", "known")
      )

      assert ehosctl(["apps", "register", file], opts) ==
               {0, "· ledger already has this version. Nothing changed.\n  Version   #{@new}\n",
                ""}
    end

    test "prints a refused manifest's reasons under EHOS's sentence",
         %{provider: provider, opts: opts, manifest: file} do
      api(provider, "POST", "/api/v1/applications/manifests", 422, %{
        "error" => "invalid",
        "message" => "The manifest is refused.",
        "reasons" => ["roles.0.name is too long"]
      })

      assert ehosctl(["apps", "register", file], opts) ==
               {2, "", "ehosctl: The manifest is refused.\n  - roles.0.name is too long\n"}
    end

    test "a registration answered with an outcome its status does not mean is not taken",
         %{provider: provider, opts: opts, manifest: file} do
      api(provider, "POST", "/api/v1/applications/manifests", 201, %{
        "application" => "ledger",
        "version" => "v-1",
        "digest" => @new,
        "outcome" => "known"
      })

      assert ehosctl(["apps", "register", file], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. EHOS " <>
                  "answered 201, so it kept the version.\nWhat to do:\n  To see it, run:\n" <>
                  "  ehosctl apps show APPLICATION --installation local\n"}
    end

    test "writes a utility service's manifest from its ehos.yaml, as EHOS writes it, and " <>
           "sends that",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      api(provider, "POST", "/api/v1/applications/manifests", 201, %{
        "application" => "invoice-pdf",
        "version" => "v-1",
        "digest" => @new,
        "outcome" => "created"
      })

      for name <- ["ehos.yaml", "service.yml", "SERVICE.YAML"] do
        file = Path.join(tmp_dir, name)

        File.write!(file, """
        schema: ehos.yaml/v8
        kind: service
        application: invoice-pdf
        serves: [{name: http, port: 8080}]
        health: {port: 8081, ready: /ready, live: /live}
        """)

        assert ehosctl(["apps", "register", file], opts) ==
                 {0,
                  """
                  ✓ Registered a version of invoice-pdf. No environment runs it yet.
                    Version   #{@new}

                  Next:
                    ehosctl apps review invoice-pdf #{@new} --env ENVIRONMENT --installation local
                  """, ""}
      end

      # What eh-os's `EhosYaml.service_manifest/1` writes from the same file.
      manifest =
        ~s({"application":"invoice-pdf","ehos_yaml":"ehos.yaml/v8","health":{"live":"/live","port":8081,"ready":"/ready"},"kind":"service","schema":"ehos.manifest/v9","serves":[{"name":"http","port":8080}]})

      sent = %{
        path: "/api/v1/applications/manifests",
        query: %{},
        body: manifest,
        content_type: "application/json"
      }

      assert FakeProvider.requests(provider, "POST /api/v1/applications/manifests") ==
               [sent, sent, sent]
    end

    test "refuses an ehos.yaml with a key a utility service may not give, and sends nothing",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "ehos.yaml")

      File.write!(file, """
      schema: ehos.yaml/v8
      kind: service
      application: invoice-pdf
      health: {port: 8081, ready: /ready, live: /live}
      needs: {database: {engine: postgres}}
      """)

      assert ehosctl(["apps", "register", file], opts) ==
               {2, "",
                "ehosctl: ehosctl refuses #{file}:\n" <>
                  "  - line 5, needs.database: is not for a utility service, which keeps no " <>
                  "data of its own: remove it\n" <>
                  "ehosctl sent nothing.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/applications/manifests") == []
    end

    test "refuses an ehos.yaml that is not UTF-8, or larger than EHOS reads, and sends nothing",
         %{provider: provider, opts: opts, tmp_dir: tmp} do
      file = Path.join(tmp, "ehos.yaml")
      File.write!(file, <<0xFF>>)

      assert ehosctl(["apps", "register", file], opts) ==
               {2, "", "ehosctl: #{file} is not UTF-8 text, so it is not an ehos.yaml.\n"}

      File.write!(file, String.duplicate("#", 65_537))

      assert ehosctl(["apps", "register", file], opts) ==
               {2, "",
                "ehosctl: #{file} is larger than 65536 bytes. An ehos.yaml can have 65536 " <>
                  "bytes at most.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/applications/manifests") == []
    end

    test "a gateway's 5xx after a registration says it may have been kept",
         %{provider: provider, opts: opts, manifest: file} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/applications/manifests", fn _ ->
        {502, nil}
      end)

      assert ehosctl(["apps", "register", file], opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} is unavailable (HTTP 502). Try again later. EHOS " <>
                  "may have kept the version. If you register it again, nothing changes.\n"}
    end
  end

  describe "apps show" do
    test "lists the versions, and what is in force in each environment with its state",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)
      history(provider, "staging", deployment("active"))
      history(provider, "production", nil)

      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown("""
                 ENVIRONMENT  IN FORCE             STATE
                 staging      sha256:cdcdcdcdcdcd  active
                 production   none                 none
                """), ""}

      assert FakeProvider.requests(provider, "GET #{deployments("staging")}") == [
               %{
                 path: deployments("staging"),
                 query: %{"limit" => "5"},
                 body: "",
                 content_type: nil
               }
             ]

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

      assert JSON.decode!(json) ==
               printed_show([
                 environment_shown("staging", @old, "active", deployment("active")),
                 environment_shown("production", nil, "none", nil)
               ])
    end

    test "says the failure, cut short, of the newest deployment when it failed after the " <>
           "one in force, and else the state of the one in force",
         %{provider: provider, opts: opts} do
      failure = "Back-off pulling image: " <> String.duplicate("x", 80)
      failed = deployment("failed", failure, "d-2", "2026-10-12T10:05:00Z")
      activating = deployment("activating", nil, "d-3", "2026-10-12T10:10:00Z")

      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)
      history(provider, "staging", deployment("active"), [failed])

      # A failure older than the deployment in force is not what it came to.
      history(provider, "production", activating, [failed])

      cut = "failed: Back-off pulling image: " <> String.duplicate("x", 35) <> "…"

      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown("""
                 ENVIRONMENT  IN FORCE             STATE
                 staging      sha256:cdcdcdcdcdcd  #{cut}
                 production   none                 activating
                """), ""}

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

      assert JSON.decode!(json) ==
               printed_show([
                 environment_shown("staging", @old, "failed", deployment("active"), %{
                   "failed" => failed
                 }),
                 environment_shown("production", nil, "activating", activating)
               ])

      # With nothing in force, the first deployment failing is what the environment came to.
      history(provider, "production", nil, [failed])

      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown("""
                 ENVIRONMENT  IN FORCE             STATE
                 staging      sha256:cdcdcdcdcdcd  #{cut}
                 production   none                 #{cut}
                """), ""}
    end

    test "says where each deployment in force came from, by the kind EHOS gives, and " <>
           "nothing for one without a source",
         %{provider: provider, opts: opts} do
      run = %{
        "kind" => "github_run",
        "repository" => "example/ledger",
        "ref" => "refs/heads/main",
        "commit" => String.duplicate("0a", 20),
        "event" => "push",
        "run_id" => 18_512_345_678,
        "run_attempt" => 2
      }

      stated = %{
        "kind" => "stated",
        "commit" => String.duplicate("1b", 20),
        "ref" => "refs/tags/v1.2.0",
        "stated_by" => "ada@example.com"
      }

      envs = [%{"name" => "dev", "in_force" => @old} | @versions["environments"]]

      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, %{
        @versions
        | "environments" => envs
      })

      history(provider, "dev", deployment("active"))
      history(provider, "staging", Map.put(deployment("active"), "source", run))
      history(provider, "production", Map.put(deployment("active"), "source", stated))

      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown("""
                 ENVIRONMENT  IN FORCE             STATE
                 dev          sha256:cdcdcdcdcdcd  active
                 staging      sha256:cdcdcdcdcdcd  active
                 production   none                 active
                Where the deployment in force came from:
                  staging: from GitHub's token: example/ledger, branch main, commit #{String.duplicate("0a", 20)}, run 18512345678 (attempt 2)
                  production: stated by ada@example.com: commit #{String.duplicate("1b", 20)}, ref refs/tags/v1.2.0
                """), ""}

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

      assert JSON.decode!(json) ==
               printed_show([
                 environment_shown("dev", @old, "active", deployment("active")),
                 environment_shown(
                   "staging",
                   @old,
                   "active",
                   Map.put(deployment("active"), "source", run)
                 ),
                 environment_shown(
                   "production",
                   nil,
                   "active",
                   Map.put(deployment("active"), "source", stated)
                 )
               ])
    end

    test "takes a source of a kind a later EHOS adds by its kind alone, and prints nothing " <>
           "for it; one of another shape is dropped, not the environment's state",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)
      later = %{"kind" => "attested", "by" => "someone"}
      history(provider, "staging", Map.put(deployment("active"), "source", later))
      history(provider, "production", nil)

      active = """
       ENVIRONMENT  IN FORCE             STATE
       staging      sha256:cdcdcdcdcdcd  active
       production   none                 none
      """

      assert ehosctl(["apps", "show", "ledger"], opts) == {0, shown(active), ""}

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

      assert JSON.decode!(json) ==
               printed_show([
                 environment_shown(
                   "staging",
                   @old,
                   "active",
                   Map.put(deployment("active"), "source", %{"kind" => "attested"})
                 ),
                 environment_shown("production", nil, "none", nil)
               ])

      stated = %{"kind" => "stated", "ref" => "refs/heads/main", "stated_by" => "ada@example.com"}

      history(
        provider,
        "staging",
        Map.put(deployment("active"), "source", Map.put(stated, "x", 1))
      )

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

      assert JSON.decode!(json) ==
               printed_show([
                 environment_shown(
                   "staging",
                   @old,
                   "active",
                   Map.put(deployment("active"), "source", stated)
                 ),
                 environment_shown("production", nil, "none", nil)
               ])

      history(
        provider,
        "staging",
        Map.put(deployment("active"), "source", %{"kind" => "github_run", "run_id" => "1"})
      )

      assert ehosctl(["apps", "show", "ledger"], opts) == {0, shown(active), ""}
    end

    test "orders two deployments decided at the same moment by id, as EHOS does",
         %{provider: provider, opts: opts} do
      at = "2026-10-12T10:00:00Z"
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)

      history(provider, "staging", deployment("active", nil, "d-1", at), [
        deployment("failed", "it failed", "d-2", at)
      ])

      history(provider, "production", deployment("active", nil, "d-1", at), [
        deployment("failed", "it failed", "d-0", at)
      ])

      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown("""
                 ENVIRONMENT  IN FORCE             STATE
                 staging      sha256:cdcdcdcdcdcd  failed: it failed
                 production   none                 active
                """), ""}
    end

    # eh-os D-135: the hosts outside the installation a version reaches, in a column of their own.
    test "lists the hosts outside the installation each version reaches, keeps them under " <>
           "--json, and an older EHOS's versions have none",
         %{provider: provider, opts: opts} do
      hosts = ["api.example.com:443", "mail.example.com:587"]

      versions =
        @versions
        |> put_in(["versions", Access.at(0), "egress"], hosts)
        |> put_in(["versions", Access.at(1), "egress"], [])

      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, versions)
      history(provider, "staging", deployment("active"))
      history(provider, "production", nil)

      environments = """
       ENVIRONMENT  IN FORCE             STATE
       staging      sha256:cdcdcdcdcdcd  active
       production   none                 none
      """

      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown(environments, """
                Versions, newest first:
                 VERSION              SUBMITTED             ROLES         HOSTS OUTSIDE
                 sha256:abababababab  2026-10-10T12:00:00Z  ledger.clerk  api.example.com:443, mail.example.com:587
                 sha256:cdcdcdcdcdcd  2026-10-01T12:00:00Z                none
                """), ""}

      printed = [
        environment_shown("staging", @old, "active", deployment("active")),
        environment_shown("production", nil, "none", nil)
      ]

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

      assert JSON.decode!(json) ==
               printed_show(
                 printed,
                 put_in(@printed_versions, [Access.at(0), "egress"], hosts)
               )

      # The versions of an EHOS that predates `needs.egress` carry none, and no column is printed.
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)

      assert ehosctl(["apps", "show", "ledger"], opts) == {0, shown(environments), ""}

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)
      assert JSON.decode!(json) == printed_show(printed)

      # Hosts that are not text are refused, as any name in the listing is.
      for wrong <- [[443], "api.example.com:443"] do
        api(
          provider,
          "GET",
          "/api/v1/applications/ledger/versions",
          200,
          put_in(@versions, ["versions", Access.at(0), "egress"], wrong)
        )

        assert ehosctl(["apps", "show", "ledger"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"},
               inspect(wrong)
      end
    end

    # eh-os D-112: a role's rule is listed beside it, as the console shows it.
    test "lists the roles a role may grant beside it, and keeps the rule under --json",
         %{provider: provider, opts: opts} do
      versions =
        put_in(@versions, ["versions", Access.at(0), "roles", Access.at(0), "may_grant"], [
          "ledger.auditor"
        ])

      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, versions)
      history(provider, "staging", deployment("active"))
      history(provider, "production", nil)

      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown(
                  """
                   ENVIRONMENT  IN FORCE             STATE
                   staging      sha256:cdcdcdcdcdcd  active
                   production   none                 none
                  """,
                  """
                  Versions, newest first:
                   VERSION              SUBMITTED             ROLES
                   sha256:abababababab  2026-10-10T12:00:00Z  ledger.clerk (may grant ledger.auditor)
                   sha256:cdcdcdcdcdcd  2026-10-01T12:00:00Z
                  """
                ), ""}

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

      assert JSON.decode!(json) ==
               printed_show(
                 [
                   environment_shown("staging", @old, "active", deployment("active")),
                   environment_shown("production", nil, "none", nil)
                 ],
                 put_in(
                   @printed_versions,
                   [Access.at(0), "roles", Access.at(0), "may_grant"],
                   ["ledger.auditor"]
                 )
               )
    end

    test "says an environment whose deployments went unanswered is unknown, and why",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)
      history(provider, "production", nil)

      # EHOS stops answering at the read of staging: ehosctl gets no answer, a failure with
      # what to do in it.
      FakeProvider.stub_api(provider, "GET", deployments("staging"), fn _ ->
        FakeProvider.down(provider)
        {502, %{}}
      end)

      {0, _stdout, stderr} = ehosctl(["apps", "show", "ledger"], opts)

      assert stderr =~ "! The state of the deployment is unknown in staging"
      assert stderr =~ "#{provider.issuer} did not answer."
    end

    test "asks no other environment once the credential is not accepted",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)

      api(provider, "GET", deployments("staging"), 401, %{
        "error" => "expired",
        "message" => "The credential has expired."
      })

      history(provider, "production", nil)

      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown("""
                 ENVIRONMENT  IN FORCE             STATE
                 staging      sha256:cdcdcdcdcdcd  unknown
                 production   none                 unknown
                """),
                "! The state of the deployment is unknown in staging, production.\n" <>
                  "  The credential has expired.\n"}

      assert FakeProvider.requests(provider, "GET #{deployments("production")}") == []
    end

    test "against an EHOS without the deployments' route says once why each state is unknown",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)

      for env <- ["staging", "production"],
          do:
            api(provider, "GET", deployments(env), 404, %{"errors" => %{"detail" => "Not Found"}})

      api(provider, "GET", "/api/v1", 200, %{
        "component" => "ehos",
        "version" => "0.5.0",
        "commit" => nil,
        "produces" => ["ehos.api/v1"],
        "accepts" => [],
        "requires" => %{},
        "routes" => [%{"method" => "GET", "path" => "/api/v1/applications/:name/versions"}]
      })

      why =
        "#{provider.issuer} runs EHOS 0.5.0, which has no `GET #{deployments("staging")}`: this " <>
          "command needs a later EHOS. The operator upgrades EHOS to have it."

      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown("""
                 ENVIRONMENT  IN FORCE             STATE
                 staging      sha256:cdcdcdcdcdcd  unknown
                 production   none                 unknown
                """),
                "! The state of the deployment is unknown in staging, production.\n  #{why}\n"}

      assert FakeProvider.requests(provider, "GET #{deployments("production")}") == []

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

      unknown = %{"addresses" => nil, "why" => why}

      assert JSON.decode!(json) ==
               printed_show([
                 environment_shown("staging", @old, "unknown", nil, unknown),
                 environment_shown("production", nil, "unknown", nil, unknown)
               ])
    end

    test "says an environment whose deployments cannot be read is unknown, and why, and " <>
           "shows the others",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, %{
        @versions
        | "environments" => @versions["environments"] ++ [%{"name" => "..", "in_force" => nil}]
      })

      history(provider, "staging", deployment("active"))

      api(provider, "GET", deployments("production"), 403, %{
        "error" => "forbidden",
        "message" => "Reading its deployments needs more."
      })

      # A name that would leave its place in the path is not sent.
      assert ehosctl(["apps", "show", "ledger"], opts) ==
               {0,
                shown("""
                 ENVIRONMENT  IN FORCE             STATE
                 staging      sha256:cdcdcdcdcdcd  active
                 production   none                 unknown
                 ..           none                 unknown
                """),
                "! The state of the deployment is unknown in production.\n" <>
                  "  Reading its deployments needs more.\n" <>
                  "! The state of the deployment is unknown in ...\n" <>
                  "  .. is not the name of an application or an environment.\n"}

      {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

      assert JSON.decode!(json) ==
               printed_show([
                 environment_shown("staging", @old, "active", deployment("active")),
                 environment_shown("production", nil, "unknown", nil, %{
                   "addresses" => nil,
                   "why" => "Reading its deployments needs more."
                 }),
                 environment_shown("..", nil, "unknown", nil, %{
                   "addresses" => nil,
                   "why" => ".. is not the name of an application or an environment."
                 })
               ])
    end
  end

  describe "apps review" do
    test "shows what a version would change, the version named by its start",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)
      api(provider, "GET", review_path(@new), 200, %{"review" => @review})

      assert ehosctl(
               ["apps", "review", "ledger", "sha256:abababababab", "--env", "staging"],
               opts
             ) == {0, @reviewed, ""}

      assert FakeProvider.requests(provider, "GET " <> review_path(@new)) == [
               %{
                 path: review_path(@new),
                 query: %{"environment" => "staging"},
                 body: "",
                 content_type: nil
               }
             ]
    end

    # eh-os D-112: a rule that widens lets everyone bound to the role bring more people in.
    test "names the grant rules that widen and narrow, and an older EHOS's review has none",
         %{provider: provider, opts: opts} do
      widened = %{"ledger.clerk" => ["ledger.auditor"]}
      narrowed = %{"ledger.owner" => ["ledger.clerk"]}

      ruled =
        @review
        |> put_in(["diff", "grants_widened"], widened)
        |> put_in(["diff", "grants_narrowed"], narrowed)

      api(provider, "GET", review_path(@new), 200, %{"review" => ruled})

      assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
               {0,
                @reviewed <>
                  """
                    roles that may grant more, letting more people in: ledger.clerk (ledger.auditor)
                    roles that may grant less: ledger.owner (ledger.clerk)
                  """, ""}

      {0, json, ""} =
        ehosctl(["apps", "review", "ledger", @new, "--env", "staging", "--json"], opts)

      assert JSON.decode!(json) == %{
               "review" =>
                 @printed_review
                 |> put_in(["diff", "grants_widened"], widened)
                 |> put_in(["diff", "grants_narrowed"], narrowed)
             }

      # The review of an EHOS that predates grant rules carries neither key.
      api(provider, "GET", review_path(@new), 200, %{"review" => @review})

      {0, json, ""} =
        ehosctl(["apps", "review", "ledger", @new, "--env", "staging", "--json"], opts)

      assert JSON.decode!(json) == %{"review" => @printed_review}
    end

    # eh-os#722: a rule unchanged gives more when the role it names grows or gains a rule.
    test "names who may grant a role that gives more, and an older EHOS's review has none",
         %{provider: provider, opts: opts} do
      grantable_grown = [
        %{
          "role" => "ledger.auditor",
          "granted_by" => ["ledger.clerk", "ledger.owner"],
          "gains" => ["ledger.close_month"],
          "may_grant" => ["ledger.reader"]
        },
        %{
          "role" => "ledger.reader",
          "granted_by" => ["ledger.auditor"],
          "gains" => ["ledger.export"],
          "may_grant" => []
        }
      ]

      grown = put_in(@review, ["described", "grantable_grown"], grantable_grown)
      api(provider, "GET", review_path(@new), 200, %{"review" => grown})

      assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
               {0,
                @reviewed <>
                  "  roles others may grant that give more: ledger.clerk, ledger.owner may " <>
                  "grant ledger.auditor, which gains ledger.close_month and may now grant " <>
                  "ledger.reader; ledger.auditor may grant ledger.reader, which gains " <>
                  "ledger.export\n", ""}

      {0, json, ""} =
        ehosctl(["apps", "review", "ledger", @new, "--env", "staging", "--json"], opts)

      assert JSON.decode!(json) == %{
               "review" =>
                 put_in(@printed_review, ["described", "grantable_grown"], grantable_grown)
             }

      # The review of an EHOS before eh-os#722 carries none.
      api(provider, "GET", review_path(@new), 200, %{"review" => @review})

      assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
               {0, @reviewed, ""}

      {0, json, ""} =
        ehosctl(["apps", "review", "ledger", @new, "--env", "staging", "--json"], opts)

      assert JSON.decode!(json) == %{"review" => @printed_review}

      # One that is not as EHOS gives it is refused, as any review is: a name not text, nobody who
      # grants it, or nothing it gives more.
      entry = %{
        "role" => "ledger.auditor",
        "granted_by" => ["ledger.clerk"],
        "gains" => ["x"],
        "may_grant" => []
      }

      for wrong <- [
            %{entry | "role" => 1},
            %{entry | "granted_by" => []},
            %{entry | "gains" => []},
            %{entry | "may_grant" => [1]}
          ] do
        api(provider, "GET", review_path(@new), 200, %{
          "review" => put_in(@review, ["described", "grantable_grown"], [wrong])
        })

        assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"},
               inspect(wrong)
      end
    end

    # eh-os D-135: a host outside the installation is part of the authority, as a capability is.
    test "names the hosts outside the installation added and removed, and an older EHOS's " <>
           "review has none",
         %{provider: provider, opts: opts} do
      added = ["api.example.com:443", "mail.example.com:587"]
      removed = ["old.example.com:443"]

      egress =
        @review
        |> put_in(["diff", "egress_added"], added)
        |> put_in(["diff", "egress_removed"], removed)

      api(provider, "GET", review_path(@new), 200, %{"review" => egress})

      assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
               {0,
                @reviewed <>
                  """
                    hosts outside the installation added: api.example.com:443, mail.example.com:587
                    hosts outside the installation removed: old.example.com:443
                  """, ""}

      {0, json, ""} =
        ehosctl(["apps", "review", "ledger", @new, "--env", "staging", "--json"], opts)

      assert JSON.decode!(json) == %{
               "review" =>
                 @printed_review
                 |> put_in(["diff", "egress_added"], added)
                 |> put_in(["diff", "egress_removed"], removed)
             }

      # A version that changes nothing but its hosts still changes the authority, and says how:
      # not that it changes no one's authority, nor that no capability or role changes.
      hosts_only =
        %{
          @review
          | "diff" =>
              Map.new(@review["diff"], fn {k, v} -> {k, if(is_map(v), do: %{}, else: [])} end)
        }
        |> put_in(["diff", "egress_added"], ["api.example.com:443"])

      api(provider, "GET", review_path(@new), 200, %{"review" => hosts_only})

      assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
               {0,
                """
                What version sha256:abababababab of ledger in staging changes, compared with sha256:cdcdcdcdcdcd in force:
                  hosts outside the installation added: api.example.com:443
                """, ""}

      # The review of an EHOS that predates `needs.egress` carries neither key.
      api(provider, "GET", review_path(@new), 200, %{"review" => @review})

      assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
               {0, @reviewed, ""}

      {0, json, ""} =
        ehosctl(["apps", "review", "ledger", @new, "--env", "staging", "--json"], opts)

      assert JSON.decode!(json) == %{"review" => @printed_review}

      # A host that is not text is refused, as any name in a review is.
      for key <- ~w(egress_added egress_removed), wrong <- [[1], "api.example.com:443"] do
        api(provider, "GET", review_path(@new), 200, %{
          "review" => put_in(@review, ["diff", key], wrong)
        })

        assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"},
               inspect({key, wrong})
      end
    end

    test "--json prints only what a review is said to hold", %{provider: provider, opts: opts} do
      grown = %{
        "name" => "ledger.record_entry",
        "from" => %{"kind" => "query", "secret" => "x"},
        "to" => %{"kind" => "command"},
        "extra" => true
      }

      review = put_in(@review, ["described", "grants_changed"], [grown])
      api(provider, "GET", review_path(@new), 200, %{"review" => Map.put(review, "extra", 1)})

      {0, json, ""} =
        ehosctl(["apps", "review", "ledger", @new, "--env", "staging", "--json"], opts)

      assert JSON.decode!(json) == %{
               "review" =>
                 put_in(@printed_review, ["described", "grants_changed"], [
                   %{
                     "name" => "ledger.record_entry",
                     "from" => %{"kind" => "query"},
                     "to" => %{"kind" => "command"}
                   }
                 ])
             }
    end

    test "a review whose authority changes beyond what it lists says so",
         %{provider: provider, opts: opts} do
      empty =
        Map.new(@review["diff"], fn {key, value} ->
          {key, if(is_map(value), do: %{}, else: [])}
        end)

      api(provider, "GET", review_path(@new), 200, %{"review" => %{@review | "diff" => empty}})

      assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
               {0,
                """
                What version sha256:abababababab of ledger in staging changes, compared with sha256:cdcdcdcdcdcd in force:
                  No capability or role is added, removed or relabelled, but its authority changes: what a capability runs, or what the application needs, differs.
                """, ""}
    end

    test "a whole digest without its algorithm is one, and a start of several is refused",
         %{provider: provider, opts: opts} do
      twin = "sha256:" <> String.duplicate("ab", 31) <> "ff"

      versions =
        update_in(@versions["versions"], &[%{"digest" => twin, "roles" => []} | &1])

      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, versions)
      api(provider, "GET", review_path(@new), 200, %{"review" => @review})

      "sha256:" <> hex = @new

      assert ehosctl(["apps", "review", "ledger", hex, "--env", "staging"], opts) ==
               {0, @reviewed, ""}

      assert ehosctl(["apps", "review", "ledger", "abababababab", "--env", "staging"], opts) ==
               {2, "",
                "ehosctl: 2 versions of ledger start with sha256:abababababab. Give more of the " <>
                  "digest.\n"}
    end

    test "a version's start that names none, or several, is said so before any review",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)

      assert ehosctl(
               ["apps", "review", "ledger", "sha256:000000000000", "--env", "staging"],
               opts
             ) ==
               {1, "",
                "ehosctl: ledger has no version whose digest starts with sha256:000000000000.\n"}

      assert ehosctl(["apps", "review", "ledger", "abc", "--env", "staging"], opts) ==
               {2, "",
                "ehosctl: abc is not a version. Give its digest, sha256: and 64 digits, or at " <>
                  "least its first 12 digits.\n"}

      assert FakeProvider.requests(provider, "GET " <> review_path(@new)) == []
    end

    test "an answer about another application, version or environment is not taken",
         %{provider: provider, opts: opts} do
      cannot_read = "ehosctl: #{provider.issuer} answered with something ehosctl cannot read."

      # A review naming something else is not printed, an escape sequence in it least of all.
      for review <- [
            %{@review | "application" => "other"},
            %{@review | "environment" => "production"},
            %{@review | "in_force" => "sha256:\e[2J"}
          ] do
        api(provider, "GET", review_path(@new), 200, %{"review" => review})

        assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
                 {1, "", cannot_read <> "\n"}
      end

      # A listing of another application's versions resolves nothing.
      api(provider, "GET", "/api/v1/applications/ledger/versions", 200, %{
        @versions
        | "application" => "other"
      })

      assert ehosctl(["apps", "show", "ledger"], opts) == {1, "", cannot_read <> "\n"}
    end
  end

  describe "apps review, against nothing" do
    test "says that nothing is in force there", %{provider: provider, opts: opts} do
      api(provider, "GET", review_path(@new), 200, %{"review" => %{@review | "in_force" => nil}})

      assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
               {0,
                """
                What version sha256:abababababab of ledger in staging changes, compared with nothing in force:
                  capabilities added: ledger.close_month
                  roles that grow, giving everyone bound to them more: ledger.clerk (ledger.close_month)
                """, ""}
    end
  end

  describe "apps review, refused" do
    test "exits with its kind's code", %{provider: provider, opts: opts} do
      api(provider, "GET", review_path(@new), 403, %{
        "error" => "forbidden",
        "message" =>
          "Reviewing a version needs ehos.application.register for the application, in that environment or in all of them."
      })

      assert ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts) ==
               {3, "",
                "ehosctl: Reviewing a version needs ehos.application.register for the application, in that environment or in all of them.\n"}
    end
  end

  # eh-os D-154: only a deployment puts a version in force, so nothing here sends an activation.
  describe "apps activate" do
    test "is no command, and sends nothing", %{provider: provider, opts: opts} do
      assert ehosctl(["apps", "activate", "ledger", @new, "--env", "staging"], opts) ==
               {2, "",
                ~s(ehosctl: unrecognized arguments: "activate", "ledger", "#{@new}", "--env", ) <>
                  ~s("staging"\n\nSee `ehosctl help apps`.\n)}

      assert FakeProvider.requests(provider, "POST " <> activate_path(@new)) == []
    end
  end

  describe "apps" do
    test "alone still lists the applications you may use", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/me/applications", 200, %{"applications" => []})

      assert ehosctl(["apps"], opts) ==
               {0,
                "No applications in local. An application shows here when you have a role " <>
                  "binding to one of its roles.\n", ""}
    end
  end

  # What `apps show ledger` prints: the environments' table and what is said under it, then the
  # versions.
  defp shown(environments, versions \\ @shown_versions),
    do: "ledger\n\n" <> environments <> "\n" <> versions

  # What `apps show ledger --json` prints.
  defp printed_show(environments, versions \\ @printed_versions),
    do: %{"application" => "ledger", "environments" => environments, "versions" => versions}

  # An environment as `apps show --json` prints it, with the addresses `history/4` gives it.
  defp environment_shown(name, in_force, state, deployment, fields \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "in_force" => in_force,
        "state" => state,
        "deployment" => deployment,
        "failed" => nil,
        "addresses" => if(deployment, do: ["https://ledger.#{name}.example.com"], else: []),
        "why" => nil
      },
      fields
    )
  end

  # The requests sent to EHOS's API as `"<METHOD> <path>"`, each with its JSON body decoded.

  defp review_path(digest), do: "/api/v1/applications/ledger/versions/#{digest}/review"
  defp activate_path(digest), do: "/api/v1/applications/ledger/versions/#{digest}/activate"

  defp deployments(env), do: "/api/v1/applications/ledger/environments/#{env}/deployments"

  # The deployments of ledger in `env`, as EHOS lists them (eh-os#413).
  defp history(provider, env, in_force, before \\ []),
    do:
      api(provider, "GET", deployments(env), 200, %{
        "application" => "ledger",
        "environment" => env,
        "in_force" => in_force,
        "addresses" => if(in_force, do: ["https://ledger.#{env}.example.com"], else: []),
        "before" => before
      })

  defp deployment(state, failure \\ nil, id \\ "d-1", at \\ "2026-10-12T10:00:00Z"),
    do: %{
      "kind" => "deployment",
      "id" => id,
      "state" => state,
      "image" => "ghcr.io/example/ledger@sha256:" <> String.duplicate("a1", 32),
      "manifest_digest" => @old,
      "failure" => failure,
      "by" => "grace@example.com",
      "at" => at
    }
end

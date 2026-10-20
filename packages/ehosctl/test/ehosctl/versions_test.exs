defmodule Ehosctl.VersionsTest do
  # `ehosctl apps register | show | review | activate` (eh-os#340).
  use Ehosctl.SignInCase

  @new "sha256:" <> String.duplicate("ab", 32)
  @old "sha256:" <> String.duplicate("cd", 32)
  @manifest ~s({"schema": "ehos.manifest/v3",\n  "application": "ledger", "capabilities": []}\n)

  @versions %{
    "application" => "ledger",
    "versions" => [
      %{
        "digest" => @new,
        "authority_digest" => "sha256:" <> String.duplicate("ef", 32),
        "submitted_at" => "2026-10-10T12:00:00Z",
        "roles" => [
          %{
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
        ]
      },
      %{"digest" => @old, "submitted_at" => "2026-10-01T12:00:00Z", "roles" => []}
    ],
    "environments" => [
      %{"name" => "staging", "in_force" => @old},
      %{"name" => "production", "in_force" => nil}
    ]
  }

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

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp api(provider, method, path, status, body),
    do: FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  defp review_path(digest), do: "/api/v1/applications/ledger/versions/#{digest}/review"
  defp activate_path(digest), do: "/api/v1/applications/ledger/versions/#{digest}/activate"

  describe "register" do
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

      {0, stdout, ""} = ehosctl(["apps", "register", file], opts)
      assert stdout =~ "Registered #{@new} of ledger. It is in force nowhere"

      assert [request] = FakeProvider.requests(provider, "POST /api/v1/applications/manifests")
      assert request.body == @manifest
      assert request.content_type == "application/json"

      api(
        provider,
        "POST",
        "/api/v1/applications/manifests",
        200,
        Map.put(answer, "outcome", "known")
      )

      {0, stdout, ""} = ehosctl(["apps", "register", file], opts)
      assert stdout =~ "ledger already has #{@new}; nothing changed."
    end

    test "prints a refused manifest's reasons under EHOS's sentence",
         %{provider: provider, opts: opts, manifest: file} do
      api(provider, "POST", "/api/v1/applications/manifests", 422, %{
        "error" => "invalid",
        "message" => "The manifest is refused.",
        "reasons" => ["roles.0.name is too long"]
      })

      {2, "", stderr} = ehosctl(["apps", "register", file], opts)
      assert stderr =~ "The manifest is refused.\n  - roles.0.name is too long"
    end
  end

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

  test "show lists the versions, and what is in force in each environment with its state",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)
    history(provider, "staging", deployment("active"))
    history(provider, "production", nil)

    {0, stdout, ""} = ehosctl(["apps", "show", "ledger"], opts)
    assert stdout =~ ~r/ENVIRONMENT\s+IN FORCE\s+STATE\n/
    assert stdout =~ ~r/staging\s+sha256:cdcdcdcdcdcd\s+active\n/
    assert stdout =~ ~r/production\s+none\s+none\n/
    assert stdout =~ ~r/sha256:abababababab\s+2026-10-10T12:00:00Z\s+ledger\.clerk/
    assert [request] = FakeProvider.requests(provider, "GET #{deployments("staging")}")
    assert request.query == %{"limit" => "5"}

    {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

    assert JSON.decode!(json)["environments"] == [
             %{
               "name" => "staging",
               "in_force" => @old,
               "state" => "active",
               "deployment" => deployment("active"),
               "failed" => nil,
               "addresses" => ["https://ledger.staging.example.com"],
               "why" => nil
             },
             %{
               "name" => "production",
               "in_force" => nil,
               "state" => "none",
               "deployment" => nil,
               "failed" => nil,
               "addresses" => [],
               "why" => nil
             }
           ]
  end

  test "show says the failure, cut short, of the newest deployment when it failed after the " <>
         "one in force, and else the state of the one in force",
       %{provider: provider, opts: opts} do
    failure = "Back-off pulling image: " <> String.duplicate("x", 80)
    failed = deployment("failed", failure, "d-2", "2026-10-12T10:05:00Z")

    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)
    history(provider, "staging", deployment("active"), [failed])

    # A failure older than the deployment in force is not what it came to.
    history(
      provider,
      "production",
      deployment("activating", nil, "d-3", "2026-10-12T10:10:00Z"),
      [
        failed
      ]
    )

    {0, stdout, ""} = ehosctl(["apps", "show", "ledger"], opts)
    assert stdout =~ ~r/staging\s+sha256:cdcdcdcdcdcd\s+failed: Back-off pulling image: x{35}…\n/
    assert stdout =~ ~r/production\s+none\s+activating\n/

    {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

    assert [
             %{"state" => "failed", "failed" => ^failed, "deployment" => %{"state" => "active"}},
             %{"state" => "activating", "failed" => nil}
           ] = JSON.decode!(json)["environments"]

    # With nothing in force, the first deployment failing is what the environment came to.
    history(provider, "production", nil, [failed])
    {0, stdout, ""} = ehosctl(["apps", "show", "ledger"], opts)
    assert stdout =~ ~r/production\s+none\s+failed: Back-off/
  end

  test "show orders two deployments decided at the same moment by id, as EHOS does",
       %{provider: provider, opts: opts} do
    at = "2026-10-12T10:00:00Z"
    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)

    history(provider, "staging", deployment("active", nil, "d-1", at), [
      deployment("failed", "it failed", "d-2", at)
    ])

    history(provider, "production", deployment("active", nil, "d-1", at), [
      deployment("failed", "it failed", "d-0", at)
    ])

    {0, stdout, ""} = ehosctl(["apps", "show", "ledger"], opts)
    assert stdout =~ ~r/staging\s+sha256:cdcdcdcdcdcd\s+failed: it failed\n/
    assert stdout =~ ~r/production\s+none\s+active\n/
  end

  test "show asks no other environment once the credential is not accepted",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)

    api(provider, "GET", deployments("staging"), 401, %{
      "error" => "expired",
      "message" => "The credential has expired."
    })

    history(provider, "production", nil)

    {0, stdout, ""} = ehosctl(["apps", "show", "ledger"], opts)
    assert stdout =~ ~r/staging\s+sha256:cdcdcdcdcdcd\s+unknown\n/
    assert stdout =~ ~r/production\s+none\s+unknown\n/
    assert stdout =~ "The deployment state is unknown in staging, production: "
    assert FakeProvider.requests(provider, "GET #{deployments("production")}") == []
  end

  test "show against an EHOS without the deployments' route says once why each state is unknown",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)

    for env <- ["staging", "production"],
        do: api(provider, "GET", deployments(env), 404, %{"errors" => %{"detail" => "Not Found"}})

    api(provider, "GET", "/api/v1", 200, %{
      "component" => "ehos",
      "version" => "0.5.0",
      "commit" => nil,
      "produces" => ["ehos.api/v1"],
      "accepts" => [],
      "requires" => %{},
      "routes" => [%{"method" => "GET", "path" => "/api/v1/applications/:name/versions"}]
    })

    {0, stdout, ""} = ehosctl(["apps", "show", "ledger"], opts)
    assert stdout =~ ~r/staging\s+sha256:cdcdcdcdcdcd\s+unknown\n/
    assert stdout =~ ~r/production\s+none\s+unknown\n/

    assert stdout =~
             "The deployment state is unknown in staging, production: #{provider.issuer} runs " <>
               "EHOS 0.5.0, which has no `GET #{deployments("staging")}`"

    assert FakeProvider.requests(provider, "GET #{deployments("production")}") == []

    {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

    assert [%{"state" => "unknown", "deployment" => nil}, %{"state" => "unknown"}] =
             JSON.decode!(json)["environments"]
  end

  test "show says an environment whose deployments cannot be read is unknown, and why, and " <>
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

    {0, stdout, ""} = ehosctl(["apps", "show", "ledger"], opts)
    assert stdout =~ ~r/staging\s+sha256:cdcdcdcdcdcd\s+active\n/
    assert stdout =~ ~r/production\s+none\s+unknown\n/

    assert stdout =~
             "The deployment state is unknown in production: Reading its deployments needs more.\n"

    # A name that would leave its place in the path is not sent.
    assert stdout =~
             "The deployment state is unknown in ..: .. names no application or environment.\n"

    {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

    assert [_, %{"state" => "unknown", "why" => "Reading its deployments needs more."}, _] =
             JSON.decode!(json)["environments"]
  end

  test "review shows what activating would change, a version named by its start",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)
    api(provider, "GET", review_path(@new), 200, %{"review" => @review})

    {0, stdout, ""} =
      ehosctl(["apps", "review", "ledger", "sha256:abababababab", "--env", "staging"], opts)

    assert stdout =~
             "Activating sha256:abababababab of ledger in staging, replacing sha256:cdcdcdcdcdcd:"

    assert stdout =~ "capabilities added: ledger.close_month"

    assert stdout =~
             "roles that grow, giving everyone bound to them more: ledger.clerk (ledger.close_month)"

    assert [%{query: %{"environment" => "staging"}}] =
             FakeProvider.requests(provider, "GET " <> review_path(@new))
  end

  test "a version's start that names none, or several, is said so before any review",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, @versions)

    {1, "", stderr} =
      ehosctl(["apps", "review", "ledger", "sha256:000000000000", "--env", "staging"], opts)

    assert stderr =~ "no version whose digest starts sha256:000000000000"

    {2, "", stderr} = ehosctl(["apps", "review", "ledger", "abc", "--env", "staging"], opts)
    assert stderr =~ "is not a version"
    assert FakeProvider.requests(provider, "GET " <> review_path(@new)) == []
  end

  test "activate reviews, then activates replacing what the review showed in force",
       %{provider: provider, opts: opts} do
    api(provider, "GET", review_path(@new), 200, %{"review" => @review})

    api(provider, "POST", activate_path(@new), 200, %{
      "in_force" => %{
        "application" => "ledger",
        "environment" => "staging",
        "version" => @new,
        "activated_at" => "2026-10-10T12:30:00Z"
      }
    })

    {0, stdout, ""} = ehosctl(["apps", "activate", "ledger", @new, "--env", "staging"], opts)
    assert stdout =~ "roles that grow"
    assert stdout =~ "sha256:abababababab is in force in staging."

    assert [%{body: body}] = FakeProvider.requests(provider, "POST " <> activate_path(@new))
    assert JSON.decode!(body) == %{"environment" => "staging", "replacing" => @old}
  end

  test "an activation refused because the version in force changed exits 1",
       %{provider: provider, opts: opts} do
    api(provider, "GET", review_path(@new), 200, %{"review" => %{@review | "in_force" => nil}})

    api(provider, "POST", activate_path(@new), 409, %{
      "error" => "changed",
      "message" => "The version in force in staging changed after the review. Review again."
    })

    {1, "", stderr} = ehosctl(["apps", "activate", "ledger", @new, "--env", "staging"], opts)
    assert stderr =~ "changed after the review"

    assert [%{body: body}] = FakeProvider.requests(provider, "POST " <> activate_path(@new))
    assert JSON.decode!(body)["replacing"] == nil
  end

  test "a refused review exits with its kind's code, and nothing is activated",
       %{provider: provider, opts: opts} do
    api(provider, "GET", review_path(@new), 403, %{
      "error" => "forbidden",
      "message" => "To review needs ehos.application.register there."
    })

    {3, "", stderr} = ehosctl(["apps", "activate", "ledger", @new, "--env", "staging"], opts)
    assert stderr =~ "ehos.application.register"
    assert FakeProvider.requests(provider, "POST " <> activate_path(@new)) == []
  end

  test "a whole digest without its algorithm is one, and a start of several is refused",
       %{provider: provider, opts: opts} do
    twin = "sha256:" <> String.duplicate("ab", 31) <> "ff"

    versions =
      update_in(@versions["versions"], &[%{"digest" => twin, "roles" => []} | &1])

    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, versions)
    api(provider, "GET", review_path(@new), 200, %{"review" => @review})

    "sha256:" <> hex = @new
    {0, _stdout, ""} = ehosctl(["apps", "review", "ledger", hex, "--env", "staging"], opts)

    {2, "", stderr} =
      ehosctl(["apps", "review", "ledger", "abababababab", "--env", "staging"], opts)

    assert stderr =~ "2 versions of ledger start sha256:abababababab"
  end

  test "an answer about another application, version or environment is not taken",
       %{provider: provider, opts: opts} do
    for review <- [
          %{@review | "application" => "other"},
          %{@review | "environment" => "production"},
          %{@review | "in_force" => "sha256:\e[2J"}
        ] do
      api(provider, "GET", review_path(@new), 200, %{"review" => review})

      {1, "", stderr} = ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts)
      assert stderr =~ "cannot read"
      refute stderr =~ "\e"
    end

    api(provider, "GET", review_path(@new), 200, %{"review" => @review})

    api(provider, "POST", activate_path(@new), 200, %{
      "in_force" => %{"application" => "ledger", "environment" => "staging", "version" => @old}
    })

    {1, "", stderr} = ehosctl(["apps", "activate", "ledger", @new, "--env", "staging"], opts)
    assert stderr =~ "not as what was asked"

    api(provider, "POST", activate_path(@new), 200, %{
      "in_force" => %{"application" => "other", "environment" => "staging", "version" => @new}
    })

    {1, "", stderr} = ehosctl(["apps", "activate", "ledger", @new, "--env", "staging"], opts)
    assert stderr =~ "not as what was asked"

    # A listing of another application's versions resolves nothing.
    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, %{
      @versions
      | "application" => "other"
    })

    {1, "", stderr} = ehosctl(["apps", "show", "ledger"], opts)
    assert stderr =~ "cannot read"
  end

  # eh-os D-112: a rule that widens lets everyone bound to the role bring more people in.
  test "review names the grant rules that widen and narrow, and an older EHOS's review has none",
       %{provider: provider, opts: opts} do
    ruled =
      @review
      |> put_in(["diff", "grants_widened"], %{"ledger.clerk" => ["ledger.auditor"]})
      |> put_in(["diff", "grants_narrowed"], %{"ledger.owner" => ["ledger.clerk"]})

    api(provider, "GET", review_path(@new), 200, %{"review" => ruled})

    {0, stdout, ""} = ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts)

    assert stdout =~
             "roles that may grant more, letting more people in: ledger.clerk (ledger.auditor)"

    assert stdout =~ "roles that may grant less: ledger.owner (ledger.clerk)"

    {0, json, ""} =
      ehosctl(["apps", "review", "ledger", @new, "--env", "staging", "--json"], opts)

    assert %{
             "review" => %{
               "diff" => %{"grants_widened" => %{"ledger.clerk" => ["ledger.auditor"]}}
             }
           } =
             JSON.decode!(json)

    # The review of an EHOS that predates grant rules carries neither key.
    api(provider, "GET", review_path(@new), 200, %{"review" => @review})

    {0, json, ""} =
      ehosctl(["apps", "review", "ledger", @new, "--env", "staging", "--json"], opts)

    assert %{"review" => %{"diff" => %{"grants_widened" => %{}, "grants_narrowed" => %{}}}} =
             JSON.decode!(json)
  end

  # eh-os D-112: a role's rule is listed beside it, as the console shows it.
  test "show lists the roles a role may grant beside it, and keeps the rule under --json",
       %{provider: provider, opts: opts} do
    versions =
      put_in(@versions, ["versions", Access.at(0), "roles", Access.at(0), "may_grant"], [
        "ledger.auditor"
      ])

    api(provider, "GET", "/api/v1/applications/ledger/versions", 200, versions)
    history(provider, "staging", deployment("active"))
    history(provider, "production", nil)

    {0, stdout, ""} = ehosctl(["apps", "show", "ledger"], opts)
    assert stdout =~ "ledger.clerk (may grant ledger.auditor)"

    {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)

    assert [%{"may_grant" => ["ledger.auditor"]}] =
             hd(JSON.decode!(json)["versions"])["roles"]
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

    %{"review" => printed} = JSON.decode!(json)
    refute Map.has_key?(printed, "extra")

    assert printed["described"]["grants_changed"] == [
             %{
               "name" => "ledger.record_entry",
               "from" => %{"kind" => "query"},
               "to" => %{"kind" => "command"}
             }
           ]
  end

  test "a registration answered with an outcome its status does not mean is not taken",
       %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "manifest.json")
    File.write!(file, @manifest)

    api(provider, "POST", "/api/v1/applications/manifests", 201, %{
      "application" => "ledger",
      "version" => "v-1",
      "digest" => @new,
      "outcome" => "known"
    })

    {1, "", stderr} = ehosctl(["apps", "register", file], opts)
    assert stderr =~ "`ehosctl apps show <application>`"
  end

  test "a review whose authority changes beyond what it lists says so",
       %{provider: provider, opts: opts} do
    empty =
      Map.new(@review["diff"], fn {key, value} -> {key, if(is_map(value), do: %{}, else: [])} end)

    api(provider, "GET", review_path(@new), 200, %{"review" => %{@review | "diff" => empty}})

    {0, stdout, ""} = ehosctl(["apps", "review", "ledger", @new, "--env", "staging"], opts)
    assert stdout =~ "but its authority changes"
  end

  test "a gateway's 5xx after a registration says it may have been kept",
       %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "manifest.json")
    File.write!(file, @manifest)

    FakeProvider.stub_api(provider, "POST", "/api/v1/applications/manifests", fn _ ->
      {502, nil}
    end)

    {_code, "", stderr} = ehosctl(["apps", "register", file], opts)
    assert stderr =~ "It may have been kept: registering it again changes nothing."
  end

  test "apps alone still lists the applications you may use", %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/me/applications", 200, %{"applications" => []})

    {0, stdout, ""} = ehosctl(["apps"], opts)
    assert stdout =~ "None of your roles"
  end
end

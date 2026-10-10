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

  defp review_path(digest), do: "/api/applications/ledger/versions/#{digest}/review"
  defp activate_path(digest), do: "/api/applications/ledger/versions/#{digest}/activate"

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
        "/api/applications/manifests",
        201,
        Map.put(answer, "outcome", "created")
      )

      {0, stdout, ""} = ehosctl(["apps", "register", file], opts)
      assert stdout =~ "Registered #{@new} of ledger. It is in force nowhere"

      assert [request] = FakeProvider.requests(provider, "POST /api/applications/manifests")
      assert request.body == @manifest
      assert request.content_type == "application/json"

      api(
        provider,
        "POST",
        "/api/applications/manifests",
        200,
        Map.put(answer, "outcome", "known")
      )

      {0, stdout, ""} = ehosctl(["apps", "register", file], opts)
      assert stdout =~ "ledger already has #{@new}; nothing changed."
    end

    test "prints a refused manifest's reasons under EHOS's sentence",
         %{provider: provider, opts: opts, manifest: file} do
      api(provider, "POST", "/api/applications/manifests", 422, %{
        "error" => "invalid",
        "message" => "The manifest is refused.",
        "reasons" => ["roles.0.name is too long"]
      })

      {2, "", stderr} = ehosctl(["apps", "register", file], opts)
      assert stderr =~ "The manifest is refused.\n  - roles.0.name is too long"
    end
  end

  test "show lists the versions and what is in force in each environment",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/applications/ledger/versions", 200, @versions)

    {0, stdout, ""} = ehosctl(["apps", "show", "ledger"], opts)
    assert stdout =~ ~r/staging\s+sha256:cdcdcdcdcdcd/
    assert stdout =~ ~r/production\s+none/
    assert stdout =~ ~r/sha256:abababababab\s+2026-10-10T12:00:00Z\s+ledger\.clerk/

    {0, json, ""} = ehosctl(["apps", "show", "ledger", "--json"], opts)
    assert JSON.decode!(json)["environments"] == @versions["environments"]
  end

  test "review shows what activating would change, a version named by its start",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/applications/ledger/versions", 200, @versions)
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
    api(provider, "GET", "/api/applications/ledger/versions", 200, @versions)

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

    api(provider, "GET", "/api/applications/ledger/versions", 200, versions)
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
    assert stderr =~ "something other than what was asked"
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

    api(provider, "POST", "/api/applications/manifests", 201, %{
      "application" => "ledger",
      "version" => "v-1",
      "digest" => @new,
      "outcome" => "known"
    })

    {1, "", stderr} = ehosctl(["apps", "register", file], opts)
    assert stderr =~ "`ehosctl apps show <application>`"
  end

  test "apps alone still lists the applications you may use", %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/me/applications", 200, %{"applications" => []})

    {0, stdout, ""} = ehosctl(["apps"], opts)
    assert stdout =~ "None of your roles"
  end
end

defmodule Ehosctl.EnvTemplatesTest do
  use Ehosctl.SignInCase

  @path "/api/v1/environment-templates"
  @sandbox %{
    "name" => "sandbox",
    "seed_profile" => nil,
    "default" => true,
    "quota" => nil,
    "limits" => nil,
    "bindings" => [%{"kind" => "postgres", "resource" => "trial"}]
  }
  @limits [
    %{
      "type" => "Container",
      "default" => %{"memory" => "512Mi"},
      "max" => %{"memory" => "1Gi"}
    }
  ]

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp api(provider, method, path, status, body),
    do: FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  defp sent(provider, request) do
    assert [%{body: body}] = FakeProvider.requests(provider, request)
    JSON.decode!(body)
  end

  describe "env template list and show" do
    test "lists the templates, and --json prints them", %{provider: provider, opts: opts} do
      small = %{@sandbox | "name" => "small", "default" => false, "quota" => %{"pods" => "4"}}
      tight = %{@sandbox | "name" => "tight", "default" => false, "limits" => @limits}
      api(provider, "GET", @path, 200, %{"templates" => [@sandbox, small, tight]})

      {0, stdout, ""} = ehosctl(["env", "template", "list"], opts)
      assert stdout =~ ~r/NAME\s+SEED PROFILE\s+OF ITS OWN\s+RESOURCES/
      assert stdout =~ ~r/sandbox \(default\)\s+postgres: trial/
      assert stdout =~ ~r/small\s+quota\s+postgres/
      # Limits of its own are said too, not taken for a template with nothing of its own.
      assert stdout =~ ~r/tight\s+limits\s+postgres/

      {0, json, ""} = ehosctl(["env", "template", "list", "--json"], opts)
      assert %{"templates" => [@sandbox, _small, _tight]} = JSON.decode!(json)
    end

    test "shows a template with its quota and limits", %{provider: provider, opts: opts} do
      template = %{
        @sandbox
        | "seed_profile" => "demo",
          "quota" => %{"pods" => "10", "limits.memory" => "4Gi"},
          "limits" => @limits
      }

      api(provider, "GET", @path <> "/sandbox", 200, %{"template" => template})

      {0, stdout, ""} = ehosctl(["env", "template", "show", "sandbox"], opts)
      assert stdout =~ "sandbox, the installation's default"
      assert stdout =~ "Seed profile: demo"
      assert stdout =~ "Quota: limits.memory 4Gi, pods 10"
      assert stdout =~ "Limits: Container: default memory 512Mi; max memory 1Gi"
      assert stdout =~ ~r/postgres\s+trial/
    end

    test "says a template with nothing of its own takes the installation's", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", @path <> "/bare", 200, %{
        "template" => %{@sandbox | "name" => "bare", "default" => false, "bindings" => []}
      })

      {0, stdout, ""} = ehosctl(["env", "template", "show", "bare"], opts)
      assert stdout =~ "Seed profile: none"
      assert stdout =~ "Quota: the installation's"
      assert stdout =~ "Limits: the installation's"
      assert stdout =~ "No resources"
    end

    test "refuses an answer it cannot read", %{provider: provider, opts: opts} do
      api(provider, "GET", @path, 200, %{"templates" => [%{"name" => "sandbox"}]})

      assert {1, "", stderr} = ehosctl(["env", "template", "list"], opts)
      assert stderr =~ "cannot read"
    end
  end

  describe "env template create and update" do
    @describetag :tmp_dir

    test "creates a template with a quota and limits from a file", %{
      provider: provider,
      opts: opts,
      tmp_dir: tmp_dir
    } do
      file = Path.join(tmp_dir, "limits.json")
      File.write!(file, JSON.encode!(@limits))
      api(provider, "POST", @path, 201, %{"template" => %{@sandbox | "bindings" => []}})

      {0, stdout, ""} =
        ehosctl(
          [
            "env",
            "template",
            "create",
            "sandbox",
            "--seed-profile",
            "demo",
            "--default",
            "--quota",
            "pods=10,limits.memory=4Gi",
            "--limits",
            file
          ],
          opts
        )

      assert stdout =~ "Created sandbox, the installation's default."

      assert sent(provider, "POST " <> @path) == %{
               "name" => "sandbox",
               "seed_profile" => "demo",
               "default" => true,
               "quota" => %{"pods" => "10", "limits.memory" => "4Gi"},
               "limits" => @limits
             }
    end

    test "sends only what is given, and '' gives a field back", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "PATCH", @path <> "/sandbox", 200, %{"template" => @sandbox})

      {0, stdout, ""} =
        ehosctl(
          ["env", "template", "update", "sandbox", "--quota", "", "--limits", "", "--no-default"],
          opts
        )

      assert stdout =~ "Changed sandbox"

      assert sent(provider, "PATCH " <> @path <> "/sandbox") == %{
               "quota" => nil,
               "limits" => nil,
               "default" => false
             }
    end

    test "reads a quota written with spaces around its pairs", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "PATCH", @path <> "/sandbox", 200, %{"template" => @sandbox})

      {0, _stdout, ""} =
        ehosctl(
          ["env", "template", "update", "sandbox", "--quota", "pods = 10, limits.memory=4Gi"],
          opts
        )

      assert sent(provider, "PATCH " <> @path <> "/sandbox") == %{
               "quota" => %{"pods" => "10", "limits.memory" => "4Gi"}
             }
    end

    test "refuses what it can tell is wrong before sending", %{
      provider: provider,
      opts: opts,
      tmp_dir: tmp_dir
    } do
      not_a_list = Path.join(tmp_dir, "limits.json")
      File.write!(not_a_list, ~s({"type": "Container"}))

      for {argv, said} <- [
            {["update", "sandbox"], "Say what to change"},
            {["update", "sandbox", "--default", "--no-default"], "opposite things"},
            {["create", "sandbox", "--quota", "pods"], "not KEY=VALUE"},
            {["create", "sandbox", "--quota", "pods=1,pods=2"], "names pods twice"},
            {["create", "sandbox", "--limits", not_a_list], "holds no JSON list"},
            {["show", ".."], "names no template"}
          ] do
        assert {2, "", stderr} = ehosctl(["env", "template" | argv], opts)
        assert stderr =~ said
      end

      assert FakeProvider.requests(provider, "POST " <> @path) == []
      assert FakeProvider.requests(provider, "PATCH " <> @path <> "/sandbox") == []
    end

    test "says a creation or change answered for another template did something", %{
      provider: provider,
      opts: opts
    } do
      other = %{@sandbox | "name" => "other"}
      api(provider, "POST", @path, 201, %{"template" => other})
      api(provider, "PATCH", @path <> "/sandbox", 200, %{"template" => other})

      for argv <- [["create", "sandbox"], ["update", "sandbox", "--default"]] do
        assert {1, "", stderr} = ehosctl(["env", "template" | argv], opts)
        assert stderr =~ "`ehosctl env template show`"
      end
    end

    test "prints EHOS's refusal of a quota above the ceiling", %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 422, %{
        "error" => "invalid",
        "message" => "Some fields do not fit: quota pods is above the installation's ceiling, 6.",
        "fields" => %{"quota" => ["pods is above the installation's ceiling, 6"]}
      })

      assert {2, "", stderr} =
               ehosctl(["env", "template", "create", "big", "--quota", "pods=60"], opts)

      assert stderr =~ "quota pods is above the installation's ceiling, 6."

      api(provider, "PATCH", @path <> "/small", 409, %{
        "error" => "default_taken",
        "message" => "Another template became the default meanwhile; try again to take it."
      })

      assert {1, "", stderr} = ehosctl(["env", "template", "update", "small", "--default"], opts)
      assert stderr =~ "try again"
    end
  end

  describe "env template remove, bind and unbind" do
    test "removes a template", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @path <> "/small", 200, %{"template" => %{"name" => "small"}})

      {0, stdout, ""} = ehosctl(["env", "template", "remove", "small"], opts)
      assert stdout =~ "Removed small: environments made from it keep what they were made with."
    end

    test "says a template holding secrets is not removed", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @path <> "/small", 409, %{
        "error" => "in_use",
        "message" =>
          "The template holds an application's secret as a default; delete those first."
      })

      assert {1, "", stderr} = ehosctl(["env", "template", "remove", "small"], opts)
      assert stderr =~ "delete those first"
    end

    test "binds and unbinds a resource by its kind", %{provider: provider, opts: opts} do
      api(provider, "POST", @path <> "/sandbox/bindings", 201, %{
        "binding" => %{"kind" => "postgres", "resource" => "trial"}
      })

      api(provider, "DELETE", @path <> "/sandbox/bindings/postgres", 200, %{
        "binding" => %{"kind" => "postgres"}
      })

      {0, stdout, ""} = ehosctl(["env", "template", "bind", "sandbox", "trial"], opts)
      assert stdout =~ "sandbox now gives trial for postgres."
      assert sent(provider, "POST " <> @path <> "/sandbox/bindings") == %{"resource" => "trial"}

      {0, stdout, ""} = ehosctl(["env", "template", "unbind", "sandbox", "postgres"], opts)
      assert stdout =~ "sandbox now names no resource for postgres."
    end

    test "says a bind answered for another resource did something", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "POST", @path <> "/sandbox/bindings", 201, %{
        "binding" => %{"kind" => "postgres", "resource" => "shared"}
      })

      assert {1, "", stderr} = ehosctl(["env", "template", "bind", "sandbox", "trial"], opts)
      assert stderr =~ "`ehosctl env template show`"
    end

    test "prints a bind across the line in EHOS's words", %{provider: provider, opts: opts} do
      api(provider, "POST", @path <> "/sandbox/bindings", 422, %{
        "error" => "across_the_line",
        "message" => "A template names only a resource serving non-production."
      })

      assert {2, "", "ehosctl: A template names only a resource serving non-production.\n"} =
               ehosctl(["env", "template", "bind", "sandbox", "main"], opts)
    end

    test "says an unbind answered for another kind did something", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "DELETE", @path <> "/sandbox/bindings/postgres", 200, %{
        "binding" => %{"kind" => "redis"}
      })

      # Not a success: EHOS did something other than what was asked.
      assert {1, "", stderr} =
               ehosctl(["env", "template", "unbind", "sandbox", "postgres"], opts)

      assert stderr =~ "`ehosctl env template show`"
    end
  end

  describe "env show" do
    test "prints the quota and limits an ephemeral environment was given", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", "/api/v1/environments/ledger-pr-1", 200, %{
        "environment" => %{
          "name" => "ledger-pr-1",
          "type" => "ephemeral",
          "application" => "ledger",
          "template" => "sandbox",
          "expires_at" => "2026-10-25T10:00:00Z",
          "quota" => %{"pods" => "6"},
          "limits" => nil,
          "bindings" => []
        }
      })

      {0, stdout, ""} = ehosctl(["env", "show", "ledger-pr-1"], opts)
      assert stdout =~ "Quota: pods 6"
      assert stdout =~ "Limits: the installation's"

      {0, json, ""} = ehosctl(["env", "show", "ledger-pr-1", "--json"], opts)

      assert %{"environment" => %{"quota" => %{"pods" => "6"}, "limits" => nil}} =
               JSON.decode!(json)
    end
  end
end

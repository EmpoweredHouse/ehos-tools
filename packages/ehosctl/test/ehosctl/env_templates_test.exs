defmodule Ehosctl.EnvTemplatesTest do
  # Not async, through Ehosctl.SignInCase: each test compares stderr whole, which
  # capture_io(:stderr) captures for every process.
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
  @done_otherwise "It answered that something was done, but not as what was asked.\n" <>
                    "What to do:\n  See what was done:\n  ehosctl env template list --installation local"

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "env template list and show" do
    test "lists the templates, and --json prints them", %{provider: provider, opts: opts} do
      sandbox = %{@sandbox | "seed_profile" => "demo"}
      small = %{@sandbox | "name" => "small", "default" => false, "quota" => %{"pods" => "4"}}
      tight = %{@sandbox | "name" => "tight", "default" => false, "limits" => @limits}
      both = %{small | "name" => "both", "limits" => @limits}
      # A profile may be named none, which a template without one must not read as.
      named = %{small | "name" => "named", "seed_profile" => "none"}
      # A seed profile cleared with --seed-profile '' comes back empty, and is said as one too.
      bare = %{
        @sandbox
        | "name" => "bare",
          "default" => false,
          "seed_profile" => "",
          "bindings" => []
      }

      api(provider, "GET", @path, 200, %{
        "templates" => [sandbox, small, tight, both, named, bare]
      })

      # Nothing of its own is said, not left as an empty cell, which reads as not known; limits
      # of its own are said too, not taken for a template with nothing of its own. No seed
      # profile and no resources are said as well, each in a cell of its own: a name that is
      # not there as `<none>`, which no name can be.
      assert ehosctl(["env", "template", "list"], opts) ==
               {0,
                """
                 NAME               SEED PROFILE  OF ITS OWN     RESOURCES
                 sandbox (default)  demo          none           postgres: trial
                 small              <none>        quota          postgres: trial
                 tight              <none>        limits         postgres: trial
                 both               <none>        quota, limits  postgres: trial
                 named              none          quota          postgres: trial
                 bare               <none>        none           <none>
                """, ""}

      {0, json, ""} = ehosctl(["env", "template", "list", "--json"], opts)

      assert JSON.decode!(json) == %{
               "templates" => [sandbox, small, tight, both, named, bare]
             }
    end

    test "shows a template with its quota and limits", %{provider: provider, opts: opts} do
      template = %{
        @sandbox
        | "seed_profile" => "demo",
          "quota" => %{"pods" => "10", "limits.memory" => "4Gi"},
          "limits" => @limits
      }

      api(provider, "GET", @path <> "/sandbox", 200, %{"template" => template})

      assert ehosctl(["env", "template", "show", "sandbox"], opts) ==
               {0,
                """
                sandbox, the default of the installation
                Seed profile: demo
                Quota: limits.memory 4Gi, pods 10
                Limits: Container: default memory 512Mi; max memory 1Gi
                Secret defaults: this installation does not say them

                 KIND      RESOURCE
                 postgres  trial
                """, ""}
    end

    test "says a template with nothing of its own takes the installation's", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", @path <> "/bare", 200, %{
        "template" => %{@sandbox | "name" => "bare", "default" => false, "bindings" => []}
      })

      assert ehosctl(["env", "template", "show", "bare"], opts) ==
               {0,
                """
                bare
                Seed profile: <none>
                Quota: the installation's
                Limits: the installation's
                Secret defaults: this installation does not say them

                No resources. An environment made from it gets no resource until you run `ehosctl env template bind bare RESOURCE`.
                """, ""}
    end

    # eh-os#988: the applications keeping secret defaults on a template, which hold its removal.
    test "lists how many applications keep secret defaults on each template", %{
      provider: provider,
      opts: opts
    } do
      kept = %{
        "applications" => [%{"name" => "office-client", "secrets" => 2}],
        "others" => 1
      }

      held = Map.put(@sandbox, "secret_defaults", kept)

      free =
        Map.put(%{@sandbox | "name" => "free", "default" => false}, "secret_defaults", %{
          "applications" => [],
          "others" => 0
        })

      # An installation older than eh-os#988 says nothing of them.
      older = %{@sandbox | "name" => "older", "default" => false}
      api(provider, "GET", @path, 200, %{"templates" => [held, free, older]})

      assert ehosctl(["env", "template", "list"], opts) ==
               {0,
                """
                 NAME               SEED PROFILE  OF ITS OWN  RESOURCES        SECRET DEFAULTS
                 sandbox (default)  <none>        none        postgres: trial  2 applications
                 free               <none>        none        postgres: trial  none
                 older              <none>        none        postgres: trial
                """, ""}

      {0, json, ""} = ehosctl(["env", "template", "list", "--json"], opts)
      assert JSON.decode!(json) == %{"templates" => [held, free, older]}

      # From an installation that says none of them, no column for them.
      api(provider, "GET", @path, 200, %{"templates" => [older]})

      assert ehosctl(["env", "template", "list"], opts) ==
               {0,
                """
                 NAME   SEED PROFILE  OF ITS OWN  RESOURCES
                 older  <none>        none        postgres: trial
                """, ""}
    end

    test "shows the applications keeping secret defaults on a template, named as far as EHOS names them",
         %{provider: provider, opts: opts} do
      for {kept, said} <- [
            {%{"applications" => [%{"name" => "office-client", "secrets" => 2}], "others" => 0},
             "office-client (2 secrets)"},
            {%{"applications" => [%{"name" => "office-client", "secrets" => 2}], "others" => 1},
             "office-client (2 secrets) and 1 other application whose secrets you may not list"},
            {%{"applications" => [], "others" => 2},
             "2 applications whose secrets you may not list"},
            {%{"applications" => [], "others" => 0}, "none"}
          ] do
        api(provider, "GET", @path <> "/sandbox", 200, %{
          "template" => Map.put(@sandbox, "secret_defaults", kept)
        })

        assert ehosctl(["env", "template", "show", "sandbox"], opts) ==
                 {0, sandbox_shown(said), ""}
      end

      # An installation older than eh-os#988 does not say them, and `show` says so, since a
      # refused removal points here.
      api(provider, "GET", @path <> "/sandbox", 200, %{"template" => @sandbox})

      assert ehosctl(["env", "template", "show", "sandbox"], opts) ==
               {0, sandbox_shown("this installation does not say them"), ""}
    end

    test "refuses secret defaults it cannot read", %{provider: provider, opts: opts} do
      for kept <- [
            %{"applications" => [%{"name" => "office-client"}], "others" => 0},
            %{"applications" => [], "others" => -1},
            %{"applications" => "office-client", "others" => 0},
            "office-client"
          ] do
        api(provider, "GET", @path <> "/sandbox", 200, %{
          "template" => Map.put(@sandbox, "secret_defaults", kept)
        })

        assert ehosctl(["env", "template", "show", "sandbox"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
      end
    end

    test "refuses an answer it cannot read", %{provider: provider, opts: opts} do
      api(provider, "GET", @path, 200, %{"templates" => [%{"name" => "sandbox"}]})

      assert ehosctl(["env", "template", "list"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
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

      argv = [
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
      ]

      assert ehosctl(argv, opts) ==
               {0,
                "Created the environment template sandbox, the default of the installation. " <>
                  "Give it resources with `ehosctl env template bind sandbox RESOURCE`.\n", ""}

      assert json_requests(provider, "POST " <> @path) == [
               json_request(@path, %{
                 "name" => "sandbox",
                 "seed_profile" => "demo",
                 "default" => true,
                 "quota" => %{"pods" => "10", "limits.memory" => "4Gi"},
                 "limits" => @limits
               })
             ]
    end

    test "sends only what is given, and '' gives a field back", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "PATCH", @path <> "/sandbox", 200, %{"template" => @sandbox})

      assert ehosctl(
               [
                 "env",
                 "template",
                 "update",
                 "sandbox",
                 "--quota",
                 "",
                 "--limits",
                 "",
                 "--no-default"
               ],
               opts
             ) ==
               {0, "Changed the environment template sandbox, the default of the installation.\n",
                ""}

      assert json_requests(provider, "PATCH " <> @path <> "/sandbox") == [
               json_request(@path <> "/sandbox", %{
                 "quota" => nil,
                 "limits" => nil,
                 "default" => false
               })
             ]
    end

    test "reads a quota written with spaces around its pairs", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "PATCH", @path <> "/sandbox", 200, %{"template" => @sandbox})

      assert ehosctl(
               [
                 "env",
                 "template",
                 "update",
                 "sandbox",
                 "--quota",
                 "pods = 10, limits.memory=4Gi"
               ],
               opts
             ) ==
               {0, "Changed the environment template sandbox, the default of the installation.\n",
                ""}

      assert json_requests(provider, "PATCH " <> @path <> "/sandbox") == [
               json_request(@path <> "/sandbox", %{
                 "quota" => %{"pods" => "10", "limits.memory" => "4Gi"}
               })
             ]
    end

    test "refuses what it can tell is wrong before sending", %{
      provider: provider,
      opts: opts,
      tmp_dir: tmp_dir
    } do
      not_a_list = Path.join(tmp_dir, "limits.json")
      File.write!(not_a_list, ~s({"type": "Container"}))

      pairs =
        "Give pairs such as pods=10,limits.memory=4Gi, or '' to use the quota of the installation."

      for {argv, said} <- [
            {["update", "sandbox"],
             "Nothing to change. Give --seed-profile, --quota, --limits, --default or --no-default."},
            {["update", "sandbox", "--default", "--no-default"],
             "--default and --no-default contradict each other. Give one of them."},
            {["create", "sandbox", "--quota", "pods"],
             "--quota has pods, which is not KEY=VALUE. " <> pairs},
            {["create", "sandbox", "--quota", "pods=1,pods=2"],
             "--quota names pods twice. " <> pairs},
            {["create", "sandbox", "--limits", not_a_list],
             "--limits #{not_a_list} does not hold a JSON list. Give the limits of a LimitRange, such as " <>
               ~s([{"type": "Container", "default": {"memory": "512Mi"}}].)},
            {["show", ".."],
             ".. is not the name of an environment template, a resource or a kind of need."}
          ] do
        assert ehosctl(["env", "template" | argv], opts) == {2, "", "ehosctl: #{said}\n"}
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
        assert ehosctl(["env", "template" | argv], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. " <>
                    @done_otherwise <> "\n"}
      end
    end

    test "prints EHOS's refusal of a quota above the ceiling", %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 422, %{
        "error" => "invalid",
        "message" => "Some fields do not fit: quota pods is above the installation's ceiling, 6.",
        "fields" => %{"quota" => ["pods is above the installation's ceiling, 6"]}
      })

      assert ehosctl(["env", "template", "create", "big", "--quota", "pods=60"], opts) ==
               {2, "",
                "ehosctl: Some fields do not fit: quota pods is above the installation's " <>
                  "ceiling, 6.\n"}

      api(provider, "PATCH", @path <> "/small", 409, %{
        "error" => "default_taken",
        "message" => "Another template became the default meanwhile; try again to take it."
      })

      assert ehosctl(["env", "template", "update", "small", "--default"], opts) ==
               {1, "",
                "ehosctl: Another template became the default meanwhile; try again to take it.\n"}
    end
  end

  describe "env template remove, bind and unbind" do
    test "removes a template", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @path <> "/small", 200, %{"template" => %{"name" => "small"}})

      assert ehosctl(["env", "template", "remove", "small"], opts) ==
               {0,
                "Removed the environment template small. The environments made from it keep what they got from it.\n",
                ""}
    end

    test "binds and unbinds a resource by its kind", %{provider: provider, opts: opts} do
      api(provider, "POST", @path <> "/sandbox/bindings", 201, %{
        "binding" => %{"kind" => "postgres", "resource" => "trial"}
      })

      api(provider, "DELETE", @path <> "/sandbox/bindings/postgres", 200, %{
        "binding" => %{"kind" => "postgres"}
      })

      assert ehosctl(["env", "template", "bind", "sandbox", "trial"], opts) ==
               {0, "The environment template sandbox now gives trial for postgres.\n", ""}

      assert json_requests(provider, "POST " <> @path <> "/sandbox/bindings") == [
               json_request(@path <> "/sandbox/bindings", %{"resource" => "trial"})
             ]

      assert ehosctl(["env", "template", "unbind", "sandbox", "postgres"], opts) ==
               {0, "The environment template sandbox now gives no resource for postgres.\n", ""}
    end

    test "says a template holding secrets is not removed", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @path <> "/small", 409, %{
        "error" => "in_use",
        "message" =>
          "The template holds an application's secret as a default; delete those first."
      })

      # EHOS's sentence says secrets hold it, and `show` says whose (eh-os#988).
      assert ehosctl(["env", "template", "remove", "small"], opts) ==
               {1, "",
                "ehosctl: The template holds an application's secret as a default; delete " <>
                  "those first. Run `ehosctl env template show small` to see the " <>
                  "applications that keep them.\n"}
    end

    test "says a bind answered for another resource did something", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "POST", @path <> "/sandbox/bindings", 201, %{
        "binding" => %{"kind" => "postgres", "resource" => "shared"}
      })

      assert ehosctl(["env", "template", "bind", "sandbox", "trial"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. " <>
                  @done_otherwise <> "\n"}
    end

    test "prints a bind across the line in EHOS's words", %{provider: provider, opts: opts} do
      api(provider, "POST", @path <> "/sandbox/bindings", 422, %{
        "error" => "across_the_line",
        "message" => "A template names only a resource serving non-production."
      })

      assert ehosctl(["env", "template", "bind", "sandbox", "main"], opts) ==
               {2, "", "ehosctl: A template names only a resource serving non-production.\n"}
    end

    test "says an unbind answered for another kind did something", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "DELETE", @path <> "/sandbox/bindings/postgres", 200, %{
        "binding" => %{"kind" => "redis"}
      })

      # Not a success: EHOS did something other than what was asked.
      assert ehosctl(["env", "template", "unbind", "sandbox", "postgres"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. " <>
                  @done_otherwise <> "\n"}
    end
  end

  describe "env show" do
    test "prints the quota and limits an ephemeral environment was given", %{
      provider: provider,
      opts: opts
    } do
      environment = %{
        "name" => "ledger-pr-1",
        "type" => "ephemeral",
        "application" => "ledger",
        "template" => "sandbox",
        "expires_at" => "2026-10-25T10:00:00Z",
        "quota" => %{"pods" => "6"},
        "limits" => nil,
        "bindings" => []
      }

      api(provider, "GET", "/api/v1/environments/ledger-pr-1", 200, %{
        "environment" => environment
      })

      # Neither label says "over the installation's": an ephemeral environment's carry none.
      assert ehosctl(["env", "show", "ledger-pr-1"], opts) ==
               {0,
                """
                ledger-pr-1
                  Type                   ephemeral
                  Application            ledger
                  Environment template   sandbox
                  Expires                2026-10-25T10:00:00Z
                  Quota                  pods 6
                  Limits                 the installation's

                No resource bindings.

                Next:
                  ehosctl env bind ledger-pr-1 RESOURCE --installation local
                """, ""}

      {0, json, ""} = ehosctl(["env", "show", "ledger-pr-1", "--json"], opts)
      assert JSON.decode!(json) == %{"environment" => environment}
    end
  end

  describe "env show of an environment made without its template's entries" do
    test "says it has none of them", %{provider: provider, opts: opts} do
      environment = %{
        "name" => "ledger-pr-1",
        "type" => "ephemeral",
        "application" => "ledger",
        "template" => "sandbox",
        "expires_at" => "2026-10-25T10:00:00Z",
        "template_entries" => false,
        "bindings" => []
      }

      api(provider, "GET", "/api/v1/environments/ledger-pr-1", 200, %{
        "environment" => environment
      })

      assert ehosctl(["env", "show", "ledger-pr-1"], opts) ==
               {0,
                """
                ledger-pr-1
                  Type                   ephemeral
                  Application            ledger
                  Environment template   sandbox
                  Expires                2026-10-25T10:00:00Z
                  It has no role bindings and no people agreement from the environment template.

                No resource bindings.

                Next:
                  ehosctl env bind ledger-pr-1 RESOURCE --installation local
                """, ""}

      {0, json, ""} = ehosctl(["env", "show", "ledger-pr-1", "--json"], opts)
      assert JSON.decode!(json) == %{"environment" => environment}
    end
  end

  # What `env template show sandbox` prints of `@sandbox` with its secret defaults said as `said`.
  defp sandbox_shown(said) do
    """
    sandbox, the default of the installation
    Seed profile: <none>
    Quota: the installation's
    Limits: the installation's
    Secret defaults: #{said}

     KIND      RESOURCE
     postgres  trial
    """
  end

  # The requests sent to EHOS's API as `"<METHOD> <path>"`, each with its JSON body decoded.
end

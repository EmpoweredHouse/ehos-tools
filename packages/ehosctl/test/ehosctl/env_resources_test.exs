defmodule Ehosctl.EnvResourcesTest do
  # Not async, through `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process
  # shares.
  use Ehosctl.SignInCase

  @staging %{"name" => "staging", "type" => "ephemeral"}
  @outside %{
    "name" => "billing-db",
    "kind" => "postgres",
    "provider" => "external",
    "version" => 17,
    "host" => "billing-db.example.com",
    "port" => 5432,
    "database" => "ehos",
    "listed" => true,
    "serves" => "production",
    "state" => "not_fit",
    "checked_at" => "2026-11-18T10:42:00Z",
    "secret" => "do-not-print"
  }
  @shown @outside
         |> Map.delete("secret")
         |> Map.merge(%{
           "check" => %{
             "message" => "The certificate does not verify.",
             "server_version" => nil,
             "lines" => [
               %{"name" => "reachable", "passed" => true, "message" => "The server answers."},
               %{
                 "name" => "certificate",
                 "passed" => false,
                 "message" => "The certificate does not verify."
               }
             ],
             "groups" => [
               %{
                 "name" => "ehos_ledger_production_read",
                 "members" => 1,
                 "listed" => [
                   %{"role" => "ana", "admin" => false, "inherit" => true, "set" => false}
                 ]
               },
               %{"name" => "ehos_ledger_production_write", "members" => 0, "listed" => nil}
             ],
             "groups_omitted" => 0
           },
           "bindings" => [
             %{
               "environment" => "production",
               "application" => "ledger",
               "schema" => "ehos_ledger_production",
               "used" => true
             }
           ]
         })
  @binding %{
    "id" => "b-1",
    "kind" => "postgres",
    "resource" => "shared-1",
    "application" => nil,
    "schema" => nil,
    "used" => false
  }
  @pr %{
    "name" => "ledger-pr-12",
    "type" => "ephemeral",
    "application" => "ledger",
    "template" => "small",
    "expires_at" => "2026-10-17T15:00:00Z"
  }

  @no_app "An ephemeral environment needs --app with the name of its application. For " <>
            "another type of environment, give --type."
  @ephemeral_only "--template, --ttl and --no-role-bindings apply only to an ephemeral " <>
                    "environment. Give --app, or leave them out."
  @not_duration "is not a duration. Give a number and a unit, such as 90m, 24h or 7d."
  @not_confirmed "so ehosctl removed nothing."
  @no_name_again "ehosctl: Nothing was removed: ehosctl removes ledger-pr-12 only when you " <>
                   "give the name again. Type the name when ehosctl asks on a terminal, or " <>
                   "give --confirm ledger-pr-12.\n"

  # Before a person creates an environment a pull request's pipeline may deploy to, or remove.
  @pr_warning "If the repository previews pull requests, the pipeline of a pull request " <>
                "deploys to ledger-pr-12. Its deployment replaces yours there and withdraws a " <>
                "promotion that waits for a candidate there. When the pull request closes, its " <>
                "pipeline can remove ledger-pr-12.\n"
  @at_application "This application has the maximum number of ephemeral environments: 3. " <>
                    "Remove one, then try again."
  @at_installation "The installation has the maximum number of ephemeral environments: 6. " <>
                     "Remove one, then try again."
  @pr_build %{
    "id" => "7c1e0000-0000-4000-8000-000000000012",
    "image" => "registry.example.com/ledger@sha256:" <> String.duplicate("a", 64),
    "image_digest" => "sha256:" <> String.duplicate("a", 64),
    "manifest_digest" => "sha256:" <> String.duplicate("b", 64),
    "bundle_digest" => String.duplicate("c", 64),
    "ref" => "refs/pull/12/merge",
    "source" => %{
      "kind" => "github_run",
      "repository" => "acme/ledger",
      "ref" => "refs/pull/12/merge",
      "commit" => String.duplicate("4", 40),
      "event" => "pull_request",
      "run_id" => 41,
      "run_attempt" => 1
    },
    "stated" => %{
      "pull_request" => %{
        "number" => 12,
        "head" => String.duplicate("9", 40),
        "title" => "Rooms by floor"
      }
    },
    "registered_at" => "2026-11-04T09:00:00Z",
    "registered_by" => nil
  }
  @main_build %{
    @pr_build
    | "id" => "7c1e0000-0000-4000-8000-00000000000a",
      "ref" => "refs/heads/main",
      "source" => %{@pr_build["source"] | "ref" => "refs/heads/main", "event" => "push"},
      "stated" => %{"title" => "Release rooms"}
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "env" do
    test "lists the environments, and --json prints them", %{provider: provider, opts: opts} do
      production = %{"name" => "production", "type" => "production"}

      api(provider, "GET", "/api/v1/environments", 200, %{
        "environments" => [@staging, production]
      })

      {0, stdout, ""} = ehosctl(["env", "list"], opts)

      assert stdout == """
              NAME        TYPE        APPLICATION  TEMPLATE  EXPIRES
              staging     ephemeral   <none>       <none>    never
              production  production  <none>       <none>    never
             """

      {0, json, ""} = ehosctl(["env", "list", "--json"], opts)
      assert JSON.decode!(json) == %{"environments" => [@staging, production]}
    end

    test "shows an environment with its bindings", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/environments/staging", 200, %{
        "environment" => Map.put(@staging, "bindings", [@binding])
      })

      {0, stdout, ""} = ehosctl(["env", "show", "staging"], opts)

      # A binding with no schema says so, rather than leaving the cell empty, which reads as not
      # known.
      assert stdout == """
             staging, ephemeral

              KIND      RESOURCE  FOR      SCHEMA  USED  ID
              postgres  shared-1  default  <none>  no    b-1
             """
    end

    test "says a binding's empty application and schema as not given, in show and bind", %{
      provider: provider,
      opts: opts
    } do
      own = %{@binding | "id" => "b-2", "application" => "ledger", "schema" => "ehos_ledger_s"}
      empty = %{@binding | "id" => "b-3", "application" => "", "schema" => ""}
      unschemed = %{own | "id" => "b-4", "schema" => ""}
      no_id = %{@binding | "id" => ""}

      api(provider, "GET", "/api/v1/environments/staging", 200, %{
        "environment" => Map.put(@staging, "bindings", [own, empty, no_id])
      })

      # Only what may be absent is read as not given: an empty id is not printed as nil.
      {0, stdout, ""} = ehosctl(["env", "show", "staging"], opts)

      assert stdout == """
             staging, ephemeral

              KIND      RESOURCE  FOR      SCHEMA         USED  ID
              postgres  shared-1  ledger   ehos_ledger_s  no    b-2
              postgres  shared-1  default  <none>         no    b-3
              postgres  shared-1  default  <none>         no
             """

      # --json keeps what EHOS answered.
      {0, json, ""} = ehosctl(["env", "show", "staging", "--json"], opts)

      assert JSON.decode!(json) == %{
               "environment" => Map.put(@staging, "bindings", [own, empty, no_id])
             }

      mock_binding(provider, unschemed, empty)

      assert ehosctl(["env", "bind", "staging", "shared-1"], opts) ==
               {0,
                "Bound shared-1 in staging as the default for postgres: resource binding b-3.\n",
                ""}

      assert ehosctl(["env", "bind", "staging", "shared-1", "--application", "ledger"], opts) ==
               {0,
                "Bound shared-1 in staging for the application ledger: resource binding b-4.\n",
                ""}
    end

    test "creates and removes an environment", %{provider: provider, opts: opts} do
      staging = %{"name" => "staging", "type" => "production"}
      api(provider, "POST", "/api/v1/environments", 201, %{"environment" => staging})
      api(provider, "DELETE", "/api/v1/environments/staging", 200, %{"environment" => staging})

      assert ehosctl(["env", "create", "staging", "--type", "production"], opts) ==
               {0, "Created staging, production. Run `ehosctl env bind` to bind its resources.\n",
                ""}

      assert json_requests(provider, "POST /api/v1/environments") == [
               json_request("/api/v1/environments", %{"name" => "staging", "type" => "production"})
             ]

      assert ehosctl(["env", "remove", "staging", "--confirm", "staging"], opts) ==
               {0, "Removed the environment staging. The operator deletes its namespace.\n", ""}

      assert json_requests(provider, "DELETE /api/v1/environments/staging") == [
               json_request("/api/v1/environments/staging", %{"confirm" => "staging"})
             ]
    end

    test "binds a default and an application's own, and unbinds", %{
      provider: provider,
      opts: opts
    } do
      own = %{
        @binding
        | "id" => "b-2",
          "application" => "ledger",
          "schema" => "ehos_ledger_staging"
      }

      mock_binding(provider, own, @binding)

      api(provider, "DELETE", "/api/v1/environments/staging/bindings/b-1", 200, %{
        "binding" => %{"id" => "b-1"}
      })

      assert ehosctl(["env", "bind", "staging", "shared-1"], opts) ==
               {0,
                "Bound shared-1 in staging as the default for postgres: resource binding b-1.\n",
                ""}

      assert ehosctl(["env", "bind", "staging", "shared-1", "--application", "ledger"], opts) ==
               {0,
                "Bound shared-1 in staging for the application ledger, schema ehos_ledger_staging: " <>
                  "resource binding b-2.\n", ""}

      assert ehosctl(["env", "unbind", "staging", "b-1"], opts) ==
               {0, "Removed the resource binding b-1 from staging.\n", ""}
    end

    test "unbinds an id given in upper case, which EHOS answers in lower case",
         %{provider: provider, opts: opts} do
      api(provider, "DELETE", "/api/v1/environments/staging/bindings/AB-1", 200, %{
        "binding" => %{"id" => "ab-1"}
      })

      assert ehosctl(["env", "unbind", "staging", "AB-1"], opts) ==
               {0, "Removed the resource binding AB-1 from staging.\n", ""}
    end

    test "--json prints only what a binding is, whatever else EHOS sends",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments/staging/bindings", 201, %{
        "binding" => Map.put(@binding, "secret", "do-not-print")
      })

      {0, json, ""} = ehosctl(["env", "bind", "staging", "shared-1", "--json"], opts)
      assert JSON.decode!(json) == %{"binding" => @binding}
    end

    test "prints EHOS's refusal with its kind's exit code", %{provider: provider, opts: opts} do
      path = "/api/v1/environments/production/bindings"

      api(provider, "POST", path, 422, %{
        "error" => "across_the_line",
        "message" => "A production environment binds only a resource serving production."
      })

      assert ehosctl(["env", "bind", "production", "dev-db"], opts) ==
               {2, "",
                "ehosctl: A production environment binds only a resource serving production.\n"}

      api(provider, "POST", "/api/v1/environments", 409, %{
        "error" => "being_removed",
        "message" => "An environment of that name is still being removed from the cluster."
      })

      assert ehosctl(["env", "create", "staging", "--type", "production"], opts) ==
               {5, "",
                "ehosctl: An environment of that name is still being removed from the cluster.\n"}

      api(provider, "GET", "/api/v1/environments", 403, %{
        "error" => "forbidden",
        "message" => "Reading the environments needs one of …"
      })

      assert ehosctl(["env", "list"], opts) ==
               {3, "", "ehosctl: Reading the environments needs one of …\n"}
    end

    test "says a change that went unanswered may have been done", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "DELETE", "/api/v1/environments/staging", 502, "<html>bad gateway</html>")

      assert ehosctl(["env", "remove", "staging", "--confirm", "staging"], opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} is unavailable (HTTP 502). Try again later. EHOS " <>
                  "possibly made the change. Run `ehosctl env show` to see.\n"}
    end

    test "refuses a name that would leave its place in the path, sending nothing",
         %{provider: provider, opts: opts} do
      for {args, refused} <- [
            {["env", "unbind", "staging", ".."],
             ".. is not the name of an environment, a resource or a resource binding."},
            {["env", "unbind", "..", "b-1"],
             ".. is not the name of an environment, a resource or a resource binding."},
            {["env", "bind", ".", "shared-1"],
             ". is not the name of an environment, a resource or a resource binding."},
            {["env", "remove", "..", "--confirm", ".."],
             ".. is not the name of an environment, a resource or a resource binding."},
            {["resources", "classify", "..", "production"],
             ".. is not the name of a resource. Run `ehosctl resources list` to see the resources."}
          ] do
        assert ehosctl(args, opts) == {2, "", "ehosctl: #{refused}\n"}
      end

      for request <- [
            "DELETE /api/v1/environments/staging/bindings/..",
            "DELETE /api/v1/environments/../bindings/b-1",
            "POST /api/v1/environments/./bindings",
            "DELETE /api/v1/environments/..",
            "POST /api/v1/resources/../classify"
          ],
          do: assert(FakeProvider.requests(provider, request) == [])
    end
  end

  describe "ephemeral environments" do
    test "creates one for an application from a template, with its expiry in seconds",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments", 201, %{"environment" => @pr})

      args = ~w(env create ledger-pr-12 --app ledger --template small --ttl 24h)

      assert ehosctl(args, opts) ==
               {0,
                "Created ledger-pr-12, ephemeral, for ledger from the environment template small, expires at " <>
                  "2026-10-17T15:00:00Z. Run `ehosctl env extend` to give it more time.\n",
                @pr_warning}

      assert json_requests(provider, "POST /api/v1/environments") == [
               json_request("/api/v1/environments", %{
                 "name" => "ledger-pr-12",
                 "type" => "ephemeral",
                 "application" => "ledger",
                 "template" => "small",
                 "expires_in" => 86_400
               })
             ]

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)
      assert JSON.decode!(json) == %{"environment" => @pr}
    end

    # eh-os D-161: one flag leaves out both the role entries and the people agreement.
    test "--no-role-bindings creates one without what its template holds for the application",
         %{provider: provider, opts: opts} do
      made = Map.put(@pr, "template_entries", false)
      api(provider, "POST", "/api/v1/environments", 201, %{"environment" => made})

      args = ~w(env create ledger-pr-12 --app ledger --no-role-bindings)

      assert ehosctl(args, opts) ==
               {0,
                "Created ledger-pr-12, ephemeral, for ledger from the environment template " <>
                  "small, expires at 2026-10-17T15:00:00Z. It has no role bindings and no " <>
                  "people agreement from the environment template. Run `ehosctl env extend` to " <>
                  "give it more time.\n", @pr_warning}

      assert json_requests(provider, "POST /api/v1/environments") == [
               json_request("/api/v1/environments", %{
                 "name" => "ledger-pr-12",
                 "type" => "ephemeral",
                 "application" => "ledger",
                 "template_entries" => false
               })
             ]

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)
      assert JSON.decode!(json) == %{"environment" => made}
    end

    test "--no-role-bindings answered as made with the template's entries is not taken",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments", 201, %{
        "environment" => Map.put(@pr, "template_entries", true)
      })

      assert ehosctl(~w(env create ledger-pr-12 --app ledger --no-role-bindings), opts) ==
               {1, "",
                @pr_warning <>
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. It " <>
                  "answered that something was done, but not as what was asked: run " <>
                  "`ehosctl env show` to see what was done.\n"}
    end

    test "--no-role-bindings warns when EHOS does not say it left them out",
         %{provider: provider, opts: opts} do
      # An EHOS older than the role entries answers no `template_entries`.
      api(provider, "POST", "/api/v1/environments", 201, %{"environment" => @pr})

      args = ~w(env create ledger-pr-12 --app ledger --no-role-bindings)

      # After the line that says it was created.
      assert ehosctl(args, opts) ==
               {0,
                "Created ledger-pr-12, ephemeral, for ledger from the environment template " <>
                  "small, expires at 2026-10-17T15:00:00Z. Run `ehosctl env extend` to give it " <>
                  "more time.\nEHOS did not confirm that it made ledger-pr-12 without the role " <>
                  "entries and the people agreement of the environment template. This version " <>
                  "of EHOS may not know --no-role-bindings. Run `ehosctl role-bindings list` to " <>
                  "see the role bindings in it.\n", @pr_warning}

      # Under --json, the document says it by the key it lacks.
      {0, json, ""} = ehosctl(args ++ ["--json"], opts)
      assert JSON.decode!(json) == %{"environment" => @pr}
    end

    test "--app alone leaves the template and the expiry to the installation",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments", 201, %{"environment" => @pr})

      {0, _stdout, @pr_warning} = ehosctl(~w(env create ledger-pr-12 --app ledger), opts)

      assert json_requests(provider, "POST /api/v1/environments") == [
               json_request("/api/v1/environments", %{
                 "name" => "ledger-pr-12",
                 "type" => "ephemeral",
                 "application" => "ledger"
               })
             ]
    end

    test "extends one, with --ttl or by the installation's default",
         %{provider: provider, opts: opts} do
      path = "/api/v1/environments/ledger-pr-12/extend"
      api(provider, "POST", path, 200, %{"environment" => @pr})

      assert ehosctl(~w(env extend ledger-pr-12 --ttl 90m), opts) ==
               {0, "The environment ledger-pr-12 now expires at 2026-10-17T15:00:00Z.\n", ""}

      {0, _stdout, ""} = ehosctl(~w(env extend ledger-pr-12 --app ledger), opts)

      assert json_requests(provider, "POST " <> path) == [
               json_request(path, %{"expires_in" => 5_400}),
               json_request(path, %{})
             ]
    end

    test "lists and shows its application, template and expiry",
         %{provider: provider, opts: opts} do
      production = %{"name" => "production", "type" => "production"}
      # One EHOS has not given an expiry yet, as null and as empty; one from before D-98.
      unsaid = %{@pr | "name" => "ledger-pr-13", "template" => nil, "expires_at" => nil}
      empty = %{@pr | "name" => "ledger-pr-14", "template" => "", "expires_at" => ""}
      older = %{"name" => "older", "type" => "ephemeral"}
      blank = %{"name" => "blank", "type" => "ephemeral", "application" => ""}
      envs = [@pr, production, unsaid, empty, older, blank]
      api(provider, "GET", "/api/v1/environments", 200, %{"environments" => envs})

      api(provider, "GET", "/api/v1/environments/ledger-pr-12", 200, %{
        "environment" => Map.put(@pr, "bindings", [])
      })

      # One that is not ephemeral says so in each cell, rather than leaving it empty, which reads
      # as not known: a name that is not there as `<none>`, which no name can be. One for an
      # application expires, even before EHOS says when: never would say it stays.
      {0, stdout, ""} = ehosctl(~w(env list), opts)

      assert stdout == """
              NAME          TYPE        APPLICATION  TEMPLATE  EXPIRES
              ledger-pr-12  ephemeral   ledger       small     2026-10-17T15:00:00Z
              production    production  <none>       <none>    never
              ledger-pr-13  ephemeral   ledger       <none>    when EHOS says
              ledger-pr-14  ephemeral   ledger       <none>    when EHOS says
              older         ephemeral   <none>       <none>    never
              blank         ephemeral   <none>       <none>    never
             """

      assert ehosctl(~w(env show ledger-pr-12), opts) ==
               {0,
                """
                ledger-pr-12, ephemeral, for ledger from the environment template small, expires at 2026-10-17T15:00:00Z
                No resource bindings. Run `ehosctl env bind ledger-pr-12 RESOURCE` to give it a resource.
                """, ""}

      # Empty is said as not given, as the list says it: no `from ` with nothing after it.
      api(provider, "GET", "/api/v1/environments/ledger-pr-14", 200, %{
        "environment" => Map.put(empty, "bindings", [])
      })

      assert ehosctl(~w(env show ledger-pr-14), opts) ==
               {0,
                """
                ledger-pr-14, ephemeral, for ledger, expires when EHOS says
                No resource bindings. Run `ehosctl env bind ledger-pr-14 RESOURCE` to give it a resource.
                """, ""}

      api(provider, "GET", "/api/v1/environments/blank", 200, %{
        "environment" => Map.put(blank, "bindings", [])
      })

      assert ehosctl(~w(env show blank), opts) ==
               {0,
                "blank, ephemeral\nNo resource bindings. Run `ehosctl env bind blank RESOURCE` to give it a resource.\n",
                ""}
    end

    test "says when an EHOS older than D-98 made one for no application, with no expiry",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments", 201, %{
        "environment" => %{"name" => "p", "type" => "ephemeral"}
      })

      assert ehosctl(~w(env create p --app ledger --ttl 24h), opts) ==
               {0,
                "Created p, ephemeral. This version of EHOS gives it no application and no expiry, so it does not expire. Run `ehosctl env remove` when nobody uses it.\n",
                ""}
    end

    test "says one EHOS made for an empty application as one for none", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "POST", "/api/v1/environments", 201, %{
        "environment" => %{"name" => "p", "type" => "ephemeral", "application" => ""}
      })

      assert ehosctl(~w(env create p --app ledger --ttl 24h), opts) ==
               {0,
                "Created p, ephemeral. This version of EHOS gives it no application and no expiry, so it does not expire. Run `ehosctl env remove` when nobody uses it.\n",
                ""}
    end

    test "removes one whose name is typed again when asked", %{provider: provider, opts: opts} do
      path = "/api/v1/environments/ledger-pr-12"
      api(provider, "DELETE", path, 200, %{"environment" => @pr})
      mock_typed("ledger-pr-12\n")

      assert ehosctl(~w(env remove ledger-pr-12 --app ledger), opts) ==
               {0, "Removed the environment ledger-pr-12. The operator deletes its namespace.\n",
                announced(provider) <> "Type ledger-pr-12 to remove the environment: "}

      assert json_requests(provider, "DELETE " <> path) == [
               json_request(path, %{"confirm" => "ledger-pr-12"})
             ]
    end

    test "refuses what EHOS would ignore or cannot read, sending nothing",
         %{provider: provider, opts: opts} do
      for {args, refused} <- [
            {~w(env create p --app ledger --type production),
             "--app creates an ephemeral environment, and a production environment belongs to no " <>
               "application. Give --app or --type, not both."},
            {~w(env create p), @no_app},
            {~w(env create p --type ephemeral), @no_app},
            {["env", "create", "p", "--app", ""], @no_app},
            {~w(env create p --type ephemeral --ttl 24h), @no_app},
            {~w(env create p --type production --ttl 24h), @ephemeral_only},
            {~w(env create p --type production --template small), @ephemeral_only},
            {~w(env create p --type production --no-role-bindings), @ephemeral_only},
            {~w(env create p --app ledger --ttl 24), "--ttl 24 #{@not_duration}"},
            {~w(env create p --app ledger --ttl 0h),
             "--ttl 0h is less than 1 minute. Give 1m or more."},
            {~w(env create p --app ledger --ttl 59s),
             "--ttl 59s is less than 1 minute. Give 1m or more."},
            {~w(env create p --app ledger --ttl 05m), "--ttl 05m #{@not_duration}"},
            {~w(env extend p --ttl 1w), "--ttl 1w #{@not_duration}"}
          ] do
        assert ehosctl(args, opts) == {2, "", "ehosctl: #{refused}\n"}
      end

      assert FakeProvider.requests(provider, "POST /api/v1/environments") == []
      assert FakeProvider.requests(provider, "POST /api/v1/environments/p/extend") == []
    end

    test "exits 2 when EHOS refuses a removal's confirmation", %{provider: provider, opts: opts} do
      api(provider, "DELETE", "/api/v1/environments/p", 422, %{
        "error" => "confirmation_required",
        "message" => "EHOS says confirmation_required."
      })

      assert ehosctl(~w(env remove p --confirm p), opts) ==
               {2, "", "ehosctl: EHOS says confirmation_required.\n"}
    end

    test "removes nothing when another name, or no answer, is given",
         %{provider: provider, opts: opts} do
      args = ~w(env remove ledger-pr-12)

      mock_typed("ledger\n")

      assert ehosctl(args, opts) ==
               {2, "",
                announced(provider) <>
                  "Type ledger-pr-12 to remove the environment: \e[31mehosctl:\e[0m ledger is not ledger-pr-12, " <>
                  "so ehosctl removed nothing. Run the command again and type ledger-pr-12.\n"}

      mock_typed("\n")

      assert ehosctl(args, opts) ==
               {2, "",
                announced(provider) <>
                  "Type ledger-pr-12 to remove the environment: \e[31mehosctl:\e[0m" <>
                  String.trim_leading(@no_name_again, "ehosctl:")}

      # Where stdin is no terminal, as in a job, nothing is asked: an error naming --confirm,
      # never a wait on a question or a quiet success.
      mock_no_terminal()

      assert ehosctl(args, opts) ==
               {2, "", @no_name_again}

      assert ehosctl(args ++ ~w(--confirm ledger), opts) ==
               {2, "",
                "ehosctl: --confirm ledger is not ledger-pr-12, #{@not_confirmed} Give --confirm " <>
                  "ledger-pr-12.\n"}

      assert FakeProvider.requests(provider, "DELETE /api/v1/environments/ledger-pr-12") == []
    end

    test "prints EHOS's refusals of ephemeral environments with their kinds' exit codes",
         %{provider: provider, opts: opts} do
      for {status, code, exit} <- [
            {422, "application_required", 2},
            {422, "expiry_too_long", 2},
            {404, "no_template", 1},
            {409, "too_many_for_application", 1},
            {409, "template_above_ceiling", 1}
          ] do
        api(provider, "POST", "/api/v1/environments", status, %{
          "error" => code,
          "message" => "EHOS says #{code}."
        })

        assert ehosctl(~w(env create p --app ledger), opts) ==
                 {exit, "", "ehosctl: EHOS says #{code}.\n"}
      end
    end
  end

  describe "env create at the count" do
    test "lists the ephemeral environments that hold the count after EHOS's sentence",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments", 409, at_count("too_many_for_application", 2))

      assert ehosctl(~w(env create ledger-try --app ledger), opts) ==
               {1, "",
                """
                ehosctl: #{@at_application}
                These ephemeral environments count toward the maximum of 3:
                 ENVIRONMENT   APPLICATION  EXPIRES               BUILD
                 ledger-pr-12  ledger       2026-11-05T09:00:00Z  pull request #12: Rooms by floor
                 ledger-main   ledger       2026-11-05T10:00:00Z  refs/heads/main
                 ledger-ada    ledger       2026-11-05T11:00:00Z  -
                2 more that you can read also count. Run `ehosctl env list` to see all of them.
                Run `ehosctl env remove ENVIRONMENT` to remove one.
                """}
    end

    test "--json prints EHOS's code and the environments, kept to the fields ehosctl reads",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments", 409, at_count("too_many_for_application", 0))

      {1, "", stderr} = ehosctl(~w(env create ledger-try --app ledger --json), opts)

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "failed",
                 "message" => @at_application,
                 "code" => "too_many_for_application",
                 "cap" => 3,
                 "environments" => [
                   held("ledger-pr-12", "2026-11-05T09:00:00Z", @pr_build),
                   held("ledger-main", "2026-11-05T10:00:00Z", @main_build),
                   held("ledger-ada", "2026-11-05T11:00:00Z", nil)
                 ],
                 "more" => 0
               }
             }
    end

    test "at the installation's count, says who can remove another application's",
         %{provider: provider, opts: opts} do
      body = %{
        "error" => "too_many_ephemeral",
        "message" => @at_installation,
        "cap" => 6,
        "environments" => [
          %{
            "name" => "billing-pr-3",
            "application" => "billing",
            "expires_at" => "2026-11-05T08:00:00Z",
            "build" => nil
          },
          %{"name" => "release-check", "application" => nil, "expires_at" => nil, "build" => nil}
        ],
        "more" => 1
      }

      api(provider, "POST", "/api/v1/environments", 409, body)

      assert ehosctl(~w(env create ledger-try --app ledger), opts) ==
               {1, "",
                """
                ehosctl: #{@at_installation}
                These ephemeral environments count toward the maximum of 6:
                 ENVIRONMENT    APPLICATION  EXPIRES               BUILD
                 billing-pr-3   billing      2026-11-05T08:00:00Z  -
                 release-check  <none>       never                 -
                1 more that you can read also counts. Run `ehosctl env list` to see all of them.
                Other applications can hold ephemeral environments that you cannot remove. A person with the role ehos.platform_operator can remove any of them.
                Run `ehosctl env remove ENVIRONMENT` to remove one.
                """}
    end

    test "adds nothing to EHOS's sentence where EHOS lists no environment, as for a pipeline",
         %{provider: provider, opts: opts} do
      for body <- [
            %{
              "error" => "too_many_for_application",
              "message" => @at_application,
              "cap" => 3,
              "environments" => [],
              "more" => 0
            },
            # An EHOS before the list: the sentence alone.
            %{"error" => "too_many_for_application", "message" => @at_application}
          ] do
        api(provider, "POST", "/api/v1/environments", 409, body)

        assert ehosctl(~w(env create ledger-try --app ledger), opts) ==
                 {1, "", "ehosctl: #{@at_application}\n"}

        {1, "", stderr} = ehosctl(~w(env create ledger-pr-7 --app ledger --json), opts)

        assert JSON.decode!(stderr) == %{
                 "error" =>
                   body
                   |> Map.delete("error")
                   |> Map.merge(%{"kind" => "failed", "code" => "too_many_for_application"})
               }
      end
    end

    test "prints a stated title as text a terminal cannot act on, and leaves out an environment of another shape",
         %{provider: provider, opts: opts} do
      build = put_in(@pr_build, ["stated", "pull_request", "title"], "Rooms\e[2J by floor")

      body = %{
        "error" => "too_many_for_application",
        "message" => @at_application,
        "cap" => 3,
        "environments" => [
          %{
            "name" => "ledger-pr-12",
            "application" => "ledger",
            "expires_at" => nil,
            "build" => build
          },
          %{"name" => 12, "application" => "ledger"},
          %{"name" => "ledger-x", "application" => "ledger", "build" => %{"id" => 1}}
        ],
        "more" => 0
      }

      api(provider, "POST", "/api/v1/environments", 409, body)

      assert ehosctl(~w(env create ledger-try --app ledger), opts) ==
               {1, "",
                """
                ehosctl: #{@at_application}
                These ephemeral environments count toward the maximum of 3:
                 ENVIRONMENT   APPLICATION  EXPIRES  BUILD
                 ledger-pr-12  ledger       never    pull request #12: "Rooms\\e[2J by floor"
                Run `ehosctl env remove ENVIRONMENT` to remove one.
                """}
    end
  end

  describe "resources" do
    test "lists the resources and classifies one", %{provider: provider, opts: opts} do
      resource = %{
        "name" => "shared-1",
        "kind" => "postgres",
        "provider" => "cloudnativepg",
        "version" => 18,
        "serves" => nil
      }

      api(provider, "GET", "/api/v1/resources", 200, %{"resources" => [resource]})

      api(provider, "POST", "/api/v1/resources/shared-1/classify", 200, %{
        "resource" => %{resource | "serves" => "non_production"}
      })

      {0, stdout, ""} = ehosctl(["resources", "list"], opts)

      assert stdout == """
              NAME      KIND      PROVIDER             WHERE  VERSION  SERVES     CHECK
              shared-1  postgres  In the installation         18       (not set)
             """

      assert ehosctl(["resources", "classify", "shared-1", "non_production"], opts) ==
               {0, "shared-1 now serves non-production environments.\n", ""}

      assert json_requests(provider, "POST /api/v1/resources/shared-1/classify") == [
               json_request("/api/v1/resources/shared-1/classify", %{
                 "serves" => "non_production"
               })
             ]
    end

    test "lists a database outside the installation with where it is and its check",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/resources", 200, %{"resources" => [@outside]})

      {0, stdout, ""} = ehosctl(["resources", "list"], opts)

      assert stdout == """
              NAME        KIND      PROVIDER                  WHERE                             VERSION  SERVES                   CHECK
              billing-db  postgres  Outside the installation  billing-db.example.com:5432/ehos  17       production environments  Does not pass, 18 November 2026, 10:42 UTC
             """

      {0, json, ""} = ehosctl(["resources", "list", "--json"], opts)
      assert JSON.decode!(json) == %{"resources" => [Map.drop(@outside, ["secret"])]}
    end

    test "says it cannot read a resource whose fields are not of their type",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/resources", 200, %{
        "resources" => [%{@outside | "port" => "x"}]
      })

      assert {1, "", "ehosctl: " <> said} = ehosctl(["resources", "list"], opts)
      assert said =~ "cannot read"
    end

    test "lists a resource whose check time is not ISO 8601 without it",
         %{provider: provider, opts: opts} do
      odd = %{@outside | "checked_at" => "2026-11-18 10:42"}
      api(provider, "GET", "/api/v1/resources", 200, %{"resources" => [odd]})

      {0, stdout, ""} = ehosctl(["resources", "list"], opts)
      assert stdout =~ ~r/Does not pass\s*\n/
    end

    test "shows a resource: where it is, its check line by line, its groups and bindings",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/resources/billing-db", 200, %{"resource" => @shown})

      {0, stdout, ""} = ehosctl(["resources", "show", "billing-db"], opts)

      assert stdout =~ "Provider   Outside the installation"
      assert stdout =~ "Where      billing-db.example.com:5432/ehos"
      assert stdout =~ "EHOS takes no backup of this database"
      assert stdout =~ "✓ reachable: The server answers."
      assert stdout =~ "✗ certificate: The certificate does not verify."
      assert stdout =~ ~r/ehos_ledger_production_read +1 +ana/
      assert stdout =~ ~r/ehos_ledger_production_write +0 +\(needs ehos.resource.manage\)/
      assert stdout =~ ~r/production +ledger +ehos_ledger_production/
    end

    test "check exits 0 while the database passes, and 1 when it does not",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/resources/billing-db", 200, %{"resource" => @shown})

      assert {1, stdout, ""} = ehosctl(["resources", "check", "billing-db"], opts)

      assert stdout == """
             ✗ billing-db: The certificate does not verify.

             What the last check found:
             ✓ reachable: The server answers.
             ✗ certificate: The certificate does not verify.
             """

      fit = %{
        @shown
        | "state" => "fit",
          "check" => %{@shown["check"] | "message" => "Every line of the check passed."}
      }

      api(provider, "GET", "/api/v1/resources/billing-db", 200, %{"resource" => fit})

      assert {0, "✓ billing-db: Every line of the check passed." <> _, ""} =
               ehosctl(["resources", "check", "billing-db"], opts)

      api(provider, "GET", "/api/v1/resources/billing-db", 200, %{"resource" => @shown})
      {1, json, ""} = ehosctl(["resources", "check", "billing-db", "--json"], opts)
      assert %{"resource" => %{"state" => "not_fit"}} = JSON.decode!(json)

      api(provider, "GET", "/api/v1/resources/billing-db", 200, %{"resource" => fit})
      {0, json, ""} = ehosctl(["resources", "check", "billing-db", "--json"], opts)
      assert %{"resource" => %{"state" => "fit"}} = JSON.decode!(json)
    end

    test "check refuses an instance in the installation, which has no such check",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/resources/shared-1", 200, %{
        "resource" => %{
          "name" => "shared-1",
          "kind" => "postgres",
          "provider" => "cloudnativepg",
          "version" => 18,
          "serves" => "production",
          "state" => nil,
          "check" => nil,
          "bindings" => []
        }
      })

      assert {2, "", "ehosctl: shared-1 is a database in the installation." <> _} =
               ehosctl(["resources", "check", "shared-1"], opts)
    end

    test "show and check refuse a name that would leave its place in the path",
         %{opts: opts} do
      for command <- ["show", "check"] do
        assert ehosctl(["resources", command, ".."], opts) ==
                 {2, "",
                  "ehosctl: .. is not the name of a resource. Run `ehosctl resources list` to " <>
                    "see the resources.\n"}
      end
    end

    test "env bind and env template bind say what a database outside the installation means",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments/production/bindings", 201, %{
        "binding" => %{@binding | "resource" => "billing-db"} |> Map.put("provider", "external")
      })

      {0, stdout, ""} = ehosctl(["env", "bind", "production", "billing-db"], opts)
      assert stdout =~ "billing-db is a database outside the installation. EHOS opens no data"

      api(provider, "POST", "/api/v1/environment-templates/small/bindings", 201, %{
        "binding" => %{"kind" => "postgres", "resource" => "billing-db", "provider" => "external"}
      })

      {0, stdout, ""} = ehosctl(["env", "template", "bind", "small", "billing-db"], opts)
      assert stdout =~ "billing-db is a database outside the installation."
    end

    test "a class set already is a conflict, exit 1", %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/resources/shared-1/classify", 409, %{
        "error" => "already_set",
        "message" => "That resource's class is set already, and never changes."
      })

      assert ehosctl(["resources", "classify", "shared-1", "production"], opts) ==
               {1, "", "ehosctl: That resource's class is set already, and never changes.\n"}
    end

    test "a gateway's 5xx says the class may have been set", %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/resources/shared-1/classify", 504, "<html>timeout</html>")

      assert ehosctl(["resources", "classify", "shared-1", "production"], opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} is unavailable (HTTP 504). Try again later. " <>
                  "EHOS possibly made the change. Run `ehosctl resources list` to see.\n"}
    end
  end

  # EHOS answers a binding of `resource` as an application's own with `own`, and as the default
  # for its kind with `default`.
  defp mock_binding(provider, own, default) do
    FakeProvider.stub_api(provider, "POST", "/api/v1/environments/staging/bindings", fn
      %{body: body} ->
        case JSON.decode!(body) do
          %{"application" => "ledger"} -> {201, %{"binding" => own}}
          %{"resource" => "shared-1"} -> {201, %{"binding" => default}}
        end
    end)
  end

  # The requests sent to EHOS's API as `"<METHOD> <path>"`, each with its JSON body decoded.

  # At a terminal, a governed command first names the installation it acts on.
  # A refusal at the application's count, with three environments and `more` others.
  defp at_count(code, more) do
    %{
      "error" => code,
      "message" => @at_application,
      "cap" => 3,
      "environments" => [
        held("ledger-pr-12", "2026-11-05T09:00:00Z", Map.put(@pr_build, "unread", true)),
        held("ledger-main", "2026-11-05T10:00:00Z", @main_build),
        held("ledger-ada", "2026-11-05T11:00:00Z", nil)
      ],
      "more" => more,
      "unread" => "a field a later EHOS adds"
    }
  end

  defp held(name, expires_at, build),
    do: %{"name" => name, "application" => "ledger", "expires_at" => expires_at, "build" => build}

  defp announced(provider), do: "Installation: local (#{provider.issuer})\n"

  # A person at a terminal, who types `typed` when asked.
  defp mock_typed(typed) do
    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :gets, fn "" -> typed end)
  end

  # No terminal to ask on, as in a job: nothing is asked.
  defp mock_no_terminal do
    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> false end)
    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> false end)
    expect(Ehosctl.TerminalMock, :gets, 0, fn _prompt -> nil end)
  end
end

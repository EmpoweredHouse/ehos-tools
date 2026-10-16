defmodule Ehosctl.EnvResourcesTest do
  use Ehosctl.SignInCase

  @staging %{"name" => "staging", "type" => "ephemeral"}
  @binding %{
    "id" => "b-1",
    "kind" => "postgres",
    "resource" => "shared-1",
    "application" => nil,
    "schema" => nil,
    "used" => false
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp api(provider, method, path, status, body),
    do: FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  describe "env" do
    test "lists the environments, and --json prints them", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/environments", 200, %{
        "environments" => [@staging, %{"name" => "production", "type" => "production"}]
      })

      {0, stdout, ""} = ehosctl(["env", "list"], opts)
      assert stdout =~ ~r/NAME\s+TYPE/
      assert stdout =~ ~r/staging\s+ephemeral/

      {0, json, ""} = ehosctl(["env", "list", "--json"], opts)
      assert %{"environments" => [@staging, _]} = JSON.decode!(json)
    end

    test "shows an environment with its bindings", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/environments/staging", 200, %{
        "environment" => Map.put(@staging, "bindings", [@binding])
      })

      {0, stdout, ""} = ehosctl(["env", "show", "staging"], opts)
      assert stdout =~ "staging, ephemeral"
      assert stdout =~ ~r/postgres\s+shared-1\s+default\s+no\s+b-1/
    end

    test "creates and removes an environment", %{provider: provider, opts: opts} do
      staging = %{"name" => "staging", "type" => "production"}
      api(provider, "POST", "/api/v1/environments", 201, %{"environment" => staging})
      api(provider, "DELETE", "/api/v1/environments/staging", 200, %{"environment" => staging})

      {0, stdout, ""} = ehosctl(["env", "create", "staging", "--type", "production"], opts)
      assert stdout =~ "Created staging, production."

      assert [%{body: body}] = FakeProvider.requests(provider, "POST /api/v1/environments")
      assert JSON.decode!(body) == %{"name" => "staging", "type" => "production"}

      {0, stdout, ""} = ehosctl(["env", "remove", "staging", "--confirm", "staging"], opts)
      assert stdout =~ "Removed staging"

      assert [%{body: body}] =
               FakeProvider.requests(provider, "DELETE /api/v1/environments/staging")

      assert JSON.decode!(body) == %{"confirm" => "staging"}
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

      path = "/api/v1/environments/staging/bindings"

      FakeProvider.stub_api(provider, "POST", path, fn %{body: body} ->
        case JSON.decode!(body) do
          %{"application" => "ledger"} -> {201, %{"binding" => own}}
          %{"resource" => "shared-1"} -> {201, %{"binding" => @binding}}
        end
      end)

      api(provider, "DELETE", "/api/v1/environments/staging/bindings/b-1", 200, %{
        "binding" => %{"id" => "b-1"}
      })

      {0, stdout, ""} = ehosctl(["env", "bind", "staging", "shared-1"], opts)
      assert stdout =~ "Bound shared-1 in staging as the default for postgres: binding b-1."

      {0, stdout, ""} =
        ehosctl(["env", "bind", "staging", "shared-1", "--application", "ledger"], opts)

      assert stdout =~ "as ledger's own, schema ehos_ledger_staging: binding b-2."

      {0, stdout, ""} = ehosctl(["env", "unbind", "staging", "b-1"], opts)
      assert stdout =~ "Unbound b-1 from staging."
    end

    test "prints EHOS's refusal with its kind's exit code", %{provider: provider, opts: opts} do
      path = "/api/v1/environments/production/bindings"

      api(provider, "POST", path, 422, %{
        "error" => "across_the_line",
        "message" => "A production environment binds only a resource serving production."
      })

      assert {2, "",
              "ehosctl: A production environment binds only a resource serving production.\n"} =
               ehosctl(["env", "bind", "production", "dev-db"], opts)

      api(provider, "POST", "/api/v1/environments", 409, %{
        "error" => "being_removed",
        "message" => "An environment of that name is still being removed from the cluster."
      })

      assert {5, "", _} = ehosctl(["env", "create", "staging", "--type", "production"], opts)

      api(provider, "GET", "/api/v1/environments", 403, %{
        "error" => "forbidden",
        "message" => "Reading the environments needs one of …"
      })

      assert {3, "", "ehosctl: Reading the environments needs one of …\n"} =
               ehosctl(["env", "list"], opts)
    end

    test "says a change that went unanswered may have been done", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "DELETE", "/api/v1/environments/staging", 502, "<html>bad gateway</html>")

      {_code, "", stderr} = ehosctl(["env", "remove", "staging", "--confirm", "staging"], opts)
      assert stderr =~ "It may have been done: run `ehosctl env show` to see."
    end

    test "unbinds an id given in upper case, which EHOS answers in lower case",
         %{provider: provider, opts: opts} do
      api(provider, "DELETE", "/api/v1/environments/staging/bindings/AB-1", 200, %{
        "binding" => %{"id" => "ab-1"}
      })

      {0, stdout, ""} = ehosctl(["env", "unbind", "staging", "AB-1"], opts)
      assert stdout =~ "Unbound AB-1 from staging."
    end

    test "refuses a name that would leave its place in the path, sending nothing",
         %{provider: provider, opts: opts} do
      for args <- [
            ["env", "unbind", "staging", ".."],
            ["env", "unbind", "..", "b-1"],
            ["env", "bind", ".", "shared-1"],
            ["env", "remove", "..", "--confirm", ".."],
            ["resources", "classify", "..", "production"]
          ] do
        assert {2, "", stderr} = ehosctl(args, opts)
        assert stderr =~ "names no"
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

    test "--json prints only what a binding is, whatever else EHOS sends",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments/staging/bindings", 201, %{
        "binding" => Map.put(@binding, "secret", "do-not-print")
      })

      {0, json, ""} = ehosctl(["env", "bind", "staging", "shared-1", "--json"], opts)
      assert JSON.decode!(json) == %{"binding" => @binding}
    end
  end

  describe "ephemeral environments" do
    @pr %{
      "name" => "ledger-pr-12",
      "type" => "ephemeral",
      "application" => "ledger",
      "template" => "small",
      "expires_at" => "2026-10-17T15:00:00Z"
    }

    test "creates one for an application from a template, with its expiry in seconds",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments", 201, %{"environment" => @pr})

      args = ~w(env create ledger-pr-12 --app ledger --template small --ttl 24h)
      {0, stdout, ""} = ehosctl(args, opts)

      assert stdout =~
               "Created ledger-pr-12, ephemeral, for ledger from small, expires at " <>
                 "2026-10-17T15:00:00Z, unless `ehosctl env extend` gives it longer."

      assert [%{body: body}] = FakeProvider.requests(provider, "POST /api/v1/environments")

      assert JSON.decode!(body) == %{
               "name" => "ledger-pr-12",
               "type" => "ephemeral",
               "application" => "ledger",
               "template" => "small",
               "expires_in" => 86_400
             }

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)
      assert JSON.decode!(json) == %{"environment" => @pr}
    end

    test "--app alone leaves the template and the expiry to the installation",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments", 201, %{"environment" => @pr})

      {0, _stdout, ""} = ehosctl(~w(env create ledger-pr-12 --app ledger), opts)

      assert [%{body: body}] = FakeProvider.requests(provider, "POST /api/v1/environments")

      assert JSON.decode!(body) == %{
               "name" => "ledger-pr-12",
               "type" => "ephemeral",
               "application" => "ledger"
             }
    end

    test "refuses what EHOS would ignore or cannot read, sending nothing",
         %{provider: provider, opts: opts} do
      for {args, said} <- [
            {~w(env create p --app ledger --type production), "belongs to no application"},
            {~w(env create p), "--app"},
            {~w(env create p --type ephemeral), "--app"},
            {["env", "create", "p", "--app", ""], "--app"},
            {~w(env create p --type ephemeral --ttl 24h), "--app"},
            {~w(env create p --type production --ttl 24h), "are for an ephemeral environment"},
            {~w(env create p --type production --template small), "for an ephemeral"},
            {~w(env create p --app ledger --ttl 24), "is not a duration"},
            {~w(env create p --app ledger --ttl 0h), "is less than a minute"},
            {~w(env create p --app ledger --ttl 59s), "is less than a minute"},
            {~w(env create p --app ledger --ttl 05m), "is not a duration"},
            {~w(env extend p --ttl 1w), "is not a duration"}
          ] do
        assert {2, "", stderr} = ehosctl(args, opts)
        assert stderr =~ said
      end

      assert FakeProvider.requests(provider, "POST /api/v1/environments") == []
      assert FakeProvider.requests(provider, "POST /api/v1/environments/p/extend") == []
    end

    test "extends one, with --ttl or by the installation's default",
         %{provider: provider, opts: opts} do
      path = "/api/v1/environments/ledger-pr-12/extend"
      api(provider, "POST", path, 200, %{"environment" => @pr})

      {0, stdout, ""} = ehosctl(~w(env extend ledger-pr-12 --ttl 90m), opts)
      assert stdout =~ "ledger-pr-12 now expires at 2026-10-17T15:00:00Z."

      {0, _stdout, ""} = ehosctl(~w(env extend ledger-pr-12 --app ledger), opts)

      assert [%{body: first}, %{body: second}] =
               FakeProvider.requests(provider, "POST " <> path)

      assert JSON.decode!(first) == %{"expires_in" => 5_400}
      assert JSON.decode!(second) == %{}
    end

    test "lists and shows its application, template and expiry",
         %{provider: provider, opts: opts} do
      production = %{"name" => "production", "type" => "production"}
      api(provider, "GET", "/api/v1/environments", 200, %{"environments" => [@pr, production]})

      api(provider, "GET", "/api/v1/environments/ledger-pr-12", 200, %{
        "environment" => Map.put(@pr, "bindings", [])
      })

      {0, stdout, ""} = ehosctl(~w(env list), opts)
      assert stdout =~ ~r/NAME\s+TYPE\s+APPLICATION\s+TEMPLATE\s+EXPIRES/
      assert stdout =~ ~r/ledger-pr-12\s+ephemeral\s+ledger\s+small\s+2026-10-17T15:00:00Z/
      assert stdout =~ ~r/production\s+production\s*\n/

      {0, stdout, ""} = ehosctl(~w(env show ledger-pr-12), opts)

      assert stdout =~
               "ledger-pr-12, ephemeral, for ledger from small, expires at 2026-10-17T15:00:00Z"
    end

    test "exits 2 when EHOS refuses a removal's confirmation", %{provider: provider, opts: opts} do
      api(provider, "DELETE", "/api/v1/environments/p", 422, %{
        "error" => "confirmation_required",
        "message" => "EHOS says confirmation_required."
      })

      assert {2, "", stderr} = ehosctl(~w(env remove p --confirm p), opts)
      assert stderr =~ "EHOS says confirmation_required."
    end

    test "says when an EHOS older than D-98 made one for no application, with no expiry",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/environments", 201, %{
        "environment" => %{"name" => "p", "type" => "ephemeral"}
      })

      {0, stdout, ""} = ehosctl(~w(env create p --app ledger --ttl 24h), opts)
      assert stdout =~ "for no application and with no expiry: this EHOS is older than D-98"
    end

    test "removes one whose name is typed again when asked", %{provider: provider, opts: opts} do
      path = "/api/v1/environments/ledger-pr-12"
      api(provider, "DELETE", path, 200, %{"environment" => @pr})
      asked = self()

      ask = fn question ->
        send(asked, {:asked, question})
        "ledger-pr-12\n"
      end

      {0, stdout, ""} = ehosctl(~w(env remove ledger-pr-12 --app ledger), [ask: ask] ++ opts)
      assert stdout =~ "Removed ledger-pr-12"
      assert_received {:asked, question}
      assert question == "Type ledger-pr-12 again to remove it:"

      assert [%{body: body}] = FakeProvider.requests(provider, "DELETE " <> path)
      assert JSON.decode!(body) == %{"confirm" => "ledger-pr-12"}
    end

    test "removes nothing when another name, or no answer, is given",
         %{provider: provider, opts: opts} do
      args = ~w(env remove ledger-pr-12)

      assert {2, "", stderr} = ehosctl(args, [ask: fn _ -> "ledger\n" end] ++ opts)
      assert stderr =~ "ledger is not ledger-pr-12: nothing was removed."

      # Where stdin is no terminal, as in a job or under the tests, nothing is asked: an error
      # naming --confirm, never a wait on a question or a quiet success.
      assert {2, "", stderr} = ehosctl(args, opts)
      assert stderr =~ "give --confirm ledger-pr-12"

      assert {2, "", stderr} = ehosctl(args, [ask: fn _ -> "\n" end] ++ opts)
      assert stderr =~ "needs its name again"

      assert {2, "", stderr} = ehosctl(args ++ ~w(--confirm ledger), opts)
      assert stderr =~ "--confirm ledger is not ledger-pr-12"

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

        assert {^exit, "", stderr} = ehosctl(~w(env create p --app ledger), opts)
        assert stderr =~ "EHOS says #{code}."
      end
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
      assert stdout =~ ~r/shared-1\s+postgres\s+cloudnativepg\s+18\s+\(not set\)/

      {0, stdout, ""} = ehosctl(["resources", "classify", "shared-1", "non_production"], opts)
      assert stdout =~ "shared-1 now serves non-production environments."

      assert [%{body: body}] =
               FakeProvider.requests(provider, "POST /api/v1/resources/shared-1/classify")

      assert JSON.decode!(body) == %{"serves" => "non_production"}
    end

    test "a gateway's 5xx says the class may have been set", %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/resources/shared-1/classify", 504, "<html>timeout</html>")

      {_code, "", stderr} = ehosctl(["resources", "classify", "shared-1", "production"], opts)
      assert stderr =~ "It may have been set: run `ehosctl resources list` to see."
    end

    test "a class set already is a conflict, exit 1", %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/resources/shared-1/classify", 409, %{
        "error" => "already_set",
        "message" => "That resource's class is set already, and never changes."
      })

      assert {1, "", "ehosctl: That resource's class is set already, and never changes.\n"} =
               ehosctl(["resources", "classify", "shared-1", "production"], opts)
    end
  end
end

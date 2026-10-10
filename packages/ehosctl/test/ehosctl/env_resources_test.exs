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
      api(provider, "GET", "/api/environments", 200, %{
        "environments" => [@staging, %{"name" => "production", "type" => "production"}]
      })

      {0, stdout, ""} = ehosctl(["env", "list"], opts)
      assert stdout =~ ~r/NAME\s+TYPE/
      assert stdout =~ ~r/staging\s+ephemeral/

      {0, json, ""} = ehosctl(["env", "list", "--json"], opts)
      assert %{"environments" => [@staging, _]} = JSON.decode!(json)
    end

    test "shows an environment with its bindings", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/environments/staging", 200, %{
        "environment" => Map.put(@staging, "bindings", [@binding])
      })

      {0, stdout, ""} = ehosctl(["env", "show", "staging"], opts)
      assert stdout =~ "staging, ephemeral"
      assert stdout =~ ~r/postgres\s+shared-1\s+default\s+no\s+b-1/
    end

    test "creates and removes an environment", %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/environments", 201, %{"environment" => @staging})
      api(provider, "DELETE", "/api/environments/staging", 200, %{"environment" => @staging})

      {0, stdout, ""} = ehosctl(["env", "create", "staging", "--type", "ephemeral"], opts)
      assert stdout =~ "Created staging, ephemeral."

      assert [%{body: body}] = FakeProvider.requests(provider, "POST /api/environments")
      assert JSON.decode!(body) == %{"name" => "staging", "type" => "ephemeral"}

      {0, stdout, ""} = ehosctl(["env", "remove", "staging"], opts)
      assert stdout =~ "Removed staging"
      assert [%{body: ""}] = FakeProvider.requests(provider, "DELETE /api/environments/staging")
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

      FakeProvider.stub_api(provider, "POST", "/api/environments/staging/bindings", fn %{
                                                                                         body:
                                                                                           body
                                                                                       } ->
        case JSON.decode!(body) do
          %{"application" => "ledger"} -> {201, %{"binding" => own}}
          %{"resource" => "shared-1"} -> {201, %{"binding" => @binding}}
        end
      end)

      api(provider, "DELETE", "/api/environments/staging/bindings/b-1", 200, %{
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
      path = "/api/environments/production/bindings"

      api(provider, "POST", path, 422, %{
        "error" => "across_the_line",
        "message" => "A production environment binds only a resource serving production."
      })

      assert {2, "",
              "ehosctl: A production environment binds only a resource serving production.\n"} =
               ehosctl(["env", "bind", "production", "dev-db"], opts)

      api(provider, "POST", "/api/environments", 409, %{
        "error" => "being_removed",
        "message" => "An environment of that name is still being removed from the cluster."
      })

      assert {5, "", _} = ehosctl(["env", "create", "staging", "--type", "ephemeral"], opts)

      api(provider, "GET", "/api/environments", 403, %{
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
      api(provider, "DELETE", "/api/environments/staging", 502, "<html>bad gateway</html>")

      {_code, "", stderr} = ehosctl(["env", "remove", "staging"], opts)
      assert stderr =~ "It may have been done: run `ehosctl env show` to see."
    end

    test "refuses a binding id that would leave its place in the path", %{opts: opts} do
      assert {2, "", stderr} = ehosctl(["env", "unbind", "staging", ".."], opts)
      assert stderr =~ "is not a binding's id"
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

      api(provider, "GET", "/api/resources", 200, %{"resources" => [resource]})

      api(provider, "POST", "/api/resources/shared-1/classify", 200, %{
        "resource" => %{resource | "serves" => "non_production"}
      })

      {0, stdout, ""} = ehosctl(["resources", "list"], opts)
      assert stdout =~ ~r/shared-1\s+postgres\s+cloudnativepg\s+18\s+\(not set\)/

      {0, stdout, ""} = ehosctl(["resources", "classify", "shared-1", "non_production"], opts)
      assert stdout =~ "shared-1 now serves non-production environments."

      assert [%{body: body}] =
               FakeProvider.requests(provider, "POST /api/resources/shared-1/classify")

      assert JSON.decode!(body) == %{"serves" => "non_production"}
    end

    test "a class set already is a conflict, exit 1", %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/resources/shared-1/classify", 409, %{
        "error" => "already_set",
        "message" => "That resource's class is set already, and never changes."
      })

      assert {1, "", "ehosctl: That resource's class is set already, and never changes.\n"} =
               ehosctl(["resources", "classify", "shared-1", "production"], opts)
    end
  end
end

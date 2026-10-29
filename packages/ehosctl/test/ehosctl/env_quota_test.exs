defmodule Ehosctl.EnvQuotaTest do
  use Ehosctl.SignInCase

  @path "/api/v1/environments/production"
  @production %{
    "name" => "production",
    "type" => "production",
    "application" => nil,
    "template" => nil,
    "expires_at" => nil,
    "quota" => nil,
    "limits" => nil,
    "seed_profile" => nil
  }
  @quota %{"limits.memory" => "8Gi", "requests.memory" => "8Gi"}
  @limits [
    %{"type" => "Container", "default" => %{"memory" => "1Gi"}},
    %{"type" => "Pod", "max" => %{"memory" => "4Gi"}}
  ]
  # What a command that leaves both to the installation prints.
  @installations """
  production, production
  Quota: the installation's
  Limits: the installation's
  """

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "env quota show" do
    test "says the installation's, and an environment's own", %{provider: provider, opts: opts} do
      api(provider, "GET", 200, %{"environment" => Map.put(@production, "bindings", [])})

      {0, stdout, ""} = ehosctl(["env", "quota", "show", "production"], opts)

      assert stdout == """
             production, production
             Quota: the installation's
             Limits: the installation's
             """

      own = %{@production | "quota" => @quota, "limits" => @limits}
      api(provider, "GET", 200, %{"environment" => Map.put(own, "bindings", [])})

      {0, stdout, ""} = ehosctl(["env", "quota", "show", "production"], opts)
      # Its own stands over the installation's, so a key it leaves out is not read as unbounded.
      assert stdout == """
             production, production
             Quota (over the installation's): limits.memory 8Gi, requests.memory 8Gi
             Limits (over the installation's): Container: default memory 1Gi
                                               Pod: max memory 4Gi
             """

      # --json keeps the quota and limits, and nothing a script was not promised.
      {0, json, ""} = ehosctl(["env", "quota", "show", "production", "--json"], opts)

      assert JSON.decode!(json) == %{
               "environment" => %{
                 "name" => "production",
                 "type" => "production",
                 "quota" => @quota,
                 "limits" => @limits
               }
             }
    end

    test "env show prints a production environment's quota too", %{
      provider: provider,
      opts: opts
    } do
      own = %{@production | "quota" => @quota}
      api(provider, "GET", 200, %{"environment" => Map.put(own, "bindings", [])})

      {0, stdout, ""} = ehosctl(["env", "show", "production"], opts)

      assert stdout == """
             production, production
             Quota (over the installation's): limits.memory 8Gi, requests.memory 8Gi
             Limits: the installation's
             No resources are bound in it.
             """
    end

    test "says an ephemeral environment's as it was given them, over nothing", %{
      provider: provider,
      opts: opts
    } do
      given = %{@production | "name" => "ledger-pr-1", "type" => "ephemeral", "quota" => @quota}

      FakeProvider.stub_api(provider, "GET", "/api/v1/environments/ledger-pr-1", fn _ ->
        {200, %{"environment" => Map.put(given, "bindings", [])}}
      end)

      {0, stdout, ""} = ehosctl(["env", "quota", "show", "ledger-pr-1"], opts)

      assert stdout == """
             ledger-pr-1, ephemeral, its template's when it was made
             Quota: limits.memory 8Gi, requests.memory 8Gi
             Limits: the installation's
             """
    end

    test "refuses an answer whose quota it cannot read", %{provider: provider, opts: opts} do
      api(provider, "GET", 200, %{"environment" => %{@production | "quota" => %{"pods" => 4}}})

      assert ehosctl(["env", "quota", "show", "production"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end

    test "refuses an answer for another environment", %{provider: provider, opts: opts} do
      other = %{@production | "name" => "staging", "quota" => @quota}
      api(provider, "GET", 200, %{"environment" => other})

      assert ehosctl(["env", "quota", "show", "production"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end
  end

  describe "env quota set and clear" do
    @describetag :tmp_dir

    test "sends the quota and limits given, and says what was set", %{
      provider: provider,
      opts: opts,
      tmp_dir: tmp_dir
    } do
      file = Path.join(tmp_dir, "limits.json")
      File.write!(file, JSON.encode!(@limits))
      own = %{@production | "quota" => @quota, "limits" => @limits}
      api(provider, "PATCH", 200, %{"environment" => own, "no_longer_fit" => []})

      argv = ["--quota", "limits.memory=8Gi,requests.memory=8Gi", "--limits", file]
      {0, stdout, ""} = ehosctl(["env", "quota", "set", "production" | argv], opts)

      assert stdout == """
             production, production
             Quota (over the installation's): limits.memory 8Gi, requests.memory 8Gi
             Limits (over the installation's): Container: default memory 1Gi
                                               Pod: max memory 4Gi
             """

      assert patches(provider) == [patch(%{"quota" => @quota, "limits" => @limits})]
    end

    test "sends only what is given, '' giving it back, and refuses nothing given", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "PATCH", 200, %{"environment" => @production, "no_longer_fit" => []})

      assert ehosctl(["env", "quota", "set", "production", "--limits", ""], opts) ==
               {0, @installations, ""}

      assert patches(provider) == [patch(%{"limits" => nil})]

      assert ehosctl(["env", "quota", "set", "production"], opts) ==
               {2, "", "ehosctl: Say what to set: --quota, --limits, or both.\n"}

      assert ehosctl(["env", "quota", "set", "production", "--quota", "pods"], opts) ==
               {2, "",
                "ehosctl: --quota has pods, which is not KEY=VALUE: give pairs such as " <>
                  "pods=10,limits.memory=4Gi, or '' for the installation's.\n"}
    end

    test "clear gives both back to the installation", %{provider: provider, opts: opts} do
      api(provider, "PATCH", 200, %{"environment" => @production, "no_longer_fit" => []})

      assert ehosctl(["env", "quota", "clear", "production"], opts) == {0, @installations, ""}
      assert patches(provider) == [patch(%{"quota" => nil, "limits" => nil})]
    end

    test "warns which applications no longer fit, and --json keeps them", %{
      provider: provider,
      opts: opts
    } do
      own = %{@production | "quota" => %{"limits.memory" => "1Gi"}}
      api(provider, "PATCH", 200, %{"environment" => own, "no_longer_fit" => ["ledger", "shop"]})

      argv = ["env", "quota", "set", "production", "--quota", "limits.memory=1Gi"]
      {0, stdout, ""} = ehosctl(argv, opts)

      assert stdout == """
             production, production
             Quota (over the installation's): limits.memory 1Gi
             Limits: the installation's
             Warning: the next deployment of ledger, shop here no longer fits this quota, and is \
             refused until the quota or what it asks for changes; what runs keeps running.
             """

      {0, json, ""} = ehosctl(argv ++ ["--json"], opts)

      assert JSON.decode!(json) == %{
               "environment" => %{
                 "name" => "production",
                 "type" => "production",
                 "quota" => %{"limits.memory" => "1Gi"},
                 "limits" => nil
               },
               "no_longer_fit" => ["ledger", "shop"]
             }
    end

    test "prints EHOS's refusals in its words", %{provider: provider, opts: opts} do
      api(provider, "PATCH", 422, %{
        "error" => "invalid",
        "message" =>
          "Some fields do not fit: quota pods is above the installation's ceiling, 20.",
        "fields" => %{"quota" => ["pods is above the installation's ceiling, 20"]}
      })

      assert ehosctl(["env", "quota", "set", "production", "--quota", "pods=60"], opts) ==
               {2, "",
                "ehosctl: Some fields do not fit: quota pods is above the installation's " <>
                  "ceiling, 20.\n"}

      api(provider, "PATCH", 403, %{
        "error" => "forbidden",
        "message" => "You do not hold ehos.environment.manage."
      })

      assert ehosctl(["env", "quota", "clear", "production"], opts) ==
               {3, "", "ehosctl: You do not hold ehos.environment.manage.\n"}
    end

    test "says an answer for another environment was not what was asked", %{
      provider: provider,
      opts: opts
    } do
      other = %{@production | "name" => "staging"}
      api(provider, "PATCH", 200, %{"environment" => other, "no_longer_fit" => []})

      assert ehosctl(["env", "quota", "clear", "production"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. It " <>
                  "answered that something was done, but not as what was asked: run " <>
                  "`ehosctl env quota show` to see what was done.\n"}
    end

    test "refuses a name that would leave its place in the path", %{opts: opts} do
      assert ehosctl(["env", "quota", "clear", ".."], opts) ==
               {2, "", "ehosctl: .. names no environment, resource or binding.\n"}
    end
  end

  defp api(provider, method, status, body), do: api(provider, method, @path, status, body)

  # The PATCHes sent to the environment, each body decoded.
  defp patches(provider), do: json_requests(provider, "PATCH " <> @path)

  defp patch(body),
    do: %{path: @path, query: %{}, body: body, content_type: "application/json"}
end

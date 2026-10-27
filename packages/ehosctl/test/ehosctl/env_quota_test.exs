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

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp api(provider, method, status, body),
    do: FakeProvider.stub_api(provider, method, @path, fn _request -> {status, body} end)

  defp sent(provider) do
    assert [%{body: body}] = FakeProvider.requests(provider, "PATCH " <> @path)
    JSON.decode!(body)
  end

  describe "env quota show" do
    test "says the installation's, and an environment's own", %{provider: provider, opts: opts} do
      api(provider, "GET", 200, %{"environment" => Map.put(@production, "bindings", [])})

      {0, stdout, ""} = ehosctl(["env", "quota", "show", "production"], opts)
      assert stdout =~ "production, production"
      assert stdout =~ "Quota: the installation's"
      assert stdout =~ "Limits: the installation's"

      own = %{@production | "quota" => @quota, "limits" => @limits}
      api(provider, "GET", 200, %{"environment" => Map.put(own, "bindings", [])})

      {0, stdout, ""} = ehosctl(["env", "quota", "show", "production"], opts)
      # Its own stands over the installation's, so a key it leaves out is not read as unbounded.
      assert stdout =~ "Quota (over the installation's): limits.memory 8Gi, requests.memory 8Gi\n"

      assert stdout =~
               "Limits (over the installation's): Container: default memory 1Gi\n" <>
                 "                                  Pod: max memory 4Gi"

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
      assert stdout =~ "Quota (over the installation's): limits.memory 8Gi, requests.memory 8Gi"
      assert stdout =~ "Limits: the installation's\n"
    end

    test "says an ephemeral environment's as it was given them, over nothing", %{
      provider: provider,
      opts: opts
    } do
      given = %{@production | "name" => "ledger-pr-1", "type" => "ephemeral", "quota" => @quota}
      api(provider, "GET", 200, %{"environment" => Map.put(given, "bindings", [])})

      {0, stdout, ""} = ehosctl(["env", "quota", "show", "production"], opts)
      assert stdout =~ "ledger-pr-1, ephemeral, its template's when it was made\n"
      assert stdout =~ "Quota: limits.memory 8Gi, requests.memory 8Gi\n"
      refute stdout =~ "over the installation's"
    end

    test "refuses an answer whose quota it cannot read", %{provider: provider, opts: opts} do
      api(provider, "GET", 200, %{"environment" => %{@production | "quota" => %{"pods" => 4}}})

      assert {1, "", stderr} = ehosctl(["env", "quota", "show", "production"], opts)
      assert stderr =~ "cannot read"
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

      assert stdout =~ "Quota (over the installation's): limits.memory 8Gi, requests.memory 8Gi"
      refute stdout =~ "Warning"
      assert sent(provider) == %{"quota" => @quota, "limits" => @limits}
    end

    test "sends only what is given, '' giving it back, and refuses nothing given", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "PATCH", 200, %{"environment" => @production, "no_longer_fit" => []})

      {0, _stdout, ""} = ehosctl(["env", "quota", "set", "production", "--limits", ""], opts)
      assert sent(provider) == %{"limits" => nil}

      assert {2, "", stderr} = ehosctl(["env", "quota", "set", "production"], opts)
      assert stderr =~ "Say what to set"

      assert {2, "", stderr} =
               ehosctl(["env", "quota", "set", "production", "--quota", "pods"], opts)

      assert stderr =~ "not KEY=VALUE"
    end

    test "clear gives both back to the installation", %{provider: provider, opts: opts} do
      api(provider, "PATCH", 200, %{"environment" => @production, "no_longer_fit" => []})

      {0, stdout, ""} = ehosctl(["env", "quota", "clear", "production"], opts)
      assert stdout =~ "Quota: the installation's"
      assert sent(provider) == %{"quota" => nil, "limits" => nil}
    end

    test "warns which applications no longer fit, and --json keeps them", %{
      provider: provider,
      opts: opts
    } do
      own = %{@production | "quota" => %{"limits.memory" => "1Gi"}}
      api(provider, "PATCH", 200, %{"environment" => own, "no_longer_fit" => ["ledger", "shop"]})

      argv = ["env", "quota", "set", "production", "--quota", "limits.memory=1Gi"]
      {0, stdout, ""} = ehosctl(argv, opts)
      assert stdout =~ "Warning: the next deployment of ledger, shop here no longer fits"

      {0, json, ""} = ehosctl(argv ++ ["--json"], opts)
      assert %{"no_longer_fit" => ["ledger", "shop"]} = JSON.decode!(json)
    end

    test "prints EHOS's refusals in its words", %{provider: provider, opts: opts} do
      api(provider, "PATCH", 422, %{
        "error" => "invalid",
        "message" =>
          "Some fields do not fit: quota pods is above the installation's ceiling, 20.",
        "fields" => %{"quota" => ["pods is above the installation's ceiling, 20"]}
      })

      assert {2, "", stderr} =
               ehosctl(["env", "quota", "set", "production", "--quota", "pods=60"], opts)

      assert stderr =~ "above the installation's ceiling, 20."

      api(provider, "PATCH", 403, %{
        "error" => "forbidden",
        "message" => "You do not hold ehos.environment.manage."
      })

      assert {3, "", stderr} = ehosctl(["env", "quota", "clear", "production"], opts)
      assert stderr =~ "ehos.environment.manage"
    end

    test "says an answer for another environment was not what was asked", %{
      provider: provider,
      opts: opts
    } do
      other = %{@production | "name" => "staging"}
      api(provider, "PATCH", 200, %{"environment" => other, "no_longer_fit" => []})

      assert {1, "", stderr} = ehosctl(["env", "quota", "clear", "production"], opts)
      assert stderr =~ "`ehosctl env quota show`"
    end

    test "refuses a name that would leave its place in the path", %{opts: opts} do
      assert {2, "", stderr} = ehosctl(["env", "quota", "clear", ".."], opts)
      assert stderr =~ "names no environment"
    end
  end
end

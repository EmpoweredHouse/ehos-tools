defmodule Ehosctl.RolesAppsTest do
  use Ehosctl.SignInCase

  alias Ehosctl.FakeApplication

  @record_entry %{
    "name" => "ledger.record_entry",
    "label" => "Record an entry",
    "kind" => "command"
  }
  @balance %{"name" => "ledger.balance", "label" => "Balance", "kind" => "query"}

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    app = FakeApplication.start(provider)
    %{app: app}
  end

  describe "roles" do
    setup %{provider: provider} do
      FakeProvider.put_me(provider,
        roles: [
          role("ledger.clerk", "ledger", "staging"),
          role("ehos.people_reader", nil, nil),
          role("journal.editor", "journal", "staging", %{"gone" => true}),
          role("ledger.auditor", "ledger", "production", %{
            "held_by" => %{"kind" => "agent", "name" => "helper (agent of grace@example.com)"},
            "beyond_owner" => true
          }),
          # eh-os#798: given through ledger, under a clerk's rule.
          role("ledger.client", "ledger", "production", %{
            "grant" => %{
              "by" => "ada@example.com",
              "rule" => "ledger.clerk",
              "through" => "ledger"
            }
          })
        ]
      )
    end

    test "lists the roles held by the person and their agents, with what grants nothing",
         %{provider: provider, opts: opts} do
      {code, stdout, stderr} = ehosctl(["roles"], opts)

      assert {code, stderr} == {0, ""}

      assert stdout == """
              ROLE                HELD BY                                    APPLICATION  ENVIRONMENT  NOTE
              ledger.clerk        grace@example.com                          ledger       staging
              ehos.people_reader  grace@example.com                          (all)        (all)
              journal.editor      grace@example.com                          journal      staging      gone: grants nothing
              ledger.auditor      agent helper (agent of grace@example.com)  ledger       production   beyond its owner: grants only what the owner holds
              ledger.client       grace@example.com                          ledger       production   granted by ada@example.com through ledger, under the rule of ledger.clerk
             """

      # With a credential for EHOS's API, the one login kept.
      assert FakeProvider.requests(provider, "/api/v1/me/roles") == [%{}]
    end

    test "--app and --env keep the roles that hold there, those across them too", %{opts: opts} do
      {code, stdout, stderr} =
        ehosctl(["roles", "--app", "ledger", "--env", "staging", "--json"], opts)

      assert {code, stderr} == {0, ""}

      assert JSON.decode!(stdout) == %{
               "roles" => [
                 role("ledger.clerk", "ledger", "staging"),
                 role("ehos.people_reader", nil, nil)
               ]
             }
    end

    test "says when nothing matches", %{provider: provider, opts: opts} do
      FakeProvider.put_me(provider, roles: [role("ledger.clerk", "ledger", "staging")])

      assert ehosctl(["roles", "--app", "nothing"], opts) ==
               {0, "You hold no roles in local that match.\n", ""}
    end

    test "prints a name with a terminal's control characters quoted", %{
      provider: provider,
      opts: opts
    } do
      FakeProvider.put_me(provider, roles: [role("ledger.clerk\e[2J", "ledger", "staging")])

      {code, stdout, stderr} = ehosctl(["roles"], opts)

      assert {code, stderr} == {0, ""}

      assert stdout == ~S"""
              ROLE                 HELD BY            APPLICATION  ENVIRONMENT  NOTE
              "ledger.clerk\e[2J"  grace@example.com  ledger       staging
             """
    end

    test "EHOS's refusal is printed in its words, and exits with its kind",
         %{provider: provider, opts: opts} do
      FakeProvider.answer_api(provider, 401, %{
        "error" => "disabled",
        "message" => "Your account is disabled. Ask someone who manages people to enable it."
      })

      assert ehosctl(["roles"], opts) ==
               {4, "",
                "ehosctl: Your account is disabled. Ask someone who manages people to enable it.\n"}

      FakeProvider.answer_api(provider, 429, %{
        "error" => "too_many_calls",
        "message" => "Too many calls. Try again in 12 seconds."
      })

      assert ehosctl(["roles"], opts) ==
               {5, "", "ehosctl: Too many calls. Try again in 12 seconds.\n"}

      FakeProvider.answer_api(provider, 403, %{"error" => "workload", "message" => "\e[2J"})

      assert ehosctl(["roles"], opts) ==
               {3, "",
                "ehosctl: An application's credential may only read the people and send mail.\n"}
    end

    test "EHOS stopped is unavailable, in the chart page's words", %{
      provider: provider,
      opts: opts
    } do
      FakeProvider.answer_api(provider, 503, %{
        "error" => "temporarily_unavailable",
        "error_description" => "EHOS is unavailable. Try again in a few minutes."
      })

      {code, stdout, stderr} = ehosctl(["roles", "--json"], opts)

      assert {code, stdout} == {5, ""}

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "unreachable",
                 "message" => "EHOS is unavailable. Try again in a few minutes."
               }
             }
    end

    test "an answer it cannot read fails", %{provider: provider, opts: opts} do
      FakeProvider.answer_api(provider, 200, %{"roles" => [%{"role" => 1}]})

      assert ehosctl(["roles"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end

    test "EHOS down is unreachable", %{provider: provider, opts: opts} do
      FakeProvider.down(provider)
      assert ehosctl(["roles"], opts) == {5, "", "ehosctl: #{provider.issuer} did not answer.\n"}
    end
  end

  describe "apps" do
    test "lists each application in each environment, with its address and capabilities",
         %{provider: provider, app: app, opts: opts} do
      FakeProvider.put_me(provider,
        applications: [
          entry(app, "staging", [@record_entry, @balance]),
          entry(app, "production", [])
        ]
      )

      {code, stdout, stderr} = ehosctl(["apps"], opts)

      assert {code, stderr} == {0, ""}

      assert stdout == """
             ledger in staging, at #{app.address}
               roles: ledger.clerk
               command  ledger.record_entry  Record an entry
               query    ledger.balance       Balance

             ledger in production, at #{app.address}
               roles: ledger.clerk
               grants nothing: the role is gone, or no version is in force there
             """

      {code, stdout, stderr} = ehosctl(["apps", "--json"], opts)

      assert {code, stderr} == {0, ""}

      assert JSON.decode!(stdout) == %{
               "applications" => [
                 entry(app, "staging", [@record_entry, @balance]),
                 entry(app, "production", [])
               ]
             }
    end

    test "says when no role is bound in an application", %{opts: opts} do
      assert ehosctl(["apps"], opts) ==
               {0, "None of your roles in local is bound in an application.\n", ""}
    end

    test "says a capability of a kind it does not know needs a later ehosctl, and refuses `..`",
         %{provider: provider, app: app, opts: opts} do
      later = %{"name" => "ledger.watch", "label" => "Watch", "kind" => "subscription"}
      FakeProvider.put_me(provider, applications: [entry(app, "staging", [@balance, later])])

      {code, stdout, stderr} = ehosctl(["apps"], opts)

      assert {code, stderr} == {0, ""}

      assert stdout == """
             ledger in staging, at #{app.address}
               roles: ledger.clerk
               query    ledger.balance  Balance
               subscription  ledger.watch    Watch (needs a later ehosctl)
             """

      dots = %{"name" => "..", "label" => "Up", "kind" => "command"}
      FakeProvider.put_me(provider, applications: [entry(app, "staging", [dots])])

      assert ehosctl(["apps"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end

    test "refuses an address a credential could not safely be sent to",
         %{provider: provider, app: app, opts: opts} do
      for address <- ["ftp://ledger.example.com", "https://user@ledger.example.com", "ledger"] do
        FakeProvider.put_me(provider,
          applications: [%{entry(app, "staging", []) | "address" => address}]
        )

        assert ehosctl(["apps"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
      end
    end
  end

  defp role(role, application, environment, extra \\ %{}) do
    Map.merge(
      %{
        "role" => role,
        "held_by" => %{"kind" => "person", "name" => "grace@example.com"},
        "application" => application,
        "environment" => environment,
        "gone" => false,
        "beyond_owner" => false
      },
      extra
    )
  end

  defp entry(app, environment, capabilities) do
    %{
      "application" => "ledger",
      "environment" => environment,
      "audience" => "ledger/#{environment}",
      "address" => app.address,
      "roles" => ["ledger.clerk"],
      "capabilities" => capabilities
    }
  end
end

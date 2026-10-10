defmodule Ehosctl.RolesAppsTest do
  use Ehosctl.SignInCase

  alias Ehosctl.FakeApplication

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    app = FakeApplication.start(provider)
    %{app: app}
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

  @record_entry %{
    "name" => "ledger.record_entry",
    "label" => "Record an entry",
    "kind" => "command"
  }
  @balance %{"name" => "ledger.balance", "label" => "Balance", "kind" => "query"}

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
          })
        ]
      )
    end

    test "lists the roles held by the person and their agents, with what grants nothing",
         %{provider: provider, opts: opts} do
      {0, stdout, ""} = ehosctl(["roles"], opts)
      [header | rows] = String.split(stdout, "\n", trim: true)

      assert header =~ ~r/ROLE\s+HELD BY\s+APPLICATION\s+ENVIRONMENT\s+NOTE/
      assert Enum.at(rows, 0) =~ ~r/ledger.clerk\s+grace@example.com\s+ledger\s+staging/
      assert Enum.at(rows, 1) =~ ~r/ehos.people_reader\s+grace@example.com\s+\(all\)\s+\(all\)/
      assert Enum.at(rows, 2) =~ "gone: grants nothing"
      assert Enum.at(rows, 3) =~ "agent helper (agent of grace@example.com)"
      assert Enum.at(rows, 3) =~ "beyond its owner"

      # With a credential for EHOS's API, the one login kept.
      assert [_roles] = FakeProvider.requests(provider, "/api/me/roles")
    end

    test "--app and --env keep the roles that hold there, those across them too", %{opts: opts} do
      {0, stdout, ""} = ehosctl(["roles", "--app", "ledger", "--env", "staging", "--json"], opts)

      assert %{"roles" => roles} = JSON.decode!(stdout)
      assert Enum.map(roles, & &1["role"]) == ["ledger.clerk", "ehos.people_reader"]
    end

    test "says when nothing matches", %{provider: provider, opts: opts} do
      FakeProvider.put_me(provider, roles: [role("ledger.clerk", "ledger", "staging")])

      assert {0, "You hold no roles in local that match.\n", ""} =
               ehosctl(["roles", "--app", "nothing"], opts)
    end

    test "prints a name with a terminal's control characters quoted", %{
      provider: provider,
      opts: opts
    } do
      FakeProvider.put_me(provider, roles: [role("ledger.clerk\e[2J", "ledger", "staging")])

      {0, stdout, ""} = ehosctl(["roles"], opts)
      refute stdout =~ "\e"
      assert stdout =~ ~S("ledger.clerk\e[2J")
    end

    test "EHOS's refusal is printed in its words, and exits with its kind",
         %{provider: provider, opts: opts} do
      FakeProvider.answer_api(provider, 401, %{
        "error" => "disabled",
        "message" => "Your account is disabled. Ask someone who manages people to enable it."
      })

      assert {4, "", "ehosctl: Your account is disabled. Ask someone who manages people" <> _} =
               ehosctl(["roles"], opts)

      FakeProvider.answer_api(provider, 429, %{
        "error" => "too_many_calls",
        "message" => "Too many calls. Try again in 12 seconds."
      })

      assert {5, "", "ehosctl: Too many calls. Try again in 12 seconds.\n"} =
               ehosctl(["roles"], opts)

      FakeProvider.answer_api(provider, 403, %{"error" => "workload", "message" => "\e[2J"})

      assert {3, "", "ehosctl: An application's credential may only read the people.\n"} =
               ehosctl(["roles"], opts)
    end

    test "EHOS stopped is unavailable, in the chart page's words", %{
      provider: provider,
      opts: opts
    } do
      FakeProvider.answer_api(provider, 503, %{
        "error" => "temporarily_unavailable",
        "error_description" => "EHOS is unavailable. Try again in a few minutes."
      })

      {5, "", stderr} = ehosctl(["roles", "--json"], opts)

      assert %{"error" => %{"kind" => "unreachable", "message" => "EHOS is unavailable." <> _}} =
               JSON.decode!(stderr)
    end

    test "an answer it cannot read fails", %{provider: provider, opts: opts} do
      FakeProvider.answer_api(provider, 200, %{"roles" => [%{"role" => 1}]})

      assert {1, "", "ehosctl: " <> message} = ehosctl(["roles"], opts)
      assert message =~ "answered with something ehosctl cannot read"
    end

    test "EHOS down is unreachable", %{provider: provider, opts: opts} do
      FakeProvider.down(provider)
      assert {5, "", "ehosctl: " <> _} = ehosctl(["roles"], opts)
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

      {0, stdout, ""} = ehosctl(["apps"], opts)

      assert stdout == """
             ledger in staging, at #{app.address}
               roles: ledger.clerk
               command  ledger.record_entry  Record an entry
               query    ledger.balance       Balance

             ledger in production, at #{app.address}
               roles: ledger.clerk
               grants nothing: the role is gone, or no version is in force there
             """

      {0, stdout, ""} = ehosctl(["apps", "--json"], opts)
      assert %{"applications" => [%{"audience" => "ledger/staging"}, _]} = JSON.decode!(stdout)
    end

    test "says when no role is bound in an application", %{opts: opts} do
      assert {0, "None of your roles in local is bound in an application.\n", ""} =
               ehosctl(["apps"], opts)
    end

    test "refuses an address a credential could not safely be sent to",
         %{provider: provider, app: app, opts: opts} do
      for address <- ["ftp://ledger.example.com", "https://user@ledger.example.com", "ledger"] do
        FakeProvider.put_me(provider,
          applications: [%{entry(app, "staging", []) | "address" => address}]
        )

        assert {1, "", _stderr} = ehosctl(["apps"], opts)
      end
    end
  end
end

defmodule Ehosctl.TemplateEntriesTest do
  # `ehosctl env template role-entry …` and `ehosctl env template people …` (eh-os D-161), against
  # EHOS's API as eh-os's `EhosWeb.TemplateEntryController` answers it. Not async, through
  # `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process shares.
  use Ehosctl.SignInCase

  @ada "0b9c2a8e-1f0e-4d43-9f5b-3a1c2d4e5f60"
  @entry "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
  @path "/api/v1/applications/office/templates/sandbox"
  @entries @path <> "/role-entries"
  @people @path <> "/people"

  @principals [
    %{"id" => @ada, "kind" => "person", "email" => "ada@example.com"},
    %{
      "id" => "7d1e2f3a-4b5c-4d6e-8f90-a1b2c3d4e5f6",
      "kind" => "agent",
      "name" => "month-closer",
      "owner" => "ada@example.com"
    }
  ]

  @set %{
    "id" => @entry,
    "person" => @ada,
    "role" => "office.reviewer",
    "set_at" => "2026-11-06T10:00:00Z"
  }
  @listed Map.merge(@set, %{"person_email" => "ada@example.com", "set_by" => "grace@example.com"})
  @agreement %{
    "agreed_by_id" => @ada,
    "agreed_by" => "ada@example.com",
    "agreed_at" => "2026-11-06T10:00:00Z"
  }

  @done_otherwise "It answered that something was done, but not as what was asked: run " <>
                    "`ehosctl env template role-entry list sandbox --app office` to see what " <>
                    "was done."

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "env template role-entry list" do
    test "lists the role entries, and --json prints them", %{provider: provider, opts: opts} do
      # A person who set one and is no longer named is said as none.
      unnamed = %{@listed | "id" => "e-2", "role" => "office.clerk", "set_by" => nil}

      api(provider, "GET", @entries, 200, %{
        "application" => "office",
        "template" => "sandbox",
        "role_entries" => [@listed, unnamed]
      })

      args = ~w(env template role-entry list sandbox --app office)

      assert ehosctl(args, opts) ==
               {0,
                """
                 PERSON           ROLE             SET BY             SET AT                      ID
                 ada@example.com  office.reviewer  grace@example.com  6 November 2026, 10:00 UTC  #{@entry}
                 ada@example.com  office.clerk     <none>             6 November 2026, 10:00 UTC  e-2
                """, ""}

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)

      assert JSON.decode!(json) == %{
               "application" => "office",
               "template" => "sandbox",
               "role_entries" => [@listed, unnamed]
             }
    end

    test "says how to add one when there is none", %{provider: provider, opts: opts} do
      api(provider, "GET", @entries, 200, %{
        "application" => "office",
        "template" => "sandbox",
        "role_entries" => []
      })

      assert ehosctl(~w(env template role-entry list sandbox --app office), opts) ==
               {0,
                "The environment template sandbox holds no role entries for office. Run " <>
                  "`ehosctl env template role-entry set sandbox ROLE --app office --to WHO` to " <>
                  "add one.\n", ""}
    end

    test "takes no list of another application or environment template",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @entries, 200, %{
        "application" => "billing",
        "template" => "sandbox",
        "role_entries" => []
      })

      assert ehosctl(~w(env template role-entry list sandbox --app office), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end

    test "prints a refusal in EHOS's words", %{provider: provider, opts: opts} do
      api(provider, "GET", @entries, 403, %{
        "error" => "forbidden",
        "message" => "You cannot change what the environment template sandbox holds for office."
      })

      assert ehosctl(~w(env template role-entry list sandbox --app office), opts) ==
               {3, "",
                "ehosctl: You cannot change what the environment template sandbox holds for " <>
                  "office.\n"}
    end
  end

  describe "env template role-entry set and remove" do
    test "sets a role entry for a person named by their email",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings/principals", 200, %{"principals" => @principals})

      api(provider, "POST", @entries, 201, %{"role_entry" => @set})

      args =
        ~w(env template role-entry set sandbox office.reviewer --app office --to Ada@Example.com)

      assert ehosctl(args, opts) ==
               {0,
                "Set the role entry office.reviewer for ada@example.com on the environment " <>
                  "template sandbox for office: role entry #{@entry}. The ephemeral " <>
                  "environments of office that EHOS makes from sandbox from now on give " <>
                  "ada@example.com this role.\n", ""}

      assert json_requests(provider, "POST " <> @entries) == [
               json_request(@entries, %{"person" => @ada, "role" => "office.reviewer"})
             ]

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)
      assert JSON.decode!(json) == %{"role_entry" => @set}
    end

    test "sends a person's id as it is", %{provider: provider, opts: opts} do
      api(provider, "POST", @entries, 201, %{"role_entry" => @set})

      args = ~w(env template role-entry set sandbox office.reviewer --app office --to #{@ada})

      assert ehosctl(args, opts) ==
               {0,
                "Set the role entry office.reviewer for #{@ada} on the environment template " <>
                  "sandbox for office: role entry #{@entry}. The ephemeral environments of " <>
                  "office that EHOS makes from sandbox from now on give #{@ada} this role.\n", ""}

      assert FakeProvider.requests(provider, "GET /api/v1/role-bindings/principals") == []
    end

    test "refuses a person named neither by email nor by id, sending nothing",
         %{provider: provider, opts: opts} do
      args = ~w(env template role-entry set sandbox office.reviewer --app office --to ada)

      assert ehosctl(args, opts) ==
               {2, "",
                "ehosctl: ada is not an email or an id. Give the email or the id of a person.\n"}

      assert FakeProvider.requests(provider, "POST " <> @entries) == []
    end

    test "says no person has an email it does not know", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings/principals", 200, %{"principals" => @principals})

      args =
        ~w(env template role-entry set sandbox office.reviewer --app office --to bob@example.com)

      assert ehosctl(args, opts) ==
               {1, "",
                "ehosctl: No person that you can bind a role to has the email bob@example.com. " <>
                  "You can bind a role to each person who is invited and not disabled. Check " <>
                  "the email.\n"}

      assert FakeProvider.requests(provider, "POST " <> @entries) == []
    end

    test "prints EHOS's refusals of a role entry in its words, with their kinds",
         %{provider: provider, opts: opts} do
      for {status, code, exit} <- [
            {422, "platform_role", 2},
            {422, "wrong_application", 2},
            {409, "already_set", 1},
            {409, "too_many_entries", 1},
            {404, "not_found", 1}
          ] do
        api(provider, "POST", @entries, status, %{"error" => code, "message" => "EHOS: #{code}."})

        args = ~w(env template role-entry set sandbox office.reviewer --app office --to #{@ada})

        assert {code, ehosctl(args, opts)} == {code, {exit, "", "ehosctl: EHOS: #{code}.\n"}}
      end
    end

    test "says a role entry answered for another role did something",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @entries, 201, %{"role_entry" => %{@set | "role" => "office.clerk"}})

      args = ~w(env template role-entry set sandbox office.reviewer --app office --to #{@ada})

      assert ehosctl(args, opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. " <>
                  @done_otherwise <> "\n"}
    end

    test "removes a role entry by its id", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @entries <> "/" <> @entry, 200, %{"role_entry" => @set})

      args = ~w(env template role-entry remove sandbox #{@entry} --app office)

      assert ehosctl(args, opts) ==
               {0,
                "Removed the role entry office.reviewer, #{@entry}, from the environment " <>
                  "template sandbox for office. The ephemeral environments that EHOS makes from " <>
                  "sandbox from now on do not get it. The environments made already keep what " <>
                  "they got.\n", ""}

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)
      assert JSON.decode!(json) == %{"role_entry" => @set}
    end

    test "says a removal answered for another role entry did something",
         %{provider: provider, opts: opts} do
      api(provider, "DELETE", @entries <> "/" <> @entry, 200, %{
        "role_entry" => %{@set | "id" => "e-2"}
      })

      assert ehosctl(~w(env template role-entry remove sandbox #{@entry} --app office), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. " <>
                  @done_otherwise <> "\n"}
    end

    test "sends a role that is not a name to EHOS, which judges it",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @entries, 422, %{
        "error" => "unknown_role",
        "message" => "That is not a role name. A role of office is written office.<role>."
      })

      assert ehosctl(~w(env template role-entry set sandbox .. --app office --to #{@ada}), opts) ==
               {2, "",
                "ehosctl: That is not a role name. A role of office is written office.<role>.\n"}

      assert json_requests(provider, "POST " <> @entries) == [
               json_request(@entries, %{"person" => @ada, "role" => ".."})
             ]
    end

    test "refuses a name that would leave its place in the path, sending nothing",
         %{provider: provider, opts: opts} do
      for args <- [
            ~w(env template role-entry list .. --app office),
            ~w(env template role-entry remove sandbox .. --app office),
            ~w(env template people show sandbox --app .)
          ] do
        {2, "", stderr} = ehosctl(args, opts)
        assert stderr =~ "is not the name of an application, an environment template"
      end

      assert FakeProvider.requests(provider, "DELETE " <> @entries <> "/..") == []
    end
  end

  describe "env template people" do
    test "shows the people agreement given in advance, and --json prints it",
         %{provider: provider, opts: opts} do
      agreement = @agreement

      api(provider, "GET", @people, 200, %{
        "application" => "office",
        "template" => "sandbox",
        "people_agreement" => agreement
      })

      args = ~w(env template people show sandbox --app office)

      assert ehosctl(args, opts) ==
               {0,
                "The environment template sandbox holds a people agreement for office, given " <>
                  "in advance by ada@example.com on 6 November 2026, 10:00 UTC.\n", ""}

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)

      assert JSON.decode!(json) == %{
               "application" => "office",
               "template" => "sandbox",
               "people_agreement" => agreement
             }
    end

    test "says there is none, and how to give one", %{provider: provider, opts: opts} do
      api(provider, "GET", @people, 200, %{
        "application" => "office",
        "template" => "sandbox",
        "people_agreement" => nil
      })

      assert ehosctl(~w(env template people show sandbox --app office), opts) ==
               {0,
                "The environment template sandbox holds no people agreement for office. Run " <>
                  "`ehosctl env template people agree sandbox --app office` to give one in " <>
                  "advance.\n", ""}
    end

    test "gives and withdraws the people agreement", %{provider: provider, opts: opts} do
      answer = %{
        "application" => "office",
        "template" => "sandbox",
        "people_agreement" => @agreement
      }

      api(provider, "POST", @people, 200, answer)
      api(provider, "DELETE", @people, 200, answer)

      assert ehosctl(~w(env template people agree sandbox --app office), opts) ==
               {0,
                "The environment template sandbox holds a people agreement for office, given " <>
                  "in advance by ada@example.com on 6 November 2026, 10:00 UTC. The ephemeral " <>
                  "environments of office that EHOS makes from sandbox from now on get a people " <>
                  "agreement.\n", ""}

      assert ehosctl(~w(env template people withdraw sandbox --app office), opts) ==
               {0,
                "Withdrew the people agreement from the environment template sandbox for " <>
                  "office. The ephemeral environments that EHOS makes from sandbox from now on " <>
                  "get no people agreement from it. The environments made already keep what " <>
                  "they got.\n", ""}

      {0, json, ""} = ehosctl(~w(env template people agree sandbox --app office --json), opts)
      assert JSON.decode!(json) == answer
    end

    # Agreeing again keeps the people agreement there is, which another person may have given.
    test "says who gave the people agreement that EHOS kept", %{provider: provider, opts: opts} do
      kept = %{
        "agreed_by_id" => "7d1e2f3a-4b5c-4d6e-8f90-a1b2c3d4e5f6",
        "agreed_by" => "grace@example.com",
        "agreed_at" => "2026-11-01T08:30:00Z"
      }

      api(provider, "POST", @people, 200, %{
        "application" => "office",
        "template" => "sandbox",
        "people_agreement" => kept
      })

      assert ehosctl(~w(env template people agree sandbox --app office), opts) ==
               {0,
                "The environment template sandbox holds a people agreement for office, given " <>
                  "in advance by grace@example.com on 1 November 2026, 08:30 UTC. The ephemeral " <>
                  "environments of office that EHOS makes from sandbox from now on get a people " <>
                  "agreement.\n", ""}
    end

    test "names by id who gave the people agreement when EHOS names no email",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @people, 200, %{
        "application" => "office",
        "template" => "sandbox",
        "people_agreement" => %{@agreement | "agreed_by" => nil}
      })

      {0, stdout, ""} = ehosctl(~w(env template people agree sandbox --app office), opts)
      assert stdout =~ "given in advance by #{@ada} on 6 November 2026, 10:00 UTC."
    end

    test "takes no people agreement answered for another environment template",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @people, 200, %{
        "application" => "office",
        "template" => "small",
        "people_agreement" => @agreement
      })

      assert ehosctl(~w(env template people agree sandbox --app office), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. It " <>
                  "answered that something was done, but not as what was asked: run " <>
                  "`ehosctl env template people show sandbox --app office` to see what was " <>
                  "done.\n"}
    end

    test "prints a withdrawal of none in EHOS's words", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @people, 404, %{
        "error" => "not_found",
        "message" =>
          "EHOS has no application office, no environment template sandbox, or no " <>
            "such entry on it. Check the names."
      })

      assert ehosctl(~w(env template people withdraw sandbox --app office), opts) ==
               {1, "",
                "ehosctl: EHOS has no application office, no environment template sandbox, or " <>
                  "no such entry on it. Check the names.\n"}
    end
  end
end

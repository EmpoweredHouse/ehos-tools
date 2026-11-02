defmodule Ehosctl.PeopleTest do
  use Ehosctl.SignInCase

  @ada %{
    "id" => "6f1c-ada",
    "email" => "ada@example.com",
    "name" => "Ada Lovelace",
    "state" => "joined"
  }
  @alan %{"id" => "7a2d-alan", "email" => "alan@example.com", "name" => nil, "state" => "invited"}
  @grace %{
    "id" => "8b3e-grace",
    "email" => "grace@example.com",
    "name" => "Grace",
    "state" => "disabled"
  }

  @table """
   EMAIL             NAME          STATE    ID
   ada@example.com   Ada Lovelace  joined   6f1c-ada
   alan@example.com                invited  7a2d-alan
  """

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "people list" do
    test "lists the people as a table", %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @alan, @grace])

      # The disabled are listed only when asked for.
      assert ehosctl(["people", "list"], opts) == {0, @table, ""}
    end

    # The fake's link names another origin: each page is still asked of the installation, which
    # is the only place the requests are recorded.
    test "pages through Link: rel=next until the end", %{provider: provider, opts: opts} do
      people =
        for n <- 1..1203 do
          %{"id" => "id-#{n}", "email" => "p#{n}@example.com", "name" => nil, "state" => "joined"}
        end

      serve_people(provider, people)

      {0, stdout, ""} = ehosctl(["people", "list", "--json"], opts)
      assert JSON.decode!(stdout) == %{"people" => people, "more" => false}

      assert requests(provider, "GET /api/v1/people") == [
               get_people(%{"limit" => "500"}),
               get_people(%{"limit" => "500", "after" => "500"}),
               get_people(%{"limit" => "500", "after" => "1000"})
             ]
    end

    test "--limit stops early and says more match", %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @alan, %{@grace | "state" => "joined"}])

      assert ehosctl(["people", "list", "--limit", "2"], opts) ==
               {0, @table <> "More people match. Give a higher --limit to see them.\n", ""}

      # The page after a full one is asked for, to tell whether more match.
      assert requests(provider, "GET /api/v1/people") == [
               get_people(%{"limit" => "2"}),
               get_people(%{"limit" => "2", "after" => "2"})
             ]

      {0, stdout, ""} = ehosctl(["people", "list", "--limit", "2", "--json"], opts)
      assert JSON.decode!(stdout) == %{"people" => [@ada, @alan], "more" => true}
    end

    test "--state and --q are EHOS's parameters", %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @alan, @grace])

      assert ehosctl(["people", "list", "--state", "disabled", "--q", "GR"], opts) ==
               {0,
                """
                 EMAIL              NAME   STATE     ID
                 grace@example.com  Grace  disabled  8b3e-grace
                """, ""}

      assert requests(provider, "GET /api/v1/people") == [
               get_people(%{"limit" => "500", "state" => "disabled", "q" => "GR"})
             ]
    end

    test "a next link is found among others, on several lines, in any case",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/people", fn %{query: query} ->
        if query["after"] == "2" do
          {200, %{"people" => [@alan]}}
        else
          {200,
           [
             {"link", ~s(</api/v1/people?after=0>; rel="first")},
             {"link", ~s(</api/v1/people?after=2>; title="page 2"; rel="prev NEXT")}
           ], %{"people" => [@ada]}}
        end
      end)

      {0, stdout, ""} = ehosctl(["people", "list", "--json"], opts)
      assert JSON.decode!(stdout) == %{"people" => [@ada, @alan], "more" => false}
    end

    test "--limit reached on a page is enough, whatever its link", %{
      provider: provider,
      opts: opts
    } do
      FakeProvider.stub_api(provider, "GET", "/api/v1/people", fn _ ->
        {200, [{"link", ~s(</elsewhere?after=x>; rel="next")}], %{"people" => [@ada]}}
      end)

      {0, stdout, ""} = ehosctl(["people", "list", "--limit", "1", "--json"], opts)
      assert JSON.decode!(stdout) == %{"people" => [@ada], "more" => true}
    end

    test "a link of another relation is not followed", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/people", fn _ ->
        {200, [{"link", ~s(</api/v1/people?after=x>; rel="next-archive")}], %{"people" => [@ada]}}
      end)

      assert ehosctl(["people", "list"], opts) ==
               {0,
                """
                 EMAIL            NAME          STATE   ID
                 ada@example.com  Ada Lovelace  joined  6f1c-ada
                """, ""}

      assert requests(provider, "GET /api/v1/people") == [get_people(%{"limit" => "500"})]
    end

    test "prints what EHOS sent with a terminal's control characters quoted",
         %{provider: provider, opts: opts} do
      serve_people(provider, [%{@ada | "name" => "Ada\e[2J"}])

      assert ehosctl(["people", "list"], opts) ==
               {0,
                ~S"""
                 EMAIL            NAME        STATE   ID
                 ada@example.com  "Ada\e[2J"  joined  6f1c-ada
                """, ""}
    end

    test "says when nobody matches, and refuses a limit below one", %{
      provider: provider,
      opts: opts
    } do
      serve_people(provider, [])

      assert ehosctl(["people", "list"], opts) ==
               {0,
                "No people match. A person shows here after a people manager invites them. " <>
                  "Change --state or --q to see other people.\n", ""}

      assert ehosctl(["people", "list", "--limit", "0"], opts) ==
               {2, "", "ehosctl: --limit must be a whole number of 1 or more.\n"}
    end

    test "EHOS's refusal is printed in its words, with its kind's exit code",
         %{provider: provider, opts: opts} do
      sentence =
        "Reading the people needs ehos.people.read, and ehos.people.manage for disabled people."

      FakeProvider.stub_api(provider, "GET", "/api/v1/people", fn _ ->
        {403, %{"error" => "forbidden", "message" => sentence}}
      end)

      assert ehosctl(["people", "list", "--state", "disabled"], opts) ==
               {3, "", "ehosctl: #{sentence}\n"}
    end

    test "a link that goes back to a page already read stops the list", %{
      provider: provider,
      opts: opts
    } do
      FakeProvider.stub_api(provider, "GET", "/api/v1/people", fn %{query: query} ->
        {person, next} =
          if query["after"] == "b", do: {@alan, "a"}, else: {@ada, "b"}

        {200, [{"link", ~s(</api/v1/people?limit=500&after=#{next}>; rel="next")}],
         %{"people" => [person]}}
      end)

      assert ehosctl(["people", "list"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} gave as the next page one already read, or more " <>
                  "pages than any list has, so the list cannot be finished.\n"}

      assert requests(provider, "GET /api/v1/people") == [
               get_people(%{"limit" => "500"}),
               get_people(%{"limit" => "500", "after" => "b"}),
               get_people(%{"limit" => "500", "after" => "a"})
             ]
    end
  end

  describe "people show" do
    test "finds a person by email among the invited and the joined, in any case",
         %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @alan])

      assert ehosctl(["people", "show", "ADA@example.com"], opts) ==
               {0,
                """
                email: ada@example.com
                name:  Ada Lovelace
                state: joined
                id:    6f1c-ada
                """, ""}

      assert requests(provider, "GET /api/v1/people") == [
               get_people(%{
                 "limit" => "500",
                 "state" => "invited,joined",
                 "q" => "ADA@example.com"
               })
             ]
    end

    test "reads a person by id", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/people/:id", fn _ ->
        {200, %{"person" => @grace}}
      end)

      {0, stdout, ""} = ehosctl(["people", "show", "8b3e-grace", "--json"], opts)
      assert JSON.decode!(stdout) == %{"person" => @grace}

      assert requests(provider, "GET /api/v1/people/8b3e-grace") == [
               %{path: "/api/v1/people/8b3e-grace", query: %{}, body: "", content_type: nil}
             ]
    end

    test "an email nobody invited or joined has is not found, and says how to find the disabled",
         %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @grace])

      assert ehosctl(["people", "show", "grace@example.com"], opts) ==
               {1, "",
                "ehosctl: No invited or joined person has the email grace@example.com. To show a " <>
                  "disabled person, give their id. Run `ehosctl people list --state disabled` " <>
                  "to see the ids.\n"}
    end

    test "an id that is no person's is EHOS's not_found", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/people/:id", fn _ ->
        {404, %{"error" => "not_found", "message" => "That person no longer exists."}}
      end)

      assert ehosctl(["people", "show", "nobody"], opts) ==
               {1, "", "ehosctl: That person no longer exists.\n"}
    end

    test "a next page elsewhere than the list is an error, not the end",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/people", fn _ ->
        {200, [{"link", ~s(</ehos/api/people?after=x>; rel="next")}], %{"people" => [@ada]}}
      end)

      assert ehosctl(["people", "show", "zed@example.com"], opts) ==
               {1, "", "ehosctl: #{provider.issuer} gave a next page ehosctl cannot follow.\n"}
    end
  end

  describe "people invite" do
    test "says the link was mailed, and never prints one", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/people", fn _request ->
        # An answer that held a link would not have it printed.
        {201,
         %{"person" => @alan, "delivery" => "mailed", "link" => "https://ehos/log-in/secret"}}
      end)

      assert ehosctl(["people", "invite", "alan@example.com", "--name", "Alan"], opts) ==
               {0, "Invited alan@example.com. EHOS mailed a sign-in link to them.\n", ""}

      assert requests(provider, "POST /api/v1/people") == [
               post_people(~S({"name":"Alan","email":"alan@example.com"}))
             ]

      FakeProvider.stub_api(provider, "POST", "/api/v1/people", fn _request ->
        {201,
         %{
           "person" => Map.put(@alan, "sign_in_url", "https://ehos/log-in/secret"),
           "delivery" => "mailed"
         }}
      end)

      {0, stdout, ""} = ehosctl(["people", "invite", "alan@example.com", "--json"], opts)
      assert JSON.decode!(stdout) == %{"person" => @alan, "delivery" => "mailed"}

      assert requests(provider, "POST /api/v1/people") == [
               post_people(~S({"name":"Alan","email":"alan@example.com"})),
               post_people(~S({"email":"alan@example.com"}))
             ]
    end

    test "says when no mail was sent, and how a link is handed over",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/people", fn _ ->
        {201, %{"person" => @ada, "delivery" => "none"}}
      end)

      assert ehosctl(["people", "invite", "ada@example.com"], opts) ==
               {0,
                "Invited Ada Lovelace <ada@example.com>. This installation does not send mail, so " <>
                  "EHOS sent no sign-in link. To give them a link, a people manager invites " <>
                  "them again in the console.\n", ""}
    end

    test "each refusal exits with its kind's code", %{provider: provider, opts: opts} do
      cases = [
        {409, "person_disabled", "They are disabled. Enable them first.", 1},
        {409, "joined",
         "They have already joined. They can ask the login page for a sign-in link.", 1},
        {403, "beyond_inviter", "They hold roles you could not bind yourself.", 3},
        {502, "not_mailed",
         "They are invited, but the mail could not be sent. Invite them again to retry.", 5},
        {422, "invalid", "Some fields do not fit: email must have the @ sign and no spaces.", 2}
      ]

      for {status, code, sentence, exit_code} <- cases do
        FakeProvider.stub_api(provider, "POST", "/api/v1/people", fn _ ->
          {status, %{"error" => code, "message" => sentence}}
        end)

        assert ehosctl(["people", "invite", "x@example.com"], opts) ==
                 {exit_code, "", "ehosctl: #{sentence}\n"}
      end
    end
  end

  describe "people rename, disable and enable" do
    setup %{provider: provider} do
      serve_people(provider, [@ada, @alan, @grace])
    end

    test "rename finds the person by email among every state, and sends the name alone",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "PATCH", "/api/v1/people/:id", fn %{body: body} ->
        {200, %{"person" => %{@grace | "name" => JSON.decode!(body)["name"]}}}
      end)

      assert ehosctl(["people", "rename", "grace@example.com", "Grace Hopper"], opts) ==
               {0, "Renamed grace@example.com to Grace Hopper.\n", ""}

      assert requests(provider, "GET /api/v1/people") == [
               get_people(%{
                 "limit" => "500",
                 "state" => "invited,joined,disabled",
                 "q" => "grace@example.com"
               })
             ]

      assert requests(provider, "PATCH /api/v1/people/8b3e-grace") == [
               %{
                 path: "/api/v1/people/8b3e-grace",
                 query: %{},
                 body: ~S({"name":"Grace Hopper"}),
                 content_type: "application/json"
               }
             ]
    end

    test "an empty name removes it", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "PATCH", "/api/v1/people/:id", fn _ ->
        {200, %{"person" => %{@ada | "name" => nil}}}
      end)

      assert ehosctl(["people", "rename", "6f1c-ada", ""], opts) ==
               {0, "Removed the name of ada@example.com.\n", ""}

      assert requests(provider, "PATCH /api/v1/people/6f1c-ada") == [
               %{
                 path: "/api/v1/people/6f1c-ada",
                 query: %{},
                 body: ~S({"name":""}),
                 content_type: "application/json"
               }
             ]

      # An id is used as it is: nobody is looked up.
      assert requests(provider, "GET /api/v1/people") == []
    end

    test "rename says the name was removed when EHOS kept none", %{
      provider: provider,
      opts: opts
    } do
      FakeProvider.stub_api(provider, "PATCH", "/api/v1/people/:id", fn _ ->
        {200, %{"person" => %{@ada | "name" => nil}}}
      end)

      assert ehosctl(["people", "rename", "6f1c-ada", "  "], opts) ==
               {0, "Removed the name of ada@example.com.\n", ""}
    end

    test "disable and enable", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/people/:id/disable", fn _ ->
        {200, %{"person" => %{@ada | "state" => "disabled"}}}
      end)

      FakeProvider.stub_api(provider, "POST", "/api/v1/people/:id/enable", fn _ ->
        {200, %{"person" => %{@grace | "state" => "joined"}}}
      end)

      assert ehosctl(["people", "disable", "ada@example.com"], opts) ==
               {0,
                "Disabled Ada Lovelace <ada@example.com>. Their sign-in has ended, and each " <>
                  "credential that they hold stops working within 10 minutes.\n", ""}

      {0, stdout, ""} = ehosctl(["people", "enable", "grace@example.com", "--json"], opts)
      assert JSON.decode!(stdout) == %{"person" => %{@grace | "state" => "joined"}}

      assert requests(provider, "POST /api/v1/people/6f1c-ada/disable") == [
               post_person("/api/v1/people/6f1c-ada/disable")
             ]

      assert requests(provider, "POST /api/v1/people/8b3e-grace/enable") == [
               post_person("/api/v1/people/8b3e-grace/enable")
             ]
    end

    test "a dot segment is not an id, and nothing is sent", %{opts: opts} do
      for word <- [".", ".."] do
        assert ehosctl(["people", "disable", word], opts) ==
                 {2, "",
                  "ehosctl: #{word} is not an id. Give the id or the email of the person.\n"}
      end
    end

    test "a write EHOS says it did, with an answer it cannot read, says so",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/people/:id/disable", fn _ ->
        {200, %{"person" => %{"id" => 1}}}
      end)

      assert ehosctl(["people", "disable", "6f1c-ada"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. EHOS " <>
                  "said that it made the change. Run `ehosctl people show` to see the person.\n"}
    end

    test "a gateway's 5xx after a write says it may have been done",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/people/:id/enable", fn _ -> {504, %{}} end)

      assert ehosctl(["people", "enable", "6f1c-ada"], opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} is unavailable (HTTP 504). Try again later. EHOS " <>
                  "possibly made the change. Run `ehosctl people show` to see the person.\n"}
    end

    test "an email nobody has is not found", %{opts: opts} do
      assert ehosctl(["people", "disable", "nobody@example.com"], opts) ==
               {1, "",
                "ehosctl: No person has the email nobody@example.com. Check the email, or run " <>
                  "`ehosctl people list --state invited,joined,disabled` to see the people.\n"}
    end

    test "each refusal exits with its kind's code", %{provider: provider, opts: opts} do
      cases = [
        {409, "self", "You cannot disable yourself.", 1},
        {409, "last_administrator",
         "That is the last administrator of the platform. Make someone else ehos.administrator first.",
         1},
        {403, "forbidden",
         "Inviting, renaming, disabling and enabling people needs ehos.people.manage.", 3},
        # The caller's own account, disabled meanwhile: sign in again, not a conflict.
        {401, "disabled",
         "Your account is disabled. Ask someone who manages people to enable it.", 4}
      ]

      for {status, code, sentence, exit_code} <- cases do
        FakeProvider.stub_api(provider, "POST", "/api/v1/people/:id/disable", fn _ ->
          {status, %{"error" => code, "message" => sentence}}
        end)

        assert ehosctl(["people", "disable", "6f1c-ada"], opts) ==
                 {exit_code, "", "ehosctl: #{sentence}\n"}
      end
    end

    test "a changeset's fields are in the sentence, and exit 2", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "PATCH", "/api/v1/people/:id", fn _ ->
        {422,
         %{
           "error" => "invalid",
           "message" => "Some fields do not fit: name should be at most 256 character(s).",
           "fields" => %{"name" => ["should be at most 256 character(s)"]}
         }}
      end)

      assert ehosctl(["people", "rename", "6f1c-ada", String.duplicate("a", 300)], opts) ==
               {2, "",
                "ehosctl: Some fields do not fit: name should be at most 256 character(s).\n"}
    end
  end

  describe "people sign-out" do
    setup %{provider: provider} do
      serve_people(provider, [@ada, @alan, @grace])
    end

    test "finds the person by email among every state, and says how many terminals it ended",
         %{provider: provider, opts: opts} do
      sign_out_answers(provider, fn _ -> {200, %{"signed_out" => 2}} end)

      assert ehosctl(["people", "sign-out", "GRACE@example.com"], opts) ==
               {0,
                "Signed out all terminals of Grace <grace@example.com>. 2 terminals were signed " <>
                  "in. Their commands stop within 10 minutes.\n", ""}

      assert requests(provider, "GET /api/v1/people") == [
               get_people(%{
                 "limit" => "500",
                 "state" => "invited,joined,disabled",
                 "q" => "GRACE@example.com"
               })
             ]

      assert requests(provider, "DELETE /api/v1/people/8b3e-grace/terminals") == [
               sign_out_request("8b3e-grace")
             ]
    end

    test "names a person given by id by it, looking nobody up, and counts one or none",
         %{provider: provider, opts: opts} do
      sign_out_answers(provider, fn _ -> {200, %{"signed_out" => 1}} end)

      assert ehosctl(["people", "sign-out", "6f1c-ada"], opts) ==
               {0,
                "Signed out all terminals of the person 6f1c-ada. 1 terminal was signed in. Its " <>
                  "commands stop within 10 minutes.\n", ""}

      sign_out_answers(provider, fn _ -> {200, %{"signed_out" => 0}} end)

      assert ehosctl(["people", "sign-out", "alan@example.com"], opts) ==
               {0, "Signed out all terminals of alan@example.com. No terminal was signed in.\n",
                ""}

      assert ehosctl(["people", "sign-out", "6f1c-ada", "--json"], opts) ==
               {0, ~s({"signed_out":0}\n), ""}

      assert requests(provider, "GET /api/v1/people") == [
               get_people(%{
                 "limit" => "500",
                 "state" => "invited,joined,disabled",
                 "q" => "alan@example.com"
               })
             ]

      assert requests(provider, "DELETE /api/v1/people/6f1c-ada/terminals") == [
               sign_out_request("6f1c-ada"),
               sign_out_request("6f1c-ada")
             ]
    end

    test "an email nobody has is not found, and nothing is sent", %{
      provider: provider,
      opts: opts
    } do
      assert ehosctl(["people", "sign-out", "nobody@example.com"], opts) ==
               {1, "",
                "ehosctl: No person has the email nobody@example.com. Check the email, or run " <>
                  "`ehosctl people list --state invited,joined,disabled` to see the people.\n"}

      assert ehosctl(["people", "sign-out", ".."], opts) ==
               {2, "", "ehosctl: .. is not an id. Give the id or the email of the person.\n"}

      assert requests(provider, "DELETE /api/v1/people/..") == []
    end

    test "each refusal exits with its kind's code", %{provider: provider, opts: opts} do
      cases = [
        {403, "forbidden",
         "Inviting, renaming, disabling and enabling people, and signing out their terminals, " <>
           "needs ehos.people.manage.", 3, "refused"},
        {404, "not_found", "That person no longer exists.", 1, "failed"}
      ]

      for {status, code, sentence, exit_code, kind} <- cases do
        sign_out_answers(provider, fn _ -> {status, %{"error" => code, "message" => sentence}} end)

        assert ehosctl(["people", "sign-out", "6f1c-ada"], opts) ==
                 {exit_code, "", "ehosctl: #{sentence}\n"}

        assert {^exit_code, "", stderr} =
                 ehosctl(["people", "sign-out", "6f1c-ada", "--json"], opts)

        assert JSON.decode!(stderr) == %{"error" => %{"message" => sentence, "kind" => kind}}
      end
    end

    test "an answer it cannot read says it was done", %{provider: provider, opts: opts} do
      for body <- [%{"signed_out" => -1}, %{"signed_out" => "2"}, %{"person" => @ada}] do
        sign_out_answers(provider, fn _ -> {200, body} end)

        assert ehosctl(["people", "sign-out", "6f1c-ada"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. EHOS " <>
                    "said that it signed out the terminals.\n"}
      end
    end

    test "a gateway's 5xx says it may have been done, and that again is harmless",
         %{provider: provider, opts: opts} do
      sign_out_answers(provider, fn _ -> {502, %{}} end)

      assert ehosctl(["people", "sign-out", "6f1c-ada"], opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} is unavailable (HTTP 502). Try again later. EHOS " <>
                  "possibly signed out the terminals. You can run the command again safely.\n"}
    end
  end

  describe "people" do
    test "alone prints its subcommands", %{opts: opts} do
      assert ehosctl(["people"], opts) ==
               {0,
                """
                ehosctl #{Ehosctl.version()}
                Manage the people of the company: list, invite, rename, disable and enable them. Also sign out their terminals, agree to applications that read them, and confirm their GitHub accounts.

                USAGE:
                    ehosctl people

                SUBCOMMANDS:

                    list              List the people, in the order of their email.
                    show              Show one person.
                    invite            Invite a person. ehosctl says if EHOS mailed a sign-in
                                      link to the person. ehosctl never shows the link.
                    rename            Change the name of a person. An empty name removes the
                                      name.
                    disable           Disable a person. Their sign-in ends now, and their
                                      credentials stop working within 10 minutes.
                    enable            Enable a disabled person again.
                    sign-out          Sign out all terminals of a person. The person stays
                                      enabled. Their commands stop within 10 minutes.
                    agreements        List the applications that ask to read the people, in one
                                      environment each, and those agreed to.
                    agree             Agree that an application may read the people in an
                                      environment.
                    withdraw          Withdraw that agreement: the application's next reading is
                                      refused.
                    github            List, confirm and remove the GitHub accounts that people
                                      claim.

                Plane: governed. Acts as you, through EHOS, which decides and records every request.

                """, ""}
    end
  end

  # `GET /api/v1/people` over `people`, a page of `limit` at a time, the cursor the index of the next.
  defp serve_people(provider, people, link_origin \\ "https://elsewhere.example") do
    FakeProvider.stub_api(provider, "GET", "/api/v1/people", fn %{query: query} ->
      states = String.split(query["state"] || "invited,joined", ",")
      q = String.downcase(query["q"] || "")

      matching =
        Enum.filter(people, fn person ->
          person["state"] in states and
            (String.starts_with?(person["email"], q) or
               String.starts_with?(String.downcase(person["name"] || ""), q))
        end)

      limit = String.to_integer(query["limit"] || "100")
      from = String.to_integer(query["after"] || "0")
      page = matching |> Enum.drop(from) |> Enum.take(limit)

      if from + limit < length(matching) do
        next = URI.encode_query(Map.put(query, "after", from + limit))

        {200, [{"link", ~s(<#{link_origin}/api/v1/people?#{next}>; rel="next")}],
         %{"people" => page}}
      else
        {200, %{"people" => page}}
      end
    end)
  end

  defp sign_out_answers(provider, answer),
    do: FakeProvider.stub_api(provider, "DELETE", "/api/v1/people/:id/terminals", answer)

  defp requests(provider, key), do: FakeProvider.requests(provider, key)

  defp get_people(query),
    do: %{path: "/api/v1/people", query: query, body: "", content_type: nil}

  defp post_people(body),
    do: %{path: "/api/v1/people", query: %{}, body: body, content_type: "application/json"}

  defp post_person(path),
    do: %{path: path, query: %{}, body: "{}", content_type: "application/json"}

  defp sign_out_request(id),
    do: %{path: "/api/v1/people/#{id}/terminals", query: %{}, body: "", content_type: nil}
end

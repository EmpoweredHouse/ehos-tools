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

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  # `GET /api/people` over `people`, a page of `limit` at a time, the cursor the index of the next.
  defp serve_people(provider, people, link_origin \\ "https://elsewhere.example") do
    FakeProvider.stub_api(provider, "GET", "/api/people", fn %{query: query} ->
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

        {200, [{"link", ~s(<#{link_origin}/api/people?#{next}>; rel="next")}],
         %{"people" => page}}
      else
        {200, %{"people" => page}}
      end
    end)
  end

  defp requests(provider, key), do: FakeProvider.requests(provider, key)

  describe "list" do
    test "lists the people as a table", %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @alan, @grace])

      {0, stdout, ""} = ehosctl(["people", "list"], opts)
      [header | rows] = String.split(stdout, "\n", trim: true)

      assert header =~ ~r/EMAIL\s+NAME\s+STATE\s+ID/
      assert Enum.at(rows, 0) =~ ~r/ada@example.com\s+Ada Lovelace\s+joined\s+6f1c-ada/
      assert Enum.at(rows, 1) =~ ~r/alan@example.com\s+invited\s+7a2d-alan/
      # The disabled are listed only when asked for.
      assert length(rows) == 2
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
      assert %{"people" => listed, "more" => false} = JSON.decode!(stdout)
      assert length(listed) == 1203

      assert [first, second, third] = requests(provider, "GET /api/people")
      assert first.query == %{"limit" => "500"}
      assert second.query == %{"limit" => "500", "after" => "500"}
      assert third.query["after"] == "1000"
    end

    test "--limit stops early and says more match", %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @alan, %{@grace | "state" => "joined"}])

      {0, stdout, ""} = ehosctl(["people", "list", "--limit", "2"], opts)
      assert stdout =~ "ada@example.com"
      assert stdout =~ "alan@example.com"
      refute stdout =~ "grace@example.com"
      assert stdout =~ "More people match: raise --limit to see them."
      assert [%{query: %{"limit" => "2"}}] = requests(provider, "GET /api/people")

      {0, stdout, ""} = ehosctl(["people", "list", "--limit", "2", "--json"], opts)
      assert %{"people" => [_, _], "more" => true} = JSON.decode!(stdout)
    end

    test "--state and --q are EHOS's parameters", %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @alan, @grace])

      {0, stdout, ""} = ehosctl(["people", "list", "--state", "disabled", "--q", "GR"], opts)
      assert stdout =~ "grace@example.com"

      assert [%{query: %{"state" => "disabled", "q" => "GR"}}] =
               requests(provider, "GET /api/people")
    end

    test "says when nobody matches, and refuses a limit below one", %{
      provider: provider,
      opts: opts
    } do
      serve_people(provider, [])
      assert {0, "No people match.\n", ""} = ehosctl(["people", "list"], opts)

      assert {2, "", "ehosctl: --limit is a whole number from 1.\n"} =
               ehosctl(["people", "list", "--limit", "0"], opts)
    end

    test "EHOS's refusal is printed in its words, with its kind's exit code",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/people", fn _ ->
        {403,
         %{
           "error" => "forbidden",
           "message" =>
             "Reading the people needs ehos.people.read, and ehos.people.manage for disabled people."
         }}
      end)

      assert {3, "", "ehosctl: Reading the people needs ehos.people.read" <> _} =
               ehosctl(["people", "list", "--state", "disabled"], opts)
    end

    test "prints what EHOS sent with a terminal's control characters quoted",
         %{provider: provider, opts: opts} do
      serve_people(provider, [%{@ada | "name" => "Ada\e[2J"}])

      {0, stdout, ""} = ehosctl(["people", "list"], opts)
      refute stdout =~ "\e"
      assert stdout =~ ~S("Ada\e[2J")
    end
  end

  test "a link that goes back to a page already read stops the list", %{
    provider: provider,
    opts: opts
  } do
    FakeProvider.stub_api(provider, "GET", "/api/people", fn %{query: query} ->
      {person, next} =
        if query["after"] == "b", do: {@alan, "a"}, else: {@ada, "b"}

      {200, [{"link", ~s(</api/people?limit=500&after=#{next}>; rel="next")}],
       %{"people" => [person]}}
    end)

    assert {1, "", stderr} = ehosctl(["people", "list"], opts)
    assert stderr =~ "as the next page one already read, or more pages than any list has"
    assert length(requests(provider, "GET /api/people")) == 3
  end

  test "a next page elsewhere than the list is an error, not the end",
       %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", "/api/people", fn _ ->
      {200, [{"link", ~s(</ehos/api/people?after=x>; rel="next")}], %{"people" => [@ada]}}
    end)

    assert {1, "", stderr} = ehosctl(["people", "show", "zed@example.com"], opts)
    assert stderr =~ "gave a next page ehosctl cannot follow."
  end

  test "rename says the name was removed when EHOS kept none", %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "PATCH", "/api/people/:id", fn _ ->
      {200, %{"person" => %{@ada | "name" => nil}}}
    end)

    assert {0, "Removed the name of ada@example.com.\n", ""} =
             ehosctl(["people", "rename", "6f1c-ada", "  "], opts)
  end

  test "a gateway's 5xx after a write says it may have been done",
       %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "POST", "/api/people/:id/enable", fn _ -> {504, %{}} end)

    assert {5, "", stderr} = ehosctl(["people", "enable", "6f1c-ada"], opts)
    assert stderr =~ "It may have been done: run `ehosctl people show` to see the person."
  end

  test "a next link is found among others, on several lines, in any case",
       %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", "/api/people", fn %{query: query} ->
      if query["after"] == "2" do
        {200, %{"people" => [@alan]}}
      else
        {200,
         [
           {"link", ~s(</api/people?after=0>; rel="first")},
           {"link", ~s(</api/people?after=2>; title="page 2"; rel="prev NEXT")}
         ], %{"people" => [@ada]}}
      end
    end)

    {0, stdout, ""} = ehosctl(["people", "list", "--json"], opts)
    assert %{"people" => [_, _], "more" => false} = JSON.decode!(stdout)
  end

  test "--limit reached on a page is enough, whatever its link", %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", "/api/people", fn _ ->
      {200, [{"link", ~s(</elsewhere?after=x>; rel="next")}], %{"people" => [@ada]}}
    end)

    {0, stdout, ""} = ehosctl(["people", "list", "--limit", "1", "--json"], opts)
    assert %{"people" => [_], "more" => true} = JSON.decode!(stdout)
  end

  test "a link of another relation is not followed", %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", "/api/people", fn _ ->
      {200, [{"link", ~s(</api/people?after=x>; rel="next-archive")}], %{"people" => [@ada]}}
    end)

    {0, _stdout, ""} = ehosctl(["people", "list"], opts)
    assert [_] = requests(provider, "GET /api/people")
  end

  describe "show" do
    test "finds a person by email among the invited and the joined, in any case",
         %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @alan])

      {0, stdout, ""} = ehosctl(["people", "show", "ADA@example.com"], opts)
      assert stdout =~ "email: ada@example.com"
      assert stdout =~ "name:  Ada Lovelace"
      assert stdout =~ "id:    6f1c-ada"

      assert [%{query: %{"state" => "invited,joined", "q" => "ADA@example.com"}}] =
               requests(provider, "GET /api/people")
    end

    test "reads a person by id", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/people/:id", fn %{path: path} ->
        assert path == "/api/people/8b3e-grace"
        {200, %{"person" => @grace}}
      end)

      {0, stdout, ""} = ehosctl(["people", "show", "8b3e-grace", "--json"], opts)
      assert JSON.decode!(stdout) == %{"person" => @grace}
    end

    test "an email nobody invited or joined has is not found, and says how to find the disabled",
         %{provider: provider, opts: opts} do
      serve_people(provider, [@ada, @grace])

      assert {1, "", "ehosctl: No invited or joined person has the email grace@example.com." <> _} =
               ehosctl(["people", "show", "grace@example.com"], opts)
    end

    test "an id that is no person's is EHOS's not_found", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/people/:id", fn _ ->
        {404, %{"error" => "not_found", "message" => "That person no longer exists."}}
      end)

      assert {1, "", "ehosctl: That person no longer exists.\n"} =
               ehosctl(["people", "show", "nobody"], opts)
    end
  end

  describe "invite" do
    test "says the link was mailed, and never prints one", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/people", fn _request ->
        # An answer that held a link would not have it printed.
        {201,
         %{"person" => @alan, "delivery" => "mailed", "link" => "https://ehos/log-in/secret"}}
      end)

      {0, stdout, ""} = ehosctl(["people", "invite", "alan@example.com", "--name", "Alan"], opts)
      assert stdout == "Invited alan@example.com. Their sign-in link was mailed to them.\n"

      assert [%{body: body}] = requests(provider, "POST /api/people")
      assert JSON.decode!(body) == %{"email" => "alan@example.com", "name" => "Alan"}

      FakeProvider.stub_api(provider, "POST", "/api/people", fn _request ->
        {201,
         %{
           "person" => Map.put(@alan, "sign_in_url", "https://ehos/log-in/secret"),
           "delivery" => "mailed"
         }}
      end)

      {0, stdout, ""} = ehosctl(["people", "invite", "alan@example.com", "--json"], opts)
      refute stdout =~ "secret"
      assert JSON.decode!(stdout) == %{"person" => @alan, "delivery" => "mailed"}

      assert List.last(requests(provider, "POST /api/people")).body ==
               ~S({"email":"alan@example.com"})
    end

    test "says when no mail was sent, and how a link is handed over",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/people", fn _ ->
        {201, %{"person" => @ada, "delivery" => "none"}}
      end)

      {0, stdout, ""} = ehosctl(["people", "invite", "ada@example.com"], opts)

      assert stdout ==
               "Invited Ada Lovelace <ada@example.com>. This installation sends no mail, so no " <>
                 "sign-in link was sent: a people manager hands one over by inviting them again " <>
                 "in the console.\n"
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
        FakeProvider.stub_api(provider, "POST", "/api/people", fn _ ->
          {status, %{"error" => code, "message" => sentence}}
        end)

        assert {^exit_code, "", stderr} = ehosctl(["people", "invite", "x@example.com"], opts)
        assert stderr == "ehosctl: #{sentence}\n"
      end
    end
  end

  describe "rename, disable and enable" do
    setup %{provider: provider} do
      serve_people(provider, [@ada, @alan, @grace])
    end

    test "rename finds the person by email among every state, and sends the name alone",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "PATCH", "/api/people/:id", fn %{path: path, body: body} ->
        assert path == "/api/people/8b3e-grace"
        {200, %{"person" => %{@grace | "name" => JSON.decode!(body)["name"]}}}
      end)

      {0, stdout, ""} = ehosctl(["people", "rename", "grace@example.com", "Grace Hopper"], opts)
      assert stdout == "Renamed grace@example.com to Grace Hopper.\n"

      assert [%{query: %{"state" => "invited,joined,disabled"}}] =
               requests(provider, "GET /api/people")

      assert [%{body: ~S({"name":"Grace Hopper"}), content_type: "application/json"}] =
               requests(provider, "PATCH /api/people/8b3e-grace")
    end

    test "an empty name removes it", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "PATCH", "/api/people/:id", fn _ ->
        {200, %{"person" => %{@ada | "name" => nil}}}
      end)

      assert {0, "Removed the name of ada@example.com.\n", ""} =
               ehosctl(["people", "rename", "6f1c-ada", ""], opts)

      assert [%{body: ~S({"name":""})}] = requests(provider, "PATCH /api/people/6f1c-ada")
      # An id is used as it is: nobody is looked up.
      assert requests(provider, "GET /api/people") == []
    end

    test "disable and enable", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/people/:id/disable", fn _ ->
        {200, %{"person" => %{@ada | "state" => "disabled"}}}
      end)

      FakeProvider.stub_api(provider, "POST", "/api/people/:id/enable", fn _ ->
        {200, %{"person" => @grace |> Map.put("state", "joined")}}
      end)

      {0, stdout, ""} = ehosctl(["people", "disable", "ada@example.com"], opts)
      assert stdout =~ "Disabled Ada Lovelace <ada@example.com>: their sign-in has ended"

      {0, stdout, ""} = ehosctl(["people", "enable", "grace@example.com", "--json"], opts)
      assert %{"person" => %{"state" => "joined"}} = JSON.decode!(stdout)

      assert [_] = requests(provider, "POST /api/people/6f1c-ada/disable")
      assert [_] = requests(provider, "POST /api/people/8b3e-grace/enable")
    end

    test "a dot segment is not an id, and nothing is sent", %{opts: opts} do
      for word <- [".", ".."] do
        assert {2, "", "ehosctl: #{word} is not an id; name a person by id or email.\n"} ==
                 ehosctl(["people", "disable", word], opts)
      end
    end

    test "a write EHOS says it did, with an answer it cannot read, says so",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/people/:id/disable", fn _ ->
        {200, %{"person" => %{"id" => 1}}}
      end)

      assert {1, "", stderr} = ehosctl(["people", "disable", "6f1c-ada"], opts)
      assert stderr =~ "It said it was done: run `ehosctl people show` to see the person."
    end

    test "an email nobody has is not found", %{opts: opts} do
      assert {1, "", "ehosctl: Nobody has the email nobody@example.com.\n"} =
               ehosctl(["people", "disable", "nobody@example.com"], opts)
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
        FakeProvider.stub_api(provider, "POST", "/api/people/:id/disable", fn _ ->
          {status, %{"error" => code, "message" => sentence}}
        end)

        assert {^exit_code, "", stderr} = ehosctl(["people", "disable", "6f1c-ada"], opts)
        assert stderr == "ehosctl: #{sentence}\n"
      end
    end

    test "a changeset's fields are in the sentence, and exit 2", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "PATCH", "/api/people/:id", fn _ ->
        {422,
         %{
           "error" => "invalid",
           "message" => "Some fields do not fit: name should be at most 256 character(s).",
           "fields" => %{"name" => ["should be at most 256 character(s)"]}
         }}
      end)

      assert {2, "",
              "ehosctl: Some fields do not fit: name should be at most 256 character(s).\n"} =
               ehosctl(["people", "rename", "6f1c-ada", String.duplicate("a", 300)], opts)
    end
  end

  test "people alone prints its subcommands", %{opts: opts} do
    {0, stdout, ""} = ehosctl(["people"], opts)

    for name <- ~w(list show invite rename disable enable), do: assert(stdout =~ name)
    refute stdout =~ "password"
  end
end

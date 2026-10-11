defmodule Ehosctl.AgreementsTest do
  # `ehosctl apps sign-in list | agree | withdraw` and `ehosctl people agreements | agree |
  # withdraw` (ehos-tools#110), on EHOS's agreements API (eh-os#374, `docs/agreements-api.md`).
  use Ehosctl.SignInCase

  @sign_in "/api/v1/applications/:name/environments/:environment/sign-in"
  @sign_in_client @sign_in <> "/:client"
  @people "/api/v1/applications/:name/environments/:environment/people"

  @agreed %{
    "client" => "ledger",
    "asks" => true,
    "agreed" => true,
    "agreed_at" => "2026-10-11T14:02:09.123456Z",
    "by" => "ada@example.com"
  }
  @asks %{"client" => "shop", "asks" => true, "agreed" => false, "agreed_at" => nil, "by" => nil}
  # Agreed by someone EHOS no longer names, and no longer asked for.
  @kept %{
    "client" => "old",
    "asks" => false,
    "agreed" => true,
    "agreed_at" => "2026-09-01T08:00:00Z",
    "by" => nil
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp api(provider, method, path, status, body),
    do: FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  defp requests(provider, key), do: FakeProvider.requests(provider, key)

  defp sign_in(requests, app \\ "tax", env \\ "production"),
    do: %{"application" => app, "environment" => env, "requests" => requests}

  describe "apps sign-in list" do
    test "lists the pages that ask, and those agreed to, in the console's words",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @sign_in, 200, sign_in([@agreed, @asks, @kept]))

      {0, stdout, ""} = ehosctl(["apps", "sign-in", "list", "tax", "--env", "production"], opts)
      [header | rows] = String.split(stdout, "\n", trim: true)

      assert header =~ ~r/PAGES OF\s+AGREEMENT\s+AGREED\s+BY/

      assert Enum.at(rows, 0) =~
               ~r/ledger\s+agreed\s+11 October 2026, 14:02 UTC\s+ada@example.com/

      assert Enum.at(rows, 1) =~ ~r/^\s*shop\s+asks$/
      assert Enum.at(rows, 2) =~ ~r/old\s+agreed, no longer asked\s+1 September 2026, 08:00 UTC$/

      assert [_] =
               requests(provider, "GET /api/v1/applications/tax/environments/production/sign-in")
    end

    test "says when no pages ask and none is agreed to", %{provider: provider, opts: opts} do
      api(provider, "GET", @sign_in, 200, sign_in([]))

      assert {0,
              "No application's pages ask for credentials for tax in production, and none is " <>
                "agreed to.\n", ""} =
               ehosctl(["apps", "sign-in", "list", "tax", "--env", "production"], opts)
    end

    test "--json prints only the fields a request holds", %{provider: provider, opts: opts} do
      api(
        provider,
        "GET",
        @sign_in,
        200,
        sign_in([Map.put(@agreed, "agreement_id", "x")]) |> Map.put("secret", "do-not-print")
      )

      {0, stdout, ""} =
        ehosctl(["apps", "sign-in", "list", "tax", "--env", "production", "--json"], opts)

      assert JSON.decode!(stdout) == sign_in([@agreed])
    end

    test "names the application and the environment in the path, percent-encoded",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @sign_in, 200, sign_in([], "tax", "pre prod/1"))

      {0, _stdout, ""} = ehosctl(["apps", "sign-in", "list", "tax", "--env", "pre prod/1"], opts)

      assert [_] =
               requests(
                 provider,
                 "GET /api/v1/applications/tax/environments/pre%20prod%2F1/sign-in"
               )
    end

    test "EHOS's refusal is printed in its words, with its kind's exit code",
         %{provider: provider, opts: opts} do
      cases = [
        {403, "forbidden",
         "Reading tax's sign-in in production needs ehos.application.deploy or " <>
           "ehos.application.register for it there.", 3},
        {404, "not_found", "No application is named tax, or no environment production.", 1}
      ]

      for {status, code, sentence, exit_code} <- cases do
        api(provider, "GET", @sign_in, status, %{"error" => code, "message" => sentence})

        assert {^exit_code, "", stderr} =
                 ehosctl(["apps", "sign-in", "list", "tax", "--env", "production"], opts)

        assert stderr == "ehosctl: #{sentence}\n"
      end
    end

    test "an answer about another application or environment, or of another shape, is not taken",
         %{provider: provider, opts: opts} do
      for body <- [
            sign_in([@agreed], "shop"),
            sign_in([@agreed], "tax", "staging"),
            sign_in([Map.delete(@agreed, "asks")]),
            sign_in([%{@agreed | "agreed_at" => "yesterday"}]),
            sign_in([%{@agreed | "client" => ""}]),
            %{"application" => "tax", "environment" => "production"}
          ] do
        api(provider, "GET", @sign_in, 200, body)

        assert {1, "", stderr} =
                 ehosctl(["apps", "sign-in", "list", "tax", "--env", "production"], opts)

        assert stderr =~ "answered with something ehosctl cannot read."
      end
    end
  end

  describe "apps sign-in agree and withdraw" do
    test "agree sends POST for the pages, and says what they may now get",
         %{provider: provider, opts: opts} do
      answer = %{
        "application" => "tax",
        "environment" => "production",
        "client" => "ledger",
        "agreed" => true
      }

      api(provider, "POST", @sign_in_client, 200, answer)

      assert {0, "Agreed: ledger's pages may get credentials for tax in production.\n", ""} =
               ehosctl(["apps", "sign-in", "agree", "tax", "ledger", "--env", "production"], opts)

      api(provider, "POST", @sign_in_client, 200, Map.put(answer, "agreement_id", "x"))

      {0, stdout, ""} =
        ehosctl(
          ["apps", "sign-in", "agree", "tax", "ledger", "--env", "production", "--json"],
          opts
        )

      assert JSON.decode!(stdout) == answer

      assert [_, _] =
               requests(
                 provider,
                 "POST /api/v1/applications/tax/environments/production/sign-in/ledger"
               )
    end

    test "withdraw sends DELETE, and says an issued credential lives out its ten minutes",
         %{provider: provider, opts: opts} do
      answer = %{
        "application" => "tax",
        "environment" => "production",
        "client" => "ledger",
        "agreed" => false
      }

      api(provider, "DELETE", @sign_in_client, 200, answer)

      {0, stdout, ""} =
        ehosctl(["apps", "sign-in", "withdraw", "tax", "ledger", "--env", "production"], opts)

      assert stdout ==
               "Withdrawn: ledger's pages get no more credentials for tax in production; one " <>
                 "already issued expires within ten minutes.\n"

      {0, stdout, ""} =
        ehosctl(
          ["apps", "sign-in", "withdraw", "tax", "ledger", "--env", "production", "--json"],
          opts
        )

      assert JSON.decode!(stdout) == answer
    end

    test "each refusal is printed in EHOS's words, with its kind's exit code",
         %{provider: provider, opts: opts} do
      cases = [
        {"POST", "agree", 403, "forbidden",
         "Only someone who may deploy tax in production may agree (ehos.application.deploy).", 3},
        {"POST", "agree", 409, "not_requested",
         "That application's pages no longer ask for tax in production.", 1},
        {"POST", "agree", 404, "not_found",
         "No application is named tax, or no environment production.", 1},
        {"DELETE", "withdraw", 404, "not_found",
         "There is no such agreement, or the environment was removed.", 1},
        {"DELETE", "withdraw", 403, "forbidden",
         "Only someone who may deploy tax in production may withdraw (ehos.application.deploy).",
         3}
      ]

      for {method, action, status, code, sentence, exit_code} <- cases do
        api(provider, method, @sign_in_client, status, %{"error" => code, "message" => sentence})

        assert {^exit_code, "", stderr} =
                 ehosctl(
                   ["apps", "sign-in", action, "tax", "ledger", "--env", "production"],
                   opts
                 )

        assert stderr == "ehosctl: #{sentence}\n"
      end
    end

    test "an answer for other pages, or that does not say the agreement, says to look",
         %{provider: provider, opts: opts} do
      for body <- [
            %{
              "application" => "tax",
              "environment" => "production",
              "client" => "shop",
              "agreed" => true
            },
            %{
              "application" => "tax",
              "environment" => "production",
              "client" => "ledger",
              "agreed" => false
            }
          ] do
        api(provider, "POST", @sign_in_client, 200, body)

        assert {1, "", stderr} =
                 ehosctl(
                   ["apps", "sign-in", "agree", "tax", "ledger", "--env", "production"],
                   opts
                 )

        assert stderr =~ "answered with something ehosctl cannot read."

        assert stderr =~
                 "not as what was asked: run `ehosctl apps sign-in list tax --env production`"
      end

      api(provider, "POST", @sign_in_client, 200, ["agreed"])

      assert {1, "", stderr} =
               ehosctl(["apps", "sign-in", "agree", "tax", "ledger", "--env", "production"], opts)

      assert stderr =~ "It said it was done: run `ehosctl apps sign-in list tax --env production`"
    end

    test "a gateway's 5xx says it may have been done", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @sign_in_client, 504, %{})

      assert {5, "", stderr} =
               ehosctl(["apps", "sign-in", "withdraw", "tax", "ledger", "--env", "prod"], opts)

      assert stderr =~ "It may have been done: run `ehosctl apps sign-in list tax --env prod`"
    end

    test "a name that would leave its place in the path is refused, and nothing is sent",
         %{provider: provider, opts: opts} do
      for args <- [
            ["agree", "..", "ledger", "--env", "production"],
            ["agree", "tax", ".", "--env", "production"],
            ["withdraw", "tax", "ledger", "--env", ".."],
            ["list", "tax", "--env", ""]
          ] do
        assert {2, "", stderr} = ehosctl(["apps", "sign-in" | args], opts)
        assert stderr =~ "names no application or environment."
      end

      assert requests(
               provider,
               "POST /api/v1/applications/../environments/production/sign-in/ledger"
             ) ==
               []
    end
  end

  test "apps sign-in alone prints its subcommands, and each takes --installation",
       %{opts: opts} do
    {0, stdout, ""} = ehosctl(["apps", "sign-in"], opts)
    for name <- ~w(list agree withdraw), do: assert(stdout =~ name)

    {0, stdout, ""} = ehosctl(["apps", "sign-in", "agree", "--help"], opts)
    assert stdout =~ "CLIENT"
    assert stdout =~ "--installation"
    assert stdout =~ "Plane: governed."
  end

  @reading %{
    "application" => "ledger",
    "environment" => "production",
    "asks" => true,
    "agreed" => true,
    "agreed_at" => "2026-10-11T14:02:09Z",
    "by" => "ada@example.com"
  }
  @reading_asks %{
    "application" => "shop",
    "environment" => "staging",
    "asks" => true,
    "agreed" => false,
    "agreed_at" => nil,
    "by" => nil
  }

  describe "people agreements" do
    test "lists the applications asking to read the people, and those agreed to",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/people-agreements", 200, %{
        "requests" => [@reading, @reading_asks, %{@reading | "asks" => false, "by" => nil}]
      })

      {0, stdout, ""} = ehosctl(["people", "agreements"], opts)
      [header | rows] = String.split(stdout, "\n", trim: true)

      assert header =~ ~r/APPLICATION\s+ENVIRONMENT\s+AGREEMENT\s+AGREED\s+BY/

      assert Enum.at(rows, 0) =~
               ~r/ledger\s+production\s+agreed\s+11 October 2026, 14:02 UTC\s+ada@example.com/

      assert Enum.at(rows, 1) =~ ~r/shop\s+staging\s+asks$/
      assert Enum.at(rows, 2) =~ ~r/ledger\s+production\s+agreed, no longer asked\s+11 October/
    end

    test "says when no application asks", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/people-agreements", 200, %{"requests" => []})

      assert {0, "No application asks to read the people, and none is agreed to.\n", ""} =
               ehosctl(["people", "agreements"], opts)
    end

    test "--json prints only the fields a request holds", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/people-agreements", 200, %{
        "requests" => [Map.put(@reading, "application_id", "x")],
        "secret" => "do-not-print"
      })

      {0, stdout, ""} = ehosctl(["people", "agreements", "--json"], opts)
      assert JSON.decode!(stdout) == %{"requests" => [@reading]}
    end

    test "EHOS's refusal is printed in its words, exit 3", %{provider: provider, opts: opts} do
      sentence = "Reading which applications may read the people needs ehos.people.manage."

      api(provider, "GET", "/api/v1/people-agreements", 403, %{
        "error" => "forbidden",
        "message" => sentence
      })

      assert {3, "", "ehosctl: #{sentence}\n"} == ehosctl(["people", "agreements"], opts)
    end

    test "an answer of another shape is not taken", %{provider: provider, opts: opts} do
      for body <- [
            %{"requests" => [Map.delete(@reading, "environment")]},
            %{"requests" => [%{@reading | "by" => 7}]},
            %{"requests" => nil},
            %{}
          ] do
        api(provider, "GET", "/api/v1/people-agreements", 200, body)

        assert {1, "", stderr} = ehosctl(["people", "agreements"], opts)
        assert stderr =~ "answered with something ehosctl cannot read."
      end
    end
  end

  describe "people agree and withdraw" do
    test "agree and withdraw, in words and as JSON", %{provider: provider, opts: opts} do
      agreed = %{"application" => "ledger", "environment" => "production", "agreed" => true}
      api(provider, "POST", @people, 200, agreed)
      api(provider, "DELETE", @people, 200, %{agreed | "agreed" => false})

      assert {0, "Agreed: ledger may now read the people in production.\n", ""} =
               ehosctl(["people", "agree", "ledger", "--env", "production"], opts)

      assert {0, "Withdrawn: ledger's next reading of the people in production is refused.\n", ""} =
               ehosctl(["people", "withdraw", "ledger", "--env", "production"], opts)

      {0, stdout, ""} =
        ehosctl(["people", "agree", "ledger", "--env", "production", "--json"], opts)

      assert JSON.decode!(stdout) == agreed

      {0, stdout, ""} =
        ehosctl(["people", "withdraw", "ledger", "--env", "production", "--json"], opts)

      assert JSON.decode!(stdout) == %{agreed | "agreed" => false}

      path = "/api/v1/applications/ledger/environments/production/people"
      assert [_, _] = requests(provider, "POST " <> path)
      assert [_, _] = requests(provider, "DELETE " <> path)
    end

    test "each refusal is printed in EHOS's words, with its kind's exit code",
         %{provider: provider, opts: opts} do
      cases = [
        {"POST", "agree", 403, "forbidden",
         "Agreeing that an application may read the people needs ehos.people.manage.", 3},
        {"POST", "agree", 404, "not_found",
         "That application, environment or agreement no longer exists.", 1},
        {"POST", "agree", 409, "not_requested",
         "That application no longer asks to read the people there.", 1},
        {"DELETE", "withdraw", 404, "not_found",
         "That application, environment or agreement no longer exists.", 1}
      ]

      for {method, action, status, code, sentence, exit_code} <- cases do
        api(provider, method, @people, status, %{"error" => code, "message" => sentence})

        assert {^exit_code, "", stderr} =
                 ehosctl(["people", action, "ledger", "--env", "production"], opts)

        assert stderr == "ehosctl: #{sentence}\n"
      end
    end

    test "an answer for another application or environment says to look",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @people, 200, %{
        "application" => "ledger",
        "environment" => "staging",
        "agreed" => true
      })

      assert {1, "", stderr} = ehosctl(["people", "agree", "ledger", "--env", "production"], opts)
      assert stderr =~ "not as what was asked: run `ehosctl people agreements` to see"
    end

    test "a name that would leave its place in the path is refused, and nothing is sent",
         %{provider: provider, opts: opts} do
      assert {2, "", stderr} = ehosctl(["people", "agree", "..", "--env", "production"], opts)
      assert stderr =~ "names no application or environment."

      assert {2, "", _stderr} = ehosctl(["people", "withdraw", "ledger", "--env", "."], opts)

      assert requests(provider, "POST /api/v1/applications/../environments/production/people") ==
               []
    end
  end
end

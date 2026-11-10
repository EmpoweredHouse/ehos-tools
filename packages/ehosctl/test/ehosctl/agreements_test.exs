defmodule Ehosctl.AgreementsTest do
  # `ehosctl apps sign-in list | agree | withdraw` and `ehosctl people agreements | agree |
  # withdraw` (ehos-tools#110), and `ehosctl mail agreements | agree | withdraw` (ehos-tools#454,
  # eh-os D-140), on EHOS's agreements API (eh-os#374, `docs/agreements-api.md`).
  use Ehosctl.SignInCase

  @sign_in "/api/v1/applications/:name/environments/:environment/sign-in"
  @sign_in_client @sign_in <> "/:client"
  @people "/api/v1/applications/:name/environments/:environment/people"
  @mail "/api/v1/applications/:name/environments/:environment/mail"

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

  @sending %{
    "application" => "ledger",
    "environment" => "production",
    "asks" => %{"level" => "external", "reply_domains" => ["example.com", "billing.example.com"]},
    "agreed" => %{"level" => "internal", "reply_domains" => ["example.com"]},
    "agreed_at" => "2026-10-11T14:02:09Z",
    "by" => "ada@example.com"
  }
  @sending_asks %{
    "application" => "shop",
    "environment" => "staging",
    "asks" => %{"level" => "internal", "reply_domains" => []},
    "agreed" => nil,
    "agreed_at" => nil,
    "by" => nil
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "apps sign-in list" do
    test "lists the pages that ask, and those agreed to, in the console's words",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @sign_in, 200, sign_in([@agreed, @asks, @kept]))

      assert ehosctl(["apps", "sign-in", "list", "tax", "--env", "production"], opts) ==
               {0,
                """
                 PAGES OF  AGREEMENT                AGREED                       BY
                 ledger    agreed                   11 October 2026, 14:02 UTC   ada@example.com
                 shop      asks
                 old       agreed, no longer asked  1 September 2026, 08:00 UTC
                """, ""}

      path = "/api/v1/applications/tax/environments/production/sign-in"
      assert requests(provider, "GET " <> path) == [request(path)]
    end

    test "what EHOS names is printed quoted when it holds a control character",
         %{provider: provider, opts: opts} do
      odd = %{@agreed | "client" => "led\e[2Jger", "by" => "ada\u202E@example.com"}
      api(provider, "GET", @sign_in, 200, sign_in([odd]))

      assert ehosctl(["apps", "sign-in", "list", "tax", "--env", "production"], opts) ==
               {0,
                ~S"""
                 PAGES OF       AGREEMENT  AGREED                      BY
                 "led\e[2Jger"  agreed     11 October 2026, 14:02 UTC  "ada\u202E@example.com"
                """, ""}
    end

    test "says when no pages ask and none is agreed to", %{provider: provider, opts: opts} do
      api(provider, "GET", @sign_in, 200, sign_in([]))

      assert ehosctl(["apps", "sign-in", "list", "tax", "--env", "production"], opts) ==
               {0,
                "No sign-in agreements for tax in production. An application shows here when " <>
                  "its pages ask for credentials for tax.\n", ""}
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

      assert ehosctl(["apps", "sign-in", "list", "tax", "--env", "pre prod/1"], opts) ==
               {0,
                "No sign-in agreements for tax in pre prod/1. An application shows here when " <>
                  "its pages ask for credentials for tax.\n", ""}

      path = "/api/v1/applications/tax/environments/pre%20prod%2F1/sign-in"
      assert requests(provider, "GET " <> path) == [request(path)]
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

        assert ehosctl(["apps", "sign-in", "list", "tax", "--env", "production"], opts) ==
                 {exit_code, "", "ehosctl: #{sentence}\n"}
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

        assert ehosctl(["apps", "sign-in", "list", "tax", "--env", "production"], opts) ==
                 cannot_read(provider)
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

      assert ehosctl(["apps", "sign-in", "agree", "tax", "ledger", "--env", "production"], opts) ==
               {0, "Agreed: the pages of ledger can get credentials for tax in production.\n", ""}

      api(provider, "POST", @sign_in_client, 200, Map.put(answer, "agreement_id", "x"))

      {0, stdout, ""} =
        ehosctl(
          ["apps", "sign-in", "agree", "tax", "ledger", "--env", "production", "--json"],
          opts
        )

      assert JSON.decode!(stdout) == answer

      path = "/api/v1/applications/tax/environments/production/sign-in/ledger"
      assert requests(provider, "POST " <> path) == [post(path), post(path)]
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

      assert ehosctl(
               ["apps", "sign-in", "withdraw", "tax", "ledger", "--env", "production"],
               opts
             ) ==
               {0,
                "Withdrew the sign-in agreement: the pages of ledger get no more credentials " <>
                  "for tax in production. A credential already issued expires within 10 " <>
                  "minutes.\n", ""}

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

        assert ehosctl(["apps", "sign-in", action, "tax", "ledger", "--env", "production"], opts) ==
                 {exit_code, "", "ehosctl: #{sentence}\n"}
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

        assert ehosctl(["apps", "sign-in", "agree", "tax", "ledger", "--env", "production"], opts) ==
                 not_as_asked(provider, "apps sign-in list tax --env production")
      end

      api(provider, "POST", @sign_in_client, 200, ["agreed"])

      assert ehosctl(["apps", "sign-in", "agree", "tax", "ledger", "--env", "production"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. EHOS " <>
                  "said that it made the change. Run `ehosctl apps sign-in list tax --env " <>
                  "production` to see it.\n"}
    end

    test "a gateway's 5xx says it may have been done", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @sign_in_client, 504, %{})

      assert ehosctl(["apps", "sign-in", "withdraw", "tax", "ledger", "--env", "prod"], opts) ==
               may_have_been_done(provider, "apps sign-in list tax --env prod")
    end

    test "a name that would leave its place in the path is refused, and nothing is sent",
         %{provider: provider, opts: opts} do
      for {args, name} <- [
            {["agree", "..", "ledger", "--env", "production"], ".."},
            {["agree", "tax", ".", "--env", "production"], "."},
            {["withdraw", "tax", "ledger", "--env", ".."], ".."},
            {["list", "tax", "--env", ""], ""}
          ] do
        assert ehosctl(["apps", "sign-in" | args], opts) == names_nothing(name)
      end

      assert requests(
               provider,
               "POST /api/v1/applications/../environments/production/sign-in/ledger"
             ) ==
               []
    end
  end

  describe "apps sign-in" do
    test "alone prints its subcommands, and each takes --installation", %{opts: opts} do
      assert ehosctl(["apps", "sign-in"], opts) ==
               {0,
                """
                ehosctl #{Ehosctl.version()}
                List, give and withdraw sign-in agreements, as the environment tab of an application does.

                USAGE:
                    ehosctl apps sign-in

                SUBCOMMANDS:

                    list            List the applications whose pages ask for credentials for an
                                    application in an environment, and the sign-in agreements.
                    agree           Agree that the pages of CLIENT can get credentials for
                                    APPLICATION in an environment.
                    withdraw        Withdraw a sign-in agreement. The pages of CLIENT get no
                                    more credentials for APPLICATION there. A credential already
                                    issued expires within 10 minutes.

                Plane: governed. This command acts as you, through EHOS. EHOS decides and records each request.

                """, ""}

      assert ehosctl(["apps", "sign-in", "agree", "--help"], opts) ==
               {0,
                """
                ehosctl #{Ehosctl.version()}
                Agree that the pages of CLIENT can get credentials for APPLICATION in an environment.

                USAGE:
                    ehosctl apps sign-in agree [--json] --env ENVIRONMENT [--installation NAME] APPLICATION CLIENT

                ARGS:

                    APPLICATION        The name of the application that the pages ask
                                       credentials for.
                    CLIENT             The name of the application whose pages ask for the
                                       credentials.

                FLAGS:

                    --json        Print one JSON document instead of words.

                OPTIONS:

                    --env                 The name of the environment.
                    --installation        The installation to talk to, instead of
                                          EHOSCTL_INSTALLATION or the current one.

                Plane: governed. This command acts as you, through EHOS. EHOS decides and records each request.

                """, ""}
    end
  end

  describe "people agreements" do
    test "lists the applications asking to read the people, and those agreed to",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/people-agreements", 200, %{
        "requests" => [@reading, @reading_asks, %{@reading | "asks" => false, "by" => nil}]
      })

      assert ehosctl(["people", "agreements"], opts) ==
               {0,
                """
                 APPLICATION  ENVIRONMENT  AGREEMENT                AGREED                      BY
                 ledger       production   agreed                   11 October 2026, 14:02 UTC  ada@example.com
                 shop         staging      asks
                 ledger       production   agreed, no longer asked  11 October 2026, 14:02 UTC
                """, ""}
    end

    # EHOS's D-161: an agreement an ephemeral environment got from its environment template.
    test "names the environment template an agreement came from, and when it reads nothing",
         %{provider: provider, opts: opts} do
      templated =
        Map.merge(@reading, %{"environment" => "ledger-pr-7", "from_template" => "previews"})

      api(provider, "GET", "/api/v1/people-agreements", 200, %{
        "requests" => [@reading, templated]
      })

      assert ehosctl(["people", "agreements"], opts) ==
               {0,
                """
                 APPLICATION  ENVIRONMENT  AGREEMENT  AGREED                      BY               FROM TEMPLATE
                 ledger       production   agreed     11 October 2026, 14:02 UTC  ada@example.com
                 ledger       ledger-pr-7  agreed     11 October 2026, 14:02 UTC  ada@example.com  previews, not while a pipeline's deployment is in force or failed after the active one
                """, ""}

      {0, stdout, ""} = ehosctl(["people", "agreements", "--json"], opts)
      assert JSON.decode!(stdout) == %{"requests" => [@reading, templated]}
    end

    test "says when no application asks", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/people-agreements", 200, %{"requests" => []})

      assert ehosctl(["people", "agreements"], opts) ==
               {0,
                "No people agreements. An application shows here when its deployment in an environment " <>
                  "asks to read the people.\n", ""}
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

      assert ehosctl(["people", "agreements"], opts) == {3, "", "ehosctl: #{sentence}\n"}
    end

    test "an answer of another shape is not taken", %{provider: provider, opts: opts} do
      for body <- [
            %{"requests" => [Map.delete(@reading, "environment")]},
            %{"requests" => [%{@reading | "by" => 7}]},
            %{"requests" => nil},
            %{}
          ] do
        api(provider, "GET", "/api/v1/people-agreements", 200, body)

        assert ehosctl(["people", "agreements"], opts) == cannot_read(provider)
      end
    end
  end

  describe "people agree and withdraw" do
    test "agree and withdraw, in words and as JSON", %{provider: provider, opts: opts} do
      agreed = %{"application" => "ledger", "environment" => "production", "agreed" => true}
      api(provider, "POST", @people, 200, agreed)
      api(provider, "DELETE", @people, 200, %{agreed | "agreed" => false})

      assert ehosctl(["people", "agree", "ledger", "--env", "production"], opts) ==
               {0, "Agreed: ledger can now read the people in production.\n", ""}

      assert ehosctl(["people", "withdraw", "ledger", "--env", "production"], opts) ==
               {0,
                "Withdrew the people agreement: EHOS refuses the next reading of the people by " <>
                  "ledger in production.\n", ""}

      {0, stdout, ""} =
        ehosctl(["people", "agree", "ledger", "--env", "production", "--json"], opts)

      assert JSON.decode!(stdout) == agreed

      {0, stdout, ""} =
        ehosctl(["people", "withdraw", "ledger", "--env", "production", "--json"], opts)

      assert JSON.decode!(stdout) == %{agreed | "agreed" => false}

      path = "/api/v1/applications/ledger/environments/production/people"
      assert requests(provider, "POST " <> path) == [post(path), post(path)]
      assert requests(provider, "DELETE " <> path) == [request(path), request(path)]
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

        assert ehosctl(["people", action, "ledger", "--env", "production"], opts) ==
                 {exit_code, "", "ehosctl: #{sentence}\n"}
      end
    end

    test "an answer for another application or environment says to look",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @people, 200, %{
        "application" => "ledger",
        "environment" => "staging",
        "agreed" => true
      })

      assert ehosctl(["people", "agree", "ledger", "--env", "production"], opts) ==
               not_as_asked(provider, "people agreements")
    end

    test "a name that would leave its place in the path is refused, and nothing is sent",
         %{provider: provider, opts: opts} do
      assert ehosctl(["people", "agree", "..", "--env", "production"], opts) ==
               names_nothing("..")

      assert ehosctl(["people", "withdraw", "ledger", "--env", "."], opts) == names_nothing(".")

      assert requests(provider, "POST /api/v1/applications/../environments/production/people") ==
               []
    end
  end

  describe "mail agreements" do
    test "lists the applications asking to send mail, and the agreements, in the console's words",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/mail-agreements", 200, %{
        "requests" => [@sending, @sending_asks, %{@sending | "asks" => nil, "by" => nil}]
      })

      assert ehosctl(["mail", "agreements"], opts) ==
               {0,
                """
                 APPLICATION  ENVIRONMENT  ASKS                                                              AGREEMENT                                                       AGREED                      BY
                 ledger       production   to any address, with replies to billing.example.com, example.com  only to the people of the company, with replies to example.com  11 October 2026, 14:02 UTC  ada@example.com
                 shop         staging      only to the people of the company                                 not agreed
                 ledger       production   no longer asks                                                    only to the people of the company, with replies to example.com  11 October 2026, 14:02 UTC
                """, ""}
    end

    test "says when no application asks", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/mail-agreements", 200, %{"requests" => []})

      assert ehosctl(["mail", "agreements"], opts) ==
               {0,
                "No mail agreements. An application shows here when its deployment in an environment " <>
                  "asks to send mail through EHOS.\n", ""}
    end

    test "--json prints only the fields a request holds", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/mail-agreements", 200, %{
        "requests" => [
          @sending
          |> Map.put("application_id", "x")
          |> put_in(["agreed", "agreement_id"], "y")
          |> put_in(["asks", "spec"], "z")
        ],
        "secret" => "do-not-print"
      })

      {0, stdout, ""} = ehosctl(["mail", "agreements", "--json"], opts)
      assert JSON.decode!(stdout) == %{"requests" => [@sending]}
    end

    test "what EHOS names is printed quoted when it holds a control character",
         %{provider: provider, opts: opts} do
      odd = put_in(@sending, ["asks", "reply_domains"], ["ex\e[2Jample.com"])
      api(provider, "GET", "/api/v1/mail-agreements", 200, %{"requests" => [odd]})

      assert ehosctl(["mail", "agreements"], opts) ==
               {0,
                ~S"""
                 APPLICATION  ENVIRONMENT  ASKS                                                AGREEMENT                                                       AGREED                      BY
                 ledger       production   to any address, with replies to "ex\e[2Jample.com"  only to the people of the company, with replies to example.com  11 October 2026, 14:02 UTC  ada@example.com
                """, ""}
    end

    test "EHOS's refusal is printed in its words, exit 3", %{provider: provider, opts: opts} do
      sentence = "Agreeing how far an application may send mail needs ehos.mail.manage."

      api(provider, "GET", "/api/v1/mail-agreements", 403, %{
        "error" => "forbidden",
        "message" => sentence
      })

      assert ehosctl(["mail", "agreements"], opts) == {3, "", "ehosctl: #{sentence}\n"}
    end

    test "an answer of another shape is not taken", %{provider: provider, opts: opts} do
      for body <- [
            %{"requests" => [Map.delete(@sending, "environment")]},
            %{"requests" => [Map.delete(@sending, "asks")]},
            %{"requests" => [Map.delete(@sending, "agreed")]},
            %{"requests" => [%{@sending | "asks" => true}]},
            %{
              "requests" => [
                %{@sending | "agreed" => %{"level" => "everyone", "reply_domains" => []}}
              ]
            },
            %{"requests" => [%{@sending | "agreed" => %{"level" => "internal"}}]},
            %{"requests" => [%{@sending | "agreed_at" => "yesterday"}]},
            %{"requests" => [%{@sending | "by" => 7}]},
            %{"requests" => nil},
            %{}
          ] do
        api(provider, "GET", "/api/v1/mail-agreements", 200, body)

        assert ehosctl(["mail", "agreements"], opts) == cannot_read(provider), inspect(body)
      end
    end
  end

  describe "mail agree and withdraw" do
    test "agree sends the level and the reply domains, and says how far it may send",
         %{provider: provider, opts: opts} do
      agreed = %{
        "application" => "ledger",
        "environment" => "production",
        "agreed" => true,
        "level" => "external",
        "reply_domains" => ["billing.example.com", "example.com"]
      }

      api(provider, "POST", @mail, 200, Map.put(agreed, "agreement_id", "x"))

      args = [
        "mail",
        "agree",
        "ledger",
        "--env",
        "production",
        "--level",
        "external",
        "--reply-domain",
        "example.com",
        "--reply-domain",
        "billing.example.com"
      ]

      assert ehosctl(args, opts) ==
               {0,
                "Agreed: in production, ledger can send mail through EHOS to any address, with " <>
                  "replies to billing.example.com, example.com, as far as its deployment there " <>
                  "asks.\n", ""}

      {0, stdout, ""} = ehosctl(args ++ ["--json"], opts)
      assert JSON.decode!(stdout) == agreed

      path = "/api/v1/applications/ledger/environments/production/mail"
      sent = ~S({"level":"external","reply_domains":["example.com","billing.example.com"]})
      assert requests(provider, "POST " <> path) == [post(path, sent), post(path, sent)]
    end

    test "agree with no reply domain sends none", %{provider: provider, opts: opts} do
      api(provider, "POST", @mail, 200, %{
        "application" => "ledger",
        "environment" => "production",
        "agreed" => true,
        "level" => "internal",
        "reply_domains" => []
      })

      assert ehosctl(
               ["mail", "agree", "ledger", "--env", "production", "--level", "internal"],
               opts
             ) ==
               {0,
                "Agreed: in production, ledger can send mail through EHOS only to the people of " <>
                  "the company, as far as its deployment there asks.\n", ""}

      path = "/api/v1/applications/ledger/environments/production/mail"

      assert requests(provider, "POST " <> path) == [
               post(path, ~S({"level":"internal","reply_domains":[]}))
             ]
    end

    test "withdraw sends DELETE, and says the next message is refused",
         %{provider: provider, opts: opts} do
      withdrawn = %{
        "application" => "ledger",
        "environment" => "production",
        "agreed" => false,
        "level" => nil,
        "reply_domains" => []
      }

      api(provider, "DELETE", @mail, 200, withdrawn)

      assert ehosctl(["mail", "withdraw", "ledger", "--env", "production"], opts) ==
               {0,
                "Withdrew the mail agreement: EHOS refuses the next message of ledger in " <>
                  "production.\n", ""}

      {0, stdout, ""} =
        ehosctl(["mail", "withdraw", "ledger", "--env", "production", "--json"], opts)

      assert JSON.decode!(stdout) == withdrawn

      path = "/api/v1/applications/ledger/environments/production/mail"
      assert requests(provider, "DELETE " <> path) == [request(path), request(path)]
    end

    test "each refusal is printed in EHOS's words, with its kind's exit code",
         %{provider: provider, opts: opts} do
      agree = ["agree", "ledger", "--env", "production", "--level", "external"]
      withdraw = ["withdraw", "ledger", "--env", "production"]

      cases = [
        {"POST", agree, 403, "forbidden",
         "Agreeing how far an application may send mail needs ehos.mail.manage.", 3},
        {"POST", agree, 404, "not_found",
         "That application, environment or agreement no longer exists.", 1},
        {"POST", agree, 409, "not_requested",
         "That application no longer asks to send mail there.", 1},
        {"POST", agree, 409, "wider_than_asked",
         "That application asks to write to the company's people only, so no wider agreement " <>
           "is given.", 1},
        {"POST", agree ++ ["--reply-domain", "other.example.com"], 409, "domain_not_asked",
         "That application does not name every one of those reply domains there.", 1},
        {"POST", ["agree", "ledger", "--env", "production", "--level", "everyone"], 422,
         "invalid",
         "A mail agreement names a level, internal or external, and at most 8 reply domains.", 2},
        {"DELETE", withdraw, 403, "forbidden",
         "Agreeing how far an application may send mail needs ehos.mail.manage.", 3},
        {"DELETE", withdraw, 404, "not_found",
         "That application, environment or agreement no longer exists.", 1}
      ]

      for {method, args, status, code, sentence, exit_code} <- cases do
        api(provider, method, @mail, status, %{"error" => code, "message" => sentence})

        assert ehosctl(["mail" | args], opts) == {exit_code, "", "ehosctl: #{sentence}\n"}, code
      end
    end

    test "an answer for another application, environment or agreement says to look",
         %{provider: provider, opts: opts} do
      asked = %{
        "application" => "ledger",
        "environment" => "production",
        "agreed" => true,
        "level" => "internal",
        "reply_domains" => ["example.com"]
      }

      for body <- [
            %{asked | "environment" => "staging"},
            %{asked | "level" => "external"},
            %{asked | "reply_domains" => []},
            %{asked | "agreed" => false}
          ] do
        api(provider, "POST", @mail, 200, body)

        assert ehosctl(
                 [
                   "mail",
                   "agree",
                   "ledger",
                   "--env",
                   "production",
                   "--level",
                   "internal",
                   "--reply-domain",
                   "example.com"
                 ],
                 opts
               ) == not_as_asked(provider, "mail agreements"),
               inspect(body)
      end
    end

    test "a gateway's 5xx says it may have been done", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @mail, 504, %{})

      assert ehosctl(["mail", "withdraw", "ledger", "--env", "prod"], opts) ==
               may_have_been_done(provider, "mail agreements")
    end

    test "a name that would leave its place in the path is refused, and nothing is sent",
         %{provider: provider, opts: opts} do
      assert ehosctl(["mail", "agree", "..", "--env", "production", "--level", "internal"], opts) ==
               names_nothing("..")

      assert ehosctl(["mail", "withdraw", "ledger", "--env", "."], opts) == names_nothing(".")

      assert requests(provider, "POST /api/v1/applications/../environments/production/mail") ==
               []
    end
  end

  describe "mail" do
    test "alone prints its subcommands, and each takes --installation", %{opts: opts} do
      assert ehosctl(["mail"], opts) ==
               {0,
                """
                ehosctl #{Ehosctl.version()}
                List, give and withdraw mail agreements: how far an application can send mail through EHOS in an environment.

                USAGE:
                    ehosctl mail

                SUBCOMMANDS:

                    agreements        List the applications that ask to send mail through EHOS
                                      in an environment, and the mail agreements.
                    agree             Agree how far an application can send mail through EHOS in
                                      an environment, or change the mail agreement. The
                                      application sends no further than its deployment there
                                      asks.
                    withdraw          Withdraw a mail agreement. EHOS refuses the next message
                                      of the application.

                Plane: governed. This command acts as you, through EHOS. EHOS decides and records each request.

                """, ""}

      assert ehosctl(["mail", "agree", "--help"], opts) ==
               {0,
                """
                ehosctl #{Ehosctl.version()}
                Agree how far an application can send mail through EHOS in an environment, or change the mail agreement. The application sends no further than its deployment there asks.

                USAGE:
                    ehosctl mail agree [--json] --env ENVIRONMENT --level LEVEL [--reply-domain DOMAIN] [--installation NAME] APPLICATION

                ARGS:

                    APPLICATION        The name of the application.

                FLAGS:

                    --json        Print one JSON document instead of words.

                OPTIONS:

                    --env                 The name of the environment.
                    --level               internal: only to the people of the company. external:
                                          to any address, if the application asks for it.
                    --reply-domain        A domain that replies can go to, from the domains that
                                          the application names there. Repeat for more, up to
                                          8. Without it, the mail agreement names no reply
                                          domain.
                    --installation        The installation to talk to, instead of
                                          EHOSCTL_INSTALLATION or the current one.

                Plane: governed. This command acts as you, through EHOS. EHOS decides and records each request.

                """, ""}
    end
  end

  defp requests(provider, key), do: FakeProvider.requests(provider, key)

  defp sign_in(requests, app \\ "tax", env \\ "production"),
    do: %{"application" => app, "environment" => env, "requests" => requests}

  # A request with no body, as a GET or a DELETE sends it.
  defp request(path), do: %{path: path, query: %{}, body: "", content_type: nil}

  defp post(path, body \\ "{}"),
    do: %{path: path, query: %{}, body: body, content_type: "application/json"}

  defp cannot_read(provider),
    do: {1, "", "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}

  defp not_as_asked(provider, command),
    do:
      {1, "",
       "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. It answered " <>
         "that something was done, but not as what was asked: run `ehosctl #{command}` to see " <>
         "what was done.\n"}

  defp may_have_been_done(provider, command),
    do:
      {5, "",
       "ehosctl: #{provider.issuer} is unavailable (HTTP 504). Try again later. EHOS possibly " <>
         "made the change. Run `ehosctl #{command}` to see.\n"}

  defp names_nothing(name),
    do:
      {2, "",
       ~s(ehosctl: "#{name}" is not the name of an application or an environment. ) <>
         "Give the name of each application and of the environment.\n"}
end

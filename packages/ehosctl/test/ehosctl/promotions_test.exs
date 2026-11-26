defmodule Ehosctl.PromotionsTest do
  # `ehosctl promotions` (#246, eh-os D-105): an application's candidates and promotions, those
  # that wait for the caller, and a promotion's review, as the console shows them.
  use Ehosctl.SignInCase

  @digest "sha256:" <> String.duplicate("a1", 32)
  @image "ghcr.io/example/ledger@" <> @digest
  @manifest "sha256:" <> String.duplicate("b2", 32)
  @in_force "sha256:" <> String.duplicate("c3", 32)
  @candidate "1f0c2b3a-0000-4000-8000-000000000001"
  @promotion "4c7a6b5e-0000-4000-8000-000000000004"
  @older "5d8b7c6f-0000-4000-8000-000000000005"
  @review_path "/api/v1/promotions/" <> @promotion

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "promotions APPLICATION" do
    test "prints the way to production, the candidates and the promotions",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/promotions", 200, overview())

      {0, stdout, ""} = ehosctl(["promotions", "ledger"], opts)

      assert stdout == """
             Promotions of ledger. Four eyes is on: the person who deployed a candidate or asked for its promotion does not approve it.

             To production: deployed to an ephemeral environment > candidate > [promotion asked for] > approved > in production Production runs a promoted version.

             Candidates:
              CANDIDATE                             ENVIRONMENT  #{String.pad_trailing("IMAGE", String.length(@image) + 2)}DEPLOYED BY      TRY IT
              #{@candidate}  ledger-try   #{@image}  ada@example.com  https://ledger-try.example.com
             Where each came from:
               #{@candidate}: from GitHub's token: example/ledger, branch main, commit 0123456789abcdef0123456789abcdef01234567, run 42 (attempt 1)

             Promotions, newest first:
              PROMOTION                             TO          FROM        STATE      ASKED BY         DECIDED BY
              #{@promotion}  production  ledger-try  requested  ada@example.com  <none>
              #{@older}  production  ledger-try  approved   ada@example.com  ada@example.com (self-approved)
             Run `ehosctl promotions show PROMOTION` to read the review of one.
             """
    end

    test "says <none> to try a candidate that has no address",
         %{provider: provider, opts: opts} do
      body = update_in(overview(), ["candidates"], fn [c] -> [%{c | "addresses" => []}] end)
      api(provider, "GET", "/api/v1/applications/ledger/promotions", 200, body)

      {0, stdout, ""} = ehosctl(["promotions", "ledger"], opts)

      assert stdout == """
             Promotions of ledger. Four eyes is on: the person who deployed a candidate or asked for its promotion does not approve it.

             To production: deployed to an ephemeral environment > candidate > [promotion asked for] > approved > in production Production runs a promoted version.

             Candidates:
              CANDIDATE                             ENVIRONMENT  #{String.pad_trailing("IMAGE", String.length(@image) + 2)}DEPLOYED BY      TRY IT
              #{@candidate}  ledger-try   #{@image}  ada@example.com  <none>
             Where each came from:
               #{@candidate}: from GitHub's token: example/ledger, branch main, commit 0123456789abcdef0123456789abcdef01234567, run 42 (attempt 1)

             Promotions, newest first:
              PROMOTION                             TO          FROM        STATE      ASKED BY         DECIDED BY
              #{@promotion}  production  ledger-try  requested  ada@example.com  <none>
              #{@older}  production  ledger-try  approved   ada@example.com  ada@example.com (self-approved)
             Run `ehosctl promotions show PROMOTION` to read the review of one.
             """
    end

    test "--json keeps the fields ehosctl reads", %{provider: provider, opts: opts} do
      api(
        provider,
        "GET",
        "/api/v1/applications/ledger/promotions",
        200,
        Map.put(overview(), "later", "unread")
      )

      {0, json, ""} = ehosctl(["promotions", "ledger", "--json"], opts)

      assert JSON.decode!(json) == overview()
    end

    test "says a production environment the caller does not act in, and no candidates",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/ledger/promotions", 200, %{
        "four_eyes" => false,
        "candidates" => [],
        "production" => ["production"],
        "way" => %{
          "production" => %{"at" => "none", "in_production" => false, "known" => false}
        },
        "promotions" => []
      })

      {0, stdout, ""} = ehosctl(["promotions", "ledger"], opts)

      assert stdout == """
             Promotions of ledger. Four eyes is off: the person who deployed a candidate or asked for its promotion can approve it.

             To production: EHOS shows the state of production only to a person who can deploy, register or approve there.

             No candidates. A candidate shows here when a deployment of ledger is active in an ephemeral environment.

             No promotions of ledger yet.
             """
    end

    test "reads an EHOS that gives no way to production", %{provider: provider, opts: opts} do
      api(
        provider,
        "GET",
        "/api/v1/applications/ledger/promotions",
        200,
        Map.delete(overview(), "way")
      )

      {0, stdout, ""} = ehosctl(["promotions", "ledger"], opts)
      refute stdout =~ "To production"
    end

    test "refuses an answer it cannot read", %{provider: provider, opts: opts} do
      digest = %{"algorithm" => "sha256"}

      for body <- [
            %{"promotions" => 1},
            update_in(overview(), ["candidates"], fn [candidate] ->
              [%{candidate | "authority_digest" => digest}]
            end)
          ] do
        api(provider, "GET", "/api/v1/applications/ledger/promotions", 200, body)

        assert ehosctl(["promotions", "ledger"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
      end
    end

    test "refuses no application, an application with --waiting, and a name that is no segment",
         %{opts: opts} do
      assert ehosctl(["promotions"], opts) ==
               {2, "", "ehosctl: Name an application, or give --waiting.\n"}

      assert ehosctl(["promotions", "ledger", "--waiting"], opts) ==
               {2, "",
                "ehosctl: Give an application or --waiting, not both: --waiting lists the " <>
                  "promotions of every application that wait for you.\n"}

      assert ehosctl(["promotions", ".."], opts) ==
               {2, "", "ehosctl: .. is not the name of an application.\n"}
    end
  end

  describe "promotions --waiting" do
    test "lists the promotions that wait for the caller, oldest first",
         %{provider: provider, opts: opts} do
      waiting =
        promotion(@promotion, "requested", %{
          "application" => "ledger",
          "environment" => "production",
          "candidate_environment" => "ledger-try"
        })

      api(provider, "GET", "/api/v1/promotions", 200, %{"promotions" => [waiting]})

      {0, stdout, ""} = ehosctl(["promotions", "--waiting"], opts)

      assert stdout == """
             Promotions that wait for your approval, oldest first:
              PROMOTION                             APPLICATION  TO          FROM        ASKED
              #{@promotion}  ledger       production  ledger-try  12 November 2026, 08:00 UTC
             Run `ehosctl promotions show PROMOTION` to read the review of one.
             """

      {0, json, ""} = ehosctl(["promotions", "--waiting", "--json"], opts)
      assert JSON.decode!(json) == %{"promotions" => [waiting]}
    end

    test "says when none waits", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/promotions", 200, %{"promotions" => []})

      assert ehosctl(["promotions", "--waiting"], opts) ==
               {0, "No promotion waits for your approval.\n", ""}
    end
  end

  describe "promotions show" do
    test "prints the review an approver reads", %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, review())

      {0, stdout, ""} = ehosctl(["promotions", "show", String.upcase(@promotion)], opts)

      assert stdout == """
             Promote sha256:a1a1a1a1a1a1 from ledger-try to production

             ! EHOS did not check that the candidate does what it must do.
               The candidate ran in ledger-try. EHOS did not check that its image serves the specifications that its manifest names. If you approve, you confirm that the candidate does what it must do. EHOS checks what other applications read from it by the names and versions that they subscribe to. EHOS does not check the fields that they use.

             ! EHOS could not check these points about the applications that read from it:
               - billing declares nothing EHOS read

             You deployed this candidate or asked for its promotion. Four eyes is on, so another person must approve it.

             ! mail.example.com:587 is the mail server of this installation.
               If the mail server admits the server by its address, ledger can send through it as anyone in the domain of the company. That mail goes around its mail agreement and the audit record. Approve this only if you intend it. This path closes only when the mail server requires a user and no longer admits the server by its address.

             Promotion #{@promotion}
               State      requested
               Try it     https://ledger-try.example.com
               Image      #{@image}
               Manifest   #{@manifest}
               Source     from GitHub's token: example/ledger, branch main, commit 0123456789abcdef0123456789abcdef01234567, run 42 (attempt 1)

             In production:
               Version in force now   #{@in_force}
               Code changes           https://github.com/example/ledger/compare/fedcba987654...0123456789ab
               Commits stated by the pipeline:
                 0123456789ab Post entries in batches
                 fedcba987655
               What it changes in authority:
                 capabilities added: ledger.post
                 hosts outside the installation added: mail.example.com:587
             """
    end

    test "--json keeps the review's fields, and leaves out those EHOS did not give",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, Map.put(review(), "later", "unread"))

      {0, json, ""} = ehosctl(["promotions", "show", @promotion, "--json"], opts)
      assert JSON.decode!(json) == %{"review" => review()}

      older =
        Map.drop(
          review(),
          ~w(compare changes build mail_relay readers_said breaks breaks_held source addresses
             callers services_hosts kind service_callers)
        )

      api(provider, "GET", @review_path, 200, older)

      {0, json, ""} = ehosctl(["promotions", "show", @promotion, "--json"], opts)
      assert JSON.decode!(json) == %{"review" => older}

      # Each key an older EHOS does not give is said as none.
      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)
      refute stdout =~ "Code changes"
      refute stdout =~ "Try it"
      refute stdout =~ "Source"
      refute stdout =~ "mail server"
      refute stdout =~ "could not check"
      refute stdout =~ "Applications:"
      refute stdout =~ "utility services"
    end

    test "says that production's side is not shown to someone who does not act there",
         %{provider: provider, opts: opts} do
      unseen =
        Map.merge(review(), %{
          "there" => false,
          "self" => false,
          "in_force" => nil,
          "compare" => nil,
          "changes" => nil,
          "authority" => nil,
          "diff" => nil,
          "described" => nil,
          "readers_said" => [],
          "mail_relay" => [],
          "requester_can_deploy" => nil
        })

      api(provider, "GET", @review_path, 200, unseen)

      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)

      assert stdout =~
               "\n\nYou do not deploy, register or approve in production, so EHOS does not " <>
                 "show its side: the version in force, what the candidate changes there, and " <>
                 "why it would be refused.\n"

      refute stdout =~ "Version in force"
    end

    test "says what stops an approval", %{provider: provider, opts: opts} do
      blocked =
        Map.merge(review(), %{
          "self" => false,
          "readers_said" => [],
          "mail_relay" => [],
          "changed" => true,
          "refusals" => ["ledger needs a database"],
          "candidate_active" => false,
          "requester_can_deploy" => false,
          "register" => %{"needed" => true, "held" => false},
          "breaks" => ["billing subscribes to ledger.entries, which it would stop publishing"],
          "breaks_held" => false,
          "promotion" => Map.put(review()["promotion"], "break_reason", "billing moves to v2")
        })

      api(provider, "GET", @review_path, 200, blocked)

      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)

      # The notices, whole and in the console's order, up to the promotion's own record.
      [notices, _record] = String.split(stdout, "\n\nPromotion #{@promotion}\n")

      assert notices ==
               """
               Promote sha256:a1a1a1a1a1a1 from ledger-try to production

               ! EHOS did not check that the candidate does what it must do.
                 The candidate ran in ledger-try. EHOS did not check that its image serves the specifications that its manifest names. If you approve, you confirm that the candidate does what it must do. EHOS checks what other applications read from it by the names and versions that they subscribe to. EHOS does not check the fields that they use.

               The requester asked to break other applications on purpose. Reason: billing moves to v2
                 - billing subscribes to ledger.entries, which it would stop publishing
               Only a person who can approve promotions of each application that it breaks can approve this promotion.

               The version in force in production changed after the request. Nobody can approve this promotion now. Ask for the promotion again.

               production does not accept this candidate now, for these reasons:
                 - ledger needs a database

               The candidate is no longer active. If a person tries to approve the promotion, EHOS withdraws it.

               The person who asked for this promotion can no longer deploy in production. EHOS records the deployment as theirs, so nobody can approve it. Ask for the promotion again.

               This promotion changes the authority of the application. To approve it, you also need the right to register the application in production. Ask for the role ehos.registrar there.\
               """
    end

    test "says a decided promotion's reason, and a self-approval", %{
      provider: provider,
      opts: opts
    } do
      refused =
        Map.merge(review(), %{
          "promotion" =>
            Map.merge(review()["promotion"], %{"state" => "refused", "reason" => "Not yet"}),
          "authority" => "unchanged",
          "requester_can_deploy" => nil,
          "mail_relay" => []
        })

      api(provider, "GET", @review_path, 200, refused)
      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)

      assert stdout =~
               "This promotion was refused, so nothing changed in production. The lists below " <>
                 "show what an approval would have changed."

      assert stdout =~ "  Reason     Not yet\n"
      assert stdout =~ "  Version in force at the request   #{@in_force}\n"
      refute stdout =~ "EHOS did not check"

      approved =
        Map.merge(refused, %{
          "promotion" =>
            Map.merge(review()["promotion"], %{"state" => "approved", "self_approved" => true})
        })

      api(provider, "GET", @review_path, 200, approved)
      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)

      assert stdout =~
               "No second person approved it, because four eyes was off on this installation."

      assert stdout =~
               "The candidate granted the same authority as the version in force at the time " <>
                 "of the request."
    end

    test "says the applications that a utility service's promotion agrees for, and their hosts",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, service_review(%{}))

      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)

      assert stdout =~
               """

               This promotion adds hosts outside the installation. If you approve, you also agree for each application that calls invoice-pdf in production. What these applications send invoice-pdf can then reach the hosts below.
               Applications:
                 - office
                 - an application you may not open
               Hosts that each application then reaches:
                 - api.office.example:443

               """

      assert stdout =~ "    hosts outside the installation added: api.office.example:443\n"

      {0, json, ""} = ehosctl(["promotions", "show", @promotion, "--json"], opts)
      assert JSON.decode!(json) == %{"review" => service_review(%{})}
    end

    test "says what stops an approval for a utility service's callers",
         %{provider: provider, opts: opts} do
      api(
        provider,
        "GET",
        @review_path,
        200,
        service_review(%{"held" => false, "changed" => true})
      )

      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)

      assert stdout =~
               """
                 - api.office.example:443
               Only a person who can approve promotions of each of these applications can approve this promotion.
               The hosts that this promotion adds, or the applications that call invoice-pdf, changed after the request. Nobody can approve this promotion now. Ask for the promotion again.

               """

      # A promotion that adds a host for no caller agrees for none, and says nothing of it.
      api(provider, "GET", @review_path, 200, service_review(%{"named" => [], "held" => false}))

      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)
      refute stdout =~ "Applications:"
      refute stdout =~ "Only a person"
    end

    test "says the callers of a decided promotion in its tense", %{provider: provider, opts: opts} do
      for {state, said} <- [
            {"approved",
             "The approval also agreed for each application that called invoice-pdf in " <>
               "production. What these applications send invoice-pdf can reach the hosts below."},
            {"refused",
             "An approval would also have agreed for each application that called invoice-pdf " <>
               "in production."}
          ] do
        decided =
          %{"held" => false}
          |> service_review()
          |> put_in(["promotion", "state"], state)
          |> Map.put("requester_can_deploy", nil)

        api(provider, "GET", @review_path, 200, decided)

        {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)
        assert stdout =~ "\nThis promotion adds hosts outside the installation. #{said}\n"
        refute stdout =~ "Only a person"
      end
    end

    test "says what the approver of a utility service confirms, and the applications that call it",
         %{provider: provider, opts: opts} do
      # A field of a caller that ehosctl does not read stays out of --json.
      answer =
        update_in(utility_review(), ["service_callers", "named"], fn [first | rest] ->
          [Map.put(first, "later", "unread") | rest]
        end)

      api(provider, "GET", @review_path, 200, answer)

      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)

      assert stdout == """
             Promote sha256:a1a1a1a1a1a1 from invoice-pdf-try to production

             ! EHOS does not check what a utility service does.
               The candidate ran in invoice-pdf-try. invoice-pdf is a utility service: a program with no contract. If you approve, you confirm that the candidate does what the applications that call it need. EHOS does not check what these applications send invoice-pdf, or what invoice-pdf answers.

             These applications ask to call invoice-pdf in production now, or have a service agreement for it:
               - office: agreed
               - payroll: asks, not agreed
               - store: agreed, waits for the application's side
               - an application you may not open

             Promotion #{@promotion}
               State      requested
               Try it     https://ledger-try.example.com
               Image      #{@image}
               Manifest   #{@manifest}
               Source     from GitHub's token: example/ledger, branch main, commit 0123456789abcdef0123456789abcdef01234567, run 42 (attempt 1)

             In production:
               Version in force now   <none>
               It adds or removes no host outside the installation.
             """

      {0, json, ""} = ehosctl(["promotions", "show", @promotion, "--json"], opts)
      assert JSON.decode!(json) == %{"review" => utility_review()}
    end

    test "says when no application calls a utility service there, and the hosts it changes",
         %{provider: provider, opts: opts} do
      none =
        utility_review()
        |> Map.put("service_callers", %{"named" => [], "others" => nil})
        |> put_in(["diff", "egress_added"], ["api.office.example:443"])

      api(provider, "GET", @review_path, 200, none)

      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)

      assert stdout == """
             Promote sha256:a1a1a1a1a1a1 from invoice-pdf-try to production

             ! EHOS does not check what a utility service does.
               The candidate ran in invoice-pdf-try. invoice-pdf is a utility service: a program with no contract. If you approve, you confirm that the candidate does what the applications that call it need. EHOS does not check what these applications send invoice-pdf, or what invoice-pdf answers.

             No application asks to call invoice-pdf in production now.

             Promotion #{@promotion}
               State      requested
               Try it     https://ledger-try.example.com
               Image      #{@image}
               Manifest   #{@manifest}
               Source     from GitHub's token: example/ledger, branch main, commit 0123456789abcdef0123456789abcdef01234567, run 42 (attempt 1)

             In production:
               Version in force now   <none>
               What it changes:
                 hosts outside the installation added: api.office.example:443
             """
    end

    test "says the hosts that a candidate reaches through the utility services it starts to call",
         %{provider: provider, opts: opts} do
      starts =
        Map.merge(review(), %{
          "readers_said" => [],
          "mail_relay" => [],
          "services_hosts" => [
            %{
              "service" => "invoice-pdf",
              "hosts" => ["api.office.example:443", "files.office.example:443"]
            }
          ]
        })

      api(provider, "GET", @review_path, 200, starts)

      {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)

      assert stdout =~
               """

               The candidate starts to call utility services that send data to hosts outside the installation. What ledger sends them can then reach these hosts:
                 - invoice-pdf: api.office.example:443, files.office.example:443

               """

      {0, json, ""} = ehosctl(["promotions", "show", @promotion, "--json"], opts)
      assert JSON.decode!(json) == %{"review" => starts}
    end

    test "says why EHOS cannot compare the code", %{provider: provider, opts: opts} do
      for {missing, said} <- [
            {["same_repository"],
             "Production and the candidate come from different repositories."},
            {["in_force", "candidate"],
             "The deployment in production and the candidate name no commit from the GitHub token."},
            {["in_force_unknown"],
             "EHOS does not know which deployment production ran at the time of the request."}
          ] do
        compare = %{"url" => nil, "missing" => missing}

        api(
          provider,
          "GET",
          @review_path,
          200,
          Map.merge(review(), %{"compare" => compare, "changes" => nil})
        )

        {0, stdout, ""} = ehosctl(["promotions", "show", @promotion], opts)
        assert stdout =~ "  Code changes           EHOS cannot compare the code. " <> said <> "\n"
      end
    end

    test "refuses a review of another promotion, or of none named, and an id that is no segment",
         %{provider: provider, opts: opts} do
      for review <- [
            put_in(review(), ["promotion", "id"], @older),
            put_in(review(), ["promotion", "environment"], nil),
            Map.put(review(), "callers", []),
            Map.put(review(), "callers", %{
              "adds" => [],
              "named" => [1],
              "held" => true,
              "changed" => false
            }),
            Map.put(review(), "callers", %{"adds" => [], "named" => [], "held" => true}),
            Map.put(review(), "services_hosts", nil),
            Map.put(review(), "kind", 1),
            Map.put(review(), "service_callers", []),
            Map.put(review(), "service_callers", %{"named" => [], "others" => 1}),
            Map.put(review(), "service_callers", %{
              "named" => [%{"application" => "office", "asks" => true}],
              "others" => nil
            }),
            Map.put(review(), "services_hosts", [%{"service" => "invoice-pdf", "hosts" => "x"}])
          ] do
        api(provider, "GET", @review_path, 200, review)

        assert ehosctl(["promotions", "show", @promotion], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
      end

      assert ehosctl(["promotions", "show", "."], opts) ==
               {2, "", "ehosctl: . is not the id of a promotion.\n"}
    end

    test "prints EHOS's refusal with its exit code", %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 404, %{
        "error" => "not_found",
        "message" => "No such promotion."
      })

      assert ehosctl(["promotions", "show", @promotion], opts) ==
               {1, "", "ehosctl: No such promotion.\n"}

      api(provider, "GET", @review_path, 403, %{
        "error" => "forbidden",
        "message" => "You may not read the promotions of ledger."
      })

      assert ehosctl(["promotions", "show", @promotion], opts) ==
               {3, "", "ehosctl: You may not read the promotions of ledger.\n"}
    end
  end

  defp overview do
    %{
      "four_eyes" => true,
      "candidates" => [
        %{
          "id" => @candidate,
          "environment" => "ledger-try",
          "image" => @image,
          "manifest_digest" => @manifest,
          "authority_digest" => @manifest,
          "by" => "ada@example.com",
          "at" => "2026-11-12T07:00:00Z",
          "addresses" => ["https://ledger-try.example.com"],
          "source" => source(),
          "build" => nil
        }
      ],
      "production" => ["production"],
      "way" => %{
        "production" => %{"at" => "requested", "in_production" => true, "known" => true}
      },
      "promotions" => [
        promotion(@promotion, "requested", %{
          "environment" => "production",
          "candidate_environment" => "ledger-try",
          "requested_by" => "ada@example.com",
          "decided_by" => nil
        }),
        promotion(@older, "approved", %{
          "environment" => "production",
          "candidate_environment" => "ledger-try",
          "requested_by" => "ada@example.com",
          "decided_by" => "ada@example.com",
          "self_approved" => true,
          "four_eyes" => false
        })
      ]
    }
  end

  defp review do
    %{
      "promotion" =>
        promotion(@promotion, "requested", %{
          "application" => "ledger",
          "environment" => "production",
          "candidate_environment" => "ledger-try",
          "in_force_digest" => @in_force
        }),
      "there" => true,
      "four_eyes" => true,
      "self" => true,
      "may_approve" => true,
      "may_withdraw" => true,
      "approvable" => false,
      "in_force" => @in_force,
      "changed" => false,
      "compare" => %{
        "url" => "https://github.com/example/ledger/compare/fedcba987654...0123456789ab",
        "missing" => []
      },
      "changes" => [
        %{"commit" => "0123456789abcdef", "title" => "Post entries in batches"},
        %{"commit" => "fedcba9876550000", "title" => nil}
      ],
      "build" => nil,
      "authority" => "changed",
      "register" => %{"needed" => false, "held" => true},
      "refusals" => [],
      "readers_said" => ["billing declares nothing EHOS read"],
      "breaks" => [],
      "breaks_held" => false,
      "requester_can_deploy" => true,
      "candidate_active" => true,
      "source" => source(),
      "addresses" => ["https://ledger-try.example.com"],
      "diff" => %{
        "capabilities_added" => ["ledger.post"],
        "capabilities_removed" => [],
        "roles_added" => [],
        "roles_removed" => [],
        "roles_grown" => %{},
        "roles_shrunk" => %{},
        "grants_widened" => %{},
        "grants_narrowed" => %{},
        "egress_added" => ["mail.example.com:587"],
        "egress_removed" => []
      },
      "described" => %{
        "roles_added" => [],
        "redescribed" => [],
        "grants_changed" => [],
        "grantable_grown" => []
      },
      "mail_relay" => ["mail.example.com:587"],
      "callers" => nil,
      "services_hosts" => [],
      "kind" => "application",
      "service_callers" => nil
    }
  end

  # A promotion of the utility service invoice-pdf, its first to production, that adds no host, as
  # EHOS reviews it with its callers there.
  defp utility_review do
    review()
    |> Map.merge(%{
      "kind" => "service",
      "in_force" => nil,
      "compare" => nil,
      "changes" => nil,
      "readers_said" => [],
      "mail_relay" => [],
      "self" => false,
      "service_callers" => %{
        "named" => [
          %{
            "application" => "office",
            "asks" => true,
            "deployed" => true,
            "agreed" => true,
            "holds" => true,
            "application_side" => "not_needed"
          },
          %{
            "application" => "payroll",
            "asks" => true,
            "deployed" => true,
            "agreed" => false,
            "holds" => false,
            "application_side" => "not_needed"
          },
          %{
            "application" => "store",
            "asks" => true,
            "deployed" => true,
            "agreed" => true,
            "holds" => false,
            "application_side" => "waiting"
          }
        ],
        "others" => "an application you may not open"
      }
    })
    |> put_in(["promotion", "application"], "invoice-pdf")
    |> put_in(["promotion", "candidate_environment"], "invoice-pdf-try")
    |> put_in(["diff", "capabilities_added"], [])
    |> put_in(["diff", "egress_added"], [])
  end

  # A promotion of the utility service invoice-pdf that adds a host, as EHOS reviews it.
  defp service_review(callers) do
    review()
    |> Map.merge(%{
      "readers_said" => [],
      "mail_relay" => [],
      "callers" =>
        Map.merge(
          %{
            "adds" => ["api.office.example:443"],
            "named" => ["office", "an application you may not open"],
            "held" => true,
            "changed" => false
          },
          callers
        )
    })
    |> put_in(["promotion", "application"], "invoice-pdf")
    |> put_in(["diff", "capabilities_added"], [])
    |> put_in(["diff", "egress_added"], ["api.office.example:443"])
  end

  defp promotion(id, state, fields) do
    Map.merge(
      %{
        "id" => id,
        "state" => state,
        "candidate_id" => @candidate,
        "image" => @image,
        "image_digest" => @digest,
        "manifest_digest" => @manifest,
        "authority_digest" => @manifest,
        "in_force_digest" => @in_force,
        "reason" => nil,
        "break_reason" => nil,
        "four_eyes" => true,
        "self_approved" => false,
        "deployment_id" => nil,
        "decided_at" => nil,
        "inserted_at" => "2026-11-12T08:00:00Z"
      },
      fields
    )
  end

  defp source do
    %{
      "kind" => "github_run",
      "repository" => "example/ledger",
      "ref" => "refs/heads/main",
      "commit" => "0123456789abcdef0123456789abcdef01234567",
      "event" => "push",
      "run_id" => 42,
      "run_attempt" => 1
    }
  end
end

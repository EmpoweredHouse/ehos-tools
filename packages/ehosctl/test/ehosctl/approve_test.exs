defmodule Ehosctl.ApproveTest do
  # `ehosctl approve` and `ehosctl refuse` (#246, eh-os D-105): decide a promotion after its
  # review, as the console's review does, and follow the production deployment an approval decides.
  use Ehosctl.SignInCase

  @digest "sha256:" <> String.duplicate("a1", 32)
  @image "ghcr.io/example/ledger@" <> @digest
  @manifest "sha256:" <> String.duplicate("b2", 32)
  @candidate "1f0c2b3a-0000-4000-8000-000000000001"
  @promotion "4c7a6b5e-0000-4000-8000-000000000004"
  @deployment "6e9c8d7a-0000-4000-8000-000000000006"
  @review_path "/api/v1/promotions/" <> @promotion
  @approve @review_path <> "/approve"
  @refuse @review_path <> "/refuse"
  @deployments "/api/v1/applications/ledger/environments/production/deployments"
  # A value with what a shell expands, a quote that ends a word, and a character a terminal acts on.
  @odd "x$(id)'\e"

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    stub_virtual_clock()
    :ok
  end

  describe "approve" do
    test "prints the review, asks, approves, and waits until the deployment is active",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, review())
      api(provider, "POST", @approve, 200, approved("pending"))
      history(provider, "active")
      mock_terminal_answer("y\n")

      {0, stdout, stderr} = ehosctl(["approve", @promotion], opts)

      assert stdout =~ "Promote sha256:a1a1a1a1a1a1 from ledger-try to production\n"
      assert stdout =~ "\n  Version in force now: none\n"

      assert String.ends_with?(
               stdout,
               """

               You approved promotion #{@promotion}. EHOS decided deployment #{@deployment} of ledger in production: it is pending.

               ✓ Deployment #{@deployment} is active in production.
                 Address   https://ledger.example.com
               """
             )

      # At a terminal, the wait's `==>` is dim.
      assert String.ends_with?(
               stderr,
               "Approve promotion #{@promotion}? EHOS then deploys the candidate to production. " <>
                 "[y/N] \e[2m==>\e[0m Waiting until the deployment is active, for at most 10 " <>
                 "minutes\n\e[2m==>\e[0m State of the deployment: active\n"
             )

      assert json_requests(provider, "POST " <> @approve) == [json_request(@approve, %{})]
    end

    test "--yes --json prints one document, shaped as deploy --json gives a deployment",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, review())
      api(provider, "POST", @approve, 200, approved("pending"))
      history(provider, "active")

      {0, json, ""} = ehosctl(["approve", @promotion, "--yes", "--json"], opts)

      assert JSON.decode!(json) == %{
               "review" => review(),
               "promotion" => promotion("approved"),
               "deployment" => @deployment,
               "state" => "active",
               "failure" => nil,
               "outcome" => "active",
               "addresses" => ["https://ledger.example.com"]
             }
    end

    test "--no-wait returns once EHOS decides the deployment", %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, review())
      api(provider, "POST", @approve, 200, approved("pending"))

      {0, stdout, ""} = ehosctl(["approve", @promotion, "--yes", "--no-wait"], opts)

      assert String.ends_with?(
               stdout,
               "\nYou approved promotion #{@promotion}. EHOS decided deployment " <>
                 "#{@deployment} of ledger in production: it is pending.\n"
             )

      assert FakeProvider.requests(provider, "GET " <> @deployments) == []
    end

    test "says a failure of the production deployment, with exit 1",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, review())
      api(provider, "POST", @approve, 200, approved("pending"))
      history(provider, "failed", "Back-off pulling image")

      {1, _stdout, stderr} = ehosctl(["approve", @promotion, "--yes"], opts)

      assert stderr ==
               "==> Waiting until the deployment is active, for at most 10 minutes\n" <>
                 "==> State of the deployment: failed\n" <>
                 "ehosctl: Deployment #{@deployment} failed in production: Back-off pulling image.\n"
    end

    test "ends 0 when the approver may not read the deployments in production",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, review())
      api(provider, "POST", @approve, 200, approved("pending"))

      api(provider, "GET", @deployments, 403, %{
        "error" => "forbidden",
        "message" => "You may not read the deployments of ledger in production."
      })

      {0, stdout, "==> Waiting until the deployment is active, for at most 10 minutes\n"} =
        ehosctl(["approve", @promotion, "--yes"], opts)

      assert String.ends_with?(
               stdout,
               "ehosctl cannot follow the deployment in production: reading its deployments " <>
                 "needs ehos.application.deploy or ehos.application.register there. Open the " <>
                 "page of ledger in the console to see if it became active.\n"
             )

      {0, json, ""} = ehosctl(["approve", @promotion, "--yes", "--json"], opts)

      assert JSON.decode!(json) == %{
               "review" => review(),
               "promotion" => promotion("approved"),
               "deployment" => @deployment,
               "state" => "pending",
               "failure" => nil,
               "outcome" => "not_followed"
             }
    end

    test "approves nothing without a yes, or where nobody can answer",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, review())
      mock_terminal_answer("n\n")

      {2, _stdout, stderr} = ehosctl(["approve", @promotion], opts)
      assert stderr =~ "[y/N] \e[31mehosctl:\e[0m You did not confirm, so nothing was approved.\n"

      stub(Ehosctl.TerminalMock, :input_terminal?, fn -> false end)
      stub(Ehosctl.TerminalMock, :error_terminal?, fn -> false end)

      assert {2, _stdout,
              "ehosctl: Nothing was approved: ehosctl asks before it approves a promotion, and " <>
                "nobody can answer here. Answer on a terminal, or give --yes.\n"} =
               ehosctl(["approve", @promotion], opts)

      {2, "", stderr} = ehosctl(["approve", @promotion, "--json"], opts)

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "invalid",
                 "message" =>
                   "Give --yes with --json: ehosctl does not ask a question when it prints JSON."
               }
             }

      assert json_requests(provider, "POST " <> @approve) == []
    end

    test "sends nothing when the review says it cannot be approved",
         %{provider: provider, opts: opts} do
      for {changes, code, said} <- [
            {%{"approvable" => false, "changed" => true}, 1,
             "ehosctl: You cannot approve promotion #{@promotion} now. Its review says why. " <>
               "ehosctl sent nothing.\n"},
            {%{"approvable" => false, "may_approve" => false}, 3,
             "ehosctl: You cannot approve promotions of ledger in production. Approving needs " <>
               "ehos.release.approve there. ehosctl sent nothing.\n"},
            {%{
               "approvable" => false,
               "promotion" => %{review()["promotion"] | "state" => "refused"}
             }, 1,
             "ehosctl: Promotion #{@promotion} is refused, so nobody can approve it. ehosctl " <>
               "sent nothing.\n"}
          ] do
        api(provider, "GET", @review_path, 200, Map.merge(review(), changes))

        {^code, stdout, ^said} = ehosctl(["approve", @promotion, "--yes"], opts)
        assert stdout =~ "Promote sha256:a1a1a1a1a1a1"
      end

      assert json_requests(provider, "POST " <> @approve) == []
    end

    test "says what to do after EHOS refuses the approval", %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, review())

      for {code, sentence, more} <- [
            {"changed", "The version in force in production changed.",
             " Ask for the promotion again with `ehosctl promote`. That withdraws this one."},
            {"self_approval", "Four eyes holds.",
             " Four eyes is on, so another person must approve it."},
            {"candidate_gone", "The candidate is no longer active.",
             " EHOS withdrew the promotion. Deploy the version to an ephemeral environment " <>
               "again, and ask for a new promotion."},
            {"readers_not_held", "It breaks readers you may not approve for.",
             " Only a person who can approve the promotions of each application that it breaks " <>
               "can approve it."}
          ] do
        api(provider, "POST", @approve, 409, %{"error" => code, "message" => sentence})

        {1, _stdout, stderr} = ehosctl(["approve", @promotion, "--yes"], opts)
        assert stderr == "ehosctl: " <> sentence <> more <> "\n"
      end
    end

    test "leaves out the command to see whether EHOS approved when the id holds a character a terminal acts on",
         %{provider: provider, opts: opts} do
      path = Ehosctl.PromotionReview.path(@odd)
      api(provider, "GET", path, 200, put_in(review(), ["promotion", "id"], @odd))
      api(provider, "POST", path <> "/approve", 500, %{"message" => "Internal error."})

      {code, _review, stderr} = ehosctl(["approve", @odd, "--yes"], opts)

      assert {code, stderr} ==
               {5,
                "ehosctl: Internal error. EHOS possibly made the change.\nWhat to do:\n  See whether it did before you run the command again.\n"}
    end

    test "prints the applications that a utility service's promotion agrees for, before it asks",
         %{provider: provider, opts: opts} do
      service =
        review()
        |> Map.merge(%{
          "callers" => %{
            "adds" => ["api.office.example:443"],
            "named" => ["office"],
            "held" => true,
            "changed" => false
          },
          "services_hosts" => []
        })
        |> put_in(["promotion", "application"], "invoice-pdf")
        |> put_in(["diff", "egress_added"], ["api.office.example:443"])

      api(provider, "GET", @review_path, 200, service)
      mock_terminal_answer("n\n")

      {2, stdout, stderr} = ehosctl(["approve", @promotion], opts)

      # The applications and their hosts come before the record, and the question after it.
      [_notices, callers] = String.split(stdout, "\n\nThis promotion adds hosts", parts: 2)

      assert String.starts_with?(
               callers,
               """
                outside the installation. If you approve, you also agree for each application that calls invoice-pdf in production. What these applications send invoice-pdf can then reach the hosts below.
               Applications:
                 - office
               Hosts that each application then reaches:
                 - api.office.example:443

               Promotion #{@promotion}
               """
             )

      assert stdout =~ "    hosts outside the installation added: api.office.example:443\n"
      assert stderr =~ "Approve promotion #{@promotion}?"
      assert stderr =~ "You did not confirm, so nothing was approved.\n"
      assert json_requests(provider, "POST " <> @approve) == []
    end

    test "prints a refusal of a utility service's promotion as EHOS says it",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @review_path, 200, review())

      for {code, sentence, more} <- [
            {"callers_changed",
             "Since the promotion was requested, the utility service has a caller or a host to " <>
               "add that the request did not name; ask for the promotion again.",
             " Ask for the promotion again with `ehosctl promote`. If another person asked for " <>
               "it, give --replace with its id."},
            {"callers_not_held",
             "The promotion adds a host that the utility service's callers reach through it, " <>
               "and only someone who holds ehos.release.approve there for each of them may " <>
               "approve it.",
             " Only a person who can approve the promotions of each application that calls the " <>
               "utility service can approve it."}
          ] do
        api(provider, "POST", @approve, 409, %{"error" => code, "message" => sentence})

        {1, _stdout, stderr} = ehosctl(["approve", @promotion, "--yes"], opts)
        assert stderr == "ehosctl: " <> sentence <> more <> "\n"

        {1, "", json} = ehosctl(["approve", @promotion, "--yes", "--json"], opts)

        assert JSON.decode!(json) == %{
                 "error" => %{"kind" => "failed", "code" => code, "message" => sentence <> more}
               }
      end
    end
  end

  describe "refuse" do
    test "refuses the promotion with the reason", %{provider: provider, opts: opts} do
      refused = Map.merge(promotion("refused"), %{"reason" => "Not before the audit"})
      api(provider, "POST", @refuse, 200, %{"promotion" => refused})

      assert ehosctl(
               ["refuse", String.upcase(@promotion), "--reason", "Not before the audit"],
               opts
             ) ==
               {0, "Promotion #{@promotion} is refused. Production did not change.\n", ""}

      assert json_requests(provider, "POST " <> @refuse) == [
               json_request(@refuse, %{"reason" => "Not before the audit"})
             ]

      {0, json, ""} = ehosctl(["refuse", @promotion, "--reason", "Not yet", "--json"], opts)
      assert JSON.decode!(json) == %{"promotion" => refused}
    end

    test "leaves out the command to see whether EHOS refused when the id holds a character a terminal acts on",
         %{provider: provider, opts: opts} do
      path = Ehosctl.PromotionReview.path(@odd) <> "/refuse"
      api(provider, "POST", path, 500, %{"message" => "Internal error."})

      assert ehosctl(["refuse", @odd, "--reason", "Not yet"], opts) ==
               {5, "",
                "ehosctl: Internal error. EHOS possibly made the change.\nWhat to do:\n  See whether it did before you run the command again.\n"}
    end

    test "refuses a reason EHOS would refuse, before anything is sent",
         %{provider: provider, opts: opts} do
      for reason <- ["", String.duplicate("é", 1025)] do
        assert ehosctl(["refuse", @promotion, "--reason", reason], opts) ==
                 {2, "", "ehosctl: --reason takes 1 to 1024 characters.\n"}
      end

      assert ehosctl(["refuse", "..", "--reason", "Not yet"], opts) ==
               {2, "", "ehosctl: .. is not the id of a promotion.\n"}

      assert json_requests(provider, "POST " <> @refuse) == []
    end

    test "prints EHOS's refusal with its exit code", %{provider: provider, opts: opts} do
      api(provider, "POST", @refuse, 403, %{
        "error" => "forbidden",
        "message" => "Refusing needs ehos.release.approve there."
      })

      assert ehosctl(["refuse", @promotion, "--reason", "Not yet"], opts) ==
               {3, "", "ehosctl: Refusing needs ehos.release.approve there.\n"}
    end
  end

  defp review do
    %{
      "promotion" =>
        Map.merge(promotion("requested"), %{
          "application" => "ledger",
          "environment" => "production",
          "candidate_environment" => "ledger-try"
        }),
      "there" => true,
      "four_eyes" => false,
      "self" => false,
      "may_approve" => true,
      "may_withdraw" => false,
      "approvable" => true,
      "in_force" => nil,
      "changed" => false,
      "authority" => "changed",
      "register" => %{"needed" => false, "held" => true},
      "refusals" => [],
      "requester_can_deploy" => true,
      "candidate_active" => true,
      "addresses" => ["https://ledger-try.example.com"],
      "diff" => %{
        "capabilities_added" => [],
        "capabilities_removed" => [],
        "roles_added" => [],
        "roles_removed" => [],
        "roles_grown" => %{},
        "roles_shrunk" => %{},
        "grants_widened" => %{},
        "grants_narrowed" => %{},
        "egress_added" => [],
        "egress_removed" => []
      },
      "described" => %{
        "roles_added" => [],
        "redescribed" => [],
        "grants_changed" => [],
        "grantable_grown" => []
      }
    }
  end

  defp promotion(state),
    do: %{
      "id" => @promotion,
      "state" => state,
      "candidate_id" => @candidate,
      "image" => @image,
      "image_digest" => @digest,
      "manifest_digest" => @manifest,
      "authority_digest" => @manifest,
      "in_force_digest" => nil,
      "reason" => nil,
      "break_reason" => nil,
      "four_eyes" => false,
      "self_approved" => false,
      "deployment_id" => nil,
      "decided_at" => nil,
      "inserted_at" => "2026-11-12T08:00:00Z"
    }

  defp approved(state),
    do: %{
      "promotion" => promotion("approved"),
      "deployment" => %{"id" => @deployment, "state" => state, "failure" => nil}
    }

  # The deployments in production, read while `approve` waits, with the one it decided in force.
  defp history(provider, state, failure \\ nil) do
    api(provider, "GET", @deployments, 200, %{
      "application" => "ledger",
      "environment" => "production",
      "in_force" => %{
        "kind" => "deployment",
        "id" => @deployment,
        "state" => state,
        "image" => @image,
        "manifest_digest" => @manifest,
        "failure" => failure,
        "by" => "ada@example.com",
        "at" => "2026-11-12T09:00:00Z"
      },
      "addresses" => ["https://ledger.example.com"],
      "before" => []
    })
  end

  defp mock_terminal_answer(answer) do
    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :gets, fn "" -> answer end)
  end
end

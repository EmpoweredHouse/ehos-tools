defmodule Ehosctl.PromoteTest do
  # `ehosctl promote` (#246, eh-os D-105): ask for the promotion of a candidate to production, and
  # withdraw one that waits, as the console's promotions page does.
  use Ehosctl.SignInCase

  @digest "sha256:" <> String.duplicate("a1", 32)
  @image "ghcr.io/example/ledger@" <> @digest
  @candidate "1f0c2b3a-0000-4000-8000-000000000001"
  @promotion "4c7a6b5e-0000-4000-8000-000000000004"
  @waiting "5d8b7c6f-0000-4000-8000-000000000005"
  @path "/api/v1/applications/ledger/promotions"
  @withdraw "/api/v1/promotions/#{@promotion}/withdraw"
  # A value with what a shell expands, a quote that ends a word, and a character a terminal acts on.
  @odd "x$(id)'\e"

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "promote APPLICATION --candidate --env" do
    test "asks for the promotion, and says how to read its review",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 201, %{"promotion" => promotion("requested")})

      {0, stdout, ""} =
        ehosctl(
          ["promote", "ledger", "--candidate", String.upcase(@candidate), "--env", "production"],
          opts
        )

      assert stdout == """
             You asked for the promotion of candidate #{@candidate} to production: promotion #{@promotion} is requested.
             A person who can approve promotions in production approves or refuses it. Run `ehosctl promotions show #{@promotion}` to read its review.
             """

      assert json_requests(provider, "POST " <> @path) == [
               json_request(@path, %{"candidate" => @candidate, "environment" => "production"})
             ]
    end

    test "leaves out the command to read the review when EHOS names the promotion with a character a terminal acts on",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 201, %{
        "promotion" => %{promotion("requested") | "id" => @odd}
      })

      assert ehosctl(promote(), opts) ==
               {0,
                ~S|You asked for the promotion of candidate 1f0c2b3a-0000-4000-8000-000000000001 to production: promotion "x$(id)'\e" is requested.| <>
                  "\nA person who can approve promotions in production approves or refuses it.\n",
                ""}
    end

    test "sends --replace and --break only when they are given, and --json keeps the promotion",
         %{provider: provider, opts: opts} do
      api(
        provider,
        "POST",
        @path,
        201,
        %{"promotion" => Map.put(promotion("requested"), "later", "unread")}
      )

      {0, json, ""} =
        ehosctl(
          promote(["--replace", @waiting, "--break", "billing moves to v2", "--json"]),
          opts
        )

      assert JSON.decode!(json) == %{"promotion" => promotion("requested")}

      assert json_requests(provider, "POST " <> @path) == [
               json_request(@path, %{
                 "candidate" => @candidate,
                 "environment" => "production",
                 "replace" => @waiting,
                 "break" => "billing moves to v2"
               })
             ]
    end

    test "names the request that waits, and how to read and replace it",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 409, %{
        "error" => "already_requested",
        "message" => "Another person's request for a promotion waits there.",
        "waiting" => @waiting
      })

      assert ehosctl(promote(), opts) ==
               {1, "",
                "ehosctl: Another person's request for a promotion waits there.\n" <>
                  "Promotion #{@waiting} waits there. Run `ehosctl promotions show #{@waiting}` " <>
                  "to read it. To withdraw it and ask for yours, run the command again with " <>
                  "--replace #{@waiting}.\n"}

      {1, "", stderr} = ehosctl(promote(["--json"]), opts)

      assert %{"error" => %{"code" => "already_requested", "waiting" => @waiting}} =
               JSON.decode!(stderr)
    end

    test "leaves out the commands to read and replace the request that waits when EHOS names it with a character a terminal acts on",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 409, %{
        "error" => "already_requested",
        "message" => "Another person's request for a promotion waits there.",
        "waiting" => @odd
      })

      assert ehosctl(promote(), opts) ==
               {1, "",
                "ehosctl: Another person's request for a promotion waits there.\n" <>
                  ~S|Promotion "x$(id)'\e" waits there.| <> "\n"}
    end

    test "says how to break readers on purpose, and --json keeps the refusals",
         %{provider: provider, opts: opts} do
      refusals = ["publishes: ledger.entries, which billing subscribes to"]

      api(provider, "POST", @path, 409, %{
        "error" => "would_be_refused",
        "message" =>
          "Production's deployment would be refused: publishes: ledger.entries, which billing " <>
            "subscribes to.",
        "refusals" => refusals
      })

      {1, "", stderr} = ehosctl(promote(), opts)

      assert stderr ==
               "ehosctl: Production's deployment would be refused: publishes: ledger.entries, " <>
                 "which billing subscribes to.\nTo break the applications that read those " <>
                 "names on purpose, run the command again with --break and your reason. A " <>
                 "person who can approve the promotions of each of them must approve it.\n"

      {1, "", stderr} = ehosctl(promote(["--json"]), opts)

      assert %{"error" => %{"code" => "would_be_refused", "refusals" => ^refusals}} =
               JSON.decode!(stderr)
    end

    test "says where to see the candidates", %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 409, %{
        "error" => "not_a_candidate",
        "message" => "The deployment is not a candidate."
      })

      assert ehosctl(promote(), opts) ==
               {1, "",
                "ehosctl: The deployment is not a candidate. Run `ehosctl promotions ledger` to " <>
                  "see the candidates of the application and its production environments.\n"}
    end

    test "leaves out the command to see the candidates when the application's name holds a character a terminal acts on",
         %{provider: provider, opts: opts} do
      path = "/api/v1/applications/#{Ehosctl.Api.segment(@odd)}/promotions"

      api(provider, "POST", path, 409, %{
        "error" => "not_a_candidate",
        "message" => "The deployment is not a candidate."
      })

      assert ehosctl(["promote", @odd, "--candidate", @candidate, "--env", "production"], opts) ==
               {1, "", "ehosctl: The deployment is not a candidate.\n"}
    end

    test "leaves out the command to see whether EHOS made the change when the application's name holds a character a terminal acts on",
         %{provider: provider, opts: opts} do
      path = "/api/v1/applications/#{Ehosctl.Api.segment(@odd)}/promotions"
      api(provider, "POST", path, 500, %{"message" => "Internal error."})

      assert ehosctl(["promote", @odd, "--candidate", @candidate, "--env", "production"], opts) ==
               {5, "",
                "ehosctl: Internal error. EHOS possibly made the change. See whether it did before you run the command again.\n"}
    end

    test "quotes for a shell the application's name in the commands it offers",
         %{provider: provider, opts: opts} do
      path = "/api/v1/applications/#{Ehosctl.Api.segment("x$(id)'y")}/promotions"
      api(provider, "POST", path, 500, %{"message" => "Internal error."})
      promote = ["promote", "x$(id)'y", "--candidate", @candidate, "--env", "production"]

      assert ehosctl(promote, opts) ==
               {5, "",
                "ehosctl: Internal error. EHOS possibly made the change.\nWhat to do:\n" <>
                  "  See whether it did before you run the command again:\n" <>
                  "  ehosctl promotions 'x$(id)'\\''y' --installation local\n"}

      api(provider, "POST", path, 409, %{
        "error" => "not_a_candidate",
        "message" => "The deployment is not a candidate."
      })

      assert ehosctl(promote, opts) ==
               {1, "",
                "ehosctl: The deployment is not a candidate. Run `ehosctl promotions " <>
                  "'x$(id)'\\''y'` to see the candidates of the application and its production " <>
                  "environments.\n"}
    end

    test "prints a refusal of the caller's capability with its exit code",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 403, %{
        "error" => "forbidden",
        "message" => "Requesting needs ehos.application.deploy in that production environment."
      })

      assert ehosctl(promote(), opts) ==
               {3, "",
                "ehosctl: Requesting needs ehos.application.deploy in that production " <>
                  "environment.\n"}
    end

    test "refuses, before anything is sent, what EHOS would refuse as invalid",
         %{provider: provider, opts: opts} do
      asked =
        "ehosctl: Name the application, the candidate with --candidate and the production " <>
          "environment with --env. To withdraw a promotion, give --withdraw PROMOTION.\n"

      assert ehosctl(["promote", "ledger", "--env", "production"], opts) == {2, "", asked}
      assert ehosctl(["promote"], opts) == {2, "", asked}

      assert ehosctl(promote(["--replace", "nope"]), opts) ==
               {2, "",
                "ehosctl: --replace takes the id of a promotion, such as " <>
                  "4c7a6b5e-0000-4000-8000-000000000004. `ehosctl promotions APPLICATION` lists " <>
                  "them.\n"}

      too_long = String.duplicate("é", 1025)

      for reason <- ["", too_long] do
        assert ehosctl(promote(["--break", reason]), opts) ==
                 {2, "", "ehosctl: --break takes a reason of 1 to 1024 characters.\n"}
      end

      assert ehosctl(["promote", "..", "--candidate", @candidate, "--env", "production"], opts) ==
               {2, "", "ehosctl: .. is not the name of an application.\n"}

      assert json_requests(provider, "POST " <> @path) == []
    end
  end

  describe "promote --withdraw" do
    test "withdraws the promotion", %{provider: provider, opts: opts} do
      api(provider, "POST", @withdraw, 200, %{"promotion" => promotion("withdrawn")})

      assert ehosctl(["promote", "--withdraw", String.upcase(@promotion)], opts) ==
               {0, "Promotion #{@promotion} is withdrawn. Production did not change.\n", ""}

      assert json_requests(provider, "POST " <> @withdraw) == [json_request(@withdraw, %{})]

      {0, json, ""} = ehosctl(["promote", "--withdraw", @promotion, "--json"], opts)
      assert JSON.decode!(json) == %{"promotion" => promotion("withdrawn")}
    end

    test "prints EHOS's refusal of a promotion already decided", %{provider: provider, opts: opts} do
      api(provider, "POST", @withdraw, 409, %{
        "error" => "not_requested",
        "message" => "The promotion was already decided."
      })

      assert ehosctl(["promote", "--withdraw", @promotion], opts) ==
               {1, "", "ehosctl: The promotion was already decided.\n"}
    end

    test "refuses another flag beside it, and an id that is not a promotion's",
         %{provider: provider, opts: opts} do
      alone =
        "ehosctl: --withdraw takes the id of the promotion alone. Do not give an application, " <>
          "--candidate, --env, --replace or --break with it.\n"

      assert ehosctl(["promote", "ledger", "--withdraw", @promotion], opts) == {2, "", alone}

      assert ehosctl(["promote", "--withdraw", @promotion, "--env", "production"], opts) ==
               {2, "", alone}

      assert {2, "", "ehosctl: --withdraw takes the id of a promotion" <> _} =
               ehosctl(["promote", "--withdraw", ".."], opts)

      assert json_requests(provider, "POST " <> @withdraw) == []
    end
  end

  defp promote(extra \\ []),
    do: ["promote", "ledger", "--candidate", @candidate, "--env", "production" | extra]

  defp promotion(state),
    do: %{
      "id" => @promotion,
      "state" => state,
      "candidate_id" => @candidate,
      "image" => @image,
      "image_digest" => @digest,
      "manifest_digest" => "sha256:" <> String.duplicate("b2", 32),
      "authority_digest" => "sha256:" <> String.duplicate("b2", 32),
      "in_force_digest" => nil,
      "reason" => nil,
      "break_reason" => nil,
      "four_eyes" => true,
      "self_approved" => false,
      "deployment_id" => nil,
      "decided_at" => nil,
      "inserted_at" => "2026-11-12T08:00:00Z"
    }
end

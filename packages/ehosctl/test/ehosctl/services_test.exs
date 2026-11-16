defmodule Ehosctl.ServicesTest do
  # `ehosctl services list | agree | withdraw` (ehos-tools#923, eh-os D-175): service agreements on
  # EHOS's agreements API (eh-os `docs/agreements-api.md`, "Service agreements").
  use Ehosctl.SignInCase

  @list "/api/v1/applications/:name/environments/:environment/services"
  @caller "/api/v1/applications/:name/environments/:environment/callers/:caller"

  @agreed %{
    "service" => "invoice-pdf",
    "application" => "office",
    "asks" => true,
    "deployed" => true,
    "agreed" => true,
    "holds" => true,
    "agreed_at" => "2026-11-14T09:02:09.123456Z",
    "by" => "ada@example.com",
    "variable" => "EHOS_SERVICE_INVOICE_PDF_URL",
    "hosts" => ["api.office.example:443", "files.office.example:443"],
    "application_side" => "agreed",
    "application_by" => "grace@example.com"
  }
  @asks %{
    @agreed
    | "application" => "shop",
      "agreed" => false,
      "holds" => false,
      "agreed_at" => nil,
      "by" => nil,
      "application_side" => "waiting",
      "application_by" => nil
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp listed(name, kind, requests),
    do: %{
      "application" => name,
      "kind" => kind,
      "environment" => "production",
      "requests" => requests
    }

  describe "services list" do
    test "lists a utility service's callers, in the tab's words", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", @list, 200, listed("invoice-pdf", "service", [@agreed, @asks]))

      assert {0, stdout, ""} =
               ehosctl(["services", "list", "invoice-pdf", "--env", "production"], opts)

      assert stdout =~ ~r/APPLICATION +SERVICE AGREEMENT +AGREED +BY +HOSTS +APPLICATION'S SIDE/

      assert stdout =~
               ~r/office +agreed +14 November 2026, 09:02 UTC +ada@example.com +api.office.example:443, files.office.example:443 +agreed by grace@example.com/

      assert stdout =~ ~r/shop +asks, not agreed +api.office.example:443, .* +waits/
      refute stdout =~ "EHOS_SERVICE_INVOICE_PDF_URL"

      path = "/api/v1/applications/invoice-pdf/environments/production/services"
      assert requests(provider, "GET " <> path) == [request(path)]
    end

    test "lists an application's utility services, with the variable of each address",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @list, 200, listed("office", "application", [@agreed]))

      assert {0, stdout, ""} =
               ehosctl(["services", "list", "office", "--env", "production"], opts)

      assert stdout =~
               ~r/SERVICE +SERVICE AGREEMENT +AGREED +BY +HOSTS +APPLICATION'S SIDE +ADDRESS IN/

      assert stdout =~
               ~r/invoice-pdf +agreed .* agreed by grace@example.com +EHOS_SERVICE_INVOICE_PDF_URL/
    end

    test "says when a service agreement waits for the application's side, and when none is needed",
         %{provider: provider, opts: opts} do
      waits = %{
        @agreed
        | "holds" => false,
          "application_side" => "waiting",
          "application_by" => nil
      }

      no_hosts = %{
        @agreed
        | "service" => "pdf-render",
          "hosts" => [],
          "application_side" => "not_needed",
          "application_by" => nil
      }

      api(provider, "GET", @list, 200, listed("office", "application", [waits, no_hosts]))

      assert {0, stdout, ""} =
               ehosctl(["services", "list", "office", "--env", "production"], opts)

      assert stdout =~
               ~r/invoice-pdf +agreed, waits for the application's side .* api.office.example:443, files.office.example:443 +waits +EHOS_/

      assert stdout =~ ~r/pdf-render +agreed .* none +not needed +EHOS_/
    end

    test "reads an EHOS that names no hosts as a service with none",
         %{provider: provider, opts: opts} do
      before = Map.drop(@agreed, ~w(hosts application_side application_by))
      api(provider, "GET", @list, 200, listed("office", "application", [before]))

      assert {0, stdout, ""} =
               ehosctl(["services", "list", "office", "--env", "production"], opts)

      assert stdout =~ ~r/invoice-pdf +agreed .* none +not needed +EHOS_/

      {0, json, ""} =
        ehosctl(["services", "list", "office", "--env", "production", "--json"], opts)

      assert JSON.decode!(json) == listed("office", "application", [before])
    end

    test "says what an empty list means, from either side", %{provider: provider, opts: opts} do
      api(provider, "GET", @list, 200, listed("invoice-pdf", "service", []))

      assert ehosctl(["services", "list", "invoice-pdf", "--env", "production"], opts) ==
               {0,
                "No callers of invoice-pdf in production. An application shows here when its " <>
                  "deployment there asks to call invoice-pdf.\n", ""}

      api(provider, "GET", @list, 200, listed("office", "application", []))

      assert ehosctl(["services", "list", "office", "--env", "production"], opts) ==
               {0,
                "No utility services for office in production. A utility service shows here " <>
                  "when the deployment of office there asks to call it.\n", ""}
    end

    test "--json prints the fields the API holds, and no other", %{provider: provider, opts: opts} do
      body = listed("invoice-pdf", "service", [Map.put(@agreed, "secret", "x")])
      api(provider, "GET", @list, 200, body)

      {0, stdout, ""} =
        ehosctl(["services", "list", "invoice-pdf", "--env", "production", "--json"], opts)

      assert JSON.decode!(stdout) == listed("invoice-pdf", "service", [@agreed])
    end

    test "an answer for another application, or one it cannot read, is refused",
         %{provider: provider, opts: opts} do
      for body <- [
            listed("other", "service", []),
            listed("invoice-pdf", "job", []),
            listed("invoice-pdf", "service", [Map.delete(@agreed, "holds")]),
            listed("invoice-pdf", "service", [%{@agreed | "service" => "other"}]),
            listed("invoice-pdf", "application", [%{@agreed | "service" => "invoice-pdf"}]),
            listed("invoice-pdf", "service", [%{@agreed | "hosts" => "api.office.example:443"}]),
            listed("invoice-pdf", "service", [%{@agreed | "hosts" => [""]}]),
            listed("invoice-pdf", "service", [%{@agreed | "application_side" => "maybe"}]),
            listed("invoice-pdf", "service", [%{@agreed | "application_by" => 7}]),
            %{}
          ] do
        api(provider, "GET", @list, 200, body)

        assert ehosctl(["services", "list", "invoice-pdf", "--env", "production"], opts) ==
                 cannot_read(provider),
               inspect(body)
      end
    end

    test "a refusal is printed in EHOS's words", %{provider: provider, opts: opts} do
      sentence =
        "Reading the service agreements of invoice-pdf in production needs " <>
          "ehos.application.deploy or ehos.application.register for it there."

      api(provider, "GET", @list, 403, %{"error" => "forbidden", "message" => sentence})

      assert ehosctl(["services", "list", "invoice-pdf", "--env", "production"], opts) ==
               {3, "", "ehosctl: #{sentence}\n"}
    end
  end

  describe "services agree and withdraw" do
    test "agree sends POST, and says what EHOS does now", %{provider: provider, opts: opts} do
      agreed = %{
        "service" => "invoice-pdf",
        "application" => "office",
        "environment" => "production",
        "agreed" => true
      }

      api(provider, "POST", @caller, 200, agreed)
      args = ["services", "agree", "invoice-pdf", "office", "--env", "production"]

      assert ehosctl(args, opts) ==
               {0,
                "Agreed: office can call invoice-pdf in production. EHOS starts the pods of " <>
                  "office again with the address of invoice-pdf.\n", ""}

      {0, stdout, ""} = ehosctl(args ++ ["--json"], opts)
      assert JSON.decode!(stdout) == agreed

      path = "/api/v1/applications/invoice-pdf/environments/production/callers/office"
      assert requests(provider, "POST " <> path) == [post(path), post(path)]
    end

    test "withdraw sends DELETE, and says no new connection opens",
         %{provider: provider, opts: opts} do
      api(provider, "DELETE", @caller, 200, %{
        "service" => "invoice-pdf",
        "application" => "office",
        "environment" => "production",
        "agreed" => false
      })

      assert ehosctl(
               ["services", "withdraw", "invoice-pdf", "office", "--env", "production"],
               opts
             ) ==
               {0,
                "Withdrew the service agreement: office cannot open a new connection to " <>
                  "invoice-pdf in production. EHOS starts the pods of office again without the " <>
                  "address.\n", ""}
    end

    test "each refusal is printed in EHOS's words, with its kind's exit code",
         %{provider: provider, opts: opts} do
      agree = ["agree", "invoice-pdf", "office", "--env", "production"]
      withdraw = ["withdraw", "invoice-pdf", "office", "--env", "production"]

      cases = [
        {"POST", agree, 403, "forbidden",
         "You cannot change the service agreements of invoice-pdf in production. Ask a person " <>
           "who manages role bindings for a role that grants ehos.application.deploy for " <>
           "invoice-pdf there.", 3},
        {"POST", agree, 404, "not_found",
         "The utility service, the application, the environment or the service agreement does " <>
           "not exist.", 1},
        {"POST", agree, 409, "not_requested",
         "No deployment of office in production asks to call invoice-pdf. Deploy a version " <>
           "whose ehos.yaml names invoice-pdf in needs.services, then agree.", 1},
        {"POST", agree, 409, "too_many_callers",
         "invoice-pdf has 128 service agreements in production, the most that EHOS gives. " <>
           "Withdraw one that no application needs, then agree.", 1},
        {"DELETE", withdraw, 404, "not_found",
         "The utility service, the application, the environment or the service agreement does " <>
           "not exist.", 1}
      ]

      for {method, args, status, code, sentence, exit_code} <- cases do
        api(provider, method, @caller, status, %{"error" => code, "message" => sentence})

        assert ehosctl(["services" | args], opts) == {exit_code, "", "ehosctl: #{sentence}\n"},
               code
      end
    end

    test "an answer for another service agreement says to look", %{provider: provider, opts: opts} do
      api(provider, "POST", @caller, 200, %{
        "service" => "invoice-pdf",
        "application" => "shop",
        "environment" => "production",
        "agreed" => true
      })

      assert ehosctl(["services", "agree", "invoice-pdf", "office", "--env", "production"], opts) ==
               not_as_asked(provider, "services list invoice-pdf --env production")
    end

    test "a name that would leave its place in the path is refused, and nothing is sent",
         %{provider: provider, opts: opts} do
      assert ehosctl(["services", "agree", "..", "office", "--env", "production"], opts) ==
               names_nothing("..")

      assert ehosctl(["services", "list", "office", "--env", "."], opts) == names_nothing(".")

      assert requests(
               provider,
               "POST /api/v1/applications/../environments/production/callers/office"
             ) == []
    end
  end

  defp requests(provider, key), do: FakeProvider.requests(provider, key)

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

  defp names_nothing(name),
    do:
      {2, "",
       ~s(ehosctl: "#{name}" is not the name of an application or an environment. ) <>
         "Give the name of each application and of the environment.\n"}
end

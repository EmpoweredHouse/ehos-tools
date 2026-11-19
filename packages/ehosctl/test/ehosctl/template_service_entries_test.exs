defmodule Ehosctl.TemplateServiceEntriesTest do
  # `ehosctl env template service-entry …` (eh-os D-188, ehos-tools#1008), against EHOS's API as
  # eh-os's `EhosWeb.TemplateServiceEntryController` answers it. Not async, through
  # `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process shares.
  use Ehosctl.SignInCase

  @path "/api/v1/applications/office/templates/sandbox/service-entries"
  @side @path <> "/invoice-pdf/application"

  @entry %{
    "service" => "invoice-pdf",
    "source" => "production",
    "set_by" => "grace@example.com",
    "set_at" => "2026-11-19T10:00:00Z",
    "hosts" => ["api.office.example.org:443"],
    "application_side" => "waiting",
    "application_agreed_by" => nil,
    "application_agreed_at" => nil,
    "application_hosts" => []
  }
  @agreed %{
    @entry
    | "application_side" => "agreed",
      "application_agreed_by" => "ada@example.com",
      "application_agreed_at" => "2026-11-19T11:00:00Z",
      "application_hosts" => ["api.office.example.org:443"]
  }

  @look "env template service-entry list sandbox --app office"

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "env template service-entry list" do
    test "lists the entries, and --json prints them", %{provider: provider, opts: opts} do
      plain = %{
        @entry
        | "service" => "pdf-text",
          "hosts" => [],
          "application_side" => "not_needed"
      }

      api(provider, "GET", @path, 200, %{
        "application" => "office",
        "template" => "sandbox",
        "service_entries" => [@entry, plain]
      })

      args = ~w(env template service-entry list sandbox --app office)

      assert ehosctl(args, opts) ==
               {0,
                """
                 SERVICE      SOURCE      HOSTS                       APPLICATION'S SIDE  SET BY             SET AT
                 invoice-pdf  production  api.office.example.org:443  waiting             grace@example.com  19 November 2026, 10:00 UTC
                 pdf-text     production  none                        not needed          grace@example.com  19 November 2026, 10:00 UTC
                """, ""}

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)

      assert JSON.decode!(json) == %{
               "application" => "office",
               "template" => "sandbox",
               "service_entries" => [@entry, plain]
             }
    end

    test "says how to add one when there is none", %{provider: provider, opts: opts} do
      api(provider, "GET", @path, 200, %{
        "application" => "office",
        "template" => "sandbox",
        "service_entries" => []
      })

      assert ehosctl(~w(env template service-entry list sandbox --app office), opts) ==
               {0,
                "The environment template sandbox holds no service entries for office. Run " <>
                  "`ehosctl env template service-entry set sandbox SERVICE --app office " <>
                  "--source ENVIRONMENT` to add one.\n", ""}
    end

    test "takes no list of another application", %{provider: provider, opts: opts} do
      api(provider, "GET", @path, 200, %{
        "application" => "billing",
        "template" => "sandbox",
        "service_entries" => []
      })

      assert ehosctl(~w(env template service-entry list sandbox --app office), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end

    test "refuses a name that would leave its place in the path, sending nothing",
         %{provider: provider, opts: opts} do
      assert ehosctl(~w(env template service-entry list .. --app office), opts) ==
               {2, "",
                "ehosctl: .. is not the name of an application, an environment template or a " <>
                  "utility service.\n"}

      assert FakeProvider.requests(provider, "GET " <> @path) == []
    end
  end

  describe "env template service-entry set and remove" do
    test "sets an entry, and says the application's side must agree to its hosts",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 200, %{"service_entry" => @entry})

      args =
        ~w(env template service-entry set sandbox invoice-pdf --app office --source production)

      assert ehosctl(args, opts) ==
               {0,
                "Set the service entry invoice-pdf on the environment template sandbox for " <>
                  "office, copied from production. The service names hosts outside the " <>
                  "installation, so the entry copies nothing until a person who may approve " <>
                  "the releases of office runs `ehosctl env template service-entry agree " <>
                  "sandbox invoice-pdf --app office --host …`. An EHOS that copies services " <>
                  "copies it into the ephemeral environments of office that it makes from " <>
                  "sandbox.\n", ""}

      assert json_requests(provider, "POST " <> @path) == [
               json_request(@path, %{"service" => "invoice-pdf", "source" => "production"})
             ]

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)
      assert JSON.decode!(json) == %{"service_entry" => @entry}
    end

    test "prints EHOS's refusals of an entry in its words, with their kinds",
         %{provider: provider, opts: opts} do
      for {status, code, exit} <- [
            {422, "not_a_service", 2},
            {409, "not_production", 1},
            {404, "not_found", 1},
            {403, "forbidden", 3}
          ] do
        api(provider, "POST", @path, status, %{"error" => code, "message" => "EHOS: #{code}."})

        args =
          ~w(env template service-entry set sandbox invoice-pdf --app office --source production)

        assert {code, ehosctl(args, opts)} == {code, {exit, "", "ehosctl: EHOS: #{code}.\n"}}
      end
    end

    test "says an entry answered for another service did something",
         %{provider: provider, opts: opts} do
      api(provider, "POST", @path, 200, %{"service_entry" => %{@entry | "service" => "other"}})

      args =
        ~w(env template service-entry set sandbox invoice-pdf --app office --source production)

      assert ehosctl(args, opts) == not_as_asked(provider)
    end

    test "removes an entry", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @path <> "/invoice-pdf", 200, %{
        "application" => "office",
        "template" => "sandbox",
        "service" => "invoice-pdf"
      })

      assert ehosctl(~w(env template service-entry remove sandbox invoice-pdf --app office), opts) ==
               {0,
                "Removed the service entry invoice-pdf from the environment template sandbox " <>
                  "for office. A copy that EHOS made already stays until the next deployment of " <>
                  "office there.\n", ""}
    end
  end

  describe "env template service-entry agree and withdraw" do
    test "sends the hosts given, once each, and says what the copies may reach",
         %{provider: provider, opts: opts} do
      api(provider, "PUT", @side, 200, %{"service_entry" => @agreed})

      args =
        ~w(env template service-entry agree sandbox invoice-pdf --app office) ++
          ~w(--host api.office.example.org:443 --host api.office.example.org:443)

      assert ehosctl(args, opts) ==
               {0,
                "Agreed for office to the hosts of invoice-pdf on the environment template " <>
                  "sandbox: api.office.example.org:443. The copies in its ephemeral environments " <>
                  "can send data to these hosts.\n", ""}

      assert json_requests(provider, "PUT " <> @side) == [
               json_request(@side, %{"hosts" => ["api.office.example.org:443"]})
             ]
    end

    test "says where to read the hosts when they changed", %{provider: provider, opts: opts} do
      api(provider, "PUT", @side, 409, %{
        "error" => "hosts_changed",
        "message" => "The hosts sent are not the hosts the service names now in its source."
      })

      args =
        ~w(env template service-entry agree sandbox invoice-pdf --app office --host old.example:443)

      assert ehosctl(args, opts) ==
               {1, "",
                "ehosctl: The hosts sent are not the hosts the service names now in its source. " <>
                  "`ehosctl env template service-entry list sandbox --app office` lists them.\n"}
    end

    test "withdraws the application's side", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @side, 200, %{"service_entry" => @entry})

      assert ehosctl(
               ~w(env template service-entry withdraw sandbox invoice-pdf --app office),
               opts
             ) ==
               {0,
                "Withdrew the agreement of office to the hosts of invoice-pdf on the environment " <>
                  "template sandbox. The service names hosts outside the " <>
                  "installation, so the entry copies nothing until a person who may approve the " <>
                  "releases of office runs `ehosctl env template service-entry agree sandbox " <>
                  "invoice-pdf --app office --host …`.\n", ""}
    end

    test "takes no agreement EHOS says it did not give", %{provider: provider, opts: opts} do
      api(provider, "PUT", @side, 200, %{"service_entry" => @entry})

      args =
        ~w(env template service-entry agree sandbox invoice-pdf --app office) ++
          ~w(--host api.office.example.org:443)

      assert ehosctl(args, opts) == not_as_asked(provider)

      # Nor one agreed to other hosts than those sent.
      other = %{@agreed | "application_hosts" => ["other.example.org:443"]}
      api(provider, "PUT", @side, 200, %{"service_entry" => other})
      assert ehosctl(args, opts) == not_as_asked(provider)
    end
  end

  defp not_as_asked(provider),
    do:
      {1, "",
       "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. It answered " <>
         "that something was done, but not as what was asked.\nWhat to do:\n  See what was " <>
         "done:\n  ehosctl #{@look} --installation local\n"}
end

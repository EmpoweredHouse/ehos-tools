defmodule Ehosctl.DomainsTest do
  # `ehosctl domains` (eh-os D-155, ehos-tools#853): the domains of the company mapped to a
  # production application, from `/api/v1/domains`.
  use Ehosctl.SignInCase

  doctest Ehosctl.Domains

  @guide "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#make-the-dns-records-for-public-certificates"

  # A value with what a shell expands, a quote that ends a word, and a character a terminal acts on.
  @odd "x$(id)'\e"

  # A mapping as eh-os's `docs/installation-api.md` gives it.
  @waiting %{
    "name" => "ledger.client.example",
    "application" => "ledger",
    "environment" => "production",
    "entry" => "web",
    "state" => "waiting_for_dns",
    "mapped_by" => "admin@client.example",
    "mapped_at" => "2026-11-08T10:00:00.000000Z",
    "record" => %{
      "name" => "ledger.client.example",
      "type" => "CNAME",
      "value" => "edge.ehos.client.example."
    },
    "check" => %{
      "outcome" => "disagrees",
      "reason" => "other_target",
      "found" => ["old.example"],
      "error" => nil
    },
    "checked_at" => "2026-11-08T10:01:00.000000Z",
    "next_check_at" => "2026-11-08T10:03:00.000000Z",
    "named_by" => ["billing"]
  }

  @active %{
    @waiting
    | "name" => "shop.client.example",
      "application" => "shop",
      "state" => "active",
      "record" => %{@waiting["record"] | "name" => "shop.client.example"},
      "check" => %{"outcome" => "agrees", "reason" => nil, "found" => nil, "error" => nil},
      "next_check_at" => nil,
      "named_by" => []
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "domains" do
    test "lists the mapped domains, and exits 0 while each is active", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", "/api/v1/domains", 200, %{"domains" => [@active]})

      assert ehosctl(~w(domains), opts) ==
               {0,
                """
                 DOMAIN               APPLICATION  ENVIRONMENT  ENTRY  STATE
                 shop.client.example  shop         production   web    active
                """, ""}

      {0, json, ""} = ehosctl(~w(domains --json), opts)
      assert JSON.decode!(json) == %{"domains" => [@active]}
    end

    test "says what to do, and exits 1, while a domain is not active", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", "/api/v1/domains", 200, %{"domains" => [@waiting, @active]})

      assert ehosctl(~w(domains), opts) ==
               {1,
                """
                 DOMAIN                 APPLICATION  ENVIRONMENT  ENTRY  STATE
                 ledger.client.example  ledger       production   web    waiting for DNS
                 shop.client.example    shop         production   web    active
                A domain that is not active does not show its application yet. `ehosctl domains show ledger.client.example` says what to change, as does the console at #{provider.issuer}/domains/ledger.client.example.
                """, ""}

      {1, json, ""} = ehosctl(~w(domains --json), opts)
      assert JSON.decode!(json) == %{"domains" => [@waiting, @active]}
    end

    test "names a word to replace in capitals when several domains are not active", %{
      provider: provider,
      opts: opts
    } do
      other = %{@waiting | "name" => "books.client.example"}
      api(provider, "GET", "/api/v1/domains", 200, %{"domains" => [@waiting, other]})

      {1, stdout, ""} = ehosctl(~w(domains), opts)

      assert stdout |> String.split("\n") |> Enum.take(-2) == [
               "A domain that is not active does not show its application yet. `ehosctl " <>
                 "domains show DOMAIN` says what to change, as does the console at " <>
                 "#{provider.issuer}/domains/DOMAIN.",
               ""
             ]
    end

    test "says where to see what to change without the command when EHOS names the domain with a character a terminal acts on",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/domains", 200, %{
        "domains" => [%{@waiting | "name" => @odd}]
      })

      assert ehosctl(~w(domains), opts) ==
               {1,
                """
                 DOMAIN       APPLICATION  ENVIRONMENT  ENTRY  STATE
                 "x$(id)'\\e"  ledger       production   web    waiting for DNS
                A domain that is not active does not show its application yet. The console at #{provider.issuer}/domains/"x$(id)'\\e" says what to change.
                """, ""}
    end

    test "shows a state it does not know as EHOS gives it, and drops fields it does not know",
         %{provider: provider, opts: opts} do
      later = @active |> Map.put("state", "paused") |> Map.put("extra", "dropped")
      api(provider, "GET", "/api/v1/domains", 200, %{"domains" => [later]})

      {1, stdout, ""} = ehosctl(~w(domains), opts)
      assert stdout =~ "shop.client.example  shop         production   web    paused\n"

      {1, json, ""} = ehosctl(~w(domains --json), opts)
      assert JSON.decode!(json) == %{"domains" => [Map.put(@active, "state", "paused")]}
    end

    test "says how a domain gets here when none is mapped", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/domains", 200, %{"domains" => []})

      assert ehosctl(~w(domains), opts) ==
               {0,
                "No domain is mapped. A domain shows here when a person maps it with " <>
                  "`ehosctl domains map` or on the Domains page of the console.\n", ""}
    end

    test "says EHOS's refusal, and refuses an answer it cannot read", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", "/api/v1/domains", 403, %{
        "error" => "forbidden",
        "message" => "Managing domains needs ehos.domain.manage at the whole platform."
      })

      assert ehosctl(~w(domains), opts) ==
               {3, "",
                "ehosctl: Managing domains needs ehos.domain.manage at the whole platform.\n"}

      api(provider, "GET", "/api/v1/domains", 200, %{"domains" => [%{"name" => "x"}]})

      assert ehosctl(~w(domains), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end
  end

  describe "domains map" do
    test "maps a domain and prints the CNAME to make", %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/domains", 201, Map.put(@waiting, "check", nil))

      assert ehosctl(
               ~w(domains map ledger.client.example --app ledger --env production),
               opts
             ) ==
               {0,
                """
                Mapped ledger.client.example to ledger in production, entry web.

                Make this DNS record at the DNS provider of the domain:

                 NAME                   TYPE   VALUE
                 ledger.client.example  CNAME  edge.ehos.client.example.

                EHOS checks the record, then gets a certificate for the domain. `ehosctl domains show ledger.client.example` shows the state, as does the console at #{provider.issuer}/domains/ledger.client.example. The guide says how to make a record: #{@guide}
                """, ""}

      assert json_requests(provider, "POST /api/v1/domains") == [
               json_request("/api/v1/domains", %{
                 "domain" => "ledger.client.example",
                 "application" => "ledger",
                 "environment" => "production"
               })
             ]
    end

    test "says where to see the state without the command when EHOS names the domain with a character a terminal acts on",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/domains", 201, %{@waiting | "name" => @odd, "check" => nil})

      assert ehosctl(~w(domains map ledger.client.example --app ledger --env production), opts) ==
               {0,
                """
                Mapped "x$(id)'\\e" to ledger in production, entry web.

                Make this DNS record at the DNS provider of the domain:

                 NAME                   TYPE   VALUE
                 ledger.client.example  CNAME  edge.ehos.client.example.

                EHOS checks the record, then gets a certificate for the domain. The console at #{provider.issuer}/domains/"x$(id)'\\e" shows the state. The guide says how to make a record: #{@guide}
                """, ""}
    end

    test "names the entry when given, and gives the mapping under --json", %{
      provider: provider,
      opts: opts
    } do
      mapping = %{@waiting | "entry" => "api", "check" => nil}
      api(provider, "POST", "/api/v1/domains", 201, mapping)

      {0, json, ""} =
        ehosctl(
          ~w(domains map ledger.client.example --app ledger --env production --entry api --json),
          opts
        )

      assert JSON.decode!(json) == mapping

      assert [%{body: %{"entry" => "api"}}] =
               json_requests(provider, "POST /api/v1/domains")
    end

    test "says EHOS's refusal", %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/domains", 422, %{
        "error" => "public_suffix",
        "message" => "co.uk is a public suffix. Map a domain of your company."
      })

      assert ehosctl(~w(domains map co.uk --app ledger --env production), opts) ==
               {2, "", "ehosctl: co.uk is a public suffix. Map a domain of your company.\n"}
    end
  end

  describe "domains show" do
    test "shows the state, the record, the last check and what to change, and exits 1",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/domains/ledger.client.example", 200, @waiting)

      assert ehosctl(~w(domains show ledger.client.example), opts) ==
               {1,
                """
                ledger.client.example: waiting for DNS
                Shows ledger in production, entry web. Mapped by admin@client.example, 8 November 2026, 10:00 UTC.

                The DNS record at the DNS provider of the domain:

                 NAME                   TYPE   VALUE
                 ledger.client.example  CNAME  edge.ehos.client.example.

                Last check, 8 November 2026, 10:01 UTC: the name servers give a CNAME to old.example. Change it to the value of the record above. Next check: 8 November 2026, 10:03 UTC.

                Applications that name ledger in production: billing. They reach it at its own address, which does not answer while the entry web is mapped.

                The console at #{provider.issuer}/domains/ledger.client.example shows the same. The guide says how to make a record: #{@guide}
                """, ""}

      {1, json, ""} = ehosctl(~w(domains show ledger.client.example --json), opts)
      assert JSON.decode!(json) == @waiting
    end

    test "says each reason a check does not agree", %{provider: provider, opts: opts} do
      for {check, said} <- [
            {%{"reason" => "missing", "found" => []},
             "the name servers give no record at ledger.client.example. Make the record."},
            {%{"reason" => "not_cname", "found" => ["192.0.2.1"]},
             "the name servers give other records at ledger.client.example: 192.0.2.1. " <>
               "Remove them, and make the CNAME."},
            {%{"reason" => "edge_address", "found" => ["192.0.2.1"]},
             "edge.ehos.client.example has the address 192.0.2.1, which is not the address of " <>
               "the server. Remove the record of your own at edge.ehos.client.example: the " <>
               "records of the installation give its address."},
            {%{"reason" => "aaaa", "found" => ["2001:db8::1"]},
             "edge.ehos.client.example has an AAAA record, 2001:db8::1. Remove it: the server " <>
               "answers on IPv4 alone."},
            {%{"reason" => "apex", "found" => []},
             "ledger.client.example is the apex of a zone, which cannot hold a CNAME. Remove " <>
               "this mapping, and map a name under it."},
            # As eh-os's check gives it: no answer is an unknown outcome.
            {%{
               "outcome" => "unknown",
               "reason" => "no_answer",
               "found" => nil,
               "error" => "The name server ns1.dns.example gave no answer: timeout."
             },
             "no name server answered (The name server ns1.dns.example gave no answer: " <>
               "timeout.). EHOS asks again."},
            {%{"outcome" => "unknown", "reason" => "no_answer", "found" => nil, "error" => ""},
             "no name server answered (no reason given). EHOS asks again."},
            {%{"reason" => "later", "found" => ["x"]},
             "the record is not correct (later): the name servers give x."}
          ] do
        mapping = %{@waiting | "check" => Map.merge(@waiting["check"], check)}
        api(provider, "GET", "/api/v1/domains/ledger.client.example", 200, mapping)

        {1, stdout, ""} = ehosctl(~w(domains show ledger.client.example), opts)
        assert stdout =~ "Last check, 8 November 2026, 10:01 UTC: #{said}", said
      end
    end

    # A later EHOS may leave out a null field; `unknown` is not a wrong record.
    test "reads a check without a reason, and says when the check could not tell", %{
      provider: provider,
      opts: opts
    } do
      for {check, said} <- [
            {%{"outcome" => "unknown", "error" => "timeout"},
             "EHOS could not tell if the record is correct (timeout). EHOS asks again."},
            {%{"outcome" => "unknown"},
             "EHOS could not tell if the record is correct. EHOS asks again."},
            {%{"outcome" => "unknown", "error" => ""},
             "EHOS could not tell if the record is correct. EHOS asks again."},
            {%{"outcome" => "later"}, "the check gave later."},
            {%{"outcome" => "disagrees", "found" => ["x"]},
             "the record is not correct (no reason given): the name servers give x."}
          ] do
        api(provider, "GET", "/api/v1/domains/ledger.client.example", 200, %{
          @waiting
          | "check" => check
        })

        {1, stdout, ""} = ehosctl(~w(domains show ledger.client.example), opts)
        assert stdout =~ "Last check, 8 November 2026, 10:01 UTC: #{said}", said
      end
    end

    test "exits 0 for an active domain, and says when nothing was checked yet", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", "/api/v1/domains/shop.client.example", 200, @active)

      {0, stdout, ""} = ehosctl(~w(domains show shop.client.example), opts)
      assert stdout =~ "shop.client.example: active\n"
      assert stdout =~ "Last check, 8 November 2026, 10:01 UTC: the record is correct.\n"
      refute stdout =~ "The guide"

      api(provider, "GET", "/api/v1/domains/ledger.client.example", 200, %{
        @waiting
        | "check" => nil,
          "checked_at" => nil
      })

      {1, stdout, ""} = ehosctl(~w(domains show ledger.client.example), opts)

      assert stdout =~
               "EHOS has not checked the record yet. Next check: 8 November 2026, 10:03 UTC.\n"
    end

    test "says EHOS's refusal, and refuses a name that leaves its place in the path", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", "/api/v1/domains/none.client.example", 404, %{
        "error" => "not_found",
        "message" => "No domain none.client.example is mapped."
      })

      assert ehosctl(~w(domains show none.client.example), opts) ==
               {1, "", "ehosctl: No domain none.client.example is mapped.\n"}

      assert ehosctl(~w(domains show ..), opts) ==
               {2, "",
                "ehosctl: .. is not a domain. Give a domain such as ledger.client.example.\n"}
    end
  end

  describe "domains remove" do
    test "removes a mapping with --yes", %{provider: provider, opts: opts} do
      api(provider, "DELETE", "/api/v1/domains/ledger.client.example", 200, @waiting)

      assert ehosctl(~w(domains remove ledger.client.example --yes), opts) ==
               {0,
                "Removed the mapping of ledger.client.example to ledger in production, entry " <>
                  "web. You can remove its DNS record at the DNS provider of the domain.\n", ""}

      assert length(
               FakeProvider.requests(provider, "DELETE /api/v1/domains/ledger.client.example")
             ) ==
               1
    end

    test "asks first on a terminal, and removes nothing without a yes", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "DELETE", "/api/v1/domains/ledger.client.example", 200, @waiting)

      mock_terminal_answer("n\n")

      assert ehosctl(~w(domains remove ledger.client.example), opts) ==
               {2, "",
                "Installation: local (#{provider.issuer})\n" <>
                  "Remove the mapping of ledger.client.example? The application stops answering " <>
                  "at the domain. [y/N] \e[31mehosctl:\e[0m You did not confirm, so nothing was removed.\n"}

      mock_terminal_answer("y\n")
      {0, _stdout, _stderr} = ehosctl(~w(domains remove ledger.client.example), opts)

      assert length(
               FakeProvider.requests(provider, "DELETE /api/v1/domains/ledger.client.example")
             ) ==
               1
    end

    test "refuses to ask where nobody can answer", %{opts: opts} do
      stub(Ehosctl.TerminalMock, :input_terminal?, fn -> false end)
      stub(Ehosctl.TerminalMock, :error_terminal?, fn -> false end)

      assert ehosctl(~w(domains remove ledger.client.example), opts) ==
               {2, "",
                "ehosctl: Nothing was removed: ehosctl asks before it removes the mapping of " <>
                  "ledger.client.example, and nobody can answer here. Answer on a terminal, or " <>
                  "give --yes.\n"}
    end
  end

  defp mock_terminal_answer(answer) do
    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :gets, fn "" -> answer end)
  end
end

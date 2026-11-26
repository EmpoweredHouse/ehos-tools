defmodule Ehosctl.InstallationDomainTest do
  # `ehosctl status domain` (eh-os#1293, ehos-tools#832): the DNS records of the
  # installation's domain, from `/api/v1/installation/domain`.
  use Ehosctl.SignInCase

  doctest Ehosctl.InstallationDomain

  @path "/api/v1/installation/domain"
  @guide "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#make-the-dns-records-for-public-certificates"

  @there %{
    "name" => "ehos.client.example",
    "type" => "CAA",
    "value" => "0 issue \"letsencrypt.org\"",
    "purpose" => "Lets Let's Encrypt issue certificates for the console's host.",
    "without" => "Without it, another authority could issue them.",
    "state" => "there",
    "found" => [],
    "advice" => nil
  }

  @other %{
    "name" => "ehos.client.example",
    "type" => "A",
    "value" => "203.0.113.10",
    "purpose" => "Sends the console's host to the server.",
    "without" => "Without it, no person and no pipeline reaches the console at this host.",
    "state" => "other",
    "found" => ["198.51.100.7"],
    "advice" => "Your name servers give 198.51.100.7 in place of this value. Change the value."
  }

  # A reading as eh-os's `docs/installation-api.md` gives it.
  @reading %{
    "host" => "ehos.client.example",
    "public_certificates" => true,
    "known" => true,
    "zone" => "client.example",
    "servers" => ["ns1.dns.example"],
    "checked_at" => "2026-11-06T10:00:00.000000Z",
    "checked_by" => "admin@client.example",
    "error" => nil,
    "records" => [@other, @there],
    "problems" => [
      %{
        "kind" => "edge",
        "name" => "edge.ehos.client.example",
        "found" => ["198.51.100.7"],
        "advice" => "edge.ehos.client.example has a record of its own. Remove it."
      }
    ],
    "addresses" => [
      %{
        "name" => "ledger.staging.ehos.client.example",
        "reason" => "Issuing",
        "message" => "Issuing certificate as Secret does not exist"
      }
    ]
  }

  @right %{
    @reading
    | "records" => [@there],
      "problems" => [],
      "addresses" => [],
      "checked_by" => nil
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  test "prints each record with its state and what to change, and exits 1 while one is not right",
       %{provider: provider, opts: opts} do
    api(provider, "GET", @path, 200, @reading)

    assert ehosctl(~w(status domain), opts) ==
             {1,
              """
              DNS records of ehos.client.example, in the zone client.example, at the name servers ns1.dns.example.
              Last check: 6 November 2026, 10:00 UTC, asked by admin@client.example.

               NAME                 TYPE  VALUE                      STATE
               ehos.client.example  A     203.0.113.10               other value
               ehos.client.example  CAA   0 issue "letsencrypt.org"  there

              What to change:
              - ehos.client.example A: Your name servers give 198.51.100.7 in place of this value. Change the value.
              - edge.ehos.client.example has a record of its own. Remove it.

              Addresses of applications without a certificate yet:

               ADDRESS                             REASON   MESSAGE
               ledger.staging.ehos.client.example  Issuing  Issuing certificate as Secret does not exist

              The console shows the same at #{provider.issuer}/installation/domain. The guide says how to make each record at your DNS provider: #{@guide}
              """, ""}

    {1, json, ""} = ehosctl(~w(status domain --json), opts)
    assert JSON.decode!(json) == @reading
  end

  test "exits 0 once each record is there and nothing else is wrong", %{
    provider: provider,
    opts: opts
  } do
    api(provider, "GET", @path, 200, @right)

    assert ehosctl(~w(status domain), opts) ==
             {0,
              """
              DNS records of ehos.client.example, in the zone client.example, at the name servers ns1.dns.example.
              Last check: 6 November 2026, 10:00 UTC, the daily check of EHOS.

               NAME                 TYPE  VALUE                      STATE
               ehos.client.example  CAA   0 issue "letsencrypt.org"  there
              """, ""}
  end

  test "fails while a record is not checked, and shows a state it does not know", %{
    provider: provider,
    opts: opts
  } do
    api(provider, "GET", @path, 200, %{
      @right
      | "records" => [%{@there | "state" => "unchecked"}, %{@there | "state" => "later"}],
        "checked_at" => nil,
        "error" => "No name server of client.example answered."
    })

    {1, stdout, ""} = ehosctl(~w(status domain), opts)
    assert stdout =~ "EHOS has not checked the records yet.\n"

    assert stdout =~
             "The check did not get an answer: No name server of client.example answered.\n"

    assert stdout =~ "not checked\n"
    assert stdout =~ "later\n"
  end

  # EHOS builds advice from what the name servers give, which a line break must not leave as a
  # line of ehosctl's own.
  test "prints advice with a line break as one quoted line", %{provider: provider, opts: opts} do
    api(provider, "GET", @path, 200, %{
      @reading
      | "records" => [%{@other | "advice" => "Change the value.\nRun rm -rf now."}],
        "problems" => []
    })

    {1, stdout, ""} = ehosctl(~w(status domain), opts)
    assert stdout =~ ~s(- ehos.client.example A: "Change the value.\\nRun rm -rf now."\n)
    refute stdout =~ "\nRun rm -rf now."
  end

  # A later EHOS may leave out a null field, as the validation accepts.
  test "reads a reading without who checked or when", %{provider: provider, opts: opts} do
    api(provider, "GET", @path, 200, Map.delete(@right, "checked_by"))
    {0, stdout, ""} = ehosctl(~w(status domain), opts)
    assert stdout =~ "Last check: 6 November 2026, 10:00 UTC, the daily check of EHOS.\n"

    api(provider, "GET", @path, 200, Map.drop(@right, ["checked_at", "checked_by"]))
    {0, stdout, ""} = ehosctl(~w(status domain), opts)
    assert stdout =~ "EHOS has not checked the records yet.\n"
  end

  test "checks the records first with --check", %{provider: provider, opts: opts} do
    api(provider, "POST", @path <> "/check", 200, @right)

    {0, json, ""} = ehosctl(~w(status domain --check --json), opts)
    assert JSON.decode!(json) == @right
    assert length(FakeProvider.requests(provider, "POST #{@path}/check")) == 1
  end

  test "says EHOS's refusal of a check too soon", %{provider: provider, opts: opts} do
    api(provider, "POST", @path <> "/check", 429, %{
      "error" => "too_soon",
      "message" => "EHOS checked the records less than a minute ago. Try again in 40 seconds.",
      "retry_after" => 40
    })

    {kind, "", stderr} = ehosctl(~w(status domain --check), opts)
    assert kind != 0

    assert stderr ==
             "ehosctl: EHOS checked the records less than a minute ago. Try again in 40 " <>
               "seconds.\n"
  end

  test "says that an installation under its own CA needs no records", %{
    provider: provider,
    opts: opts
  } do
    api(provider, "GET", @path, 200, %{
      @right
      | "public_certificates" => false,
        "zone" => nil,
        "servers" => [],
        "records" => [],
        "checked_at" => nil
    })

    assert ehosctl(~w(status domain), opts) ==
             {0,
              "EHOS at ehos.client.example uses the certificate authority of the installation, " <>
                "so it needs no DNS records of your company.\n", ""}
  end

  test "says to install again when the installer gave EHOS no values", %{
    provider: provider,
    opts: opts
  } do
    api(provider, "GET", @path, 200, %{@right | "known" => false, "checked_at" => nil})

    assert ehosctl(~w(status domain), opts) ==
             {1, "",
              "ehosctl: EHOS does not know the values of the DNS records.\n" <>
                "  The installer did not give them.\n" <>
                "What to do:\n" <>
                "  Install EHOS again with ehosctl 0.37.0 or later:\n" <>
                "  ehosctl install --installation local\n"}
  end

  test "refuses an answer it cannot read", %{provider: provider, opts: opts} do
    for broken <- [
          Map.delete(@reading, "known"),
          %{@reading | "records" => [%{"name" => "x"}]},
          %{@reading | "addresses" => "later"}
        ] do
      api(provider, "GET", @path, 200, broken)

      assert ehosctl(~w(status domain), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"},
             inspect(broken)
    end
  end
end

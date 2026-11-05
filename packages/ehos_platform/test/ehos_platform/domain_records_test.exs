defmodule EhosPlatform.DomainRecordsTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosPlatform.CertificateLogMock
  alias EhosPlatform.DnsMock
  alias EhosPlatform.DomainRecords

  doctest DomainRecords

  setup :verify_on_exit!

  @host "ehos.client.example"
  @address "203.0.113.10"
  @challenge "4f2c._acme-dns.ehos.client.example"
  @console "https://acme-v02.api.letsencrypt.org/acme/acct/1"
  @addresses "https://acme-v02.api.letsencrypt.org/acme/acct/2"
  @console_caa {0, "issue", "letsencrypt.org; accounturi=#{@console}; validationmethods=dns-01"}
  @addresses_caa {0, "issue",
                  "letsencrypt.org; accounturi=#{@addresses}; validationmethods=http-01"}
  # The zone's two name servers, as the zone names them, and their addresses.
  @name_servers %{"ns1.dns.example" => {192, 0, 2, 1}, "ns2.dns.example" => {192, 0, 2, 2}}

  @records DomainRecords.records(%{
             host: @host,
             address: @address,
             challenge: @challenge,
             console_account: @console,
             addresses_account: @addresses
           })

  # The company's zone `client.example` with every record made, as its name servers serve it.
  @zone %{
    {@host, :a} => [@address],
    {"*.#{@host}", :a} => [@address],
    {"_acme-dns.#{@host}", :ns} => [@host],
    {"_acme-challenge.#{@host}", :cname} => [@challenge],
    {@host, :caa} => [@console_caa],
    {"*.#{@host}", :caa} => [@addresses_caa]
  }

  describe "records/1 and format/1" do
    test "say each record with its value and what it is for, and where the guide is" do
      text = DomainRecords.format(@records)

      assert text =~
               "  _acme-challenge.ehos.client.example  CNAME  #{@challenge}.\n" <>
                 "    Points Let's Encrypt to the record that acme-dns writes for the console."

      assert text =~ ~s(  ehos.client.example                  CAA    0 issue "letsencrypt.org;)
      assert String.ends_with?(text, DomainRecords.guide())
      assert length(String.split(text, "\n")) == 13
    end
  end

  describe "check/2" do
    test "passes when every name server of the zone serves each record" do
      asked = serve(@zone)

      assert DomainRecords.check(@records, dns: DnsMock) == :ok
      # Both name servers, each asked without recursion.
      assert asked.() |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort() ==
               [:recursive, {192, 0, 2, 1}, {192, 0, 2, 2}]
    end

    test "finds the zone at the host when the host is a zone of its own" do
      serve(@zone, zone: @host)

      assert DomainRecords.check(@records, dns: DnsMock) == :ok
    end

    test "names each record that is missing, with what to make" do
      serve(Map.drop(@zone, [{"_acme-challenge.#{@host}", :cname}, {"_acme-dns.#{@host}", :ns}]))

      assert DomainRecords.check(@records, dns: DnsMock) ==
               {:error,
                [
                  "_acme-dns.ehos.client.example has no NS record at the name servers of " <>
                    "client.example. Make it: NS ehos.client.example.",
                  "_acme-challenge.ehos.client.example has no CNAME record at the name servers " <>
                    "of client.example. Make it: CNAME #{@challenge}."
                ]}
    end

    test "names a record with another value, and what to change it to" do
      serve(Map.put(@zone, {@host, :a}, ["198.51.100.7"]))

      assert DomainRecords.check(@records, dns: DnsMock) ==
               {:error,
                [
                  "ehos.client.example has the A record 198.51.100.7. Change it to: #{@address}"
                ]}
    end

    test "names a record that one name server does not serve yet" do
      serve(@zone, only_at: {192, 0, 2, 1})

      assert {:error, [_ | _] = problems} = DomainRecords.check(@records, dns: DnsMock)
      assert Enum.all?(problems, &(&1 =~ "has no"))
    end

    test "refuses another CAA record beside EHOS's, and a CAA record with another account" do
      other = {0, "issue", "sectigo.com"}
      serve(Map.put(@zone, {@host, :caa}, [@console_caa, other]))

      assert DomainRecords.check(@records, dns: DnsMock) ==
               {:error,
                [
                  ~s(ehos.client.example has another CAA record beside EHOS's: 0 issue "sectigo.com". ) <>
                    "Remove it, so that Let's Encrypt follows EHOS's record alone."
                ]}

      serve(Map.put(@zone, {"*.#{@host}", :caa}, [@console_caa]))

      assert {:error, [problem]} = DomainRecords.check(@records, dns: DnsMock)
      assert problem =~ "*.ehos.client.example has the CAA record 0 issue"
    end

    test "reads a CAA value with spaces around its separators as the same value" do
      {flags, _tag, value} = @console_caa
      spaced = {flags, "ISSUE", String.replace(value, ";", " ; ") |> String.replace("=", " = ")}
      serve(Map.put(@zone, {@host, :caa}, [spaced]))

      assert DomainRecords.check(@records, dns: DnsMock) == :ok
    end

    test "shows what a name server answers without its control characters" do
      serve(Map.put(@zone, {@host, :a}, ["198.51.100.7\e[2K"]))

      assert DomainRecords.check(@records, dns: DnsMock) ==
               {:error,
                [
                  "ehos.client.example has the A record 198.51.100.7?[2K. Change it to: #{@address}"
                ]}
    end

    test "says a name server that refuses or fails did not answer, rather than that records are missing" do
      for rcode <- [:refused, :servfail] do
        serve(@zone, rcode: {{192, 0, 2, 2}, rcode})

        assert DomainRecords.check(@records, dns: DnsMock) ==
                 {:error,
                  ["The name server ns2.dns.example did not answer: it answered #{rcode}."]}
      end
    end

    test "reads a CNAME at the host as no A record of its own" do
      serve(
        @zone
        |> Map.put({@host, :a}, [@address])
        |> Map.put(:cname_at_host, "web.client.example")
      )

      assert {:error, [problem | _]} = DomainRecords.check(@records, dns: DnsMock)
      assert problem =~ "ehos.client.example has no A record"
    end

    test "refuses an AAAA record at the host or under it" do
      serve(Map.put(@zone, {"*.#{@host}", :aaaa}, ["2001:db8::1"]))

      assert DomainRecords.check(@records, dns: DnsMock) ==
               {:error,
                [
                  "*.ehos.client.example has an AAAA record (2001:db8::1). The server answers " <>
                    "on its IPv4 address alone: remove the AAAA record, or a browser can try " <>
                    "the other address."
                ]}
    end

    test "refuses a record of its own at edge.<host>, which hides the wildcard's CAA" do
      serve(Map.put(@zone, {"edge.#{@host}", :a}, [@address]))

      assert DomainRecords.check(@records, dns: DnsMock) ==
               {:error,
                [
                  "edge.ehos.client.example has a record of its own, or is not answered by the " <>
                    "wildcard *.ehos.client.example. Remove every record at " <>
                    "edge.ehos.client.example: a domain mapped to an application points there."
                ]}
    end

    test "says when a name server does not answer, or the zone has none" do
      serve(@zone, failing: {192, 0, 2, 2})

      assert DomainRecords.check(@records, dns: DnsMock) ==
               {:error, ["The name server ns2.dns.example did not answer: timeout."]}

      stub(DnsMock, :query, fn _name, :soa, :recursive ->
        {:ok, %{rcode: :nxdomain, answers: [], authority: []}}
      end)

      assert DomainRecords.check(@records, dns: DnsMock) ==
               {:error,
                [
                  "The name servers of ehos.client.example could not be found: no zone holds " <>
                    "client.example."
                ]}
    end
  end

  test "dns/1 asks DNS itself when :dns is not given, or nil" do
    assert DomainRecords.dns([]) == EhosPlatform.DnsImpl
    assert DomainRecords.dns(dns: nil) == EhosPlatform.DnsImpl
    assert DomainRecords.dns(dns: DnsMock) == DnsMock
  end

  describe "warnings/2" do
    test "lists the certificates the logs hold for the host and each wildcard above it" do
      expect(CertificateLogMock, :certificates, 2, fn
        "ehos.client.example" ->
          {:ok, []}

        "*.client.example" ->
          {:ok,
           [
             %{
               names: ["*.client.example", "client.example"],
               issuer: "C=US, O=Let's Encrypt, CN=R12",
               not_after: "2027-01-20T10:00:00"
             }
           ]}
      end)

      assert DomainRecords.warnings(@host, certificate_log: CertificateLogMock) == [
               "A record of your own under ehos.client.example sends that name away from the " <>
                 "server, since the wildcard *.ehos.client.example does not replace it.",
               "The Certificate Transparency logs hold a certificate for *.client.example " <>
                 "(*.client.example, client.example), from C=US, O=Let's Encrypt, CN=R12, valid " <>
                 "until 2027-01-20T10:00:00. Whoever holds its key can answer as the console to " <>
                 "a browser, and to an application when the issuer is Let's Encrypt."
             ]
    end

    test "lists at most five certificates for a name, and counts the rest" do
      certificate = %{names: ["*.client.example"], issuer: "CN=R12", not_after: "2027-01-20"}

      stub(CertificateLogMock, :certificates, fn
        "*.client.example" -> {:ok, List.duplicate(certificate, 8)}
        _host -> {:ok, []}
      end)

      warnings = DomainRecords.warnings(@host, certificate_log: CertificateLogMock)

      assert length(warnings) == 1 + 5 + 1

      assert List.last(warnings) ==
               "The Certificate Transparency logs hold 3 more certificates for " <>
                 "*.client.example: search https://crt.sh for it."
    end

    test "shows what the logs answer without its control characters" do
      stub(CertificateLogMock, :certificates, fn
        "*.client.example" ->
          {:ok, [%{names: ["a\e[2Kb"], issuer: "CN=R\r12", not_after: "2027"}]}

        _host ->
          {:ok, []}
      end)

      [_other, logged] = DomainRecords.warnings(@host, certificate_log: CertificateLogMock)
      assert logged =~ "(a?[2Kb), from CN=R?12"
    end

    test "says when the logs could not be read, and goes on" do
      stub(CertificateLogMock, :certificates, fn _name -> {:error, "timeout"} end)

      assert [_other, unread | _] =
               DomainRecords.warnings("ehos.dept.client.co.uk",
                 certificate_log: CertificateLogMock
               )

      assert unread ==
               "The Certificate Transparency logs could not be read for ehos.dept.client.co.uk " <>
                 "(timeout). Search https://crt.sh for it, to see which certificates name it."

      # The host, *.dept.client.co.uk and *.client.co.uk: never the public suffix's wildcard.
      assert length(
               DomainRecords.warnings("ehos.dept.client.co.uk",
                 certificate_log: CertificateLogMock
               )
             ) == 4
    end
  end

  # Serves `zone` as the company's name servers do, and returns a function that lists what was
  # asked: `{name, type, server}`. The zone is `client.example`, or `:zone`; a name under the
  # wildcard with no record of its own gets the wildcard's; `_acme-dns.<host>`'s NS records are a
  # referral, in the authority section. `:only_at` serves the records at one server alone, the
  # other answering as an empty zone; `:failing` is a server that never answers.
  defp serve(zone, opts \\ []) do
    {:ok, asked} = Agent.start_link(fn -> [] end)
    apex = Keyword.get(opts, :zone, "client.example")

    stub(DnsMock, :query, fn name, type, server ->
      Agent.update(asked, &[{name, type, server} | &1])

      case server do
        :recursive -> recursive(name, type, apex)
        address -> authoritative(zone, name, type, address, opts)
      end
    end)

    fn -> asked |> Agent.get(& &1) |> Enum.reverse() end
  end

  defp recursive(name, :soa, apex),
    do:
      {:ok,
       %{
         rcode: :noerror,
         answers:
           if(name == apex, do: [%{name: apex, type: :soa, data: "ns1.dns.example"}], else: []),
         authority: []
       }}

  defp recursive(apex, :ns, apex),
    do:
      {:ok,
       %{
         rcode: :noerror,
         answers: for(name <- Map.keys(@name_servers), do: %{name: apex, type: :ns, data: name}),
         authority: []
       }}

  defp recursive(name, :a, _apex),
    do:
      {:ok,
       %{
         rcode: :noerror,
         answers: [%{name: name, type: :a, data: @name_servers |> Map.fetch!(name) |> ip()}],
         authority: []
       }}

  defp authoritative(zone, name, type, address, opts) do
    cond do
      opts[:failing] == address ->
        {:error, "timeout"}

      match?({^address, _rcode}, opts[:rcode]) ->
        {:ok, %{rcode: elem(opts[:rcode], 1), answers: [], authority: []}}

      Map.has_key?(zone, :cname_at_host) and name == @host and type == :a ->
        target = zone.cname_at_host

        {:ok,
         %{
           rcode: :noerror,
           answers: [
             %{name: @host, type: :cname, data: target},
             %{name: target, type: :a, data: @address}
           ],
           authority: []
         }}

      opts[:only_at] not in [nil, address] ->
        {:ok, %{rcode: :nxdomain, answers: [], authority: []}}

      type == :ns and name == "_acme-dns.#{@host}" ->
        referral =
          for host <- Map.get(zone, {name, :ns}, []), do: %{name: name, type: :ns, data: host}

        {:ok, %{rcode: :noerror, answers: [], authority: referral}}

      true ->
        data = Map.get_lazy(zone, {name, type}, fn -> wildcard(zone, name, type) end)

        {:ok,
         %{
           rcode: :noerror,
           answers: for(d <- data, do: %{name: name, type: type, data: d}),
           authority: []
         }}
    end
  end

  # A name of its own hides the wildcard for every type.
  defp wildcard(zone, name, type) do
    own? = Enum.any?(Map.keys(zone), &match?({^name, _type}, &1))

    case String.split(name, ".", parts: 2) do
      [_label, @host] when not own? -> Map.get(zone, {"*.#{@host}", type}, [])
      _other -> []
    end
  end

  defp ip(tuple), do: tuple |> :inet.ntoa() |> to_string()
end

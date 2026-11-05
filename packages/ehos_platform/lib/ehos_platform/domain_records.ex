defmodule EhosPlatform.DomainRecords do
  @moduledoc """
  The seven DNS records a company makes for an installation with public certificates (eh-os D-158),
  what each one is for, and their check at the company's authoritative name servers.

    * `records/1` gives them, with this installation's values;
    * `check/2` asks each authoritative name server of the zone that holds the host, never a
      resolver that keeps an answer, and says what is missing or wrong;
    * `warnings/2` says what the installer cannot check, and lists the certificates the public
      Certificate Transparency logs already hold for the host or a wildcard above it;
    * `registered_domain?/1` says whether a host is a domain a registrar gives, by the Public Suffix
      List, which the installer refuses, since the cluster's DNS rule would then capture every
      name of the company.

  DNS is asked through `EhosPlatform.Dns` and the logs through `EhosPlatform.CertificateLog`
  (T-20).
  """

  alias EhosPlatform.CertificateLogImpl
  alias EhosPlatform.DnsImpl

  # The guide to the records, which says how each DNS provider takes them.
  @guide "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#make-the-dns-records-for-public-certificates"

  @typedoc "One record the company makes: its name, type and value, and what it is for."
  @type dns_record :: %{
          name: String.t(),
          type: String.t(),
          value: String.t(),
          purpose: String.t()
        }

  @typedoc """
  What the records are made from: the console's host, the server's IPv4 address, acme-dns's name
  for the console's challenge (`<id>._acme-dns.<host>`), and the URIs of the console's and the
  addresses' Let's Encrypt accounts.
  """
  @type installation :: %{
          host: String.t(),
          address: String.t(),
          challenge: String.t(),
          console_account: String.t(),
          addresses_account: String.t()
        }

  @doc "The address of the guide to the records."
  @spec guide() :: String.t()
  def guide, do: @guide

  @doc """
  The seven records, in the order the guide lists them.

      iex> EhosPlatform.DomainRecords.records(%{
      ...>   host: "ehos.client.example",
      ...>   address: "203.0.113.10",
      ...>   challenge: "4f2c._acme-dns.ehos.client.example",
      ...>   console_account: "https://acme-v02.api.letsencrypt.org/acme/acct/1",
      ...>   addresses_account: "https://acme-v02.api.letsencrypt.org/acme/acct/2"
      ...> }) |> Enum.map(&{&1.name, &1.type, &1.value})
      [
        {"ehos.client.example", "A", "203.0.113.10"},
        {"*.ehos.client.example", "A", "203.0.113.10"},
        {"_acme-dns.ehos.client.example", "NS", "ehos.client.example."},
        {"_acme-challenge.ehos.client.example", "CNAME", "4f2c._acme-dns.ehos.client.example."},
        {"ehos.client.example", "CAA", ~s(0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/1; validationmethods=dns-01")},
        {"ehos.client.example", "CAA", ~s(0 issuewild ";")},
        {"*.ehos.client.example", "CAA", ~s(0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/2; validationmethods=http-01")}
      ]
  """
  @spec records(installation()) :: [dns_record()]
  def records(%{host: host, address: address} = installation) do
    [
      %{
        name: host,
        type: "A",
        value: address,
        purpose: "Sends the console's host to the server."
      },
      %{
        name: "*.#{host}",
        type: "A",
        value: address,
        purpose: "Sends the address of each application to the server."
      },
      %{
        name: "_acme-dns.#{host}",
        type: "NS",
        value: "#{host}.",
        purpose: "Lets acme-dns on the server answer for the console's DNS challenge."
      },
      %{
        name: "_acme-challenge.#{host}",
        type: "CNAME",
        value: "#{installation.challenge}.",
        purpose: "Points Let's Encrypt to the record that acme-dns writes for the console."
      },
      %{
        name: host,
        type: "CAA",
        value: caa(installation.console_account, "dns-01"),
        purpose: "Lets only the console's account get a certificate for the console's host."
      },
      # eh-os D-158, amended on 5 November 2026: a wildcard certificate is checked at the name
      # under its `*`, so without this the console's account could get `*.<host>`, which covers
      # every application's address.
      %{
        name: host,
        type: "CAA",
        value: ~s(0 issuewild ";"),
        purpose: "Lets no account get a wildcard certificate for the console's host."
      },
      %{
        name: "*.#{host}",
        type: "CAA",
        value: caa(installation.addresses_account, "http-01"),
        purpose:
          "Lets only the addresses' account get a certificate for an application's address."
      }
    ]
  end

  defp caa(account, method),
    do: ~s(0 issue "letsencrypt.org; accounturi=#{account}; validationmethods=#{method}")

  @doc """
  The records as text for a terminal: each with its value, and on the line under it what it is
  for, then where the guide is.
  """
  @spec format([dns_record()]) :: String.t()
  def format(records) do
    width = records |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end)

    lines =
      Enum.map(records, fn record ->
        "  #{String.pad_trailing(record.name, width)}  #{String.pad_trailing(record.type, 5)}  " <>
          "#{record.value}\n    #{record.purpose}"
      end)

    Enum.join(lines, "\n") <>
      "\nThe guide says how to make each record at your DNS provider: #{@guide}"
  end

  @doc """
  Whether `host` is a registered domain: one label under a public suffix of the Public Suffix List,
  as `client.example` or `client.co.uk` is, and `ehos.client.example` is not.

      iex> EhosPlatform.DomainRecords.registered_domain?("client.co.uk")
      true

      iex> EhosPlatform.DomainRecords.registered_domain?("ehos.client.co.uk")
      false
  """
  @spec registered_domain?(String.t()) :: boolean()
  def registered_domain?(host) do
    case PublicSufx.public_suffix(host) do
      nil -> false
      suffix -> length(String.split(host, ".")) == length(String.split(suffix, ".")) + 1
    end
  end

  @doc """
  Checks the records at every authoritative name server of the zone that holds the host: `:ok`,
  or `{:error, problems}`, one sentence for each record that is missing or wrong, and for what
  else is there that must not be.

  Beside the seven records, it refuses an `AAAA` record at the host or under it, since the server
  answers on its IPv4 address alone; another `CAA` record at either name, since Let's Encrypt
  would then follow it; and a record of its own at `edge.<host>`, whose `A` and `CAA` must be the
  wildcard's (eh-os D-155).

  Options: `:dns`, the `EhosPlatform.Dns` to ask, `EhosPlatform.DnsImpl` unless given or `nil`.
  """
  @spec check([dns_record()], keyword()) :: :ok | {:error, [String.t()]}
  def check(records, opts \\ []) do
    dns = dns(opts)
    [%{name: host} | _rest] = records

    with {:ok, zone, servers} <- name_servers(dns, host) do
      problems =
        servers
        |> Enum.flat_map(&server_problems(dns, records, host, &1))
        |> Enum.uniq()

      if problems == [],
        do: :ok,
        else: {:error, Enum.map(problems, &(&1 |> String.replace("{zone}", zone) |> printable()))}
    end
  end

  defp server_problems(dns, records, host, {server_name, address}) do
    case at_server(dns, records, host, address) do
      {:ok, found} -> found
      {:error, reason} -> ["The name server #{server_name} did not answer: #{reason}."]
    end
  end

  # The zone that holds the host, the closest name at or above it with an SOA record of its own,
  # and the IPv4 address of each of its name servers, through this machine's resolver.
  defp name_servers(dns, host) do
    with {:ok, zone} <- zone(dns, host),
         {:ok, %{answers: answers}} <- dns.query(zone, :ns, :recursive),
         names = for(%{type: :ns, name: ^zone, data: name} <- answers, do: name),
         true <- names != [] || {:error, ["The zone #{zone} has no name servers."]},
         addressed = Enum.flat_map(names, &addresses(dns, &1)),
         true <-
           addressed != [] ||
             {:error, ["No name server of the zone #{zone} has an IPv4 address."]} do
      {:ok, zone, addressed}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, ["The name servers of #{host} could not be found: #{reason}."]}

      {:error, problems} ->
        {:error, problems}
    end
  end

  defp zone(dns, name) do
    case dns.query(name, :soa, :recursive) |> answered() do
      {:ok, %{answers: answers}} ->
        if Enum.any?(answers, &match?(%{type: :soa, name: ^name}, &1)),
          do: {:ok, name},
          else: parent_zone(dns, name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parent_zone(dns, name) do
    case String.split(name, ".", parts: 2) do
      [_label, parent] ->
        if String.contains?(parent, "."), do: zone(dns, parent), else: none(name)

      [_top] ->
        none(name)
    end
  end

  defp none(name), do: {:error, "no zone holds #{name}"}

  defp addresses(dns, name_server) do
    case dns.query(name_server, :a, :recursive) do
      {:ok, %{answers: answers}} ->
        for %{type: :a, data: address} <- answers,
            {:ok, ip} <- [:inet.parse_ipv4strict_address(String.to_charlist(address))],
            do: {name_server, ip}

      {:error, _reason} ->
        []
    end
  end

  defp at_server(dns, records, host, address) do
    questions =
      Enum.uniq(for record <- records, do: {record.name, query_type(record.type)}) ++
        [{host, :aaaa}, {"*.#{host}", :aaaa}, {"edge.#{host}", :a}, {"edge.#{host}", :caa}]

    answers =
      Enum.reduce_while(questions, %{}, fn {name, type} = question, acc ->
        case dns.query(name, type, address) |> answered() do
          {:ok, reply} -> {:cont, Map.put(acc, question, reply)}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with %{} <- answers do
      {caa, others} = Enum.split_with(records, &(&1.type == "CAA"))

      {:ok,
       Enum.flat_map(others, &record_problems(answers, &1)) ++
         Enum.flat_map(by_name(caa), &authorities(answers, &1)) ++
         no_aaaa(answers, host) ++ no_aaaa(answers, "*.#{host}") ++ edge(answers, host)}
    end
  end

  defp query_type("A"), do: :a
  defp query_type("NS"), do: :ns
  defp query_type("CNAME"), do: :cname
  defp query_type("CAA"), do: :caa

  defp record_problems(answers, %{type: "NS"} = record), do: delegation(answers, record)
  defp record_problems(answers, record), do: single(answers, record, query_type(record.type))

  # The records grouped by name, in the order each name first comes.
  defp by_name(records) do
    for name <- records |> Enum.map(& &1.name) |> Enum.uniq(),
        do: {name, Enum.filter(records, &(&1.name == name))}
  end

  # One record of `type` at the name, with the record's value, and no other.
  defp single(answers, record, type) do
    expected = trim(record.value)

    case values(answers, record.name, type) do
      [] -> [missing(record)]
      [^expected] -> []
      found -> [other(record, found)]
    end
  end

  # An `NS` record that the zone delegates by: the zone's server gives it as a referral, in the
  # authority section, and as an answer when it serves the child zone too.
  defp delegation(answers, record) do
    reply = Map.fetch!(answers, {record.name, :ns})
    expected = trim(record.value)

    found =
      for %{type: :ns, name: name, data: data} <- reply.answers ++ reply.authority,
          name == record.name,
          do: data

    case Enum.uniq(found) do
      [] -> [missing(record)]
      [^expected] -> []
      found -> [other(record, found)]
    end
  end

  # The CAA records of one name, each there and no other beside them: Let's Encrypt follows every
  # record of the set.
  defp authorities(answers, {name, records}) do
    found = values(answers, name, :caa)
    expected = Enum.map(records, &caa_value(&1.value))
    others = Enum.reject(found, &(normal_caa(&1) in expected))

    missing =
      for record <- records,
          caa_value(record.value) not in Enum.map(found, &normal_caa/1),
          do: missing(record)

    if others == [],
      do: missing,
      else:
        missing ++
          [
            "#{name} has another CAA record beside EHOS's: " <>
              "#{Enum.map_join(others, ", ", &show_caa/1)}. Remove it, so that Let's Encrypt " <>
              "follows EHOS's records alone."
          ]
  end

  defp no_aaaa(answers, name) do
    case values(answers, name, :aaaa) do
      [] ->
        []

      found ->
        [
          "#{name} has an AAAA record (#{Enum.join(found, ", ")}). The server answers on its IPv4 " <>
            "address alone: remove the AAAA record, or a browser can try the other address."
        ]
    end
  end

  # edge.<host> must be answered by the wildcard: its A and CAA records what the wildcard serves.
  # A name of its own there hides both. A wildcard that is wrong itself is said once, above.
  defp edge(answers, host) do
    same? = fn type ->
      Enum.sort(values(answers, "edge.#{host}", type)) ==
        Enum.sort(values(answers, "*.#{host}", type))
    end

    if same?.(:a) and same?.(:caa),
      do: [],
      else: [
        "edge.#{host} has a record of its own, or is not answered by the wildcard *.#{host}. " <>
          "Remove every record at edge.#{host}: a domain mapped to an application points there."
      ]
  end

  # The records of `type` that `name` itself owns: a CNAME there brings its target's along.
  defp values(answers, name, type) do
    reply = Map.fetch!(answers, {name, type})
    for %{type: ^type, name: ^name, data: data} <- reply.answers, do: data
  end

  # An answer is one with no error, or one saying the name is not there; a server that refused or
  # failed did not say what the zone holds.
  defp answered({:ok, %{rcode: rcode}} = reply) when rcode in [:noerror, :nxdomain], do: reply
  defp answered({:ok, %{rcode: rcode}}), do: {:error, "it answered #{rcode}"}
  defp answered(error), do: error

  @doc false
  # The `EhosPlatform.Dns` `check/2` asks: the one in `opts`, or `EhosPlatform.DnsImpl` when it is
  # not given or nil.
  @spec dns(keyword()) :: module()
  def dns(opts), do: Keyword.get(opts, :dns) || DnsImpl

  defp missing(record),
    do:
      "#{record.name} has no #{record.type} record at the name servers of {zone}. " <>
        "Make it: #{record.type} #{record.value}"

  defp other(record, found),
    do:
      "#{record.name} has the #{record.type} record #{Enum.join(found, ", ")}. " <>
        "Change it to: #{record.value}"

  defp trim(value), do: value |> String.trim_trailing(".") |> String.downcase()

  # `0 issue "a; b"` as the three fields DNS holds, with no space around `;` or `=`.
  defp caa_value(value) do
    [flags, tag, quoted] = String.split(value, " ", parts: 3)
    normal_caa({String.to_integer(flags), tag, String.trim(quoted, "\"")})
  end

  defp normal_caa({flags, tag, value}),
    do:
      {flags, String.downcase(tag),
       value |> String.replace(~r/\s*([;=])\s*/, "\\1") |> String.trim()}

  defp show_caa({flags, tag, value}), do: ~s(#{flags} #{tag} "#{value}")

  @doc """
  What the installer warns of: any other record under the host, which the check cannot see, and
  the certificates the Certificate Transparency logs hold that are not expired for the host or a
  wildcard above it, up to the registered domain. Each is a sentence; a log that does not answer is
  one too.

  Options: `:certificate_log`, the `EhosPlatform.CertificateLog` to ask,
  `EhosPlatform.CertificateLogImpl` unless given or `nil`.
  """
  @spec warnings(String.t(), keyword()) :: [String.t()]
  def warnings(host, opts \\ []) do
    log = Keyword.get(opts, :certificate_log) || CertificateLogImpl

    other =
      "A record of your own under #{host} sends that name away from the server, since the " <>
        "wildcard *.#{host} does not replace it."

    [other | Enum.flat_map(logged_names(host), &logged(log, &1))] |> Enum.map(&printable/1)
  end

  # At most this many certificates are said for one name; the rest are counted.
  @listed 5

  @doc """
  `text` as a terminal shows it as it is: what a name server or the logs answered can hold control
  or format characters, which could move the cursor or rewrite a line, and each becomes `?`. Text
  that is not UTF-8 is shown as Elixir writes a binary.

      iex> EhosPlatform.DomainRecords.printable("a\\e[2Kb")
      "a?[2Kb"
  """
  @spec printable(String.t()) :: String.t()
  def printable(text) do
    if String.valid?(text),
      do: String.replace(text, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, "?"),
      else: inspect(text)
  end

  # The host and each wildcard above it, below the public suffix: for ehos.client.example,
  # ehos.client.example and *.client.example.
  defp more(_name, 0), do: []

  defp more(name, count),
    do: [
      "The Certificate Transparency logs hold #{count} more certificates for #{name}: " <>
        "search https://crt.sh for it."
    ]

  defp logged_names(host) do
    [_label | parents] = String.split(host, ".")
    suffix = PublicSufx.public_suffix(host) || List.last(parents)

    wildcards =
      parents
      |> Enum.with_index()
      |> Enum.map(fn {_label, index} -> parents |> Enum.drop(index) |> Enum.join(".") end)
      |> Enum.take_while(&(&1 != suffix))
      |> Enum.map(&"*.#{&1}")

    [host | wildcards]
  end

  defp logged(log, name) do
    case log.certificates(name) do
      {:ok, []} ->
        []

      {:ok, certificates} ->
        {listed, more} = Enum.split(certificates, @listed)

        Enum.map(listed, fn certificate ->
          "The Certificate Transparency logs hold a certificate for #{name} " <>
            "(#{Enum.join(certificate.names, ", ")}), from #{certificate.issuer}, valid until " <>
            "#{certificate.not_after}. Whoever holds its key can answer as the console to a " <>
            "browser, and to an application when the issuer is Let's Encrypt."
        end) ++ more(name, length(more))

      {:error, reason} ->
        [
          "The Certificate Transparency logs could not be read for #{name} (#{reason}). " <>
            "Search https://crt.sh for it, to see which certificates name it."
        ]
    end
  end
end

defmodule Ehosctl.Domains do
  @moduledoc """
  `ehosctl domains`, `domains map`, `domains show` and `domains remove`: the domains of the
  company mapped to a production application, such as `ledger.client.example` in place of the
  application's own address, through EHOS's API (eh-os
  [`docs/installation-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/installation-api.md),
  [D-155](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0155-an-application-s-entry-in-a-production-environment-answers-at-a-domain-of-the-company-s-own-mapped-in-the-console-under-a-certificate-from-a-public-acme-issuer.md),
  [ehos-tools#853](https://github.com/EmpoweredHouse/ehos-tools/issues/853)), as the console's
  Domains page does. Each call needs `ehos.domain.manage` at the whole platform; EHOS decides and
  records it, and its refusal is printed in its words.

  A mapping waits for the company's `CNAME` record, then for its certificate, and is right only
  once it is `active`. `domains` and `domains show` print what they read, then exit 1 while a
  mapping is not active, so a pipeline can wait for one. A state this `ehosctl` does not know, as a
  later EHOS may give, is printed as EHOS gives it. No message says how a DNS provider takes a
  record: each points to the console's page of the domain, and to the guide in eh-os's
  `docs/INSTALLING.md`.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Terminal

  require Ehosctl.Api

  @look "`ehosctl domains`"
  @guide "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#make-the-dns-records-for-public-certificates"
  @active "active"
  @fields ~w(name application environment entry state mapped_by mapped_at record check
             checked_at next_check_at named_by)

  @impl Ehosctl.Command
  def name, do: :domains

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def runs_bare?, do: true

  @impl Ehosctl.Command
  def spec do
    domain = [
      value_name: "DOMAIN",
      required: true,
      help: "The domain of your company, such as ledger.client.example."
    ]

    [
      about:
        "List the domains of your company that show a production application, with their " <>
          "state. Map, show and remove a domain. Exits 1 while a domain is not active.",
      flags: Output.json_flag(),
      subcommands: [
        map: [
          name: "map",
          about:
            "Map a domain of your company to an entry of an application in production. EHOS " <>
              "gives the DNS record to make, then gets a certificate for the domain.",
          args: [domain: domain],
          options: [
            app: [
              long: "--app",
              value_name: "APPLICATION",
              required: true,
              help: "The application that the domain shows."
            ],
            env: [
              long: "--env",
              value_name: "ENVIRONMENT",
              required: true,
              help: "The production environment of the application."
            ],
            entry: [
              long: "--entry",
              value_name: "ENTRY",
              help: "The public entry of the application. By default web."
            ]
          ],
          flags: Output.json_flag()
        ],
        show: [
          name: "show",
          about:
            "Show a mapped domain: its state, the DNS record to make, the last check of the " <>
              "record and what to change. Exits 1 while the domain is not active.",
          args: [domain: domain],
          flags: Output.json_flag()
        ],
        remove: [
          name: "remove",
          about: "Remove the mapping of a domain. The application stops answering at the domain.",
          args: [domain: domain],
          flags: [yes: [long: "--yes", help: "Remove without a question."]] ++ Output.json_flag()
        ]
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"domains" => domains}} when is_list(domains) <-
           Api.read(installation, "/api/v1/domains", opts),
         true <- Enum.all?(domains, &mapping?/1) || Api.unexpected(installation) do
      domains = Enum.map(domains, &only/1)

      %{text: listed(domains, installation), json: %{domains: domains}}
      |> right_or_1(Enum.all?(domains, &active?/1), parsed)
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  def call([:map], parsed, opts) do
    domain = parsed.args.domain
    %{app: app, env: env, entry: entry} = parsed.options
    installation = Keyword.fetch!(opts, :installation)
    body = maybe_put(%{domain: domain, application: app, environment: env}, :entry, entry)

    Api.write(
      opts,
      {:post, "/api/v1/domains", body},
      [
        status: 201,
        key: nil,
        valid?: &(mapping?(&1) and &1["application"] == app and &1["environment"] == env),
        only: &only/1,
        look: @look
      ],
      &mapped(&1, installation)
    )
  end

  def call([:show], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, path} <- path(parsed.args.domain),
         {:ok, body} <- Api.read(installation, path, opts),
         true <- mapping?(body) || Api.unexpected(installation) do
      mapping = only(body)

      %{text: shown(mapping, installation), json: mapping}
      |> right_or_1(active?(mapping), parsed)
    end
  end

  def call([:remove], parsed, opts) do
    domain = parsed.args.domain

    with {:ok, path} <- path(domain),
         :ok <- confirmed(domain, parsed.flags.yes) do
      Api.write(
        opts,
        {:delete, path, nil},
        [status: 200, key: nil, valid?: &mapping?/1, only: &only/1, look: @look],
        &removed/1
      )
    end
  end

  @doc """
  A state of a mapping as a person reads it. One this `ehosctl` does not know, as a later EHOS
  may add, is shown as EHOS gives it.

      iex> Ehosctl.Domains.state("waiting_for_dns")
      "waiting for DNS"

      iex> Ehosctl.Domains.state("paused")
      "paused"
  """
  @spec state(String.t()) :: String.t()
  def state("waiting_for_dns"), do: "waiting for DNS"
  def state(state), do: Refusal.shown(state)

  # The result printed, then exit 1 while a mapping is not right, as `ehosctl doctor` does.
  defp right_or_1(output, true, _parsed), do: {:ok, output}

  defp right_or_1(output, false, parsed),
    do: tap(1, fn _ -> Output.result(output, parsed.flags[:json] == true) end)

  defp active?(mapping), do: mapping["state"] == @active

  defp path(domain) when Api.is_nameless(domain),
    do:
      {:error, :invalid,
       "#{Refusal.shown(domain)} is not a domain. Give a domain such as ledger.client.example."}

  defp path(domain), do: {:ok, "/api/v1/domains/" <> Api.segment(domain)}

  defp listed([], _installation),
    do:
      "No domain is mapped. A domain shows here when a person maps it with `ehosctl domains " <>
        "map` or on the Domains page of the console."

  defp listed(domains, installation) do
    rows =
      for mapping <- domains do
        %{
          "DOMAIN" => Refusal.shown(mapping["name"]),
          "APPLICATION" => Refusal.shown(mapping["application"]),
          "ENVIRONMENT" => Refusal.shown(mapping["environment"]),
          "ENTRY" => Refusal.shown(mapping["entry"]),
          "STATE" => state(mapping["state"])
        }
      end

    table = Output.table(rows, ~w(DOMAIN APPLICATION ENVIRONMENT ENTRY STATE))

    case Enum.reject(domains, &active?/1) do
      [] -> table
      [one] -> table <> "\n" <> not_active(one["name"], installation)
      _more -> table <> "\n" <> not_active("<domain>", installation)
    end
  end

  defp not_active(domain, installation),
    do:
      "A domain that is not active does not show its application yet. " <>
        "`ehosctl domains show #{shown_arg(domain)}` says what to change, as does " <>
        "#{console(installation, domain)}."

  defp mapped(mapping, installation),
    do:
      "Mapped #{Refusal.shown(mapping["name"])} to #{place(mapping)}.\n\n" <>
        "Make this DNS record at the DNS provider of the domain:\n\n" <>
        record_table(mapping["record"]) <>
        "\n\nEHOS checks the record, then gets a certificate for the domain. " <>
        "`ehosctl domains show #{shown_arg(mapping["name"])}` shows the state, as does " <>
        "#{console(installation, mapping["name"])}. The guide says how to make a record: " <>
        @guide

  defp removed(mapping),
    do:
      "Removed the mapping of #{Refusal.shown(mapping["name"])} to #{place(mapping)}. You can " <>
        "remove its DNS record at the DNS provider of the domain."

  defp shown(mapping, installation) do
    name = mapping["name"]

    [
      "#{Refusal.shown(name)}: #{state(mapping["state"])}",
      "Shows #{place(mapping)}. Mapped by #{Refusal.shown(mapping["mapped_by"])}, " <>
        "#{date(mapping["mapped_at"])}.",
      "",
      "The DNS record at the DNS provider of the domain:",
      "",
      record_table(mapping["record"]),
      "",
      checked(mapping),
      named_by(mapping),
      if(active?(mapping),
        do: nil,
        else:
          "\n#{console_capital(installation, name)} shows the same. The guide says how to make " <>
            "a record: " <> @guide
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp place(mapping),
    do:
      "#{Refusal.shown(mapping["application"])} in #{Refusal.shown(mapping["environment"])}, " <>
        "entry #{Refusal.shown(mapping["entry"])}"

  defp record_table(record),
    do:
      Output.table(
        [
          %{
            "NAME" => Refusal.shown(record["name"]),
            "TYPE" => Refusal.shown(record["type"]),
            "VALUE" => Refusal.shown(record["value"])
          }
        ],
        ~w(NAME TYPE VALUE)
      )

  defp checked(%{"check" => nil} = mapping),
    do: "EHOS has not checked the record yet." <> next_check(mapping["next_check_at"])

  defp checked(%{"check" => check, "record" => record} = mapping),
    do:
      "Last check, #{date(mapping["checked_at"])}: #{check_said(check, record)}" <>
        next_check(mapping["next_check_at"])

  defp next_check(nil), do: ""
  defp next_check(at), do: " Next check: #{date(at)}."

  defp check_said(%{"outcome" => "agrees"}, _record), do: "the record is correct."

  # eh-os docs/installation-api.md: `unknown` says the check could not tell, not that it is wrong.
  defp check_said(%{"outcome" => "unknown"} = check, _record),
    do:
      "EHOS could not tell if the record is correct" <>
        if(is_binary(check["error"]), do: " (#{Refusal.shown(check["error"])}).", else: ".") <>
        " EHOS asks again."

  # A key EHOS leaves out reads as null, as `mapping?/1` accepts it.
  defp check_said(check, record),
    do: reason_said(check["reason"], found(check["found"]), check["error"], record)

  defp reason_said("missing", _found, _error, record),
    do: "the name servers give no record at #{Refusal.shown(record["name"])}. Make the record."

  defp reason_said("other_target", found, _error, _record),
    do: "the name servers give a CNAME to #{found}. Change it to the value of the record above."

  defp reason_said("not_cname", found, _error, record),
    do:
      "the name servers give other records at #{Refusal.shown(record["name"])}: #{found}. " <>
        "Remove them, and make the CNAME."

  defp reason_said("edge_address", found, _error, record),
    do:
      "#{edge(record)} has the address #{found}, which is not the address of the server. " <>
        "Remove the record of your own at #{edge(record)}: the records of the installation " <>
        "give its address."

  defp reason_said("aaaa", found, _error, record),
    do:
      "#{edge(record)} has an AAAA record, #{found}. Remove it: the server answers on IPv4 " <>
        "alone."

  defp reason_said("apex", _found, _error, record),
    do:
      "#{Refusal.shown(record["name"])} is the apex of a zone, which cannot hold a CNAME. " <>
        "Remove this mapping, and map a name under it."

  defp reason_said("no_answer", _found, error, _record),
    do: "no name server answered (#{Refusal.shown(error || "no reason given")}). EHOS asks again."

  defp reason_said(reason, found, _error, _record),
    do:
      "the record is not correct (#{Refusal.shown(reason || "no reason given")})" <>
        if(found == "", do: ".", else: ": the name servers give #{found}.")

  defp found(found) when is_list(found), do: Enum.map_join(found, ", ", &Refusal.shown/1)
  defp found(_none), do: ""

  # The CNAME's value, `edge.<host>.`, without its last dot.
  defp edge(record), do: record["value"] |> String.trim_trailing(".") |> Refusal.shown()

  defp named_by(%{"named_by" => [_ | _] = named, "entry" => entry} = mapping),
    do:
      "\nApplications that name #{Refusal.shown(mapping["application"])} in " <>
        "#{Refusal.shown(mapping["environment"])}: " <>
        Enum.map_join(named, ", ", &Refusal.shown/1) <>
        ". They reach it at its own address, which does not answer while the entry " <>
        "#{Refusal.shown(entry)} is mapped."

  defp named_by(_mapping), do: nil

  defp date(nil), do: "at a time EHOS does not give"

  defp date(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> Output.date(datetime)
      _other -> Refusal.shown(at)
    end
  end

  defp console({_name, installation}, domain),
    do: "the console at #{installation["url"]}/domains/#{shown_arg(domain)}"

  defp console_capital({_name, installation}, domain),
    do: "The console at #{installation["url"]}/domains/#{shown_arg(domain)}"

  defp shown_arg(domain), do: Refusal.shown(domain)

  defp confirmed(_domain, true), do: :ok

  defp confirmed(domain, false) do
    question =
      "Remove the mapping of #{Refusal.shown(domain)}? The application stops answering at " <>
        "the domain."

    case confirm(question) do
      true ->
        :ok

      false ->
        {:error, :invalid, "You did not confirm, so nothing was removed."}

      nil ->
        {:error, :invalid,
         "Nothing was removed: ehosctl asks before it removes the mapping of " <>
           "#{Refusal.shown(domain)}, and nobody can answer here. Answer on a terminal, or " <>
           "give --yes."}
    end
  end

  # `nil` where nobody can answer: stdin and stderr are not both a terminal.
  defp confirm(question) do
    terminal = Terminal.current()

    if terminal.input_terminal?() and terminal.error_terminal?() do
      IO.write(:stderr, question <> " [y/N] ")
      yes?(terminal.gets(""))
    end
  end

  defp yes?(answer) when is_binary(answer),
    do: String.downcase(String.trim(answer)) in ["y", "yes"]

  defp yes?(_eof), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # What a mapping is (eh-os `docs/installation-api.md`); fields a later EHOS adds are dropped,
  # and a state is any text, since a later EHOS adds states.
  defp mapping?(%{"record" => record, "check" => check, "named_by" => named_by} = mapping) do
    Enum.all?(~w(name application environment entry state), &text?(mapping[&1])) and
      record?(record) and check?(check) and is_list(named_by) and
      Enum.all?(named_by, &is_binary/1) and
      Enum.all?(~w(mapped_by mapped_at checked_at next_check_at), &nil_or_text?(mapping[&1]))
  end

  defp mapping?(_mapping), do: false

  defp record?(%{} = record), do: Enum.all?(~w(name type value), &text?(record[&1]))
  defp record?(_record), do: false

  defp check?(nil), do: true

  defp check?(%{"outcome" => outcome} = check) when is_binary(outcome),
    do:
      nil_or_text?(check["reason"]) and nil_or_text?(check["error"]) and
        (is_nil(check["found"]) or
           (is_list(check["found"]) and Enum.all?(check["found"], &is_binary/1)))

  defp check?(_check), do: false

  defp text?(value), do: is_binary(value) and value != ""
  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp only(mapping) do
    mapping
    |> Map.take(@fields)
    |> Map.update!("record", &Map.take(&1, ~w(name type value)))
    |> Map.update!("check", fn
      nil -> nil
      check -> Map.take(check, ~w(outcome reason found error))
    end)
  end
end

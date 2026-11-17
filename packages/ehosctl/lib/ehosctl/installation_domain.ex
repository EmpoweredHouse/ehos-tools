defmodule Ehosctl.InstallationDomain do
  @moduledoc """
  `ehosctl status domain`: the DNS records that an installation with public certificates
  needs at the company's DNS provider, each with its state at the company's name servers from
  EHOS's last check and what to change, through EHOS's API (eh-os
  [`docs/installation-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/installation-api.md),
  [D-162](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0162-the-governance-plane-checks-the-company-s-dns-records-at-its-name-servers-over-port-53-of-public-addresses-learns-their-values-from-the-installer-and-lists-the-addresses-certificates.md)), as the console's
  page of the installation's domain shows them. With `--check`, EHOS checks the records first.

  It needs one of the platform capabilities. It prints what it reads, then exits 1 while a record
  is not there or EHOS reports a problem, so a pipeline can wait for the records. A state this
  `ehosctl` does not know is printed as EHOS gives it. No message says how a DNS provider takes a
  record: each points to the console's page, and to the guide in eh-os's `docs/INSTALLING.md`.
  """

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @path "/api/v1/installation/domain"
  @guide "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#make-the-dns-records-for-public-certificates"
  @fields ~w(host public_certificates known zone servers checked_at checked_by error records
             problems addresses)
  @record_fields ~w(name type value purpose without state found advice)

  @doc "The declaration of `ehosctl status domain`, for `Ehosctl.Status`."
  @spec spec() :: keyword()
  def spec,
    do: [
      name: "domain",
      about:
        "Show the DNS records that the installation needs at your DNS provider, their state " <>
          "at the last check, and what to change. Exits 1 while a record is not right.",
      flags:
        [
          check: [
            long: "--check",
            help: "Check the records now, then show them. EHOS checks at most once a minute."
          ]
        ] ++ Output.json_flag()
    ]

  @doc "Runs `ehosctl status domain`. `opts` are those a command is handed."
  @spec call(Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call(parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, body} <- reading(installation, parsed.flags.check, opts),
         true <- reading?(body) || Api.unexpected(installation),
         :ok <- known(body) do
      reading = only(body)

      %{text: shown(reading, installation), json: reading}
      |> right_or_1(right?(reading), parsed)
    end
  end

  # The reading printed, then exit 1 while a record is not right, as `ehosctl doctor` does.
  defp right_or_1(output, true, _parsed), do: {:ok, output}

  defp right_or_1(output, false, parsed),
    do: tap(1, fn _ -> Output.result(output, parsed.flags[:json] == true) end)

  @doc """
  A record's state as a person reads it. One this `ehosctl` does not know is shown as EHOS gives
  it.

      iex> Ehosctl.InstallationDomain.state("other")
      "other value"

      iex> Ehosctl.InstallationDomain.state("pending")
      "pending"
  """
  @spec state(String.t()) :: String.t()
  def state("there"), do: "there"
  def state("missing"), do: "missing"
  def state("other"), do: "other value"
  def state("cname"), do: "CNAME"
  def state("unchecked"), do: "not checked"
  def state(state), do: Refusal.shown(state)

  defp reading(installation, true, opts) do
    case Api.answer(installation, :post, @path <> "/check", nil, opts) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, answer} -> Api.refusal(answer, installation)
      {:error, kind, message, :sent} -> {:error, kind, message}
      error -> error
    end
  end

  defp reading(installation, _check, opts), do: Api.read(installation, @path, opts)

  defp known(%{"public_certificates" => true, "known" => false}),
    do:
      {:error, :failed,
       "EHOS does not know the values of the DNS records: the installer did not give them. " <>
         "Run `ehosctl install` again with ehosctl 0.37.0 or later."}

  defp known(_reading), do: :ok

  # Right: no public certificates, which need no records, or each record there and no problem.
  defp right?(%{"public_certificates" => false}), do: true

  defp right?(reading),
    do: Enum.all?(reading["records"], &(&1["state"] == "there")) and reading["problems"] == []

  defp shown(%{"public_certificates" => false} = reading, _installation),
    do:
      "EHOS at #{Refusal.shown(reading["host"])} uses the certificate authority of the " <>
        "installation, so it needs no DNS records of your company."

  defp shown(reading, installation) do
    [
      "DNS records of #{Refusal.shown(reading["host"])}#{zone(reading)}",
      checked(reading),
      error(reading["error"]),
      "",
      records_table(reading["records"]),
      advice(reading),
      addresses(reading["addresses"]),
      footer(right?(reading), installation)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp zone(%{"zone" => zone, "servers" => [_ | _] = servers}) when is_binary(zone),
    do:
      ", in the zone #{Refusal.shown(zone)}, at the name servers " <>
        Enum.map_join(servers, ", ", &Refusal.shown/1) <> "."

  defp zone(_reading), do: "."

  # A key EHOS leaves out reads as null, as `reading?/1` accepts it.
  defp checked(reading), do: checked(reading["checked_at"], reading["checked_by"])

  defp checked(nil, _by), do: "EHOS has not checked the records yet."
  defp checked(at, nil), do: "Last check: #{date(at)}, the daily check of EHOS."
  defp checked(at, by), do: "Last check: #{date(at)}, asked by #{Refusal.shown(by)}."

  defp error(nil), do: nil
  defp error(error), do: "The check did not get an answer: #{Refusal.shown(error)}"

  defp records_table([]), do: "EHOS gives no records."

  defp records_table(records),
    do:
      records
      |> Enum.map(
        &%{
          "NAME" => Refusal.shown(&1["name"]),
          "TYPE" => Refusal.shown(&1["type"]),
          "VALUE" => Refusal.shown(&1["value"]),
          "STATE" => state(&1["state"])
        }
      )
      |> Output.table(~w(NAME TYPE VALUE STATE))

  defp advice(reading) do
    lines =
      for(
        %{"advice" => said} = record <- reading["records"],
        is_binary(said),
        do:
          "#{Refusal.shown(record["name"])} #{Refusal.shown(record["type"])}: #{shown_text(said)}"
      ) ++
        for %{"advice" => said} <- reading["problems"], is_binary(said), do: shown_text(said)

    if lines == [],
      do: nil,
      else: "\nWhat to change:\n" <> Enum.map_join(lines, "\n", &("- " <> &1))
  end

  defp addresses("unavailable"),
    do: "\nEHOS cannot read the certificates of the addresses of the applications now."

  defp addresses([]), do: nil

  defp addresses(addresses),
    do:
      "\nAddresses of applications without a certificate yet:\n\n" <>
        Output.table(
          Enum.map(
            addresses,
            &%{
              "ADDRESS" => Refusal.shown(&1["name"]),
              "REASON" => Refusal.shown(&1["reason"] || ""),
              "MESSAGE" => Refusal.shown(&1["message"] || "")
            }
          ),
          ~w(ADDRESS REASON MESSAGE)
        )

  defp footer(true, _installation), do: nil

  defp footer(false, {_name, installation}),
    do:
      "\nThe console shows the same at #{installation["url"]}/installation/domain. The guide " <>
        "says how to make each record at your DNS provider: " <> @guide

  # EHOS builds advice from what the name servers give: one with a line break is quoted, so it
  # cannot print a line that reads as ehosctl's own.
  defp shown_text(text), do: Refusal.shown(text)

  defp date(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> Output.date(datetime)
      _other -> Refusal.shown(at)
    end
  end

  # What a reading is (eh-os `docs/installation-api.md`): anything else is an answer `ehosctl`
  # cannot read. Fields a later EHOS adds are dropped, and a state is any text.
  defp reading?(%{"host" => host, "public_certificates" => public, "known" => known} = body)
       when is_binary(host) and is_boolean(public) and is_boolean(known) do
    Enum.all?(~w(zone checked_at checked_by error), &nil_or_text?(body[&1])) and
      texts_or_nil?(body["servers"]) and list_of?(body["records"], &record?/1) and
      list_of?(body["problems"], &problem?/1) and
      (body["addresses"] == "unavailable" or list_of?(body["addresses"], &address?/1))
  end

  defp reading?(_body), do: false

  defp record?(%{} = record),
    do:
      Enum.all?(~w(name type value state), &text?(record[&1])) and
        Enum.all?(~w(purpose without advice), &nil_or_text?(record[&1])) and
        texts_or_nil?(record["found"])

  defp record?(_record), do: false

  defp problem?(%{"kind" => kind} = problem) when is_binary(kind),
    do:
      nil_or_text?(problem["name"]) and nil_or_text?(problem["advice"]) and
        texts_or_nil?(problem["found"])

  defp problem?(_problem), do: false

  defp address?(%{"name" => name} = address) when is_binary(name),
    do: nil_or_text?(address["reason"]) and nil_or_text?(address["message"])

  defp address?(_address), do: false

  defp list_of?(list, valid?) when is_list(list), do: Enum.all?(list, valid?)
  defp list_of?(_list, _valid?), do: false

  defp texts_or_nil?(nil), do: true
  defp texts_or_nil?(texts), do: list_of?(texts, &is_binary/1)

  defp text?(value), do: is_binary(value) and value != ""
  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp only(body) do
    body
    |> Map.take(@fields)
    |> Map.update!("records", fn records -> Enum.map(records, &Map.take(&1, @record_fields)) end)
    |> Map.update!("problems", fn problems ->
      Enum.map(problems, &Map.take(&1, ~w(kind name found advice)))
    end)
    |> Map.update!("addresses", fn
      "unavailable" -> "unavailable"
      addresses -> Enum.map(addresses, &Map.take(&1, ~w(name reason message)))
    end)
  end
end

defmodule Ehosctl.TemplateServiceEntries do
  @moduledoc """
  `ehosctl env template service-entry list | set | remove | agree | withdraw`: the utility services
  that an environment template names for one application, which EHOS copies into the ephemeral
  environments of the application made from it, each from the version in force in a production
  environment, the source (eh-os
  [D-188](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0188-a-pull-request-preview-gets-each-utility-service-its-environment-template-names-for-its-application-as-a-copy-of-the-build-in-force-in-a-production-environment.md)).
  An EHOS that takes the entries before it copies services keeps them and copies nothing.

  The entries are under `/api/v1/applications/:name/templates/:template/service-entries`, as a
  template's role entries are (`Ehosctl.TemplateEntries`), so each command takes the environment
  template as its argument and the application as `--app`.

  - **The service's side** sets and removes an entry: it needs `ehos.application.deploy` over the
    utility service.
  - **The application's side** agrees to the hosts outside the installation that the service's
    version in force in the source names, withdraws that agreement, and removes an entry too (eh-os
    D-190): it needs `ehos.release.approve` over the application. `agree` sends the hosts given with `--host`,
    which must be every host the service names there now, as `list` shows them; the agreement
    covers builds no person reviewed, since a pipeline makes most ephemeral environments.

  EHOS decides and records each call, and its refusal is printed in its words.
  """

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @entry_fields ~w(service source set_by set_at hosts application_side application_agreed_by
                   application_agreed_at application_hosts)
  @sides ~w(not_needed waiting agreed)

  @doc "The declaration of `ehosctl env template service-entry`, for `Ehosctl.EnvTemplates`."
  @spec spec() :: keyword()
  def spec do
    template = [
      value_name: "TEMPLATE",
      required: true,
      help: "The name of the environment template."
    ]

    service = [
      value_name: "SERVICE",
      required: true,
      help: "The name of the utility service."
    ]

    app = [
      app: [
        long: "--app",
        value_name: "APPLICATION",
        required: true,
        help: "The name of the application that calls the utility service."
      ]
    ]

    [
      service_entry: [
        name: "service-entry",
        about:
          "List, set and remove the service entries of an environment template, and agree to " <>
            "the hosts of their services. A service entry names a utility service that the " <>
            "ephemeral environments of an application get a copy of, from a production " <>
            "environment.",
        subcommands: [
          list: [
            name: "list",
            about:
              "List the service entries that an environment template holds for an " <>
                "application, with the hosts of each service and the application's agreement.",
            args: [template: template],
            options: app,
            flags: Output.json_flag()
          ],
          set: [
            name: "set",
            about:
              "Set a service entry: the ephemeral environments of the application get a copy " <>
                "of SERVICE from the version in force in a production environment. To remove " <>
                "it, run `ehosctl env template service-entry remove`.",
            args: [template: template, service: service],
            options:
              app ++
                [
                  source: [
                    long: "--source",
                    value_name: "ENVIRONMENT",
                    required: true,
                    help: "The production environment that the copy comes from."
                  ]
                ],
            flags: Output.json_flag()
          ],
          remove: [
            name: "remove",
            about:
              "Remove a service entry from an environment template. A person who may deploy " <>
                "SERVICE, or one who may approve the releases of the application, removes it.",
            args: [template: template, service: service],
            options: app,
            flags: Output.json_flag()
          ],
          agree: [
            name: "agree",
            about:
              "Agree for the application to the hosts outside the installation that SERVICE " <>
                "sends data to from its source. The ephemeral environments run builds that no " <>
                "person reviewed, and their data reaches these hosts.",
            args: [template: template, service: service],
            options:
              app ++
                [
                  host: [
                    long: "--host",
                    value_name: "HOST:PORT",
                    multiple: true,
                    required: true,
                    help:
                      "A host that SERVICE names, as `ehosctl env template service-entry list` " <>
                        "shows it. Repeat for each host. EHOS refuses the agreement if the " <>
                        "hosts are not all the hosts that SERVICE names now."
                  ]
                ],
            flags: Output.json_flag()
          ],
          withdraw: [
            name: "withdraw",
            about:
              "Withdraw the agreement of the application to the hosts of SERVICE. The service " <>
                "entry stays, and copies nothing while SERVICE names a host.",
            args: [template: template, service: service],
            options: app,
            flags: Output.json_flag()
          ]
        ]
      ]
    ]
  end

  @doc """
  Runs `ehosctl env template service-entry <action>`, as `c:Ehosctl.Command.call/3` runs a
  command.
  """
  @spec call(atom(), Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call(action, parsed, opts) do
    app = parsed.options.app

    # A name that would leave its place in the path (`.`, `..`), or names nothing, is refused
    # before anything is sent: a proxy that resolves dot segments would send it elsewhere. The
    # source and the hosts go in the body, where EHOS judges them.
    in_path = [app, parsed.args.template | List.wrap(Map.get(parsed.args, :service))]

    case Enum.find(in_path, &Api.is_nameless(&1)) do
      nil ->
        run(action, {app, parsed.args.template}, parsed, opts)

      word ->
        {:error, :invalid,
         "#{Refusal.shown(word)} is not the name of an application, an environment template " <>
           "or a utility service."}
    end
  end

  defp run(:list, {app, template} = place, _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, body} <- Api.read(installation, path(place), opts),
         {:ok, entries} <- listed(body, place, installation) do
      {:ok,
       %{
         text: table(entries, place),
         json: %{application: app, template: template, service_entries: entries}
       }}
    end
  end

  defp run(:set, {app, template} = place, parsed, opts) do
    service = parsed.args.service
    source = parsed.options.source

    Api.write(
      opts,
      {:post, path(place), %{service: service, source: source}},
      [
        status: 200,
        key: "service_entry",
        valid?: &(entry?(&1) and &1["service"] == service and &1["source"] == source),
        only: &Map.take(&1, @entry_fields),
        look: look(place)
      ],
      fn entry ->
        "Set the service entry #{Refusal.shown(service)} on #{where(place)}, copied from " <>
          "#{Refusal.shown(source)}. An EHOS that copies services copies " <>
          "#{Refusal.shown(service)} into the ephemeral environments of #{Refusal.shown(app)} " <>
          "that it makes from #{Refusal.shown(template)}. #{side_said(entry, place)}"
      end
    )
  end

  defp run(:remove, {app, template} = place, parsed, opts) do
    service = parsed.args.service
    asked = %{"application" => app, "template" => template, "service" => service}

    Api.write(
      opts,
      {:delete, path(place) <> "/" <> Api.segment(service), nil},
      [
        status: 200,
        key: nil,
        valid?: &(Map.take(&1, Map.keys(asked)) == asked),
        only: &Map.take(&1, Map.keys(asked)),
        look: look(place)
      ],
      fn _answer ->
        "Removed the service entry #{Refusal.shown(service)} from #{where(place)}. A copy " <>
          "that EHOS made already stays until the next deployment of #{Refusal.shown(app)} " <>
          "there."
      end
    )
  end

  defp run(action, place, parsed, opts) when action in [:agree, :withdraw] do
    service = parsed.args.service
    side_path = path(place) <> "/" <> Api.segment(service) <> "/application"

    # EHOS compares the hosts as a set, and refuses more than a version can name: a host given
    # twice is sent once.
    request =
      if action == :agree,
        do: {:put, side_path, %{hosts: Enum.uniq(parsed.options.host)}},
        else: {:delete, side_path, nil}

    Api.write(
      opts,
      request,
      [
        status: 200,
        key: "service_entry",
        valid?:
          &(entry?(&1) and &1["service"] == service and decided?(action, &1, parsed.options)),
        only: &Map.take(&1, @entry_fields),
        look: look(place),
        refused: &side_refused(&1, place)
      ],
      fn entry -> side_decided(action, entry, place) end
    )
  end

  # Agreed to the hosts sent, and no others.
  defp decided?(:agree, entry, %{host: hosts}),
    do:
      entry["application_side"] == "agreed" and
        MapSet.new(entry["application_hosts"]) == MapSet.new(hosts)

  defp decided?(:withdraw, entry, _options), do: entry["application_agreed_at"] == nil

  defp side_decided(:agree, entry, {app, template}),
    do:
      "Agreed for #{Refusal.shown(app)} to the hosts of #{Refusal.shown(entry["service"])} " <>
        "on the environment template #{Refusal.shown(template)}: " <>
        "#{hosts(entry["application_hosts"])}. The copies in its ephemeral environments can " <>
        "send data to these hosts."

  defp side_decided(:withdraw, entry, {app, template} = place),
    do:
      "Withdrew the agreement of #{Refusal.shown(app)} to the hosts of " <>
        "#{Refusal.shown(entry["service"])} on the environment template " <>
        "#{Refusal.shown(template)}. #{side_said(entry, place)}"

  # EHOS says to read the hosts again; the command that reads them.
  defp side_refused(%{"error" => "hosts_changed"}, place), do: " #{look(place)} lists them."
  defp side_refused(_body, _place), do: nil

  defp side_said(%{"application_side" => "not_needed"}, _place),
    do: "The service names no host outside the installation, so no other agreement is needed."

  defp side_said(%{"application_side" => "agreed"}, _place),
    do: "The application's agreement to the hosts of the service holds."

  defp side_said(%{"application_side" => "waiting", "service" => service}, {app, template}),
    do:
      "The service names hosts outside the installation, so the entry copies nothing until a " <>
        "person who may approve the releases of #{Refusal.shown(app)} runs `ehosctl env " <>
        "template service-entry agree #{Refusal.shown(template)} #{Refusal.shown(service)} " <>
        "--app #{Refusal.shown(app)} --host …`."

  defp path({app, template}),
    do:
      "/api/v1/applications/#{Api.segment(app)}/templates/#{Api.segment(template)}" <>
        "/service-entries"

  defp look({app, template}),
    do:
      "`ehosctl env template service-entry list #{Refusal.shown(template)} --app " <>
        "#{Refusal.shown(app)}`"

  defp where({app, template}),
    do: "the environment template #{Refusal.shown(template)} for #{Refusal.shown(app)}"

  # The application and the environment template asked for, and no other.
  defp listed(
         %{"application" => app, "template" => template, "service_entries" => entries},
         {app, template},
         installation
       )
       when is_list(entries) do
    if Enum.all?(entries, &entry?/1),
      do: {:ok, Enum.map(entries, &Map.take(&1, @entry_fields))},
      else: Api.unexpected(installation)
  end

  defp listed(_body, _place, installation), do: Api.unexpected(installation)

  # `set_by` and `application_agreed_by` are null for a person EHOS no longer names.
  defp entry?(%{"service" => service, "source" => source} = entry)
       when is_binary(service) and is_binary(source),
       do:
         moment?(entry["set_at"]) and name?(entry["set_by"]) and
           name?(entry["application_agreed_by"]) and hosts?(entry["hosts"]) and
           hosts?(entry["application_hosts"]) and entry["application_side"] in @sides and
           (is_nil(entry["application_agreed_at"]) or moment?(entry["application_agreed_at"]))

  defp entry?(_entry), do: false

  defp name?(name), do: is_nil(name) or is_binary(name)

  defp hosts?(hosts) when is_list(hosts), do: Enum.all?(hosts, &(is_binary(&1) and &1 != ""))
  defp hosts?(_hosts), do: false

  defp moment?(at) when is_binary(at), do: match?({:ok, _at, _offset}, DateTime.from_iso8601(at))
  defp moment?(_at), do: false

  defp table([], {app, template}),
    do:
      "The environment template #{Refusal.shown(template)} holds no service entries for " <>
        "#{Refusal.shown(app)}. Run `ehosctl env template service-entry set " <>
        "#{Refusal.shown(template)} SERVICE --app #{Refusal.shown(app)} --source ENVIRONMENT` " <>
        "to add one."

  defp table(entries, _place) do
    entries
    |> Enum.map(fn entry ->
      %{
        "SERVICE" => Refusal.shown(entry["service"]),
        "SOURCE" => Refusal.shown(entry["source"]),
        "HOSTS" => hosts(entry["hosts"]),
        "APPLICATION'S SIDE" => side(entry["application_side"]),
        "SET BY" => Refusal.named(entry["set_by"]),
        "SET AT" => Output.date(entry["set_at"])
      }
    end)
    |> Output.table(["SERVICE", "SOURCE", "HOSTS", "APPLICATION'S SIDE", "SET BY", "SET AT"])
  end

  defp side("not_needed"), do: "not needed"
  defp side(side), do: side

  defp hosts([]), do: "none"
  defp hosts(hosts), do: Enum.map_join(hosts, ", ", &Refusal.shown/1)
end

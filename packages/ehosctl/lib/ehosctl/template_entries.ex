defmodule Ehosctl.TemplateEntries do
  @moduledoc """
  `ehosctl env template role-entry list | set | remove` and
  `ehosctl env template people show | agree | withdraw`: what an environment template holds for
  one application about who may use an ephemeral environment made from it, through EHOS's API
  (eh-os
  [D-161](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0161-an-ephemeral-environment-gets-role-bindings-and-a-people-agreement-from-what-its-environment-template-holds-for-its-application-each-set-by-whoever-could-give-it.md),
  eh-os#1298), as the console's Environment templates page manages it.

  A role entry is a person and a role of the application; a people agreement given in advance
  lets the application read the people in such an environment. Both are under
  `/api/v1/applications/:name/templates/:template`, as an application's secret defaults on an
  environment template are (`Ehosctl.Secrets`), so each command takes the environment template as
  its argument and the application as `--app`. Role entries need `ehos.role_binding.manage` over
  the application, and the people agreement `ehos.people.manage` at the whole platform. EHOS
  decides and records each call, and its refusal is printed in its words.

  A person is named as `ehosctl role-bindings bind --to` names one: by their email, looked up
  among whom the Role bindings page offers, or by their id (`Ehosctl.RoleBindings.person/2`). A
  role entry is named by the id `role-entry list` prints.

  `ehosctl env create --no-role-bindings` and `ehosctl deploy --create-env --no-role-bindings`
  make an ephemeral environment without what its environment template holds here
  (`Ehosctl.Env.create_ephemeral/6`).
  """

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.RoleBindings

  require Ehosctl.Api

  @entry_fields ~w(id person role set_at)
  @listed_fields ~w(id person person_email role set_by set_at)
  @agreement_fields ~w(agreed_by_id agreed_at)

  @doc """
  The declarations of `ehosctl env template role-entry` and `ehosctl env template people`, for
  `Ehosctl.EnvTemplates`'s subcommands.
  """
  @spec spec() :: keyword()
  def spec do
    template = [
      value_name: "TEMPLATE",
      required: true,
      help: "The name of the environment template."
    ]

    app = [
      app: [
        long: "--app",
        value_name: "APPLICATION",
        required: true,
        help: "The name of the application."
      ]
    ]

    [
      role_entry: [
        name: "role-entry",
        about:
          "List, set and remove the role entries of an environment template. A role entry is " <>
            "a person and a role of an application, for the ephemeral environments of the " <>
            "application made from the environment template.",
        subcommands: [
          list: [
            name: "list",
            about: "List the role entries that an environment template holds for an application.",
            args: [template: template],
            options: app,
            flags: Output.json_flag()
          ],
          set: [
            name: "set",
            about:
              "Set a role entry: a person and a role of the application. To remove it, run " <>
                "`ehosctl env template role-entry remove`.",
            args: [
              template: template,
              role: [
                value_name: "ROLE",
                required: true,
                help: "The role of the application, written APPLICATION.NAME."
              ]
            ],
            options:
              app ++
                [
                  to: [
                    long: "--to",
                    value_name: "WHO",
                    required: true,
                    help: "The email or the id of the person."
                  ]
                ],
            flags: Output.json_flag()
          ],
          remove: [
            name: "remove",
            about: "Remove a role entry from an environment template.",
            args: [
              template: template,
              entry: [
                value_name: "ENTRY",
                required: true,
                help:
                  "The id of the role entry, as `ehosctl env template role-entry list` shows it."
              ]
            ],
            options: app,
            flags: Output.json_flag()
          ]
        ]
      ],
      people: [
        name: "people",
        about:
          "Show, give and withdraw a people agreement that an environment template holds for " <>
            "an application, given in advance for its ephemeral environments.",
        subcommands: [
          show: [
            name: "show",
            about:
              "Show if an environment template holds a people agreement for an application, " <>
                "and who gave it.",
            args: [template: template],
            options: app,
            flags: Output.json_flag()
          ],
          agree: [
            name: "agree",
            about:
              "Give a people agreement in advance: the application can read the people in its " <>
                "ephemeral environments made from the environment template.",
            args: [template: template],
            options: app,
            flags: Output.json_flag()
          ],
          withdraw: [
            name: "withdraw",
            about:
              "Withdraw the people agreement that an environment template holds for an " <>
                "application.",
            args: [template: template],
            options: app,
            flags: Output.json_flag()
          ]
        ]
      ]
    ]
  end

  @doc """
  Runs `ehosctl env template <group> <action>`, `group` being `:role_entry` or `:people`, as
  `c:Ehosctl.Command.call/3` runs a command.
  """
  @spec call(:role_entry | :people, atom(), Optimus.ParseResult.t(), keyword()) ::
          Ehosctl.Command.result()
  def call(group, action, parsed, opts) do
    app = parsed.options.app

    # A name that would leave its place in the path (`.`, `..`), or names nothing, is refused
    # before anything is sent: a proxy that resolves dot segments would send it elsewhere. A role
    # goes in the body, where EHOS judges it.
    in_path = [app, parsed.args.template | List.wrap(Map.get(parsed.args, :entry))]

    case Enum.find(in_path, &Api.is_nameless(&1)) do
      nil ->
        run(group, action, {app, parsed.args.template}, parsed, opts)

      word ->
        {:error, :invalid,
         "#{Refusal.shown(word)} is not the name of an application, an environment template " <>
           "or a role entry."}
    end
  end

  defp run(:role_entry, :list, {app, template} = place, _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, body} <- Api.read(installation, path(place) <> "/role-entries", opts),
         {:ok, entries} <- listed(body, place, installation) do
      {:ok,
       %{
         text: table(entries, place),
         json: %{application: app, template: template, role_entries: entries}
       }}
    end
  end

  defp run(:role_entry, :set, {app, template} = place, parsed, opts) do
    role = parsed.args.role

    with {:ok, person} <- RoleBindings.person(parsed.options.to, opts) do
      Api.write(
        opts,
        {:post, path(place) <> "/role-entries", %{person: person.id, role: role}},
        [
          status: 201,
          key: "role_entry",
          valid?: &(entry?(&1) and same_id?(&1["person"], person.id) and &1["role"] == role),
          only: &Map.take(&1, @entry_fields),
          look: look(place)
        ],
        fn entry ->
          "Set the role entry #{Refusal.shown(entry["role"])} for #{person.shown} on " <>
            "#{where(place)}: role entry #{Refusal.shown(entry["id"])}. The ephemeral " <>
            "environments of #{Refusal.shown(app)} that EHOS makes from " <>
            "#{Refusal.shown(template)} from now on give #{person.shown} this role."
        end
      )
    end
  end

  defp run(:role_entry, :remove, {_app, template} = place, parsed, opts) do
    id = parsed.args.entry

    Api.write(
      opts,
      {:delete, path(place) <> "/role-entries/" <> Api.segment(id), nil},
      [
        status: 200,
        key: "role_entry",
        # The role entry asked for, and no other, is what EHOS says it removed: a UUID, which
        # EHOS reads in either case.
        valid?: &(entry?(&1) and same_id?(&1["id"], id)),
        only: &Map.take(&1, @entry_fields),
        look: look(place)
      ],
      fn entry ->
        "Removed the role entry #{Refusal.shown(entry["role"])}, #{Refusal.shown(entry["id"])}, " <>
          "from #{where(place)}. The ephemeral environments that EHOS makes from " <>
          "#{Refusal.shown(template)} from now on do not get it. #{kept()}"
      end
    )
  end

  defp run(:people, :show, {app, template} = place, _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, body} <- Api.read(installation, path(place) <> "/people", opts),
         {:ok, agreement} <- held(body, place, installation) do
      {:ok,
       %{
         text: agreement_said(agreement, place),
         json: %{application: app, template: template, people_agreement: agreement}
       }}
    end
  end

  defp run(:people, :agree, {app, template} = place, _parsed, opts),
    do:
      decide(opts, :post, place, fn %{"people_agreement" => agreement} ->
        agreement_said(agreement, place) <>
          " The ephemeral environments of #{Refusal.shown(app)} that EHOS makes " <>
          "from #{Refusal.shown(template)} from now on get a people agreement."
      end)

  defp run(:people, :withdraw, {_app, template} = place, _parsed, opts),
    do:
      decide(opts, :delete, place, fn _answer ->
        "Withdrew the people agreement from #{where(place)}. The ephemeral environments that " <>
          "EHOS makes from #{Refusal.shown(template)} from now on get no people " <>
          "agreement from it. #{kept()}"
      end)

  # EHOS answers a people agreement given or withdrawn as it answers `GET`, with the application
  # and the environment template: it is taken only for the ones asked for.
  defp decide(opts, method, {app, template} = place, said) do
    Api.write(
      opts,
      {method, path(place) <> "/people", nil},
      [
        status: 200,
        key: nil,
        valid?: &(asked?(&1, place) and given?(&1["people_agreement"])),
        only: fn answer ->
          %{
            "application" => app,
            "template" => template,
            "people_agreement" => only_agreement(answer["people_agreement"])
          }
        end,
        look: "`ehosctl env template people show #{shown_place(place)}`"
      ],
      said
    )
  end

  defp asked?(%{"application" => app, "template" => template}, {app, template}), do: true
  defp asked?(_answer, _place), do: false

  defp kept, do: "The environments made already keep what they got."

  defp path({app, template}),
    do: "/api/v1/applications/#{Api.segment(app)}/templates/#{Api.segment(template)}"

  defp look(place), do: "`ehosctl env template role-entry list #{shown_place(place)}`"

  defp shown_place({app, template}),
    do: "#{Refusal.shown(template)} --app #{Refusal.shown(app)}"

  defp where({app, _template} = place),
    do: "#{template_said(place)} for #{Refusal.shown(app)}"

  defp template_said({_app, template}),
    do: "the environment template #{Refusal.shown(template)}"

  # The application and the environment template asked for, and no other.
  defp listed(
         %{"application" => app, "template" => template, "role_entries" => entries},
         {app, template},
         installation
       )
       when is_list(entries) do
    if Enum.all?(entries, &listed?/1),
      do: {:ok, Enum.map(entries, &Map.take(&1, @listed_fields))},
      else: Api.unexpected(installation)
  end

  defp listed(_body, _place, installation), do: Api.unexpected(installation)

  # The people agreement of the application and the environment template asked for, or none.
  defp held(
         %{"application" => app, "template" => template, "people_agreement" => agreement},
         {app, template},
         installation
       ) do
    if agreement?(agreement),
      do: {:ok, only_agreement(agreement)},
      else: Api.unexpected(installation)
  end

  defp held(_body, _place, installation), do: Api.unexpected(installation)

  defp entry?(%{"id" => id, "person" => person, "role" => role} = entry),
    do: is_binary(id) and is_binary(person) and is_binary(role) and moment?(entry["set_at"])

  defp entry?(_entry), do: false

  # `set_by` is null for a person EHOS no longer names.
  defp listed?(entry),
    do:
      entry?(entry) and is_binary(entry["person_email"]) and
        (is_nil(entry["set_by"]) or is_binary(entry["set_by"]))

  defp same_id?(given, asked) when is_binary(given),
    do: String.downcase(given) == String.downcase(asked)

  defp same_id?(_given, _asked), do: false

  # None, as `GET` may answer, or one given.
  defp agreement?(nil), do: true
  defp agreement?(agreement), do: given?(agreement)

  # Who gave it and when; `agreed_by`, their email, is null for a person EHOS no longer names.
  defp given?(%{"agreed_by_id" => id} = agreement) when is_binary(id),
    do:
      moment?(agreement["agreed_at"]) and
        (is_nil(agreement["agreed_by"]) or is_binary(agreement["agreed_by"]))

  defp given?(_agreement), do: false

  defp only_agreement(nil), do: nil
  defp only_agreement(agreement), do: Map.take(agreement, ["agreed_by" | @agreement_fields])

  defp moment?(at) when is_binary(at), do: match?({:ok, _at, _offset}, DateTime.from_iso8601(at))
  defp moment?(_at), do: false

  defp agreement_said(nil, {app, template} = place),
    do:
      "The environment template #{Refusal.shown(template)} holds no people agreement for " <>
        "#{Refusal.shown(app)}. Run `ehosctl env template people agree #{shown_place(place)}` " <>
        "to give one in advance."

  defp agreement_said(agreement, {app, template}),
    do:
      "The environment template #{Refusal.shown(template)} holds a people agreement for " <>
        "#{Refusal.shown(app)}, given in advance by " <>
        "#{Refusal.shown(agreement["agreed_by"] || agreement["agreed_by_id"])} on " <>
        "#{Output.date(agreement["agreed_at"])}."

  defp table([], {app, template}),
    do:
      "The environment template #{Refusal.shown(template)} holds no role entries for " <>
        "#{Refusal.shown(app)}. Run `ehosctl env template role-entry set " <>
        "#{Refusal.shown(template)} ROLE --app #{Refusal.shown(app)} --to WHO` to add one."

  defp table(entries, _place) do
    entries
    |> Enum.map(fn entry ->
      %{
        "PERSON" => Refusal.shown(entry["person_email"]),
        "ROLE" => Refusal.shown(entry["role"]),
        "SET BY" => Refusal.named(entry["set_by"]),
        "SET AT" => Output.date(entry["set_at"]),
        "ID" => Refusal.shown(entry["id"])
      }
    end)
    |> Output.table(["PERSON", "ROLE", "SET BY", "SET AT", "ID"])
  end
end

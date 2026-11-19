defmodule Ehosctl.Resources do
  @moduledoc """
  `ehosctl resources list | show | check | classify`: the database servers an installation's
  environments may bind, through EHOS's API (eh-os
  [`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md),
  D-57, D-170), as the console's Resources pages show and classify them.

  A resource is an instance in the installation, or a database outside it, which the operator
  checks every hour. `show` prints what the last check found, line by line, and the bindings that
  name the resource; `check` prints the lines alone, and exits 1 unless the database passed, so a
  pipeline can stop on it. The groups' members come only to whoever holds `ehos.resource.manage`.

  Listing and showing need one of the platform capabilities; classifying `ehos.resource.manage`. A
  resource's class is set once. Registering a resource is not a command: it stays a platform
  operation.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Failure
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  # A classification that may have been made although its answer was lost.
  @look " EHOS possibly made the change. Run `ehosctl resources list` to see."

  @impl Ehosctl.Command
  def name, do: :resources

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :applications

  @impl Ehosctl.Command
  def summary, do: "List the resources that environments can bind."

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "List the resources that environments can bind, and set whether each serves production.",
      subcommands: [
        list: [
          name: "list",
          about: "List the resources of the installation.",
          flags: Output.json_flag()
        ],
        show: [
          name: "show",
          about:
            "Show a resource: where it is, what its last check found, and what is bound to it.",
          args: [
            resource: [value_name: "RESOURCE", required: true, help: "The name of the resource."]
          ],
          flags: Output.json_flag()
        ],
        check: [
          name: "check",
          about:
            "Print what the last check of a database outside the installation found. Exits 1 " <>
              "when the database did not pass.",
          args: [
            resource: [value_name: "RESOURCE", required: true, help: "The name of the resource."]
          ],
          flags: Output.json_flag()
        ],
        classify: [
          name: "classify",
          about:
            "Set whether a resource serves production environments. You can set it only once.",
          args: [
            resource: [value_name: "RESOURCE", required: true, help: "The name of the resource."],
            serves: [value_name: "SERVES", required: true, help: "production or non_production."]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:list], _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    case Api.answer(installation, :get, "/api/v1/resources", nil, opts) do
      {:ok, %{status: 200, body: %{"resources" => resources}}} when is_list(resources) ->
        if Enum.all?(resources, &resource?/1) do
          resources = Enum.map(resources, &only_resource/1)
          {:ok, %{text: table(resources), json: %{resources: resources}}}
        else
          Api.unexpected(installation)
        end

      {:ok, answer} ->
        Api.refusal(answer, installation)

      {:error, kind, message, :sent} ->
        {:error, kind, message}

      error ->
        error
    end
  end

  def call([command], %{args: %{resource: name}}, _opts)
      when command in [:show, :check] and Api.is_nameless(name),
      do:
        {:error, :invalid,
         "#{Refusal.shown(name)} is not the name of a resource. Run `ehosctl resources list` " <>
           "to see the resources."}

  def call([:show], parsed, opts) do
    with {:ok, resource} <- shown(parsed.args.resource, opts) do
      {:ok, %{text: shown_text(resource), json: %{resource: resource}}}
    end
  end

  # D-170: a pipeline stops on a database that did not pass; the lines are printed either way.
  def call([:check], parsed, opts) do
    with {:ok, resource} <- shown(parsed.args.resource, opts),
         do: checked(resource, parsed.flags[:json] == true)
  end

  def call([:classify], %{args: %{resource: name}}, _opts) when Api.is_nameless(name),
    do:
      {:error, :invalid,
       "#{Refusal.shown(name)} is not the name of a resource. Run `ehosctl resources list` to " <>
         "see the resources."}

  def call([:classify], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{resource: name, serves: serves} = parsed.args
    path = "/api/v1/resources/" <> Api.segment(name) <> "/classify"

    case Api.answer(installation, :post, path, %{serves: serves}, opts) do
      {:ok, %{status: 200, body: %{"resource" => resource}}} ->
        if resource?(resource) do
          resource = only_resource(resource)

          {:ok,
           %{
             text:
               "#{Refusal.shown(resource["name"])} now serves #{serves_text(resource["serves"])}.",
             json: %{resource: resource}
           }}
        else
          said_done(installation)
        end

      {:ok, %{status: 200}} ->
        said_done(installation)

      # A gateway's 5xx without EHOS's code may have come after the class was set.
      {:ok, %{status: status} = answer} when status >= 500 ->
        refused = Api.refusal(answer, installation)
        if Api.coded?(answer.body), do: refused, else: Refusal.added(refused, @look)

      {:ok, answer} ->
        Api.refusal(answer, installation)

      # Setting a class twice is refused, so sending it again tells whether it was set.
      {:error, kind, message, :sent} ->
        {:error, kind, Failure.added(message, @look)}

      error ->
        error
    end
  end

  defp checked(%{"provider" => "external"} = resource, json?) do
    output = %{text: check_text(resource), json: %{resource: resource}}
    code = if resource["state"] == "fit", do: 0, else: 1
    tap(code, fn _ -> Output.result(output, json?) end)
  end

  defp checked(resource, _json?), do: {:error, :invalid, not_checked(resource)}

  defp not_checked(%{"provider" => "cloudnativepg", "name" => name}),
    do:
      "#{Refusal.shown(name)} is a database in the installation. EHOS checks only a database " <>
        "outside the installation this way. Run `ehosctl resources show #{Refusal.shown(name)}` " <>
        "to see it."

  defp not_checked(%{"name" => name}),
    do:
      "EHOS checks only a database outside the installation this way, and " <>
        "#{Refusal.shown(name)} is not one. Run `ehosctl resources show #{Refusal.shown(name)}` " <>
        "to see it."

  defp shown(name, opts) do
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/resources/" <> Api.segment(name)

    case Api.answer(installation, :get, path, nil, opts) do
      {:ok, %{status: 200, body: %{"resource" => resource}}} ->
        if resource?(resource) and shown_parts?(resource),
          do: {:ok, only_shown(resource)},
          else: Api.unexpected(installation)

      {:ok, answer} ->
        Api.refusal(answer, installation)

      {:error, kind, message, :sent} ->
        {:error, kind, message}

      error ->
        error
    end
  end

  @doc """
  What a binding to a database outside the installation means, as a sentence that starts with a
  space, to follow what `ehosctl env bind` and `env template bind` say (eh-os D-170); `""` for any
  other binding.
  """
  @spec outside_note(map()) :: String.t()
  def outside_note(%{"provider" => "external", "resource" => resource}),
    do:
      " #{Refusal.shown(resource)} is a database outside the installation. EHOS opens no data " <>
        "session there, and a role binding of a role that grants ehos.data.read or " <>
        "ehos.data.write gives no way to its data. The administrator of the database gives a person a way in through its provider."

  def outside_note(_binding), do: ""

  defp said_done(installation) do
    {:error, kind, message} = Api.unexpected(installation)

    {:error, kind,
     Failure.added(message, " EHOS said that it set it. Run `ehosctl resources list` to see.")}
  end

  # What each field of EHOS's answer may be beside nil; a field it does not send yet is nil.
  @resource_fields [
    {"serves", :text},
    {"provider", :text},
    {"version", :integer},
    {"host", :text},
    {"port", :integer},
    {"database", :text},
    {"listed", :boolean},
    {"state", :text},
    {"checked_at", :text}
  ]

  defp resource?(%{"name" => name, "kind" => kind} = resource)
       when is_binary(name) and is_binary(kind),
       do: Enum.all?(@resource_fields, fn {field, type} -> typed?(resource[field], type) end)

  defp resource?(_resource), do: false

  defp typed?(nil, _type), do: true
  defp typed?(value, :text), do: is_binary(value)
  defp typed?(value, :integer), do: is_integer(value)
  defp typed?(value, :boolean), do: is_boolean(value)

  defp nil_or_text?(value), do: typed?(value, :text)
  defp nil_or_integer?(value), do: typed?(value, :integer)
  defp nil_or_boolean?(value), do: typed?(value, :boolean)

  @listed ~w(name kind provider version host port database listed serves state checked_at)

  defp only_resource(resource), do: Map.take(resource, @listed)

  defp shown_parts?(resource),
    do:
      (is_nil(resource["check"]) or check?(resource["check"])) and bindings?(resource["bindings"])

  defp check?(%{"lines" => lines, "groups" => groups} = check)
       when is_list(lines) and is_list(groups),
       do:
         Enum.all?(lines, &line?/1) and Enum.all?(groups, &group?/1) and
           nil_or_text?(check["message"]) and nil_or_text?(check["server_version"]) and
           nil_or_integer?(check["groups_omitted"])

  defp check?(_check), do: false

  defp line?(%{"name" => name, "passed" => passed} = line),
    do: is_binary(name) and is_boolean(passed) and nil_or_text?(line["message"])

  defp line?(_line), do: false

  defp group?(%{"name" => name, "members" => members} = group),
    do:
      is_binary(name) and is_integer(members) and
        (is_nil(group["listed"]) or
           (is_list(group["listed"]) and Enum.all?(group["listed"], &member?/1)))

  defp group?(_group), do: false

  defp member?(%{"role" => role} = member),
    do: is_binary(role) and Enum.all?(~w(admin inherit set), &nil_or_boolean?(member[&1]))

  defp member?(_member), do: false

  defp bindings?(bindings) when is_list(bindings),
    do:
      Enum.all?(
        bindings,
        &(match?(%{"environment" => environment} when is_binary(environment), &1) and
            nil_or_text?(&1["application"]) and nil_or_text?(&1["schema"]) and
            nil_or_boolean?(&1["used"]))
      )

  defp bindings?(_bindings), do: false

  # Only what the commands say, whatever else EHOS sends.
  defp only_shown(resource) do
    resource
    |> only_resource()
    |> Map.put("check", only_check(resource["check"]))
    |> Map.put(
      "bindings",
      Enum.map(resource["bindings"], &Map.take(&1, ~w(environment application schema used)))
    )
  end

  defp only_check(nil), do: nil

  defp only_check(check) do
    %{
      "message" => check["message"],
      "server_version" => check["server_version"],
      "lines" => Enum.map(check["lines"], &Map.take(&1, ~w(name passed message))),
      "groups" =>
        Enum.map(check["groups"], fn group ->
          group
          |> Map.take(~w(name members))
          |> Map.put(
            "listed",
            group["listed"] &&
              Enum.map(group["listed"], &Map.take(&1, ~w(role admin inherit set)))
          )
        end),
      "groups_omitted" => check["groups_omitted"]
    }
  end

  defp provider_text("cloudnativepg"), do: "In the installation"
  defp provider_text("external"), do: "Outside the installation"
  defp provider_text(other), do: text(other)

  defp state_text("fit"), do: "Passes"
  defp state_text("not_fit"), do: "Does not pass"
  defp state_text("not_checked"), do: "Not checked yet"
  defp state_text("unread"), do: "Cannot be read now"
  defp state_text(nil), do: ""
  defp state_text(other), do: text(other)

  defp address(%{"host" => host, "port" => port, "database" => database})
       when is_binary(host) and is_integer(port) and is_binary(database),
       do: "#{Refusal.shown(host)}:#{port}/#{Refusal.shown(database)}"

  defp address(_resource), do: ""

  # An instance, or an EHOS before the check, which answers no state.
  defp check_column(%{"state" => nil}), do: ""
  defp check_column(resource) when not is_map_key(resource, "state"), do: ""

  # A time that is not ISO 8601 is left out, never the cause of a crash of the whole list.
  defp check_column(%{"state" => state} = resource) do
    with at when is_binary(at) <- resource["checked_at"],
         {:ok, at, _offset} <- DateTime.from_iso8601(at) do
      "#{state_text(state)}, #{Output.date(at)}"
    else
      _never_or_unreadable -> state_text(state)
    end
  end

  defp shown_text(resource) do
    Output.lines([
      Output.values(
        [
          {"Resource", Refusal.shown(resource["name"])},
          {"Provider", provider_text(resource["provider"])},
          {"Where", address(resource)},
          {"Version", "PostgreSQL #{text(resource["version"])}"},
          {"Serves", serves_text(resource["serves"])},
          {"Check", check_column(resource)}
        ]
        |> Enum.reject(fn {_label, value} -> value in ["", "PostgreSQL "] end)
      ),
      unlisted(resource),
      outside(resource),
      lines_text(resource["check"]),
      groups_text(resource["check"]),
      bindings_text(resource["bindings"])
    ])
  end

  defp check_text(resource) do
    Output.lines([
      Output.outcome(
        if(resource["state"] == "fit", do: :done, else: :failed),
        "#{Refusal.shown(resource["name"])}: #{text(resource["check"]["message"])}"
      ),
      lines_text(resource["check"])
    ])
  end

  defp unlisted(%{"listed" => false}),
    do:
      Output.warning(
        "The chart no longer lists this resource.",
        "EHOS keeps it for its resource bindings and refuses a new one."
      )

  defp unlisted(_resource), do: nil

  # D-170: what EHOS does not take on there, said where the resource is shown.
  defp outside(%{"provider" => "external"}),
    do:
      "\nEHOS takes no backup of this database and does not restore it. Backups and restore are " <>
        "its provider's and the administrator's. EHOS opens no data session on it, and does not " <>
        "decide or record who reaches its data: the administrator of the database does."

  defp outside(_resource), do: nil

  defp lines_text(nil), do: nil
  defp lines_text(%{"lines" => []}), do: nil

  defp lines_text(%{"lines" => lines}) do
    lines
    |> Enum.map(fn line ->
      Output.outcome(
        if(line["passed"], do: :done, else: :failed),
        "#{Refusal.shown(line["name"])}: #{text(line["message"])}"
      )
    end)
    |> then(&["", "What the last check found:" | &1])
    |> Output.lines()
  end

  defp groups_text(nil), do: nil
  defp groups_text(%{"groups" => []}), do: nil

  defp groups_text(%{"groups" => groups} = check) do
    rows =
      Enum.map(groups, fn group ->
        %{
          "GROUP" => Refusal.shown(group["name"]),
          "MEMBERS" => Integer.to_string(group["members"]),
          "LISTED" => members_text(group["listed"])
        }
      end)

    omitted =
      if is_integer(check["groups_omitted"]) and check["groups_omitted"] > 0,
        do: "#{check["groups_omitted"]} more groups are not listed."

    Output.lines(["", Output.table(rows, ["GROUP", "MEMBERS", "LISTED"]), omitted])
  end

  defp members_text(nil), do: "(needs ehos.resource.manage)"
  defp members_text([]), do: ""
  defp members_text(listed), do: Enum.map_join(listed, ", ", &Refusal.shown(&1["role"]))

  defp bindings_text([]), do: "\nNo resource bindings name this resource."

  defp bindings_text(bindings) do
    rows =
      Enum.map(bindings, fn binding ->
        %{
          "ENVIRONMENT" => Refusal.shown(binding["environment"]),
          "APPLICATION" => text(binding["application"]),
          "SCHEMA" => text(binding["schema"])
        }
      end)

    Output.lines(["", Output.table(rows, ["ENVIRONMENT", "APPLICATION", "SCHEMA"])])
  end

  defp serves_text("production"), do: "production environments"
  defp serves_text("non_production"), do: "non-production environments"
  defp serves_text(nil), do: "(not set)"
  defp serves_text(other), do: Refusal.shown(other)

  defp table([]),
    do: "No resources. A resource shows here when an installation administrator registers it."

  defp table(resources) do
    resources
    |> Enum.map(fn resource ->
      %{
        "NAME" => Refusal.shown(resource["name"]),
        "KIND" => Refusal.shown(resource["kind"]),
        "PROVIDER" => provider_text(resource["provider"]),
        "WHERE" => address(resource),
        "VERSION" => text(resource["version"]),
        "SERVES" => serves_text(resource["serves"]),
        "CHECK" => check_column(resource)
      }
    end)
    |> Output.table(["NAME", "KIND", "PROVIDER", "WHERE", "VERSION", "SERVES", "CHECK"])
  end

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: Refusal.shown(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: ""
end

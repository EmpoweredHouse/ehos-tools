defmodule Ehosctl.Roles do
  @moduledoc """
  `ehosctl roles [--app A] [--env E]`: the roles bound to the person and to their agents, as the
  console's My roles lists them (`Ehosctl.Api.roles/2`).

  `--app` and `--env` keep the roles that hold there: those bound there, and those bound across
  every application or environment, which hold there too.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @impl Ehosctl.Command
  def name, do: :roles

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :access

  @impl Ehosctl.Command
  def summary, do: "List the roles that you and your agents hold."

  @impl Ehosctl.Command
  def spec,
    do: [
      about: "List the roles that you and your agents hold.",
      options: [
        app: [
          long: "--app",
          value_name: "APPLICATION",
          help: "Show only the roles that hold in this application."
        ],
        env: [
          long: "--env",
          value_name: "ENVIRONMENT",
          help: "Show only the roles that hold in this environment."
        ]
      ],
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{app: app, env: env} = parsed.options

    with {:ok, roles} <- Api.roles(installation, opts) do
      roles =
        Enum.filter(roles, &(holds?(&1["application"], app) and holds?(&1["environment"], env)))

      {:ok, %{text: text(roles, elem(installation, 0)), json: %{roles: roles}}}
    end
  end

  defp holds?(_bound, nil), do: true
  defp holds?(bound, asked), do: bound in [nil, asked]

  defp text([], name),
    do:
      "You and your agents hold no roles in #{name} that match. A role shows here after " <>
        "someone binds it to you or to one of your agents."

  # Columns as `ehosctl installations list` prints them: no borders.
  @columns ["ROLE", "HELD BY", "APPLICATION", "ENVIRONMENT", "NOTE"]

  defp text(roles, _name) do
    roles
    |> Enum.map(fn role ->
      %{
        "ROLE" => Refusal.shown(role["role"]),
        "HELD BY" => held_by(role["held_by"]),
        "APPLICATION" => across(role["application"]),
        "ENVIRONMENT" => across(role["environment"]),
        "NOTE" => note(role)
      }
    end)
    |> Output.table(@columns)
  end

  defp held_by(%{"kind" => "person", "name" => name}), do: Refusal.shown(name)
  defp held_by(%{"kind" => "agent", "name" => name}), do: "agent " <> Refusal.shown(name)

  defp across(nil), do: "(all)"
  defp across(name), do: Refusal.shown(name)

  defp note(role),
    do:
      [gone(role), beyond(role), granted(role), templated(role)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("; ")

  defp gone(%{"gone" => true}), do: "gone: grants nothing"
  defp gone(_role), do: ""

  defp beyond(%{"beyond_owner" => true}), do: "beyond its owner: grants only what the owner holds"
  defp beyond(_role), do: ""

  # EHOS's D-112: a role someone gave the person through their application, under their rule.
  defp granted(%{"grant" => %{"rule" => rule, "through" => through} = grant}),
    do:
      "granted by #{Refusal.shown(grant["by"] || "someone")} through #{Refusal.shown(through)}, " <>
        "under the rule of #{Refusal.shown(rule)}"

  defp granted(_role), do: ""

  # EHOS's D-161: a role an ephemeral environment got from an environment template's role entry.
  defp templated(%{"from_template" => %{"template" => template} = from}) do
    set_by =
      case from["by"] do
        nil -> ""
        by -> ", set by #{Refusal.shown(by)}"
      end

    "from the environment template #{Refusal.shown(template)}#{set_by}: no right to grant roles"
  end

  defp templated(_role), do: ""
end

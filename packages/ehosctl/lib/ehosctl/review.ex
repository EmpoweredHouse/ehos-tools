defmodule Ehosctl.Review do
  @moduledoc """
  What putting a manifest in force changes in an application's authority, as EHOS's API says it:
  its `diff` and `described`, which a version's review
  (`GET /api/v1/applications/:name/versions/:digest/review`, `ehosctl apps review`) and a
  deployment's preview (`POST /api/v1/deployments/preview`, `ehosctl deploy --preview`) give
  alike, so both are read, kept and said here once.

  `diff` names the capabilities and roles added and removed, the roles that grow or shrink, and,
  from an EHOS that reads `ehos.manifest/v5`, the roles whose grant rule widens or narrows
  (eh-os D-112), which an older EHOS leaves out and which are then none;
  `described` the roles added as they are described, and the capabilities or roles described
  otherwise under the same name, `grants_changed` those whose kind or principals change.
  """

  alias Ehosctl.Refusal

  @diff_lists ~w(capabilities_added capabilities_removed roles_added roles_removed)
  @diff_maps ~w(roles_grown roles_shrunk)
  # eh-os D-112: absent from an EHOS that predates grant rules, and then none.
  @grant_maps ~w(grants_widened grants_narrowed)

  @doc """
  Whether `answer`'s `diff` and `described` are as a version's review gives them, with every name
  in them text.

      iex> Ehosctl.Review.changes?(%{"diff" => %{}, "described" => %{}})
      false
  """
  @spec changes?(term()) :: boolean()
  def changes?(%{"diff" => %{} = diff, "described" => %{} = described}) do
    Enum.all?(@diff_lists, &names?(diff[&1])) and Enum.all?(@diff_maps, &grown?(diff[&1])) and
      Enum.all?(@grant_maps, &grown?(Map.get(diff, &1, %{}))) and
      all?(described["roles_added"], &role?/1) and
      all?(described["redescribed"], &redescribed?/1) and
      all?(described["grants_changed"], &redescribed?/1)
  end

  def changes?(_answer), do: false

  @doc """
  `answer`'s `diff` and `described`, which `changes?/1` has checked, kept to the fields read, so
  nothing else an answer holds reaches a script under `--json`.
  """
  @spec kept(map()) :: %{String.t() => map()}
  def kept(%{"diff" => diff, "described" => described}),
    do: %{
      "diff" =>
        diff
        |> Map.take(@diff_lists ++ @diff_maps)
        |> Map.merge(Map.new(@grant_maps, &{&1, Map.get(diff, &1, %{})})),
      "described" => %{
        "roles_added" => Enum.map(described["roles_added"], &role/1),
        "redescribed" => Enum.map(described["redescribed"], &redescribed/1),
        "grants_changed" => Enum.map(described["grants_changed"], &redescribed/1)
      }
    }

  @doc """
  What `answer` changes, one line for each kind of change, indented by two spaces. When it names
  none and its `authority` is `"changed"`, one line that says the authority changes all the same;
  when it names none and the authority is unchanged, none: the caller says that in its own words.

      iex> Ehosctl.Review.lines(%{
      ...>   "authority" => "changed",
      ...>   "diff" => %{"capabilities_added" => ["ledger.post"], "capabilities_removed" => [],
      ...>     "roles_added" => [], "roles_removed" => [], "roles_grown" => %{}, "roles_shrunk" => %{}},
      ...>   "described" => %{"grants_changed" => [], "redescribed" => []}
      ...> })
      ["  capabilities added: ledger.post"]
  """
  @spec lines(map()) :: [String.t()]
  def lines(answer) do
    case {changes(answer), answer["authority"]} do
      {[], "unchanged"} ->
        []

      # The authority form holds more than a review names: what a capability runs, and what of
      # the application's needs names a capability.
      {[], _changed} ->
        [
          "  No capability or role is added, removed or relabelled, but its authority " <>
            "changes: what a capability runs, or what the application needs, differs."
        ]

      {lines, _authority} ->
        lines
    end
  end

  @doc """
  The lines of what `answer` adds, removes and changes by name, and none when it names nothing:
  `lines/1` without the line that says the authority changed otherwise.
  """
  @spec named(map()) :: [String.t()]
  def named(answer), do: changes(answer)

  defp changes(%{"diff" => diff, "described" => described}) do
    Enum.reject(
      [
        list("capabilities added", diff["capabilities_added"]),
        list("capabilities removed", diff["capabilities_removed"]),
        list("roles added", diff["roles_added"]),
        list("roles removed", diff["roles_removed"]),
        grown("roles that grow, giving everyone bound to them more", diff["roles_grown"]),
        grown("roles that shrink", diff["roles_shrunk"]),
        grown(
          "roles that may grant more, letting more people in",
          Map.get(diff, "grants_widened", %{})
        ),
        grown("roles that may grant less", Map.get(diff, "grants_narrowed", %{})),
        list(
          "what a capability lets its holders do changed for",
          names(described["grants_changed"])
        ),
        list("descriptions changed for", names(described["redescribed"]))
      ],
      &is_nil/1
    )
  end

  defp list(_label, []), do: nil
  defp list(label, names), do: "  #{label}: " <> Enum.map_join(names, ", ", &Refusal.shown/1)

  defp grown(_label, roles) when map_size(roles) == 0, do: nil

  defp grown(label, roles) do
    "  #{label}: " <>
      Enum.map_join(Enum.sort(roles), "; ", fn {role, names} ->
        "#{Refusal.shown(role)} (#{Enum.map_join(names, ", ", &Refusal.shown/1)})"
      end)
  end

  defp names(changes), do: for(%{"name" => name} when is_binary(name) <- changes, do: name)

  @doc """
  Whether `role` is a role as EHOS describes one: its `name`, its `label` or `nil`, and its
  `capabilities`, each with its `name` and, beside it, its `label`, `kind` and `principals`; and,
  from an EHOS that reads `ehos.manifest/v5`, `may_grant`, the roles its holders may grant
  (eh-os D-112), which an older EHOS leaves out.

      iex> Ehosctl.Review.role?(%{"name" => "clerk", "capabilities" => [%{"name" => "ledger.post"}]})
      true

      iex> Ehosctl.Review.role?(%{"name" => "clerk"})
      false
  """
  @spec role?(term()) :: boolean()
  def role?(%{"name" => name, "capabilities" => capabilities} = role)
      when is_binary(name) and is_list(capabilities),
      do:
        nil_or_text?(role["label"]) and Enum.all?(capabilities, &capability?/1) and
          names?(Map.get(role, "may_grant", []))

  def role?(_role), do: false

  @doc "A role `role?/1` has checked, kept to the fields it reads."
  @spec role(map()) :: map()
  def role(role),
    do: %{
      "name" => role["name"],
      "label" => role["label"],
      "capabilities" =>
        Enum.map(role["capabilities"], &Map.take(&1, ~w(name label kind principals))),
      "may_grant" => Map.get(role, "may_grant", [])
    }

  defp capability?(%{"name" => name} = capability) when is_binary(name),
    do: description?(capability)

  defp capability?(_capability), do: false

  # What a capability says beside its name: its label, its kind, and the principals it serves.
  defp description?(%{} = described),
    do:
      nil_or_text?(described["label"]) and nil_or_text?(described["kind"]) and
        (is_nil(described["principals"]) or names?(described["principals"]))

  defp description?(_described), do: false

  # A capability or a role described otherwise under the same name: as it was, and as it is.
  defp redescribed?(%{"name" => name, "from" => from, "to" => to}) when is_binary(name),
    do: description?(from) and description?(to)

  defp redescribed?(_change), do: false

  defp redescribed(change),
    do: %{
      "name" => change["name"],
      "from" => Map.take(change["from"], ~w(label kind principals)),
      "to" => Map.take(change["to"], ~w(label kind principals))
    }

  defp grown?(roles),
    do:
      is_map(roles) and
        Enum.all?(roles, fn {role, names} -> is_binary(role) and names?(names) end)

  defp names?(names), do: is_list(names) and Enum.all?(names, &is_binary/1)
  defp all?(list, valid?), do: is_list(list) and Enum.all?(list, valid?)
  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)
end

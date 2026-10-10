defmodule Ehosctl.Apps do
  @moduledoc """
  `ehosctl apps`: the applications the person may use, each in an environment where they hold a
  role, with its address and what their roles grant there (`Ehosctl.Api.applications/2`). These
  are what `ehosctl credential` and `ehosctl call` reach.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @impl Ehosctl.Command
  def name, do: :apps

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about: "List the applications you may use, where they are, and what you may do there.",
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], _parsed, opts) do
    {name, _} = installation = Keyword.fetch!(opts, :installation)

    with {:ok, applications} <- Api.applications(installation, opts) do
      {:ok, %{text: text(applications, name), json: %{applications: applications}}}
    end
  end

  defp text([], name), do: "None of your roles in #{name} is bound in an application."

  defp text(applications, _name), do: Enum.map_join(applications, "\n\n", &entry/1)

  defp entry(entry) do
    heading =
      "#{Refusal.shown(entry["application"])} in #{Refusal.shown(entry["environment"])}, " <>
        "at #{entry["address"]}\n  roles: " <>
        Enum.map_join(entry["roles"], ", ", &Refusal.shown/1)

    case entry["capabilities"] do
      [] ->
        heading <> "\n  grants nothing: the role is gone, or no version is in force there"

      capabilities ->
        width = capabilities |> Enum.map(&String.length(Refusal.shown(&1["name"]))) |> Enum.max()

        lines =
          Enum.map(capabilities, fn capability ->
            name = String.pad_trailing(Refusal.shown(capability["name"]), width)
            label = if is_binary(capability["label"]), do: Refusal.shown(capability["label"])

            label =
              if Api.known_kind?(capability["kind"]),
                do: label,
                else: "#{label} (needs a later ehosctl)"

            String.trim_trailing(
              "  #{String.pad_trailing(Refusal.shown(capability["kind"]), 7)}  #{name}  #{label}"
            )
          end)

        Enum.join([heading | lines], "\n")
    end
  end
end

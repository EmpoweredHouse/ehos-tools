defmodule Ehosctl.DeploymentHistory do
  @moduledoc """
  `ehosctl apps history <application> --env E`: an application's deployments in an environment, as
  the environment's tab of the console's application page shows them (eh-os#802), read from
  `Ehosctl.Deployments`: the deployment in force, where it came from and the promotion that brought
  it, its addresses, and before it the deployments and refusals, newest first. Each deployment
  before says which came after it and what that one changed: a superseded one the deployment that
  replaced it, any other the next one decided.

  Text from EHOS goes through `Ehosctl.Refusal.shown/1`. Against an EHOS older than eh-os 0.14.0,
  a deployment says nothing of what came after it; against one with no such route, the command
  says it cannot read them there.
  """

  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Source

  # The start of an id or a digest shown, as the console shows them.
  @shown 12

  @doc "The history as text: `Ehosctl.Deployments.history/5`'s answer."
  @spec text(Ehosctl.Deployments.history()) :: String.t()
  def text(history) do
    app = Refusal.shown(history["application"])
    env = Refusal.shown(history["environment"])

    [
      in_force(history, app, env),
      before(history["before"], history["in_force"])
    ]
    |> Enum.join("\n\n")
  end

  defp in_force(%{"in_force" => nil}, app, env), do: "Nothing of #{app} is deployed in #{env}."

  defp in_force(%{"in_force" => deployment, "addresses" => addresses}, app, env) do
    source = Source.line(deployment["source"])

    [
      "In force in #{env}: #{app}'s deployment #{id(deployment["id"])}, " <>
        "#{Refusal.shown(deployment["state"])}.",
      "  image:     #{Refusal.shown(deployment["image"])}",
      source && "  source:    #{source}",
      "  manifest:  #{Refusal.shown(deployment["manifest_digest"])}",
      deployment["promotion"] && "  promotion: #{Refusal.shown(deployment["promotion"])}",
      "  deployed:  #{Refusal.shown(deployment["at"])}#{by(deployment["by"])}",
      "  address:   #{addresses(addresses)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp before([], _in_force), do: "Nothing before it."

  defp before(entries, in_force) do
    rows =
      Enum.map(entries, fn
        %{"kind" => "refused"} = refused ->
          %{
            "WHEN" => Refusal.shown(refused["at"]),
            "DEPLOYMENT" => "-",
            "IMAGE" => digest(refused["image"]),
            "OUTCOME" => "refused: " <> Refusal.shown(refused["why"]),
            "AFTER IT" => ""
          }

        deployment ->
          %{
            "WHEN" => Refusal.shown(deployment["at"]),
            "DEPLOYMENT" => id(deployment["id"]),
            "IMAGE" => digest(deployment["image"]),
            "OUTCOME" => outcome(deployment),
            "AFTER IT" => after_it(deployment, in_force)
          }
      end)

    "Before it, newest first:\n" <>
      Output.table(rows, ["WHEN", "DEPLOYMENT", "IMAGE", "OUTCOME", "AFTER IT"])
  end

  defp outcome(%{"failure" => failure, "state" => state}) when is_binary(failure),
    do: "#{Refusal.shown(state)}: #{Refusal.shown(failure)}"

  defp outcome(%{"state" => state} = deployment) do
    case deployment["promotion"] do
      nil -> Refusal.shown(state)
      promotion -> "#{Refusal.shown(state)}, promoted by #{id(promotion)}"
    end
  end

  # eh-os#802: none from an older EHOS, or for the newest listed.
  defp after_it(%{"next" => %{} = next} = deployment, in_force) do
    named =
      if in_force && in_force["id"] == next["id"],
        do: "the deployment in force",
        else: id(next["id"])

    "#{followed(deployment)} #{named}: #{changed(next)}"
  end

  defp after_it(_deployment, _in_force), do: ""

  defp followed(%{"state" => "superseded"}), do: "replaced by"
  defp followed(_deployment), do: "followed by"

  defp changed(%{"changed" => []}), do: "the same image, manifest and secrets"

  defp changed(%{"changed" => changed, "secrets" => secrets}) do
    Enum.map_join(changed, ", ", fn
      "image" -> "a new image"
      "manifest" -> "a new manifest"
      "secrets" when secrets == [] -> "new versions of secrets"
      "secrets" -> "new versions of " <> Enum.map_join(secrets, ", ", &Refusal.shown/1)
    end)
  end

  defp by(nil), do: ""
  defp by(by), do: " by " <> Refusal.shown(by)

  defp addresses([]), do: "none: it serves nothing public"
  defp addresses(addresses), do: Enum.map_join(addresses, ", ", &Refusal.shown/1)

  defp id(id) when is_binary(id), do: Refusal.shown(String.slice(id, 0, @shown))
  defp id(_id), do: "-"

  # The digest is the record; the repository is in the whole image.
  defp digest(image) when is_binary(image) do
    case String.split(image, "@sha256:", parts: 2) do
      [_repository, hex] -> Refusal.shown("sha256:" <> String.slice(hex, 0, @shown))
      _other -> Refusal.shown(image)
    end
  end

  defp digest(_image), do: "-"
end

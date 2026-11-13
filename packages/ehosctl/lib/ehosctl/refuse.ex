defmodule Ehosctl.Refuse do
  @moduledoc """
  `ehosctl refuse <id> --reason <text>`: refuses a promotion that waits, with a reason, as the
  console's review does (eh-os
  [`docs/promotions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/promotions-api.md),
  [D-105](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0105-production-is-reached-only-by-promoting-a-candidate-and-a-promotion-is-a-record-of-its-own-approved-by-the-application-s-process-owner.md)).

  It sends `POST /api/v1/promotions/:id/refuse` with `{"reason"}`, and needs
  `ehos.release.approve` in that production environment. Production does not change, and the
  reason shows beside the promotion for whoever reads it. A reason that is empty or longer than
  1024 characters is refused here before anything is sent; one EHOS reads as empty otherwise,
  such as spaces alone, EHOS refuses as `invalid`.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.PromotionReview
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @impl Ehosctl.Command
  def name, do: :refuse

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    [
      about: "Refuse a promotion, with a reason. Production does not change.",
      args: [
        id: [value_name: "PROMOTION", required: true, help: "The id of the promotion."]
      ],
      options: [
        reason: [
          long: "--reason",
          value_name: "TEXT",
          required: true,
          help:
            "Why you refuse it, 1 to 1024 characters. The person who asked for the promotion " <>
              "reads it."
        ]
      ],
      flags: Output.json_flag()
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], %{args: %{id: id}}, _opts) when Api.is_nameless(id),
    do: {:error, :invalid, "#{Refusal.shown(id)} is not the id of a promotion."}

  def call([], %{args: %{id: id}, options: %{reason: reason}}, opts) do
    if PromotionReview.reason?(reason),
      do: refuse(String.downcase(id), reason, opts),
      else: {:error, :invalid, "--reason takes 1 to 1024 characters."}
  end

  defp refuse(id, reason, opts) do
    Api.write(
      opts,
      {:post, PromotionReview.path(id) <> "/refuse", %{reason: reason}},
      [
        status: 200,
        key: "promotion",
        valid?: &(PromotionReview.promotion?(&1) and &1["id"] == id),
        only: &PromotionReview.kept_promotion/1,
        look: "`ehosctl promotions show #{Refusal.shown(id)}`"
      ],
      &refused/1
    )
  end

  defp refused(promotion),
    do:
      "Promotion #{Refusal.shown(promotion["id"])} is #{Refusal.shown(promotion["state"])}. " <>
        "Production did not change."
end

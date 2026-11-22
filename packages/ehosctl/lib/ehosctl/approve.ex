defmodule Ehosctl.Approve do
  @moduledoc """
  `ehosctl approve <id>`: approves a promotion, which deploys its candidate to production, as the
  console's review does with its button (eh-os
  [`docs/promotions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/promotions-api.md),
  [D-105](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0105-production-is-reached-only-by-promoting-a-candidate-and-a-promotion-is-a-record-of-its-own-approved-by-the-application-s-process-owner.md)).

  It reads the review first (`Ehosctl.PromotionReview`) and prints it. When the review says the
  caller may not approve it, or that nobody can now (`may_approve`, `approvable`), it sends
  nothing, as the console offers no button then, and says why. Otherwise it asks, unless `--yes`,
  where a person can answer; where nobody can, as in a job, it approves nothing without `--yes`.
  Then it sends `POST /api/v1/promotions/:id/approve`, which needs `ehos.release.approve` in that
  production environment, and `ehos.application.register` there too when the authority changes
  (eh-os D-119).

  EHOS answers with the production deployment it decided, which `approve` follows until it is
  active, failed, superseded or ten minutes pass, as `ehosctl deploy` does
  (`Ehosctl.Deployments.follow/5`); `--no-wait` returns at once. A caller who may not read the
  deployments there, as a process owner who holds `ehos.release.approve` alone, is told so, and
  the approval still exits 0, with the `outcome` `not_followed` under `--json`. Under `--json`,
  which needs `--yes`, one document at the end: the `review`, the approved `promotion`, the
  `deployment`'s id, and its last `state` and `failure`, as `deploy --json` gives them, with the
  `outcome` and the `addresses` when it waited.

  A refusal of EHOS's says what to do next: ask for the promotion again after `changed` or
  `requester_cannot_deploy`, another person after `self_approval`, and so on.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Deployments
  alias Ehosctl.Output
  alias Ehosctl.PromotionReview
  alias Ehosctl.Refusal
  alias Ehosctl.Terminal
  alias EhosPlatform.Shell

  @impl Ehosctl.Command
  def name, do: :approve

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :applications

  @impl Ehosctl.Command
  def summary, do: "Approve a promotion after you read its review."

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Approve a promotion after you read its review. EHOS then deploys the candidate to " <>
          "production, and ehosctl waits until the deployment is active.",
      args: [
        id: [value_name: "PROMOTION", required: true, help: "The id of the promotion."]
      ],
      flags:
        [
          yes: [long: "--yes", help: "Approve without a question. Needed with --json."],
          no_wait: [
            long: "--no-wait",
            help:
              "Return when EHOS decides the deployment. Do not wait until the deployment is " <>
                "active."
          ]
        ] ++ Output.json_flag()
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], %{flags: %{json: true, yes: false}}, _opts),
    do:
      {:error, :invalid,
       "Give --yes with --json: ehosctl does not ask a question when it prints JSON."}

  def call([], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{yes: yes?, json: json?, no_wait: no_wait?} = parsed.flags

    with {:ok, review} <- PromotionReview.read(installation, parsed.args.id, opts),
         :ok <- shown(review, json?),
         :ok <- approvable(review),
         :ok <- confirmed(review, yes?) do
      approve(review, {not no_wait?, json?}, opts)
    end
  end

  defp shown(_review, true), do: :ok
  defp shown(review, false), do: IO.puts(PromotionReview.text(review) <> "\n")

  # What the console offers its button for, and nothing else is sent.
  defp approvable(%{"promotion" => %{"state" => state} = promotion}) when state != "requested",
    do:
      {:error, :failed,
       "Promotion #{Refusal.shown(promotion["id"])} is #{Refusal.shown(state)}, so nobody can " <>
         "approve it. ehosctl sent nothing."}

  defp approvable(%{"may_approve" => false, "promotion" => promotion}),
    do:
      {:error, :refused,
       "You cannot approve promotions of #{Refusal.shown(promotion["application"])} in " <>
         "#{Refusal.shown(promotion["environment"])}. Approving needs ehos.release.approve " <>
         "there. ehosctl sent nothing."}

  defp approvable(%{"approvable" => false, "promotion" => promotion}),
    do:
      {:error, :failed,
       "You cannot approve promotion #{Refusal.shown(promotion["id"])} now. Its review says " <>
         "why. ehosctl sent nothing."}

  defp approvable(_review), do: :ok

  defp confirmed(_review, true), do: :ok

  defp confirmed(%{"promotion" => promotion}, false) do
    question =
      "Approve promotion #{Refusal.shown(promotion["id"])}? EHOS then deploys the candidate to " <>
        "#{Refusal.shown(promotion["environment"])}."

    case Terminal.confirm_at_terminal(question) do
      true ->
        :ok

      false ->
        {:error, :invalid, "You did not confirm, so nothing was approved."}

      nil ->
        {:error, :invalid,
         "Nothing was approved: ehosctl asks before it approves a promotion, and nobody can " <>
           "answer here. Answer on a terminal, or give --yes."}
    end
  end

  defp approve(%{"promotion" => promotion} = review, {wait?, json?}, opts) do
    id = promotion["id"]

    approved =
      Api.write(
        opts,
        {:post, PromotionReview.path(id) <> "/approve", %{}},
        [
          status: 200,
          key: nil,
          valid?: &approved?(&1, id),
          only: &only(&1, review),
          look: "`ehosctl promotions show #{Shell.word(id)}`",
          refused: &refused/1
        ],
        &approved_text/1
      )

    case approved do
      {:ok, %{json: body, text: text}} when wait? ->
        if not json?, do: Output.result(%{text: text, json: nil}, false)
        follow(body, json?, opts)

      other ->
        other
    end
  end

  defp approved?(%{"promotion" => approved, "deployment" => deployment}, id),
    do: PromotionReview.promotion?(approved) and approved["id"] == id and deployment?(deployment)

  defp approved?(_answer, _id), do: false

  defp deployment?(%{"id" => id, "state" => state} = deployment),
    do:
      is_binary(id) and is_binary(state) and
        (is_nil(deployment["failure"]) or is_binary(deployment["failure"]))

  defp deployment?(_deployment), do: false

  # Shaped as `deploy --json` gives a deployment, with the review it was approved from.
  defp only(%{"promotion" => approved, "deployment" => deployment}, review),
    do: %{
      "review" => review,
      "promotion" => PromotionReview.kept_promotion(approved),
      "deployment" => deployment["id"],
      "state" => deployment["state"],
      "failure" => deployment["failure"]
    }

  defp approved_text(body) do
    promotion = body["review"]["promotion"]

    "You approved promotion #{Refusal.shown(promotion["id"])}. EHOS decided deployment " <>
      "#{Refusal.shown(body["deployment"])} of #{Refusal.shown(promotion["application"])} in " <>
      "#{Refusal.shown(promotion["environment"])}: it is #{Refusal.shown(body["state"])}."
  end

  defp follow(%{"review" => %{"promotion" => promotion}} = body, json?, opts) do
    installation = Keyword.fetch!(opts, :installation)
    where = {promotion["application"], promotion["environment"]}

    installation
    |> Deployments.follow(where, body, json?, opts)
    |> followed(body, json?)
  end

  # A process owner holds `ehos.release.approve` alone, and reading the deployments needs
  # `ehos.application.deploy` or `ehos.application.register` there: the approval stands, and
  # only the wait cannot be done.
  defp followed({:error, :refused, _message, %{"code" => "forbidden"}}, body, true),
    do: Output.result(%{text: "", json: Map.put(body, "outcome", "not_followed")}, true)

  defp followed({:error, :refused, _message, %{"code" => "forbidden"}}, body, false) do
    promotion = body["review"]["promotion"]

    # The shape `deploy` gives when it cannot follow its deployment (`Ehosctl.Deployments`).
    Output.result(
      %{
        text:
          Output.lines([
            "",
            Output.outcome(
              :warning,
              "ehosctl cannot follow the deployment in " <>
                "#{Refusal.shown(promotion["environment"])}: reading its deployments needs " <>
                "ehos.application.deploy or ehos.application.register there."
            ),
            "  Open the page of #{Refusal.shown(promotion["application"])} in the console to " <>
              "see if it became active."
          ]),
        json: nil
      },
      false
    )
  end

  defp followed(result, _body, _json?), do: result

  # What to do after each refusal of an approval, as the console's review says it.
  defp refused(%{"error" => code}) when code in ["changed", "requester_cannot_deploy"],
    do: " Ask for the promotion again with `ehosctl promote`. That withdraws this one."

  defp refused(%{"error" => "self_approval"}),
    do: " Four eyes is on, so another person must approve it."

  defp refused(%{"error" => "candidate_gone"}),
    do:
      " EHOS withdrew the promotion. Deploy the version to an ephemeral environment again, and " <>
        "ask for a new promotion."

  defp refused(%{"error" => "readers_not_held"}),
    do:
      " Only a person who can approve the promotions of each application that it breaks can " <>
        "approve it."

  # The version in force did not move, so a new request withdraws this one only when its own
  # requester asks again; anyone else names it with --replace.
  defp refused(%{"error" => "callers_changed"}),
    do:
      " Ask for the promotion again with `ehosctl promote`. If another person asked for it, " <>
        "give --replace with its id."

  defp refused(%{"error" => "callers_not_held"}),
    do:
      " Only a person who can approve the promotions of each application that calls the " <>
        "utility service can approve it."

  defp refused(%{"error" => "would_be_refused", "refusals" => refusals}) when is_list(refusals),
    do: {"", %{"refusals" => Enum.filter(refusals, &is_binary/1)}}

  defp refused(_body), do: nil
end

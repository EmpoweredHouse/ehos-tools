defmodule Ehosctl.Promote do
  @moduledoc """
  `ehosctl promote <application> --candidate <deployment id> --env <production>` asks for the
  promotion of a candidate to a production environment, and `ehosctl promote --withdraw <id>`
  withdraws a promotion that waits, through EHOS's API (eh-os
  [`docs/promotions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/promotions-api.md),
  [D-105](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0105-production-is-reached-only-by-promoting-a-candidate-and-a-promotion-is-a-record-of-its-own-approved-by-the-application-s-process-owner.md)),
  as the console's promotions page asks for and withdraws one.

  A request sends `POST /api/v1/applications/:name/promotions` with `{"candidate", "environment"}`,
  and needs `ehos.application.deploy` for the application in that production environment. One
  request waits for each application there:

  - The same person asking again for the same candidate gets the request that waits.
  - Someone else's request that waits is withdrawn only when `--replace` names it, else EHOS
    refuses the call as `already_requested` and names the one that waits as `waiting`, which
    `ehosctl` prints with how to read and replace it, and keeps under `--json`.
  - A candidate that would stop publishing a name another application there subscribes to is
    refused as `would_be_refused`, unless `--break` gives the reason to break those readers on
    purpose (eh-os D-132); `--json` keeps `refusals`.

  `--withdraw` sends `POST /api/v1/promotions/:id/withdraw`. It needs to be the requester, or to
  hold `ehos.application.deploy` there.

  Some of what EHOS would refuse as `invalid` is refused here before anything is sent: a `--break`
  that is empty or longer than 1024 characters, a `--replace` that is not a promotion's id, and
  flags that do not go together.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Failure
  alias Ehosctl.Output
  alias Ehosctl.PromotionReview
  alias Ehosctl.Refusal
  alias EhosPlatform.Shell

  require Ehosctl.Api

  @impl Ehosctl.Command
  def name, do: :promote

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :applications

  @impl Ehosctl.Command
  def summary, do: "Ask to promote a candidate to production, or withdraw it."

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Ask for the promotion of a candidate to a production environment, or withdraw a " <>
          "promotion that waits.",
      args: [
        application: [
          value_name: "APPLICATION",
          required: false,
          help: "The name of the application. Not accepted with --withdraw."
        ]
      ],
      options: [
        candidate: [
          long: "--candidate",
          value_name: "DEPLOYMENT",
          help:
            "The id of the candidate: an active deployment of the application in one of its " <>
              "ephemeral environments. `ehosctl promotions APPLICATION` lists them."
        ],
        env: [
          long: "--env",
          value_name: "ENVIRONMENT",
          help: "The name of the production environment."
        ],
        replace: [
          long: "--replace",
          value_name: "PROMOTION",
          help:
            "The id of the promotion that another person asked for and that waits there. EHOS " <>
              "withdraws it and records the withdrawal as yours."
        ],
        break: [
          long: "--break",
          value_name: "REASON",
          help:
            "The reason to break, on purpose, the applications that read a name the candidate " <>
              "stops publishing. 1 to 1024 characters."
        ],
        withdraw: [
          long: "--withdraw",
          value_name: "PROMOTION",
          help: "Withdraw the promotion with this id. Production does not change."
        ]
      ],
      flags: Output.json_flag()
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], %{options: %{withdraw: id}} = parsed, opts) when is_binary(id) do
    with :ok <- withdraw_alone(parsed),
         :ok <- promotion_id(id, "--withdraw") do
      withdraw(String.downcase(id), opts)
    end
  end

  def call([], %{args: %{application: app}, options: options}, opts) do
    with :ok <- asked(app, options),
         :ok <- maybe_promotion_id(options.replace),
         :ok <- break(options.break) do
      request(app, options, opts)
    end
  end

  ## Asking for a promotion

  defp asked(app, %{candidate: candidate, env: env})
       when is_binary(app) and is_binary(candidate) and is_binary(env) do
    if Api.is_nameless(app),
      do: {:error, :invalid, "#{Refusal.shown(app)} is not the name of an application."},
      else: :ok
  end

  defp asked(_app, _options),
    do:
      {:error, :invalid,
       "Name the application, the candidate with --candidate and the production environment " <>
         "with --env. To withdraw a promotion, give --withdraw PROMOTION."}

  defp maybe_promotion_id(nil), do: :ok
  defp maybe_promotion_id(id), do: promotion_id(id, "--replace")

  defp promotion_id(id, flag) do
    if Api.uuid?(id),
      do: :ok,
      else:
        {:error, :invalid,
         Failure.new(
           "#{flag} takes the id of a promotion, such as 4c7a6b5e-0000-4000-8000-000000000004.",
           advice: "See the promotions of the application:",
           to_do: ["ehosctl promotions APPLICATION"]
         )}
  end

  defp break(nil), do: :ok

  defp break(reason) do
    if PromotionReview.reason?(reason),
      do: :ok,
      else:
        {:error, :invalid,
         "--break takes a reason of 1 to #{PromotionReview.most_reason()} characters."}
  end

  defp request(app, options, opts) do
    # EHOS answers an id in lower case, whichever case it was asked in.
    options = %{
      options
      | candidate: String.downcase(options.candidate),
        replace: options.replace && String.downcase(options.replace)
    }

    body =
      %{candidate: options.candidate, environment: options.env}
      |> maybe_put(:replace, options.replace)
      |> maybe_put(:break, options.break)

    Api.write(
      opts,
      {:post, "/api/v1/applications/#{Api.segment(app)}/promotions", body},
      [
        status: 201,
        key: "promotion",
        valid?: &(PromotionReview.promotion?(&1) and &1["candidate_id"] == options.candidate),
        only: &PromotionReview.kept_promotion/1,
        look: "ehosctl promotions #{Shell.word(app)}",
        refused: &request_refused(&1, app)
      ],
      &requested(&1, options.env)
    )
  end

  defp requested(promotion, env) do
    id = Refusal.shown(promotion["id"])
    env = Refusal.shown(env)

    "You asked for the promotion of candidate #{Refusal.shown(promotion["candidate_id"])} to " <>
      "#{env}: promotion #{id} is #{Refusal.shown(promotion["state"])}.\n" <>
      "A person who can approve promotions in #{env} approves or refuses it." <>
      Output.offered([
        " Run ",
        {:command, "ehosctl promotions show #{Shell.word(promotion["id"])}"},
        " to read its review."
      ])
  end

  # What to do after each refusal of a request, with the fields `--json` keeps beside its code.
  defp request_refused(%{"error" => "already_requested", "waiting" => waiting}, _app)
       when is_binary(waiting) do
    word = Shell.word(waiting)

    {"\nPromotion #{Refusal.shown(waiting)} waits there." <>
       Output.offered([
         " Run ",
         {:command, "ehosctl promotions show #{word}"},
         " to read it. To withdraw it and ask for yours, run the command again with " <>
           "--replace #{word}."
       ]), %{"waiting" => waiting}}
  end

  defp request_refused(%{"error" => "already_requested"}, _app),
    do: {" Ask for the promotion again.", %{"waiting" => nil}}

  defp request_refused(%{"error" => "would_be_refused", "refusals" => refusals}, _app)
       when is_list(refusals) do
    refusals = Enum.filter(refusals, &is_binary/1)

    more =
      if Enum.any?(refusals, &String.starts_with?(&1, "publishes:")),
        do:
          "\nTo break the applications that read those names on purpose, run the command again " <>
            "with --break and your reason. A person who can approve the promotions of each of " <>
            "them must approve it.",
        else: ""

    {more, %{"refusals" => refusals}}
  end

  defp request_refused(%{"error" => code}, app)
       when code in ["not_a_candidate", "not_production"],
       do:
         Output.offered([
           " Run ",
           {:command, "ehosctl promotions #{Shell.word(app)}"},
           " to see the candidates of the application and its production environments."
         ])

  defp request_refused(_body, _app), do: nil

  ## Withdrawing a promotion

  defp withdraw_alone(%{args: %{application: nil}, options: options}) do
    if Enum.all?([options.candidate, options.env, options.replace, options.break], &is_nil/1),
      do: :ok,
      else: withdraw_not_alone()
  end

  defp withdraw_alone(_parsed), do: withdraw_not_alone()

  defp withdraw_not_alone,
    do:
      {:error, :invalid,
       "--withdraw takes the id of the promotion alone. Do not give an application, " <>
         "--candidate, --env, --replace or --break with it."}

  defp withdraw(id, opts) do
    Api.write(
      opts,
      {:post, PromotionReview.path(id) <> "/withdraw", %{}},
      [
        status: 200,
        key: "promotion",
        valid?: &(PromotionReview.promotion?(&1) and &1["id"] == id),
        only: &PromotionReview.kept_promotion/1,
        look: "ehosctl promotions show #{Shell.word(id)}"
      ],
      &withdrawn/1
    )
  end

  defp withdrawn(promotion),
    do:
      "Promotion #{Refusal.shown(promotion["id"])} is #{Refusal.shown(promotion["state"])}. " <>
        "Production did not change."

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule Ehosctl.Promotions do
  @moduledoc """
  `ehosctl promotions <application>`, `promotions --waiting` and `promotions show <id>`: an
  application's way to production, its candidates and its promotions; the promotions that wait
  for the caller's approval; and one promotion's review, through EHOS's API (eh-os
  [`docs/promotions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/promotions-api.md),
  [D-105](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0105-production-is-reached-only-by-promoting-a-candidate-and-a-promotion-is-a-record-of-its-own-approved-by-the-application-s-process-owner.md)),
  as the console's promotions page, its Approvals page and its review show them.

  A version reaches production only by promotion: a candidate, an active deployment of the
  application in one of its ephemeral environments, is promoted to a production environment once
  a person who may approve there approves it.

  - `<application>` reads `GET /api/v1/applications/:name/promotions`: for each production
    environment the step the newest attempt is at and whether production runs a promoted version
    (`way`, told only to a caller who acts there), whether four eyes holds, the candidates and the
    50 newest promotions. It needs `ehos.application.deploy`, `ehos.application.register` or
    `ehos.release.approve` anywhere in the application.
  - `--waiting` reads `GET /api/v1/promotions`: those waiting for the caller's approval, oldest
    first.
  - `show <id>` reads `GET /api/v1/promotions/:id`, the review an approver reads before deciding
    (`Ehosctl.PromotionReview`).

  `--json` keeps the fields `ehosctl` reads, so nothing else EHOS's answer holds reaches a script.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.PromotionReview
  alias Ehosctl.Refusal
  alias Ehosctl.Source

  require Ehosctl.Api

  # The way to production, in order (eh-os `Ehos.Promotions.way/0`), and the console's names.
  @steps [
    {"deployed", "deployed to an ephemeral environment"},
    {"candidate", "candidate"},
    {"requested", "promotion asked for"},
    {"approved", "approved"},
    {"in_production", "in production"}
  ]

  @candidate ~w(id environment image manifest_digest authority_digest by at addresses source
                build)

  @impl Ehosctl.Command
  def name, do: :promotions

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :applications

  @impl Ehosctl.Command
  def summary, do: "List promotions, and show the review of one."

  @impl Ehosctl.Command
  def runs_bare?, do: true

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "List the candidates and promotions of an application, or the promotions that wait for " <>
          "your approval, and show a promotion's review.",
      args: [
        application: [
          value_name: "APPLICATION",
          required: false,
          help: "The name of the application. Not accepted with --waiting."
        ]
      ],
      flags:
        [
          waiting: [
            long: "--waiting",
            help: "List the promotions that wait for your approval, in every application."
          ]
        ] ++ Output.json_flag(),
      subcommands: [
        show: [
          name: "show",
          about:
            "Show the review of a promotion: what an approval puts in force in production, and " <>
              "what you must know before you decide.",
          args: [
            id: [value_name: "PROMOTION", required: true, help: "The id of the promotion."]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:show], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, review} <- PromotionReview.read(installation, parsed.args.id, opts) do
      {:ok, %{text: PromotionReview.text(review), json: %{review: review}}}
    end
  end

  def call([], %{args: %{application: nil}, flags: %{waiting: false}}, _opts),
    do: {:error, :invalid, "Name an application, or give --waiting."}

  def call([], %{args: %{application: app}, flags: %{waiting: true}}, _opts)
      when is_binary(app),
      do:
        {:error, :invalid,
         "Give an application or --waiting, not both: --waiting lists the promotions of every " <>
           "application that wait for you."}

  def call([], %{flags: %{waiting: true}}, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, body} <- Api.read(installation, "/api/v1/promotions", opts) do
      waiting(body, installation)
    end
  end

  def call([], %{args: %{application: app}}, _opts) when Api.is_nameless(app),
    do: {:error, :invalid, "#{Refusal.shown(app)} is not the name of an application."}

  def call([], %{args: %{application: app}}, opts) do
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/applications/#{Api.segment(app)}/promotions"

    with {:ok, body} <- Api.read(installation, path, opts) do
      if overview?(body),
        do: {:ok, %{text: overview_text(kept(body), app), json: kept(body)}},
        else: Api.unexpected(installation)
    end
  end

  ## Waiting for the caller

  defp waiting(%{"promotions" => listed}, installation) when is_list(listed) do
    if Enum.all?(listed, &PromotionReview.promotion?/1) do
      promotions = Enum.map(listed, &PromotionReview.kept_promotion/1)
      {:ok, %{text: waiting_text(promotions), json: %{promotions: promotions}}}
    else
      Api.unexpected(installation)
    end
  end

  defp waiting(_body, installation), do: Api.unexpected(installation)

  defp waiting_text([]), do: "No promotion waits for your approval."

  defp waiting_text(promotions) do
    rows =
      for promotion <- promotions do
        %{
          "PROMOTION" => id(promotion["id"]),
          "APPLICATION" => Refusal.shown(promotion["application"]),
          "TO" => Refusal.shown(promotion["environment"]),
          "FROM" => Refusal.shown(promotion["candidate_environment"]),
          "ASKED" => Refusal.shown(promotion["inserted_at"])
        }
      end

    Enum.join(
      [
        "Promotions that wait for your approval, oldest first:",
        Output.table(rows, ["PROMOTION", "APPLICATION", "TO", "FROM", "ASKED"])
      ] ++ ["Run `ehosctl promotions show PROMOTION` to read the review of one."],
      "\n"
    )
  end

  ## An application's candidates and promotions

  defp overview?(%{"four_eyes" => four_eyes, "promotions" => promotions} = body)
       when is_boolean(four_eyes) do
    all?(Map.get(body, "candidates", []), &candidate?/1) and
      all?(Map.get(body, "production", []), &is_binary/1) and
      way?(Map.get(body, "way", %{})) and all?(promotions, &PromotionReview.promotion?/1)
  end

  defp overview?(_body), do: false

  defp candidate?(%{"id" => id, "environment" => env, "image" => image} = candidate),
    do:
      is_binary(id) and is_binary(env) and is_binary(image) and
        Enum.all?(~w(by at build manifest_digest authority_digest), &nil_or_text?(candidate[&1])) and
        all?(Map.get(candidate, "addresses", []), &is_binary/1)

  defp candidate?(_candidate), do: false

  # eh-os#802: absent from an EHOS before it, and then not said.
  defp way?(way) when is_map(way), do: Enum.all?(way, &step?/1)
  defp way?(_way), do: false

  defp step?({name, %{"at" => at, "in_production" => in_production, "known" => known}}),
    do: is_binary(name) and is_binary(at) and is_boolean(in_production) and is_boolean(known)

  defp step?(_step), do: false

  defp kept(body) do
    body
    |> Map.take(~w(four_eyes candidates production way promotions))
    |> Map.update("candidates", [], &Enum.map(&1, fn c -> candidate(c) end))
    |> Map.update!("promotions", &Enum.map(&1, fn p -> PromotionReview.kept_promotion(p) end))
    |> keep_way()
  end

  defp candidate(candidate) do
    candidate
    |> Map.take(@candidate)
    |> Source.keeping()
  end

  defp keep_way(%{"way" => way} = body),
    do:
      Map.put(
        body,
        "way",
        Map.new(way, fn {name, step} -> {name, Map.take(step, ~w(at in_production known))} end)
      )

  defp keep_way(body), do: body

  defp overview_text(overview, app) do
    app = Refusal.shown(app)

    [
      ["Promotions of #{app}. #{four_eyes(overview["four_eyes"])}"],
      way(overview, app),
      candidates(overview["candidates"], app),
      promotions(overview["promotions"], app)
    ]
    |> Enum.reject(&(&1 == []))
    |> Enum.map_join("\n\n", &Enum.join(&1, "\n"))
  end

  defp four_eyes(true),
    do:
      "Four eyes is on: the person who deployed a candidate or asked for its promotion does " <>
        "not approve it."

  defp four_eyes(false),
    do:
      "Four eyes is off: the person who deployed a candidate or asked for its promotion can " <>
        "approve it."

  # The step the newest attempt is at, for each production environment the application has.
  defp way(%{"way" => way}, app) when map_size(way) > 0 do
    for {name, step} <- Enum.sort(way) do
      "To #{Refusal.shown(name)}: " <> step(step, name, app)
    end
  end

  defp way(_overview, _app), do: []

  defp step(%{"known" => false}, name, _app),
    do:
      "EHOS shows the state of #{Refusal.shown(name)} only to a person who can deploy, " <>
        "register or approve there."

  defp step(%{"at" => "none"} = step, name, app),
    do:
      "no version of #{app} is in these steps for #{Refusal.shown(name)}." <>
        in_production(step)

  defp step(%{"at" => at} = step, _name, _app) do
    steps =
      Enum.map_join(@steps, " > ", fn {key, said} ->
        if key == at, do: "[#{said}]", else: said
      end)

    steps <> in_production(step)
  end

  defp in_production(%{"in_production" => true, "at" => at}) when at != "in_production",
    do: " Production runs a promoted version."

  defp in_production(_step), do: ""

  defp candidates([], app),
    do: [
      "No candidates. A candidate shows here when a deployment of #{app} is active in an " <>
        "ephemeral environment."
    ]

  defp candidates(candidates, _app) do
    rows =
      for candidate <- candidates do
        %{
          "CANDIDATE" => id(candidate["id"]),
          "ENVIRONMENT" => Refusal.shown(candidate["environment"]),
          "IMAGE" => Refusal.shown(candidate["image"]),
          "DEPLOYED BY" => Refusal.shown(candidate["by"] || "unknown"),
          "TRY IT" => Enum.map_join(Map.get(candidate, "addresses", []), ", ", &Refusal.shown/1)
        }
      end

    sources =
      for candidate <- candidates, line = Source.line(candidate["source"]) do
        "  #{id(candidate["id"])}: #{line}"
      end

    [
      "Candidates:",
      Output.table(rows, ["CANDIDATE", "ENVIRONMENT", "IMAGE", "DEPLOYED BY", "TRY IT"])
    ] ++
      if(sources == [], do: [], else: ["Where each came from:" | sources])
  end

  defp promotions([], app),
    do: ["No promotions of #{app} yet."]

  defp promotions(promotions, _app) do
    rows =
      for promotion <- promotions do
        %{
          "PROMOTION" => id(promotion["id"]),
          "TO" => Refusal.shown(promotion["environment"]),
          "FROM" => Refusal.shown(promotion["candidate_environment"]),
          "STATE" => Refusal.shown(promotion["state"]),
          "ASKED BY" => Refusal.shown(promotion["requested_by"] || "unknown"),
          "DECIDED BY" => decided_by(promotion)
        }
      end

    reasons =
      for promotion <- promotions,
          {label, reason} <- [
            {"reason", promotion["reason"]},
            {"reason to break readers", promotion["break_reason"]}
          ],
          is_binary(reason) do
        "  #{id(promotion["id"])} #{label}: #{Refusal.shown(reason)}"
      end

    [
      "Promotions, newest first:",
      Output.table(rows, ["PROMOTION", "TO", "FROM", "STATE", "ASKED BY", "DECIDED BY"])
    ] ++
      reasons ++ ["Run `ehosctl promotions show PROMOTION` to read the review of one."]
  end

  # eh-os#757: a self-approval is marked beside who decided.
  defp decided_by(%{"decided_by" => by, "self_approved" => true}) when is_binary(by),
    do: Refusal.shown(by) <> " (self-approved)"

  defp decided_by(%{"decided_by" => by}) when is_binary(by), do: Refusal.shown(by)
  defp decided_by(_promotion), do: ""

  # Whole, since `promote`, `approve` and `promotions show` take it as it is printed.
  defp id(id), do: Refusal.shown(id)

  defp all?(list, valid?), do: is_list(list) and Enum.all?(list, valid?)
  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)
end

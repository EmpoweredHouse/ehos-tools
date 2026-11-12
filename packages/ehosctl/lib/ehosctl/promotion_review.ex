defmodule Ehosctl.PromotionReview do
  @moduledoc """
  A promotion's review, the one an approver reads before deciding, as EHOS's API gives it
  (`GET /api/v1/promotions/:id`, eh-os
  [`docs/promotions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/promotions-api.md))
  and the console's review shows it, with the same notices and parts (eh-os
  [D-105](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0105-production-is-reached-only-by-promoting-a-candidate-and-a-promotion-is-a-record-of-its-own-approved-by-the-application-s-process-owner.md)):
  read, checked, kept to the fields `ehosctl` reads, and said. `ehosctl promotions show` prints
  it.

  Production's side (the version in force, the comparison of the code, the authority, the
  refusals and the readers) is given only to a caller who acts in that production environment,
  `there`; to anyone else it is null or empty, and said so. The keys a later EHOS added are read
  when given and said as none when not: `readers_said`, `breaks` and `breaks_held` (eh-os D-132),
  `source` and `addresses` (D-129), `mail_relay` (D-141), and `compare`, `changes` and `build`
  (D-146). `--json` keeps each as EHOS gave it, and leaves out the ones it did not give.

  A promotion's own record, as each of EHOS's answers gives it, is `promotion?/1`'s and
  `kept_promotion/1`'s, which the list of promotions reads too.
  """

  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.Mail
  alias Ehosctl.Refusal
  alias Ehosctl.Review
  alias Ehosctl.Source

  require Ehosctl.Api

  @typedoc "A review, kept to the fields read."
  @type t :: %{String.t() => term()}

  # The start of an id, a digest or a commit shown, as the console shows them.
  @shown 12

  @promotion ~w(id state candidate_id image image_digest manifest_digest authority_digest
                in_force_digest reason break_reason four_eyes self_approved deployment_id
                decided_at inserted_at application environment candidate_environment
                requested_by decided_by)
  @flags ~w(there four_eyes self may_approve may_withdraw approvable changed candidate_active)
  @texts ~w(refusals readers_said breaks addresses mail_relay)
  @review @flags ++
            @texts ++
            ~w(promotion in_force compare changes build authority register breaks_held
               requester_can_deploy source diff described)

  @doc """
  The review of promotion `id`, in either case, checked and kept, or EHOS's refusal. An answer of another shape,
  or for another promotion, is one `ehosctl` cannot read. An id that would leave its place in the
  path (`.`, `..`), or names nothing, is refused before anything is sent.
  """
  @spec read({Config.name(), Config.installation()}, String.t(), keyword()) ::
          {:ok, t()} | Api.error()
  def read(_installation, id, _opts) when Api.is_nameless(id),
    do: {:error, :invalid, "#{Refusal.shown(id)} is not the id of a promotion."}

  def read(installation, id, opts) do
    # EHOS answers an id in lower case, whichever case it was asked in.
    id = String.downcase(id)

    with {:ok, body} <- Api.read(installation, path(id), opts) do
      if review?(body) and body["promotion"]["id"] == id,
        do: {:ok, kept(body)},
        else: Api.unexpected(installation)
    end
  end

  @doc "The path of promotion `id` in EHOS's API, and of its decisions below it."
  @spec path(String.t()) :: String.t()
  def path(id), do: "/api/v1/promotions/" <> Api.segment(id)

  @doc """
  Whether `promotion` is a promotion as EHOS's answers give it: its id, state, image and digests,
  and every other field read of its type, or absent.
  """
  @spec promotion?(term()) :: boolean()
  def promotion?(%{"id" => id, "state" => state, "image" => image} = promotion)
      when is_binary(id) and is_binary(state) and is_binary(image) do
    Enum.all?(
      ~w(candidate_id image_digest manifest_digest authority_digest in_force_digest reason
         break_reason deployment_id decided_at inserted_at application environment
         candidate_environment requested_by decided_by),
      &nil_or_text?(promotion[&1])
    ) and Enum.all?(~w(four_eyes self_approved), &(promotion[&1] in [nil, true, false]))
  end

  def promotion?(_promotion), do: false

  @doc "`promotion`, which `promotion?/1` has checked, kept to the fields read."
  @spec kept_promotion(map()) :: map()
  def kept_promotion(promotion), do: Map.take(promotion, @promotion)

  # The review names where the promotion goes, which `approve` follows the deployment in.
  defp review?(%{"promotion" => promotion} = review) do
    promotion?(promotion) and
      Enum.all?(~w(application environment candidate_environment), &is_binary(promotion[&1])) and
      Enum.all?(@flags, &is_boolean(review[&1])) and
      Enum.all?(@texts, &texts?(Map.get(review, &1, []))) and texts_or_nil?(review) and
      parts?(review)
  end

  defp review?(_review), do: false

  defp texts_or_nil?(review),
    do: Enum.all?(~w(in_force authority build), &nil_or_text?(review[&1]))

  defp parts?(review) do
    Map.get(review, "breaks_held", false) in [true, false] and
      review["requester_can_deploy"] in [nil, true, false] and register?(review["register"]) and
      compare?(review["compare"]) and changes?(review["changes"]) and side?(review)
  end

  defp register?(%{"needed" => needed, "held" => held}),
    do: is_boolean(needed) and is_boolean(held)

  defp register?(_register), do: false

  defp compare?(nil), do: true

  defp compare?(%{"url" => url, "missing" => missing}),
    do: nil_or_text?(url) and texts?(missing)

  defp compare?(_compare), do: false

  defp changes?(nil), do: true

  defp changes?(changes),
    do: is_list(changes) and Enum.all?(changes, &change?/1)

  defp change?(%{"commit" => commit} = change),
    do: is_binary(commit) and nil_or_text?(change["title"])

  defp change?(_change), do: false

  # What the authority changes is given with production's side, and both or neither.
  defp side?(%{"diff" => nil, "described" => nil}), do: true
  defp side?(review), do: Review.changes?(review)

  defp kept(review) do
    review
    |> Map.take(@review)
    |> Map.update!("promotion", &kept_promotion/1)
    |> Map.update!("register", &Map.take(&1, ~w(needed held)))
    |> keep_if("source", &Source.kept/1)
    |> keep_if("compare", &(&1 && Map.take(&1, ~w(url missing))))
    |> keep_if(
      "changes",
      &(&1 && Enum.map(&1, fn change -> Map.take(change, ~w(commit title)) end))
    )
    |> keep_side()
  end

  defp keep_if(review, key, keep) when is_map_key(review, key),
    do: Map.update!(review, key, keep)

  defp keep_if(review, _key, _keep), do: review

  defp keep_side(%{"diff" => nil} = review), do: review
  defp keep_side(review), do: Map.merge(review, Review.kept(review))

  @doc """
  The review as a person reads it: what the approval would promote, then what an approver must
  know before deciding, then the record, then production's side, or that it is not shown.
  """
  @spec text(t()) :: String.t()
  def text(review) do
    promotion = review["promotion"]
    to = Refusal.shown(promotion["environment"])

    [
      [heading(promotion)],
      notices(review, promotion, to),
      record(review, promotion),
      production(review, promotion, to)
    ]
    |> Enum.reject(&(&1 == []))
    |> Enum.map_join("\n\n", &Enum.join(&1, "\n"))
  end

  defp heading(promotion),
    do:
      "Promote #{short(promotion["image_digest"] || promotion["image"])} from " <>
        "#{Refusal.shown(promotion["candidate_environment"])} to " <>
        "#{Refusal.shown(promotion["environment"])}"

  # The console's notices, in its order: each is a paragraph, and its items lines below it.
  @notices ~w(not_verified breaks readers_said changed refusals candidate_gone
              requester_cannot_deploy self_approval self_approved authority_unchanged not_applied
              register_needed mail_relay)a

  defp notices(review, promotion, to) do
    @notices
    |> Enum.map(&notice(&1, review, promotion, to))
    |> Enum.filter(&is_binary/1)
    |> Enum.intersperse("")
  end

  defp notice(:not_verified, _review, %{"state" => "requested"} = promotion, _to),
    do:
      "The candidate ran in #{Refusal.shown(promotion["candidate_environment"])}. EHOS did not " <>
        "check that its image serves the specifications that its manifest names. If you " <>
        "approve, you confirm that the candidate does what it must do. EHOS checks what other " <>
        "applications read from it by the names and versions that they subscribe to. EHOS does " <>
        "not check the fields that they use."

  defp notice(:breaks, review, promotion, _to), do: breaks(review, promotion)

  defp notice(:readers_said, review, _promotion, _to),
    do:
      listed(
        "EHOS could not check these points about the applications that read from it:",
        Map.get(review, "readers_said", [])
      )

  defp notice(:changed, %{"changed" => true}, _promotion, to),
    do:
      "The version in force in #{to} changed after the request. Nobody can approve this " <>
        "promotion now. Ask for the promotion again."

  defp notice(:refusals, review, _promotion, to),
    do: listed("#{to} does not accept this candidate now, for these reasons:", review["refusals"])

  defp notice(:candidate_gone, %{"candidate_active" => false}, %{"state" => "requested"}, _to),
    do:
      "The candidate is no longer active. If a person tries to approve the promotion, EHOS " <>
        "withdraws it."

  defp notice(
         :requester_cannot_deploy,
         %{"requester_can_deploy" => false},
         %{"state" => "requested"},
         to
       ),
       do:
         "The person who asked for this promotion can no longer deploy in #{to}. EHOS records " <>
           "the deployment as theirs, so nobody can approve it. Ask for the promotion again."

  defp notice(
         :self_approval,
         %{"self" => true, "four_eyes" => true},
         %{"state" => "requested"},
         _to
       ),
       do:
         "You deployed this candidate or asked for its promotion. Four eyes is on, so another " <>
           "person must approve it."

  defp notice(:self_approved, _review, %{"state" => "approved", "self_approved" => true}, _to),
    do:
      "The person who deployed the candidate or asked for its promotion approved it. No " <>
        "second person approved it, because four eyes was off on this installation."

  defp notice(:authority_unchanged, %{"authority" => "unchanged"}, %{"state" => state}, to),
    do: authority_unchanged(state, to)

  defp notice(:not_applied, _review, %{"state" => state}, to)
       when state in ["refused", "withdrawn"],
       do:
         "This promotion was #{state}, so nothing changed in #{to}. The lists below show what " <>
           "an approval would have changed."

  defp notice(:register_needed, %{"register" => %{"needed" => true, "held" => false}}, _p, to),
    do:
      "This promotion changes the authority of the application. To approve it, you also need " <>
        "the right to register the application in #{to}. Ask for the role ehos.registrar there."

  defp notice(:mail_relay, review, promotion, _to),
    do:
      review
      |> Map.get("mail_relay", [])
      |> Enum.map(&Refusal.shown/1)
      |> Mail.relay(Refusal.shown(promotion["application"]))

  defp notice(_notice, _review, _promotion, _to), do: nil

  defp breaks(%{"breaks" => [_ | _] = broken} = review, promotion) do
    held =
      if review["breaks_held"],
        do: [],
        else: [
          "Only a person who can approve promotions of each application that it breaks can " <>
            "approve this promotion."
        ]

    Enum.join(
      [
        "The requester asked to break other applications on purpose. Reason: " <>
          Refusal.shown(promotion["break_reason"] || "none given")
        | Enum.map(broken, &("  - " <> Refusal.shown(&1)))
      ] ++ held,
      "\n"
    )
  end

  defp breaks(_review, _promotion), do: nil

  defp authority_unchanged("requested", to),
    do:
      "The candidate grants the same authority as the version in force. An approval changes " <>
        "no one's authority in #{to}."

  defp authority_unchanged("approved", to),
    do:
      "The candidate granted the same authority as the version in force at the time of the " <>
        "request. The approval changed no one's authority in #{to}."

  defp authority_unchanged(_state, _to), do: nil

  defp listed(_heading, []), do: nil

  defp listed(heading, items),
    do: Enum.join([heading | Enum.map(items, &("  - " <> Refusal.shown(&1)))], "\n")

  defp record(review, promotion) do
    source = Source.line(review["source"])

    reason =
      if promotion["state"] == "withdrawn",
        do: "Reason for the withdrawal",
        else: "Reason for the refusal"

    [
      "  State:    #{Refusal.shown(promotion["state"])}",
      Map.get(review, "addresses", []) != [] &&
        "  Try it:   " <> Enum.map_join(review["addresses"], ", ", &Refusal.shown/1),
      promotion["reason"] && "  #{reason}: #{Refusal.shown(promotion["reason"])}",
      "  Image:    #{Refusal.shown(promotion["image"])}",
      "  Manifest: #{Refusal.shown(promotion["manifest_digest"])}",
      source && "  Source:   #{source}",
      is_binary(review["build"]) && "  Build:    #{Refusal.shown(review["build"])}"
    ]
    |> Enum.filter(&is_binary/1)
    |> then(&["Promotion #{Refusal.shown(promotion["id"])}" | &1])
  end

  defp production(%{"there" => false}, _promotion, to),
    do: [
      "You do not deploy, register or approve in #{to}, so EHOS does not show its side: the " <>
        "version in force, what the candidate changes there, and why it would be refused."
    ]

  defp production(review, promotion, to) do
    [
      "In #{to}:",
      "  Version in force now: #{Refusal.shown(review["in_force"] || "none")}",
      promotion["state"] != "requested" &&
        "  Version in force at the request: " <>
          Refusal.shown(promotion["in_force_digest"] || "none")
    ]
    |> Kernel.++(code(review["compare"], review["changes"]))
    |> Kernel.++(authority(review))
    |> Enum.filter(&is_binary/1)
  end

  # eh-os D-146: what the candidate changes in production's code, or what is missing to compare
  # them, and the commits between as the candidate's pipeline stated them, never checked.
  defp code(nil, _changes), do: []

  defp code(compare, changes) do
    [
      "  Code changes: " <>
        if(compare["url"], do: Refusal.shown(compare["url"]), else: missing(compare["missing"]))
    ] ++ commits(changes)
  end

  defp commits(nil), do: []
  defp commits([]), do: ["  The candidate runs the same commit as production."]

  defp commits(changes),
    do: [
      "  Commits stated by the pipeline:"
      | Enum.map(changes, fn change ->
          String.trim_trailing(
            "    #{change["commit"] |> String.slice(0, @shown) |> Refusal.shown()} " <>
              Refusal.shown(change["title"] || "")
          )
        end)
    ]

  # The console's words for why EHOS gives no comparison (eh-os `PromotionsLive`).
  defp missing(["same_repository"]),
    do:
      "EHOS cannot compare the code. Production and the candidate come from different " <>
        "repositories."

  defp missing(["in_force_unknown" | candidate]) do
    "EHOS cannot compare the code. EHOS does not know which deployment production ran at the " <>
      "time of the request." <>
      if(candidate == [], do: "", else: " The candidate names no commit from the GitHub token.")
  end

  defp missing(missing) do
    parts =
      Enum.map(missing, fn
        "in_force" -> "the deployment in production"
        "candidate" -> "the candidate"
        other -> Refusal.shown(other)
      end)

    "EHOS cannot compare the code. #{String.capitalize(Enum.join(parts, " and "))} " <>
      "#{if length(parts) > 1, do: "name", else: "names"} no commit from the GitHub token."
  end

  defp authority(%{"diff" => nil}), do: []

  defp authority(review) do
    case Review.lines(review) do
      [] -> ["  It changes the authority of no one: it grants what the version in force grants."]
      lines -> ["  What it changes in authority:" | Enum.map(lines, &("  " <> &1))]
    end
  end

  defp short("sha256:" <> hex), do: Refusal.shown("sha256:" <> String.slice(hex, 0, @shown))
  defp short(other), do: Refusal.shown(other)

  defp texts?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)
  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)
end

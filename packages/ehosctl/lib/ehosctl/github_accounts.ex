defmodule Ehosctl.GitHubAccounts do
  @moduledoc """
  GitHub accounts linked to people, so that a GitHub Actions job deploys on behalf of the person
  whose push started it (eh-os
  [`docs/deployment-identity-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/deployment-identity-api.md#github-accounts),
  D-110), as the console's **GitHub accounts** page links them.

  Linking takes two people, unless only one person may manage people (eh-os D-152), and nobody
  types an id or a login:

    * `ehosctl github list | claim | remove`: a person's own accounts, and the refused runs they
      may claim an account from. `claim` shows the run, its page on GitHub included, and asks
      whether it is theirs (`--yes` answers); with no run named, it takes the one there is.
    * `ehosctl people github list | confirm | remove`: a people manager's view of the claims
      waiting, each with the run it was claimed from. `confirm` shows the person and the run,
      warns when someone else claims the same account, and asks; a login is whatever its owner
      chose, so the person is checked with outside EHOS. The only people manager confirms their
      own claim, which EHOS records as a self-confirmation; anyone else's own is refused.

  EHOS decides and records each call, and its refusal is printed in its words.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @look "ehosctl github list"
  @look_waiting "ehosctl people github list"

  @impl Ehosctl.Command
  def name, do: :github

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :access

  @impl Ehosctl.Command
  def summary, do: "List, claim and remove your GitHub accounts."

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "List, claim and remove your GitHub accounts. A GitHub Actions job that your " <>
          "linked account starts deploys on your behalf.",
      subcommands: [
        list: [
          name: "list",
          about:
            "List your GitHub accounts, and the refused runs that you can claim an account from.",
          flags: Output.json_flag()
        ],
        claim: [
          name: "claim",
          about:
            "Claim the GitHub account that a refused run of yours names. Then a people " <>
              "manager confirms it. If you are the only people manager, you confirm it.",
          args: [
            run: [
              value_name: "RUN",
              required: false,
              help:
                "The run, as `ehosctl github list` shows it. If you give no run, ehosctl " <>
                  "uses the only run that you have."
            ]
          ],
          flags: [yes: [long: "--yes", help: "Do not ask."]] ++ Output.json_flag()
        ],
        remove: [
          name: "remove",
          about: "Remove one of your GitHub accounts. EHOS refuses the next run of the account.",
          args: [account: account_arg()],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @doc "`people github`, for `Ehosctl.People`'s declaration."
  @spec people_spec() :: keyword()
  def people_spec do
    [
      github: [
        name: "github",
        about: "List, confirm and remove the GitHub accounts that people claim.",
        subcommands: [
          list: [
            name: "list",
            about:
              "List the claims that wait for confirmation, the oldest first, each with its run.",
            flags: Output.json_flag()
          ],
          confirm: [
            name: "confirm",
            about:
              "Confirm a claim. First, check with the person that the run is theirs. You " <>
                "can confirm your own claim only if you are the only people manager.",
            args: [account: account_arg()],
            flags: [yes: [long: "--yes", help: "Do not ask."]] ++ Output.json_flag()
          ],
          remove: [
            name: "remove",
            about: "Remove the GitHub account of a person, or refuse a claim.",
            args: [account: account_arg()],
            flags: Output.json_flag()
          ]
        ]
      ]
    ]
  end

  defp account_arg,
    do: [
      value_name: "ACCOUNT",
      required: true,
      help: "The id of the account, as `list` shows it."
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:list], _parsed, opts) do
    with {:ok, accounts, runs} <- mine(opts) do
      {:ok,
       %{
         text: mine_text(accounts, runs),
         json: %{accounts: accounts, claimable: runs}
       }}
    end
  end

  def call([:claim], parsed, opts) do
    with {:ok, _accounts, runs} <- mine(opts),
         {:ok, run} <- chosen(runs, parsed.args[:run]),
         :ok <- confirmed(claim_question(run), parsed) do
      Api.write(
        opts,
        {:post, "/api/v1/me/github-accounts", %{exchange: run["exchange"]}},
        [
          status: 201,
          key: "account",
          valid?: &(account?(&1) and &1["github_id"] == run["github_id"]),
          only: &only_account/1,
          look: @look
        ],
        fn account ->
          "Claimed #{Refusal.shown(account["login"])} as the account " <>
            "#{Refusal.shown(account["id"])}. A people manager must confirm it with " <>
            "`ehosctl people github confirm`. If you are the only people manager, you confirm " <>
            "it. Until then, EHOS refuses the runs of the account."
        end
      )
    else
      :not_confirmed -> {:ok, %{text: "You did not claim the account.", json: nil}}
      error -> error
    end
  end

  def call([:remove], parsed, opts),
    do: remove("/api/v1/me/github-accounts/", parsed.args.account, @look, opts)

  @doc "Runs `people github …`, for `Ehosctl.People`."
  @spec people([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def people([:list], _parsed, opts) do
    with {:ok, waiting} <- waiting(opts) do
      {:ok, %{text: waiting_text(waiting), json: %{accounts: waiting}}}
    end
  end

  def people([:confirm], parsed, opts) do
    id = parsed.args.account

    with :ok <- an_id(id, @look_waiting),
         {:ok, waiting} <- waiting(opts),
         {:ok, claim} <- waiting_claim(waiting, id),
         :ok <- may_confirm(claim),
         :ok <- confirmed(confirm_question(claim), parsed) do
      Api.write(
        opts,
        {:post, "/api/v1/github-accounts/#{Api.segment(id)}/confirm",
         %{github_id: claim["github_id"]}},
        [
          status: 200,
          key: "account",
          valid?: &(account?(&1) and same_id?(&1["id"], id) and is_binary(&1["confirmed_at"])),
          only: &only_account/1,
          look: @look_waiting
        ],
        fn account ->
          "Confirmed #{Refusal.shown(account["login"])} for " <>
            "#{Refusal.shown(claim["person"]["email"])}. The runs of the account now deploy " <>
            "on behalf of this person."
        end
      )
    else
      :not_confirmed -> {:ok, %{text: "You did not confirm the claim.", json: nil}}
      error -> error
    end
  end

  def people([:remove], parsed, opts),
    do: remove("/api/v1/github-accounts/", parsed.args.account, @look_waiting, opts)

  defp remove(prefix, id, look, opts) do
    with :ok <- an_id(id, look) do
      Api.write(
        opts,
        {:delete, prefix <> Api.segment(id), nil},
        [
          status: 200,
          key: "account",
          valid?: &(account?(&1) and same_id?(&1["id"], id)),
          only: &only_account/1,
          look: look
        ],
        fn account ->
          "Removed #{Refusal.shown(account["login"])}. EHOS refuses the next run of the " <>
            "account."
        end
      )
    end
  end

  defp mine(opts) do
    installation = Keyword.fetch!(opts, :installation)

    case Api.read(installation, "/api/v1/me/github-accounts", opts) do
      {:ok, %{"accounts" => accounts, "claimable" => runs}}
      when is_list(accounts) and is_list(runs) ->
        if Enum.all?(accounts, &account?/1) and Enum.all?(runs, &run?/1),
          do: {:ok, Enum.map(accounts, &only_account/1), Enum.map(runs, &only_run/1)},
          else: Api.unexpected(installation)

      {:ok, _body} ->
        Api.unexpected(installation)

      error ->
        error
    end
  end

  defp waiting(opts) do
    installation = Keyword.fetch!(opts, :installation)

    case Api.read(installation, "/api/v1/github-accounts", opts) do
      {:ok, %{"accounts" => waiting}} when is_list(waiting) ->
        if Enum.all?(waiting, &waiting?/1),
          do: {:ok, Enum.map(waiting, &only_waiting/1)},
          else: Api.unexpected(installation)

      {:ok, _body} ->
        Api.unexpected(installation)

      error ->
        error
    end
  end

  defp chosen([], _run),
    do:
      {:error, :failed,
       "You have no refused run to claim an account from. Run a GitHub Actions job of a " <>
         "trusted repository first. When EHOS refuses the run, you can claim its account."}

  defp chosen([run], nil), do: {:ok, run}

  defp chosen(_runs, nil),
    do:
      {:error, :invalid,
       "You have more than one run to claim from. Give one run, as `#{@look}` shows it."}

  defp chosen(runs, id) do
    case Enum.find(runs, &same_id?(&1["exchange"], id)) do
      nil ->
        {:error, :failed,
         "#{Refusal.shown(id)} is not one of your runs to claim from. Run `#{@look}` to see them."}

      run ->
        {:ok, run}
    end
  end

  defp waiting_claim(waiting, id) do
    case Enum.find(waiting, &same_id?(&1["id"], id)) do
      nil ->
        {:error, :failed,
         "#{Refusal.shown(id)} is not a claim that waits for confirmation. Run " <>
           "`#{@look_waiting}` to see the claims."}

      claim ->
        {:ok, claim}
    end
  end

  # EHOS 0.24.0 and later say whether the caller may confirm a claim: one's own only as the only
  # people manager (eh-os D-152). Refused before asking, as EHOS would after; an older EHOS says
  # nothing, and decides. In EHOS's words and kind, as its `self` would be.
  defp may_confirm(%{"confirmable" => false}),
    do:
      {:error, :failed,
       "You cannot confirm your own claim. Another people manager must confirm it."}

  defp may_confirm(_claim), do: :ok

  defp claim_question(run),
    do:
      "The run of #{Refusal.shown(run["login"])}, GitHub id #{run["github_id"]}:\n" <>
        run_text(run) <> "\nIs this run yours?"

  defp confirm_question(claim) do
    contested =
      if claim["contested"],
        do:
          "\nAnother person also claims this account. Confirm it only for the person whose " <>
            "run this is.",
        else: ""

    "#{Refusal.shown(claim["person"]["email"])} claims #{Refusal.shown(claim["login"])}, " <>
      "GitHub id #{claim["github_id"]}, from this run:\n" <>
      run_text(claim["run"]) <>
      contested <> "\nHave you checked with them that it is theirs?"
  end

  # A claim made before EHOS kept the run it rests on has none (eh-os's claims from before
  # 2026-10-16), and a run may leave out what GitHub did not sign.
  defp run_text(nil),
    do: "  EHOS does not show this run any more. Ask the person which run it was."

  defp run_text(run) do
    [
      "  #{field(run, "repository")} at #{field(run, "ref")}, #{field(run, "event_name")}, " <>
        "commit #{short(run["sha"])}, #{at(run["at"])}",
      run["run_url"] && "  #{Refusal.shown(run["run_url"])}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp field(run, key), do: if(run[key], do: Refusal.shown(run[key]), else: "unknown")

  defp at(nil), do: "unknown"
  defp at(at), do: Output.date(at)

  # A run's commit, as `claim` and `list` show it: in `list` it tells several refused runs on one
  # ref apart.
  defp short(sha) when is_binary(sha), do: Refusal.shown(String.slice(sha, 0, 12))
  defp short(_sha), do: "unknown"

  defp confirmed(question, parsed) do
    if parsed.flags.yes or Ehosctl.Terminal.confirm(question),
      do: :ok,
      else: :not_confirmed
  end

  defp an_id(id, look) when Api.is_nameless(id),
    do:
      {:error, :invalid,
       "#{Refusal.shown(id)} is not the id of an account. Run `#{look}` to see the ids."}

  defp an_id(_id, _look), do: :ok

  # EHOS's ids are UUIDs, read in either case and answered in lower case.
  defp same_id?(given, id) when is_binary(given) and is_binary(id),
    do: String.downcase(given) == String.downcase(id)

  defp same_id?(_given, _id), do: false

  @account ~w(id person_id github_id login claimed_at confirmed_at confirmed_by_id removed_at)
  @run ~w(exchange github_id login repository ref event_name sha run_url at)

  defp account?(%{"id" => id, "login" => login} = account)
       when is_binary(id) and is_binary(login),
       do:
         is_integer(account["github_id"]) and is_binary(account["claimed_at"]) and
           nil_or_text?(account["confirmed_at"]) and nil_or_text?(account["removed_at"])

  defp account?(_account), do: false

  defp run?(%{"exchange" => exchange, "login" => login} = run)
       when is_binary(exchange) and is_binary(login),
       do:
         is_integer(run["github_id"]) and
           Enum.all?(~w(repository ref event_name sha run_url at), &nil_or_text?(run[&1]))

  defp run?(_run), do: false

  defp waiting?(%{"person" => %{"id" => id, "email" => email}} = claim)
       when is_binary(id) and is_binary(email),
       do:
         account?(claim) and (is_nil(claim["run"]) or run?(claim["run"])) and
           is_boolean(claim["contested"]) and
           (not Map.has_key?(claim, "confirmable") or is_boolean(claim["confirmable"]))

  defp waiting?(_claim), do: false

  defp only_account(account), do: Map.take(account, @account)
  defp only_run(run), do: Map.take(run, @run)

  defp only_waiting(claim) do
    claim
    |> only_account()
    |> Map.merge(%{
      "person" => Map.take(claim["person"], ~w(id email)),
      "run" => claim["run"] && Map.take(claim["run"], @run),
      "contested" => claim["contested"]
    })
    |> confirmable(claim["confirmable"])
  end

  # Whether the caller may confirm it, which EHOS 0.24.0 and later say (eh-os D-152): the only
  # people manager may confirm their own claim.
  defp confirmable(claim, confirmable) when is_boolean(confirmable),
    do: Map.put(claim, "confirmable", confirmable)

  defp confirmable(claim, _absent), do: claim

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp mine_text(accounts, runs) do
    accounts_text =
      case accounts do
        [] ->
          "You have no GitHub account. Claim one with `ehosctl github claim` after EHOS " <>
            "refuses a run of yours."

        accounts ->
          accounts
          |> Enum.map(fn account ->
            %{
              "LOGIN" => Refusal.shown(account["login"]),
              "GITHUB ID" => to_string(account["github_id"]),
              "STATE" => state(account),
              "ID" => Refusal.shown(account["id"])
            }
          end)
          |> Output.table(["LOGIN", "GITHUB ID", "STATE", "ID"])
      end

    runs_text =
      case runs do
        [] ->
          ""

        runs ->
          "\n\nRuns that you can claim an account from, with `ehosctl github claim RUN`:\n" <>
            (runs
             |> Enum.map(fn run ->
               %{
                 "LOGIN" => Refusal.shown(run["login"]),
                 "REPOSITORY" => Refusal.named(run["repository"]),
                 "REF" => Refusal.named(run["ref"]),
                 "COMMIT" => short(run["sha"]),
                 "AT" => Output.date(run["at"]),
                 "RUN" => Refusal.shown(run["exchange"])
               }
             end)
             |> Output.table(["LOGIN", "REPOSITORY", "REF", "COMMIT", "AT", "RUN"]))
      end

    accounts_text <> runs_text
  end

  defp state(%{"removed_at" => removed}) when is_binary(removed), do: "removed"
  defp state(%{"confirmed_at" => confirmed}) when is_binary(confirmed), do: "linked"
  defp state(_account), do: "claimed, not confirmed yet"

  defp note(claim) do
    [
      claim["confirmable"] == false && "yours: another people manager confirms it",
      claim["contested"] && "someone else claims it too"
    ]
    |> Enum.filter(&is_binary/1)
    |> noted()
  end

  defp noted([]), do: Output.none()
  defp noted(notes), do: Enum.join(notes, "; ")

  defp waiting_text([]),
    do:
      "No claim of a GitHub account waits for confirmation. A claim shows here after a " <>
        "person runs `ehosctl github claim`."

  defp waiting_text(waiting) do
    waiting
    |> Enum.map(fn claim ->
      %{
        "PERSON" => Refusal.shown(claim["person"]["email"]),
        "LOGIN" => Refusal.shown(claim["login"]),
        "REPOSITORY" => Refusal.named((claim["run"] || %{})["repository"]),
        "NOTE" => note(claim),
        "ID" => Refusal.shown(claim["id"])
      }
    end)
    |> Output.table(["PERSON", "LOGIN", "REPOSITORY", "NOTE", "ID"])
  end
end

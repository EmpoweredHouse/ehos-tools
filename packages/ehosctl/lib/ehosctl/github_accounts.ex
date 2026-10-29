defmodule Ehosctl.GitHubAccounts do
  @moduledoc """
  GitHub accounts linked to people, so that a GitHub Actions job deploys on behalf of the person
  whose push started it (eh-os
  [`docs/deployment-identity-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/deployment-identity-api.md#github-accounts),
  D-110), as the console's **GitHub accounts** page links them.

  Linking takes two people, and nobody types an id or a login:

    * `ehosctl github list | claim | remove`: a person's own accounts, and the refused runs they
      may claim an account from. `claim` shows the run, its page on GitHub included, and asks
      whether it is theirs (`--yes` answers); with no run named, it takes the one there is.
    * `ehosctl people github list | confirm | remove`: a people manager's view of the claims
      waiting, each with the run it was claimed from. `confirm` shows the person and the run,
      warns when someone else claims the same account, and asks; a login is whatever its owner
      chose, so the person is checked with outside EHOS.

  EHOS decides and records each call, and its refusal is printed in its words.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @look "`ehosctl github list`"
  @look_waiting "`ehosctl people github list`"

  @impl Ehosctl.Command
  def name, do: :github

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "List, claim and remove your GitHub accounts, which a GitHub Actions job deploys on " <>
          "behalf of.",
      subcommands: [
        list: [
          name: "list",
          about: "List your GitHub accounts, and the refused runs you may claim one from.",
          flags: Output.json_flag()
        ],
        claim: [
          name: "claim",
          about:
            "Claim the GitHub account a refused run of yours names; a people manager then " <>
              "confirms it.",
          args: [
            run: [
              value_name: "RUN",
              required: false,
              help: "The run, as `list` prints it; the only one there is when left out."
            ]
          ],
          flags: [yes: [long: "--yes", help: "Do not ask."]] ++ Output.json_flag()
        ],
        remove: [
          name: "remove",
          about: "Remove one of your GitHub accounts: its next run is refused.",
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
        about: "List, confirm and remove the GitHub accounts people claim.",
        subcommands: [
          list: [
            name: "list",
            about: "List the claims waiting, the oldest first, each with its run.",
            flags: Output.json_flag()
          ],
          confirm: [
            name: "confirm",
            about:
              "Confirm a claim, after checking with the person that the run is theirs; never " <>
                "your own.",
            args: [account: account_arg()],
            flags: [yes: [long: "--yes", help: "Do not ask."]] ++ Output.json_flag()
          ],
          remove: [
            name: "remove",
            about: "Remove a person's GitHub account, or turn down a claim.",
            args: [account: account_arg()],
            flags: Output.json_flag()
          ]
        ]
      ]
    ]
  end

  defp account_arg,
    do: [value_name: "ACCOUNT", required: true, help: "The account's id, as `list` prints it."]

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
          "Claimed #{Refusal.shown(account["login"])}: account #{Refusal.shown(account["id"])}. " <>
            "A people manager confirms it; until then its runs are refused."
        end
      )
    else
      :not_confirmed -> {:ok, %{text: "Nothing was claimed.", json: nil}}
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

    with :ok <- an_id(id),
         {:ok, waiting} <- waiting(opts),
         {:ok, claim} <- waiting_claim(waiting, id),
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
            "#{Refusal.shown(claim["person"]["email"])}: their runs now deploy on their behalf."
        end
      )
    else
      :not_confirmed -> {:ok, %{text: "Nothing was confirmed.", json: nil}}
      error -> error
    end
  end

  def people([:remove], parsed, opts),
    do: remove("/api/v1/github-accounts/", parsed.args.account, @look_waiting, opts)

  defp remove(prefix, id, look, opts) do
    with :ok <- an_id(id) do
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
          "Removed #{Refusal.shown(account["login"])}: its next run is refused."
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
       "No refused run of yours can be claimed from: run a GitHub Actions job of a trusted " <>
         "repository first, and its refusal names your account here."}

  defp chosen([run], nil), do: {:ok, run}

  defp chosen(_runs, nil),
    do:
      {:error, :invalid, "You have several runs to claim from: name one, as #{@look} prints it."}

  defp chosen(runs, id) do
    case Enum.find(runs, &same_id?(&1["exchange"], id)) do
      nil -> {:error, :failed, "#{Refusal.shown(id)} is none of your runs to claim from."}
      run -> {:ok, run}
    end
  end

  defp waiting_claim(waiting, id) do
    case Enum.find(waiting, &same_id?(&1["id"], id)) do
      nil ->
        {:error, :failed,
         "#{Refusal.shown(id)} is no claim waiting: run #{@look_waiting} to see them."}

      claim ->
        {:ok, claim}
    end
  end

  defp claim_question(run),
    do:
      "The run of #{Refusal.shown(run["login"])}, GitHub id #{run["github_id"]}:\n" <>
        run_text(run) <> "\nIs this run yours?"

  defp confirm_question(claim) do
    contested =
      if claim["contested"],
        do:
          "\nSomeone else claims this account too: confirm it only for the person whose run " <>
            "this is.",
        else: ""

    "#{Refusal.shown(claim["person"]["email"])} claims #{Refusal.shown(claim["login"])}, " <>
      "GitHub id #{claim["github_id"]}, from this run:\n" <>
      run_text(claim["run"]) <>
      contested <> "\nHave you checked with them that it is theirs?"
  end

  # A claim made before EHOS kept the run it rests on has none (eh-os's claims from before
  # 2026-10-16), and a run may leave out what GitHub did not sign.
  defp run_text(nil), do: "  a run EHOS no longer shows: check with them which one it was"

  defp run_text(run) do
    [
      "  #{field(run, "repository")} at #{field(run, "ref")}, #{field(run, "event_name")}, " <>
        "commit #{short(run["sha"])}, #{field(run, "at")}",
      run["run_url"] && "  #{Refusal.shown(run["run_url"])}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp field(run, key), do: if(run[key], do: Refusal.shown(run[key]), else: "unknown")

  defp short(sha) when is_binary(sha), do: Refusal.shown(String.slice(sha, 0, 12))
  defp short(_sha), do: "unknown"

  defp confirmed(question, parsed) do
    if parsed.flags.yes or confirm(question),
      do: :ok,
      else: :not_confirmed
  end

  # A question with no answer, as a script's stdin gives, is a no.
  defp confirm(question) do
    case Ehosctl.Terminal.current().gets(question <> " [y/N] ") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      nil -> false
    end
  end

  defp an_id(id) when Api.is_nameless(id),
    do: {:error, :invalid, "#{Refusal.shown(id)} names no account."}

  defp an_id(_id), do: :ok

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
           is_boolean(claim["contested"])

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
  end

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp mine_text(accounts, runs) do
    accounts_text =
      case accounts do
        [] ->
          "You have no GitHub account."

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
          "\n\nRuns you may claim an account from, with `ehosctl github claim RUN`:\n" <>
            (runs
             |> Enum.map(fn run ->
               %{
                 "LOGIN" => Refusal.shown(run["login"]),
                 "REPOSITORY" => Refusal.shown(run["repository"] || ""),
                 "REF" => Refusal.shown(run["ref"] || ""),
                 "AT" => Refusal.shown(run["at"] || ""),
                 "RUN" => Refusal.shown(run["exchange"])
               }
             end)
             |> Output.table(["LOGIN", "REPOSITORY", "REF", "AT", "RUN"]))
      end

    accounts_text <> runs_text
  end

  defp state(%{"removed_at" => removed}) when is_binary(removed), do: "removed"
  defp state(%{"confirmed_at" => confirmed}) when is_binary(confirmed), do: "linked"
  defp state(_account), do: "claimed, not confirmed yet"

  defp waiting_text([]), do: "No claim of a GitHub account is waiting."

  defp waiting_text(waiting) do
    waiting
    |> Enum.map(fn claim ->
      %{
        "PERSON" => Refusal.shown(claim["person"]["email"]),
        "LOGIN" => Refusal.shown(claim["login"]),
        "REPOSITORY" => Refusal.shown((claim["run"] || %{})["repository"] || ""),
        "NOTE" => if(claim["contested"], do: "someone else claims it too", else: ""),
        "ID" => Refusal.shown(claim["id"])
      }
    end)
    |> Output.table(["PERSON", "LOGIN", "REPOSITORY", "NOTE", "ID"])
  end
end

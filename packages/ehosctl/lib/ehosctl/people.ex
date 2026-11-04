defmodule Ehosctl.People do
  @moduledoc """
  `ehosctl people list | show | invite | rename | disable | enable | sign-out`: the company's
  people, through EHOS's API (eh-os
  [`docs/people-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/people-api.md),
  [D-80](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0080-ehos-s-api-lists-people-to-ehos-people-read-and-manages-them-for-ehos-people-manage.md)).

  Listing and showing need `ehos.people.read`; the rest `ehos.people.manage`, which implies it.
  EHOS decides and records each call, and its refusal is printed in its words. `sign-out`, which
  signs out every terminal of a person as the people page does, needs `ehos.people.manage`
  whoever is named, oneself included: a person signs their own out one by one with
  `ehosctl terminals sign-out`.

  A person is named by their id or by their email: a word with an `@` is an email, found with
  `GET /api/v1/people?q=`, among every state for a command that manages them and among the invited
  and the joined for `show`, since only a people manager may list the disabled.

  `invite` says whether the sign-in link was mailed, and never prints one: the API never gives
  one (D-80), and whatever else an answer holds is left out. No command sets or resets a password.

  `ehosctl people agreements | agree | withdraw`: the applications that may read the people, in
  each environment, as the people page agrees (`Ehosctl.Agreements`).

  `ehosctl people github list | confirm | remove`: the GitHub accounts people claim, which a
  people manager confirms (`Ehosctl.GitHubAccounts`, eh-os D-110).
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Agreements
  alias Ehosctl.Api
  alias Ehosctl.GitHubAccounts
  alias Ehosctl.Output
  alias Ehosctl.Pages
  alias Ehosctl.Refusal

  require Ehosctl.Api

  # The largest page EHOS gives; `Ehosctl.Pages` bounds how many are read for one list.
  @page 500

  @impl Ehosctl.Command
  def name, do: :people

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    person = [
      value_name: "PERSON",
      required: true,
      help: "The id or the email of the person."
    ]

    [
      about:
        "Manage the people of the company: list, invite, rename, disable and enable them. " <>
          "Also sign out their terminals, agree to applications that read them, and confirm " <>
          "their GitHub accounts.",
      subcommands:
        [
          list: [
            name: "list",
            about: "List the people, in the order of their email.",
            options: [
              state: [
                long: "--state",
                value_name: "STATES",
                help:
                  "The states to show, separated by commas: invited, joined, disabled. The " <>
                    "default is invited,joined. To show disabled people, you need " <>
                    "ehos.people.manage."
              ],
              q: [
                long: "--q",
                value_name: "PREFIX",
                help:
                  "Show only the people whose name or email starts with this text. The case " <>
                    "of the letters does not matter."
              ],
              limit: [
                long: "--limit",
                value_name: "N",
                parser: :integer,
                help: "Show at most this number of people. The default is all people."
              ]
            ],
            flags: Output.json_flag()
          ],
          show: [
            name: "show",
            about: "Show one person.",
            args: [person: person],
            flags: Output.json_flag()
          ],
          invite: [
            name: "invite",
            about:
              "Invite a person. ehosctl says if EHOS mailed a sign-in link to the person. " <>
                "ehosctl never shows the link.",
            args: [email: [value_name: "EMAIL", required: true, help: "The email of the person."]],
            options: [
              name: [
                long: "--name",
                value_name: "NAME",
                help: "The name of the person. The person can change it later."
              ]
            ],
            flags: Output.json_flag()
          ],
          rename: [
            name: "rename",
            about: "Change the name of a person. An empty name removes the name.",
            args: [
              person: person,
              name: [
                value_name: "NAME",
                required: true,
                help: "The new name, or \"\" to remove the name."
              ]
            ],
            flags: Output.json_flag()
          ],
          disable: [
            name: "disable",
            about:
              "Disable a person. Their sign-in ends now, and their credentials stop working " <>
                "within 10 minutes.",
            args: [person: person],
            flags: Output.json_flag()
          ],
          enable: [
            name: "enable",
            about: "Enable a disabled person again.",
            args: [person: person],
            flags: Output.json_flag()
          ],
          "sign-out": [
            name: "sign-out",
            about:
              "Sign out all terminals of a person. The person stays enabled. Their commands " <>
                "stop within 10 minutes.",
            args: [person: person],
            flags: Output.json_flag()
          ]
        ] ++ Agreements.people_spec() ++ GitHubAccounts.people_spec()
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([action], parsed, opts) when action in [:agreements, :agree, :withdraw],
    do: Agreements.people(action, parsed, opts)

  def call([:github, action], parsed, opts), do: GitHubAccounts.people([action], parsed, opts)

  def call([:list], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{state: state, q: q, limit: limit} = parsed.options

    with :ok <- positive(limit),
         {:ok, people, more?} <- list(installation, %{state: state, q: q}, limit, opts) do
      {:ok, %{text: table(people, more?), json: %{people: people, more: more?}}}
    end
  end

  def call([:show], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, person} <- find(installation, parsed.args.person, :read, opts) do
      {:ok, %{text: shown(person), json: %{person: person}}}
    end
  end

  def call([:invite], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    body =
      Map.reject(%{email: parsed.args.email, name: parsed.options.name}, &is_nil(elem(&1, 1)))

    with {:ok, %{status: 201, body: %{"person" => person, "delivery" => delivery}}}
         when delivery in ["mailed", "none"] <-
           write(installation, :post, "/api/v1/people", body, opts),
         true <- person?(person) || done_unread(installation) do
      person = only_person(person)
      {:ok, %{text: invited(person, delivery), json: %{person: person, delivery: delivery}}}
    else
      {:ok, %{status: 201}} -> done_unread(installation)
      {:ok, answer} -> unanswered_write(answer, installation)
      error -> error
    end
  end

  def call([:rename], parsed, opts) do
    name = parsed.args.name

    # What EHOS kept, which says whether the name was removed: a blank one is.
    manage(parsed, opts, :patch, "", %{name: name}, fn person ->
      if person["name"] in [nil, ""],
        do: "Removed the name of #{label(person)}.",
        else: "Renamed #{Refusal.shown(person["email"])} to #{Refusal.shown(person["name"])}."
    end)
  end

  def call([:disable], parsed, opts),
    do:
      manage(parsed, opts, :post, "/disable", nil, fn person ->
        "Disabled #{label(person)}. Their sign-in has ended, and each credential that they " <>
          "hold stops working within 10 minutes."
      end)

  def call([:enable], parsed, opts),
    do: manage(parsed, opts, :post, "/enable", nil, &"Enabled #{label(&1)}.")

  def call([:"sign-out"], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"id" => id} = person} <- find(installation, parsed.args.person, :manage, opts) do
      installation
      |> Api.answer(:delete, "/api/v1/people/" <> Api.segment(id) <> "/terminals", nil, opts)
      |> signed_out(person, installation)
    end
  end

  defp manage(parsed, opts, method, suffix, body, said) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"id" => id}} <- find(installation, parsed.args.person, :manage, opts),
         {:ok, %{status: 200, body: %{"person" => person}}} <-
           write(installation, method, "/api/v1/people/" <> Api.segment(id) <> suffix, body, opts),
         true <- person?(person) || done_unread(installation) do
      person = only_person(person)
      {:ok, %{text: said.(person), json: %{person: person}}}
    else
      {:ok, %{status: 200}} -> done_unread(installation)
      {:ok, answer} -> unanswered_write(answer, installation)
      error -> error
    end
  end

  # Nothing shows another person's terminals, but signing them out again changes nothing more.
  @again " EHOS possibly signed out the terminals. You can run the command again safely."

  # EHOS answers how many sign-ins it ended, which may be none.
  defp signed_out({:ok, %{status: 200, body: %{"signed_out" => count}}}, person, _installation)
       when is_integer(count) and count >= 0,
       do: {:ok, %{text: every_terminal(person, count), json: %{signed_out: count}}}

  defp signed_out({:ok, %{status: status}}, _person, installation) when status in 200..299 do
    {:error, kind, message} = Api.unexpected(installation)
    {:error, kind, message <> " EHOS said that it signed out the terminals."}
  end

  defp signed_out({:ok, %{status: status} = answer}, _person, installation) when status >= 500 do
    refused = Api.refusal(answer, installation)
    if Api.coded?(answer.body), do: refused, else: Refusal.added(refused, @again)
  end

  defp signed_out({:ok, answer}, _person, installation), do: Api.refusal(answer, installation)

  defp signed_out({:error, kind, message, :sent}, _person, _installation),
    do: {:error, kind, message <> @again}

  defp signed_out(error, _person, _installation), do: error

  # The console's words, and how many there were.
  defp every_terminal(person, count) do
    done = "Signed out all terminals of #{named(person)}."

    case count do
      0 -> done <> " No terminal was signed in."
      1 -> done <> " 1 terminal was signed in. Its commands stop within 10 minutes."
      n -> done <> " #{n} terminals were signed in. Their commands stop within 10 minutes."
    end
  end

  # A person named by id is not looked up, so they are named by it.
  defp named(%{"email" => email} = person) when is_binary(email), do: label(person)
  defp named(%{"id" => id}), do: "the person #{Refusal.shown(id)}"

  @look " EHOS possibly made the change. Run `ehosctl people show` to see the person."

  # A 5xx with no code of EHOS's own, a gateway's, may have come after the write was done.
  defp unanswered_write(%{status: status} = answer, installation) when status >= 500 do
    refused = Api.refusal(answer, installation)
    if Api.coded?(answer.body), do: refused, else: Refusal.added(refused, @look)
  end

  defp unanswered_write(answer, installation), do: Api.refusal(answer, installation)

  # A write EHOS answered as done, with something ehosctl cannot read.
  defp done_unread(installation) do
    {:error, kind, message} = Api.unexpected(installation)

    {:error, kind,
     message <> " EHOS said that it made the change. Run `ehosctl people show` to see the person."}
  end

  # Only what people-api.md says a person is: whatever else an answer holds, a sign-in link
  # among it, is never printed (D-80).
  defp only_person(person), do: Map.take(person, ~w(id email name state))

  # A write that went unanswered may have been done; doing it again is harmless, as each of them
  # leaves the person as asked, so the person is told to look.
  defp write(installation, method, path, body, opts) do
    case Api.answer(installation, method, path, body, opts) do
      {:error, kind, message, :sent} ->
        {:error, kind, message <> @look}

      result ->
        result
    end
  end

  @doc """
  The people `filter` (`:state`, `:q`) matches, at most `limit` of them (`nil` for every one),
  following each page's `Link: rel="next"` (`Ehosctl.Pages`), and whether more match.
  """
  @spec list({String.t(), map()}, map(), pos_integer() | nil, keyword()) ::
          {:ok, [map()], boolean()} | Refusal.error()
  def list(installation, filter, limit, opts) do
    query =
      [state: filter[:state], q: filter[:q], limit: min(limit || @page, @page)]
      |> Enum.reject(&is_nil(elem(&1, 1)))
      |> URI.encode_query()

    Pages.read(
      installation,
      "/api/v1/people?" <> query,
      [key: "people", valid?: &person?/1, only: &only_person/1],
      limit,
      opts
    )
  end

  defp read(installation, path, opts) do
    case Api.answer(installation, :get, path, nil, opts) do
      {:error, kind, message, :sent} -> {:error, kind, message}
      result -> result
    end
  end

  # A person named by id is that id, read for `show`; by email, found among those `show` may list,
  # or, for a command that manages them, among every state.
  defp find(installation, word, need, opts) do
    cond do
      String.contains?(word, "@") ->
        by_email(installation, word, need, opts)

      Api.is_nameless(word) ->
        {:error, :invalid,
         "#{Refusal.shown(word)} is not an id. Give the id or the email of the person."}

      need == :manage ->
        {:ok, %{"id" => word}}

      true ->
        with {:ok, answer} <- read(installation, "/api/v1/people/" <> Api.segment(word), opts) do
          person_read(answer, installation)
        end
    end
  end

  defp by_email(installation, word, need, opts) do
    states = if need == :manage, do: "invited,joined,disabled", else: "invited,joined"
    email = String.downcase(word)

    with {:ok, people, _more?} <- list(installation, %{state: states, q: word}, nil, opts) do
      case Enum.find(people, &(String.downcase(&1["email"]) == email)) do
        nil -> {:error, :failed, nobody(word, need)}
        person -> {:ok, person}
      end
    end
  end

  defp person_read(%{status: 200, body: %{"person" => person}}, installation) do
    if person?(person),
      do: {:ok, only_person(person)},
      else: Api.unexpected(installation)
  end

  defp person_read(answer, installation), do: Api.refusal(answer, installation)

  defp nobody(email, :manage),
    do:
      "No person has the email #{Refusal.shown(email)}. Check the email, or run " <>
        "`ehosctl people list --state invited,joined,disabled` to see the people."

  defp nobody(email, :read),
    do:
      "No invited or joined person has the email #{Refusal.shown(email)}. To show a disabled " <>
        "person, give their id. Run `ehosctl people list --state disabled` to see the ids."

  defp positive(nil), do: :ok
  defp positive(limit) when limit > 0, do: :ok
  defp positive(_limit), do: {:error, :invalid, "--limit must be a whole number of 1 or more."}

  defp person?(%{"id" => id, "email" => email, "state" => state} = person),
    do:
      is_binary(id) and not Api.is_nameless(id) and is_binary(email) and is_binary(state) and
        (is_nil(person["name"]) or is_binary(person["name"]))

  defp person?(_person), do: false

  defp invited(person, "mailed"),
    do: "Invited #{label(person)}. EHOS mailed a sign-in link to them."

  defp invited(person, "none"),
    do:
      "Invited #{label(person)}. This installation does not send mail, so EHOS sent no " <>
        "sign-in link. To give them a link, a people manager invites them again in the console."

  defp label(%{"name" => name, "email" => email}) when is_binary(name) and name != "",
    do: "#{Refusal.shown(name)} <#{Refusal.shown(email)}>"

  defp label(person), do: Refusal.shown(person["email"])

  defp shown(person) do
    Enum.join(
      [
        "email: #{Refusal.shown(person["email"])}",
        "name:  #{if person["name"] in [nil, ""], do: "(none)", else: Refusal.shown(person["name"])}",
        "state: #{Refusal.shown(person["state"])}",
        "id:    #{Refusal.shown(person["id"])}"
      ],
      "\n"
    )
  end

  @columns ["EMAIL", "NAME", "STATE", "ID"]

  defp table([], _more?),
    do:
      "No people match. A person shows here after a people manager invites them. " <>
        "Change --state or --q to see other people."

  defp table(people, more?) do
    rows =
      people
      |> Enum.map(fn person ->
        %{
          "EMAIL" => Refusal.shown(person["email"]),
          "NAME" => if(is_binary(person["name"]), do: Refusal.shown(person["name"]), else: ""),
          "STATE" => Refusal.shown(person["state"]),
          "ID" => Refusal.shown(person["id"])
        }
      end)
      |> Output.table(@columns)

    if more?, do: rows <> "\nMore people match. Give a higher --limit to see them.", else: rows
  end
end

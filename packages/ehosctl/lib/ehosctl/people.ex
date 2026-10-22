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
      help: "The person: their id, or their email."
    ]

    [
      about:
        "List, invite, rename, disable and enable the company's people, sign out their " <>
          "terminals, agree to applications reading them, and confirm their GitHub accounts.",
      subcommands:
        [
          list: [
            name: "list",
            about: "List the people, ordered by email.",
            options: [
              state: [
                long: "--state",
                value_name: "STATES",
                help:
                  "Comma-separated: invited, joined, disabled. By default invited,joined; " <>
                    "disabled needs ehos.people.manage."
              ],
              q: [
                long: "--q",
                value_name: "PREFIX",
                help: "Only the people whose name or email starts with it, in any case."
              ],
              limit: [
                long: "--limit",
                value_name: "N",
                parser: :integer,
                help: "At most this many people. By default every one."
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
            about: "Invite someone. Says whether their sign-in link was mailed, never the link.",
            args: [email: [value_name: "EMAIL", required: true, help: "Their email."]],
            options: [
              name: [
                long: "--name",
                value_name: "NAME",
                help: "Their name, which they can change."
              ]
            ],
            flags: Output.json_flag()
          ],
          rename: [
            name: "rename",
            about: "Change a person's name. An empty name removes it.",
            args: [
              person: person,
              name: [value_name: "NAME", required: true, help: "The new name, or \"\" for none."]
            ],
            flags: Output.json_flag()
          ],
          disable: [
            name: "disable",
            about:
              "Disable a person: their sign-in ends now, and their credentials within minutes.",
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
              "Sign out every terminal of a person, without disabling them: their commands stop " <>
                "within ten minutes.",
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
        "Disabled #{label(person)}: their sign-in has ended, and every credential they hold " <>
          "stops working within ten minutes."
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
  @again " It may have been done: signing their terminals out again is harmless."

  # EHOS answers how many sign-ins it ended, which may be none.
  defp signed_out({:ok, %{status: 200, body: %{"signed_out" => count}}}, person, _installation)
       when is_integer(count) and count >= 0,
       do: {:ok, %{text: every_terminal(person, count), json: %{signed_out: count}}}

  defp signed_out({:ok, %{status: status}}, _person, installation) when status in 200..299 do
    {:error, kind, message} = Api.unexpected(installation)
    {:error, kind, message <> " It said it was done."}
  end

  defp signed_out({:ok, %{status: status} = answer}, _person, installation) when status >= 500 do
    {:error, kind, message} = Api.refusal(answer, installation)

    if Api.coded?(answer.body),
      do: {:error, kind, message},
      else: {:error, kind, message <> @again}
  end

  defp signed_out({:ok, answer}, _person, installation), do: Api.refusal(answer, installation)

  defp signed_out({:error, kind, message, :sent}, _person, _installation),
    do: {:error, kind, message <> @again}

  defp signed_out(error, _person, _installation), do: error

  # The console's words, and how many there were.
  defp every_terminal(person, count) do
    done = "Every terminal of #{named(person)} is signed out"

    case count do
      0 -> done <> ": none was signed in."
      1 -> done <> ": 1 was signed in, and its commands stop within ten minutes."
      n -> done <> ": #{n} were signed in, and their commands stop within ten minutes."
    end
  end

  # A person named by id is not looked up, so they are named by it.
  defp named(%{"email" => email} = person) when is_binary(email), do: label(person)
  defp named(%{"id" => id}), do: "the person #{Refusal.shown(id)}"

  @look " It may have been done: run `ehosctl people show` to see the person."

  # A 5xx with no code of EHOS's own, a gateway's, may have come after the write was done.
  defp unanswered_write(%{status: status} = answer, installation) when status >= 500 do
    {:error, kind, message} = Api.refusal(answer, installation)

    if Api.coded?(answer.body),
      do: {:error, kind, message},
      else: {:error, kind, message <> @look}
  end

  defp unanswered_write(answer, installation), do: Api.refusal(answer, installation)

  # A write EHOS answered as done, with something ehosctl cannot read.
  defp done_unread(installation) do
    {:error, kind, message} = Api.unexpected(installation)

    {:error, kind,
     message <> " It said it was done: run `ehosctl people show` to see the person."}
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
        states = if need == :manage, do: "invited,joined,disabled", else: "invited,joined"
        email = String.downcase(word)

        with {:ok, people, _more?} <- list(installation, %{state: states, q: word}, nil, opts) do
          case Enum.find(people, &(String.downcase(&1["email"]) == email)) do
            nil -> {:error, :failed, nobody(word, need)}
            person -> {:ok, person}
          end
        end

      Api.is_nameless(word) ->
        {:error, :invalid, "#{Refusal.shown(word)} is not an id; name a person by id or email."}

      need == :manage ->
        {:ok, %{"id" => word}}

      true ->
        with {:ok, answer} <- read(installation, "/api/v1/people/" <> Api.segment(word), opts) do
          case answer do
            %{status: 200, body: %{"person" => person}} ->
              if person?(person),
                do: {:ok, only_person(person)},
                else: Api.unexpected(installation)

            answer ->
              Api.refusal(answer, installation)
          end
        end
    end
  end

  defp nobody(email, :manage), do: "Nobody has the email #{Refusal.shown(email)}."

  defp nobody(email, :read),
    do:
      "No invited or joined person has the email #{Refusal.shown(email)}. A disabled person " <>
        "is shown by their id, which `ehosctl people list --state disabled` lists."

  defp positive(nil), do: :ok
  defp positive(limit) when limit > 0, do: :ok
  defp positive(_limit), do: {:error, :invalid, "--limit is a whole number from 1."}

  defp person?(%{"id" => id, "email" => email, "state" => state} = person),
    do:
      is_binary(id) and not Api.is_nameless(id) and is_binary(email) and is_binary(state) and
        (is_nil(person["name"]) or is_binary(person["name"]))

  defp person?(_person), do: false

  defp invited(person, "mailed"),
    do: "Invited #{label(person)}. Their sign-in link was mailed to them."

  defp invited(person, "none"),
    do:
      "Invited #{label(person)}. This installation sends no mail, so no sign-in link was " <>
        "sent: a people manager hands one over by inviting them again in the console."

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

  defp table([], _more?), do: "No people match."

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

    if more?, do: rows <> "\nMore people match: raise --limit to see them.", else: rows
  end
end

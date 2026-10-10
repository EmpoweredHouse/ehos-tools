defmodule Ehosctl.People do
  @moduledoc """
  `ehosctl people list | show | invite | rename | disable | enable`: the company's people, through
  EHOS's API (eh-os
  [`docs/people-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/people-api.md),
  [D-80](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0080-ehos-s-api-lists-people-to-ehos-people-read-and-manages-them-for-ehos-people-manage.md)).

  Listing and showing need `ehos.people.read`; the rest `ehos.people.manage`, which implies it.
  EHOS decides and records each call, and its refusal is printed in its words.

  A person is named by their id or by their email: a word with an `@` is an email, found with
  `GET /api/people?q=`, among every state for a command that manages them and among the invited
  and the joined for `show`, since only a people manager may list the disabled.

  `invite` says whether the sign-in link was mailed, and never prints one: the API never gives
  one (D-80), and whatever else an answer holds is left out. No command sets or resets a password.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  # The largest page EHOS gives.
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
      about: "List, invite, rename, disable and enable the company's people.",
      subcommands: [
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
            name: [long: "--name", value_name: "NAME", help: "Their name, which they can change."]
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
        ]
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
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
           write(installation, :post, "/api/people", body, opts),
         true <- person?(person) || Api.unexpected(installation) do
      {:ok, %{text: invited(person, delivery), json: %{person: person, delivery: delivery}}}
    else
      {:ok, %{status: 201}} -> Api.unexpected(installation)
      {:ok, answer} -> Api.refusal(answer, installation)
      error -> error
    end
  end

  def call([:rename], parsed, opts) do
    name = parsed.args.name

    manage(parsed, opts, :patch, "", %{name: name}, fn person ->
      if name == "",
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

  defp manage(parsed, opts, method, suffix, body, said) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"id" => id}} <- find(installation, parsed.args.person, :manage, opts),
         {:ok, %{status: 200, body: %{"person" => person}}} <-
           write(installation, method, "/api/people/" <> segment(id) <> suffix, body, opts),
         true <- person?(person) || Api.unexpected(installation) do
      {:ok, %{text: said.(person), json: %{person: person}}}
    else
      {:ok, answer} -> Api.refusal(answer, installation)
      error -> error
    end
  end

  # A write that went unanswered may have been done; doing it again is harmless, as each of them
  # leaves the person as asked, so the person is told to look.
  defp write(installation, method, path, body, opts) do
    case Api.answer(installation, method, path, body, opts) do
      {:error, kind, message, :sent} ->
        {:error, kind,
         message <> " It may have been done: run `ehosctl people show` to see the person."}

      result ->
        result
    end
  end

  @doc """
  The people `filter` (`:state`, `:q`) matches, at most `limit` of them (`nil` for every one),
  following each page's `Link: rel="next"`, and whether more match.

  The next page is asked of the installation's own address, with the path and query the link
  gives: a link elsewhere would carry the credential there.
  """
  @spec list({String.t(), map()}, map(), pos_integer() | nil, keyword()) ::
          {:ok, [map()], boolean()} | Refusal.error()
  def list(installation, filter, limit, opts) do
    query =
      [state: filter[:state], q: filter[:q], limit: min(limit || @page, @page)]
      |> Enum.reject(&is_nil(elem(&1, 1)))
      |> URI.encode_query()

    pages(installation, "/api/people?" <> query, [], limit, opts)
  end

  defp pages(installation, path, people, limit, opts) do
    with {:ok, answer} <- read(installation, path, opts),
         %{status: 200, body: %{"people" => page}} when is_list(page) <- answer,
         true <- Enum.all?(page, &person?/1) || Api.unexpected(installation) do
      people = people ++ page
      next = next(answer.headers["link"])

      cond do
        limit != nil and length(people) >= limit ->
          {:ok, Enum.take(people, limit), length(people) > limit or next != nil}

        next == nil or next == path or page == [] ->
          {:ok, people, false}

        true ->
          pages(installation, next, people, limit, opts)
      end
    else
      %{} = answer -> Api.refusal(answer, installation)
      error -> error
    end
  end

  defp read(installation, path, opts) do
    case Api.answer(installation, :get, path, nil, opts) do
      {:error, kind, message, :sent} -> {:error, kind, message}
      result -> result
    end
  end

  # `<https://…/api/people?…>; rel="next"`: its path and query, when the path is the list's.
  defp next(nil), do: nil

  defp next(link) do
    with [_, target] <- Regex.run(~r/<([^>]*)>\s*;\s*rel="?next"?/, link),
         %URI{path: "/api/people", query: query} when is_binary(query) <- URI.parse(target) do
      "/api/people?" <> query
    else
      _ -> nil
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

      need == :manage ->
        {:ok, %{"id" => word}}

      true ->
        with {:ok, answer} <- read(installation, "/api/people/" <> segment(word), opts) do
          case answer do
            %{status: 200, body: %{"person" => person}} ->
              if person?(person), do: {:ok, person}, else: Api.unexpected(installation)

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

  defp segment(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp positive(nil), do: :ok
  defp positive(limit) when limit > 0, do: :ok
  defp positive(_limit), do: {:error, :invalid, "--limit is a whole number from 1."}

  defp person?(%{"id" => id, "email" => email, "state" => state} = person),
    do:
      is_binary(id) and id != "" and is_binary(email) and is_binary(state) and
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

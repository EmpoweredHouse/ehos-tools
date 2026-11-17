defmodule Ehosctl.Terminals do
  @moduledoc """
  `ehosctl terminals` and `ehosctl terminals sign-out <id>`: the person's own terminals signed in
  with `ehosctl login`, and one of them signed out, as the console's settings list them and sign
  them out (eh-os
  [`docs/terminal-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/terminal-api.md),
  D-89). Neither needs a capability, since each reaches only what is the caller's. EHOS records a
  sign-out; one of a terminal that is not the caller's, or has ended, it refuses and does not
  record.

  A terminal is named by its id, which the list prints in full. The list does not say which is the
  one this `ehosctl` runs on: EHOS's API does not say which sign-in a credential belongs to, and
  the second a sign-in was made does not tell two apart (a second `login` within minutes of the
  first shares its time, and the first lives on at EHOS). `--json` prints EHOS's answer, kept to
  the four fields read.

  Every terminal of another person is signed out with `ehosctl people sign-out`, a people
  manager's.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @times ~w(signed_in_at last_used_at ends_at)

  @impl Ehosctl.Command
  def name, do: :terminals

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :sign_in

  @impl Ehosctl.Command
  def summary, do: "List your signed-in terminals, and sign one out."

  @impl Ehosctl.Command
  def runs_bare?, do: true

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "List your terminals that are signed in with `ehosctl login`, the newest first, " <>
          "and sign out a terminal.",
      flags: Output.json_flag(),
      subcommands: [
        "sign-out": [
          name: "sign-out",
          about:
            "Sign out one of your terminals. The terminal cannot renew its sign-in, so its " <>
              "commands stop within 10 minutes.",
          args: [
            id: [
              value_name: "ID",
              required: true,
              help: "The id of the terminal, as `ehosctl terminals` shows it."
            ]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], _parsed, opts) do
    named = Keyword.fetch!(opts, :installation)

    with {:ok, %{"terminals" => terminals}} when is_list(terminals) <-
           Api.read(named, "/api/v1/me/terminals", opts),
         true <- Enum.all?(terminals, &terminal?/1) || Api.unexpected(named) do
      terminals = Enum.map(terminals, &Map.take(&1, ["id" | @times]))

      {:ok, %{text: table(terminals), json: %{terminals: terminals}}}
    else
      {:ok, _body} -> Api.unexpected(named)
      error -> error
    end
  end

  # A word that would leave its place in the path (`.`, `..`), or names nothing, is refused before
  # anything is sent: a proxy that resolves dot segments would send it elsewhere.
  def call([:"sign-out"], %{args: %{id: id}}, _opts) when Api.is_nameless(id),
    do:
      {:error, :invalid,
       "#{Refusal.shown(id)} is not the id of a terminal. Run `ehosctl terminals` to see " <>
         "the ids."}

  def call([:"sign-out"], %{args: %{id: id}}, opts) do
    Api.write(
      opts,
      {:delete, "/api/v1/me/terminals/" <> Api.segment(id), nil},
      [
        status: 200,
        key: "signed_out",
        # One terminal, the one named: anything else is not what was asked.
        valid?: &(&1 === 1),
        only: & &1,
        look: "`ehosctl terminals`"
      ],
      fn _count ->
        "Signed out the terminal #{Refusal.shown(id)}. It cannot renew its sign-in, so its " <>
          "commands stop within 10 minutes."
      end
    )
  end

  defp terminal?(%{"id" => id} = terminal),
    do:
      is_binary(id) and not Api.is_nameless(id) and
        Enum.all?(@times, &time?(terminal[&1]))

  defp terminal?(_terminal), do: false

  defp time?(at) when is_binary(at),
    do: match?({:ok, _datetime, _offset}, DateTime.from_iso8601(at))

  defp time?(_at), do: false

  @columns ["SIGNED IN", "LAST USED", "ENDS BY", "ID"]

  defp table([]),
    do: "No terminal is signed in. A terminal shows here after you run `ehosctl login` on it."

  defp table(terminals) do
    terminals
    |> Enum.map(fn terminal ->
      %{
        "SIGNED IN" => at(terminal["signed_in_at"]),
        "LAST USED" => at(terminal["last_used_at"]),
        "ENDS BY" => at(terminal["ends_at"]),
        "ID" => Refusal.shown(terminal["id"])
      }
    end)
    |> Output.table(@columns)
  end

  # As the console's settings write a moment.
  defp at(iso8601) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601)
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end

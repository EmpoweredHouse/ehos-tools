defmodule Ehosctl.Agents do
  @moduledoc """
  `ehosctl agents list | create <name>`: the person's own agents, and a new one, as the console's
  My roles page lists and creates them (eh-os
  [`docs/terminal-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/terminal-api.md),
  D-37, D-47). An agent holds nothing until a role is bound to it (`ehosctl role-bindings bind
  … --agent`), and never more than its owner holds there. Creating one is recorded by EHOS; a
  person has at most 200.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  # What would reach every list that names the agent and move the text around it, or break its
  # line: control characters, line and paragraph separators, and the marks and overrides of text
  # direction. Joiners stay, which emoji and several scripts are written with.
  @unreadable ~r/[\p{Cc}\x{2028}\x{2029}\x{200E}\x{200F}\x{061C}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @impl Ehosctl.Command
  def name, do: :agents

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about: "List and create your agents.",
      subcommands: [
        list: [name: "list", about: "List your agents, by name.", flags: Output.json_flag()],
        create: [
          name: "create",
          about: "Create an agent of yours. It holds nothing until a role is bound to it.",
          args: [
            name: [value_name: "NAME", required: true, help: "Its name, unique among yours."]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:list], _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"agents" => agents}} when is_list(agents) <-
           Api.read(installation, "/api/me/agents", opts),
         true <- Enum.all?(agents, &agent?/1) || Api.unexpected(installation) do
      agents = Enum.map(agents, &only_agent/1)
      {:ok, %{text: table(agents), json: %{agents: agents}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  def call([:create], %{args: %{name: ""}}, _opts),
    do: {:error, :invalid, "An agent's name is required."}

  def call([:create], parsed, opts) do
    name = parsed.args.name

    if Regex.match?(@unreadable, name), do: unreadable(name), else: create(name, opts)
  end

  defp unreadable(name),
    do:
      {:error, :invalid,
       "#{Refusal.shown(name)} holds characters that print as nothing or move the text around " <>
         "them: give a name a person can read."}

  defp create(name, opts) do
    Api.write(
      opts,
      {:post, "/api/me/agents", %{name: name}},
      [
        status: 201,
        key: "agent",
        valid?: &agent?/1,
        only: &only_agent/1,
        look: "`ehosctl agents list`"
      ],
      # Named by its id in the command to paste: a name may hold spaces or a shell's characters.
      fn agent ->
        "Created the agent #{Refusal.shown(agent["name"])}, #{Refusal.shown(agent["id"])}. It " <>
          "holds nothing until a role is bound to it: `ehosctl role-bindings bind <role> " <>
          "--to #{Refusal.shown(agent["id"])}`."
      end
    )
  end

  defp agent?(%{"id" => id, "name" => name} = agent),
    do:
      is_binary(id) and is_binary(name) and
        (is_nil(agent["created_at"]) or is_binary(agent["created_at"]))

  defp agent?(_agent), do: false

  defp only_agent(agent), do: Map.take(agent, ~w(id name created_at))

  defp table([]), do: "You have no agents."

  defp table(agents) do
    agents
    |> Enum.map(fn agent ->
      %{
        "NAME" => Refusal.shown(agent["name"]),
        "CREATED" => Refusal.shown(agent["created_at"] || ""),
        "ID" => Refusal.shown(agent["id"])
      }
    end)
    |> Output.table(["NAME", "CREATED", "ID"])
  end
end

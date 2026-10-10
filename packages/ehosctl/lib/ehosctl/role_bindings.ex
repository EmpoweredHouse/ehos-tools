defmodule Ehosctl.RoleBindings do
  @moduledoc """
  `ehosctl role-bindings list | bind | unbind`: which roles are bound to whom and where, binding
  one and removing one, through EHOS's API (eh-os
  [`docs/role-bindings-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/role-bindings-api.md),
  D-31), as the console's Bindings page does.

  Each needs `ehos.role_binding.manage`: anywhere to list, over the binding's scope to bind or
  unbind, and for a platform role every capability it grants there too. EHOS decides and records
  each call, and its refusal is printed in its words.

  A person is named by their email, an agent by its owner's email and `--agent` with its name, or
  either by its id; the email is looked up among whom the Bindings page offers
  (`GET /api/role-bindings/principals`). A binding is named by the id `list` prints.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @look "`ehosctl role-bindings list`"
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @impl Ehosctl.Command
  def name, do: :"role-bindings"

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    [
      about: "List, bind and remove role bindings.",
      subcommands: [
        list: [
          name: "list",
          about: "List the bindings in every scope where you manage them.",
          flags: Output.json_flag()
        ],
        bind: [
          name: "bind",
          about:
            "Bind a role to a person or an agent: at the whole platform, in an application " <>
              "with --app, or in one of its environments with --app and --env.",
          args: [
            role: [
              value_name: "ROLE",
              required: true,
              help:
                "The role: ehos.NAME for a platform role, APPLICATION.NAME for an application's."
            ]
          ],
          options: [
            to: [
              long: "--to",
              value_name: "WHO",
              required: true,
              help: "The person's email, or the agent's owner's with --agent, or an id."
            ],
            agent: [
              long: "--agent",
              value_name: "NAME",
              help: "Bind the agent of this name that --to's person owns."
            ],
            app: [
              long: "--app",
              value_name: "APPLICATION",
              help: "Bind it in this application."
            ],
            env: [
              long: "--env",
              value_name: "ENVIRONMENT",
              help: "Bind it in this environment of --app's; an application's role needs one."
            ]
          ],
          flags: Output.json_flag()
        ],
        unbind: [
          name: "unbind",
          about: "Remove a role binding.",
          args: [
            binding: [
              value_name: "BINDING",
              required: true,
              help: "The binding's id, as `list` prints it."
            ]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:list], _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"role_bindings" => bindings}} when is_list(bindings) <-
           Api.read(installation, "/api/role-bindings", opts),
         true <- Enum.all?(bindings, &listed?/1) || Api.unexpected(installation) do
      bindings = Enum.map(bindings, &only_listed/1)
      {:ok, %{text: table(bindings), json: %{role_bindings: bindings}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  def call([:bind], parsed, opts) do
    %{to: to, agent: agent, app: app, env: env} = parsed.options
    role = parsed.args.role

    with :ok <- scope_given(app, env),
         {:ok, principal} <- principal(to, agent, opts) do
      body =
        Map.reject(
          %{principal: principal.id, role: role, application: app, environment: env},
          &is_nil(elem(&1, 1))
        )

      Api.write(
        opts,
        {:post, "/api/role-bindings", body},
        [
          status: 201,
          key: "role_binding",
          valid?: &made?(&1, principal.id, role),
          only: &only_made/1,
          look: @look
        ],
        &bound(&1, principal.shown, app, env)
      )
    end
  end

  def call([:unbind], %{args: %{binding: id}}, _opts) when id in ["", ".", ".."],
    do: {:error, :invalid, "#{Refusal.shown(id)} names no binding."}

  def call([:unbind], parsed, opts) do
    id = parsed.args.binding

    Api.write(
      opts,
      {:delete, "/api/role-bindings/" <> URI.encode(id, &URI.char_unreserved?/1), nil},
      [
        status: 200,
        key: "role_binding",
        # The binding asked for, and no other, is what EHOS says it removed: a UUID, which EHOS
        # reads in either case and answers in lower case.
        valid?: &unbound?(&1, id),
        only: &Map.take(&1, ~w(id role)),
        look: @look
      ],
      fn binding ->
        "Removed the binding of #{Refusal.shown(binding["role"])}, " <>
          "#{Refusal.shown(binding["id"])}."
      end
    )
  end

  # P-6: an environment is one of an application's.
  defp scope_given(nil, env) when is_binary(env),
    do: {:error, :invalid, "--env needs --app: an environment is named within an application."}

  defp scope_given(_app, _env), do: :ok

  # An id is sent as it is; an email is looked up among whom a binding may name, which a binder
  # may read and nobody else.
  defp principal(to, agent, opts) do
    cond do
      is_nil(agent) and Regex.match?(@uuid, to) ->
        {:ok, %{id: to, shown: Refusal.shown(to)}}

      String.contains?(to, "@") ->
        lookup(to, agent, opts)

      agent ->
        {:error, :invalid, "With --agent, --to is the agent's owner's email."}

      true ->
        {:error, :invalid,
         "#{Refusal.shown(to)} is neither an email nor an id: name a person by their email, " <>
           "or an agent by its owner's email and --agent."}
    end
  end

  defp lookup(email, agent, opts) do
    installation = Keyword.fetch!(opts, :installation)
    email = String.downcase(email)

    with {:ok, %{"principals" => principals}} when is_list(principals) <-
           Api.read(installation, "/api/role-bindings/principals", opts),
         true <- Enum.all?(principals, &principal?/1) || Api.unexpected(installation) do
      principals |> Enum.find(&named?(&1, email, agent)) |> found(email, agent)
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  defp named?(%{"kind" => "person", "email" => email}, wanted, nil),
    do: String.downcase(email) == wanted

  defp named?(%{"kind" => "agent", "owner" => owner, "name" => name}, wanted, agent)
       when is_binary(agent),
       do: String.downcase(owner) == wanted and name == agent

  defp named?(_principal, _wanted, _agent), do: false

  defp found(%{"id" => id, "kind" => "person", "email" => email}, _wanted, nil),
    do: {:ok, %{id: id, shown: Refusal.shown(email)}}

  defp found(%{"id" => id, "name" => name, "owner" => owner}, _wanted, _agent),
    do: {:ok, %{id: id, shown: "#{Refusal.shown(name)}, the agent of #{Refusal.shown(owner)}"}}

  defp found(nil, email, nil),
    do:
      {:error, :failed,
       "Nobody you may bind has the email #{Refusal.shown(email)}: a disabled person is not " <>
         "offered, and an invited one is."}

  defp found(nil, email, agent),
    do:
      {:error, :failed,
       "#{Refusal.shown(email)} has no agent named #{Refusal.shown(agent)} you may bind."}

  defp bound(binding, who, app, env) do
    where =
      case {app, env} do
        {nil, nil} -> "at the whole platform"
        {app, nil} -> "in #{Refusal.shown(app)}"
        {app, env} -> "in #{Refusal.shown(app)} in #{Refusal.shown(env)}"
      end

    links =
      case binding["sign_in_links_ended"] do
        0 -> ""
        _ended -> " Their earlier sign-in link no longer works: they ask for a new one."
      end

    "Bound #{Refusal.shown(binding["role"])} to #{who} #{where}: binding " <>
      "#{Refusal.shown(binding["id"])}.#{links}"
  end

  defp listed?(%{"id" => id, "role" => role, "held_by" => held_by} = binding),
    do:
      is_binary(id) and is_binary(role) and holder?(held_by) and
        nil_or_text?(binding["application"]) and nil_or_text?(binding["environment"]) and
        is_boolean(binding["gone"]) and is_boolean(binding["beyond_owner"])

  defp listed?(_binding), do: false

  defp holder?(%{"id" => id, "kind" => kind, "name" => name}),
    do: is_binary(id) and kind in ["person", "agent"] and is_binary(name)

  defp holder?(_held_by), do: false

  defp only_listed(binding) do
    binding
    |> Map.take(~w(id role application environment gone beyond_owner))
    |> Map.put("held_by", Map.take(binding["held_by"], ~w(id kind name)))
  end

  defp principal?(%{"id" => id, "kind" => "person", "email" => email}),
    do: is_binary(id) and is_binary(email)

  defp principal?(%{"id" => id, "kind" => "agent", "name" => name, "owner" => owner}),
    do: is_binary(id) and is_binary(name) and is_binary(owner)

  defp principal?(_principal), do: false

  # The binding asked for, of that role to that principal, whose id EHOS reads in either case.
  defp made?(%{"id" => id, "role" => role, "principal" => principal} = binding, asked, role)
       when is_binary(id) and is_binary(principal),
       do:
         String.downcase(principal) == String.downcase(asked) and
           is_integer(binding["sign_in_links_ended"]) and binding["sign_in_links_ended"] >= 0

  defp made?(_binding, _asked, _role), do: false

  defp only_made(binding), do: Map.take(binding, ~w(id role principal sign_in_links_ended))

  defp unbound?(%{"id" => given, "role" => role}, id) when is_binary(given) and is_binary(role),
    do: String.downcase(given) == String.downcase(id)

  defp unbound?(_answer, _id), do: false

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp table([]), do: "No role bindings in the scopes where you manage them."

  defp table(bindings) do
    bindings
    |> Enum.map(fn binding ->
      %{
        "ROLE" => Refusal.shown(binding["role"]),
        "HELD BY" => Refusal.shown(binding["held_by"]["name"]),
        "WHERE" => where(binding),
        "NOTE" => note(binding),
        "ID" => Refusal.shown(binding["id"])
      }
    end)
    |> Output.table(["ROLE", "HELD BY", "WHERE", "NOTE", "ID"])
  end

  defp where(%{"application" => nil}), do: "the whole platform"
  defp where(%{"application" => app, "environment" => nil}), do: Refusal.shown(app)

  defp where(%{"application" => app, "environment" => env}),
    do: "#{Refusal.shown(app)} in #{Refusal.shown(env)}"

  defp note(%{"gone" => true}), do: "gone: grants nothing"
  defp note(%{"beyond_owner" => true}), do: "beyond its owner"
  defp note(_binding), do: ""
end

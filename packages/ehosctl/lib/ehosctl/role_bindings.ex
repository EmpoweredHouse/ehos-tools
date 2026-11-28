defmodule Ehosctl.RoleBindings do
  @moduledoc """
  `ehosctl role-bindings roles | list | bind | unbind`: what each platform role is for, which
  roles are bound to whom and where, binding one or several and removing one, through EHOS's API
  (eh-os
  [`docs/role-bindings-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/role-bindings-api.md),
  D-31), as the console's Role bindings page does. The words of each platform role are EHOS's,
  read from `GET /api/v1/role-bindings/roles`; `ehosctl` holds no copy of them.

  Each needs `ehos.role_binding.manage`: anywhere to list, over the binding's scope to bind or
  unbind, and for a platform role every capability it grants there too. EHOS decides and records
  each call, and its refusal is printed in its words.

  A person is named by their email, an agent by its owner's email and `--agent` with its name, or
  either by its id; the email is looked up among whom the Role bindings page offers
  (`GET /api/v1/role-bindings/principals`). A binding is named by the id `list` prints.

  Several roles are bound in one place one request each, in the order given, as the console's
  Role bindings page binds them (eh-os#703): EHOS decides and records each, and a role it refuses does
  not stop the rest. Not being signed in, or EHOS being unavailable, would fail every role the same
  way, so the rest are not asked.

  A role binding of `ehos.data_reader` or `ehos.data_writer` in a production environment ends, and
  has a reason (eh-os D-203): `--for` sends its duration and `--reason` its reason. Only EHOS knows
  whether an environment is production, so a reason is asked for at a terminal only once EHOS
  answers that it needs one, and the same answer is sent for each role of the command that needs
  one, unless EHOS refused it as not valid. The two flags are sent with those two roles alone.
  Bound again before its end, such a role binding keeps its id and gets the new end, which `bind`
  says as extended or shortened against the end `list` gave before.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Failure
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Terminal

  require Ehosctl.Api

  @look "ehosctl role-bindings list"

  # The roles whose role binding in a production environment ends and has a reason (eh-os D-203).
  @ending_roles ~w(ehos.data_reader ehos.data_writer)

  @impl Ehosctl.Command
  def name, do: :"role-bindings"

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :access

  @impl Ehosctl.Command
  def summary, do: "List, bind and remove role bindings."

  @impl Ehosctl.Command
  def spec do
    [
      about: "Show the platform roles, and list, bind and remove role bindings.",
      subcommands: [
        roles: [
          name: "roles",
          about:
            "Show each platform role: what it is for, the roles that it includes, and the " <>
              "capabilities that it grants. To see the roles bound to you and to your agents, " <>
              "run ehosctl roles.",
          flags: Output.json_flag()
        ],
        list: [
          name: "list",
          about:
            "List the role bindings in the places where you manage role bindings, or the role " <>
              "bindings of one person or agent.",
          options: [
            to: [
              long: "--to",
              value_name: "WHO",
              help:
                "Show only the role bindings of this person or agent: an email, the email of " <>
                  "the owner with --agent, or an id."
            ],
            agent: [
              long: "--agent",
              value_name: "NAME",
              help: "Show only the role bindings of the agent with this name. --to is its owner."
            ]
          ],
          flags: Output.json_flag()
        ],
        bind: [
          name: "bind",
          about:
            "Bind one or more roles to a person or an agent. Without --app, the role binding " <>
              "holds at the whole platform. Run `ehosctl role-bindings roles` to see the " <>
              "platform roles.",
          # Every role after the first comes as an argument Optimus does not name.
          allow_unknown_args: true,
          args: [
            role: [
              value_name: "ROLE...",
              required: true,
              help:
                "The role: ehos.NAME for a platform role, or APPLICATION.NAME for a role of an " <>
                  "application. Each role gets its own role binding."
            ]
          ],
          options: [
            to: [
              long: "--to",
              value_name: "WHO",
              required: true,
              help: "The email of the person, the email of the owner with --agent, or an id."
            ],
            agent: [
              long: "--agent",
              value_name: "NAME",
              help: "Bind the roles to the agent with this name. --to is its owner."
            ],
            app: [
              long: "--app",
              value_name: "APPLICATION",
              help: "Bind the roles in this application."
            ],
            env: [
              long: "--env",
              value_name: "ENVIRONMENT",
              help:
                "Bind the roles in this environment of the application. A role of an " <>
                  "application needs an environment."
            ],
            duration: [
              long: "--for",
              value_name: "DURATION",
              help:
                "How long a role binding of ehos.data_reader or ehos.data_writer in a " <>
                  "production environment lasts. If you give none, the default time of the " <>
                  "installation applies. Format: hours or days, such as 4h or 7d."
            ],
            reason: [
              long: "--reason",
              value_name: "TEXT",
              help:
                "Why you need a role binding of ehos.data_reader or ehos.data_writer in a " <>
                  "production environment. EHOS needs a reason there, and keeps it with the role " <>
                  "binding. If you give none at a terminal, ehosctl asks for it. Format: one " <>
                  "line of 10 to 500 characters."
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
              help: "The id of the role binding, as `ehosctl role-bindings list` shows it."
            ]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:roles], _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"roles" => roles}} when is_list(roles) <-
           Api.read(installation, "/api/v1/role-bindings/roles", opts),
         true <- Enum.all?(roles, &role?/1) || Api.unexpected(installation) do
      roles = Enum.map(roles, &only_role/1)
      {:ok, %{text: described(roles), json: %{roles: roles}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  def call([:list], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{to: to, agent: agent} = parsed.options

    with {:ok, holder} <- holder(to, agent, opts),
         {:ok, %{"role_bindings" => bindings}} when is_list(bindings) <-
           Api.read(installation, "/api/v1/role-bindings", opts),
         true <- Enum.all?(bindings, &listed?/1) || Api.unexpected(installation) do
      bindings =
        bindings
        |> Enum.filter(&(is_nil(holder) or held_by?(&1, holder)))
        |> Enum.map(&only_listed/1)

      {:ok, %{text: table(bindings, holder), json: %{role_bindings: bindings}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  def call([:bind], parsed, opts) do
    %{to: to, agent: agent, app: app, env: env, duration: duration, reason: reason} =
      parsed.options

    given = [parsed.args.role | parsed.unknown]

    with {:ok, roles} <- roles(given),
         :ok <- scope_given(app, env),
         {:ok, seconds} <- seconds(duration),
         terms = %{duration: seconds, reason: reason(reason), typed: nil},
         :ok <- terms_given(roles, terms),
         {:ok, principal} <- principal(to, agent, opts) do
      place = %{app: app, env: env}
      ctx = %{principal: principal, place: place, ends: ends(roles, principal, place, opts)}

      # One role named answers as one binding always did; several, even of one role, as several.
      case given do
        [role] -> role |> bind(ctx, terms, opts) |> elem(0)
        _several -> bind_each(roles, ctx, terms, parsed.flags[:json] == true, opts)
      end
    end
  end

  def call([:unbind], %{args: %{binding: id}}, _opts) when Api.is_nameless(id),
    do:
      {:error, :invalid,
       "#{Refusal.shown(id)} is not the id of a role binding. Run `#{@look}` to see the ids."}

  def call([:unbind], parsed, opts) do
    id = parsed.args.binding

    Api.write(
      opts,
      {:delete, "/api/v1/role-bindings/" <> Api.segment(id), nil},
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
        "Removed the role binding #{Refusal.shown(binding["role"])}, " <>
          "#{Refusal.shown(binding["id"])}."
      end
    )
  end

  # The roles named, each once; an option bind does not take is not taken for a role, and a role
  # that is not text is no role.
  defp roles(given) do
    cond do
      option = Enum.find(given, &String.starts_with?(&1, "-")) ->
        {:error, :invalid,
         Failure.new("#{Refusal.shown(option)} is not an option of bind.",
           advice: "See its options:",
           to_do: ["ehosctl role-bindings bind --help"]
         )}

      role = Enum.find(given, &(not String.valid?(&1))) ->
        {:error, :invalid,
         "#{Refusal.shown(String.replace_invalid(role))} is not the name of a role. " <>
           "A role is ehos.NAME or APPLICATION.NAME."}

      true ->
        {:ok, Enum.uniq(given)}
    end
  end

  # `--for` in hours or days, as seconds, which EHOS checks against the installation's times.
  defp seconds(nil), do: {:ok, nil}

  defp seconds(duration) do
    case Regex.run(~r/\A([1-9][0-9]{0,4})([hd])\z/, duration) do
      [_all, count, "h"] ->
        {:ok, String.to_integer(count) * 3_600}

      [_all, count, "d"] ->
        {:ok, String.to_integer(count) * 86_400}

      nil ->
        {:error, :invalid,
         "--for #{Refusal.shown(duration)} is not a duration in hours or days. " <>
           "Give it as 4h or 7d, for example."}
    end
  end

  # --for and --reason hold only for a role that ends; another role is sent without them, so
  # they need one such role among those named.
  defp terms_given(roles, %{duration: nil, reason: nil}) when is_list(roles), do: :ok

  defp terms_given(roles, _terms) do
    if Enum.any?(roles, &(&1 in @ending_roles)),
      do: :ok,
      else:
        {:error, :invalid,
         "--for and --reason are only for a role binding of ehos.data_reader or " <>
           "ehos.data_writer in a production environment. Leave them out."}
  end

  # One role, as one binding always was answered, with the terms that the next role of the
  # command is sent with: a reason typed at the prompt is kept for each role that needs one.
  defp bind(role, ctx, terms, opts) do
    role
    |> sent(ctx, terms, opts)
    |> with_reason(role, ctx, terms, opts)
  end

  defp sent(role, ctx, terms, opts) do
    Api.write(
      opts,
      {:post, "/api/v1/role-bindings", body(ctx, role, terms)},
      [
        status: 201,
        key: "role_binding",
        valid?: &made?(&1, ctx.principal.id, role),
        only: &only_made/1,
        look: @look,
        refused: &terms_refused/1
      ],
      &bound(&1, ctx.principal.shown, ctx.place, Map.get(ctx.ends, role))
    )
  end

  # EHOS needs a reason that was not given: the one typed for an earlier role of the command, or
  # one typed now, at a terminal; without one, its refusal says which flag gives it. A typed
  # reason that EHOS refused as not valid is not kept for the next role, which asks again.
  defp with_reason(
         {:error, _kind, _message, %{"code" => "reason_required"}} = refused,
         role,
         ctx,
         %{reason: nil} = terms,
         opts
       ) do
    case terms.typed || typed_reason(role) do
      nil ->
        {refused, terms}

      reason ->
        answer = sent(role, ctx, %{terms | reason: reason}, opts)
        {answer, kept(answer, terms, reason)}
    end
  end

  defp with_reason(answer, _role, _ctx, terms, _opts), do: {answer, terms}

  defp kept({:error, _kind, _message, %{"code" => "invalid_reason"}}, terms, _reason), do: terms
  defp kept(_answer, terms, reason), do: %{terms | typed: reason}

  # The question goes to stderr, so `--json` keeps stdout to its document, and is asked only where
  # a person can answer it.
  defp typed_reason(role) do
    if Terminal.can_ask?() do
      IO.write(
        :stderr,
        "A role binding of #{Refusal.shown(role)} in a production environment needs a reason. " <>
          "EHOS keeps it with the role binding.\nReason: "
      )

      reason(Terminal.current().gets(""))
    end
  end

  # A reason given or typed blank is none, which EHOS would refuse as none.
  defp reason(typed) when is_binary(typed) do
    case String.trim(typed) do
      "" -> nil
      reason -> reason
    end
  end

  defp reason(nil), do: nil

  # What ehosctl adds to EHOS's sentence: the flag that gives what the refusal is about.
  defp terms_refused(%{"error" => "reason_required"}),
    do: " Give it with --reason. At a terminal, ehosctl asks for it."

  defp terms_refused(%{"error" => "invalid_duration"}),
    do: " Give --for in hours or days, from 1h up to that time, such as 4h or 7d."

  defp terms_refused(%{"error" => "not_expiring"}), do: " Leave out --for and --reason."
  defp terms_refused(_body), do: nil

  # The end of each role binding of a data role named that is there already and has not ended:
  # binding it again changes its end. Only a role binding of a data role in an environment can
  # have one, and the listing is read once for the command. Whatever it answers, the roles are
  # sent, and a role binding with no end found is said as one made.
  defp ends(roles, principal, %{app: app, env: env}, opts) when is_binary(env) do
    installation = Keyword.fetch!(opts, :installation)
    ending = Enum.filter(roles, &(&1 in @ending_roles))
    now = Ehosctl.Clock.current().now()

    with [_role | _more] <- ending,
         {:ok, %{"role_bindings" => bindings}} when is_list(bindings) <-
           Api.read(installation, "/api/v1/role-bindings", opts) do
      for %{"role" => role} = binding <- bindings,
          role in ending,
          at = same_end(binding, principal.id, app, env),
          DateTime.after?(at, now),
          into: %{},
          do: {role, at}
    else
      _none -> %{}
    end
  end

  defp ends(_roles, _principal, _place, _opts), do: %{}

  defp same_end(
         %{
           "held_by" => %{"id" => id},
           "application" => app,
           "environment" => env,
           "expires_at" => ends
         },
         principal,
         app,
         env
       )
       when is_binary(id) and is_binary(ends) do
    with true <- String.downcase(id) == String.downcase(principal),
         {:ok, at, _offset} <- DateTime.from_iso8601(ends) do
      at
    else
      _other -> nil
    end
  end

  defp same_end(_binding, _principal, _app, _env), do: nil

  # Several roles, one request each: what was bound and what was refused, each said by role. A
  # refusal by EHOS does not stop the rest; not being signed in, or EHOS being unavailable, would
  # only repeat for each, so the rest are not asked, and the command exits with that kind, which a
  # script retries on; otherwise with the first refusal's. What was bound is printed on stdout, as
  # words or as JSON, and the refusals on stderr.
  defp bind_each(roles, ctx, terms, json?, opts) do
    answers = ask_each(roles, terms, &bind(&1, ctx, &2, opts))
    made = for {_role, {:ok, %{json: %{"role_binding" => binding}}}} <- answers, do: binding
    bound = for {_role, {:ok, %{text: text}}} <- answers, do: text

    refused =
      for {role, answer} <- answers,
          is_tuple(answer) and elem(answer, 0) == :error,
          do: refused(role, answer)

    not_asked = for {role, :not_asked} <- answers, do: role

    case refused do
      [] ->
        {:ok, %{text: each(bound), json: %{role_bindings: made, refused: [], not_asked: []}}}

      _refused when json? ->
        refused_json(made, refused, not_asked, refused_kind(refused, not_asked))

      _refused ->
        refused_text(bound, refused, not_asked, refused_kind(refused, not_asked))
    end
  end

  # Each binding's outcome, a part of its own.
  defp each(bound), do: bound |> Enum.intersperse("") |> Output.lines()

  # Under `--json`, each refusal names EHOS's code too, where EHOS gave one (ehos-tools#781).
  defp refused(role, {:error, kind, message}), do: %{role: role, kind: kind, refusal: message}

  defp refused(role, {:error, kind, message, refusal}),
    do: Map.merge(%{role: role, kind: kind, refusal: message}, Map.take(refusal, ["code"]))

  defp refused_kind([%{kind: first} | _] = refused, not_asked),
    do: stopping_kind(refused, not_asked) || first

  defp refused_json(made, refused, not_asked, kind) do
    IO.puts(
      Output.json(%{
        role_bindings: made,
        refused:
          Enum.map(refused, &Map.update!(&1, :refusal, fn m -> String.replace_invalid(m) end)),
        not_asked: not_asked
      })
    )

    Output.code(kind)
  end

  defp refused_text(bound, refused, not_asked, kind) do
    if bound != [], do: Output.result(%{text: each(bound), json: nil}, false)

    said =
      Enum.map(refused, fn %{role: role, refusal: message} ->
        "#{Refusal.shown(role)}: #{message}"
      end) ++
        Enum.map(not_asked, &"#{Refusal.shown(&1)}: not sent to EHOS.")

    {:error, kind, Enum.join(said, "\n")}
  end

  # The kind that stopped the run, when one did: only the last refusal can, since nothing is asked
  # after it, the last role's included, when nothing was left to ask.
  defp stopping_kind(refused, _not_asked) do
    case List.last(refused) do
      %{kind: kind} when kind in [:not_signed_in, :unreachable] -> kind
      _other -> nil
    end
  end

  defp ask_each(roles, terms, ask) do
    Enum.reduce(roles, {[], terms, false}, fn
      role, {answers, terms, true} ->
        {[{role, :not_asked} | answers], terms, true}

      role, {answers, terms, false} ->
        {answer, terms} = ask.(role, terms)

        stop? = elem(answer, 0) == :error and elem(answer, 1) in [:not_signed_in, :unreachable]

        {[{role, answer} | answers], terms, stop?}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # A role that never ends is sent without the terms, which EHOS would refuse for it.
  defp body(ctx, role, terms),
    do:
      Map.reject(
        %{
          principal: ctx.principal.id,
          role: role,
          application: ctx.place.app,
          environment: ctx.place.env,
          duration: if(role in @ending_roles, do: terms.duration),
          reason: if(role in @ending_roles, do: terms.reason)
        },
        &is_nil(elem(&1, 1))
      )

  # Whose bindings `list` shows: anyone's without --to, or the principal named as bind names one,
  # whose id each binding is matched by, in either case.
  defp holder(nil, nil, _opts), do: {:ok, nil}

  defp holder(nil, _agent, _opts),
    do: {:error, :invalid, "--agent needs --to. Give the email of the owner of the agent."}

  defp holder(to, agent, opts) do
    with {:ok, principal} <- principal(to, agent, opts), do: {:ok, String.downcase(principal.id)}
  end

  defp held_by?(%{"held_by" => %{"id" => id}}, holder), do: String.downcase(id) == holder

  # P-6: an environment is one of an application's.
  defp scope_given(nil, env) when is_binary(env),
    do: {:error, :invalid, "--env needs --app. Give the application with --app."}

  defp scope_given(_app, _env), do: :ok

  # An id is sent as it is; an email is looked up among whom a binding may name, which a binder
  # may read and nobody else.
  defp principal(to, agent, opts, not_named \\ &not_named/1) do
    cond do
      is_nil(agent) and Api.uuid?(to) ->
        {:ok, %{id: to, shown: Refusal.shown(to)}}

      String.contains?(to, "@") ->
        lookup(to, agent, opts)

      agent ->
        {:error, :invalid, "With --agent, --to must be the email of the owner of the agent."}

      true ->
        {:error, :invalid, not_named.(to)}
    end
  end

  defp not_named(to),
    do:
      "#{Refusal.shown(to)} is not an email or an id. Give the email of a person, or the " <>
        "email of the owner of an agent with --agent."

  @doc """
  The person `to` names, as `bind --to` names one without `--agent`: an id as it is, or an email
  looked up among whom a role binding may name (`GET /api/v1/role-bindings/principals`). Returns
  their id and how they are said, or the error. `ehosctl env template role-entry set` names its
  person with it (`Ehosctl.TemplateEntries`).
  """
  @spec person(String.t(), keyword()) ::
          {:ok, %{id: String.t(), shown: String.t()}} | Ehosctl.Api.error()
  def person(to, opts),
    do:
      principal(to, nil, opts, fn to ->
        "#{Refusal.shown(to)} is not an email or an id. Give the email or the id of a person."
      end)

  defp lookup(email, agent, opts) do
    installation = Keyword.fetch!(opts, :installation)
    email = String.downcase(email)

    with {:ok, %{"principals" => principals}} when is_list(principals) <-
           Api.read(installation, "/api/v1/role-bindings/principals", opts),
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
       "No person that you can bind a role to has the email #{Refusal.shown(email)}. " <>
         "You can bind a role to each person who is invited and not disabled. Check the email."}

  defp found(nil, email, agent),
    do:
      {:error, :failed,
       "#{Refusal.shown(email)} has no agent named #{Refusal.shown(agent)} that you can bind " <>
         "a role to."}

  defp bound(binding, who, %{app: app, env: env}, previous) do
    where =
      case {app, env} do
        {nil, nil} -> "at the whole platform"
        {app, nil} -> "in #{Refusal.shown(app)}"
        {app, env} -> "in #{Refusal.shown(app)} in #{Refusal.shown(env)}"
      end

    links =
      case binding["sign_in_links_ended"] do
        0 -> []
        _ended -> ["  Their earlier sign-in link no longer works. They must ask for a new one."]
      end

    Output.lines(
      [
        Output.outcome(:done, done_said(binding, who, where, previous)),
        Output.values([{"Role binding", Refusal.shown(binding["id"])} | terms_values(binding)])
      ] ++ links
    )
  end

  # A role binding that was there with an end, bound again, has a new end (eh-os D-203).
  defp done_said(binding, who, where, previous) do
    role = Refusal.shown(binding["role"])

    case changed_end(previous, binding["expires_at"]) do
      :gt -> "Extended the role binding #{role} of #{who} #{where}."
      :lt -> "Shortened the role binding #{role} of #{who} #{where}."
      _same_or_new -> "Bound #{role} to #{who} #{where}."
    end
  end

  defp changed_end(%DateTime{} = previous, ends) when is_binary(ends) do
    case DateTime.from_iso8601(ends) do
      {:ok, at, _offset} -> DateTime.compare(at, previous)
      _error -> nil
    end
  end

  defp changed_end(_previous, _ends), do: nil

  defp terms_values(%{"expires_at" => ends} = binding) when is_binary(ends),
    do: [
      {"Ends", Output.date(ends)},
      {"Reason", Refusal.shown(binding["reason"] || Output.none())}
    ]

  defp terms_values(_binding), do: []

  defp listed?(%{"id" => id, "role" => role, "held_by" => held_by} = binding),
    do:
      is_binary(id) and is_binary(role) and holder?(held_by) and
        nil_or_text?(binding["application"]) and nil_or_text?(binding["environment"]) and
        is_boolean(binding["gone"]) and is_boolean(binding["beyond_owner"]) and
        Enum.all?(
          ~w(granted_by rule through from_template expires_at reason),
          &nil_or_text?(binding[&1])
        ) and
        including?(binding["included_by"])

  defp listed?(_binding), do: false

  # EHOS's role binding that makes this one add nothing; an EHOS from before it answers no key.
  defp including?(nil), do: true

  defp including?(%{"id" => id, "role" => role} = including),
    do:
      is_binary(id) and is_binary(role) and nil_or_text?(including["application"]) and
        nil_or_text?(including["environment"])

  defp including?(_including), do: false

  defp holder?(%{"id" => id, "kind" => kind, "name" => name}),
    do: is_binary(id) and kind in ["person", "agent"] and is_binary(name)

  defp holder?(_held_by), do: false

  defp only_listed(binding) do
    binding
    |> Map.take(
      ~w(id role application environment gone beyond_owner included_by granted_by rule through
         from_template expires_at reason)
    )
    |> Map.put("held_by", Map.take(binding["held_by"], ~w(id kind name)))
    |> only_including()
  end

  defp only_including(%{"included_by" => %{} = including} = binding),
    do: %{binding | "included_by" => Map.take(including, ~w(id role application environment))}

  defp only_including(binding), do: binding

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
           is_integer(binding["sign_in_links_ended"]) and binding["sign_in_links_ended"] >= 0 and
           nil_or_text?(binding["expires_at"]) and nil_or_text?(binding["reason"])

  defp made?(_binding, _asked, _role), do: false

  defp only_made(binding),
    do: Map.take(binding, ~w(id role principal sign_in_links_ended expires_at reason))

  defp unbound?(%{"id" => given, "role" => role}, id) when is_binary(given) and is_binary(role),
    do: String.downcase(given) == String.downcase(id)

  defp unbound?(_answer, _id), do: false

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp table([]),
    do:
      "No role bindings in the places where you manage them. " <>
        "Run `ehosctl role-bindings bind ROLE --to WHO` to add one."

  defp table(bindings) do
    now = Ehosctl.Clock.current().now()
    columns = columns(bindings)

    bindings
    |> Enum.map(fn binding ->
      Map.take(
        %{
          "ROLE" => Refusal.shown(binding["role"]),
          "HELD BY" => Refusal.shown(binding["held_by"]["name"]),
          "WHERE" => where(binding),
          "ENDS" => Output.date(binding["expires_at"]),
          "REASON" => Refusal.shown(binding["reason"] || Output.none()),
          "NOTE" => note(binding, now),
          "ID" => Refusal.shown(binding["id"])
        },
        columns
      )
    end)
    |> Output.table(columns)
  end

  # The end and the reason only where a role binding has them (eh-os D-203), as most have neither.
  defp columns(bindings) do
    if Enum.any?(bindings, &(is_binary(&1["expires_at"]) or is_binary(&1["reason"]))),
      do: ["ROLE", "HELD BY", "WHERE", "ENDS", "REASON", "NOTE", "ID"],
      else: ["ROLE", "HELD BY", "WHERE", "NOTE", "ID"]
  end

  defp table([], nil), do: table([])
  defp table([], _holder), do: "They hold no role in the places where you manage role bindings."
  defp table(bindings, _holder), do: table(bindings)

  # A key left out reads as null, as `listed?/1` read it.
  defp where(binding) do
    case {binding["application"], binding["environment"]} do
      {nil, _env} -> "the whole platform"
      {app, nil} -> Refusal.shown(app)
      {app, env} -> "#{Refusal.shown(app)} in #{Refusal.shown(env)}"
    end
  end

  defp note(binding, now),
    do:
      [
        ended(binding, now),
        gone(binding),
        beyond(binding),
        included(binding),
        granted(binding),
        templated(binding)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("; ")

  # EHOS removes a role binding whose end has passed soon after; until then it grants nothing.
  defp ended(%{"expires_at" => ends}, now) when is_binary(ends) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(ends),
         true <- DateTime.after?(now, at) do
      "ended: grants nothing"
    else
      _not_ended -> ""
    end
  end

  defp ended(_binding, _now), do: ""

  # As `ehosctl roles` says them.
  defp gone(%{"gone" => true}), do: "gone: grants nothing"
  defp gone(_binding), do: ""

  defp beyond(%{"beyond_owner" => true}), do: "beyond its owner: grants only what the owner holds"
  defp beyond(_binding), do: ""

  # As the console says it: the role binding that includes this one, and where it holds when that
  # is wider.
  defp included(%{"included_by" => %{"role" => role} = including} = binding) do
    held =
      cond do
        where(including) == where(binding) -> ""
        is_nil(including["application"]) -> " at the whole platform"
        true -> " at the application"
      end

    "adds nothing: #{Refusal.shown(role)}#{held} includes this role"
  end

  defp included(_binding), do: ""

  defp role?(%{"name" => name, "description" => description} = role),
    do:
      is_binary(name) and is_binary(description) and texts?(role["includes"]) and
        is_boolean(role["platform_only"]) and is_boolean(role["production_only"]) and
        is_list(role["capabilities"]) and Enum.all?(role["capabilities"], &capability?/1)

  defp role?(_role), do: false

  defp texts?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

  defp capability?(%{"name" => name, "description" => description}),
    do: is_binary(name) and is_binary(description)

  defp capability?(_capability), do: false

  defp only_role(role) do
    role
    |> Map.take(~w(name description includes platform_only production_only))
    |> Map.put(
      "capabilities",
      Enum.map(role["capabilities"], &Map.take(&1, ~w(name description)))
    )
  end

  # Each role in EHOS's words: what it is for, what it includes, where it can be bound, and each
  # capability that it grants.
  defp described([]), do: "No platform roles."
  defp described(roles), do: Enum.map_join(roles, "\n\n", &described_role/1)

  defp described_role(role) do
    includes =
      case role["includes"] do
        [] -> []
        names -> ["Includes #{Enum.map_join(names, ", ", &Refusal.shown/1)}."]
      end

    where =
      cond do
        role["platform_only"] -> ["You can bind it only at the whole platform."]
        role["production_only"] -> ["In an environment, you can bind it only in production."]
        true -> []
      end

    capabilities =
      case role["capabilities"] do
        [] -> "It grants no capability."
        granted -> capabilities(granted)
      end

    Enum.join(
      [Refusal.shown(role["name"]), Refusal.shown(role["description"])] ++
        includes ++ where ++ [capabilities],
      "\n"
    )
  end

  defp capabilities(granted) do
    granted
    |> Enum.map(
      &%{
        "CAPABILITY" => Refusal.shown(&1["name"]),
        "GRANTS" => Refusal.shown(&1["description"])
      }
    )
    |> Output.table(["CAPABILITY", "GRANTS"])
  end

  # EHOS's D-112: a binding a person made through their application, under their role's rule. An
  # EHOS from before it answers neither key, which reads as none.
  defp granted(%{"rule" => rule} = binding) when is_binary(rule) do
    through =
      case binding["through"] do
        nil -> ""
        through -> " through #{Refusal.shown(through)}"
      end

    "granted by #{Refusal.shown(binding["granted_by"] || "someone removed")}#{through}, " <>
      "under the rule of #{Refusal.shown(rule)}"
  end

  defp granted(_binding), do: ""

  # EHOS's D-161: a binding an environment template's role entry made in an ephemeral environment,
  # set by `granted_by`. An EHOS from before it answers no key, which reads as none.
  defp templated(%{"from_template" => template} = binding) when is_binary(template) do
    set_by =
      case binding["granted_by"] do
        nil -> ""
        by -> ", set by #{Refusal.shown(by)}"
      end

    "from the environment template #{Refusal.shown(template)}#{set_by}: no right to grant roles"
  end

  defp templated(_binding), do: ""
end

defmodule Ehosctl.Env do
  @moduledoc """
  `ehosctl env list | show | create | extend | remove | bind | unbind`: an installation's
  environments and the resources bound in them, through EHOS's API (eh-os
  [`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md),
  D-54, D-57, D-82), as the console's Environments and environment pages manage them.

  An ephemeral environment belongs to one application, is made from a template and expires unless
  it is extended (eh-os D-98): `env create <name> --app A [--template T] [--ttl 24h]` makes one,
  and `env extend <name> [--ttl 72h]` gives it longer. Removing an ephemeral environment takes it
  down whole (D-100), and every removal sends the environment's name again as `confirm`: typed by
  the person when asked on a terminal, or given as `--confirm <name>` where nobody can type, as in
  a GitHub Actions job. `ehosctl` never fills it in itself. In a job, `--app` names the trust the
  job's exchange means (T-18), which `extend` and `remove` take too.

  Reading needs one of the platform capabilities; creating a production environment
  `ehos.environment.manage`, and removing one `ehos.environment.remove_production`, which only the
  administrator holds; creating, extending and removing an ephemeral one `ehos.application.deploy`
  on its application (one made before D-98, which belongs to none, is removed with
  `ehos.environment.manage`); binding and unbinding `ehos.resource.manage`. EHOS decides and
  records each call, and its refusal is printed in its words. An environment and a resource are
  named by their name, a binding by the id `env show` lists.

  `ehosctl env template …` manages the templates ephemeral environments are made from
  (`Ehosctl.EnvTemplates`), and `env show` prints the quota and limits one was given when it was
  made, its template's over the installation's.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.EnvTemplates
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @impl Ehosctl.Command
  def name, do: :env

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    env = [value_name: "ENVIRONMENT", required: true, help: "The environment, by its name."]

    [
      about:
        "List, create and remove environments, bind resources in them, and manage the " <>
          "templates ephemeral ones are made from.",
      subcommands: [
        list: [
          name: "list",
          about: "List the environments, by name.",
          flags: Output.json_flag()
        ],
        show: [
          name: "show",
          about: "Show an environment and the resources bound in it.",
          args: [environment: env],
          flags: Output.json_flag()
        ],
        create: [
          name: "create",
          about:
            "Create an environment: an ephemeral one for an application with --app, else one of " <>
              "the --type given.",
          args: [environment: env],
          options: [
            type: [
              long: "--type",
              value_name: "TYPE",
              help:
                "production or ephemeral: which resources it may bind (D-57); an ephemeral one " <>
                  "is made with --app."
            ],
            app: [
              long: "--app",
              value_name: "APPLICATION",
              help: "The application an ephemeral environment belongs to (D-98)."
            ],
            template: [
              long: "--template",
              value_name: "TEMPLATE",
              help: "The template to make it from; the installation's default without one."
            ],
            ttl: ttl_option("How long until it expires; the installation's default without one.")
          ],
          flags: Output.json_flag()
        ],
        extend: [
          name: "extend",
          about: "Give an ephemeral environment longer before it expires, from now.",
          args: [environment: env],
          options: [
            app: app_option(),
            ttl:
              ttl_option(
                "How long from now until it expires; the installation's default without one."
              )
          ],
          flags: Output.json_flag()
        ],
        remove: [
          name: "remove",
          about:
            "Remove an environment: an ephemeral one is taken down whole, its data dropped " <>
              "(D-100).",
          args: [environment: env],
          options: [
            app: app_option(),
            confirm: [
              long: "--confirm",
              value_name: "ENVIRONMENT",
              help:
                "The environment's name again, where nobody can type it when asked, as in a " <>
                  "GitHub Actions job."
            ]
          ],
          flags: Output.json_flag()
        ],
        bind: [
          name: "bind",
          about:
            "Bind a resource in an environment: its default for the resource's kind, or with " <>
              "--application that application's own.",
          args: [
            environment: env,
            resource: [value_name: "RESOURCE", required: true, help: "The resource, by its name."]
          ],
          options: [
            application: [
              long: "--application",
              value_name: "APPLICATION",
              help: "Bind it as this application's own, for its schema there."
            ]
          ],
          flags: Output.json_flag()
        ],
        unbind: [
          name: "unbind",
          about: "Remove a binding no deployment has used.",
          args: [
            environment: env,
            binding: [
              value_name: "BINDING",
              required: true,
              help: "The binding's id, as `show` lists it."
            ]
          ],
          flags: Output.json_flag()
        ],
        template: EnvTemplates.spec()
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:template, action], parsed, opts), do: EnvTemplates.call(action, parsed, opts)

  def call(command, parsed, opts) do
    # A name that would leave its place in the path (`.`, `..`), or names nothing, is refused
    # before anything is sent: a proxy that resolves dot segments would send it elsewhere.
    case Enum.find(Map.values(parsed.args), &Api.is_nameless(&1)) do
      nil ->
        run(command, parsed, opts)

      word ->
        {:error, :invalid, "#{Refusal.shown(word)} names no environment, resource or binding."}
    end
  end

  defp run([:list], _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"environments" => envs}} when is_list(envs) <-
           read(installation, "/api/v1/environments", opts),
         true <- Enum.all?(envs, &environment?/1) || Api.unexpected(installation) do
      envs = Enum.map(envs, &only_environment/1)
      {:ok, %{text: table(envs), json: %{environments: envs}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  defp run([:show], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/environments/" <> Api.segment(parsed.args.environment)

    with {:ok, %{"environment" => env}} <- read(installation, path, opts),
         true <- shown?(env) || Api.unexpected(installation) do
      env = only_shown(env)
      {:ok, %{text: shown(env), json: %{environment: env}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  defp run([:create], parsed, opts) do
    with {:ok, body} <- created(parsed.args.environment, parsed.options) do
      write(
        opts,
        :post,
        "/api/v1/environments",
        body,
        201,
        "environment",
        {&environment?/1, &only_environment/1},
        &created_said(worded(&1))
      )
    end
  end

  defp run([:extend], parsed, opts) do
    path = "/api/v1/environments/" <> Api.segment(parsed.args.environment) <> "/extend"

    with {:ok, body} <- expiry(%{}, parsed.options.ttl) do
      write(
        opts,
        :post,
        path,
        body,
        200,
        "environment",
        {&environment?/1, &only_environment/1},
        fn env -> "#{Refusal.shown(env["name"])} now expires #{expires(worded(env))}." end
      )
    end
  end

  defp run([:remove], parsed, opts) do
    name = parsed.args.environment
    path = "/api/v1/environments/" <> Api.segment(name)

    with :ok <- confirmed(name, parsed.options.confirm, opts) do
      write(
        opts,
        :delete,
        path,
        %{confirm: name},
        200,
        "environment",
        {&environment?/1, &only_environment/1},
        fn env ->
          "Removed #{Refusal.shown(env["name"])}: the operator deletes its namespace."
        end
      )
    end
  end

  defp run([:bind], parsed, opts) do
    path = "/api/v1/environments/" <> Api.segment(parsed.args.environment) <> "/bindings"

    body =
      Map.reject(
        %{resource: parsed.args.resource, application: parsed.options.application},
        &is_nil(elem(&1, 1))
      )

    write(opts, :post, path, body, 201, "binding", {&binding?/1, &only_binding/1}, fn binding ->
      binding = worded(binding)

      whose =
        if binding["application"],
          do:
            "as #{Refusal.shown(binding["application"])}'s own" <>
              if(binding["schema"], do: ", schema #{Refusal.shown(binding["schema"])}", else: ""),
          else: "as the default for #{Refusal.shown(binding["kind"])}"

      "Bound #{Refusal.shown(binding["resource"])} in #{Refusal.shown(parsed.args.environment)} " <>
        "#{whose}: binding #{Refusal.shown(binding["id"])}."
    end)
  end

  defp run([:unbind], parsed, opts) do
    %{environment: env, binding: id} = parsed.args

    path = "/api/v1/environments/" <> Api.segment(env) <> "/bindings/" <> Api.segment(id)
    # The binding asked for, and no other, is what EHOS says it removed: a UUID, which EHOS reads
    # in either case and answers in lower case.
    unbound = {&same_id?(&1, id), &Map.take(&1, ["id"])}

    write(opts, :delete, path, nil, 200, "binding", unbound, fn _ ->
      "Unbound #{Refusal.shown(id)} from #{Refusal.shown(env)}."
    end)
  end

  # Read only by a GitHub Actions job's exchange, as the trust it means (`Ehosctl.CLI`, T-18).
  defp app_option,
    do: [
      long: "--app",
      value_name: "APPLICATION",
      help:
        "In a GitHub Actions job, the application whose trust its exchange names, where its " <>
          "repository is trusted by more than one; read by nothing else."
    ]

  defp ttl_option(help),
    do: [long: "--ttl", value_name: "DURATION", help: help <> " Such as 90m, 24h or 7d."]

  # The body of a creation: an ephemeral environment with --app, whose application, template and
  # expiry EHOS checks. EHOS refuses an ephemeral one without its application, and a production
  # one names none of them, which EHOS would otherwise ignore: both are refused before sending.
  defp created(name, %{type: type, app: app, template: template, ttl: ttl}) do
    # An empty --app names no application, as `Ehosctl.CLI` reads it for the exchange.
    app = if app == "", do: nil, else: app

    cond do
      is_binary(app) and type not in [nil, "ephemeral"] ->
        {:error, :invalid,
         "--app makes an ephemeral environment; a #{Refusal.shown(type)} one belongs to no " <>
           "application."}

      is_nil(app) and type in [nil, "ephemeral"] ->
        {:error, :invalid,
         "Name the application an ephemeral environment belongs to with --app, or the type " <>
           "of another with --type."}

      is_nil(app) and not (is_nil(template) and is_nil(ttl)) ->
        {:error, :invalid, "--template and --ttl are for an ephemeral environment, with --app."}

      true ->
        %{name: name, type: type || "ephemeral", application: app, template: template}
        |> Map.reject(&is_nil(elem(&1, 1)))
        |> expiry(ttl)
    end
  end

  # `--ttl` as EHOS's `expires_in`, in seconds, from a minute (environments-api.md); without it,
  # EHOS gives its default. EHOS holds the maximum, which the installation sets.
  defp expiry(body, nil), do: {:ok, body}

  defp expiry(body, ttl) do
    case Regex.run(~r/\A([0-9]{1,7})([smhd])\z/, ttl) do
      [_ttl, count, unit] when binary_part(count, 0, 1) != "0" or count == "0" ->
        case String.to_integer(count) * seconds(unit) do
          seconds when seconds >= 60 -> {:ok, Map.put(body, :expires_in, seconds)}
          _less -> {:error, :invalid, "--ttl #{Refusal.shown(ttl)} is less than a minute."}
        end

      _not_one ->
        {:error, :invalid,
         "--ttl #{Refusal.shown(ttl)} is not a duration, such as 90m, 24h or 7d."}
    end
  end

  defp seconds("s"), do: 1
  defp seconds("m"), do: 60
  defp seconds("h"), do: 3_600
  defp seconds("d"), do: 86_400

  # An EHOS older than D-98 makes an ephemeral environment with no application and no expiry,
  # whatever --app and --ttl asked: it is said, since the environment then never goes away.
  defp created_said(%{"type" => "ephemeral", "application" => app} = env) when is_binary(app),
    do:
      "Created #{Refusal.shown(env["name"])}, #{ephemeral(env)}, unless `ehosctl env extend` " <>
        "gives it longer."

  defp created_said(%{"type" => "ephemeral"} = env),
    do:
      "Created #{Refusal.shown(env["name"])}, ephemeral, but for no application and with no " <>
        "expiry: this EHOS is older than D-98. Remove it with `ehosctl env remove` when it is " <>
        "no longer used."

  defp created_said(env),
    do:
      "Created #{Refusal.shown(env["name"])}, #{Refusal.shown(env["type"])}. Bind its " <>
        "resources with `ehosctl env bind`."

  # "ephemeral, for ledger from small, expires at …": what `create` and `show` say of one.
  defp ephemeral(env) do
    from = if env["template"], do: " from #{Refusal.shown(env["template"])}", else: ""
    "ephemeral, for #{Refusal.shown(env["application"])}#{from}, expires #{expires(env)}"
  end

  defp expires(%{"expires_at" => at}) when is_binary(at), do: "at " <> Refusal.shown(at)

  defp expires(_env), do: "when EHOS says"

  # A removal sends the environment's name again (eh-os D-100): as --confirm, else typed when
  # asked on a terminal. ehosctl never supplies it, and anything but the name exactly removes
  # nothing and exits 2: where nobody can answer, as in a job or a pipe, it is not asked at all,
  # so a job neither waits on a question nor reports a removal that did not happen.
  defp confirmed(name, given, _opts) when is_binary(given) do
    if given == name,
      do: :ok,
      else:
        {:error, :invalid,
         "--confirm #{Refusal.shown(given)} is not #{Refusal.shown(name)}: nothing was removed."}
  end

  defp confirmed(name, nil, opts) do
    ask = Keyword.get(opts, :ask, &ask/1)

    answer =
      with answer when is_binary(answer) <-
             ask.("Type #{Refusal.shown(name)} again to remove it:"),
           do: String.trim(answer)

    case answer do
      ^name ->
        :ok

      answer when is_binary(answer) and answer != "" ->
        {:error, :invalid,
         "#{Refusal.shown(answer)} is not #{Refusal.shown(name)}: nothing was removed."}

      _no_answer ->
        {:error, :invalid,
         "Removing #{Refusal.shown(name)} needs its name again: type it when asked on a " <>
           "terminal, or give --confirm #{Refusal.shown(name)}."}
    end
  end

  # The question goes to stderr, so `--json` keeps stdout to its document, and is asked only when
  # stdin and stderr are both a terminal, so it is never awaited unseen: `nil` otherwise, as at
  # the end of what a pipe gives.
  defp ask(question) do
    if terminal?() do
      IO.write(:stderr, question <> " ")

      case IO.gets(:stdio, "") do
        answer when is_binary(answer) -> answer
        _eof -> nil
      end
    end
  end

  # `:standard_io`'s options say which of the three streams are a terminal.
  defp terminal? do
    case :io.getopts(:standard_io) do
      options when is_list(options) ->
        Keyword.get(options, :stdin) == true and Keyword.get(options, :stderr) == true

      _error ->
        false
    end
  end

  @look "`ehosctl env show`"

  # `{valid?, only}`: whether the answer is what was asked for, and the fields of it printed.
  defp write(opts, method, path, body, status, key, {valid?, only}, said),
    do:
      Api.write(
        opts,
        {method, path, body},
        [status: status, key: key, valid?: valid?, only: only, look: @look],
        said
      )

  defp read(installation, path, opts), do: Api.read(installation, path, opts)

  defp same_id?(%{"id" => given}, id) when is_binary(given),
    do: String.downcase(given) == String.downcase(id)

  defp same_id?(_answer, _id), do: false

  # `application`, `template` and `expires_at` are an ephemeral environment's (eh-os D-98), null
  # for a production one, and absent from an EHOS older than D-98.
  defp environment?(%{"name" => name, "type" => type} = env),
    do:
      is_binary(name) and is_binary(type) and
        Enum.all?(~w(application template expires_at), &nil_or_text?(env[&1]))

  defp environment?(_env), do: false

  defp only_environment(env), do: Map.take(env, ~w(name type application template expires_at))

  # An environment or a binding as its words say it: an empty application, template, expiry or
  # schema is one EHOS has not given, as null is. `--json` keeps what EHOS answered.
  defp worded(env) do
    Map.new(env, fn
      {key, ""} when key in ~w(application template expires_at schema) -> {key, nil}
      pair -> pair
    end)
  end

  # `quota` and `limits` are what an ephemeral environment was given when made, its template's over
  # the installation's (eh-os D-98): null for one made before, which has the installation's, and
  # absent from an EHOS that does not say them.
  defp shown?(%{"bindings" => bindings} = env) when is_list(bindings),
    do:
      environment?(env) and Enum.all?(bindings, &binding?/1) and
        EnvTemplates.quota?(env["quota"]) and EnvTemplates.limits?(env["limits"])

  defp shown?(_env), do: false

  defp only_shown(env) do
    env
    |> only_environment()
    |> Map.merge(Map.take(env, ~w(quota limits)))
    |> Map.put("bindings", Enum.map(env["bindings"], &only_binding/1))
  end

  defp binding?(%{"id" => id, "kind" => kind, "resource" => resource} = binding),
    do:
      is_binary(id) and is_binary(kind) and is_binary(resource) and
        nil_or_text?(binding["application"]) and nil_or_text?(binding["schema"]) and
        is_boolean(Map.get(binding, "used", false))

  defp binding?(_binding), do: false

  defp only_binding(binding), do: Map.take(binding, ~w(id kind resource application schema used))

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp table([]), do: "No environments."

  defp table(envs) do
    envs
    |> Enum.map(&worded/1)
    |> Enum.map(
      &%{
        "NAME" => Refusal.shown(&1["name"]),
        "TYPE" => Refusal.shown(&1["type"]),
        "APPLICATION" => Refusal.named(&1["application"]),
        "TEMPLATE" => Refusal.named(&1["template"]),
        "EXPIRES" => expires_cell(&1)
      }
    )
    |> Output.table(["NAME", "TYPE", "APPLICATION", "TEMPLATE", "EXPIRES"])
  end

  # An ephemeral environment for an application expires when EHOS says, even before it says
  # when; one for none (made by an EHOS older than D-98) and any other never do.
  defp expires_cell(%{"expires_at" => at}) when is_binary(at), do: Refusal.shown(at)

  defp expires_cell(%{"type" => "ephemeral", "application" => app}) when is_binary(app),
    do: "when EHOS says"

  defp expires_cell(_env), do: "never"

  defp shown(env) do
    env = worded(env)

    head =
      if env["type"] == "ephemeral" and is_binary(env["application"]),
        do: "#{Refusal.shown(env["name"])}, #{ephemeral(env)}",
        else: "#{Refusal.shown(env["name"])}, #{Refusal.shown(env["type"])}"

    head = head <> resources_given(env)

    case env["bindings"] do
      [] ->
        head <> "\nNo resources are bound in it."

      bindings ->
        rows =
          bindings
          |> Enum.map(fn binding ->
            binding = worded(binding)

            %{
              "KIND" => Refusal.shown(binding["kind"]),
              "RESOURCE" => Refusal.shown(binding["resource"]),
              "FOR" =>
                if(binding["application"],
                  do: Refusal.shown(binding["application"]),
                  else: "default"
                ),
              "SCHEMA" => Refusal.named(binding["schema"]),
              "USED" => if(binding["used"] == true, do: "yes", else: "no"),
              "ID" => Refusal.shown(binding["id"])
            }
          end)
          |> Output.table(["KIND", "RESOURCE", "FOR", "SCHEMA", "USED", "ID"])

        head <> "\n\n" <> rows
    end
  end

  # An ephemeral environment's quota and limits, as it was given them; nothing for another,
  # whose come from the installation, or from an EHOS that does not say them.
  defp resources_given(%{"type" => "ephemeral"} = env)
       when is_map_key(env, "quota") or is_map_key(env, "limits"),
       do:
         "\nQuota: #{EnvTemplates.quota_said(env["quota"])}" <>
           "\nLimits: #{String.replace(EnvTemplates.limits_said(env["limits"]), "\n", "\n        ")}"

  defp resources_given(_env), do: ""
end

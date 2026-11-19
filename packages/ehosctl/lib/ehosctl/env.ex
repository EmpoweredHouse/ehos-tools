defmodule Ehosctl.Env do
  @moduledoc """
  `ehosctl env list | show | create | extend | remove | bind | unbind | start-without-data`: an
  installation's environments and the resources bound in them, through EHOS's API (eh-os
  [`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md),
  D-54, D-57, D-82), as the console's Environments and environment pages manage them.

  An ephemeral environment belongs to one application, is made from a template and expires unless
  it is extended (eh-os D-98): `env create <name> --app A [--template T] [--ttl 24h]` makes one,
  and `env extend <name> [--ttl 72h]` gives it longer. Removing an ephemeral environment takes it
  down whole (D-100), and every removal sends the environment's name again as `confirm`: typed by
  the person when asked on a terminal, or given as `--confirm <name>` where nobody can type, as in
  a GitHub Actions job. `ehosctl` never fills it in itself. In a job, `--app` names the trust the
  job's exchange means (T-18), which `extend` and `remove` take too. Before it creates an
  environment named `<application>-pr-<n>`, `create` says on stderr, unless under `--json`, that
  the pipeline of a pull request may deploy over it and remove it. At the count, EHOS's refusal
  names the environments that hold it (`Ehosctl.AtCount`).

  Reading needs one of the platform capabilities; creating a production environment
  `ehos.environment.manage`, and removing one `ehos.environment.remove_production`, which only the
  administrator holds; creating, extending and removing an ephemeral one `ehos.application.deploy`
  on its application (one made before D-98, which belongs to none, is removed with
  `ehos.environment.manage`); binding, unbinding and starting an application again without its
  data `ehos.resource.manage`. `start-without-data` makes EHOS forget that the data of an
  application's resource binding was ready, after the administrator of a database outside the
  installation dropped it (D-170), so its next deployment makes the schema again, empty; it asks
  first, unless `--yes`, since it cannot be undone. EHOS decides and
  records each call, and its refusal is printed in its words. An environment and a resource are
  named by their name, a binding by the id `env show` lists.

  `ehosctl env template …` manages the templates ephemeral environments are made from
  (`Ehosctl.EnvTemplates`), and `ehosctl env quota …` the quota and limits of one that is not
  ephemeral (`Ehosctl.EnvQuota`, D-143). `env show` prints an environment's quota and limits: an
  ephemeral one's as it was given them when it was made, its template's over the installation's,
  and another's own, or the installation's.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.EnvQuota
  alias Ehosctl.EnvTemplates
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.TemplateEntries

  require Ehosctl.Api

  @impl Ehosctl.Command
  def name, do: :env

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :applications

  @impl Ehosctl.Command
  def summary, do: "List, create and remove environments."

  @impl Ehosctl.Command
  def spec do
    env = [value_name: "ENVIRONMENT", required: true, help: "The name of the environment."]

    [
      about:
        "List, create and remove environments. Bind resources in them, set their quota, and " <>
          "manage environment templates.",
      subcommands: [
        list: [
          name: "list",
          about: "List the environments of the installation.",
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
            "Create an environment. With --app, it is an ephemeral environment of that " <>
              "application. Without --app, give --type.",
          args: [environment: env],
          options: [
            type: [
              long: "--type",
              value_name: "TYPE",
              help:
                "The type of the environment: production or ephemeral. The type decides which " <>
                  "resources it can bind. An ephemeral environment needs --app."
            ],
            app: [
              long: "--app",
              value_name: "APPLICATION",
              help: "The application that the ephemeral environment belongs to."
            ],
            template: [
              long: "--template",
              value_name: "TEMPLATE",
              help:
                "The environment template to make it from. If you do not give one, EHOS uses " <>
                  "the default of the installation."
            ],
            ttl:
              ttl_option(
                "How long until the environment expires. If you do not give it, EHOS uses the " <>
                  "default of the installation."
              )
          ],
          flags: [no_role_bindings: no_role_bindings_flag()] ++ Output.json_flag()
        ],
        extend: [
          name: "extend",
          about:
            "Give an ephemeral environment more time before it expires. The time counts from now.",
          args: [environment: env],
          options: [
            app: app_option(),
            ttl:
              ttl_option(
                "How long from now until the environment expires. If you do not give it, EHOS " <>
                  "uses the default of the installation."
              )
          ],
          flags: Output.json_flag()
        ],
        remove: [
          name: "remove",
          about:
            "Remove an environment. If it is an ephemeral environment, EHOS takes it down " <>
              "whole and drops its data.",
          args: [environment: env],
          options: [
            app: app_option(),
            confirm: [
              long: "--confirm",
              value_name: "ENVIRONMENT",
              help:
                "The name of the environment again. Use it where nobody can type the name, as " <>
                  "in a GitHub Actions job."
            ]
          ],
          flags: Output.json_flag()
        ],
        bind: [
          name: "bind",
          about:
            "Bind a resource in an environment. Without --application, the resource binding " <>
              "is the default for the kind of the resource.",
          args: [
            environment: env,
            resource: [
              value_name: "RESOURCE",
              required: true,
              help: "The name of the resource."
            ]
          ],
          options: [
            application: [
              long: "--application",
              value_name: "APPLICATION",
              help:
                "Bind the resource for this application only. EHOS gives the application its " <>
                  "own schema in it."
            ]
          ],
          flags: Output.json_flag()
        ],
        unbind: [
          name: "unbind",
          about: "Remove a resource binding that no deployment has used.",
          args: [
            environment: env,
            binding: [
              value_name: "BINDING",
              required: true,
              help: "The id of the resource binding, as `ehosctl env show` shows it."
            ]
          ],
          flags: Output.json_flag()
        ],
        "start-without-data": [
          name: "start-without-data",
          about:
            "Start an application again without its data, after the administrator of a " <>
              "database outside the installation dropped the data on purpose. The next " <>
              "deployment makes its schema again, empty. You cannot undo this.",
          args: [
            environment: env,
            application: [
              value_name: "APPLICATION",
              required: true,
              help: "The name of the application."
            ]
          ],
          flags:
            [yes: [long: "--yes", help: "Start again without a question."]] ++
              Output.json_flag()
        ],
        template: EnvTemplates.spec(),
        quota: EnvQuota.spec()
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:template, group, action], parsed, opts),
    do: TemplateEntries.call(group, action, parsed, opts)

  def call([:template, action], parsed, opts), do: EnvTemplates.call(action, parsed, opts)

  def call(command, parsed, opts) do
    # A name that would leave its place in the path (`.`, `..`), or names nothing, is refused
    # before anything is sent: a proxy that resolves dot segments would send it elsewhere.
    case Enum.find(Map.values(parsed.args), &Api.is_nameless(&1)) do
      nil ->
        case command do
          [:quota, action] -> EnvQuota.call(action, parsed, opts)
          command -> run(command, parsed, opts)
        end

      word ->
        {:error, :invalid,
         "#{Refusal.shown(word)} is not the name of an environment, a resource or a resource binding."}
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
    entries? = not parsed.flags.no_role_bindings

    with {:ok, body} <- created(parsed.args.environment, parsed.options, entries?) do
      if body[:application] && not parsed.flags.json,
        do: warn_pull_request(body.application, body.name)

      create(body, opts)
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
        fn env ->
          "The environment #{Refusal.shown(env["name"])} now expires #{expires(worded(env))}."
        end
      )
    end
  end

  defp run([:remove], parsed, opts) do
    name = parsed.args.environment
    path = "/api/v1/environments/" <> Api.segment(name)

    with :ok <- confirmed(name, parsed.options.confirm) do
      write(
        opts,
        :delete,
        path,
        %{confirm: name},
        200,
        "environment",
        {&environment?/1, &only_environment/1},
        fn env ->
          "Removed the environment #{Refusal.shown(env["name"])}. The operator deletes its " <>
            "namespace."
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

      "Bound #{Refusal.shown(binding["resource"])} in #{Refusal.shown(parsed.args.environment)} " <>
        "#{whose(binding)}: resource binding #{Refusal.shown(binding["id"])}." <>
        Ehosctl.Resources.outside_note(binding)
    end)
  end

  defp run([:unbind], parsed, opts) do
    %{environment: env, binding: id} = parsed.args

    path = "/api/v1/environments/" <> Api.segment(env) <> "/bindings/" <> Api.segment(id)
    # The binding asked for, and no other, is what EHOS says it removed: a UUID, which EHOS reads
    # in either case and answers in lower case.
    unbound = {&same_id?(&1, id), &Map.take(&1, ["id"])}

    write(opts, :delete, path, nil, 200, "binding", unbound, fn _ ->
      "Removed the resource binding #{Refusal.shown(id)} from #{Refusal.shown(env)}."
    end)
  end

  # eh-os D-170: EHOS forgets that the binding's data was ready, so the next deployment makes the
  # schema again, empty, where it would otherwise wait at `DataGone`.
  defp run([:"start-without-data"], parsed, opts) do
    %{environment: env, application: app} = parsed.args
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/environments/" <> Api.segment(env)

    with {:ok, %{"environment" => shown}} <- read(installation, path, opts),
         true <- shown?(shown) || Api.unexpected(installation),
         {:ok, binding} <- with_data(shown["bindings"], env, app),
         :ok <- start_confirmed(binding, env, app, parsed.flags.yes) do
      id = binding["id"]
      forgotten = {&forgotten?(&1, id), &only_binding/1}

      write(
        opts,
        :delete,
        path <> "/bindings/" <> Api.segment(id) <> "/data-ready",
        nil,
        200,
        "binding",
        forgotten,
        fn _ -> started(env, app) end
      )
    else
      {:ok, _body} -> Api.unexpected(installation)
      {:unchanged, output} -> {:ok, output}
      error -> error
    end
  end

  defp whose(binding) do
    if binding["application"],
      do:
        "for the application #{Refusal.shown(binding["application"])}" <>
          if(binding["schema"], do: ", schema #{Refusal.shown(binding["schema"])}", else: ""),
      else: "as the default for #{Refusal.shown(binding["kind"])}"
  end

  # Read only by a GitHub Actions job's exchange, as the trust it means (`Ehosctl.CLI`, T-18).
  defp app_option,
    do: [
      long: "--app",
      value_name: "APPLICATION",
      help:
        "In a GitHub Actions job, the application whose trust the job uses, if more than one " <>
          "application trusts its repository. ehosctl uses it nowhere else."
    ]

  @doc """
  The `--no-role-bindings` flag of a command that creates an ephemeral environment, its help
  starting with `lead`: `env create`'s, and `deploy`'s, which says it works only with
  `--create-env`.
  """
  @spec no_role_bindings_flag(String.t()) :: keyword()
  def no_role_bindings_flag(lead \\ "Create") do
    [
      long: "--no-role-bindings",
      help:
        lead <>
          " the ephemeral environment without the role entries and the people " <>
          "agreement that its environment template holds for the application. This flag " <>
          "leaves out both: the environment gets no role binding and no people agreement " <>
          "from the environment template."
    ]
  end

  defp ttl_option(help),
    do: [long: "--ttl", value_name: "DURATION", help: help <> " Examples: 90m, 24h, 7d."]

  @doc """
  Creates an ephemeral environment `name` of `application` from `template`, or from the
  installation's default environment template when it is `nil`, with that environment template's
  defaults: `POST /api/v1/environments`, as `ehosctl env create --app` sends it. With `entries?`
  false, as `--no-role-bindings` asks, EHOS makes it without the role entries and the people
  agreement the environment template holds for the application (eh-os D-161); otherwise nothing
  is sent of them, and EHOS gives them. Returns what `env create` prints, or EHOS's refusal, with
  the environments that hold the count at one. `ehosctl deploy --create-env` creates the
  environment it deploys to with it.
  """
  @spec create_ephemeral(String.t(), String.t(), String.t() | nil, boolean(), keyword()) ::
          {:ok, Output.t()} | Api.error()
  def create_ephemeral(name, application, template, entries?, opts) do
    %{name: name, type: "ephemeral", application: application, template: template}
    |> Map.reject(&is_nil(elem(&1, 1)))
    |> without_entries(entries?)
    |> create(opts)
  end

  # EHOS gives an ephemeral environment its template's entries unless asked not to, so `false`
  # alone is sent, for `--no-role-bindings`. An EHOS older than D-161 ignores the key and answers
  # without `template_entries`, which `unconfirmed/2` says.
  defp without_entries(body, true), do: body
  defp without_entries(body, false), do: Map.put(body, :template_entries, false)

  defp create(body, opts),
    do:
      write(
        opts,
        :post,
        "/api/v1/environments",
        body,
        201,
        "environment",
        {&made?(&1, body), &only_environment/1},
        &Enum.join([created_said(worded(&1)) | List.wrap(unconfirmed(&1, body))], "\n")
      )

  # An environment asked for without its template's entries that EHOS says it made with them is
  # not what was asked.
  defp made?(env, %{template_entries: false}),
    do: environment?(env) and env["template_entries"] != true

  defp made?(env, _body), do: environment?(env)

  # The line after "Created …" for an environment asked for without its template's role entries
  # and people agreement that EHOS does not say it made so: an EHOS older than D-161 answers no
  # `template_entries`. `--json` says it by the key it lacks.
  defp unconfirmed(%{"name" => name} = env, %{template_entries: false})
       when not is_map_key(env, "template_entries"),
       do:
         "EHOS did not confirm that it made #{Refusal.shown(name)} without the role entries and " <>
           "the people agreement of the environment template. This version of EHOS may not know " <>
           "--no-role-bindings. Run `ehosctl role-bindings list` to see the role bindings in it."

  defp unconfirmed(_env, _body), do: nil

  @doc """
  The warning for an ephemeral environment `name` of `application` that may be a pull request's,
  `<application>-pr-<n>`: the template's pipeline, when its repository previews pull requests,
  deploys to it on each push, and can remove it when the pull request closes (eh-os D-110,
  D-156). `nil` for any other name.

      iex> Ehosctl.Env.pull_request_warning("ledger", "ledger-try")
      nil
  """
  @spec pull_request_warning(String.t(), String.t()) :: String.t() | nil
  def pull_request_warning(application, name) do
    if Regex.match?(~r/\A#{Regex.escape(application)}-pr-[0-9]+\z/, name),
      do:
        "If the repository previews pull requests, the pipeline of a pull request deploys to " <>
          "#{Refusal.shown(name)}. Its deployment replaces yours there and withdraws a " <>
          "promotion that waits for a candidate there. When the pull request closes, its " <>
          "pipeline can remove #{Refusal.shown(name)}."
  end

  @doc """
  Prints `pull_request_warning/2` on stderr, before the command acts on the environment, when it
  has one.
  """
  @spec warn_pull_request(String.t(), String.t()) :: :ok
  def warn_pull_request(application, name) do
    case pull_request_warning(application, name) do
      nil -> :ok
      warning -> IO.puts(:stderr, warning)
    end
  end

  # The body of a creation: an ephemeral environment with --app, whose application, template and
  # expiry EHOS checks. EHOS refuses an ephemeral one without its application, and a production
  # one names none of them, which EHOS would otherwise ignore: both are refused before sending.
  defp created(name, %{type: type, app: app, template: template, ttl: ttl}, entries?) do
    # An empty --app names no application, as `Ehosctl.CLI` reads it for the exchange.
    app = if app == "", do: nil, else: app

    # What only an ephemeral environment takes: its template, its expiry, and leaving out the
    # template's role entries and people agreement.
    ephemeral_only? = not (is_nil(template) and is_nil(ttl) and entries?)

    with :ok <- ephemeral_options(app, type, ephemeral_only?) do
      %{name: name, type: type || "ephemeral", application: app, template: template}
      |> Map.reject(&is_nil(elem(&1, 1)))
      |> without_entries(entries?)
      |> expiry(ttl)
    end
  end

  defp ephemeral_options(app, type, ephemeral_only?) do
    cond do
      is_binary(app) and type not in [nil, "ephemeral"] ->
        {:error, :invalid,
         "--app creates an ephemeral environment, and a #{Refusal.shown(type)} environment " <>
           "belongs to no application. Give --app or --type, not both."}

      is_nil(app) and type in [nil, "ephemeral"] ->
        {:error, :invalid,
         "An ephemeral environment needs --app with the name of its application. For another " <>
           "type of environment, give --type."}

      is_nil(app) and ephemeral_only? ->
        {:error, :invalid,
         "--template, --ttl and --no-role-bindings apply only to an ephemeral environment. " <>
           "Give --app, or leave them out."}

      true ->
        :ok
    end
  end

  # `--ttl` as EHOS's `expires_in`, in seconds, from a minute (environments-api.md); without it,
  # EHOS gives its default. EHOS holds the maximum, which the installation sets.
  defp expiry(body, nil), do: {:ok, body}

  defp expiry(body, ttl) do
    case Regex.run(~r/\A([0-9]{1,7})([smhd])\z/, ttl) do
      [_ttl, count, unit] when binary_part(count, 0, 1) != "0" or count == "0" ->
        case String.to_integer(count) * seconds(unit) do
          seconds when seconds >= 60 ->
            {:ok, Map.put(body, :expires_in, seconds)}

          _less ->
            {:error, :invalid,
             "--ttl #{Refusal.shown(ttl)} is less than 1 minute. Give 1m or more."}
        end

      _not_one ->
        {:error, :invalid,
         "--ttl #{Refusal.shown(ttl)} is not a duration. Give a number and a unit, such as " <>
           "90m, 24h or 7d."}
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
      "Created #{Refusal.shown(env["name"])}, #{ephemeral(env)}.#{entries_said(env)} Run " <>
        "`ehosctl env extend` to give it more time."

  defp created_said(%{"type" => "ephemeral"} = env),
    do:
      "Created #{Refusal.shown(env["name"])}, ephemeral. This version of EHOS gives it no " <>
        "application and no expiry, so it does not expire. Run `ehosctl env remove` when " <>
        "nobody uses it."

  defp created_said(env),
    do:
      "Created #{Refusal.shown(env["name"])}, #{Refusal.shown(env["type"])}. Run " <>
        "`ehosctl env bind` to bind its resources."

  # As `env show` says what `--no-role-bindings` left out, on a line of its own.
  defp entries_shown(%{"template_entries" => false}), do: "\n" <> left_out()
  defp entries_shown(_env), do: ""

  # What `--no-role-bindings` left out, as EHOS says it made the environment.
  defp entries_said(%{"template_entries" => false}), do: " " <> left_out()
  defp entries_said(_env), do: ""

  defp left_out,
    do: "It has no role bindings and no people agreement from the environment template."

  # "ephemeral, for ledger from small, expires at …": what `create` and `show` say of one.
  defp ephemeral(env) do
    from =
      if env["template"],
        do: " from the environment template #{Refusal.shown(env["template"])}",
        else: ""

    "ephemeral, for #{Refusal.shown(env["application"])}#{from}, expires #{expires(env)}"
  end

  defp expires(%{"expires_at" => at}) when is_binary(at), do: "at " <> Refusal.shown(at)

  defp expires(_env), do: "when EHOS says"

  # A removal sends the environment's name again (eh-os D-100): as --confirm, else typed when
  # asked on a terminal. ehosctl never supplies it, and anything but the name exactly removes
  # nothing and exits 2: where nobody can answer, as in a job or a pipe, it is not asked at all,
  # so a job neither waits on a question nor reports a removal that did not happen.
  defp confirmed(name, given) when is_binary(given) do
    if given == name,
      do: :ok,
      else:
        {:error, :invalid,
         "--confirm #{Refusal.shown(given)} is not #{Refusal.shown(name)}, so ehosctl " <>
           "removed nothing. Give --confirm #{Refusal.shown(name)}."}
  end

  defp confirmed(name, nil) do
    answer =
      with answer when is_binary(answer) <-
             ask("Type #{Refusal.shown(name)} to remove the environment:"),
           do: String.trim(answer)

    case answer do
      ^name ->
        :ok

      answer when is_binary(answer) and answer != "" ->
        {:error, :invalid,
         "#{Refusal.shown(answer)} is not #{Refusal.shown(name)}, so ehosctl removed " <>
           "nothing. Run the command again and type #{Refusal.shown(name)}."}

      _no_answer ->
        {:error, :invalid,
         "Nothing was removed: ehosctl removes #{Refusal.shown(name)} only when you give the " <>
           "name again. Type the name when ehosctl asks on a terminal, or give --confirm " <>
           "#{Refusal.shown(name)}."}
    end
  end

  # The question goes to stderr, so `--json` keeps stdout to its document, and is asked only when
  # stdin and stderr are both a terminal, so it is never awaited unseen: `nil` otherwise, as at
  # the end of what a pipe gives.
  defp ask(question) do
    terminal = Ehosctl.Terminal.current()

    if terminal.input_terminal?() and terminal.error_terminal?() do
      IO.write(:stderr, question <> " ")
      terminal.gets("")
    end
  end

  # The application's resource binding whose data EHOS holds as ready: `{:unchanged, output}` when
  # it holds none, which leaves nothing to do. An EHOS that does not say `data_ready_at` is asked
  # anyway, and its answer decides.
  defp with_data(bindings, env, app) do
    own = Enum.filter(bindings, &(&1["application"] == app))

    cond do
      own == [] ->
        {:error, :failed,
         "#{Refusal.shown(app)} has no resource binding in #{Refusal.shown(env)}, so ehosctl " <>
           "changed nothing. Run `ehosctl env show #{Refusal.shown(env)}` to see the resource " <>
           "bindings."}

      binding = Enum.find(own, &data_ready?/1) ->
        {:ok, binding}

      true ->
        {:unchanged, no_data(env, app)}
    end
  end

  defp data_ready?(binding),
    do: binding["data_ready_at"] != nil or not is_map_key(binding, "data_ready_at")

  defp no_data(env, app) do
    said =
      "EHOS holds no data of #{Refusal.shown(app)} in #{Refusal.shown(env)}: its next " <>
        "deployment makes its schema, empty. ehosctl changed nothing."

    %{text: Output.outcome(:unchanged, said), json: %{binding: nil}}
  end

  defp forgotten?(binding, id),
    do: same_id?(binding, id) and binding?(binding) and is_nil(binding["data_ready_at"])

  defp started(env, app),
    do:
      "The next deployment of #{Refusal.shown(app)} in #{Refusal.shown(env)} makes its schema " <>
        "again, empty.\nNext: deploy a new version of #{Refusal.shown(app)} to " <>
        "#{Refusal.shown(env)}, so its migrations run in the new schema."

  # Forgetting the data cannot be undone, so it asks first, unless --yes; where nobody can answer,
  # as in a job or a pipe, it changes nothing.
  defp start_confirmed(_binding, _env, _app, true), do: :ok

  defp start_confirmed(binding, env, app, false) do
    question =
      "Start #{Refusal.shown(app)} in #{Refusal.shown(env)} again without data? The next " <>
        "deployment makes the schema #{Refusal.named(binding["schema"])} again, empty. Do this " <>
        "only after the administrator of the database dropped the data on purpose. You cannot " <>
        "undo it."

    case Ehosctl.Terminal.confirm_at_terminal(question) do
      true ->
        :ok

      false ->
        {:error, :invalid, "You did not confirm, so nothing was changed."}

      nil ->
        {:error, :invalid,
         "Nothing was changed: ehosctl asks before it starts #{Refusal.shown(app)} in " <>
           "#{Refusal.shown(env)} again without data, and nobody can answer here. Answer on a " <>
           "terminal, or give --yes."}
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
  # for a production one, and absent from an EHOS older than D-98; so is `template_entries`,
  # whether it got its template's role entries and people agreement (D-161).
  defp environment?(%{"name" => name, "type" => type} = env),
    do:
      is_binary(name) and is_binary(type) and
        Enum.all?(~w(application template expires_at), &nil_or_text?(env[&1])) and
        (is_nil(env["template_entries"]) or is_boolean(env["template_entries"]))

  defp environment?(_env), do: false

  defp only_environment(env),
    do: Map.take(env, ~w(name type application template expires_at template_entries))

  # An environment or a binding as its words say it: an empty application, template, expiry or
  # schema is one EHOS has not given, as null is. `--json` keeps what EHOS answered.
  defp worded(env) do
    Map.new(env, fn
      {key, ""} when key in ~w(application template expires_at schema) -> {key, nil}
      pair -> pair
    end)
  end

  # `quota` and `limits` are what an ephemeral environment was given when made, its template's over
  # the installation's (eh-os D-98), and another's own (D-143): null for the installation's, and
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
        is_boolean(Map.get(binding, "used", false)) and
        nil_or_text?(binding["provider"]) and nil_or_text?(binding["data_ready_at"])

  defp binding?(_binding), do: false

  defp only_binding(binding),
    do: Map.take(binding, ~w(id kind resource provider application schema used data_ready_at))

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp table([]),
    do:
      "No environments. An environment shows here when a person creates it with " <>
        "`ehosctl env create`."

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

    head = head <> resources_given(env) <> entries_shown(env)

    case env["bindings"] do
      [] ->
        head <>
          "\nNo resource bindings. Run `ehosctl env bind #{Refusal.shown(env["name"])} " <>
          "RESOURCE` to give it a resource."

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

  # An ephemeral environment's quota and limits, as it was given them, and another's own (D-143),
  # null for the installation's; nothing from an EHOS that does not say them.
  defp resources_given(env)
       when is_map_key(env, "quota") or is_map_key(env, "limits"),
       do: EnvQuota.said(env)

  defp resources_given(_env), do: ""
end

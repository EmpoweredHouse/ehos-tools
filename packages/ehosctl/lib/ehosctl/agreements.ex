defmodule Ehosctl.Agreements do
  @moduledoc """
  The four things EHOS gives an application only once someone agrees, listed, agreed to and
  withdrawn through EHOS's API (eh-os
  [`docs/agreements-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/agreements-api.md),
  eh-os#374), as the console does:

    * `ehosctl apps sign-in list | agree | withdraw`: that another application's pages may get
      credentials for an application in an environment, as the application's environment tab
      agrees (eh-os D-70). Agreeing and withdrawing need `ehos.application.deploy` for the
      application there; listing needs that or `ehos.application.register`.
    * `ehosctl people agreements | agree | withdraw`: that an application's workload may read the
      company's people in an environment, as the people page agrees (eh-os D-81). Each needs
      `ehos.people.manage`.
    * `ehosctl mail agreements | agree | withdraw`: how far an application's workload may send
      mail through EHOS in an environment, to the company's people only or to any address, and
      with replies to which of its domains, as the Installation page agrees (eh-os D-140). Each
      needs `ehos.mail.manage`.
    * `ehosctl services list | agree | withdraw`: that an application may call a utility service
      in an environment, as the environment tab of the utility service agrees (eh-os D-175).
      Agreeing and withdrawing need `ehos.application.deploy` for the utility service there;
      listing needs that, `ehos.application.register` or `ehos.release.approve` for the
      application named. `services agree-hosts | withdraw-hosts` give and withdraw the
      application's side, to the hosts outside the installation that the service names there,
      and need `ehos.release.approve` for the application there.

  EHOS decides and records each call, and its refusal is printed in its words. An application and
  an environment are named by their names, each a segment of the path. An answer is taken only
  for the application, the environment and the pages asked for, and only the fields the API says
  it holds are printed, under `--json` too.
  """

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @sign_in_fields ~w(client asks agreed agreed_at by)
  @people_fields ~w(application environment asks agreed agreed_at by from_template)
  @mail_fields ~w(application environment asks agreed agreed_at by)
  @mail_answer ~w(application environment agreed level reply_domains)
  @side_answer ~w(service application environment application_agreed)
  @service_fields ~w(service application asks deployed agreed holds agreed_at by variable hosts
                     application_side application_by)

  @doc """
  The declaration of `ehosctl apps sign-in`, for `Ehosctl.Apps`'s subcommands: `list`, `agree`
  and `withdraw`.
  """
  @spec sign_in_spec() :: keyword()
  def sign_in_spec do
    app = [
      value_name: "APPLICATION",
      required: true,
      help: "The name of the application that the pages ask credentials for."
    ]

    client = [
      value_name: "CLIENT",
      required: true,
      help: "The name of the application whose pages ask for the credentials."
    ]

    [
      name: "sign-in",
      about:
        "List, give and withdraw sign-in agreements, as the environment tab of an " <>
          "application does.",
      subcommands: [
        list: [
          name: "list",
          about:
            "List the applications whose pages ask for credentials for an application in an " <>
              "environment, and the sign-in agreements.",
          args: [application: app],
          options: [env: env()],
          flags: Output.json_flag()
        ],
        agree: [
          name: "agree",
          about:
            "Agree that the pages of CLIENT can get credentials for APPLICATION in an " <>
              "environment.",
          args: [application: app, client: client],
          options: [env: env()],
          flags: Output.json_flag()
        ],
        withdraw: [
          name: "withdraw",
          about:
            "Withdraw a sign-in agreement. The pages of CLIENT get no more credentials for " <>
              "APPLICATION there. A credential already issued expires within 10 minutes.",
          args: [application: app, client: client],
          options: [env: env()],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @doc """
  The declarations of `ehosctl people agreements | agree | withdraw`, for `Ehosctl.People`'s
  subcommands.
  """
  @spec people_spec() :: keyword()
  def people_spec do
    app = [value_name: "APPLICATION", required: true, help: "The name of the application."]

    [
      agreements: [
        name: "agreements",
        about:
          "List the applications that ask to read the people in an environment, and the " <>
            "people agreements.",
        flags: Output.json_flag()
      ],
      agree: [
        name: "agree",
        about: "Agree that an application can read the people in an environment.",
        args: [application: app],
        options: [env: env()],
        flags: Output.json_flag()
      ],
      withdraw: [
        name: "withdraw",
        about:
          "Withdraw a people agreement. EHOS refuses the next reading of the people by the " <>
            "application.",
        args: [application: app],
        options: [env: env()],
        flags: Output.json_flag()
      ]
    ]
  end

  @doc """
  The declaration of `ehosctl mail`, for `Ehosctl.Mail`: `agreements`, `agree` and `withdraw`.
  """
  @spec mail_spec() :: keyword()
  def mail_spec do
    app = [value_name: "APPLICATION", required: true, help: "The name of the application."]

    [
      about:
        "List, give and withdraw mail agreements: how far an application can send mail " <>
          "through EHOS in an environment.",
      subcommands: [
        agreements: [
          name: "agreements",
          about:
            "List the applications that ask to send mail through EHOS in an environment, and " <>
              "the mail agreements.",
          flags: Output.json_flag()
        ],
        agree: [
          name: "agree",
          about:
            "Agree how far an application can send mail through EHOS in an environment, or " <>
              "change the mail agreement. The application sends no further than its " <>
              "deployment there asks.",
          args: [application: app],
          options: [
            env: env(),
            level: [
              long: "--level",
              value_name: "LEVEL",
              required: true,
              help:
                "internal: only to the people of the company. external: to any address, " <>
                  "if the application asks for it."
            ],
            reply_domain: [
              long: "--reply-domain",
              value_name: "DOMAIN",
              multiple: true,
              help:
                "A domain that replies can go to, from the domains that the application names " <>
                  "there. Repeat for more, up to 8. Without it, the mail agreement names no reply domain."
            ]
          ],
          flags: Output.json_flag()
        ],
        withdraw: [
          name: "withdraw",
          about: "Withdraw a mail agreement. EHOS refuses the next message of the application.",
          args: [application: app],
          options: [env: env()],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @doc """
  The declaration of `ehosctl services`, for `Ehosctl.Services`: `list`, `agree`, `withdraw`,
  `agree-hosts` and `withdraw-hosts`.
  """
  @spec services_spec() :: keyword()
  def services_spec do
    service = [
      value_name: "SERVICE",
      required: true,
      help: "The name of the utility service."
    ]

    app = [
      value_name: "APPLICATION",
      required: true,
      help: "The name of the application that calls the utility service."
    ]

    side_app = Keyword.put(app, :help, "The name of the application that calls SERVICE.")

    [
      about:
        "List, give and withdraw service agreements: which application can call a utility " <>
          "service in an environment.",
      subcommands: [
        list: [
          name: "list",
          about:
            "List the service agreements of an application or a utility service in an " <>
              "environment: for a utility service, the applications that ask to call it or are " <>
              "agreed to; for an application, the utility services that it asks to call or is " <>
              "agreed for.",
          args: [
            name: [
              value_name: "NAME",
              required: true,
              help: "The name of the application or the utility service."
            ]
          ],
          options: [env: env()],
          flags: Output.json_flag()
        ],
        agree: [
          name: "agree",
          about:
            "Agree that APPLICATION can call SERVICE in an environment. EHOS gives the " <>
              "application the address of the service, and starts its pods again.",
          args: [service: service, application: app],
          options: [env: env()],
          flags: Output.json_flag()
        ],
        withdraw: [
          name: "withdraw",
          about:
            "Withdraw a service agreement. APPLICATION cannot open a new connection to " <>
              "SERVICE there.",
          args: [service: service, application: app],
          options: [env: env()],
          flags: Output.json_flag()
        ],
        agree_hosts: [
          name: "agree-hosts",
          about:
            "Agree for APPLICATION to the hosts outside the installation that SERVICE sends " <>
              "data to in an environment. If SERVICE names a host there, its service agreement " <>
              "holds only after this agreement.",
          args: [application: side_app, service: service],
          options: [
            env: env(),
            host: [
              long: "--host",
              value_name: "HOST:PORT",
              multiple: true,
              required: true,
              help:
                "A host that SERVICE names there, as `ehosctl services list` shows it. Repeat " <>
                  "for each host. EHOS refuses the agreement if the hosts are not all the hosts " <>
                  "that SERVICE names there now."
            ]
          ],
          flags: Output.json_flag()
        ],
        withdraw_hosts: [
          name: "withdraw-hosts",
          about:
            "Withdraw the agreement of APPLICATION to the hosts of SERVICE. APPLICATION cannot " <>
              "open a new connection to SERVICE there. The service agreement stays.",
          args: [application: side_app, service: service],
          options: [env: env()],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  defp env,
    do: [
      long: "--env",
      value_name: "ENVIRONMENT",
      required: true,
      help: "The name of the environment."
    ]

  @doc """
  Runs `ehosctl apps sign-in <action>`: lists the applications whose pages ask for credentials for
  the application in the environment, and those agreed to, or agrees or withdraws for one of them.
  Returns the result to print, or the error: EHOS's refusal of its kind, `:invalid` for a name
  that would leave its place in the path, before anything is sent.
  """
  @spec sign_in(:list | :agree | :withdraw, Optimus.ParseResult.t(), keyword()) ::
          Ehosctl.Command.result()
  def sign_in(action, parsed, opts) do
    env = parsed.options.env

    with :ok <- named([env | Map.values(parsed.args)]) do
      run_sign_in(action, parsed.args, env, opts)
    end
  end

  defp run_sign_in(:list, %{application: app}, env, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, body} <- Api.read(installation, sign_in_path(app, env), opts) do
      sign_in_listed(body, app, env, installation)
    end
  end

  defp run_sign_in(action, %{application: app, client: client}, env, opts) do
    path = sign_in_path(app, env) <> "/" <> Api.segment(client)
    asked = %{"application" => app, "environment" => env, "client" => client}
    look = "`ehosctl apps sign-in list #{Refusal.shown(app)} --env #{Refusal.shown(env)}`"

    decide(opts, action, path, asked, look, fn ->
      pages = "the pages of #{Refusal.shown(client)}"
      where = "#{Refusal.shown(app)} in #{Refusal.shown(env)}"

      case action do
        :agree ->
          "Agreed: #{pages} can get credentials for #{where}."

        :withdraw ->
          "Withdrew the sign-in agreement: #{pages} get no more credentials for #{where}. " <>
            "A credential already issued expires within 10 minutes."
      end
    end)
  end

  # The application and the environment asked for, and no other.
  defp sign_in_listed(
         %{"application" => app, "environment" => env, "requests" => requests},
         app,
         env,
         installation
       )
       when is_list(requests) do
    if Enum.all?(requests, &sign_in_request?/1) do
      requests = Enum.map(requests, &Map.take(&1, @sign_in_fields))

      {:ok,
       %{
         text: sign_in_table(requests, app, env),
         json: %{application: app, environment: env, requests: requests}
       }}
    else
      Api.unexpected(installation)
    end
  end

  defp sign_in_listed(_other, _app, _env, installation), do: Api.unexpected(installation)

  @doc """
  Runs `ehosctl people <action>`: lists the applications that ask to read the people, in each
  environment, and those agreed to, or agrees or withdraws for an application in an environment.
  Returns the result to print, or the error: EHOS's refusal of its kind, `:invalid` for a name
  that would leave its place in the path, before anything is sent.
  """
  @spec people(:agreements | :agree | :withdraw, Optimus.ParseResult.t(), keyword()) ::
          Ehosctl.Command.result()
  def people(:agreements, _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, body} <- Api.read(installation, "/api/v1/people-agreements", opts) do
      people_listed(body, installation)
    end
  end

  def people(action, parsed, opts) do
    %{application: app} = parsed.args
    env = parsed.options.env

    with :ok <- named([app, env]) do
      path = "/api/v1/applications/#{Api.segment(app)}/environments/#{Api.segment(env)}/people"
      asked = %{"application" => app, "environment" => env}

      decide(opts, action, path, asked, "`ehosctl people agreements`", fn ->
        people_decided(action, app, env)
      end)
    end
  end

  defp people_listed(%{"requests" => requests}, installation) when is_list(requests) do
    if Enum.all?(requests, &people_request?/1) do
      requests = Enum.map(requests, &Map.take(&1, @people_fields))
      {:ok, %{text: people_table(requests), json: %{requests: requests}}}
    else
      Api.unexpected(installation)
    end
  end

  defp people_listed(_other, installation), do: Api.unexpected(installation)

  defp people_decided(action, app, env) do
    {app, env} = {Refusal.shown(app), Refusal.shown(env)}

    case action do
      :agree ->
        "Agreed: #{app} can now read the people in #{env}."

      :withdraw ->
        "Withdrew the people agreement: EHOS refuses the next reading of the people by #{app} " <>
          "in #{env}."
    end
  end

  @doc """
  Runs `ehosctl mail <action>`: lists the applications that ask to send mail through EHOS, in each
  environment, and the agreements given, or agrees, changes or withdraws one for an application
  in an environment. Returns the result to print, or the error: EHOS's refusal of its kind,
  `:invalid` for a name that would leave its place in the path, before anything is sent.
  """
  @spec mail(:agreements | :agree | :withdraw, Optimus.ParseResult.t(), keyword()) ::
          Ehosctl.Command.result()
  def mail(:agreements, _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, body} <- Api.read(installation, "/api/v1/mail-agreements", opts) do
      mail_listed(body, installation)
    end
  end

  def mail(action, parsed, opts) do
    %{application: app} = parsed.args
    env = parsed.options.env

    with :ok <- named([app, env]) do
      path = "/api/v1/applications/#{Api.segment(app)}/environments/#{Api.segment(env)}/mail"
      decide_mail(action, {app, env}, path, parsed.options, opts)
    end
  end

  defp mail_listed(%{"requests" => requests}, installation) when is_list(requests) do
    if Enum.all?(requests, &mail_request?/1) do
      requests = Enum.map(requests, &only_mail_request/1)
      {:ok, %{text: mail_table(requests), json: %{requests: requests}}}
    else
      Api.unexpected(installation)
    end
  end

  defp mail_listed(_other, installation), do: Api.unexpected(installation)

  # As for the people, giving an agreement again is the same agreement, so a change that went
  # unanswered is safe to send again. EHOS keeps the reply domains once each, sorted, and answers
  # what it kept: it is taken only when it is what was asked.
  defp decide_mail(:agree, {app, env}, path, options, opts) do
    domains = options.reply_domain || []
    asked = %{level: options.level, reply_domains: domains}

    expected = %{
      "application" => app,
      "environment" => env,
      "agreed" => true,
      "level" => options.level,
      "reply_domains" => domains |> Enum.uniq() |> Enum.sort()
    }

    write_mail(opts, {:post, path, asked}, expected, fn agreement ->
      "Agreed: in #{Refusal.shown(env)}, #{Refusal.shown(app)} can #{mail_asked(agreement)}, " <>
        "as far as its deployment there asks."
    end)
  end

  defp decide_mail(:withdraw, {app, env}, path, _options, opts) do
    expected = %{
      "application" => app,
      "environment" => env,
      "agreed" => false,
      "level" => nil,
      "reply_domains" => []
    }

    write_mail(opts, {:delete, path, nil}, expected, fn _agreement ->
      "Withdrew the mail agreement: EHOS refuses the next message of #{Refusal.shown(app)} " <>
        "in #{Refusal.shown(env)}."
    end)
  end

  @doc """
  Runs `ehosctl services <action>`: lists the service agreements of an application or a utility
  service in an environment, or agrees or withdraws one, or the application's side of one.
  Returns the result to print, or the error: EHOS's refusal of its kind, `:invalid` for a name
  that would leave its place in the path, before anything is sent.
  """
  @spec services(
          :list | :agree | :withdraw | :agree_hosts | :withdraw_hosts,
          Optimus.ParseResult.t(),
          keyword()
        ) :: Ehosctl.Command.result()
  def services(action, parsed, opts) do
    env = parsed.options.env

    with :ok <- named([env | Map.values(parsed.args)]) do
      run_services(action, parsed.args, parsed.options, opts)
    end
  end

  defp run_services(:list, %{name: name}, %{env: env}, opts) do
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/applications/#{Api.segment(name)}/environments/#{Api.segment(env)}/services"

    with {:ok, body} <- Api.read(installation, path, opts) do
      services_listed(body, name, env, installation)
    end
  end

  defp run_services(action, %{application: app, service: service}, options, opts)
       when action in [:agree_hosts, :withdraw_hosts] do
    env = options.env

    path =
      "/api/v1/applications/#{Api.segment(app)}/environments/#{Api.segment(env)}" <>
        "/services/#{Api.segment(service)}"

    look = "`ehosctl services list #{Refusal.shown(app)} --env #{Refusal.shown(env)}`"

    # EHOS compares the hosts as a set, and refuses more than a version can name: a host given
    # twice is sent once.
    {request, agreed} =
      if action == :agree_hosts,
        do: {{:post, path, %{hosts: Enum.uniq(options.host)}}, true},
        else: {{:delete, path, nil}, false}

    expected = %{
      "service" => service,
      "application" => app,
      "environment" => env,
      "application_agreed" => agreed
    }

    Api.write(
      opts,
      request,
      [
        status: 200,
        key: nil,
        valid?: &(Map.take(&1, @side_answer) == expected),
        only: &Map.take(&1, @side_answer),
        look: look,
        refused: &side_refused(&1, look)
      ],
      fn _answer -> side_decided(action, service, app, env) end
    )
  end

  defp run_services(action, %{service: service, application: app}, %{env: env}, opts) do
    path =
      "/api/v1/applications/#{Api.segment(service)}/environments/#{Api.segment(env)}" <>
        "/callers/#{Api.segment(app)}"

    asked = %{"service" => service, "application" => app, "environment" => env}
    look = "`ehosctl services list #{Refusal.shown(service)} --env #{Refusal.shown(env)}`"

    decide(opts, action, path, asked, look, fn ->
      {service, app, env} = {Refusal.shown(service), Refusal.shown(app), Refusal.shown(env)}

      case action do
        :agree ->
          "Agreed: #{app} can call #{service} in #{env}. EHOS starts the pods of #{app} " <>
            "again with the address of #{service}."

        :withdraw ->
          "Withdrew the service agreement: #{app} cannot open a new connection to #{service} " <>
            "in #{env}. EHOS starts the pods of #{app} again without the address."
      end
    end)
  end

  # The console's words for the application's side given or withdrawn, without its "You".
  defp side_decided(action, service, app, env) do
    {service, app, env} = {Refusal.shown(service), Refusal.shown(app), Refusal.shown(env)}

    case action do
      :agree_hosts ->
        "Agreed for #{app} to the hosts of #{service} in #{env}. While #{app} asks, it can " <>
          "call #{service}, and EHOS starts its pods again with the address."

      :withdraw_hosts ->
        "Withdrew the agreement of #{app} to the hosts of #{service} in #{env}. #{app} cannot " <>
          "open a new connection to #{service}, and EHOS starts its pods again without the " <>
          "address."
    end
  end

  # EHOS says to read the hosts again; the command that reads them.
  defp side_refused(%{"error" => "hosts_changed"}, look), do: " #{look} lists them."
  defp side_refused(_body, _look), do: nil

  # The application and the environment asked for, and no other.
  defp services_listed(
         %{"application" => name, "kind" => kind, "environment" => env, "requests" => requests},
         name,
         env,
         installation
       )
       when kind in ["application", "service"] and is_list(requests) do
    if Enum.all?(requests, &(service_request?(&1) and own_side?(&1, name, kind))) do
      requests = Enum.map(requests, &Map.take(&1, @service_fields))

      {:ok,
       %{
         text: services_table(requests, name, kind, env),
         json: %{application: name, kind: kind, environment: env, requests: requests}
       }}
    else
      Api.unexpected(installation)
    end
  end

  defp services_listed(_other, _name, _env, installation), do: Api.unexpected(installation)

  defp write_mail(opts, request, expected, said) do
    Api.write(
      opts,
      request,
      [
        status: 200,
        key: nil,
        valid?: &(Map.take(&1, @mail_answer) == expected),
        only: &Map.take(&1, @mail_answer),
        look: "`ehosctl mail agreements`"
      ],
      said
    )
  end

  # An agreement given is `POST`, withdrawn `DELETE`, each answered with what was asked and
  # whether it is now agreed. Giving one again is the same agreement, so a change that went
  # unanswered is safe to send again; `Api.write/4` tells the person to look first.
  defp decide(opts, action, path, asked, look, said) do
    {method, agreed} = if action == :agree, do: {:post, true}, else: {:delete, false}
    expected = Map.put(asked, "agreed", agreed)
    fields = Map.keys(expected)

    Api.write(
      opts,
      {method, path, nil},
      [
        status: 200,
        key: nil,
        valid?: &(Map.take(&1, fields) == expected),
        only: &Map.take(&1, fields),
        look: look
      ],
      fn _answer -> said.() end
    )
  end

  # A name that would leave its place in the path (`.`, `..`), or names nothing, is refused
  # before anything is sent: a proxy that resolves dot segments would send it elsewhere.
  defp named(names) do
    case Enum.find(names, &Api.is_nameless(&1)) do
      nil ->
        :ok

      word ->
        {:error, :invalid,
         "#{inspect(word)} is not the name of an application or an environment. Give the " <>
           "name of each application and of the environment."}
    end
  end

  defp sign_in_path(app, env),
    do: "/api/v1/applications/#{Api.segment(app)}/environments/#{Api.segment(env)}/sign-in"

  defp sign_in_request?(%{"client" => client} = request) when is_binary(client),
    do: client != "" and state?(request)

  defp sign_in_request?(_request), do: false

  defp service_request?(
         %{"service" => service, "application" => app, "variable" => variable} = request
       )
       when is_binary(service) and is_binary(app) and is_binary(variable),
       do:
         service != "" and app != "" and state?(request) and is_boolean(request["deployed"]) and
           is_boolean(request["holds"]) and outside?(request)

  defp service_request?(_request), do: false

  # The hosts outside the installation that the service names there, and the application's side
  # of the service agreement. An EHOS from before these answers neither: its services name no host.
  defp outside?(request),
    do:
      hosts?(request["hosts"]) and side?(request["application_side"]) and
        (is_nil(request["application_by"]) or is_binary(request["application_by"]))

  defp hosts?(nil), do: true
  defp hosts?(hosts) when is_list(hosts), do: Enum.all?(hosts, &(is_binary(&1) and &1 != ""))
  defp hosts?(_hosts), do: false

  defp side?(side), do: side in [nil, "not_needed", "waiting", "agreed"]

  # Each row names the application or the service asked for on its own side.
  defp own_side?(request, name, "service"), do: request["service"] == name
  defp own_side?(request, name, "application"), do: request["application"] == name

  defp people_request?(%{"application" => app, "environment" => env} = request)
       when is_binary(app) and is_binary(env),
       do:
         app != "" and env != "" and state?(request) and
           (is_nil(request["from_template"]) or is_binary(request["from_template"]))

  defp people_request?(_request), do: false

  # What it asks and what is agreed, each a reach of mail or nil, since when and by whom.
  # `asks` and `agreed` are always written, null when there is none.
  defp mail_request?(
         %{"application" => app, "environment" => env, "asks" => _, "agreed" => _} = request
       )
       when is_binary(app) and is_binary(env),
       do:
         app != "" and env != "" and reach?(request["asks"]) and reach?(request["agreed"]) and
           moment?(request["agreed_at"]) and (is_nil(request["by"]) or is_binary(request["by"]))

  defp mail_request?(_request), do: false

  defp reach?(nil), do: true

  defp reach?(%{"level" => level, "reply_domains" => domains})
       when level in ["internal", "external"] and is_list(domains),
       do: Enum.all?(domains, &is_binary/1)

  defp reach?(_reach), do: false

  defp only_mail_request(request) do
    request
    |> Map.take(@mail_fields)
    |> Map.update!("asks", &only_reach/1)
    |> Map.update!("agreed", &only_reach/1)
  end

  defp only_reach(nil), do: nil
  defp only_reach(reach), do: Map.take(reach, ~w(level reply_domains))

  # Whether it asks, whether it is agreed to, since when and by whom: `by` is nil for someone
  # EHOS no longer names.
  defp state?(request),
    do:
      is_boolean(request["asks"]) and is_boolean(request["agreed"]) and
        moment?(request["agreed_at"]) and (is_nil(request["by"]) or is_binary(request["by"]))

  defp moment?(nil), do: true
  defp moment?(at) when is_binary(at), do: match?({:ok, _at, _offset}, DateTime.from_iso8601(at))
  defp moment?(_at), do: false

  defp sign_in_table([], app, env),
    do:
      "No sign-in agreements for #{Refusal.shown(app)} in #{Refusal.shown(env)}. An " <>
        "application shows here when its pages ask for credentials for #{Refusal.shown(app)}."

  defp sign_in_table(requests, _app, _env) do
    requests
    |> Enum.map(&Map.put(row(&1), "PAGES OF", Refusal.shown(&1["client"])))
    |> Output.table(["PAGES OF", "AGREEMENT", "AGREED", "BY"])
  end

  defp services_table([], name, "service", env),
    do:
      "No callers of #{Refusal.shown(name)} in #{Refusal.shown(env)}. An application shows " <>
        "here when its deployment there asks to call #{Refusal.shown(name)}."

  defp services_table([], name, _application, env),
    do:
      "No utility services for #{Refusal.shown(name)} in #{Refusal.shown(env)}. A utility " <>
        "service shows here when the deployment of #{Refusal.shown(name)} there asks to call it."

  # The tab's words for each state, and, on an application's side, the variable it reads the
  # address in.
  defp services_table(requests, _name, kind, _env) do
    {other, columns} = services_columns(kind)

    requests
    |> Enum.map(fn request ->
      %{
        String.upcase(other) => Refusal.shown(request[other]),
        "SERVICE AGREEMENT" => service_state(request),
        "AGREED" => if(request["agreed_at"], do: Output.date(request["agreed_at"]), else: ""),
        "BY" => if(request["by"], do: Refusal.shown(request["by"]), else: ""),
        "HOSTS" => hosts(request["hosts"]),
        "APPLICATION'S SIDE" => application_side(request),
        "ADDRESS IN" => Refusal.shown(request["variable"])
      }
      # The table's columns are its rows' keys.
      |> Map.take(columns)
    end)
    |> Output.table(columns)
  end

  defp services_columns("service"),
    do:
      {"application",
       ["APPLICATION", "SERVICE AGREEMENT", "AGREED", "BY", "HOSTS", "APPLICATION'S SIDE"]}

  defp services_columns("application"),
    do:
      {"service",
       [
         "SERVICE",
         "SERVICE AGREEMENT",
         "AGREED",
         "BY",
         "HOSTS",
         "APPLICATION'S SIDE",
         "ADDRESS IN"
       ]}

  defp hosts(hosts) when hosts in [nil, []], do: "none"
  defp hosts(hosts), do: Enum.map_join(hosts, ", ", &Refusal.shown/1)

  # The tab's words for the application's side: needed only while the service names a host.
  defp application_side(%{"application_side" => "agreed", "application_by" => by})
       when is_binary(by),
       do: "agreed by #{Refusal.shown(by)}"

  defp application_side(%{"application_side" => "agreed"}), do: "agreed"
  defp application_side(%{"application_side" => "waiting"}), do: "waits"
  defp application_side(_not_needed), do: "not needed"

  @doc """
  The words of `ehosctl services list`, and of the console's tab, for the state of a service
  agreement as EHOS gives it: whether it is agreed, asked for and holding, whether the service is
  deployed there, and the application's side, each given, as `ehosctl services list` and the
  review of a utility service's promotion check them before they say a state.

      iex> Ehosctl.Agreements.service_state(%{
      ...>   "agreed" => false,
      ...>   "asks" => true,
      ...>   "holds" => false,
      ...>   "deployed" => true,
      ...>   "application_side" => "not_needed"
      ...> })
      "asks, not agreed"
  """
  @spec service_state(map()) :: String.t()
  def service_state(%{"agreed" => true, "asks" => true, "application_side" => "waiting"}),
    do: "agreed, waits for the application's side"

  def service_state(request) do
    cond do
      request["holds"] and request["deployed"] ->
        "agreed"

      request["holds"] ->
        "agreed, service not deployed here"

      request["agreed"] ->
        "agreed, no longer asked"

      request["deployed"] ->
        "asks, not agreed"

      true ->
        "asks, service not deployed here"
    end
  end

  defp people_table([]),
    do:
      "No people agreements. An application shows here when its deployment in an environment " <>
        "asks to read the people."

  defp people_table(requests) do
    templated? = Enum.any?(requests, &is_binary(&1["from_template"]))

    requests
    |> Enum.map(fn request ->
      request
      |> row()
      |> Map.put("APPLICATION", Refusal.shown(request["application"]))
      |> Map.put("ENVIRONMENT", Refusal.shown(request["environment"]))
      |> put_from_template(templated?, request["from_template"])
    end)
    |> Output.table(["APPLICATION", "ENVIRONMENT", "AGREEMENT", "AGREED", "BY", "FROM TEMPLATE"])
  end

  # The column of an environment template only when an agreement came from one: the table's
  # columns are its rows' keys.
  defp put_from_template(row, false, _template), do: row

  defp put_from_template(row, true, template),
    do: Map.put(row, "FROM TEMPLATE", from_template(template))

  defp mail_table([]),
    do:
      "No mail agreements. An application shows here when its deployment in an environment " <>
        "asks to send mail through EHOS."

  # The Installation page's words, without its "Send mail through EHOS" that every cell would
  # repeat: what each asks, or that it no longer does, and the agreement.
  defp mail_table(requests) do
    requests
    |> Enum.map(fn request ->
      %{
        "APPLICATION" => Refusal.shown(request["application"]),
        "ENVIRONMENT" => Refusal.shown(request["environment"]),
        "ASKS" => if(request["asks"], do: whom(request["asks"]), else: "no longer asks"),
        "AGREEMENT" => if(request["agreed"], do: whom(request["agreed"]), else: "not agreed"),
        "AGREED" => if(request["agreed_at"], do: Output.date(request["agreed_at"]), else: ""),
        "BY" => if(request["by"], do: Refusal.shown(request["by"]), else: "")
      }
    end)
    |> Output.table(["APPLICATION", "ENVIRONMENT", "ASKS", "AGREEMENT", "AGREED", "BY"])
  end

  defp mail_asked(reach), do: "send mail through EHOS " <> whom(reach)

  defp whom(reach), do: Ehosctl.Mail.whom(reach)

  # EHOS's D-161: the environment template a people agreement came from, which reads nothing while
  # a deployment by a pipeline is in force there, or one failed after the active one. An EHOS from
  # before it answers no key.
  defp from_template(nil), do: ""

  defp from_template(template),
    do:
      "#{Refusal.shown(template)}, not while a pipeline's deployment is in force or failed " <>
        "after the active one"

  # The console's words for an agreement's state: an agreement outlasts the deployment that asked
  # for it, until it is withdrawn.
  defp row(request) do
    %{
      "AGREEMENT" =>
        cond do
          request["agreed"] and request["asks"] -> "agreed"
          request["agreed"] -> "agreed, no longer asked"
          true -> "asks"
        end,
      "AGREED" => if(request["agreed_at"], do: Output.date(request["agreed_at"]), else: ""),
      "BY" => if(request["by"], do: Refusal.shown(request["by"]), else: "")
    }
  end
end

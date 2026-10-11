defmodule Ehosctl.Agreements do
  @moduledoc """
  The two things EHOS gives an application only once someone agrees, listed, agreed to and
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

  EHOS decides and records each call, and its refusal is printed in its words. An application and
  an environment are named by their names, each a segment of the path. An answer is taken only
  for the application, the environment and the pages asked for, and only the fields the API says
  it holds are printed, under `--json` too.
  """

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @sign_in_fields ~w(client asks agreed agreed_at by)
  @people_fields ~w(application environment asks agreed agreed_at by)

  @doc """
  The declaration of `ehosctl apps sign-in`, for `Ehosctl.Apps`'s subcommands: `list`, `agree`
  and `withdraw`.
  """
  @spec sign_in_spec() :: keyword()
  def sign_in_spec do
    app = [
      value_name: "APPLICATION",
      required: true,
      help: "The application whose credentials are asked for, by its name."
    ]

    client = [
      value_name: "CLIENT",
      required: true,
      help: "The application whose pages ask for them, by its name."
    ]

    [
      name: "sign-in",
      about:
        "List, agree to and withdraw other applications' pages getting credentials for an " <>
          "application, as its environment tab does.",
      subcommands: [
        list: [
          name: "list",
          about:
            "List the applications whose pages ask for credentials for an application in an " <>
              "environment, and those agreed to.",
          args: [application: app],
          options: [env: env()],
          flags: Output.json_flag()
        ],
        agree: [
          name: "agree",
          about:
            "Agree that CLIENT's pages may get credentials for APPLICATION in an environment.",
          args: [application: app, client: client],
          options: [env: env()],
          flags: Output.json_flag()
        ],
        withdraw: [
          name: "withdraw",
          about:
            "Withdraw that agreement: CLIENT's pages get no more credentials for APPLICATION " <>
              "there, and one already issued expires within ten minutes.",
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
    app = [value_name: "APPLICATION", required: true, help: "The application, by its name."]

    [
      agreements: [
        name: "agreements",
        about:
          "List the applications that ask to read the people, in one environment each, and " <>
            "those agreed to.",
        flags: Output.json_flag()
      ],
      agree: [
        name: "agree",
        about: "Agree that an application may read the people in an environment.",
        args: [application: app],
        options: [env: env()],
        flags: Output.json_flag()
      ],
      withdraw: [
        name: "withdraw",
        about: "Withdraw that agreement: the application's next reading is refused.",
        args: [application: app],
        options: [env: env()],
        flags: Output.json_flag()
      ]
    ]
  end

  defp env,
    do: [
      long: "--env",
      value_name: "ENVIRONMENT",
      required: true,
      help: "The environment, by its name."
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
      case body do
        # The application and the environment asked for, and no other.
        %{"application" => ^app, "environment" => ^env, "requests" => requests}
        when is_list(requests) ->
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

        _other ->
          Api.unexpected(installation)
      end
    end
  end

  defp run_sign_in(action, %{application: app, client: client}, env, opts) do
    path = sign_in_path(app, env) <> "/" <> segment(client)
    asked = %{"application" => app, "environment" => env, "client" => client}
    look = "`ehosctl apps sign-in list #{Refusal.shown(app)} --env #{Refusal.shown(env)}`"

    decide(opts, action, path, asked, look, fn ->
      pages = "#{Refusal.shown(client)}'s pages"
      where = "#{Refusal.shown(app)} in #{Refusal.shown(env)}"

      case action do
        :agree ->
          "Agreed: #{pages} may get credentials for #{where}."

        :withdraw ->
          "Withdrawn: #{pages} get no more credentials for #{where}; one already issued " <>
            "expires within ten minutes."
      end
    end)
  end

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
      case body do
        %{"requests" => requests} when is_list(requests) ->
          if Enum.all?(requests, &people_request?/1) do
            requests = Enum.map(requests, &Map.take(&1, @people_fields))
            {:ok, %{text: people_table(requests), json: %{requests: requests}}}
          else
            Api.unexpected(installation)
          end

        _other ->
          Api.unexpected(installation)
      end
    end
  end

  def people(action, parsed, opts) do
    %{application: app} = parsed.args
    env = parsed.options.env

    with :ok <- named([app, env]) do
      path = "/api/v1/applications/#{segment(app)}/environments/#{segment(env)}/people"
      asked = %{"application" => app, "environment" => env}

      decide(opts, action, path, asked, "`ehosctl people agreements`", fn ->
        {app, env} = {Refusal.shown(app), Refusal.shown(env)}

        case action do
          :agree -> "Agreed: #{app} may now read the people in #{env}."
          :withdraw -> "Withdrawn: #{app}'s next reading of the people in #{env} is refused."
        end
      end)
    end
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
    case Enum.find(names, &(&1 in ["", ".", ".."])) do
      nil -> :ok
      word -> {:error, :invalid, "#{Refusal.shown(word)} names no application or environment."}
    end
  end

  defp sign_in_path(app, env),
    do: "/api/v1/applications/#{segment(app)}/environments/#{segment(env)}/sign-in"

  defp segment(name), do: URI.encode(name, &URI.char_unreserved?/1)

  defp sign_in_request?(%{"client" => client} = request) when is_binary(client),
    do: client != "" and state?(request)

  defp sign_in_request?(_request), do: false

  defp people_request?(%{"application" => app, "environment" => env} = request)
       when is_binary(app) and is_binary(env),
       do: app != "" and env != "" and state?(request)

  defp people_request?(_request), do: false

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
      "No application's pages ask for credentials for #{Refusal.shown(app)} in " <>
        "#{Refusal.shown(env)}, and none is agreed to."

  defp sign_in_table(requests, _app, _env) do
    requests
    |> Enum.map(&Map.put(row(&1), "PAGES OF", Refusal.shown(&1["client"])))
    |> Output.table(["PAGES OF", "AGREEMENT", "AGREED", "BY"])
  end

  defp people_table([]), do: "No application asks to read the people, and none is agreed to."

  defp people_table(requests) do
    requests
    |> Enum.map(fn request ->
      request
      |> row()
      |> Map.put("APPLICATION", Refusal.shown(request["application"]))
      |> Map.put("ENVIRONMENT", Refusal.shown(request["environment"]))
    end)
    |> Output.table(["APPLICATION", "ENVIRONMENT", "AGREEMENT", "AGREED", "BY"])
  end

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

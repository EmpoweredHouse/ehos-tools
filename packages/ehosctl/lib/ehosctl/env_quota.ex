defmodule Ehosctl.EnvQuota do
  @moduledoc """
  `ehosctl env quota show | set | clear`: an environment's own quota and limits, through EHOS's
  API (eh-os
  [`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md),
  "An environment's own quota", D-143), as the console's environment page sets them.

  An environment that is not ephemeral gets the installation's quota and limits until it is given
  its own. `--quota` is merged key by key over the installation's, and `--limits` replaces the
  installation's for each resource it names, both within the ceiling whoever runs the server set;
  they are written as `ehosctl env template` writes a template's. A flag left out leaves its field
  as it is, and one given as `''` gives it back to the installation, as `clear` does for both.

  Setting needs `ehos.environment.manage`, and EHOS records each change as
  `environment_quota.set`. A quota below what is deployed there is taken: what runs keeps running,
  and the applications whose next deployment there no longer fits are named. An ephemeral
  environment's quota is its template's, which EHOS refuses to change here.
  """

  alias Ehosctl.Api
  alias Ehosctl.EnvTemplates
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @look "`ehosctl env quota show`"

  @doc "The declaration of `ehosctl env quota`, for `Ehosctl.Env`'s subcommands."
  @spec spec() :: keyword()
  def spec do
    env = [value_name: "ENVIRONMENT", required: true, help: "The environment, by its name."]

    [
      name: "quota",
      about:
        "Show, set and clear an environment's own quota and limits, within the installation's " <>
          "ceiling (D-143).",
      subcommands: [
        show: [
          name: "show",
          about: "Show an environment's quota and limits: its own, or the installation's.",
          args: [environment: env],
          flags: Output.json_flag()
        ],
        set: [
          name: "set",
          about:
            "Give an environment that is not ephemeral a quota or limits of its own; a flag left " <>
              "out keeps what it has.",
          args: [environment: env],
          options: EnvTemplates.quota_options(),
          flags: Output.json_flag()
        ],
        clear: [
          name: "clear",
          about: "Give an environment back the installation's quota and limits.",
          args: [environment: env],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @doc """
  Runs `ehosctl env quota <action>`, as `c:Ehosctl.Command.call/3` runs a command; the
  environment's name is checked by `Ehosctl.Env`.
  """
  @spec call(atom(), Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call(:show, parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    # The environment EHOS answers is the one asked for, or its quota is not this one's.
    with {:ok, %{"environment" => env}} <- Api.read(installation, path(parsed), opts),
         true <-
           (environment?(env) and env["name"] == parsed.args.environment) ||
             Api.unexpected(installation) do
      env = only_environment(env)
      {:ok, %{text: shown(env), json: %{environment: env}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  def call(:set, parsed, opts) do
    with {:ok, body} <- EnvTemplates.quota_and_limits(%{}, parsed.options, opts) do
      if body == %{},
        do: {:error, :invalid, "Say what to set: --quota, --limits, or both."},
        else: write(parsed, body, opts)
    end
  end

  def call(:clear, parsed, opts), do: write(parsed, %{quota: nil, limits: nil}, opts)

  defp path(parsed), do: "/api/v1/environments/" <> Api.segment(parsed.args.environment)

  # EHOS answers the environment and `no_longer_fit`, the applications whose next deployment there
  # would now be refused for room; the environment it names is the one asked for, or something
  # else was done.
  defp write(parsed, body, opts) do
    name = parsed.args.environment

    Api.write(
      opts,
      {:patch, path(parsed), body},
      [status: 200, key: nil, valid?: &set?(&1, name), only: &only_set/1, look: @look],
      fn %{"environment" => env, "no_longer_fit" => names} ->
        if not parsed.flags[:json], do: warn_no_longer_fit(names)

        Output.lines([
          Output.outcome(:done, "Changed the quota and limits of #{Refusal.shown(env["name"])}."),
          Output.values(values(env))
        ])
      end
    )
  end

  defp set?(%{"environment" => env, "no_longer_fit" => names}, name),
    do:
      environment?(env) and env["name"] == name and is_list(names) and
        Enum.all?(names, &is_binary/1)

  defp set?(_answer, _name), do: false

  defp only_set(answer),
    do: %{
      "environment" => only_environment(answer["environment"]),
      "no_longer_fit" => answer["no_longer_fit"]
    }

  defp environment?(%{"name" => name, "type" => type} = env),
    do:
      is_binary(name) and is_binary(type) and EnvTemplates.quota?(env["quota"]) and
        EnvTemplates.limits?(env["limits"])

  defp environment?(_env), do: false

  defp only_environment(env), do: Map.take(env, ~w(name type quota limits))

  defp shown(env) do
    whose = if env["type"] == "ephemeral", do: ", its template's when it was made", else: ""

    Output.lines([
      "#{Refusal.shown(env["name"])}, #{Refusal.shown(env["type"])}#{whose}",
      Output.values(values(env))
    ])
  end

  @doc """
  An environment's quota and limits as labelled values, as `env quota` and `env show` print them.
  An ephemeral environment's are what it was given when it was made. Another's own are said to
  stand over the installation's, which EHOS merges them over, so a key they leave out is not read
  as unbounded.
  """
  @spec values(map()) :: [{String.t(), String.t()}]
  def values(env) do
    label = fn name, own, nothing ->
      if env["type"] != "ephemeral" and own not in nothing,
        do: "#{name} (over the installation's)",
        else: name
    end

    [
      {label.("Quota", env["quota"], [nil, %{}]), EnvTemplates.quota_said(env["quota"])},
      {label.("Limits", env["limits"], [nil, []]), EnvTemplates.limits_said(env["limits"])}
    ]
  end

  defp warn_no_longer_fit([]), do: :ok

  defp warn_no_longer_fit(names),
    do:
      Output.warn(
        "The next deployment of these applications here no longer fits this quota:",
        Output.lines([
          Output.list(Enum.map(names, &Refusal.shown/1)),
          "EHOS refuses it until the quota or what it asks for changes. What runs keeps running."
        ])
      )
end

defmodule Ehosctl.Env do
  @moduledoc """
  `ehosctl env list | show | create | remove | bind | unbind`: an installation's environments and
  the resources bound in them, through EHOS's API (eh-os
  [`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md),
  D-54, D-57, D-82), as the console's Environments and environment pages manage them.

  Reading needs one of the platform capabilities; creating and removing `ehos.environment.manage`;
  binding and unbinding `ehos.resource.manage`. EHOS decides and records each call, and its refusal
  is printed in its words. An environment and a resource are named by their name, a binding by the
  id `env show` lists.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @impl Ehosctl.Command
  def name, do: :env

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    env = [value_name: "ENVIRONMENT", required: true, help: "The environment, by its name."]

    [
      about: "List, create and remove environments, and bind resources in them.",
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
          about: "Create an environment.",
          args: [environment: env],
          options: [
            type: [
              long: "--type",
              value_name: "TYPE",
              required: true,
              help: "production or ephemeral: which resources it may bind (D-57)."
            ]
          ],
          flags: Output.json_flag()
        ],
        remove: [
          name: "remove",
          about: "Remove an environment nothing names any more.",
          args: [environment: env],
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
        ]
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call(command, parsed, opts) do
    # A name that would leave its place in the path (`.`, `..`), or names nothing, is refused
    # before anything is sent: a proxy that resolves dot segments would send it elsewhere.
    case Enum.find(Map.values(parsed.args), &(&1 in ["", ".", ".."])) do
      nil ->
        run(command, parsed, opts)

      word ->
        {:error, :invalid, "#{Refusal.shown(word)} names no environment, resource or binding."}
    end
  end

  defp run([:list], _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"environments" => envs}} when is_list(envs) <-
           read(installation, "/api/environments", opts),
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
    path = "/api/environments/" <> segment(parsed.args.environment)

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
    body = %{name: parsed.args.environment, type: parsed.options.type}

    write(
      opts,
      :post,
      "/api/environments",
      body,
      201,
      "environment",
      {&environment?/1, &only_environment/1},
      fn env ->
        "Created #{Refusal.shown(env["name"])}, #{Refusal.shown(env["type"])}. Bind its " <>
          "resources with `ehosctl env bind`."
      end
    )
  end

  defp run([:remove], parsed, opts) do
    path = "/api/environments/" <> segment(parsed.args.environment)

    write(
      opts,
      :delete,
      path,
      nil,
      200,
      "environment",
      {&environment?/1, &only_environment/1},
      fn env ->
        "Removed #{Refusal.shown(env["name"])}: the operator deletes its namespace."
      end
    )
  end

  defp run([:bind], parsed, opts) do
    path = "/api/environments/" <> segment(parsed.args.environment) <> "/bindings"

    body =
      Map.reject(
        %{resource: parsed.args.resource, application: parsed.options.application},
        &is_nil(elem(&1, 1))
      )

    write(opts, :post, path, body, 201, "binding", {&binding?/1, &only_binding/1}, fn binding ->
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

    path = "/api/environments/" <> segment(env) <> "/bindings/" <> segment(id)
    # The binding asked for, and no other, is what EHOS says it removed: a UUID, which EHOS reads
    # in either case and answers in lower case.
    unbound = {&same_id?(&1, id), &Map.take(&1, ["id"])}

    write(opts, :delete, path, nil, 200, "binding", unbound, fn _ ->
      "Unbound #{Refusal.shown(id)} from #{Refusal.shown(env)}."
    end)
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

  defp segment(name), do: URI.encode(name, &URI.char_unreserved?/1)

  defp environment?(%{"name" => name, "type" => type}), do: is_binary(name) and is_binary(type)
  defp environment?(_env), do: false

  defp only_environment(env), do: Map.take(env, ~w(name type))

  defp shown?(%{"bindings" => bindings} = env) when is_list(bindings),
    do: environment?(env) and Enum.all?(bindings, &binding?/1)

  defp shown?(_env), do: false

  defp only_shown(env),
    do:
      env |> only_environment() |> Map.put("bindings", Enum.map(env["bindings"], &only_binding/1))

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
    |> Enum.map(&%{"NAME" => Refusal.shown(&1["name"]), "TYPE" => Refusal.shown(&1["type"])})
    |> Output.table(["NAME", "TYPE"])
  end

  defp shown(env) do
    head = "#{Refusal.shown(env["name"])}, #{Refusal.shown(env["type"])}"

    case env["bindings"] do
      [] ->
        head <> "\nNo resources are bound in it."

      bindings ->
        rows =
          bindings
          |> Enum.map(fn binding ->
            %{
              "KIND" => Refusal.shown(binding["kind"]),
              "RESOURCE" => Refusal.shown(binding["resource"]),
              "FOR" =>
                if(binding["application"],
                  do: Refusal.shown(binding["application"]),
                  else: "default"
                ),
              "SCHEMA" => if(binding["schema"], do: Refusal.shown(binding["schema"]), else: ""),
              "USED" => if(binding["used"] == true, do: "yes", else: "no"),
              "ID" => Refusal.shown(binding["id"])
            }
          end)
          |> Output.table(["KIND", "RESOURCE", "FOR", "SCHEMA", "USED", "ID"])

        head <> "\n\n" <> rows
    end
  end
end

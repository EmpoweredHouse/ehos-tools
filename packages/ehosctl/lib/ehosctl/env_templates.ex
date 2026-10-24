defmodule Ehosctl.EnvTemplates do
  @moduledoc """
  `ehosctl env template list | show | create | update | remove | bind | unbind`: the templates an
  installation makes its ephemeral environments from, through EHOS's API (eh-os
  [`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md),
  "Templates", D-98), as the console's Templates page manages them.

  A template names, for each kind of need, the non-production resource an environment made from it
  gets, the seed profile its applications' seeds are given, whether it is the installation's
  default, and optionally a quota and limits of its own within the installation's ceiling. Each is
  copied into an environment when it is made, so a change to a template moves no environment.

  Reading needs one of the platform capabilities, and every change `ehos.environment.manage`. EHOS
  decides and records each call, and its refusal is printed in its words. A template is named by
  its name, a resource by its name, and a template's resource by its kind of need.

  `--quota` is a `ResourceQuota`'s `hard` as `key=value` pairs, merged key by key over the
  installation's; `--limits` a file holding a `LimitRange`'s `limits` as JSON, or `-` for stdin.
  Either given empty, `''`, gives it back to the installation, as an empty `--seed-profile` clears
  the profile. A flag left out leaves its field as it is.
  """

  alias Ehosctl.Api
  alias Ehosctl.ManifestFile
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @look "`ehosctl env template show`"

  # A LimitRange's bounds from the least to the most, as the API server holds them in order.
  @bound_order ~w(min defaultRequest default max)

  @doc "The declaration of `ehosctl env template`, for `Ehosctl.Env`'s subcommands."
  @spec spec() :: keyword()
  def spec do
    template = [value_name: "TEMPLATE", required: true, help: "The template, by its name."]

    [
      name: "template",
      about:
        "List, create, change and remove the templates ephemeral environments are made from, " <>
          "as the console's Templates page does.",
      subcommands: [
        list: [
          name: "list",
          about: "List the templates, by name.",
          flags: Output.json_flag()
        ],
        show: [
          name: "show",
          about: "Show a template: its resources, seed profile, quota and limits.",
          args: [template: template],
          flags: Output.json_flag()
        ],
        create: [
          name: "create",
          about: "Create a template; bind its resources with `env template bind`.",
          args: [template: template],
          options: fields(),
          flags:
            [default: [long: "--default", help: "Make it the installation's default."]] ++
              Output.json_flag()
        ],
        update: [
          name: "update",
          about: "Change a template's seed profile, quota, limits, or whether it is the default.",
          args: [template: template],
          options: fields(),
          flags:
            [
              default: [long: "--default", help: "Make it the installation's default."],
              no_default: [
                long: "--no-default",
                help:
                  "Make it no longer the default: an environment created without --template is " <>
                    "then refused until another is."
              ]
            ] ++ Output.json_flag()
        ],
        remove: [
          name: "remove",
          about:
            "Remove a template; environments made from it keep what they were made with, and " <>
              "its name is free again.",
          args: [template: template],
          flags: Output.json_flag()
        ],
        bind: [
          name: "bind",
          about:
            "Name a resource serving non-production as the template's for its kind of need, in " <>
              "place of the one named before.",
          args: [
            template: template,
            resource: [value_name: "RESOURCE", required: true, help: "The resource, by its name."]
          ],
          flags: Output.json_flag()
        ],
        unbind: [
          name: "unbind",
          about: "Name no resource for a kind of need in the template.",
          args: [
            template: template,
            kind: [
              value_name: "KIND",
              required: true,
              help: "The kind of need, such as postgres, as `show` lists it."
            ]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  defp fields,
    do: [
      seed_profile: [
        long: "--seed-profile",
        value_name: "PROFILE",
        help:
          "Handed to each application's seed as EHOS_SEED_PROFILE: lowercase letters, digits " <>
            "and underscores; '' for none."
      ],
      quota: [
        long: "--quota",
        value_name: "KEY=VALUE,...",
        help:
          "A quota of its own, such as pods=10,limits.memory=4Gi, over the installation's " <>
            "key by key; '' for the installation's."
      ],
      limits: [
        long: "--limits",
        value_name: "FILE",
        help:
          "A LimitRange's limits, a JSON list, from a file or - for stdin; '' for the " <>
            "installation's."
      ]
    ]

  @doc """
  Runs `ehosctl env template <action>`, as `c:Ehosctl.Command.call/3` runs a command.
  """
  @spec call(atom(), Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call(action, parsed, opts) do
    # A name that would leave its place in the path (`.`, `..`), or names nothing, is refused
    # before anything is sent: a proxy that resolves dot segments would send it elsewhere.
    case Enum.find(Map.values(parsed.args), &Api.is_nameless(&1)) do
      nil ->
        run(action, parsed, opts)

      word ->
        {:error, :invalid, "#{Refusal.shown(word)} names no template, resource or kind of need."}
    end
  end

  defp run(:list, _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"templates" => templates}} when is_list(templates) <-
           Api.read(installation, "/api/v1/environment-templates", opts),
         true <- Enum.all?(templates, &template?/1) || Api.unexpected(installation) do
      templates = Enum.map(templates, &only_template/1)
      {:ok, %{text: table(templates), json: %{templates: templates}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  defp run(:show, parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, %{"template" => template}} <- Api.read(installation, path(parsed), opts),
         true <- template?(template) || Api.unexpected(installation) do
      template = only_template(template)
      {:ok, %{text: shown(template), json: %{template: template}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  defp run(:create, parsed, opts) do
    name = parsed.args.template

    with {:ok, body} <- body(%{name: name}, parsed, opts) do
      body = if parsed.flags.default, do: Map.put(body, :default, true), else: body

      write(opts, :post, "/api/v1/environment-templates", body, 201, name, fn template ->
        "Created #{Refusal.shown(template["name"])}#{default_said(template)}. Name its " <>
          "resources with `ehosctl env template bind`."
      end)
    end
  end

  defp run(:update, parsed, opts) do
    with {:ok, body} <- body(%{}, parsed, opts),
         {:ok, body} <- default(body, parsed.flags) do
      if body == %{} do
        {:error, :invalid,
         "Say what to change: --seed-profile, --quota, --limits, --default or --no-default."}
      else
        write(opts, :patch, path(parsed), body, 200, parsed.args.template, fn template ->
          "Changed #{Refusal.shown(template["name"])}#{default_said(template)}."
        end)
      end
    end
  end

  defp run(:remove, parsed, opts) do
    removed = {&same_name?(&1, parsed.args.template), &Map.take(&1, ["name"])}

    write(opts, :delete, path(parsed), nil, 200, "template", removed, fn template ->
      "Removed #{Refusal.shown(template["name"])}: environments made from it keep what they " <>
        "were made with."
    end)
  end

  defp run(:bind, parsed, opts) do
    body = %{resource: parsed.args.resource}
    bound = {&binding?/1, &only_binding/1}

    write(opts, :post, path(parsed) <> "/bindings", body, 201, "binding", bound, fn binding ->
      "#{Refusal.shown(parsed.args.template)} now gives #{Refusal.shown(binding["resource"])} " <>
        "for #{Refusal.shown(binding["kind"])}."
    end)
  end

  defp run(:unbind, parsed, opts) do
    %{template: template, kind: kind} = parsed.args
    path = path(parsed) <> "/bindings/" <> Api.segment(kind)
    unbound = {&same_kind?(&1, kind), &Map.take(&1, ["kind"])}

    write(opts, :delete, path, nil, 200, "binding", unbound, fn _ ->
      "#{Refusal.shown(template)} now names no resource for #{Refusal.shown(kind)}."
    end)
  end

  defp path(parsed),
    do: "/api/v1/environment-templates/" <> Api.segment(parsed.args.template)

  # The fields a creation and a change share, each sent only when given: '' sends null for a
  # quota and limits, which gives them back to the installation, and an empty profile, which
  # EHOS stores as none.
  defp body(body, parsed, opts) do
    %{seed_profile: profile, quota: quota, limits: limits} = parsed.options
    body = if is_nil(profile), do: body, else: Map.put(body, :seed_profile, profile)

    with {:ok, body} <- quota(body, quota) do
      limits(body, limits, opts)
    end
  end

  defp quota(body, nil), do: {:ok, body}
  defp quota(body, ""), do: {:ok, Map.put(body, :quota, nil)}

  defp quota(body, given) do
    pairs = String.split(given, ",")

    parsed =
      Enum.reduce_while(pairs, %{}, fn pair, quota ->
        # `pods = 10, limits.memory=4Gi` as written by hand: a space kept would send a key no
        # ceiling names, refused for a difference the person cannot see.
        case pair |> String.split("=", parts: 2) |> Enum.map(&String.trim/1) do
          [key, value] when key != "" and value != "" ->
            if Map.has_key?(quota, key),
              do: {:halt, {:error, "names #{Refusal.shown(key)} twice"}},
              else: {:cont, Map.put(quota, key, value)}

          _not_a_pair ->
            {:halt, {:error, "has #{Refusal.shown(pair)}, which is not KEY=VALUE"}}
        end
      end)

    case parsed do
      {:error, why} ->
        {:error, :invalid,
         "--quota #{why}: give pairs such as pods=10,limits.memory=4Gi, or '' for the " <>
           "installation's."}

      quota ->
        {:ok, Map.put(body, :quota, quota)}
    end
  end

  defp limits(body, nil, _opts), do: {:ok, body}
  defp limits(body, "", _opts), do: {:ok, Map.put(body, :limits, nil)}

  defp limits(body, file, opts) do
    with {:ok, bytes} <- ManifestFile.read(file, Keyword.put(opts, :what, "limits file")) do
      case JSON.decode(bytes) do
        {:ok, limits} when is_list(limits) ->
          {:ok, Map.put(body, :limits, limits)}

        _not_a_list ->
          {:error, :invalid,
           "--limits #{Refusal.shown(file)} holds no JSON list: a LimitRange's limits, such as " <>
             ~s([{"type": "Container", "default": {"memory": "512Mi"}}].)}
      end
    end
  end

  defp default(_body, %{default: true, no_default: true}),
    do: {:error, :invalid, "--default and --no-default say opposite things: give one."}

  defp default(body, %{default: true}), do: {:ok, Map.put(body, :default, true)}
  defp default(body, %{no_default: true}), do: {:ok, Map.put(body, :default, false)}
  defp default(body, _flags), do: {:ok, body}

  defp default_said(%{"default" => true}), do: ", the installation's default"
  defp default_said(_template), do: ""

  # A template EHOS says it made or changed is the one asked for, or something else was done.
  defp write(opts, method, path, body, status, name, said) do
    asked = {&(template?(&1) and same_name?(&1, name)), &only_template/1}
    write(opts, method, path, body, status, "template", asked, said)
  end

  # `{valid?, only}`: whether the answer is what was asked for, and the fields of it printed.
  defp write(opts, method, path, body, status, key, {valid?, only}, said),
    do:
      Api.write(
        opts,
        {method, path, body},
        [status: status, key: key, valid?: valid?, only: only, look: @look],
        said
      )

  defp same_name?(%{"name" => name}, asked), do: name == asked
  defp same_name?(_answer, _asked), do: false

  defp same_kind?(%{"kind" => kind}, asked), do: kind == asked
  defp same_kind?(_answer, _asked), do: false

  defp template?(%{"name" => name, "default" => default, "bindings" => bindings} = template),
    do:
      is_binary(name) and is_boolean(default) and nil_or_text?(template["seed_profile"]) and
        is_list(bindings) and Enum.all?(bindings, &binding?/1) and quota?(template["quota"]) and
        limits?(template["limits"])

  defp template?(_template), do: false

  defp only_template(template) do
    template
    |> Map.take(~w(name seed_profile default quota limits))
    |> Map.put("bindings", Enum.map(template["bindings"], &only_binding/1))
  end

  defp binding?(%{"kind" => kind, "resource" => resource}),
    do: is_binary(kind) and is_binary(resource)

  defp binding?(_binding), do: false

  defp only_binding(binding), do: Map.take(binding, ~w(kind resource))

  @doc """
  Whether `quota` is a `ResourceQuota`'s `hard` as EHOS answers it, a map of quantities as
  strings, or null for the installation's.
  """
  @spec quota?(term()) :: boolean()
  def quota?(nil), do: true

  def quota?(quota) when is_map(quota),
    do: Enum.all?(quota, fn {key, value} -> is_binary(key) and is_binary(value) end)

  def quota?(_quota), do: false

  @doc """
  Whether `limits` is a `LimitRange`'s `limits` as EHOS answers them, a list of objects, or null
  for the installation's.
  """
  @spec limits?(term()) :: boolean()
  def limits?(nil), do: true
  def limits?(limits) when is_list(limits), do: Enum.all?(limits, &is_map/1)
  def limits?(_limits), do: false

  @doc """
  A quota in words, `pods 10, limits.memory 4Gi`, by key, or `the installation's` for null.
  """
  @spec quota_said(map() | nil) :: String.t()
  def quota_said(quota) when quota in [nil, %{}], do: "the installation's"

  def quota_said(quota) do
    quota
    |> Enum.sort()
    |> Enum.map_join(", ", fn {key, value} -> "#{Refusal.shown(key)} #{Refusal.shown(value)}" end)
  end

  @doc """
  Limits in words, one line per item, `Container: default memory 512Mi; max memory 1Gi`, or
  `the installation's` for null.
  """
  @spec limits_said([map()] | nil) :: String.t()
  def limits_said(limits) when limits in [nil, []], do: "the installation's"

  def limits_said(limits) do
    Enum.map_join(limits, "\n", fn item ->
      bounds =
        item
        |> Map.delete("type")
        |> Enum.sort_by(fn {kind, _} -> Enum.find_index(@bound_order, &(&1 == kind)) || 99 end)
        |> Enum.map_join("; ", fn {kind, resources} ->
          "#{Refusal.shown(kind)} #{resources_said(resources)}"
        end)

      "#{Refusal.shown(item["type"] || "Container")}: #{bounds}"
    end)
  end

  defp resources_said(resources) when is_map(resources),
    do:
      resources
      |> Enum.sort()
      |> Enum.map_join(" ", fn {name, value} ->
        "#{Refusal.shown(name)} #{Refusal.shown(value)}"
      end)

  defp resources_said(other), do: Refusal.shown(other)

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp table([]), do: "No templates."

  defp table(templates) do
    templates
    |> Enum.map(
      &%{
        "NAME" => Refusal.shown(&1["name"]) <> if(&1["default"], do: " (default)", else: ""),
        "SEED PROFILE" => optional(&1["seed_profile"]),
        "OF ITS OWN" => own(&1),
        "RESOURCES" => resources(&1["bindings"])
      }
    )
    |> Output.table(["NAME", "SEED PROFILE", "OF ITS OWN", "RESOURCES"])
  end

  # Which of a quota and limits the template has of its own, rather than the installation's: a
  # template with limits alone is not one with nothing of its own.
  defp own(template) do
    ~w(quota limits)
    |> Enum.reject(&(template[&1] in [nil, %{}, []]))
    |> Enum.join(", ")
  end

  defp resources(bindings),
    do:
      Enum.map_join(bindings, ", ", fn binding ->
        "#{Refusal.shown(binding["kind"])}: #{Refusal.shown(binding["resource"])}"
      end)

  defp optional(value) when is_binary(value), do: Refusal.shown(value)
  defp optional(_none), do: ""

  defp shown(template) do
    head =
      Refusal.shown(template["name"]) <>
        if(template["default"], do: ", the installation's default", else: "")

    resources =
      case template["bindings"] do
        [] ->
          "No resources: an environment made from it gets none until `env template bind` " <>
            "names one."

        bindings ->
          bindings
          |> Enum.map(
            &%{"KIND" => Refusal.shown(&1["kind"]), "RESOURCE" => Refusal.shown(&1["resource"])}
          )
          |> Output.table(["KIND", "RESOURCE"])
      end

    Enum.join(
      [
        head,
        "Seed profile: " <> (optional(template["seed_profile"]) |> none_said()),
        "Quota: " <> quota_said(template["quota"]),
        "Limits: " <> indented(limits_said(template["limits"])),
        "",
        resources
      ],
      "\n"
    )
  end

  defp none_said(""), do: "none"
  defp none_said(profile), do: profile

  # Each item after the first starts its own line, under the first's.
  defp indented(text), do: String.replace(text, "\n", "\n        ")
end

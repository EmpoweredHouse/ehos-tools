defmodule Ehosctl.Resources do
  @moduledoc """
  `ehosctl resources list | classify`: the database servers an installation's environments may
  bind, through EHOS's API (eh-os
  [`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md),
  D-57), as the console's Resources page shows and classifies them.

  Listing needs one of the platform capabilities; classifying `ehos.resource.manage`. A resource's
  class is set once. Registering a resource is not a command: it stays a platform operation.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  # A classification that may have been made although its answer was lost.
  @look " It may have been set: run `ehosctl resources list` to see."

  @impl Ehosctl.Command
  def name, do: :resources

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about: "List the resources environments may bind, and classify them.",
      subcommands: [
        list: [
          name: "list",
          about: "List the resources, by name.",
          flags: Output.json_flag()
        ],
        classify: [
          name: "classify",
          about: "Set whether a resource serves production or not. It is set once (D-57).",
          args: [
            resource: [value_name: "RESOURCE", required: true, help: "The resource, by its name."],
            serves: [value_name: "SERVES", required: true, help: "production or non_production."]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:list], _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    case Api.answer(installation, :get, "/api/v1/resources", nil, opts) do
      {:ok, %{status: 200, body: %{"resources" => resources}}} when is_list(resources) ->
        if Enum.all?(resources, &resource?/1) do
          resources = Enum.map(resources, &only_resource/1)
          {:ok, %{text: table(resources), json: %{resources: resources}}}
        else
          Api.unexpected(installation)
        end

      {:ok, answer} ->
        Api.refusal(answer, installation)

      {:error, kind, message, :sent} ->
        {:error, kind, message}

      error ->
        error
    end
  end

  def call([:classify], %{args: %{resource: name}}, _opts) when Api.is_nameless(name),
    do: {:error, :invalid, "#{Refusal.shown(name)} names no resource."}

  def call([:classify], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{resource: name, serves: serves} = parsed.args
    path = "/api/v1/resources/" <> Api.segment(name) <> "/classify"

    case Api.answer(installation, :post, path, %{serves: serves}, opts) do
      {:ok, %{status: 200, body: %{"resource" => resource}}} ->
        if resource?(resource) do
          resource = only_resource(resource)

          {:ok,
           %{
             text:
               "#{Refusal.shown(resource["name"])} now serves #{serves_text(resource["serves"])}.",
             json: %{resource: resource}
           }}
        else
          said_done(installation)
        end

      {:ok, %{status: 200}} ->
        said_done(installation)

      # A gateway's 5xx without EHOS's code may have come after the class was set.
      {:ok, %{status: status} = answer} when status >= 500 ->
        {:error, kind, message} = Api.refusal(answer, installation)

        if Api.coded?(answer.body),
          do: {:error, kind, message},
          else: {:error, kind, message <> @look}

      {:ok, answer} ->
        Api.refusal(answer, installation)

      # Setting a class twice is refused, so sending it again tells whether it was set.
      {:error, kind, message, :sent} ->
        {:error, kind, message <> @look}

      error ->
        error
    end
  end

  defp said_done(installation) do
    {:error, kind, message} = Api.unexpected(installation)
    {:error, kind, message <> " It said it was set: run `ehosctl resources list` to see."}
  end

  defp resource?(%{"name" => name, "kind" => kind} = resource),
    do:
      is_binary(name) and is_binary(kind) and nil_or_text?(resource["serves"]) and
        nil_or_text?(resource["provider"]) and
        (is_nil(resource["version"]) or is_integer(resource["version"]))

  defp resource?(_resource), do: false

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp only_resource(resource), do: Map.take(resource, ~w(name kind provider version serves))

  defp serves_text("production"), do: "production environments"
  defp serves_text("non_production"), do: "non-production environments"
  defp serves_text(nil), do: "(not set)"
  defp serves_text(other), do: Refusal.shown(other)

  defp table([]), do: "No resources are registered."

  defp table(resources) do
    resources
    |> Enum.map(fn resource ->
      %{
        "NAME" => Refusal.shown(resource["name"]),
        "KIND" => Refusal.shown(resource["kind"]),
        "PROVIDER" => text(resource["provider"]),
        "VERSION" => text(resource["version"]),
        "SERVES" => serves_text(resource["serves"])
      }
    end)
    |> Output.table(["NAME", "KIND", "PROVIDER", "VERSION", "SERVES"])
  end

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: Refusal.shown(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: ""
end

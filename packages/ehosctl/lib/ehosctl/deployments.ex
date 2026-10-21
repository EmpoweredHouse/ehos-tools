defmodule Ehosctl.Deployments do
  @moduledoc """
  An application's deployments in an environment, as the console's application page shows them,
  from `GET /api/v1/applications/:name/environments/:environment/deployments` (eh-os#413): the
  deployment in force with its state, the addresses the application is served at there, and the
  deployments and refusals before it, newest first. `ehosctl deploy` follows the deployment it
  made by its id there, and `ehosctl apps show` says each environment's state from it.

  Reading it needs `ehos.application.deploy` or `ehos.application.register` in the environment.
  An installation whose EHOS predates the route answers `{:lacking, message}`, so that a command
  can say what it cannot tell there rather than fail.
  """

  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.Refusal
  alias Ehosctl.Source

  @typedoc """
  What the route answers, kept to the fields read: `"application"`, `"environment"`,
  `"addresses"`, `"in_force"` (a deployment or `nil`) and `"before"`, deployments and refusals
  (`"kind" => "refused"`), newest first.
  """
  @type history :: %{String.t() => term()}

  @typedoc """
  A deployment: `"kind" => "deployment"`, `"id"`, `"state"` (`pending`, `activating`, `active`,
  `failed`, `superseded` or `withdrawn`), `"image"`, `"manifest_digest"`, `"source"`, where it
  came from or `nil` (`Ehosctl.Source`), `"failure"`, `"by"` and `"at"`.
  """
  @type deployment :: %{String.t() => term()}

  # The most entries of `before` asked for unless a caller asks for more: `deploy` follows the
  # newest deployment, and `apps show` reads the newest before the one in force.
  @limit 5

  @deployment ~w(kind id state image manifest_digest source failure by at)
  @refused ~w(kind id image digest by why at)

  @doc """
  The deployments of `application` in `environment`, the `limit` newest before the one in force
  (EHOS takes 1 to 50), or `{:lacking, message}` when the installation's EHOS has no such route, or the refusal or
  error of the read. An answer for another application or environment, or of another shape, is
  one `ehosctl` cannot read. A name that would leave its place in the path (`.`, `..`), or names
  nothing, is refused before anything is sent.
  """
  @spec history(
          {Config.name(), Config.installation()},
          String.t(),
          String.t(),
          keyword(),
          pos_integer()
        ) :: {:ok, history()} | {:lacking, String.t()} | Api.error()
  def history(installation, application, environment, opts, limit \\ @limit) do
    case Enum.find([application, environment], &(&1 in ["", ".", ".."])) do
      nil ->
        read(installation, application, environment, opts, limit)

      word ->
        {:error, :invalid, "#{Refusal.shown(word)} names no application or environment."}
    end
  end

  defp read(installation, application, environment, opts, limit) do
    path =
      "/api/v1/applications/#{segment(application)}/environments/#{segment(environment)}" <>
        "/deployments?" <> URI.encode_query(limit: limit)

    case Api.read_if_routed(installation, path, opts) do
      {:ok, body} ->
        if history?(body, application, environment),
          do: {:ok, kept(body)},
          else: Api.unexpected(installation)

      other ->
        other
    end
  end

  @doc """
  The newest deployment before the one in force, when it was decided after it and failed: a
  deployment that failed is never in force, so this is what the latest attempt came to. `nil`
  otherwise, and when either moment cannot be read.
  """
  @spec failed_after(history()) :: deployment() | nil
  def failed_after(history) do
    newest = Enum.find(history["before"], &match?(%{"kind" => "deployment"}, &1))
    in_force = history["in_force"]

    with %{"state" => "failed"} <- newest,
         true <- is_nil(in_force) or after?(newest, in_force) do
      newest
    else
      _other -> nil
    end
  end

  # In EHOS's order: by the moment each was decided, then by id for two decided in the same one.
  defp after?(later, earlier) do
    with true <- is_binary(later["at"]) and is_binary(earlier["at"]),
         {:ok, later_at, _offset} <- DateTime.from_iso8601(later["at"]),
         {:ok, earlier_at, _offset} <- DateTime.from_iso8601(earlier["at"]) do
      case DateTime.compare(later_at, earlier_at) do
        :gt -> true
        :eq -> later["id"] > earlier["id"]
        :lt -> false
      end
    else
      _other -> false
    end
  end

  @doc "The deployment `id` in `history`, in force or before it, or `nil`."
  @spec find(history(), String.t()) :: deployment() | nil
  def find(history, id),
    do:
      Enum.find(
        [history["in_force"] | history["before"]],
        &match?(%{"kind" => "deployment", "id" => ^id}, &1)
      )

  defp history?(%{"application" => app, "environment" => env} = body, app, env),
    do:
      texts?(body["addresses"]) and (is_nil(body["in_force"]) or deployment?(body["in_force"])) and
        is_list(body["before"]) and Enum.all?(body["before"], &entry?/1)

  defp history?(_body, _app, _env), do: false

  # A kind a later EHOS adds is left out rather than making the history unreadable.
  defp entry?(%{"kind" => "deployment"} = deployment), do: deployment?(deployment)
  defp entry?(%{"kind" => "refused", "id" => id}), do: is_binary(id)
  defp entry?(%{"kind" => kind}), do: is_binary(kind)
  defp entry?(_entry), do: false

  defp deployment?(%{"kind" => "deployment", "id" => id, "state" => state} = deployment),
    do:
      is_binary(id) and is_binary(state) and
        (is_nil(deployment["failure"]) or is_binary(deployment["failure"])) and
        Source.valid?(deployment["source"])

  defp deployment?(_deployment), do: false

  defp texts?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

  # Kept to the fields read, so nothing else an answer holds reaches a script under `--json`.
  defp kept(body) do
    %{
      "application" => body["application"],
      "environment" => body["environment"],
      "addresses" => body["addresses"],
      "in_force" => body["in_force"] && Map.take(body["in_force"], @deployment),
      "before" =>
        Enum.flat_map(body["before"], fn
          %{"kind" => "deployment"} = deployment -> [Map.take(deployment, @deployment)]
          %{"kind" => "refused"} = refused -> [Map.take(refused, @refused)]
          _other -> []
        end)
    }
  end

  defp segment(name), do: URI.encode(name, &URI.char_unreserved?/1)
end

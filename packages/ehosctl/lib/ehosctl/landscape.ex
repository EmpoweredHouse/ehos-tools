defmodule Ehosctl.Landscape do
  @moduledoc """
  `ehosctl landscape --env E`: the environment's landscape, its applications as one system, as
  EHOS's console draws it, from `GET /api/v1/environments/E/landscape` (eh-os D-123, eh-os#791):

    * the applications drawn, each from the graph documents its latest active deployment there
      carried;
    * each name a fact is published under, with the applications that publish it and those that
      subscribe to it, and, for one nobody drawn publishes, that it comes from outside what the
      reader may see there;
    * what the picture leaves out: the applications with no active deployment there, those whose
      deployment sent no graph documents, the versions of the format EHOS did not read, and the
      domains that publish and subscribe to nothing.

  It shows only the applications the reader may see there, as the console does: someone who holds
  `ehos.application.deploy` or `ehos.application.register` for none of them is refused, and the
  refusal is recorded by EHOS. `--json` prints EHOS's answer: the environment, the landscape
  document the console draws, and what is said beside it.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @beside ~w(no_active_deployment no_documents unread_versions quiet_domains)

  @impl Ehosctl.Command
  def name, do: :landscape

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Show an environment's applications as one system: who publishes each fact and who " <>
          "subscribes to it, as their deployments there declare it.",
      options: [
        env: [
          long: "--env",
          value_name: "ENVIRONMENT",
          required: true,
          help: "The environment whose landscape to show."
        ]
      ],
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    env = parsed.options.env
    path = "/api/v1/environments/#{URI.encode(env, &URI.char_unreserved?/1)}/landscape"

    with {:ok, body} <- Api.read(installation, path, opts),
         true <- answer?(body) || Api.unexpected(installation) do
      answer = Map.take(body, ~w(environment landscape beside))
      {:ok, %{text: shown(answer), json: answer}}
    end
  end

  # What eh-os#791's route answers; anything else is refused whole rather than printed in part. A
  # key EHOS adds later is left out.
  defp answer?(%{"environment" => env, "landscape" => landscape, "beside" => beside})
       when is_binary(env),
       do: landscape?(landscape) and beside?(beside)

  defp answer?(_body), do: false

  defp landscape?(%{"nodes" => nodes, "relations" => relations})
       when is_map(nodes) and is_map(relations) do
    lists?(nodes, ~w(domain contract publication)) and
      lists?(relations, ~w(publishes subscribed_by))
  end

  defp landscape?(_landscape), do: false

  defp lists?(map, keys),
    do: Enum.all?(keys, fn key -> is_list(map[key]) and Enum.all?(map[key], &is_map/1) end)

  defp beside?(beside) when is_map(beside) do
    Enum.all?(@beside, &is_list(beside[&1])) and
      Enum.all?(beside["no_active_deployment"] ++ beside["no_documents"], &is_binary/1) and
      Enum.all?(beside["unread_versions"], &unread?/1) and
      Enum.all?(beside["quiet_domains"], &quiet?/1)
  end

  defp beside?(_beside), do: false

  defp unread?(%{"application" => application, "versions" => versions})
       when is_binary(application) and is_list(versions),
       do: Enum.all?(versions, &is_integer/1)

  defp unread?(_unread), do: false

  defp quiet?(%{"application" => application, "domain" => domain}),
    do: is_binary(application) and is_binary(domain)

  defp quiet?(_quiet), do: false

  defp shown(%{"environment" => env, "landscape" => landscape, "beside" => beside}) do
    applications = applications(landscape)

    picture =
      case drawn(landscape, applications) do
        [] ->
          "Nothing is drawn in #{Refusal.shown(env)}: no application you may see has an active " <>
            "deployment there that declares a fact it publishes or subscribes to."

        drawn ->
          "The landscape of #{Refusal.shown(env)}\n\nDrawn: #{names(drawn)}\n\n" <>
            wire(landscape, applications)
      end

    Enum.join([picture | said(beside)], "\n\n")
  end

  # Each contract's application, by the box it is drawn in.
  defp applications(%{"nodes" => %{"domain" => domains, "contract" => contracts}}) do
    boxes = Map.new(domains, &{&1["id"], &1["application"]})
    Map.new(contracts, &{&1["id"], boxes[&1["in"]]})
  end

  defp drawn(%{"nodes" => %{"domain" => domains}}, applications) do
    boxed = applications |> Map.values() |> MapSet.new()
    domains |> Enum.map(& &1["application"]) |> Enum.filter(&(&1 in boxed)) |> Enum.uniq()
  end

  # Each name on the wire, with whom publishes it and whom subscribes to it, by application.
  defp wire(%{"nodes" => %{"publication" => publications}, "relations" => relations}, apps) do
    publishers = by_publication(relations["publishes"], "to", "from", apps)
    subscribers = by_publication(relations["subscribed_by"], "from", "to", apps)

    lines =
      for publication <- Enum.sort_by(publications, &to_string(&1["name"])) do
        id = publication["id"]
        name = Refusal.shown(to_string(publication["name"]))

        publishing =
          case Map.get(publishers, id, []) do
            [] -> "    published by no application you may see here"
            those -> "    published by #{names(those)}"
          end

        subscribing =
          case Map.get(subscribers, id, []) do
            [] -> []
            those -> ["    subscribed to by #{names(those)}"]
          end

        Enum.join(["  #{name}", publishing | subscribing], "\n")
      end

    Enum.join(["On the wire:" | lines], "\n")
  end

  defp by_publication(relations, publication, contract, applications) do
    relations
    |> Enum.group_by(& &1[publication], &applications[&1[contract]])
    |> Map.new(fn {id, apps} -> {id, apps |> Enum.reject(&is_nil/1) |> Enum.uniq()} end)
  end

  defp said(beside) do
    [
      list(beside["no_active_deployment"], "No active deployment here, so not drawn"),
      list(
        beside["no_documents"],
        "Their active deployment sent no graph documents, so not drawn"
      ),
      unread(beside["unread_versions"]),
      quiet(beside["quiet_domains"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp list([], _said), do: nil
  defp list(applications, said), do: "#{said}: #{names(applications)}"

  defp unread([]), do: nil

  defp unread(unread) do
    lines =
      for %{"application" => application, "versions" => versions} <- unread do
        "  #{Refusal.shown(application)}: version #{Enum.join(versions, ", ")}"
      end

    Enum.join(
      [
        "Sent graph documents of a version this EHOS does not read, drawn once its pipeline " <>
          "deploys again to an EHOS that reads it:"
        | lines
      ],
      "\n"
    )
  end

  defp quiet([]), do: nil

  defp quiet(quiet) do
    domains =
      Enum.map_join(quiet, ", ", fn %{"application" => application, "domain" => domain} ->
        "#{Refusal.shown(application)} · #{Refusal.shown(domain)}"
      end)

    "Publishing and subscribing to nothing, so without a box: #{domains}"
  end

  defp names(names), do: Enum.map_join(names, ", ", &Refusal.shown(to_string(&1)))
end

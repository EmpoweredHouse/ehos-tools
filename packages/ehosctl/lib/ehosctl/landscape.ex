defmodule Ehosctl.Landscape do
  @moduledoc """
  `ehosctl landscape --env E`: the environment's landscape, its applications as one system, as
  EHOS's console draws it, from `GET /api/v1/environments/E/landscape` (eh-os D-123, eh-os#791):

    * the applications drawn, each from the graph documents its latest active deployment there
      carried, whether or not it publishes or subscribes to anything (eh-os#900);
    * each name a fact is published under, with the applications that publish it and those that
      subscribe to it, and, for one nobody drawn publishes, that it comes from outside what the
      reader may see there;
    * what the picture leaves out: the applications with no active deployment there, those whose
      deployment sent no graph documents, the versions of the format EHOS did not read, and, from
      an EHOS from before eh-os#900, which drew no box for them, the domains that publish and
      subscribe to nothing.

  It shows only the applications the reader may see there, as the console does: someone who holds
  `ehos.application.deploy` or `ehos.application.register` for none of them is refused, and the
  refusal is recorded by EHOS. `--json` prints EHOS's answer: the environment, the landscape
  document the console draws, and what is said beside it.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @beside ~w(no_active_deployment no_documents unread_versions)

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
      lists?(relations, ~w(publishes subscribed_by)) and printed?(nodes, relations)
  end

  defp landscape?(_landscape), do: false

  defp lists?(map, keys),
    do: Enum.all?(keys, fn key -> is_list(map[key]) and Enum.all?(map[key], &is_map/1) end)

  # The fields the picture is printed from, each text, or nothing where the join may leave one out.
  defp printed?(nodes, relations) do
    Enum.all?(nodes["domain"], &(is_binary(&1["id"]) and is_binary(&1["application"]))) and
      Enum.all?(nodes["contract"], &(is_binary(&1["id"]) and text_or_nil?(&1["in"]))) and
      Enum.all?(nodes["publication"], &(is_binary(&1["id"]) and text_or_nil?(&1["name"]))) and
      Enum.all?(
        relations["publishes"] ++ relations["subscribed_by"],
        &(text_or_nil?(&1["from"]) and text_or_nil?(&1["to"]))
      )
  end

  defp text_or_nil?(value), do: is_nil(value) or is_binary(value)

  defp beside?(beside) when is_map(beside) do
    # eh-os#900: an EHOS that draws every domain may leave `quiet_domains` out.
    Enum.all?(@beside, &is_list(beside[&1])) and is_list(Map.get(beside, "quiet_domains", [])) and
      Enum.all?(beside["no_active_deployment"] ++ beside["no_documents"], &is_binary/1) and
      Enum.all?(beside["unread_versions"], &unread?/1) and
      Enum.all?(Map.get(beside, "quiet_domains", []), &quiet?/1)
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
      case drawn(landscape, Map.get(beside, "quiet_domains", [])) do
        [] ->
          "Nothing is drawn in #{Refusal.shown(env)}: no application you may see has an active " <>
            "deployment there that sent its domain's graph document."

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

  # Every domain has a box (eh-os#900), but one an EHOS from before it names as quiet.
  defp drawn(%{"nodes" => %{"domain" => domains}}, quiet) do
    unboxed = MapSet.new(quiet, &{&1["application"], &1["domain"]})

    domains
    |> Enum.reject(&MapSet.member?(unboxed, {&1["application"], &1["name"]}))
    |> Enum.map(& &1["application"])
    |> Enum.uniq()
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
      quiet(Map.get(beside, "quiet_domains", []))
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
        "Sent graph documents of a version this EHOS does not read; what they say is drawn once " <>
          "its pipeline deploys again to an EHOS that reads it:"
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

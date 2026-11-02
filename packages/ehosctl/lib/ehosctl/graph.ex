defmodule Ehosctl.Graph do
  @moduledoc """
  `ehosctl graph <application> <deployment>`: the graph documents a deployment carried, its
  domains', contracts' and process modules', as EHOS's console draws them when a reader goes down
  from an application's box in the landscape (eh-os D-134, eh-os#890):

    * with no option, the list `GET /api/v1/applications/A/deployments/D/graph` gives: which
      deployment, its environment and state, whether a later one is active there, and each
      document's kind, name, domain and module;
    * with `--domain MODULE`, `--contract ID` or `--process ID`, the one `graph.v1` document
      `GET …/graph/:kind/:ref` gives, as JSON.

  `ehosctl landscape` names the deployment each box is drawn from. EHOS answers the same
  not-found for a deployment that is not there, one the reader may not see, and a document the
  deployment did not carry, so asking tells nothing.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @kinds ~w(domain contract process)

  # What each option names, in a refusal.
  @named %{domain: "domain", contract: "contract", process: "process module"}

  @impl Ehosctl.Command
  def name, do: :graph

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "List the graph documents that a deployment carried, of its domains, contracts and " <>
          "process modules, or print one of them as JSON.",
      args: [
        application: [
          value_name: "APPLICATION",
          required: true,
          help: "The name of the application."
        ],
        deployment: [
          value_name: "DEPLOYMENT",
          required: true,
          help:
            "The id of the deployment, as `ehosctl landscape` or `ehosctl apps history --json` " <>
              "shows it."
        ]
      ],
      options: [
        domain: [
          long: "--domain",
          value_name: "MODULE",
          help: "Print the graph document of the domain with this module."
        ],
        contract: [
          long: "--contract",
          value_name: "ID",
          help: "Print the graph document of the contract with this id."
        ],
        process: [
          long: "--process",
          value_name: "ID",
          help: "Print the graph document of the process module with this id."
        ]
      ],
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{application: app, deployment: id} = parsed.args
    path = "/api/v1/applications/#{Api.segment(app)}/deployments/#{Api.segment(id)}/graph"
    asked = Enum.filter([:domain, :contract, :process], &parsed.options[&1])

    # A name that would leave its place in the path (`.`, `..`), or names nothing, is refused
    # before anything is sent: a proxy that resolves dot segments would send it elsewhere.
    named =
      [{app, "application"}, {id, "deployment"}] ++
        Enum.map(asked, &{parsed.options[&1], @named[&1]})

    cond do
      nameless = Enum.find(named, fn {word, _what} -> Api.is_nameless(word) end) ->
        {word, what} = nameless
        {:error, :invalid, "ehosctl does not accept #{inspect(word)} as the name of the #{what}."}

      length(asked) > 1 ->
        {:error, :invalid, "Give only one of --domain, --contract and --process."}

      asked == [] ->
        list(installation, path, opts)

      true ->
        [kind] = asked
        document(installation, path, Atom.to_string(kind), parsed.options[kind], opts)
    end
  end

  defp list(installation, path, opts) do
    with {:ok, body} <- Api.read(installation, path, opts),
         true <- index?(body) || Api.unexpected(installation) do
      answer =
        Map.take(body, ~w(application environment deployment state later_active documents))

      {:ok, %{text: shown(answer), json: answer}}
    end
  end

  # The document as EHOS kept it: JSON for a person too, since it is what a program reads.
  defp document(installation, path, kind, ref, opts) do
    with {:ok, document} <- Api.read(installation, "#{path}/#{kind}/#{Api.segment(ref)}", opts),
         true <- asked?(document, kind, ref) || Api.unexpected(installation) do
      {:ok, %{text: Output.pretty_json(document), json: document}}
    end
  end

  # A `graph.v1` document names itself under its kind: a domain by its module, a contract or a
  # process module by its id.
  defp asked?(document, kind, ref), do: document["kind"] == kind and document[kind] == ref

  # What eh-os#890's route answers; anything else is refused whole rather than printed in part. A
  # key EHOS adds later is left out.
  defp index?(%{"documents" => documents} = body) when is_list(documents) do
    Enum.all?(~w(application environment deployment state), &is_binary(body[&1])) and
      text_or_nil?(body["later_active"]) and Enum.all?(documents, &document?/1)
  end

  defp index?(_body), do: false

  defp document?(%{"kind" => kind, "domain" => domain, "module" => module} = document)
       when kind in @kinds,
       do: is_binary(domain) and is_binary(module) and text_or_nil?(document["name"])

  defp document?(_document), do: false

  defp text_or_nil?(value), do: is_nil(value) or is_binary(value)

  defp shown(answer) do
    heading =
      "Deployment #{Refusal.shown(answer["deployment"])} of " <>
        "#{Refusal.shown(answer["application"])} in #{Refusal.shown(answer["environment"])}, " <>
        "#{Refusal.shown(answer["state"])}."

    later =
      answer["later_active"] &&
        "A later deployment is active there: #{Refusal.shown(answer["later_active"])}."

    [heading, later, documents(answer["documents"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp documents([]),
    do:
      "This deployment carried no graph documents. A deployment carries them when its build, " <>
        "its bundle or its --graph options hold them."

  defp documents(documents) do
    rows =
      Enum.map(documents, fn document ->
        %{
          "KIND" => document["kind"],
          "NAME" => if(document["name"], do: Refusal.shown(document["name"]), else: "-"),
          "DOMAIN" => Refusal.shown(document["domain"]),
          "MODULE" => Refusal.shown(document["module"])
        }
      end)

    Output.table(rows, ["KIND", "NAME", "DOMAIN", "MODULE"]) <>
      "\n\nPrint one with --domain and its MODULE, or --contract or --process and its NAME as the ID."
  end
end

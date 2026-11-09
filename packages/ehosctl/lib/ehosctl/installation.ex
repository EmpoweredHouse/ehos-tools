defmodule Ehosctl.Installation do
  @moduledoc """
  `ehosctl installation`: where the installation runs and what it uses, through EHOS's API (eh-os
  [`docs/installation-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/installation-api.md),
  D-90), as the console's Installation page shows it, from the same reading:

    * what the installer said the installation is, and the console's address;
    * which EHOS runs, the commit it was built from, and when it was installed, from an EHOS that
      says so (eh-os 0.14.0 on);
    * whether four eyes holds on its promotions, and since when (eh-os D-128, eh-os#749), from an
      EHOS that says;
    * each node, with its capacity and what it uses now;
    * each environment, with its quota, what its pods request against it, and what it and each of
      its applications use now.

  It needs one of the platform capabilities (D-82), and a refused read is recorded by EHOS. What
  EHOS could not read, it says, and the rest is printed: a cluster without metrics-server has no
  usage.

  `ehosctl installation domain` shows the DNS records of the installation's domain
  (`Ehosctl.InstallationDomain`).

  Not to be confused with `ehosctl installations`, the installations this machine knows.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.InstallationDomain
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @impl Ehosctl.Command
  def name, do: :installation

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def runs_bare?, do: true

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Show where the installation runs, and the resources that it and its applications use now.",
      flags: Output.json_flag(),
      subcommands: [domain: InstallationDomain.spec()]
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], _parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, body} <- Api.read(installation, "/api/v1/installation", opts),
         true <- reading?(body) || Api.unexpected(installation) do
      reading = only_reading(body)
      {:ok, %{text: shown(reading), json: reading}}
    end
  end

  def call([:domain], parsed, opts), do: InstallationDomain.call(parsed, opts)

  # What a reading is (eh-os `docs/installation-api.md`): anything else is an answer `ehosctl`
  # cannot read, refused whole rather than printed in part.
  @described ~w(name provider region size)
  @states ~w(available unavailable)
  @quota ~w(cpu_requests_millicores memory_requests_bytes memory_limits_bytes pods)

  # EHOS counts in what Kubernetes holds, a signed 64-bit integer, and never below nothing: an
  # amount outside that is an answer `ehosctl` cannot read, rather than one it cannot print.
  @max_amount Integer.pow(2, 63) - 1

  defp reading?(%{"installation" => description, "environments" => environments} = body)
       when is_map(description) and is_list(environments) do
    Enum.all?(@described, &text_or_nil?(description[&1])) and is_binary(description["console"]) and
      nodes?(body["nodes"]) and
      body["quotas"] in @states and body["usage"] in @states and
      Enum.all?(environments, &environment?/1) and nil_or?(body["ehos"], &ehos?/1) and
      nil_or?(body["four_eyes"], &four_eyes?/1)
  end

  defp reading?(_body), do: false

  defp nodes?(nil), do: true
  defp nodes?(nodes) when is_list(nodes), do: Enum.all?(nodes, &node?/1)
  defp nodes?(_nodes), do: false

  defp ehos?(%{"version" => version} = ehos) when is_binary(version),
    do: text_or_nil?(ehos["commit"]) and nil_or?(ehos["installed_at"], &instant?/1)

  defp ehos?(_ehos), do: false

  defp instant?(text) when is_binary(text),
    do: match?({:ok, _at, _offset}, DateTime.from_iso8601(text))

  defp instant?(_text), do: false
  # eh-os#749: absent from an EHOS before it.
  defp four_eyes?(%{"on" => on} = four_eyes) when is_boolean(on),
    do: nil_or?(four_eyes["since"], &is_binary/1)

  defp four_eyes?(_four_eyes), do: false

  defp node?(%{"name" => name} = node) when is_binary(name),
    do:
      measure?(node["capacity"]) and measure?(node["allocatable"]) and
        nil_or?(node["used"], &measure?/1)

  defp node?(_node), do: false

  defp environment?(%{"name" => name, "applications" => applications} = env)
       when is_binary(name) and is_list(applications),
       do:
         nil_or?(env["quota"], &quota?/1) and nil_or?(env["requested"], &quota?/1) and
           nil_or?(env["used"], &measure?/1) and Enum.all?(applications, &application?/1)

  defp environment?(_env), do: false

  defp application?(%{"name" => name, "pods" => pods} = application) when is_binary(name),
    do: amount?(pods) and measure?(application["used"])

  defp application?(_application), do: false

  defp measure?(%{"cpu_millicores" => cpu, "memory_bytes" => memory}),
    do: amount?(cpu) and amount?(memory)

  defp measure?(_measure), do: false

  # A quota names only the limits it sets. A limit this version does not know is left out, as
  # any other field EHOS may add later.
  defp quota?(quota) when is_map(quota),
    do: quota |> Map.take(@quota) |> Map.values() |> Enum.all?(&amount?/1)

  defp quota?(_quota), do: false

  defp amount?(amount), do: is_integer(amount) and amount >= 0 and amount <= @max_amount

  defp text_or_nil?(value), do: is_nil(value) or is_binary(value)
  defp nil_or?(value, valid?), do: is_nil(value) or valid?.(value)

  defp only_reading(body) do
    %{
      "installation" => Map.new(["console" | @described], &{&1, body["installation"][&1]}),
      # `null` from an EHOS before 0.14.0, which does not say.
      "ehos" => body["ehos"] && Map.new(~w(version commit installed_at), &{&1, body["ehos"][&1]}),
      "four_eyes" => only_four_eyes(body["four_eyes"]),
      "nodes" => body["nodes"] && Enum.map(body["nodes"], &only_node/1),
      "quotas" => body["quotas"],
      "usage" => body["usage"],
      "environments" => Enum.map(body["environments"], &only_environment/1)
    }
  end

  # Every key the contract names, `null` where EHOS left one out, so `--json` keeps one shape.
  defp only_node(node) do
    %{
      "name" => node["name"],
      "capacity" => only_measure(node["capacity"]),
      "allocatable" => only_measure(node["allocatable"]),
      "used" => only_measure(node["used"])
    }
  end

  defp only_environment(env) do
    %{
      "name" => env["name"],
      "quota" => only_quota(env["quota"]),
      "requested" => only_quota(env["requested"]),
      "used" => only_measure(env["used"]),
      "applications" =>
        Enum.map(env["applications"], fn application ->
          %{
            "name" => application["name"],
            "pods" => application["pods"],
            "used" => only_measure(application["used"])
          }
        end)
    }
  end

  defp only_four_eyes(nil), do: nil
  defp only_four_eyes(four_eyes), do: %{"on" => four_eyes["on"], "since" => four_eyes["since"]}

  defp only_quota(nil), do: nil
  defp only_quota(quota), do: Map.take(quota, @quota)

  defp only_measure(nil), do: nil
  defp only_measure(measure), do: Map.take(measure, ~w(cpu_millicores memory_bytes))

  defp shown(reading) do
    [
      described(reading["installation"]),
      ehos(reading["ehos"]),
      four_eyes(reading["four_eyes"]),
      unread(reading),
      nodes(reading["nodes"]),
      environments(reading["environments"], reading["quotas"]),
      applications(reading["environments"])
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp described(description) do
    name = said(description["name"], "This installation")

    where =
      case {description["provider"], description["region"]} do
        {nil, nil} -> ""
        {provider, nil} -> " on #{Refusal.shown(provider)}"
        {nil, region} -> " in #{Refusal.shown(region)}"
        {provider, region} -> " on #{Refusal.shown(provider)}, #{Refusal.shown(region)}"
      end

    size = if description["size"], do: "\nSize: #{Refusal.shown(description["size"])}", else: ""
    "#{name}#{where}, at #{Refusal.shown(description["console"])}#{size}"
  end

  defp ehos(nil), do: ""

  defp ehos(ehos) do
    commit = if ehos["commit"], do: ", commit #{Refusal.shown(ehos["commit"])}", else: ""

    installed =
      case ehos["installed_at"] do
        nil ->
          ", with no record of when it was installed"

        at ->
          {:ok, at, _offset} = DateTime.from_iso8601(at)
          ", installed #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}"
      end

    "EHOS #{Refusal.shown(ehos["version"])}#{commit}#{installed}"
  end

  # eh-os D-128: whether a promotion needs a second person, and since when a starting server found
  # it changed to that (eh-os#749).
  defp four_eyes(nil), do: ""

  defp four_eyes(%{"on" => on} = four_eyes) do
    since = if four_eyes["since"], do: ", since #{Refusal.shown(four_eyes["since"])}", else: ""

    if on,
      do: "Four eyes on promotions: on#{since}. The person who deployed or asked cannot approve.",
      else:
        "Four eyes on promotions: off#{since}. The person who deployed or asked can approve. " <>
          "EHOS records it as a self-approval."
  end

  defp said(nil, otherwise), do: otherwise
  defp said(value, _otherwise), do: Refusal.shown(value)

  defp unread(reading) do
    [
      is_nil(reading["nodes"]) && "EHOS could not list the nodes of the cluster.",
      reading["quotas"] == "unavailable" && "EHOS could not list the quotas of the environments.",
      reading["usage"] == "unavailable" &&
        "The metrics API of the cluster did not answer, so ehosctl does not show the use now. " <>
          "A cluster without metrics-server has no metrics API."
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp nodes(nil), do: ""
  defp nodes([]), do: "The cluster has no nodes."

  defp nodes(nodes) do
    nodes
    |> Enum.map(fn node ->
      %{
        "NODE" => Refusal.shown(node["name"]),
        "CPU USED" => used(node["used"], "cpu_millicores", node["allocatable"]),
        "MEMORY USED" => used(node["used"], "memory_bytes", node["allocatable"]),
        "CAPACITY" =>
          "#{cpu(node["capacity"]["cpu_millicores"])}, #{memory(node["capacity"]["memory_bytes"])}"
      }
    end)
    |> Output.table(["NODE", "CPU USED", "MEMORY USED", "CAPACITY"])
  end

  defp environments([], _quotas),
    do: "No environments. An environment shows here when a person creates one."

  defp environments(environments, quotas) do
    table =
      environments
      |> Enum.map(fn env ->
        %{
          "ENVIRONMENT" => Refusal.shown(env["name"]),
          "CPU USED" => measured(env["used"], "cpu_millicores"),
          "MEMORY USED" => measured(env["used"], "memory_bytes"),
          "CPU REQUESTED" => against(env, "cpu_requests_millicores", quotas),
          "MEMORY REQUESTED" => against(env, "memory_requests_bytes", quotas),
          "PODS" => against(env, "pods", quotas)
        }
      end)
      |> Output.table([
        "ENVIRONMENT",
        "CPU USED",
        "MEMORY USED",
        "CPU REQUESTED",
        "MEMORY REQUESTED",
        "PODS"
      ])

    table <>
      "\nThe quota limits what the pods of an environment request. A pod can use more than it " <>
      "requested, up to its limit."
  end

  defp applications(environments) do
    rows =
      for env <- environments, application <- env["applications"] do
        %{
          "APPLICATION" => Refusal.shown(application["name"]),
          "ENVIRONMENT" => Refusal.shown(env["name"]),
          "PODS" => Integer.to_string(application["pods"]),
          "CPU USED" => cpu(application["used"]["cpu_millicores"]),
          "MEMORY USED" => memory(application["used"]["memory_bytes"])
        }
      end

    case rows do
      [] ->
        "No pods of applications run, or EHOS does not know their use. An application shows " <>
          "here when its pods run."

      rows ->
        Output.table(rows, ["APPLICATION", "ENVIRONMENT", "PODS", "CPU USED", "MEMORY USED"])
    end
  end

  defp used(nil, _key, _of), do: "not known"
  defp used(used, key, of), do: "#{format(key, used[key])} of #{format(key, of[key])}"

  defp measured(nil, _key), do: "not known"
  defp measured(used, key), do: format(key, used[key])

  # Without the quotas listed, none is known; with them, an environment without one has no
  # namespace yet.
  defp against(%{"quota" => nil}, _key, "unavailable"), do: "not known"
  defp against(%{"quota" => nil}, _key, _quotas), do: "no quota yet"

  defp against(%{"quota" => quota, "requested" => requested}, key, _quotas) do
    case {(requested || %{})[key], quota[key]} do
      {_requested, nil} -> "no limit"
      {nil, limit} -> "? of #{format(key, limit)}"
      {asked, limit} -> "#{format(key, asked)} of #{format(key, limit)}"
    end
  end

  defp format(key, amount) when key in ~w(cpu_millicores cpu_requests_millicores),
    do: cpu(amount)

  defp format(key, amount) when key in ~w(memory_bytes memory_requests_bytes memory_limits_bytes),
    do: memory(amount)

  defp format("pods", amount), do: Integer.to_string(amount)

  @doc """
  CPU as the console prints it: whole CPUs from 1, as Kubernetes writes a quota, and millicores
  below, as it writes a request.

      iex> Ehosctl.Installation.cpu(2000)
      "2 CPU"

      iex> Ehosctl.Installation.cpu(1427)
      "1.43 CPU"

      iex> Ehosctl.Installation.cpu(299)
      "299m CPU"
  """
  @spec cpu(integer()) :: String.t()
  def cpu(millicores) when millicores >= 1000 and rem(millicores, 1000) == 0,
    do: "#{div(millicores, 1000)} CPU"

  def cpu(millicores) when millicores >= 1000,
    do: "#{:erlang.float_to_binary(millicores / 1000, decimals: 2)} CPU"

  def cpu(millicores), do: "#{millicores}m CPU"

  @doc """
  Memory as the console prints it, in binary units, as a quota is written.

      iex> Ehosctl.Installation.memory(4_294_967_296)
      "4 GiB"

      iex> Ehosctl.Installation.memory(293_703_680)
      "280.1 MiB"
  """
  @spec memory(integer()) :: String.t()
  def memory(bytes) when bytes >= 1024 * 1024 * 1024,
    do: "#{rounded(bytes / (1024 * 1024 * 1024))} GiB"

  def memory(bytes), do: "#{rounded(bytes / (1024 * 1024))} MiB"

  defp rounded(amount) do
    if amount == Float.round(amount),
      do: amount |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(amount, decimals: 1)
  end
end

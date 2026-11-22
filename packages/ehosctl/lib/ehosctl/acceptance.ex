defmodule Ehosctl.Acceptance do
  @moduledoc """
  Whether an installation accepts a component, by eh-os D-91's rule: a consumer and a producer
  work together when what the consumer accepts includes what the producer produces, and each
  one's `requires` holds. Only the installation answers for the installation: what it says at
  `GET /api/v1` (`Ehosctl.Api.describe/2`) is compared with a component's own `release.json`, or
  with this build of `ehosctl`, never with another release's claim.

    * **`ehosctl`** is accepted when its version meets the installation's `requires.ehosctl`
      (`Version.match?/3`, pre-releases allowed, so `0.3.0-dev` meets `>= 0.3.0-dev`) and it
      accepts the `ehos.api` version the installation produces.
    * **`ehos_app`** is accepted when every `ehos.yaml` version it produces, the one it writes
      into a new application, is among the installation's `accepts`.
    * **`eh_os_contract`** is accepted when the manifest the application writes is among the
      installation's `accepts` and among the versions the release produces. Which one an
      application writes depends on its `ehos.yaml` (eh_os_contract writes `ehos.manifest/v3`
      for an `ehos.yaml/v3` and `v2` for an older one), so it is read from the manifest
      `ehosctl verify` last wrote; without one, any manifest version the release produces that
      the installation accepts will do, since the application could be writing it.
    * **A document**, `ehos.yaml` or the manifest, is accepted when its schema is among the
      installation's `accepts`.
    * **`ehos_design`** has no interface with EHOS: acceptance does not apply.
    * **Every release, the other way** (`release/2`): what the installation produces must be
      among what the release accepts, for each interface it accepts that the installation
      produces at all, and what it `requires` of `ehos` must hold for the version the
      installation runs.

  Each rule answers `:yes`, `{:no, why}`, or `{:unknown, why}` when the installation or the
  component does not say enough to tell.
  """

  @typedoc "An answer, with the reason for anything but a yes."
  @type verdict :: :yes | {:no, String.t()} | {:unknown, String.t()} | :not_applicable

  @typedoc """
  What is known of the installation: what it says about itself, or why it is not known.
  """
  @type installation :: Ehosctl.Api.described() | {:unknown, String.t()}

  @doc """
  Whether the installation accepts an `ehosctl` of `version` that accepts `accepts`, `nil` when
  that release does not say.

      iex> described = %{"produces" => ["ehos.api/v1"], "requires" => %{"ehosctl" => ">= 0.3.0-dev"}}
      iex> Ehosctl.Acceptance.ehosctl(described, "0.3.0-dev", ["ehos.api/v1"])
      :yes
      iex> Ehosctl.Acceptance.ehosctl(described, "0.2.0", ["ehos.api/v1"])
      {:no, "this installation requires ehosctl >= 0.3.0-dev"}
      iex> Ehosctl.Acceptance.ehosctl(described, "0.3.0", ["ehos.api/v2"])
      {:no, "this version of ehosctl reads ehos.api/v2, and this installation's API is ehos.api/v1"}
  """
  @spec ehosctl(installation(), String.t(), [String.t()] | nil) :: verdict()
  def ehosctl({:unknown, why}, _version, _accepts), do: {:unknown, why}

  def ehosctl(_described, _version, nil),
    do: {:unknown, "its release has no release.json to say what it accepts"}

  def ehosctl(described, version, accepts) do
    api = Enum.filter(described["produces"], &String.starts_with?(&1, "ehos.api/"))

    if Enum.any?(api, &(&1 in accepts)) do
      required(described["requires"]["ehosctl"], version)
    else
      {:no,
       "this version of ehosctl reads " <>
         "#{named(Enum.filter(accepts, &String.starts_with?(&1, "ehos.api/")))}, and this " <>
         "installation's API is #{named(api)}"}
    end
  end

  defp required(nil, _version), do: :yes

  defp required(requirement, version) do
    with {:ok, parsed} <- Version.parse_requirement(requirement),
         {:ok, version} <- Version.parse(version) do
      if Version.match?(version, parsed, allow_pre: true),
        do: :yes,
        else: {:no, "this installation requires ehosctl #{requirement}"}
    else
      :error ->
        {:unknown, "this installation requires ehosctl #{requirement}, which ehosctl cannot read"}
    end
  end

  @doc """
  Whether the installation accepts the `ehos.yaml` an `ehos_app` that produces `produces` writes,
  `nil` when that release does not say.

      iex> Ehosctl.Acceptance.ehos_app(%{"accepts" => ["ehos.yaml/v1", "ehos.yaml/v2"]}, ["ehos.yaml/v3"])
      {:no, "it writes ehos.yaml/v3, and this installation accepts ehos.yaml/v1 and ehos.yaml/v2"}
  """
  @spec ehos_app(installation(), [String.t()] | nil) :: verdict()
  def ehos_app({:unknown, why}, _produces), do: {:unknown, why}

  def ehos_app(_described, nil),
    do: {:unknown, "its release has no release.json to say which ehos.yaml it writes"}

  def ehos_app(described, produces) do
    case Enum.filter(produces, &String.starts_with?(&1, "ehos.yaml/")) do
      [] ->
        {:unknown, "its release.json names no ehos.yaml it writes"}

      written ->
        if Enum.all?(written, &(&1 in described["accepts"])),
          do: :yes,
          else: {:no, "it writes #{named(written)}, and #{accepting(described, "ehos.yaml/")}"}
    end
  end

  @doc """
  Whether the installation accepts the manifest an `eh_os_contract` that produces `produces`
  writes for this application, which writes `written`, or `nil` when that is not known.

      iex> described = %{"accepts" => ["ehos.manifest/v2"]}
      iex> Ehosctl.Acceptance.eh_os_contract(described, ["ehos.manifest/v2", "ehos.manifest/v3"], nil)
      :yes
      iex> Ehosctl.Acceptance.eh_os_contract(described, ["ehos.manifest/v2", "ehos.manifest/v3"], "ehos.manifest/v3")
      {:no, "this application writes ehos.manifest/v3, and this installation accepts ehos.manifest/v2"}
  """
  @spec eh_os_contract(installation(), [String.t()] | nil, String.t() | nil) :: verdict()
  def eh_os_contract({:unknown, why}, _produces, _written), do: {:unknown, why}

  def eh_os_contract(_described, nil, _written),
    do: {:unknown, "its release has no release.json to say which manifests it writes"}

  def eh_os_contract(described, produces, written) do
    manifests = Enum.filter(produces, &String.starts_with?(&1, "ehos.manifest/"))
    accepted = Enum.filter(manifests, &(&1 in described["accepts"]))

    cond do
      manifests == [] ->
        {:unknown, "its release.json names no manifest it writes"}

      written != nil and written not in manifests ->
        {:no, "this application writes #{written}, which this release does not write"}

      written != nil and written not in accepted ->
        {:no, "this application writes #{written}, and #{accepting(described, "ehos.manifest/")}"}

      accepted == [] ->
        {:no, "it writes #{named(manifests)}, and #{accepting(described, "ehos.manifest/")}"}

      true ->
        :yes
    end
  end

  @doc """
  Whether the installation accepts a document whose schema is `schema`, `nil` when it is not
  known.

      iex> Ehosctl.Acceptance.document(%{"accepts" => ["ehos.yaml/v1"]}, "ehos.yaml/v1")
      :yes
  """
  @spec document(installation(), String.t() | nil) :: verdict()
  def document({:unknown, why}, _schema), do: {:unknown, why}
  def document(_described, nil), do: {:unknown, "it names no schema ehosctl reads"}

  def document(described, schema) do
    if schema in described["accepts"] do
      :yes
    else
      [name | _] = String.split(schema, "/")
      {:no, accepting(described, name <> "/")}
    end
  end

  @doc """
  A release judged the other way, where its `release.json` says enough: for each interface it
  accepts that the installation produces in some version, that version must be one it accepts
  (`eh_os_contract` accepts the `ehos.credential` EHOS issues), and what it `requires` of `ehos`
  must hold for the version the installation runs. `:yes` where nothing is said of either.

      iex> described = %{"version" => "0.5.0", "produces" => ["ehos.credential/v1"]}
      iex> Ehosctl.Acceptance.release(described, %{"accepts" => ["ehos.credential/v2"]})
      {:no, "it reads ehos.credential/v2, and this installation produces ehos.credential/v1"}
      iex> Ehosctl.Acceptance.release(described, %{"requires" => %{"ehos" => ">= 0.4.0"}})
      :yes
  """
  @spec release(installation(), map() | nil) :: verdict()
  def release({:unknown, why}, _json), do: {:unknown, why}
  def release(_described, nil), do: :yes

  def release(described, json) do
    accepts = if is_list(json["accepts"]), do: json["accepts"], else: []

    read =
      accepts
      |> Enum.filter(&is_binary/1)
      |> Enum.group_by(&interface/1)
      |> Enum.map(fn {name, versions} -> reads(described, name, versions) end)

    required =
      case json["requires"] do
        %{"ehos" => requirement} when is_binary(requirement) ->
          ehos(requirement, described["version"])

        _none ->
          :yes
      end

    combine([required | read])
  end

  defp reads(described, name, versions) do
    case Enum.filter(described["produces"], &(interface(&1) == name)) do
      [] ->
        :yes

      produced ->
        if Enum.any?(produced, &(&1 in versions)),
          do: :yes,
          else:
            {:no,
             "it reads #{named(versions)}, and this installation produces #{named(produced)}"}
    end
  end

  defp interface(name), do: name |> String.split("/") |> hd()

  defp ehos(requirement, version) do
    with {:ok, parsed} <- Version.parse_requirement(requirement),
         {:ok, running} <- Version.parse(version || "") do
      if Version.match?(running, parsed, allow_pre: true),
        do: :yes,
        else:
          {:no,
           "it requires ehos #{Ehosctl.Refusal.shown(requirement)}, and this installation runs " <>
             version}
    else
      :error ->
        {:unknown,
         "it requires ehos #{Ehosctl.Refusal.shown(requirement)}, which ehosctl cannot judge"}
    end
  end

  @doc """
  Verdicts taken together: any no is a no, else any unknown is unknown, else yes; a verdict that
  does not apply is left out.

      iex> Ehosctl.Acceptance.combine([:yes, {:unknown, "a"}, {:no, "b"}])
      {:no, "b"}
  """
  @spec combine([verdict()]) :: verdict()
  def combine(verdicts) do
    Enum.find(verdicts, &match?({:no, _}, &1)) || Enum.find(verdicts, &match?({:unknown, _}, &1)) ||
      if(Enum.all?(verdicts, &(&1 == :not_applicable)) and verdicts != [],
        do: :not_applicable,
        else: :yes
      )
  end

  defp accepting(described, prefix) do
    case Enum.filter(described["accepts"], &String.starts_with?(&1, prefix)) do
      [] -> "this installation accepts no #{String.trim_trailing(prefix, "/")}"
      accepted -> "this installation accepts #{named(accepted)}"
    end
  end

  defp named([]), do: "none named"
  defp named([one]), do: Ehosctl.Refusal.shown(one)

  defp named(several) do
    {init, [last]} = Enum.split(Enum.map(several, &Ehosctl.Refusal.shown/1), -1)
    Enum.join(init, ", ") <> " and " <> last
  end
end

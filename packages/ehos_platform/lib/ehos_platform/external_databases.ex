defmodule EhosPlatform.ExternalDatabases do
  @moduledoc """
  The PostgreSQL databases outside an installation that EHOS's chart lists under
  `dataResources.external` (eh-os D-170), as the installer reads them back from a release, checks
  a new one, and names the Secret of each one's managing role (T-29).

  An entry is a map of the chart's fields alone: `name`, `version`, `host`, `port` (5432 when
  left out), `database`, `ca`, `addressRanges`, `managingRoleSecret` and, when given,
  `administratorRole`. The managing role's name and password are in a `kubernetes.io/basic-auth`
  Secret in `ehos-data`, `ehos-external-<name>`, which the installer makes, labels and annotates
  with the database's name, so that it never takes over a Secret it did not make.

  Everything here is pure: `EhosPlatform.Install` reads the release and writes the Secret.
  """

  @typedoc """
  A database outside the installation, as the chart's `dataResources.external` lists it: string
  keys, `version` and `port` integers, `addressRanges` a list of IPv4 ranges.
  """
  @type entry :: %{String.t() => String.t() | pos_integer() | [String.t()]}

  @typedoc "A field of `t:entry/0` that `check/1` refuses, by the chart's key."
  @type field :: String.t()

  @secret_prefix "ehos-external-"
  @namespace "ehos-data"
  @manager_label "app.kubernetes.io/managed-by"
  @manager "ehosctl"
  @resource_annotation "ehos.empowered.house/external-database"

  # The chart's fields of an entry, each with whether it must be there and its type.
  @fields [
    {"name", :required, :string},
    {"version", :required, :integer},
    {"host", :required, :string},
    {"port", :optional, :integer},
    {"database", :required, :string},
    {"ca", :required, :string},
    {"addressRanges", :required, :strings},
    {"managingRoleSecret", :required, :string},
    {"administratorRole", :optional, :string}
  ]
  @keys for {key, _need, _type} <- @fields, do: key

  # The chart's own forms (eh-os `_helpers.tpl`, `ehos.dataExternal`).
  @name ~r/\A[a-z]([-a-z0-9]{0,48}[a-z0-9])?\z/
  # One trailing dot is kept: Cloud SQL's certificate names the instance with it, and TLS matches
  # the name only in that form (eh-os#1774).
  @host ~r/\A([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z]([-a-z0-9]{0,61}[a-z0-9])?\.?\z/
  @database ~r/\A[a-z_][a-z0-9_]{0,62}\z/
  @role ~r/\A[A-Za-z0-9_][A-Za-z0-9_.@+-]{0,62}\z/
  @range ~r/\A(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}\/(3[0-2]|[12]?[0-9])\z/

  @doc """
  The Secret that holds the managing role of the database `name`, in `ehos-data`.

      iex> EhosPlatform.ExternalDatabases.secret_name("ledger")
      "ehos-external-ledger"
  """
  @spec secret_name(String.t()) :: String.t()
  def secret_name(name), do: @secret_prefix <> name

  @doc "The namespace of the managing roles' Secrets, `ehos-data`."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  The entries of a release's `dataResources.external` that the next install writes again, and a
  warning, a head and its explanation, for each one it leaves out, or for the keys of one it
  drops. An entry keeps the chart's
  fields alone; a `port` or `version` given as digits, which the chart takes, becomes the
  integer. One that is not a map, has no name in the chart's form, lacks a field the chart needs,
  or holds a field of another type is left out. So is one whose `managingRoleSecret` is not
  `secret_name/1` of its name: the installer did not make that Secret. The entries are `nil` when
  none is kept, as when the release lists none.

      iex> EhosPlatform.ExternalDatabases.read_back(nil)
      {nil, []}
  """
  @spec read_back(term()) :: {[entry()] | nil, [{String.t(), String.t()}]}
  def read_back(listed) when is_list(listed) do
    read = Enum.map(listed, &read_entry/1)
    kept = for {:ok, entry, _dropped} <- read, do: entry
    {if(kept == [], do: nil, else: kept), Enum.flat_map(read, &said/1)}
  end

  def read_back(_none), do: {nil, []}

  defp said({:ok, _entry, said}), do: said
  defp said({:left_out, why}), do: [why]

  defp read_entry(%{} = given) do
    entry =
      for {key, _need, _type} <- @fields, Map.get(given, key) != nil, into: %{} do
        {key, whole_number(key, Map.get(given, key))}
      end

    with :ok <- named(entry),
         :ok <- typed(entry, shown_name(entry)),
         {:ok, entry} <- own_secret(entry),
         do: {:ok, entry, dropped(given, entry)}
  end

  defp read_entry(_not_a_map),
    do:
      {:left_out,
       {"The install leaves out an entry of dataResources.external.", "The entry is not a map."}}

  # The chart's `ehos.wholeNumber` takes a port or a version as its digits too.
  defp whole_number(key, value) when key in ["port", "version"] and is_binary(value) do
    if value =~ ~r/\A[0-9]{1,6}\z/, do: String.to_integer(value), else: value
  end

  defp whole_number(_key, value), do: value

  defp named(%{"name" => name}) when is_binary(name) do
    if name =~ @name, do: :ok, else: named(%{})
  end

  defp named(_entry),
    do:
      {:left_out,
       {"The install leaves out an entry of dataResources.external.",
        "The entry has no name in the form the chart takes."}}

  # Keys of an entry that the chart does not name, which the next install does not write.
  defp dropped(given, entry) do
    case given |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort() do
      [] ->
        []

      keys ->
        [
          {"The install leaves out keys of the database outside the installation " <>
             "#{shown_name(entry)}.",
           "The chart does not name these keys: #{Enum.map_join(keys, ", ", &shown/1)}."}
        ]
    end
  end

  defp typed(entry, shown) do
    case Enum.find(@fields, &(not field_typed?(entry, &1))) do
      nil ->
        :ok

      {key, _need, _type} ->
        {:left_out,
         {"The install leaves out the database outside the installation #{shown}.",
          "It has no #{key} of the type the chart takes."}}
    end
  end

  defp field_typed?(entry, {key, need, type}) do
    case Map.fetch(entry, key) do
      {:ok, value} -> of_type?(value, type)
      :error -> need == :optional
    end
  end

  defp of_type?(value, :string), do: is_binary(value)
  defp of_type?(value, :integer), do: is_integer(value)
  defp of_type?(value, :strings), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp own_secret(%{"name" => name, "managingRoleSecret" => secret} = entry) do
    if secret == secret_name(name),
      do: {:ok, entry},
      else:
        {:left_out,
         {"The install leaves out the database outside the installation " <>
            "#{shown_name(entry)}.",
          "It keeps its managing role in the Secret #{shown(secret)}, and the installer keeps " <>
            "only #{shown(secret_name(name))}. Add the database again to give it that Secret."}}
  end

  # A name from the release is shown only in the chart's form, so it never carries a control
  # character to a terminal.
  defp shown_name(%{"name" => name}) when is_binary(name), do: shown(name)
  defp shown_name(_entry), do: "without a name"

  defp shown(text) when is_binary(text) do
    if text =~ ~r/\A[A-Za-z0-9_.-]{1,253}\z/, do: text, else: "(a name not shown)"
  end

  defp shown(_not_text), do: "(a name not shown)"

  @doc """
  `:ok` when `entry` is one the chart takes, on its own, else `{:error, field, rule}`, with the
  first field it refuses and the chart's rule for it, a phrase that starts with "must". The chart
  checks more against the rest of its values, such as a name or a Secret that an instance of the
  installation already has, or two entries for one database: rendering it says those.

      iex> EhosPlatform.ExternalDatabases.check(%{"name" => "ehos-ledger"})
      {:error, "name", "must not start with ehos-, which names the objects of EHOS"}
  """
  @spec check(map()) :: :ok | {:error, field(), String.t()}
  def check(entry) do
    Enum.find_value(
      [
        {"name", &name_rule/1},
        {"version", &version_rule/1},
        {"host", &host_rule/1},
        {"port", &port_rule/1},
        {"database", &database_rule/1},
        {"ca", &ca_rule/1},
        {"addressRanges", &ranges_rule/1},
        {"managingRoleSecret", &secret_rule/1},
        {"administratorRole", &administrator_rule/1}
      ],
      :ok,
      fn {field, rule} ->
        case rule.(Map.get(entry, field)) do
          :ok -> nil
          {:error, why} -> {:error, field, why}
        end
      end
    )
  end

  defp name_rule(name) do
    cond do
      not (is_binary(name) and name =~ @name) ->
        {:error,
         "must be a DNS label of at most 50 characters: lowercase letters, digits and -, " <>
           "starting with a letter"}

      String.starts_with?(name, "ehos-") ->
        {:error, "must not start with ehos-, which names the objects of EHOS"}

      true ->
        :ok
    end
  end

  defp version_rule(version) when is_integer(version) and version in 16..999, do: :ok

  defp version_rule(_version),
    do: {:error, "must be the major version of PostgreSQL, 16 or later, such as 17"}

  defp host_rule(host) when is_binary(host) and byte_size(host) <= 253 do
    if host =~ @host, do: :ok, else: host_rule(nil)
  end

  defp host_rule(_host),
    do:
      {:error, "must be a lowercase DNS name with a dot, such as db.example.com, not an address"}

  defp port_rule(nil), do: :ok
  defp port_rule(port) when is_integer(port) and port in 1..65_535, do: :ok
  defp port_rule(_port), do: {:error, "must be from 1 to 65535"}

  defp database_rule(database) when is_binary(database) do
    if database =~ @database, do: :ok, else: database_rule(nil)
  end

  defp database_rule(_database),
    do:
      {:error,
       "must be a lowercase PostgreSQL name of at most 63 characters: letters, digits and _, " <>
         "not starting with a digit"}

  defp ca_rule(ca) when is_binary(ca) do
    cond do
      String.contains?(ca, "PRIVATE KEY") ->
        {:error, "must hold the certificates alone, and no private key"}

      certificates?(ca) ->
        :ok

      true ->
        ca_rule(nil)
    end
  end

  defp ca_rule(_ca), do: {:error, "must hold one or more certificates in PEM"}

  defp certificates?(pem) do
    case :public_key.pem_decode(pem) do
      [_ | _] = entries -> Enum.all?(entries, &match?({:Certificate, _der, :not_encrypted}, &1))
      [] -> false
    end
  rescue
    _not_pem -> false
  end

  defp ranges_rule([_ | _] = ranges) do
    with nil <- Enum.find_value(ranges, &range_refused/1) do
      if length(Enum.uniq(ranges)) == length(ranges),
        do: :ok,
        else: {:error, "must list each range once"}
    end
  end

  defp ranges_rule(_none),
    do: {:error, "must list the IPv4 ranges that the database answers from, such as 10.20.0.0/24"}

  defp range_refused(range) when is_binary(range) do
    if range =~ @range, do: range_bits(range), else: range_refused(nil)
  end

  defp range_refused(range),
    do: {:error, "must be IPv4 ranges, such as 10.20.0.0/24, and #{inspect(range)} is not one"}

  defp range_bits(range) do
    [address, prefix] = String.split(range, "/")
    octets = address |> String.split(".") |> Enum.map(&String.to_integer/1)
    prefix = String.to_integer(prefix)
    value = Enum.reduce(octets, 0, &(&2 * 256 + &1))
    size = Integer.pow(2, 32 - prefix)
    base = value - rem(value, size)

    cond do
      prefix < 20 ->
        {:error,
         "must be /20 or narrower, and #{range} is wider: list the subnets of the database"}

      hd(octets) == 127 ->
        {:error, "must not be loopback, and #{range} is"}

      Enum.take(octets, 2) == [169, 254] ->
        {:error,
         "must not be in 169.254.0.0/16, where a cloud serves the metadata of its machines, " <>
           "and #{range} is"}

      base != value ->
        {:error,
         "must have the address bits after the prefix at zero: write #{range} as " <>
           "#{dotted(base)}/#{prefix}"}

      true ->
        nil
    end
  end

  defp dotted(value),
    do: Enum.map_join([24, 16, 8, 0], ".", &(value |> Bitwise.bsr(&1) |> Bitwise.band(255)))

  @instance_secret_endings ~w(-superuser -app -replication -ca -server -pull-secret -pooler)

  defp secret_rule(secret) when is_binary(secret) do
    cond do
      not (byte_size(secret) <= 253 and
               secret =~ ~r/\A[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*\z/) ->
        {:error, "must be the name of a Secret: lowercase letters, digits, - and ."}

      String.starts_with?(secret, ["ehos-role-", "ehos-sessions-"]) ->
        {:error, "must not start with ehos-role- or ehos-sessions-, which name Secrets of EHOS"}

      # eh-os#1637: an instance taken out of the list keeps its Secrets, so the chart refuses
      # these endings whatever the name before them, but in ehosctl's own names: no instance's
      # name starts with ehos-.
      not String.starts_with?(secret, "ehos-external-") and
          String.ends_with?(secret, @instance_secret_endings) ->
        {:error,
         "must not end with -superuser, -app, -replication, -ca, -server, -pull-secret or " <>
           "-pooler, which CloudNativePG gives the Secrets of an instance"}

      true ->
        :ok
    end
  end

  defp secret_rule(_secret), do: secret_rule("")

  defp administrator_rule(nil), do: :ok

  defp administrator_rule(role) when is_binary(role) do
    cond do
      not (role =~ @role) ->
        {:error,
         "must be the name of a role, of at most 63 characters: letters, digits, _ . @ + and -"}

      role =~ ~r/\A(?i)(ehos_|pg_|public\z)/ ->
        {:error,
         "must not start with ehos_ or pg_, nor be public: those name the roles of EHOS and of " <>
           "PostgreSQL"}

      true ->
        :ok
    end
  end

  defp administrator_rule(_role), do: administrator_rule("")

  @doc """
  The Secret of the managing role of the database `name`, a `kubernetes.io/basic-auth` Secret in
  `ehos-data` that holds `username` and `password`, labelled as the installer's and annotated with
  the database's name. With `resource_version`, it replaces the one read at that version.
  """
  @spec secret(String.t(), String.t(), String.t(), String.t() | nil) :: map()
  def secret(name, username, password, resource_version \\ nil) do
    metadata = %{
      "name" => secret_name(name),
      "namespace" => @namespace,
      "labels" => %{@manager_label => @manager},
      "annotations" => %{@resource_annotation => name}
    }

    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "type" => "kubernetes.io/basic-auth",
      "metadata" =>
        if(resource_version,
          do: Map.put(metadata, "resourceVersion", resource_version),
          else: metadata
        ),
      "data" => %{
        "username" => Base.encode64(username),
        "password" => Base.encode64(password)
      }
    }
  end

  @doc """
  Whether the Secret `held`, as kubectl gives it, is the one the installer made for the database
  `name`: `:ours` when it has the installer's label, the annotation for `name`, and no owner; else
  `{:theirs, why}`, a phrase that says what holds the name.
  """
  @spec holder(map(), String.t()) :: :ours | {:theirs, String.t()}
  def holder(held, name) do
    metadata = Map.get(held, "metadata") || %{}
    labels = Map.get(metadata, "labels") || %{}
    annotations = Map.get(metadata, "annotations") || %{}

    cond do
      (owners = Map.get(metadata, "ownerReferences")) not in [nil, []] ->
        {:theirs, "it belongs to #{owners(owners)}"}

      Map.get(labels, @manager_label) != @manager ->
        {:theirs, "it does not have the label #{@manager_label}: #{@manager}"}

      Map.get(annotations, @resource_annotation) != name ->
        {:theirs,
         "its annotation #{@resource_annotation} does not name the database #{shown(name)}"}

      true ->
        :ours
    end
  end

  defp owners(owners) when is_list(owners) do
    Enum.map_join(owners, " and ", fn
      %{"kind" => kind, "name" => owner} when is_binary(kind) and is_binary(owner) ->
        "the #{shown_kind(kind)} #{shown(owner)}"

      _other ->
        "another object"
    end)
  end

  defp owners(_owners), do: "another object"

  defp shown_kind(kind), do: if(kind =~ ~r/\A[A-Za-z]{1,63}\z/, do: kind, else: "object")
end

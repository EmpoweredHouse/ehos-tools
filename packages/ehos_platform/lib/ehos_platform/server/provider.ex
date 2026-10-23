defmodule EhosPlatform.Server.Provider do
  @moduledoc """
  What `EhosPlatform.Server` needs to know about the cloud an installation's server is on (D-83,
  D-127): its
  OpenTofu module, the module's variables and where their credentials come from, the server's
  resource address, and how the provider says it has no capacity and shows a new server's host
  keys. Everything else, the cloud-init document, the state, the tunnel and the install above
  it, is the same on every provider.

  The credentials stay where the provider's own tools keep them: `~/.oci/config` for Oracle, an
  AWS profile in `~/.aws`, Google's Application Default Credentials, and an entry of OpenStack's
  `clouds.yaml` for OVHcloud. None is written to the installation's variables.
  """

  @providers %{"oci" => :oci, "aws" => :aws, "gcp" => :gcp, "ovh" => :ovh}

  @typedoc "A provider an installation's server can be on."
  @type t :: :oci | :aws | :gcp | :ovh

  # A clouds.yaml is a few kilobytes; anything far larger is not one. Its aliases are refused too: a
  # small document of nested aliases expands past any size when decoded.
  @max_clouds_yaml 64 * 1024
  @yaml_alias ~r/(?::|^\s*-|[\[{,])\s*\*[^\s,\]}]/m

  @typedoc """
  Where `up` made an installation's server, as `installation.json` keeps it: the provider, what
  says which server it is (`identity/1`), and what the next command should use again, such as the
  profile. `nil` before the first apply.
  """
  @type place :: %{String.t() => term()} | nil

  @doc "The providers' names, as `--provider` takes them."
  @spec names() :: [String.t()]
  def names, do: @providers |> Map.keys() |> Enum.sort()

  @doc """
  The provider a name gives.

      iex> EhosPlatform.Server.Provider.parse("aws")
      {:ok, :aws}
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(name) do
    case Map.fetch(@providers, name) do
      {:ok, provider} ->
        {:ok, provider}

      :error ->
        {:error, "The provider is one of #{Enum.join(names(), ", ")}, not #{inspect(name)}"}
    end
  end

  @doc "The provider's name, as `parse/1` reads it."
  @spec name(t()) :: String.t()
  def name(provider), do: Atom.to_string(provider)

  @doc "The provider's OpenTofu module, from the root of a source (`EhosPlatform.Source`)."
  @spec module(t()) :: String.t()
  def module(provider), do: "deploy/tofu/#{name(provider)}"

  @doc "The server's resource address in the provider's module."
  @spec instance(t()) :: String.t()
  def instance(:oci), do: "oci_core_instance.server"
  def instance(:aws), do: "aws_instance.server"
  def instance(:gcp), do: "google_compute_instance.server"
  def instance(:ovh), do: "openstack_compute_instance_v2.server"

  @doc """
  Whether the provider's module asks the provider to refuse deleting the server, through its
  `deletion_protection` variable (ehos-tools#430): AWS's termination protection and GCP's deletion
  protection. Oracle and OVHcloud have none on an instance, and their modules say so.
  """
  @spec deletion_protection?(t()) :: boolean()
  def deletion_protection?(provider), do: protection_attribute(provider) != nil

  @doc """
  The instance's attribute that holds its deletion protection, or nil for a provider with none.
  """
  @spec protection_attribute(t()) :: String.t() | nil
  def protection_attribute(:aws), do: "disable_api_termination"
  def protection_attribute(:gcp), do: "deletion_protection"
  def protection_attribute(_provider), do: nil

  @doc """
  Whether OpenTofu's provider refuses removing a server while its protection is on, so `down` and
  `up --replace` lift it first: Google's does. AWS's turns termination protection off before it
  terminates an instance whose `force_destroy` is set, as eh-os's AWS module sets it, so on AWS the
  protection guards the console, the API and the CLI, and not OpenTofu. Without `force_destroy` it
  would not, and a destroy would stop at the server after removing its address and rules.
  """
  @spec lifted_before_removal?(t()) :: boolean()
  def lifted_before_removal?(provider), do: provider == :gcp

  @doc "The provider's name as a person reads it."
  @spec title(t()) :: String.t()
  def title(:oci), do: "Oracle Cloud"
  def title(:aws), do: "AWS"
  def title(:gcp), do: "Google Cloud"
  def title(:ovh), do: "OVHcloud"

  @doc """
  Where an operator compares the host keys `up` trusted on first contact: cloud-init writes their
  fingerprints to the instance's console output, which no one between the workstation and the
  server can change.
  """
  @spec console(t()) :: String.t()
  def console(:oci), do: "the console history of the instance in Oracle's console"

  def console(:aws),
    do: "the instance's system log in AWS's console (Actions, Monitor and troubleshoot)"

  def console(:gcp), do: "the serial port output of the instance in Google Cloud's console"

  def console(:ovh),
    do:
      "the instance's console log (`openstack console log show <server>`, or OVHcloud's Control Panel)"

  @doc """
  What to try when the provider had no machine of that shape in that zone, or `""` when the output
  says nothing of the kind.
  """
  @spec capacity_hint(t(), String.t()) :: String.t()
  def capacity_hint(:oci, output) do
    if output =~ "Out of host capacity",
      do:
        "\nOracle has no Ampere capacity there now: run it again later, or, where the region " <>
          "has more than one availability domain, with another --availability-domain (from 0)",
      else: ""
  end

  def capacity_hint(:ovh, output) do
    if output =~ "No valid host was found",
      do:
        "\nOVHcloud has no machine of that flavor in that region now: run it again later, or " <>
          "with another --instance-type or --region",
      else: ""
  end

  def capacity_hint(provider, output) when provider in [:aws, :gcp] do
    if output =~ ~r/InsufficientInstanceCapacity|ZONE_RESOURCE_POOL_EXHAUSTED/,
      do:
        "\nThe provider has no machine of that type in that zone now: run it again later, or " <>
          "with another --availability-domain (from 0), which picks another of the region's zones",
      else: ""
  end

  @doc """
  The module's variables that depend on the provider, from `opts`, the installation's recorded
  `place`, the environment and the provider's own configuration, in that order. A first `up` that
  failed before anything was made recorded nothing, so it binds nothing.

  ## Options

    * `:oci_config` and `:oci_profile` — Oracle's configuration file and profile, which name the
      tenancy and region. Default to `~/.oci/config` and the recorded profile, or `DEFAULT`.
    * `:aws_profile` — the AWS profile, from `~/.aws`. Defaults to the recorded one, then
      `AWS_PROFILE`, then `default`. The account is pinned by its ID once known, whatever the
      profile (`aws_account_id`, the provider's `allowed_account_ids`).
    * `:gcp_project` — the GCP project. Defaults to the recorded one, then `GOOGLE_CLOUD_PROJECT`.
    * `:os_cloud` — on OVHcloud, the entry of OpenStack's `clouds.yaml` the module authenticates
      with (D-127). Defaults to the recorded one, then `OS_CLOUD`, then `ovh`. The entry must be
      there; the project is pinned by its ID once known, whatever the entry (`project_id`, the
      module's postcondition).
    * `:region` — on AWS, GCP and OVHcloud. Defaults to the recorded one, then `eu-central-1`,
      `europe-west3` (D-83) or `GRA11` (D-127). On Oracle the region is the profile's.
    * `:clouds_yaml` — the `clouds.yaml` to read, for tests. Defaults to where OpenStack's client
      looks (`clouds_yaml/1`).
    * `:env` — reads an environment variable, for tests. Defaults to `System.get_env/1`.
  """
  @spec variables(t(), keyword(), place()) :: {:ok, map()} | {:error, String.t()}
  def variables(provider, opts, nil), do: variables(provider, opts, %{})

  def variables(:oci, opts, place) do
    path = opts |> Keyword.get(:oci_config, "~/.oci/config") |> Path.expand()
    profile = opts[:oci_profile] || place["oci_profile"] || "DEFAULT"

    if opts[:region],
      do:
        {:error,
         "On Oracle the region is the profile's, in #{path}; --region is for AWS, GCP and OVHcloud"},
      else: oci_variables(path, profile)
  end

  def variables(:aws, opts, place) do
    env = Keyword.get(opts, :env, &System.get_env/1)

    profile =
      opts[:aws_profile] || place["aws_profile"] || present(env.("AWS_PROFILE")) || "default"

    {:ok,
     %{
       region: opts[:region] || place["region"] || "eu-central-1",
       aws_profile: profile,
       aws_account_id: place["aws_account_id"] || ""
     }}
  end

  def variables(:gcp, opts, place) do
    env = Keyword.get(opts, :env, &System.get_env/1)

    case opts[:gcp_project] || place["project"] || present(env.("GOOGLE_CLOUD_PROJECT")) do
      nil ->
        {:error,
         "Name the GCP project with --gcp-project, and sign in with " <>
           "`gcloud auth application-default login` (D-83)"}

      project ->
        {:ok, %{project: project, region: opts[:region] || place["region"] || "europe-west3"}}
    end
  end

  def variables(:ovh, opts, place) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    cloud = opts[:os_cloud] || place["os_cloud"] || present(env.("OS_CLOUD")) || "ovh"

    with {:ok, _path} <-
           os_cloud(cloud, Keyword.put_new_lazy(opts, :clouds_yaml, fn -> clouds_yaml(env) end)) do
      {:ok,
       %{
         os_cloud: cloud,
         region: opts[:region] || place["region"] || "GRA11",
         project_id: place["project_id"] || ""
       }}
    end
  end

  @doc """
  The `clouds.yaml` the module authenticates with, as an absolute path: `OS_CLIENT_CONFIG_FILE`'s,
  else the first of `~/.config/openstack/clouds.yaml` and `/etc/openstack/clouds.yaml` that exists,
  else `nil`, in OpenStack's client's order. Not `./clouds.yaml`, which OpenStack's client would
  read from the module's directory, where OpenTofu runs, and not from where the operator is;
  `env/2` hands OpenTofu this path, so the file checked is the file used. `env` reads an
  environment variable, and `home` is the operator's home directory.
  """
  @spec clouds_yaml((String.t() -> String.t() | nil), Path.t()) :: Path.t() | nil
  def clouds_yaml(env \\ &System.get_env/1, home \\ System.user_home!()) do
    case present(env.("OS_CLIENT_CONFIG_FILE")) do
      nil ->
        Enum.find(
          [Path.join(home, ".config/openstack/clouds.yaml"), "/etc/openstack/clouds.yaml"],
          &File.regular?/1
        )

      path ->
        Path.expand(path)
    end
  end

  @doc """
  Whether `clouds.yaml` (`opts[:clouds_yaml]`, else `clouds_yaml/1`'s) has the entry `cloud`, as
  `{:ok, path}`, or what is missing. Only the entry's presence is read: the password or the
  application credential's secret in it is OpenStack's provider's to read, never this one's.

      iex> path = Path.join(System.tmp_dir!(), "ehos-clouds-doctest.yaml")
      iex> File.write!(path, "clouds:\\n  ovh:\\n    region_name: GRA11\\n")
      iex> EhosPlatform.Server.Provider.os_cloud("ovh", clouds_yaml: path)
      {:ok, path}
  """
  @spec os_cloud(String.t(), keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  # The path is OpenStack's own, or the operator's OS_CLIENT_CONFIG_FILE.
  # sobelow_skip ["Traversal.FileModule"]
  def os_cloud(cloud, opts \\ []) do
    path = Keyword.get_lazy(opts, :clouds_yaml, fn -> clouds_yaml() end)
    missing = "Download the clouds.yaml of an OpenStack user of your OVHcloud project (D-127)"

    with {:path, path} when is_binary(path) <- {:path, path},
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_clouds_yaml <-
           File.stat(path),
         {:ok, contents} <- File.read(path),
         {:alias, false} <- {:alias, contents =~ @yaml_alias},
         {:ok, %{"clouds" => %{^cloud => %{}}}} <- YamlElixir.read_from_string(contents) do
      {:ok, path}
    else
      {:alias, true} ->
        {:error,
         "#{path} seems to use YAML aliases (`*name`), which EHOS does not read: write them " <>
           "out, or quote a value that holds `*` after a space, a comma, a colon or a bracket"}

      {:path, nil} ->
        {:error, "No clouds.yaml in ~/.config/openstack or OS_CLIENT_CONFIG_FILE. " <> missing}

      {:ok, %{"clouds" => %{}}} ->
        {:error,
         "#{path} has no entry #{inspect(cloud)} under `clouds`; name the entry with --os-cloud"}

      _other ->
        {:error, "#{path} cannot be read as OpenStack's clouds.yaml. " <> missing}
    end
  end

  # The path is the operator's own option or their home directory, in a Mix task they run.
  # sobelow_skip ["Traversal.FileModule"]
  defp oci_variables(path, profile) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, oci} <- parse_oci_config(contents, profile),
             do: {:ok, %{tenancy_ocid: oci.tenancy, region: oci.region, oci_profile: profile}}

      {:error, _reason} ->
        {:error, "#{path} is missing. Create an API key in Oracle Cloud's console (D-77)"}
    end
  end

  @size_options %{
    oci: [ocpus: "ocpus", memory_gb: "memory_gbs"],
    aws: [instance_type: "instance_type"],
    gcp: [instance_type: "machine_type"],
    ovh: [instance_type: "flavor_name"]
  }

  @size_flags [ocpus: "--ocpus", memory_gb: "--memory-gb", instance_type: "--instance-type"]

  @doc """
  The options that size the server on a provider, each with the module's variable it sets (D-84):
  an Oracle flex shape's OCPUs and memory, an EC2 instance type, a Compute Engine machine type, an
  OpenStack flavor.
  """
  @spec size_options(t()) :: [{atom(), String.t()}]
  def size_options(provider), do: Map.fetch!(@size_options, provider)

  @doc """
  The server's size as the module's variables, from `opts` and, for what they do not give, the
  `recorded` variables of the last `up`; what neither holds is left to the module's default
  (D-84). An option of another provider's is refused, as is a value no provider would take.

      iex> EhosPlatform.Server.Provider.size(:oci, [ocpus: 1], %{"memory_gbs" => 6})
      {:ok, %{"ocpus" => 1, "memory_gbs" => 6}}

      iex> EhosPlatform.Server.Provider.size(:gcp, [instance_type: "e2-standard-4"], %{})
      {:ok, %{"machine_type" => "e2-standard-4"}}
  """
  @spec size(t(), keyword(), map()) :: {:ok, %{String.t() => term()}} | {:error, String.t()}
  def size(provider, opts, recorded) do
    own = size_options(provider)

    foreign =
      for {option, _flag} <- @size_flags,
          opts[option] != nil,
          not Keyword.has_key?(own, option),
          do: option

    case foreign do
      [] ->
        Enum.reduce_while(own, {:ok, %{}}, fn {option, variable}, {:ok, size} ->
          option |> size_value(opts[option], recorded[variable]) |> add_size(variable, size)
        end)

      options ->
        flags = Enum.map_join(options, " and ", &@size_flags[&1])
        own_flags = Enum.map_join(own, " and ", fn {option, _variable} -> @size_flags[option] end)

        {:error,
         "#{flags} does not size a server on #{name(provider)}; give #{own_flags} there (D-84)"}
    end
  end

  @doc """
  Where the server's size is among its resource's attributes, each as a path into them, so a plan's
  values before and after say whether the server is resized (D-84): an Oracle flex shape's OCPUs
  and memory, an EC2 instance type, a Compute Engine machine type.
  """
  @spec size_attributes(t()) :: [[String.t() | non_neg_integer()]]
  def size_attributes(:oci),
    do: [["shape_config", 0, "ocpus"], ["shape_config", 0, "memory_in_gbs"]]

  def size_attributes(:aws), do: [["instance_type"]]
  def size_attributes(:gcp), do: [["machine_type"]]
  def size_attributes(:ovh), do: [["flavor_name"]]

  defp add_size({:ok, nil}, _variable, size), do: {:cont, {:ok, size}}
  defp add_size({:ok, value}, variable, size), do: {:cont, {:ok, Map.put(size, variable, value)}}
  defp add_size({:error, message}, _variable, _size), do: {:halt, {:error, message}}

  defp size_value(_option, nil, nil), do: {:ok, nil}
  # A recorded size is held to what the option would take: the file is the operator's to edit.
  defp size_value(option, nil, recorded) do
    with {:error, message} <- size_value(option, recorded, nil),
         do: {:error, "The size recorded in server.tfvars.json cannot be used: #{message}"}
  end

  defp size_value(option, value, _recorded) when option in [:ocpus, :memory_gb] do
    if is_integer(value) and value >= 1,
      do: {:ok, value},
      else: {:error, "#{@size_flags[option]} is a whole number from 1, not #{inspect(value)}"}
  end

  defp size_value(:instance_type, value, _recorded) do
    if is_binary(value) and value =~ ~r/\A[a-z0-9][a-z0-9.-]{0,62}\z/,
      do: {:ok, value},
      else: {:error, "--instance-type is a type's name, such as t4g.large, not #{inspect(value)}"}
  end

  @doc """
  What `installation.json` records from the module's variables: the provider, its `identity/1`,
  and the profile the next command uses again.
  """
  @spec place(t(), map()) :: %{String.t() => term()}
  def place(provider, vars) do
    vars = Map.new(vars, fn {key, value} -> {to_string(key), value} end)
    remembered = %{oci: ~w(oci_profile), aws: ~w(aws_profile), gcp: [], ovh: ~w(os_cloud)}

    vars
    |> Map.take(identity(provider) ++ remembered[provider])
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.put("provider", name(provider))
  end

  @doc """
  What makes a server this one and not another: the account and the region. A plan with another
  of either would refresh the state against a place where nothing of the installation is, drop
  every resource from it and make them all again, leaving the first server running where no
  command reaches it. On AWS the account is its ID, recorded after the first apply: a profile is
  only a name for one, and on OVHcloud the project is its ID, recorded likewise.
  """
  @spec identity(t()) :: [String.t()]
  def identity(:oci), do: ~w(tenancy_ocid region)
  def identity(:aws), do: ~w(aws_account_id region)
  def identity(:gcp), do: ~w(project region)
  def identity(:ovh), do: ~w(project_id region)

  @doc """
  The recorded `place`'s identity that `vars` would change, as `"key old → new"`, or none. A key
  the place does not hold yet, such as an AWS account before the first apply, changes nothing.
  """
  @spec moved(t(), place(), map()) :: [String.t()]
  def moved(_provider, nil, _vars), do: []

  def moved(provider, place, vars) do
    asked = place(provider, vars)

    for key <- identity(provider),
        Map.has_key?(place, key),
        Map.has_key?(asked, key),
        place[key] != asked[key],
        do: "#{key} #{place[key]} → #{asked[key]}"
  end

  @doc """
  An output of the module `up` records in the place after an apply, as `{output, key}`: on AWS,
  the account the server was made in, which the provider is then pinned to; on OVHcloud, the
  project, which the module's postcondition holds every later plan to.
  """
  @spec pinned_output(t()) :: {String.t(), String.t()} | nil
  def pinned_output(:aws), do: {"account_id", "aws_account_id"}
  def pinned_output(:ovh), do: {"project_id", "project_id"}
  def pinned_output(_provider), do: nil

  @doc """
  The environment OpenTofu runs in, beyond the operator's: on AWS, every credential an operator
  may have exported for something else (static keys, a profile, a web identity, a container's) is
  taken out, so the recorded profile is the only source, and the account ID it is pinned to the
  check (D-83).
  """
  @spec env(t()) :: [{String.t(), String.t() | nil}]
  def env(:aws) do
    for name <-
          ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
             AWS_ACCESS_KEY AWS_SECRET_KEY AWS_PROFILE AWS_DEFAULT_PROFILE
             AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME
             AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
             AWS_CONTAINER_AUTHORIZATION_TOKEN),
        do: {name, nil}
  end

  def env(:ovh), do: env(:ovh, [])

  def env(_provider), do: []

  @doc """
  `env/1` with `opts`: on OVHcloud, every OS_* variable that could stand in for the clouds.yaml
  entry, add to it or weaken how it is used (a token, a scope, TLS settings, debug logging) is
  taken out, and `OS_CLIENT_CONFIG_FILE` is set to the file found, absolute, so the file checked is
  the file OpenTofu's provider reads (D-127): `:clouds_yaml`, else `clouds_yaml/2`'s with `:env`.
  OpenStack's client also merges a `secure.yaml` beside it, or in `~/.config/openstack`, which is
  the operator's to keep apart.
  """
  @spec env(t(), keyword()) :: [{String.t(), String.t() | nil}]
  def env(:ovh, opts) do
    path =
      Keyword.get_lazy(opts, :clouds_yaml, fn ->
        clouds_yaml(Keyword.get(opts, :env, &System.get_env/1))
      end)

    removed =
      for name <-
            ~w(OS_CLOUD OS_AUTH_URL OS_AUTH_TYPE OS_USERNAME OS_USER_ID OS_PASSWORD OS_TOKEN
               OS_AUTH_TOKEN OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME
               OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID OS_PROJECT_DOMAIN_NAME
               OS_DOMAIN_ID OS_DOMAIN_NAME OS_DEFAULT_DOMAIN OS_SYSTEM_SCOPE OS_REGION_NAME
               OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_NAME
               OS_APPLICATION_CREDENTIAL_SECRET OS_INTERFACE OS_ENDPOINT_TYPE
               OS_IDENTITY_API_VERSION OS_INSECURE OS_CACERT OS_CERT OS_KEY OS_SWAUTH
               OS_DELAYED_AUTH OS_ALLOW_REAUTH OS_DEBUG OS_CLIENT_CONFIG_FILE),
          do: {name, nil}

    if path,
      do: List.keyreplace(removed, "OS_CLIENT_CONFIG_FILE", 0, {"OS_CLIENT_CONFIG_FILE", path}),
      else: removed
  end

  def env(provider, _opts), do: env(provider)

  defp present(""), do: nil
  defp present(value), do: value

  @doc """
  Reads the tenancy and the region of `profile` from the contents of an OCI configuration file.

      iex> EhosPlatform.Server.Provider.parse_oci_config("[DEFAULT]\\nuser=u\\ntenancy=ocid1.tenancy.oc1..t\\nregion=eu-frankfurt-1\\n", "DEFAULT")
      {:ok, %{tenancy: "ocid1.tenancy.oc1..t", region: "eu-frankfurt-1"}}
  """
  @spec parse_oci_config(String.t(), String.t()) ::
          {:ok, %{tenancy: String.t(), region: String.t()}} | {:error, String.t()}
  def parse_oci_config(contents, profile) do
    {_section, sections} =
      contents
      |> String.split(~r/\R/)
      |> Enum.map(&String.trim/1)
      |> Enum.reduce({nil, %{}}, &config_line/2)

    # A profile inherits what it does not set from [DEFAULT], as the OCI SDKs read it.
    case Map.merge(Map.get(sections, "DEFAULT", %{}), Map.get(sections, profile, %{})) do
      %{"tenancy" => tenancy, "region" => region} when tenancy != "" and region != "" ->
        {:ok, %{tenancy: tenancy, region: region}}

      _other ->
        {:error, "~/.oci/config has no `tenancy` and `region` in its [#{profile}] profile"}
    end
  end

  defp config_line("[" <> rest, {_section, sections}),
    do: {String.trim_trailing(rest, "]"), sections}

  defp config_line(line, {section, sections}) when is_binary(section) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        {key, value} = {String.trim(key), String.trim(value)}
        {section, Map.update(sections, section, %{key => value}, &Map.put(&1, key, value))}

      _other ->
        {section, sections}
    end
  end

  defp config_line(_line, acc), do: acc
end

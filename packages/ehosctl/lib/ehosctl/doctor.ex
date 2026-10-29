defmodule Ehosctl.Doctor do
  @moduledoc """
  `ehosctl doctor`: whether this machine can run the platform plane's commands (eh-os D-87,
  D-92, T-13), before any of them makes a server.

  It reports:

    * **the tools**, OpenTofu, Helm and kubectl, at the versions EHOS is tested with
      (`EhosPlatform.Tools`), each found as the platform commands find it
      (`Ehosctl.PlatformRunner.resolve/2`), which installs nothing, and for each one missing the
      command that installs it;
    * **`ssh`**, the system's;
    * **the cloud accounts it can see**, as `ehosctl server up` will use them: the `DEFAULT`
      profile of `~/.oci/config` (or the one `--oci-profile` names), the AWS profile `AWS_PROFILE`
      names, else `default`, in `~/.aws` (keys in the environment are taken out of OpenTofu's,
      eh-os D-83), GCP's application credentials with `GOOGLE_CLOUD_PROJECT`, and the entry of
      OpenStack's `clouds.yaml` that `OS_CLOUD` names, else `ovh`, for OVHcloud (eh-os D-127). It
      names them and never prints a secret. `GHCR_TOKEN`, which `ehosctl install` pulls EHOS's image with, is
      reported as set or not.

  It exits 0 when every tool and `ssh` are there and at least one provider's account is seen, and
  1 otherwise, after printing the report either way. It installs nothing and changes nothing.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Output
  alias Ehosctl.PlatformRunner
  alias EhosPlatform.Server.Provider
  alias EhosPlatform.Tools

  # A configuration file read is a few kilobytes; anything far larger is not one.
  @max_config 1024 * 1024

  @mise_install "https://mise.jdx.dev/installing-mise.html"

  @impl Ehosctl.Command
  def name, do: :doctor

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Check this machine for what the platform commands need: OpenTofu, Helm and kubectl at " <>
          "EHOS's versions, ssh, and a cloud account. Installs nothing.",
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, _opts) do
    report = report()
    output = %{text: text(report), json: report}

    if report.ready,
      do: {:ok, output},
      else: tap(1, fn _ -> Output.result(output, parsed.flags[:json] == true) end)
  end

  @doc """
  What `doctor` finds, as a map. The home directory to look in and the programs are
  `Ehosctl.OS`'s, and the environment `Ehosctl.SystemEnv`'s.
  """
  @spec report() :: map()
  def report do
    system_env = Ehosctl.SystemEnv.current()
    env = &system_env.get/1
    os = Ehosctl.OS.current()
    home = Path.expand(os.home())
    tools = tools(os.find_executable("mise"))
    ssh = if os.find_executable("ssh"), do: "found", else: "missing"
    accounts = accounts(env, home)

    %{
      tools: tools,
      ssh: ssh,
      accounts: accounts,
      ghcr_token: if(present?(env.("GHCR_TOKEN")), do: "set", else: "not set"),
      ready:
        Enum.all?(tools, &(&1.state == "installed")) and ssh == "found" and
          Enum.any?(accounts, &(&1.state == "found"))
    }
  end

  defp tools(nil) do
    for tool <- Tools.all() do
      Map.merge(described(tool), %{state: "missing", install: "install mise: #{@mise_install}"})
    end
  end

  defp tools(mise) do
    for tool <- Tools.all() do
      case PlatformRunner.resolve(tool.program, mise: mise) do
        {:ok, _path} ->
          Map.merge(described(tool), %{state: "installed", install: nil})

        {:error, :not_found} ->
          Map.merge(described(tool), %{
            state: "missing",
            install: "mise install #{tool.tool}@#{tool.version}"
          })
      end
    end
  end

  defp described(tool), do: %{tool: tool.tool, program: tool.program, version: tool.version}

  defp accounts(env, home) do
    [oci(env, home), aws(env, home), gcp(env, home), ovh(env, home)]
  end

  # The profile `server up` reads unless `--oci-profile` names another (`EhosPlatform.Server.Provider`).
  defp oci(_env, home) do
    case read_config(Path.join(home, ".oci/config")) do
      {:ok, contents} ->
        case Provider.parse_oci_config(contents, "DEFAULT") do
          {:ok, %{region: region}} ->
            account("oci", "found", "profile DEFAULT in ~/.oci/config, region #{shown(region)}")

          {:error, _reason} ->
            account("oci", "incomplete", "~/.oci/config has no tenancy and region in [DEFAULT]")
        end

      {:error, reason} ->
        account("oci", "none", reason)
    end
  end

  # The profile `server up` uses: AWS_PROFILE's, else `default`. Keys in the environment are not
  # one: they are taken out of OpenTofu's environment (eh-os D-83).
  defp aws(env, home) do
    profile = present(env.("AWS_PROFILE")) || "default"

    sections =
      for {file, prefix} <- [{"credentials", ""}, {"config", "profile "}],
          {:ok, contents} <- [read_config(Path.join([home, ".aws", file]))],
          section <- sections(contents),
          do: {section, prefix}

    if Enum.any?(sections, fn {section, prefix} ->
         section == prefix <> profile or (profile == "default" and section == "default")
       end),
       do: account("aws", "found", "profile #{shown(profile)} in ~/.aws"),
       else: account("aws", "none", "no profile #{shown(profile)} in ~/.aws")
  end

  defp sections(contents) do
    for line <- String.split(contents, ~r/\R/),
        [_, name] <- [Regex.run(~r/^\s*\[([^\]]+)\]\s*$/, line)],
        do: name |> String.split() |> Enum.join(" ")
  end

  # A regular file of a configuration's size, a link to one included, as dotfile managers make
  # them: a FIFO would block, and /dev/zero would not end.
  defp read_config(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_config ->
        case File.read(path) do
          {:ok, contents} -> {:ok, contents}
          {:error, _reason} -> {:error, "#{shown(path)} cannot be read"}
        end

      {:ok, _other} ->
        {:error, "#{shown(path)} is not a configuration file"}

      {:error, _reason} ->
        {:error, "no #{shown(path)}"}
    end
  end

  # A value from the operator's files or environment, shown only when it cannot rewrite the
  # terminal (`Ehosctl.Output.printable?/1`).
  defp shown(value) do
    if Output.printable?(value), do: value, else: "(a value that cannot be shown)"
  end

  # The entry `server up` authenticates with unless `--os-cloud` names another
  # (`EhosPlatform.Server.Provider.variables/3`); only its presence is read.
  defp ovh(env, home) do
    cloud = present(env.("OS_CLOUD")) || "ovh"

    case Provider.clouds_yaml(env.("OS_CLIENT_CONFIG_FILE"), home) do
      nil ->
        account("ovh", "none", "no clouds.yaml in ~/.config/openstack or OS_CLIENT_CONFIG_FILE")

      path ->
        case Provider.os_cloud(cloud, clouds_yaml: path) do
          {:ok, _path} ->
            account("ovh", "found", "entry #{shown(cloud)} in #{shown(path)}")

          # The reason names the file and what is wrong with it, never what it holds.
          {:error, reason} ->
            account("ovh", "none", shown(reason))
        end
    end
  end

  defp gcp(env, home) do
    project = present(env.("GOOGLE_CLOUD_PROJECT"))
    adc = Path.join(home, ".config/gcloud/application_default_credentials.json")

    credentials =
      cond do
        (path = present(env.("GOOGLE_APPLICATION_CREDENTIALS"))) && File.regular?(path) ->
          "GOOGLE_APPLICATION_CREDENTIALS"

        File.regular?(adc) ->
          "gcloud's application default credentials"

        true ->
          nil
      end

    case {credentials, project} do
      {nil, _project} ->
        account("gcp", "none", "no application credentials")

      {credentials, nil} ->
        account("gcp", "incomplete", "#{credentials}, but no GOOGLE_CLOUD_PROJECT")

      {credentials, project} ->
        account("gcp", "found", "#{credentials}, project #{shown(project)}")
    end
  end

  defp account(provider, state, detail), do: %{provider: provider, state: state, detail: detail}

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp present?(value), do: present(value) != nil

  defp text(report) do
    tools =
      for tool <- report.tools do
        line = "  #{mark(tool.state == "installed")} #{tool.tool} #{tool.version}"
        if tool.install, do: line <> ": #{tool.state}, #{tool.install}", else: line
      end

    accounts =
      for account <- report.accounts do
        "  #{mark(account.state == "found")} #{provider_name(account.provider)}: #{account.detail}"
      end

    verdict =
      if report.ready,
        do: "Ready for `ehosctl server up`.",
        else: "Not ready: install what is missing, then run `ehosctl doctor` again."

    Enum.join(
      ["Tools, at the versions EHOS is tested with:"] ++
        tools ++
        ["  #{mark(report.ssh == "found")} ssh: #{report.ssh}", "", "Cloud accounts:"] ++
        accounts ++
        ["", "GHCR_TOKEN, for `ehosctl install`: #{report.ghcr_token}", "", verdict],
      "\n"
    )
  end

  defp mark(true), do: "ok"
  defp mark(false), do: "--"

  defp provider_name("oci"), do: "Oracle Cloud"
  defp provider_name("aws"), do: "AWS"
  defp provider_name("gcp"), do: "GCP"
  defp provider_name("ovh"), do: "OVHcloud"
end

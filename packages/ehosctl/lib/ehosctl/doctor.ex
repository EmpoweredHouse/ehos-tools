defmodule Ehosctl.Doctor do
  @moduledoc """
  `ehosctl doctor`: whether this machine can run the platform plane's commands (eh-os D-87,
  D-92, T-13), before any of them makes a server.

  It reports:

    * **the tools**, OpenTofu, Helm and kubectl, at the versions EHOS is tested with
      (`EhosPlatform.Tools`), each looked up with `mise where <tool>@<version>`, which installs
      nothing, and for each one missing the command that installs it;
    * **`ssh`**, the system's;
    * **the cloud accounts it can see**, by where their tools keep them: an Oracle Cloud profile in
      `~/.oci/config`, an AWS profile or keys, GCP's application credentials. It names them and
      never prints a secret. `GHCR_TOKEN`, which `ehosctl install` pulls EHOS's image with, is
      reported as set or not.

  It exits 0 when every tool and `ssh` are there and at least one provider's account is seen, and
  1 otherwise, after printing the report either way. It installs nothing and changes nothing.
  """

  @behaviour Ehosctl.Command

  alias EhosPlatform.Server.Provider
  alias EhosPlatform.Tools
  alias Ehosctl.Output

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
  def call([], parsed, opts) do
    report = report(opts)
    output = %{text: text(report), json: report}

    if report.ready,
      do: {:ok, output},
      else: tap(1, fn _ -> Output.result(output, parsed.flags[:json] == true) end)
  end

  @doc """
  What `doctor` finds, as a map. `opts` replace what it reads, for tests: `:mise` (its path, or
  `false` for none), `:where` (runs `mise where`), `:find_executable`, `:env` (a function of a
  variable's name) and `:home`.
  """
  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    home = opts |> Keyword.get_lazy(:home, &System.user_home!/0) |> Path.expand()
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    tools = tools(mise(opts, find), Keyword.get(opts, :where, &where/2))
    ssh = if find.("ssh"), do: "found", else: "missing"
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

  defp mise(opts, find) do
    case Keyword.get_lazy(opts, :mise, fn -> find.("mise") end) do
      path when is_binary(path) -> path
      _none -> nil
    end
  end

  defp tools(nil, _where) do
    for tool <- Tools.all() do
      Map.merge(described(tool), %{state: "missing", install: "install mise: #{@mise_install}"})
    end
  end

  defp tools(mise, where) do
    for tool <- Tools.all() do
      case where.(mise, "#{tool.tool}@#{tool.version}") do
        {_path, 0} ->
          Map.merge(described(tool), %{state: "installed", install: nil})

        _missing ->
          Map.merge(described(tool), %{
            state: "missing",
            install: "mise install #{tool.tool}@#{tool.version}"
          })
      end
    end
  end

  defp described(tool), do: %{tool: tool.tool, program: tool.program, version: tool.version}

  # `mise where` answers where a version is installed, and fails, installing nothing, when it is
  # not.
  # sobelow_skip ["CI.System"]
  defp where(mise, spec), do: System.cmd(mise, ["where", spec], stderr_to_stdout: true)

  defp accounts(env, home) do
    [oci(env, home), aws(env, home), gcp(env, home)]
  end

  defp oci(env, home) do
    profile = present(env.("OCI_CLI_PROFILE")) || "DEFAULT"
    path = Path.join(home, ".oci/config")

    case File.read(path) do
      {:ok, contents} ->
        case Provider.parse_oci_config(contents, profile) do
          {:ok, %{region: region}} ->
            account("oci", "found", "profile #{profile} in ~/.oci/config, region #{region}")

          {:error, _reason} ->
            account(
              "oci",
              "incomplete",
              "~/.oci/config has no tenancy and region in [#{profile}]"
            )
        end

      {:error, _reason} ->
        account("oci", "none", "no ~/.oci/config")
    end
  end

  defp aws(env, home) do
    cond do
      present?(env.("AWS_ACCESS_KEY_ID")) ->
        account("aws", "found", "keys in AWS_ACCESS_KEY_ID")

      profile = present(env.("AWS_PROFILE")) ->
        account("aws", "found", "profile #{profile} (AWS_PROFILE)")

      Enum.any?(["credentials", "config"], &File.regular?(Path.join([home, ".aws", &1]))) ->
        account("aws", "found", "~/.aws, profile default unless --aws-profile")

      true ->
        account("aws", "none", "no AWS keys, profile or ~/.aws")
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
        account("gcp", "found", "#{credentials}, project #{project}")
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
end

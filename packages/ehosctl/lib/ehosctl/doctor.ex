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
    * **`psql`**, which `ehosctl db connect` starts, and whether it is 16 or later, which
      `require_auth` needs (`psql --version`; a `psql` is taken to use the `libpq` of its own
      version, as PostgreSQL's packages ship them). It is reported, and the verdict on the
      platform commands does not count it;
    * **the cloud accounts it can see**, as `ehosctl server up` will use them: the `DEFAULT`
      profile of `~/.oci/config` (or the one `--oci-profile` names), the AWS profile `AWS_PROFILE`
      names, else `default`, in `~/.aws` (keys in the environment are taken out of OpenTofu's,
      eh-os D-83), GCP's application credentials with the project `--gcp-project` names, else
      `GOOGLE_CLOUD_PROJECT`'s, and the entry of OpenStack's `clouds.yaml` that `OS_CLOUD` names,
      else `ovh`, for OVHcloud (eh-os D-127). It names them and never prints a secret;
    * **on GCP, with gcloud installed**, whether the credentials still give an access token
      (`gcloud auth application-default print-access-token`, whose token is never read), and,
      with a project, the effective organisation policies that would stop `server up`:
      `compute.requireOsLogin`, enforced, and `compute.vmExternalIpAccess`, denying the server a
      public address. gcloud reads the policies as its active account (`gcloud auth login`), not
      with the application default credentials. A policy it cannot read is reported with why,
      and stops nothing. These checks contact Google whenever gcloud is installed and GCP
      credentials are present. gcloud gives up on each request Google does not answer in 20
      seconds, which bounds a request, not a whole run of gcloud;
    * **the GitHub token `server up` reads EHOS's releases with** (`Ehosctl.GitHub.token/1`), by
      the variable it is in, and `GHCR_TOKEN`, which `ehosctl install` pulls EHOS's image with, as
      set or not.

  It exits 0 when every tool, `ssh` and the GitHub token are there and at least one provider's
  account is seen, and 1 otherwise, after printing the report either way. GCP credentials that
  give no access token, or a project whose policies stop `server up`, are not an account to use.
  It installs nothing and changes nothing (ehos-tools#657).
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.GitHub
  alias Ehosctl.Output
  alias Ehosctl.PlatformRunner
  alias EhosPlatform.Server.Provider
  alias EhosPlatform.Tools

  # A configuration file read is a few kilobytes; anything far larger is not one.
  @max_config 1024 * 1024

  @mise_install "https://mise.jdx.dev/installing-mise.html"

  # gcloud asks nothing, since nobody would answer, checks for no update of its own, and gives
  # up on each request Google does not answer in 20 seconds. That bounds a request, not a run:
  # gcloud can still make several, or stop for another reason.
  @gcloud_env [
    {"CLOUDSDK_CORE_DISABLE_PROMPTS", "1"},
    {"CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK", "1"},
    {"CLOUDSDK_CORE_HTTP_TIMEOUT", "20"}
  ]

  @policies ["compute.requireOsLogin", "compute.vmExternalIpAccess"]

  # GCP's form of a project ID, a domain-scoped one included. Anything else is never handed to
  # gcloud or put in a command to copy.
  @project_id ~r/\A(?:[a-z][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]\z/

  @impl Ehosctl.Command
  def name, do: :doctor

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Check that this machine has what the platform commands need."

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Check that this machine has what the platform commands need: OpenTofu, Helm and " <>
          "kubectl at the versions of EHOS, ssh, a cloud account and a GitHub token. It installs " <>
          "nothing.",
      options: [
        gcp_project: [
          long: "--gcp-project",
          value_name: "PROJECT",
          help:
            "The GCP project whose organisation policies doctor reads. By default " <>
              "GOOGLE_CLOUD_PROJECT."
        ]
      ],
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, _opts) do
    report = report(gcp_project: parsed.options[:gcp_project])
    output = %{text: text(report), json: report}

    if report.ready,
      do: {:ok, output},
      else: tap(1, fn _ -> Output.result(output, parsed.flags[:json] == true) end)
  end

  @doc """
  What `doctor` finds, as a map. The home directory to look in and the programs are
  `Ehosctl.OS`'s, the environment `Ehosctl.SystemEnv`'s, and gcloud runs through
  `Ehosctl.Runner`. `opts[:gcp_project]` is the GCP project, instead of `GOOGLE_CLOUD_PROJECT`'s.
  """
  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    system_env = Ehosctl.SystemEnv.current()
    env = &system_env.get/1
    os = Ehosctl.OS.current()
    home = Path.expand(os.home())
    tools = tools(os.find_executable("mise"))
    ssh = if os.find_executable("ssh"), do: "found", else: "missing"
    psql = psql(os.find_executable("psql"))
    project = present(opts[:gcp_project]) || present(env.("GOOGLE_CLOUD_PROJECT"))
    {gcp, gcp_policies} = gcp(env, home, project, os.find_executable("gcloud"))
    accounts = [oci(env, home), aws(env, home), gcp, ovh(env, home)]

    github_token_variable = github_token_variable(system_env.all())

    %{
      tools: tools,
      ssh: ssh,
      psql: psql,
      accounts: accounts,
      gcp_policies: gcp_policies,
      github_token: if(github_token_variable, do: "set", else: "not set"),
      github_token_variable: github_token_variable,
      ghcr_token: if(present?(env.("GHCR_TOKEN")), do: "set", else: "not set"),
      ready: ready?(tools, ssh, accounts, github_token_variable)
    }
  end

  # `require_auth`, which `ehosctl db connect` gives psql, came with libpq 16.
  defp psql(nil), do: %{state: "missing", version: nil}

  defp psql(path) do
    {out, status} = psql_version(path)

    case {status, Regex.run(~r/\(PostgreSQL\) ((\d+)(?:\.\d+)?)/, out)} do
      {0, [_all, version, major]} ->
        state = if String.to_integer(major) >= 16, do: "found", else: "too old"
        %{state: state, version: version}

      _other ->
        %{state: "unknown", version: nil}
    end
  end

  # A psql that cannot start, as one removed since it was found, raises (`c:Ehosctl.Runner.run/3`);
  # the report goes on without it.
  defp psql_version(path) do
    Ehosctl.Runner.current().run(path, ["--version"], [])
  rescue
    ErlangError -> {"", 1}
  end

  defp github_token_variable(env) do
    case GitHub.token(env) do
      {name, _token} -> name
      nil -> nil
    end
  end

  defp ready?(tools, ssh, accounts, github_token_variable) do
    Enum.all?(tools, &(&1.state == "installed")) and ssh == "found" and
      Enum.any?(accounts, &(&1.state == "found")) and github_token_variable != nil
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

  # The credentials `server up` hands OpenTofu, and the project it names (eh-os D-83), with what
  # gcloud says of them: whether they give an access token, and the organisation policies.
  defp gcp(env, home, project, gcloud) do
    case gcp_credentials(env, home) do
      nil ->
        {account("gcp", "none", "no application credentials"), []}

      # gcloud and OpenTofu use the variable, not the file gcloud's login left.
      {:not_a_file, path} ->
        {account(
           "gcp",
           "refused",
           "GOOGLE_APPLICATION_CREDENTIALS names #{shown(without_accounts(path))}, which is " <>
             "not a file; set it " <>
             "to a key file, or unset it to use gcloud's application default credentials"
         ), []}

      credentials ->
        if project && not Regex.match?(@project_id, project),
          do:
            {account(
               "gcp",
               "incomplete",
               "#{credentials}, but #{shown(project)} is not a GCP project id"
             ), []},
          else: gcp(credentials, project, gcloud)
    end
  end

  defp gcp(credentials, nil = _project, gcloud) do
    if gcloud && access_token(gcloud) == :refused,
      do: {refused(credentials), []},
      else:
        {account(
           "gcp",
           "incomplete",
           "#{credentials}, but no --gcp-project or GOOGLE_CLOUD_PROJECT"
         ), []}
  end

  defp gcp(credentials, project, nil = _gcloud) do
    detail =
      "#{credentials}, project #{shown(project)}; gcloud is not installed, so they are not checked"

    policies =
      for constraint <- @policies,
          do: policy(constraint, "unknown", "not checked: gcloud is not installed")

    {account("gcp", "found", detail), policies}
  end

  defp gcp(credentials, project, gcloud) do
    case access_token(gcloud) do
      :ok ->
        gcp_policies("#{credentials}, project #{shown(project)}", project, gcloud)

      :refused ->
        {refused(credentials), []}

      {:unchecked, reason} ->
        gcp_policies(unchecked(credentials, project, reason), project, gcloud)
    end
  end

  defp unchecked(credentials, project, reason),
    do: "#{credentials}, project #{shown(project)}; could not check them: #{reason}"

  defp gcp_policies(described, project, gcloud) do
    # Both at once, so a slow answer is waited for once, on any number of schedulers.
    policies =
      @policies
      |> Task.async_stream(&read_policy(gcloud, project, &1),
        max_concurrency: length(@policies),
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, policy} -> policy end)

    if Enum.any?(policies, &(&1.state == "blocks")),
      do:
        {account(
           "gcp",
           "blocked",
           "#{described}, but an organisation policy stops `ehosctl server up`"
         ), policies},
      else: {account("gcp", "found", described), policies}
  end

  defp gcp_credentials(env, home) do
    adc = Path.join(home, ".config/gcloud/application_default_credentials.json")

    path = present(env.("GOOGLE_APPLICATION_CREDENTIALS"))

    cond do
      path && File.regular?(path) ->
        "GOOGLE_APPLICATION_CREDENTIALS"

      path ->
        {:not_a_file, path}

      File.regular?(adc) ->
        "gcloud's application default credentials"

      true ->
        nil
    end
  end

  # gcloud prints the token on success; it is never read, so it cannot be printed. A failed run
  # prints no token. It is refused only when gcloud says the credentials are: no network, a proxy
  # or a broken gcloud says nothing of them.
  defp access_token(gcloud) do
    {output, status} =
      Ehosctl.Runner.current().run(
        gcloud,
        ["auth", "application-default", "print-access-token"],
        env: @gcloud_env
      )

    cond do
      status == 0 -> :ok
      refusal?(output) -> :refused
      true -> {:unchecked, first_line(without_token(output))}
    end
  end

  # gcloud may have printed a token before it failed: its ERROR line is the reason, else any line
  # that looks like a token is left out.
  defp without_token(output) do
    lines = String.split(output, ~r/\R/, trim: true)

    case Enum.find(lines, &String.starts_with?(String.trim_leading(&1), "ERROR:")) do
      nil -> lines |> Enum.reject(&(&1 =~ ~r/ya29\.|[A-Za-z0-9_-]{40,}/)) |> Enum.join("\n")
      error -> error
    end
  end

  # A transport failure says nothing of the credentials, even while gcloud refreshes them, so it
  # is looked for first.
  defp refusal?(output) do
    output = String.downcase(output)

    not String.contains?(output, [
      "connection",
      "timed out",
      "transporterror",
      "max retries",
      "name resolution",
      "proxy",
      "ssl"
    ]) and
      String.contains?(output, [
        "invalid_grant",
        "invalid_client",
        "invalid_rapt",
        "reauthentication",
        "could not automatically determine credentials",
        "token has been expired or revoked"
      ])
  end

  defp refused("GOOGLE_APPLICATION_CREDENTIALS"),
    do:
      account(
        "gcp",
        "refused",
        "the key GOOGLE_APPLICATION_CREDENTIALS names gives no access token; replace it, or " <>
          "unset GOOGLE_APPLICATION_CREDENTIALS and run `gcloud auth application-default login`"
      )

  defp refused(credentials),
    do:
      account(
        "gcp",
        "refused",
        "#{credentials} give no access token; renew them with " <>
          "`gcloud auth application-default login`"
      )

  # The policy in effect for the project, its organisation's and folders' included.
  defp read_policy(gcloud, project, constraint) do
    {output, status} =
      Ehosctl.Runner.current().run(
        gcloud,
        [
          "org-policies",
          "describe",
          constraint,
          "--project=#{project}",
          "--effective",
          "--format=json",
          "--verbosity=error"
        ],
        env: @gcloud_env
      )

    judged(constraint, project, status, output)
  end

  # A warning gcloud writes to stderr comes before the policy, since the runner merges them.
  defp judged(constraint, project, 0, output) do
    json =
      case :binary.match(output, "{") do
        {start, _length} -> binary_part(output, start, byte_size(output) - start)
        :nomatch -> output
      end

    case JSON.decode(json) do
      {:ok, %{} = policy} -> judged(constraint, project, rules(policy))
      _other -> policy(constraint, "unknown", "not checked: gcloud's answer is not JSON")
    end
  end

  # Every error of the API names it as the service, so only the words for an API that is off
  # say that it is.
  defp judged(constraint, project, _status, output) do
    reason =
      if String.contains?(output, ["SERVICE_DISABLED", "API has not been used"]),
        do:
          "the Organization Policy API is off in project #{shown(project)}; turn it on with " <>
            "`gcloud services enable orgpolicy.googleapis.com --project=#{shown(project)}`",
        else: first_line(output)

    policy(constraint, "unknown", "not checked as gcloud's active account: #{reason}")
  end

  # A rule under a condition counts as one in force: `server up` cannot tell whether it applies.
  defp judged("compute.requireOsLogin" = constraint, project, rules) do
    if Enum.any?(rules, &match?(%{"enforce" => true}, &1)),
      do:
        policy(
          constraint,
          "blocks",
          "enforced, so the server admits only OS Login users and `ehosctl server up` waits " <>
            "for SSH that never admits its key; #{lift(project)}"
        ),
      else: policy(constraint, "allows", "not enforced")
  end

  # Only an `allowAll` with no condition surely applies; a `denyAll` under one may. Allowed
  # values name the instances that may have a public address, which an administrator can make
  # the server's, so they stop nothing, but are said.
  defp judged("compute.vmExternalIpAccess" = constraint, project, rules) do
    cond do
      Enum.any?(rules, &(&1["allowAll"] == true and not is_map_key(&1, "condition"))) ->
        policy(constraint, "allows", "allows a public address")

      Enum.any?(rules, &match?(%{"denyAll" => true}, &1)) ->
        policy(
          constraint,
          "blocks",
          "denies the server a public address, so `ehosctl server up` cannot make it; " <>
            lift(project)
        )

      Enum.any?(rules, &match?(%{"values" => %{"allowedValues" => [_ | _]}}, &1)) ->
        policy(
          constraint,
          "limits",
          "allows a public address only to the instances it lists; it must list " <>
            "projects/#{shown(project)}/zones/<zone>/instances/ehos-<installation>, or " <>
            "`ehosctl server up` cannot make the server"
        )

      true ->
        policy(constraint, "allows", "allows a public address")
    end
  end

  defp rules(%{"spec" => %{"rules" => rules}}) when is_list(rules),
    do: Enum.filter(rules, &is_map/1)

  defp rules(_policy), do: []

  defp lift(project),
    do: "ask an organisation administrator to lift it for project #{shown(project)}"

  # gcloud's first line, without the account it names: a report is shared to ask for help.
  defp first_line(output) do
    line =
      output
      |> String.split(~r/\R/, trim: true)
      |> Enum.find("gcloud gave no reason", &(String.trim(&1) != ""))
      |> String.replace(~r/\s*\(?authenticated as [^\s)]*\)?/i, "")
      |> without_accounts()
      |> String.trim()
      |> String.slice(0, 300)

    shown(line)
  end

  # An email address, such as a key file named after its service account, is not shown.
  defp without_accounts(text),
    do: String.replace(text, ~r/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/, "an account")

  defp policy(constraint, state, detail),
    do: %{constraint: constraint, state: state, detail: detail}

  defp account(provider, state, detail), do: %{provider: provider, state: state, detail: detail}

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp present?(value), do: present(value) != nil

  defp psql_text(%{state: "found", version: version}), do: version

  defp psql_text(%{state: "too old", version: version}),
    do:
      "#{version}: too old. Install psql 16 or later, or use `ehosctl db tunnel` with another client."

  defp psql_text(%{state: "missing"}),
    do: "missing. Install psql 16 or later, or use `ehosctl db tunnel` with another client."

  defp psql_text(%{state: "unknown"}),
    do: "found, but `psql --version` says no version that ehosctl can read."

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

    policies =
      for policy <- report.gcp_policies do
        "  #{mark(policy.state == "allows")} #{policy.constraint}: #{policy.detail}"
      end

    policies = if policies == [], do: [], else: ["", "GCP organisation policies:" | policies]

    github_token =
      if report.github_token_variable,
        do: "set in #{report.github_token_variable}",
        else:
          "not set. Set MISE_GITHUB_TOKEN or GITHUB_TOKEN, for example to the output of " <>
            "`gh auth token`."

    verdict =
      if report.ready,
        do: "Ready for `ehosctl server up`.",
        else: "Not ready. Install or set what is missing, then run `ehosctl doctor` again."

    Enum.join(
      ["Tools, at the versions that EHOS is tested with:"] ++
        tools ++
        ["  #{mark(report.ssh == "found")} ssh: #{report.ssh}", "", "Cloud accounts:"] ++
        accounts ++
        policies ++
        [
          "",
          "GitHub token, for the releases of EHOS: #{github_token}",
          "GHCR_TOKEN, for `ehosctl install`: #{report.ghcr_token}",
          "",
          "For `ehosctl db connect`:",
          "  #{mark(report.psql.state == "found")} psql #{psql_text(report.psql)}",
          "",
          verdict
        ],
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

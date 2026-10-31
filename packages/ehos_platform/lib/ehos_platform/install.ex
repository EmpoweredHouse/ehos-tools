defmodule EhosPlatform.Install do
  @moduledoc """
  Installs EHOS into a Kubernetes cluster named by a kubeconfig context (D-79): the code that
  `mix ehos.cluster up` runs after it creates k3d, and that `mix ehos.install` runs on a server.

  An installation is two steps (D-30): the prerequisite releases, then the distribution chart.

    * `prerequisites/1` installs CloudNativePG (D-30), cert-manager, trust-manager (D-59) and
      Traefik (D-117) at their pinned versions, on a cluster where k3s's bundled Traefik does not
      run;
    * `certificate_authority/1` makes the installation's own CA, whose name constraints and
      admission policy admit the console's host and the names under it alone (D-45, D-62);
    * `name_in_cluster/1` gives pods the console's host and every name under it, so they reach
      the console and applications through the ingress without leaving the cluster (D-45);
    * `chart/2` installs or upgrades the chart and waits until the console's certificate is
      issued.

  The CA and the CoreDNS rule are this package's `priv/manifests/local-ca.yaml` and
  `priv/manifests/coredns-custom.yaml`, written for `ehos.localhost` and rendered with the target's
  host, which for `ehos.localhost` changes nothing, so the local cluster runs the rendering a server
  runs. The chart comes from the target's `EhosPlatform.Source`: a checkout's directory, packaged
  here, or a release's chart by digest (eh-os D-92).

  Every `helm` and `kubectl` call names the target's context, and its kubeconfig when it has one,
  so no other cluster is ever touched. Everything runs through `EhosPlatform.CommandRunner`, and
  the environment and waits go through `EhosPlatform.Env` and `EhosPlatform.Clock` (T-20).
  """

  alias EhosPlatform.ClockImpl
  alias EhosPlatform.CommandRunnerImpl
  alias EhosPlatform.Env
  alias EhosPlatform.Server
  alias EhosPlatform.Source
  alias EhosPlatform.TmpDir

  @local_ca "local-ca.yaml"
  @coredns_custom "coredns-custom.yaml"
  @external_names "external-names.yaml"
  @addresses_namespace_manifest "addresses-namespace.yaml"
  # eh-os D-117: the namespaces where an `ExternalName` Service is admitted (`@external_names`).
  @external_name_namespaces ["ehos-addresses", "ehos-ingress"]
  @ingress_shim "cert-manager-ingress-shim"
  # The annotation on CoreDNS's pod template that holds the hash of the rule its pods took.
  @coredns_rule "ehos.empowered.house/coredns-rule"
  @local_host "ehos.localhost"
  @namespace "ehos-system"

  # D-30: CloudNativePG is a prerequisite release, pinned here, by the digest of its OCI chart as
  # the other two are (eh-os#220): the same chart as the HTTPS repository's 0.29.1, compared file by
  # file.
  @cnpg_version "0.29.1"
  @cnpg_chart "oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg@sha256:3245fa051bb21d0dd9246272f57a2760b4234817a164a3167d2a1e7fb9f63fd9"

  # D-45: cert-manager is a prerequisite of an installation, not of the chart. Its chart is pulled
  # by the digest of v1.21.2's OCI artifact, so what installs is exactly what was checked.
  @cert_manager_version "v1.21.2"
  @cert_manager_chart "oci://quay.io/jetstack/charts/cert-manager@sha256:634dce9c13b56677a2c05e2ab76c312d0be2664022d5dd05815da67e1fd5f610"
  @cert_manager_namespace "cert-manager"

  # D-59: trust-manager copies the data CA's certificate, and EHOS's, into every environment's
  # namespace. Its trust namespace is cert-manager's, where the data CA's key is kept; it writes
  # ConfigMaps only, and installs no public trust bundle, which nothing here uses.
  @trust_manager_version "v0.25.0"
  @trust_manager_chart "oci://quay.io/jetstack/charts/trust-manager@sha256:ef4540d4c3b7eb8cd498e3420aa5171ccc7434b7fa5e3168f1218d22906dbecb"

  # eh-os D-117: Traefik is a prerequisite EHOS installs, in a namespace of its own, rather than
  # the one k3s bundles: its version is EHOS's, pinned by the digest of its OCI chart as the others
  # are. The chart's Traefik is 3.7.14; the image is 3.7.15, for the three advisories it fixes, by
  # the digest of its index.
  @traefik_version "42.0.0"
  @traefik_chart "oci://ghcr.io/traefik/helm/traefik@sha256:779f04f7aa930daddba2aacf0f4a75c8d83cac477c00996372680b61fdf423aa"
  @traefik_image "v3.7.15@sha256:0f6150202bc1fed72a7bd2107460eaa510e5b8a905f3fdb5b84f2c8619c33368"
  @ingress_namespace "ehos-ingress"
  # eh-os D-117: where EHOS keeps applications' addresses, which Traefik reads beside its own.
  @addresses_namespace "ehos-addresses"

  # eh-os D-143: every prerequisite's pods run as Kubernetes' own class, which the kubelet, short
  # of memory, never evicts; k3s admits it in any namespace. Traefik always did. CloudNativePG's,
  # cert-manager's and trust-manager's ran as none and requested nothing, so they went first,
  # before EHOS's own pods (`ehos-platform`, 1000000), which depend on them
  # (ehos-tools#500).
  @critical "system-cluster-critical"

  # D-62: the CA's Certificate and Secret, in cert-manager's namespace, and the ClusterIssuer that
  # signs from it.
  @ca_name "ehos-local-ca"
  @tls_secret "ehos-governance-tls"
  # D-55: the pull credential for a private registry, in EHOS's namespace.
  @pull_credential "ehos-pull-credential"
  # eh-os D-36: the SMTP server's password, in EHOS's namespace, which the chart names.
  @smtp_secret "ehos-smtp"
  # On that Secret while the governance plane still reads the password before it, so a run that
  # failed after writing it restarts the plane on the next.
  @restart_pending "ehos.empowered.house/restart"

  # How the operator runs the server's commands, and names an installation in them, for the
  # sentences that name them.
  @server_command "mix ehos.server"
  @name_option "--name"

  @enforce_keys [:context, :host, :source]
  defstruct @enforce_keys ++
              [
                kubeconfig: nil,
                runner: CommandRunnerImpl,
                progress: &__MODULE__.quiet/1,
                clock: ClockImpl,
                server_command: @server_command
              ]

  @typedoc "The cluster EHOS is installed into, and the console's host there."
  @type t :: %__MODULE__{
          context: String.t(),
          host: String.t(),
          source: Source.t(),
          kubeconfig: Path.t() | nil,
          runner: module(),
          progress: (String.t() -> any()),
          clock: module(),
          server_command: String.t()
        }

  @doc false
  def quiet(_line), do: :ok

  # A required option, refused by its name alone: the options can hold the token, the passphrase,
  # the SMTP password or `:registry_auth`, and the `KeyError` of `Keyword.fetch!/2` holds every
  # one of them (ehos-tools#543). This one holds the key alone, which `ehosctl` prints.
  defp required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key
    end
  end

  @doc "The CA's name, which is also its `ClusterIssuer`'s and its Secret's."
  @spec ca_name() :: String.t()
  def ca_name, do: @ca_name

  @typedoc """
  The outcome of a command: `{:ok, message}` saying what was done, or `{:error, message}` saying
  why it was not, each a sentence an operator can act on.
  """
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @registry "ghcr.io"
  @repository "ghcr.io/empoweredhouse/ehos"

  @doc """
  Installs, or upgrades, EHOS on an installation's server (`mix ehos.install`), through the
  kubeconfig `mix ehos.server tunnel` wrote in `~/.ehos/<name>` and its context `ehos-<name>`.

  The console's host is `ehos.<a-b-c-d>.sslip.io`, from the address the tunnel goes to, so no
  domain is needed: sslip.io answers every name under it with that address. The image is the
  published one, by digest, from GHCR, whose packages are private: the pull credential is written
  from `GHCR_TOKEN`, a classic token with `read:packages` alone, and kept in the cluster, so a
  later run needs no token unless it replaces it.

  A server made before EHOS installed its own Traefik runs k3s's, and is switched, with
  `:switch_traefik` alone, since it takes the console and its applications down for a few minutes
  (eh-os D-117, [eh-os#823](https://github.com/EmpoweredHouse/eh-os/issues/823)); without it,
  nothing is changed. What could still refuse is decided first. Then, over SSH at the address the
  tunnel goes to, k3s's configuration is given a drop-in that disables its Traefik, and k3s
  restarted, which takes its Traefik, its CRDs and every Traefik route out; once the cluster says
  they are gone, EHOS's Traefik and the chart are installed as on any server. The SSH needs the
  state's passphrase and the key the server was made with, as the server's commands do.

  Once the chart is installed, each PostgreSQL cluster whose pods do not run with the priority
  class it gives is restarted, one at a time (`restart_outdated_databases/1`): the console, or an
  instance's applications, are down until its new pod is ready.

  ## Options

    * `:digest` — the image's digest, `sha256:…`: the index CI published (required).
    * `:source` — what is installed, an `EhosPlatform.Source` (required).
    * `:name` and `:home` — the installation, as for `EhosPlatform.Server`. Default to `trial` and
      `~/.ehos`.
    * `:host` — the console's host, instead of the one the tunnel's address gives.
    * `:sign_in` — how long a sign-in to an application lasts (eh-os D-113): a map of
      `"absolute"` and `"idle"`, each in hours or days (`"30d"`), written into the chart's
      `governance.signIn`. A key left out is the chart's default; none, both are (12h and 1h).
    * `:four_eyes` — whether a promotion to production needs a second person (eh-os D-105):
      `true` or `false`, written into the chart's `governance.promotion.fourEyes`. None leaves it
      to the chart: on before EHOS 0.14.0; from it, what the running EHOS has, off for a new
      installation and on where the chart cannot tell (eh-os D-128).
    * `:mail` — the SMTP server EHOS sends mail through (eh-os D-36): a map of `"from"` and
      `"smtp"`, itself of `"host"`, `"port"` and, when it authenticates, `"username"`, written into
      the chart's `governance.mail`. None: EHOS sends no mail. TLS stays on and verified.
    * `:smtp_password` — the SMTP user's password, written into the Secret `#{@smtp_secret}` the
      chart reads it from. Without it, the one the cluster holds is kept; a `:mail` with a
      `"username"` and neither is refused before anything changes.
    * `:installed` — what is installed, as `installed/1` reads it back: a map of `version`,
      `image` and `chart`, written into the Helm release's values (eh-os D-92). None writes none.
    * `:server_command` — how the operator runs the server's commands, for the sentences that
      name them: `mix ehos.server` unless given (`ehosctl server` for `ehosctl`).
    * `:name_option` and `:name_in_commands` — as for `EhosPlatform.Server`: whether a command
      those sentences suggest names the installation, and with which option (`--name` unless
      given). Defaults to false.
    * `:token` — the pull credential's token. Defaults to `GHCR_TOKEN`.
    * `:username` — the GitHub user the token belongs to. Defaults to `GHCR_USERNAME`, or the
      GitHub CLI's user.
    * `:switch_traefik` — `true` to switch a server that runs k3s's Traefik, above.
    * `:passphrase` and `:ssh_key` — for the switch, as for `EhosPlatform.Server`. The passphrase
      defaults to `EHOS_STATE_PASSPHRASE`, the key to `~/.ssh/ehos_oci`.
    * `:progress`, `:runner`, `:env` and `:clock` — as for `EhosPlatform.Server`.
  """
  @spec server(keyword()) :: result()
  def server(opts) do
    # Install waits, and asks for no address.
    Server.check_options!(opts, [:sleep])
    # Before anything is read or run, as `Server.check_options!/2` refuses.
    _source = required!(opts, :source)
    name = Keyword.get(opts, :name, "trial")

    if Server.valid_name?(name),
      do: install_server(name, opts),
      else: {:error, Server.name_rule()}
  end

  defp install_server(name, opts) do
    dir = opts |> Keyword.get(:home, "~/.ehos") |> Path.expand() |> Path.join(name)
    runner = Keyword.get(opts, :runner, CommandRunnerImpl)
    progress = Keyword.get(opts, :progress, &quiet/1)
    server_command = Keyword.get(opts, :server_command, @server_command)
    tunnel = tunnel_command(opts)
    ca_file = Path.join(dir, "ca.crt")

    with {:ok, digest} <- digest(Keyword.get(opts, :digest)),
         :ok <- traefik_serves(Keyword.get(opts, :installed)),
         {:ok, kubeconfig} <- kubeconfig(dir, tunnel),
         {:ok, host} <- host(opts, dir, tunnel),
         target = %__MODULE__{
           context: "ehos-#{name}",
           host: host,
           source: Keyword.get(opts, :source),
           kubeconfig: kubeconfig,
           runner: runner,
           progress: progress,
           clock: Keyword.get(opts, :clock, ClockImpl),
           server_command: server_command
         },
         :ok <- reachable(target, tunnel),
         # eh-os#823: what refuses is decided before k3s's Traefik is switched out, which takes
         # the console down until the chart is installed again.
         {:ok, switch} <- traefik_switch(target, dir, opts),
         {:ok, smtp_password} <- smtp_password(target, opts),
         {:ok, registry_auth} <- credential(target, opts),
         :ok <- smtp_written(target, smtp_password),
         {:ok, installation} <- Server.description(dir, name),
         :ok <- switch_server(target, switch, opts),
         :ok <- prerequisites(target),
         :ok <- certificate_authority(target),
         :ok <- name_in_cluster(target),
         {:ok, pem} <- ca_pem(target),
         :ok <- write_file(ca_file, pem),
         :ok <-
           chart(target,
             repository: @repository,
             digest: digest,
             ca_file: ca_file,
             allowed_image_prefixes: ["ghcr.io/empoweredhouse/"],
             pull_credential?: true,
             own_pull_credential?: true,
             installation: installation,
             installed: Keyword.get(opts, :installed),
             sign_in: Keyword.get(opts, :sign_in),
             four_eyes: Keyword.get(opts, :four_eyes),
             mail: Keyword.get(opts, :mail),
             registry_auth: registry_auth
           ),
         :ok <-
           write_file(
             Path.join(dir, "install.json"),
             Jason.encode_to_iodata!(
               %{"digest" => digest, "host" => host, "repository" => @repository},
               pretty: true
             )
           ),
         # After what runs is recorded: a restart that fails leaves the record true, and the
         # Secret marked, so the next run restarts the plane again. The databases first, so the
         # plane restarts against a database that is up.
         :ok <- restart_outdated_databases(target),
         :ok <- restart_for_password(target, smtp_password) do
      {:ok,
       "EHOS is running at https://#{host} (image #{@repository}@#{digest}). Its certificate " <>
         "is signed by the installation's CA, in #{ca_file}: trust it to open the console " <>
         "without a warning. Invite a person with #{suggested(opts, "invite <their email>")}, " <>
         "which prints the link that signs them in: the first one " <>
         "invited while nobody is the platform's administrator becomes it."}
    end
  end

  # eh-os D-117 (eh-os#846): the Traefik `prerequisites/1` installs reads only `ehos-ingress` and
  # `ehos-addresses`. An EHOS before this keeps its console's route and its applications' HSTS in
  # `ehos-system`, which that Traefik would not serve.
  @traefik_namespaced_since "0.17.0"

  @doc """
  `:ok` unless `installed`, what `server/1` installs, is an EHOS release before
  #{@traefik_namespaced_since}, whose console the Traefik installed here would not serve (eh-os
  D-117). What names no version, a build of a checkout, is not judged.
  """
  @spec traefik_serves(map() | nil) :: :ok | {:error, String.t()}
  def traefik_serves(%{"version" => version}) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} ->
        if Version.compare(parsed, Version.parse!(@traefik_namespaced_since)) == :lt,
          do:
            {:error,
             "EHOS #{version} keeps its console's route where the Traefik this installer " <>
               "installs no longer reads (eh-os D-117): its console would not answer. Install " <>
               "#{@traefik_namespaced_since} or later. Nothing was changed"},
          else: :ok

      :error ->
        :ok
    end
  end

  def traefik_serves(_installed), do: :ok

  # D-79: the installation's CA certificate and what it runs, `install.json`, are kept beside its
  # other files, so the next upgrade starts from them.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_file(path, contents) do
    case File.write(path, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{path} cannot be written: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  The image's digest when it is one, `sha256:` and 64 hex digits, as CI publishes it; checked
  before anything uses it, `mix ehos.server.check` among them, before it makes a server.
  """
  @spec digest(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def digest(digest) when is_binary(digest) do
    if digest =~ ~r/\Asha256:[0-9a-f]{64}\z/,
      do: {:ok, digest},
      else: {:error, "--digest must be sha256: and 64 hex digits, the index CI published"}
  end

  def digest(nil),
    do:
      {:error,
       "Give --digest: the image's index, as `sha256:…`, from the summary of CI's Publish index " <>
         "job on main"}

  @typedoc """
  The SMTP server EHOS sends mail through (eh-os D-36), as the chart's `governance.mail` holds it,
  without the password: the sender, and the server's host, port and the user it authenticates as,
  when it does.
  """
  @type mail :: %{
          String.t() => String.t() | %{String.t() => String.t() | pos_integer()}
        }

  @typedoc """
  What runs on an installation's server, as `installed/1` reads it from the Helm release:

    * `:running` — `:none` where no revision of EHOS was ever deployed, `:unknown` where one was by
      something that recorded nothing, such as `mix ehos.install` before eh-os Stage 13, or what
      `server/1` recorded: a map of `"version"`, `"image"` and `"chart"`;
    * `:digest` — the image's digest that revision runs, `sha256:…`, or `nil`;
    * `:host` — the console's host that revision serves, or `nil`;
    * `:sign_in` — the sign-in limits that revision was given (eh-os D-113), a map of `"absolute"`
      and/or `"idle"` in hours or days, or `nil` when it was given none and runs the chart's;
    * `:four_eyes` — whether that revision's promotions need a second person (eh-os D-105), as
      its `governance.promotion.fourEyes` says, however it was set; `nil` when it was given none
      and runs the chart's;
    * `:four_eyes_runs` — whether they need one as that revision's server runs, given or decided
      by the chart (eh-os D-128), from what the revision applied; `nil` when it does not say, as
      an EHOS before 0.9.0, or could not be read;
    * `:mail` — the SMTP server that revision sends mail through (eh-os D-36), as `server/1`'s
      `:mail` takes it, without the password, which stays in its Secret; `nil` when it sends none,
      and `:unreadable` when its settings are not ones `server/1` writes;
    * `:last` — the release's last revision when it is not the one that runs: its `:revision`,
      `:status` (`failed`, `pending-upgrade`, …) and Helm's `:description` of it; else `nil`.
  """
  @type installed :: %{
          running: :none | :unknown | %{String.t() => String.t()},
          digest: String.t() | nil,
          host: String.t() | nil,
          sign_in: %{optional(String.t()) => String.t()} | nil,
          four_eyes: boolean() | nil,
          four_eyes_runs: boolean() | nil,
          mail: mail() | :unreadable | nil,
          last: %{revision: pos_integer(), status: String.t(), description: String.t()} | nil
        }

  @doc """
  What runs on an installation's server (`t:installed/0`), as `server/1` recorded it in the Helm
  release's values (eh-os D-92), read through the kubeconfig `tunnel` wrote: never through EHOS's
  API, which needs a credential.

  It is read from the release's last *deployed* revision, found in its history: the last revision
  may be one that failed, or one still pending, and its values say what was asked, not what runs.
  That revision is then `:last`.

  Options as `server/1`'s: `:name`, `:home`, `:runner`, `:server_command`, `:name_option`,
  `:name_in_commands`.
  """
  @spec installed(keyword()) :: {:ok, installed()} | {:error, String.t()}
  def installed(opts) do
    name = Keyword.get(opts, :name, "trial")
    dir = opts |> Keyword.get(:home, "~/.ehos") |> Path.expand() |> Path.join(name)
    runner = Keyword.get(opts, :runner, CommandRunnerImpl)

    with true <- Server.valid_name?(name) || {:error, Server.name_rule()},
         {:ok, kubeconfig} <-
           kubeconfig(dir, tunnel_command(opts)) do
      release = [
        "ehos",
        "--namespace",
        @namespace,
        "--kube-context",
        "ehos-#{name}",
        "--kubeconfig",
        kubeconfig
      ]

      # `helm get manifest` has no `--output`: it is given only to the calls that take it.
      on_release = release ++ ["--output", "json"]

      case history(runner, on_release, opts) do
        {:ok, []} -> {:ok, nothing_running(nil)}
        {:ok, revisions} -> from_revisions(revisions, runner, release, on_release, opts)
        error -> error
      end
    end
  end

  defp from_revisions(revisions, runner, release, on_release, opts) do
    deployed = revisions |> Enum.filter(&(&1.status == "deployed")) |> List.last()
    last = List.last(revisions)
    last = if last != deployed, do: last

    case deployed do
      nil ->
        {:ok, nothing_running(last)}

      %{revision: revision} ->
        with {:ok, values} <- values(runner, on_release, revision, opts) do
          {:ok,
           values
           |> recorded()
           |> Map.put(:four_eyes_runs, four_eyes_runs(runner, release, revision))
           |> Map.put(:last, last)}
        end
    end
  end

  defp nothing_running(last) do
    %{
      running: :none,
      digest: nil,
      host: nil,
      sign_in: nil,
      four_eyes: nil,
      four_eyes_runs: nil,
      mail: nil,
      last: last
    }
  end

  # The release's revisions, oldest first; none when there is no release.
  defp history(runner, on_release, opts) do
    case runner.run("helm", ["history" | on_release]) do
      {output, 0} ->
        case last_json(output) do
          {:ok, revisions} when is_list(revisions) ->
            revisions(revisions, output)

          _other ->
            {:error,
             "`helm history` gave something other than the release's revisions:\n" <> output}
        end

      {output, status} = result when is_integer(status) ->
        if String.contains?(output, "release: not found"),
          do: {:ok, []},
          else: tunnel_hint(failure("helm", result), opts)

      result ->
        failure("helm", result)
    end
  end

  defp revisions(listed, output) do
    revisions =
      for %{"revision" => revision, "status" => status} = listed <- listed,
          is_integer(revision) and revision > 0 and is_binary(status) do
        description = listed["description"]

        %{
          revision: revision,
          status: status,
          description: if(is_binary(description), do: description, else: "")
        }
      end

    if length(revisions) == length(listed),
      do: {:ok, Enum.sort_by(revisions, & &1.revision)},
      else: {:error, "`helm history` gave a revision without its number or status:\n" <> output}
  end

  defp values(runner, on_release, revision, opts) do
    case runner.run("helm", ["get", "values" | on_release] ++ ["--revision", "#{revision}"]) do
      {output, 0} ->
        case last_json(output) do
          {:ok, values} when is_map(values) or is_nil(values) ->
            {:ok, values || %{}}

          _other ->
            {:error,
             "`helm get values` gave something other than the release's values:\n" <> output}
        end

      {_output, status} = result when is_integer(status) ->
        tunnel_hint(failure("helm", result), opts)

      result ->
        failure("helm", result)
    end
  end

  # eh-os D-128, ehos-tools#350: what the revision gave the governance plane's server, which the
  # chart decides when no value is given, from the objects it applied. Not read, it is not said:
  # what runs is still upgraded.
  defp four_eyes_runs(runner, release, revision) do
    with {output, 0} <-
           runner.run("helm", ["get", "manifest" | release] ++ ["--revision", "#{revision}"]),
         [_line, value] <-
           Regex.run(~r/- name: EHOS_PROMOTION_FOUR_EYES\n\s+value: "(true|false)"/, output) do
      value == "true"
    else
      _unsaid -> nil
    end
  end

  defp tunnel_hint({:error, message}, opts),
    do: {:error, message <> "\nIs the tunnel open? #{tunnel_command(opts)} opens it."}

  # The command that opens the tunnel, quoted, as the operator runs the server's commands
  # (`:server_command`), and naming the installation when the caller asks (`:name_in_commands`):
  # without it, the command reaches whichever installation is the operator's default.
  defp tunnel_command(opts), do: suggested(opts, "tunnel")

  # A command of the server's to suggest, quoted, built as `tunnel_command/1` says.
  defp suggested(opts, subcommand) do
    command = Keyword.get(opts, :server_command, @server_command)

    named =
      if Keyword.get(opts, :name_in_commands, false),
        do:
          " #{Keyword.get(opts, :name_option, @name_option)} #{Keyword.get(opts, :name, "trial")}",
        else: ""

    "`#{command} #{subcommand}#{named}`"
  end

  # helm prints its answer as one line of JSON, `null` for no values, among any warnings it gives:
  # the last line that is JSON is it.
  defp last_json(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn line ->
      case Jason.decode(line) do
        {:ok, value} -> {:ok, value}
        {:error, _} -> nil
      end
    end)
  end

  defp recorded(values) do
    %{
      running: running(values),
      digest: recorded_digest(at(values, ["image", "digest"])),
      host: recorded_host(at(values, ["governance", "host"])),
      sign_in: sign_in(values),
      four_eyes: four_eyes(values),
      mail: mail(values)
    }
  end

  defp running(%{"installed" => %{"version" => v, "image" => i, "chart" => c} = installed})
       when is_binary(v) and is_binary(i) and is_binary(c),
       do: Map.take(installed, ["version", "image", "chart"])

  defp running(_nothing), do: :unknown

  defp recorded_digest(digest) when is_binary(digest),
    do: if(digest =~ ~r/\Asha256:[0-9a-f]{64}\z/, do: digest)

  defp recorded_digest(_none), do: nil

  defp recorded_host(host) when is_binary(host),
    do: if(match?({:ok, _}, host(host)), do: host)

  defp recorded_host(_none), do: nil

  # eh-os D-105: read as the chart reads it, so a value set by hand with `helm --set`, as an
  # installation of one person had to before ehos-tools#296, is kept too: only `false` turns four
  # eyes off, anything else keeps them on.
  defp four_eyes(values) do
    case at(values, ["governance", "promotion", "fourEyes"]) do
      nil -> nil
      value -> value not in [false, "false"]
    end
  end

  # eh-os D-113: what `server/1` wrote, each value as the chart takes it; anything else is not
  # carried into the next install, which then runs the chart's default for it.
  defp sign_in(values) do
    case at(values, ["governance", "signIn"]) do
      %{} = given ->
        limits =
          for {key, value} <- given,
              key in ["absolute", "idle"],
              is_binary(value) and sign_in_limit?(value),
              into: %{},
              do: {key, value}

        if limits == %{}, do: nil, else: limits

      _none ->
        nil
    end
  end

  @doc """
  Whether `value` is a sign-in limit the chart takes (eh-os D-113): whole hours or days, `12h` or
  `30d`, at most four digits.
  """
  @spec sign_in_limit?(String.t()) :: boolean()
  def sign_in_limit?(value) when is_binary(value), do: value =~ ~r/\A[1-9][0-9]{0,3}[hd]\z/
  def sign_in_limit?(_value), do: false

  # eh-os D-36: what `server/1` wrote, as the chart takes it, the port the chart's 587 where none
  # was written; none where the revision sends no mail. Settings `server/1` would not have written,
  # as a hand-made `helm --set` may leave them (a sender or port it would refuse, TLS turned off,
  # the password in another Secret), are `:unreadable`, never none or a map without them: the next
  # install would otherwise turn mail off, or TLS back on, without a word.
  defp mail(values) do
    from = at(values, ["governance", "mail", "from"])
    host = at(values, ["governance", "mail", "smtp", "host"])
    port = at(values, ["governance", "mail", "smtp", "port"]) || 587
    username = at(values, ["governance", "mail", "smtp", "username"])
    tls = at(values, ["governance", "mail", "smtp", "tls"])
    secret = at(values, ["governance", "mail", "smtp", "password", "secretName"])

    with true <- host not in [nil, ""] || :none,
         # TLS turned off, or the password kept elsewhere, by hand: never undone without a word.
         true <- tls in [nil, true] and secret in [nil, "", @smtp_secret],
         true <- mail_host?(host) and mail_address?(from),
         true <- is_integer(port) and port in 1..65_535,
         true <- username in [nil, ""] or mail_username?(username) do
      smtp = %{"host" => host, "port" => port}
      smtp = if username in [nil, ""], do: smtp, else: Map.put(smtp, "username", username)
      %{"from" => from, "smtp" => smtp}
    else
      :none -> nil
      _not_written_here -> :unreadable
    end
  end

  # A DNS label: letters, digits and inner hyphens, at most 63 of them.
  @label "[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"

  @doc """
  Whether `value` is an SMTP server's host EHOS takes: a DNS name, its labels separated by single
  dots. The mailer checks the server's certificate against it.
  """
  @spec mail_host?(term()) :: boolean()
  def mail_host?(value) when is_binary(value),
    do: byte_size(value) <= 253 and value =~ ~r/\A#{@label}(?:\.#{@label})*\z/

  def mail_host?(_value), do: false

  @doc """
  Whether `value` is an address EHOS may send mail from: printable ASCII, one `@` between a local
  part and a DNS name, and no space, quote, angle bracket or comma, which would change the header.
  An address beyond ASCII would need SMTPUTF8, which EHOS's mailer does not ask for.
  """
  @spec mail_address?(term()) :: boolean()
  def mail_address?(value) when is_binary(value) do
    with true <- byte_size(value) <= 254,
         [local, domain] <- String.split(value, "@"),
         # A dot-atom: dots only between atext, never first, last or doubled.
         true <- local =~ ~r/\A[!#-'*+\-\/-9=?A-Z^-~]+(?:\.[!#-'*+\-\/-9=?A-Z^-~]+)*\z/,
         true <- byte_size(local) <= 64,
         true <- mail_host?(domain) and String.contains?(domain, ".") do
      true
    else
      _not_an_address -> false
    end
  end

  def mail_address?(_value), do: false

  @doc "Whether `value` is an SMTP user EHOS takes: printable ASCII without spaces, at most 254."
  @spec mail_username?(term()) :: boolean()
  def mail_username?(value) when is_binary(value),
    do: byte_size(value) <= 254 and value =~ ~r/\A[!-~]+\z/

  def mail_username?(_value), do: false

  # A value under `keys` of nested maps, or `nil` where any of them is something else.
  defp at(value, []), do: value
  defp at(%{} = map, [key | keys]), do: at(Map.get(map, key), keys)
  defp at(_value, _keys), do: nil

  # The release command waits for the governance database and boots EHOS's code; a tunnel that is
  # wedged would otherwise keep `kubectl exec` waiting for ever.
  @invite_timeout :timer.minutes(2)

  @typedoc """
  What EHOS printed when it invited a person (`invite/1`):

    * `:invited` — its line that says whom it invited and for how long the link signs them in;
    * `:link` — the link, which signs them in once: a password;
    * `:administrator` — its line that says the person became the platform's administrator, since
      nobody was (eh-os D-37), or `nil`;
    * `:interrupted` — when kubectl failed after EHOS printed the link, a sentence that says so,
      since what EHOS printed after the link, its administrator's line among it, may be missing;
      else `nil`.
  """
  @type invited :: %{
          invited: String.t(),
          link: String.t(),
          administrator: String.t() | nil,
          interrupted: String.t() | nil
        }

  @doc """
  Invites the person `:email` names on an installation's server, and returns the link EHOS
  printed, which signs them in once, within 15 minutes (eh-os D-35).

  It is EHOS's release command, `bin/ehos eval` of `Ehos.Release.invite/1`, run with `kubectl
  exec` in the governance container, through the kubeconfig `tunnel` wrote in `~/.ehos/<name>`
  and its context `ehos-<name>`. When nobody is the platform's administrator yet, EHOS makes the
  person invited it. A person who has joined is not refused, as EHOS's API and console refuse
  them: the link signs them in again, which is how one who forgot their password gets back in
  while the installation sends no mail (eh-os#441).

  The address goes into the expression EHOS evaluates, so it is checked with `email/1` and written
  as an Elixir string literal by `invite_expression/1`, never pasted into the code.

  The link is returned, and written nowhere: whoever reads it can sign in as that person.

  ## Options

    * `:email` — the person's address (required).
    * `:name`, `:home`, `:runner`, `:server_command`, `:name_option`, `:name_in_commands` — as
      for `server/1`.
  """
  @spec invite(keyword()) :: {:ok, invited()} | {:error, String.t()}
  def invite(opts) do
    name = Keyword.get(opts, :name, "trial")
    dir = opts |> Keyword.get(:home, "~/.ehos") |> Path.expand() |> Path.join(name)
    runner = Keyword.get(opts, :runner, CommandRunnerImpl)

    with true <- Server.valid_name?(name) || {:error, Server.name_rule()},
         {:ok, expression} <- invite_expression(required!(opts, :email)),
         {:ok, kubeconfig} <- kubeconfig(dir, tunnel_command(opts)) do
      args = [
        "--kubeconfig",
        kubeconfig,
        "--context",
        "ehos-#{name}",
        "--namespace",
        @namespace,
        "exec",
        "deployment/ehos-governance",
        "--container",
        "governance",
        "--",
        "bin/ehos",
        "eval",
        expression
      ]

      "kubectl"
      |> runner.run_bounded(args, @invite_timeout)
      |> invited(opts)
    end
  end

  @doc """
  `email` when it is an address EHOS could take for a person, as eh-os's `Ehos.Accounts.Person`
  checks one: an `@` with something on each side and no other, no space, comma or semicolon, at
  most 160 characters. It refuses more than EHOS does: bytes that are not UTF-8, and a control
  or format character, a line or paragraph separator, or a space of Unicode's, such as U+00A0.
  EHOS would take those, but a terminal acts on them, or they hide or reorder the text around
  them, and an address that holds one, pasted by mistake, would be invited as another person.

  This refuses early what EHOS would refuse. What keeps an address from running as code is
  `invite_expression/1`'s string literal, which takes a quote, a backslash or `\#{` as they are.

      iex> EhosPlatform.Install.email("ada@example.com")
      {:ok, "ada@example.com"}

      iex> EhosPlatform.Install.email("ada@example.com,alan@example.com")
      {:error, ~S|"ada@example.com,alan@example.com" is not an email address EHOS takes: one @ with something on each side, and no space, comma or semicolon|}
  """
  @spec email(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def email(email) when is_binary(email) do
    cond do
      not printable?(email) or String.match?(email, ~r/\p{Z}/u) ->
        {:error,
         "#{inspect(email)} is not an email address EHOS takes: it holds bytes that are not " <>
           "UTF-8, a control or formatting character, or a space"}

      # EHOS's own expression, without Unicode's classes, as EHOS runs it.
      not String.match?(email, ~r/\A[^@,;\s]+@[^@,;\s]+\z/) ->
        {:error,
         "#{inspect(email)} is not an email address EHOS takes: one @ with something on each " <>
           "side, and no space, comma or semicolon"}

      # Counted in code points, as EHOS counts them.
      length(String.codepoints(email)) > 160 ->
        {:error, "The email address is longer than the 160 characters EHOS takes"}

      true ->
        {:ok, email}
    end
  end

  @doc """
  The Elixir expression EHOS evaluates to invite `email` (`invite/1`), once `email/1` has taken
  it: a call of `Ehos.Release.invite/1` whose one argument is a string literal, written by
  `inspect/2`, which escapes a quote, a backslash and `\#{`. The expression is parsed back before
  it is returned, and must be that call with that very string and nothing else.

      iex> EhosPlatform.Install.invite_expression(~S|a"b@example.com|)
      {:ok, ~S|Ehos.Release.invite("a\\"b@example.com")|}
  """
  @spec invite_expression(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def invite_expression(email) do
    with {:ok, email} <- email(email) do
      expression = "Ehos.Release.invite(" <> inspect(email, printable_limit: :infinity) <> ")"

      case Code.string_to_quoted(expression) do
        {:ok, {{:., _, [{:__aliases__, _, [:Ehos, :Release]}, :invite]}, _, [^email]}} ->
          {:ok, expression}

        _other ->
          {:error, "#{inspect(email)} cannot be written as an Elixir string for EHOS to take"}
      end
    end
  end

  # What `Ehos.Release.invite/1` printed, read whatever kubectl's exit status: a stream that
  # broke after EHOS printed the link still invited the person, and the link is theirs.
  defp invited({output, status}, opts) when is_integer(status) do
    email = required!(opts, :email)

    case {printed(output), status} do
      {{:ok, invited}, 0} ->
        {:ok, invited}

      {{:ok, invited}, status} ->
        {:ok,
         %{
           invited
           | interrupted:
               "kubectl failed with exit status #{status} after EHOS printed the link, so what " <>
                 "EHOS said after it may be missing: if nobody was the platform's " <>
                 "administrator, this person is now."
         }}

      {:error, 0} ->
        {:error,
         "EHOS ran the invitation of #{email} but printed no sign-in link in the form this " <>
           "version knows. What it printed is below; a link in it is a password, for that " <>
           "person alone:\n" <> output}

      {:error, status} ->
        # An exception EHOS raised, as `Ehos.Release.invite/1` raises for a person who is
        # disabled or an address it refuses: its first line says why. Anything else is said as
        # kubectl printed it, but for a sign-in link, which is a password.
        case Regex.run(~r/^\*\* (\(.+)$/m, output) do
          [_line, raised] ->
            {:error, "EHOS did not invite #{email}: #{hidden(raised)}"}

          nil ->
            tunnel_hint(failure("kubectl", {hidden(output), status}), opts)
        end
    end
  end

  defp invited({:error, :timeout}, opts),
    do:
      tunnel_hint(
        {:error,
         "kubectl did not finish within #{div(@invite_timeout, 60_000)} minutes, and no link " <>
           "reached ehosctl. EHOS may still have invited them, and made them administrator if nobody was: " <>
           "run it again for a link."},
        opts
      )

  defp invited(result, _opts), do: failure("kubectl", result)

  # EHOS's line that names the person, then the link: on a later line, not always the next, since
  # stdout and stderr come through kubectl as two streams and a log line may fall between them.
  # Then one more line when the person became administrator.
  defp printed(output) do
    lines = output |> String.replace("\r\n", "\n") |> String.split("\n")

    with [invited_line | rest] <-
           Enum.drop_while(lines, &(not String.starts_with?(&1, "Invited "))),
         true <- String.ends_with?(invited_line, ":") and printable?(invited_line),
         link when is_binary(link) <- rest |> Enum.map(&String.trim/1) |> Enum.find(&link?/1) do
      administrator =
        Enum.find(
          rest,
          &(String.starts_with?(&1, "Nobody was administrator yet:") and printable?(&1))
        )

      {:ok, %{invited: invited_line, link: link, administrator: administrator, interrupted: nil}}
    else
      _unrecognized -> :error
    end
  end

  # `text` with any sign-in link's token hidden.
  defp hidden(text), do: String.replace(text, ~r{/people/log-in/\S+}, "/people/log-in/[hidden]")

  # The length of the token EHOS writes into a sign-in link: 32 random bytes, in URL-safe Base64
  # without padding (eh-os's `Ehos.Accounts.PersonToken`).
  @token_size 43

  # The link EHOS's log-in page takes, as `Ehos.Release` writes it: an http or https URL to a
  # host, whose path is the log-in page's followed by the token.
  defp link?(link) do
    # A token cut short, as a stream broken in the middle of the line leaves it, is not one.
    printable?(link) and String.match?(link, ~r{/people/log-in/[A-Za-z0-9_-]+\z}) and
      match?(
        {:ok,
         %URI{
           scheme: scheme,
           host: host,
           path: "/people/log-in/" <> token,
           query: nil,
           fragment: nil
         }}
        when scheme in ["http", "https"] and is_binary(host) and host != "" and
               byte_size(token) >= @token_size,
        URI.new(link)
      )
  end

  # Text a terminal shows as it is: UTF-8, with no control character, which could move the cursor
  # or rewrite a line, and no format character or separator, which reorders or breaks the text.
  defp printable?(text),
    do:
      String.valid?(text) and String.printable?(text) and
        not String.match?(text, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u)

  defp kubeconfig(dir, tunnel) do
    path = Path.join(dir, "kubeconfig")

    if File.exists?(path),
      do: {:ok, path},
      else: {:error, "#{path} is missing. Open the tunnel first: #{tunnel}"}
  end

  defp host(opts, dir, tunnel) do
    case Keyword.get(opts, :host) do
      nil ->
        case address_in(dir) do
          nil ->
            {:error,
             "The server's address is unknown: open the tunnel first (#{tunnel}), " <>
               "or give --host"}

          address ->
            {:ok, sslip_host(address)}
        end

      host ->
        host(host)
    end
  end

  @doc """
  The IPv4 address the installation's tunnel last went to, as `tunnel` recorded it in
  `tunnel.json`, or `nil`. Options `:name` and `:home`, as `server/1`'s.
  """
  @spec tunnel_address(keyword()) :: String.t() | nil
  def tunnel_address(opts) do
    opts
    |> Keyword.get(:home, "~/.ehos")
    |> Path.expand()
    |> Path.join(Keyword.get(opts, :name, "trial"))
    |> address_in()
  end

  # Read as `tunnel` reads its own record: a small regular file alone (eh-os#285).
  defp address_in(dir) do
    with %{"address" => address} when is_binary(address) <-
           Server.read_tunnel(Path.join(dir, "tunnel.json")),
         {:ok, _ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)) do
      address
    else
      _none -> nil
    end
  end

  @doc """
  The console's host sslip.io answers with `address`, the one a first install takes.

      iex> EhosPlatform.Install.sslip_host("92.5.3.194")
      "ehos.92-5-3-194.sslip.io"
  """
  @spec sslip_host(String.t()) :: String.t()
  def sslip_host(address), do: "ehos.#{String.replace(address, ".", "-")}.sslip.io"

  @doc """
  The address a console's host of sslip.io names, `ehos.<a-b-c-d>.sslip.io`, or `nil` for any other
  host.

      iex> EhosPlatform.Install.sslip_address("ehos.92-5-3-194.sslip.io")
      "92.5.3.194"

      iex> EhosPlatform.Install.sslip_address("ehos.example.org")
      nil
  """
  @spec sslip_address(String.t() | nil) :: String.t() | nil
  def sslip_address(host) when is_binary(host) do
    case Regex.run(~r/\Aehos\.(\d{1,3}(?:-\d{1,3}){3})\.sslip\.io\z/, host) do
      [_, dashed] -> String.replace(dashed, "-", ".")
      nil -> nil
    end
  end

  def sslip_address(_host), do: nil

  # A host written into the CA's name constraints, its admission policy's CEL and the CoreDNS
  # rule's regular expression, and into helm's `--set`: lowercase DNS labels alone, three or more,
  # so no quote, comma, brace or regular expression's character gets in, and no name as broad as a
  # public suffix.
  defp host(host) do
    label = "[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?"
    # The last label starts with a letter, so no IP address reads as a name.
    top = "[a-z]([-a-z0-9]{0,61}[a-z0-9])?"

    if String.length(host) <= 253 and host =~ ~r/\A(#{label}\.){2,}#{top}\z/,
      do: {:ok, host},
      else:
        {:error,
         "--host must be a lowercase DNS name of three labels or more, such as ehos.example.org"}
  end

  # The nodes' allocatable CPU is read with them, for `room/2`.
  defp reachable(target, tunnel) do
    args = ["get", "nodes", "-o", "jsonpath={.items[*].status.allocatable.cpu}"]

    case target.runner.run("kubectl", kubectl_args(target, args)) do
      {output, 0} ->
        room(target, output)
        recent_kubernetes(target)

      {output, status} when is_integer(status) ->
        {:error,
         "The cluster does not answer through the tunnel (exit status #{status}). Open it with " <>
           "#{tunnel}:\n" <> output}

      result ->
        failure("kubectl", result)
    end
  end

  @room_millicores 2000

  # eh-os#892: EHOS's own pods request about one CPU, so on a one-CPU server an application's grants
  # Job, and the second copy a rollout starts, are never scheduled, and its deployment waits. Said,
  # not refused: a cluster sized otherwise may still fit one small application.
  defp room(target, output) do
    case millicores(output) do
      total when is_integer(total) and total < @room_millicores ->
        target.progress.(
          "Warning: the cluster's nodes have #{total}m of CPU to allocate, and EHOS's own pods " <>
            "request about 1000m of it. An application's grants Job and its rollouts may then " <>
            "never be scheduled (eh-os#892). Give the server 2 CPUs or more; on Oracle, " <>
            "#{target.server_command} up --ocpus 2"
        )

      _enough_or_unknown ->
        :ok
    end

    :ok
  end

  @recent_minor 37

  # eh-os D-148, eh-os#923: on Kubernetes 1.36 and before, EHOS's isolation policy, once deleted
  # and made again on a running API server, refuses every new environment's pods until the API
  # server restarts; 1.37 fixed it. Said, not refused, as `room/2` says: a cluster ehosctl did not
  # make is its owner's to upgrade (eh-os D-79). The API server's own `/version` is read, since the
  # bug is its own: `kubectl version` adds the client's, and a warning after its JSON when the two
  # are more than a minor apart. One not read or not understood is not judged.
  defp recent_kubernetes(target) do
    args = ["get", "--raw", "/version", "--request-timeout=10s"]

    with {output, 0} <- target.runner.run("kubectl", kubectl_args(target, args)),
         {major, minor, version} when major == 1 and minor < @recent_minor <-
           server_version(output) do
      target.progress.(
        "Warning: the cluster runs Kubernetes #{version}, older than 1.#{@recent_minor}. On it, " <>
          "EHOS's isolation policy, once deleted and made again, refuses every new " <>
          "environment's pods until the API server restarts (eh-os#923). A server made by " <>
          "#{target.server_command} up is moved to 1.#{@recent_minor} by hand once, as eh-os " <>
          "D-148 says, with k3s's gateway-api-crd disabled beside its Traefik; any other " <>
          "cluster is upgraded by its owner"
      )
    end

    :ok
  end

  # `/version`'s answer is a few hundred bytes; one far larger is not judged, rather than searched.
  @version_answer_bytes 65_536

  @doc false
  # The API server's version in its `/version` answer, as `{major, minor, version}`; nil when it
  # holds none. A managed cluster's minor may end in `+`, `27+`. The version is its `gitVersion`
  # when that reads as one, since it is printed, and else `major.minor`.
  #
  # The runner merges what kubectl, and a credential plugin it runs, write to stderr into the
  # answer, before it or after, braces and JSON of their own among them. The answer is looked for
  # in each span from a line that starts with `{` to one that ends with `}`, the first start and
  # the widest span first, lazily: the object with string `major` and `minor` and a `gitVersion`
  # starting `v<digit>`, as the API server always sends.
  def server_version(output) when byte_size(output) > @version_answer_bytes, do: nil

  def server_version(output) do
    starts = for [{at, _length}] <- Regex.scan(~r/^\{/m, output, return: :index), do: at

    ends =
      for [{at, _length}] <- Regex.scan(~r/\}$/m, output, return: :index), reduce: [] do
        ends -> [at | ends]
      end

    Enum.find_value(starts, fn first ->
      Enum.find_value(ends, fn last -> last > first and version_in(output, first, last) end)
    end)
  end

  defp version_in(output, first, last) do
    with {:ok, %{"major" => major, "minor" => minor, "gitVersion" => "v" <> _ = git_version}}
         when is_binary(major) and is_binary(minor) <-
           Jason.decode(binary_part(output, first, last - first + 1)),
         true <- git_version =~ ~r/\Av[0-9]/,
         {major, ""} <- Integer.parse(major),
         {minor, rest} when rest in ["", "+"] <- Integer.parse(minor) do
      {major, minor, printable_version(git_version, "#{major}.#{minor}")}
    else
      _other -> nil
    end
  end

  defp printable_version(version, fallback) do
    if version =~ ~r/\Av[0-9A-Za-z.+-]{1,64}\z/, do: version, else: fallback
  end

  @doc false
  # The sum of Kubernetes CPU quantities, `2` or `1930m`, in millicores; nil when one is neither.
  def millicores(output) do
    case output |> String.split("\n", trim: true) |> List.last("") |> String.split() do
      [] -> nil
      quantities -> Enum.reduce_while(quantities, 0, &add_millicores/2)
    end
  end

  defp add_millicores(quantity, sum) do
    case Integer.parse(quantity) do
      {cores, ""} -> {:cont, sum + cores * 1000}
      {millicores, "m"} -> {:cont, sum + millicores}
      _other -> {:halt, nil}
    end
  end

  # eh-os D-36: what to do with the SMTP password, decided before anything changes: write the one
  # given, so running again with a new one rotates it; or keep the Secret the cluster holds; or
  # nothing, where the server authenticates with no user. A server whose user has no password
  # anywhere is refused here, before the chart would start EHOS without it.
  defp smtp_password(target, opts) do
    password = Keyword.get(opts, :smtp_password)
    username = get_in(Keyword.get(opts, :mail) || %{}, ["smtp", "username"])

    cond do
      password not in [nil, ""] and username in [nil, ""] ->
        {:error,
         "SMTP_PASSWORD is set, but no SMTP user is: name the user the password belongs to, or " <>
           "unset SMTP_PASSWORD. Nothing was changed."}

      password not in [nil, ""] ->
        given_password(target, password)

      username in [nil, ""] ->
        {:ok, :none}

      true ->
        held_secret(target, username)
    end
  end

  # The same password again is kept: nothing rewritten, and nothing restarted for it.
  defp given_password(target, password) do
    with {:ok, held} <- held_password(target) do
      if held == Base.encode64(password) do
        target.progress.("Keeping the SMTP password #{@smtp_secret}: it is the one given")
        {:ok, :keep}
      else
        {:ok, {:write, password}}
      end
    end
  end

  defp held_secret(target, username) do
    case secret(target, @smtp_secret, "the SMTP password") do
      {:ok, true} ->
        target.progress.("Keeping the SMTP password #{@smtp_secret} the cluster holds")
        {:ok, :keep}

      {:ok, false} ->
        {:error,
         "The SMTP server is to be reached as #{username}, but no password for it is in the " <>
           "cluster: set SMTP_PASSWORD to it. Nothing was changed."}

      error ->
        error
    end
  end

  # The password the Secret holds, base64 as Kubernetes keeps it, or `nil` where there is none.
  # Compared, never printed: a failure says only that it could not be read.
  defp held_password(target) do
    jsonpath = "jsonpath={.data.password}"
    args = kubectl_args(target, ["get", "secret", @smtp_secret, "-n", @namespace, "-o", jsonpath])

    case target.runner.run("kubectl", args) do
      {output, 0} ->
        {:ok, output |> String.split("\n", trim: true) |> List.last()}

      {output, status} when is_integer(status) ->
        if output =~ ~s|(NotFound): secrets "#{@smtp_secret}" not found|,
          do: {:ok, nil},
          else:
            {:error,
             "kubectl could not read the SMTP password #{@smtp_secret} to compare it with " <>
               "SMTP_PASSWORD (exit status #{status}). Nothing was changed."}

      result ->
        failure("kubectl", result)
    end
  end

  defp smtp_written(target, {:write, password}), do: write_smtp_password(target, password)
  defp smtp_written(_target, _kept), do: :ok

  # eh-os D-36: the chart gives the governance plane the password as a variable, read when its pod
  # starts, and Helm sees no change in the pod's template when only the Secret changed: a password
  # written is reached by restarting the governance plane, or the old one would stay in use. The
  # Secret is marked when written and unmarked once the plane restarted, so a run that failed in
  # between restarts it on the next, the password then kept.
  defp restart_for_password(target, {:write, _password}), do: restart_governance(target)

  defp restart_for_password(target, :keep) do
    jsonpath = "jsonpath={.metadata.annotations.#{String.replace(@restart_pending, ".", "\\.")}}"
    args = kubectl_args(target, ["get", "secret", @smtp_secret, "-n", @namespace, "-o", jsonpath])

    case target.runner.run("kubectl", args) do
      {output, 0} -> if output =~ "pending", do: restart_governance(target), else: :ok
      result -> failure("kubectl", result)
    end
  end

  defp restart_for_password(_target, :none), do: :ok

  defp restart_governance(target) do
    target.progress.("Restarting the governance plane, so it sends mail with the new password")
    deployment = "deployment/ehos-governance"

    with :ok <- kubectl(target, ["rollout", "restart", deployment, "-n", @namespace]),
         :ok <-
           kubectl(target, ["rollout", "status", deployment, "-n", @namespace, "--timeout", "10m"]) do
      kubectl(target, [
        "annotate",
        "secret",
        @smtp_secret,
        "-n",
        @namespace,
        @restart_pending <> "-"
      ])
    end
  end

  # The namespaces whose CloudNativePG clusters EHOS's chart and operator make: the governance
  # plane's database, and the data instances (eh-os D-30).
  @database_namespaces [@namespace, "ehos-data"]
  @cnpg_clusters "clusters.postgresql.cnpg.io"
  @healthy "Cluster in healthy state"
  @database_poll_ms 5_000
  @database_polls 120
  # Each call has a deadline, as the other reads here do, so a tunnel that stops answering fails
  # the run rather than holding it, a database perhaps down, for ever.
  @request_timeout "--request-timeout=10s"
  @read_json [@request_timeout, "-o", "json"]

  @doc """
  Restarts each CloudNativePG cluster in `ehos-system` and `ehos-data` whose instance pods do not
  run as its spec says, one at a time, and waits until each is healthy before the next.

  CloudNativePG applies a change to a cluster's `priorityClassName` only to a new pod, so a class
  the chart gives an installation made before it (eh-os D-143) stays off the running instances
  until each is restarted ([ehos-tools#680](https://github.com/EmpoweredHouse/ehos-tools/issues/680)).
  The restart is CloudNativePG's own, the annotation `kubectl.kubernetes.io/restartedAt` on the
  cluster, which makes its pods again. The pods are compared with the spec, never with a version,
  so a cluster whose pods match it is left as it is. A single-instance cluster is down until its
  new pod is ready: the console for the governance plane's, an instance's applications for theirs.
  """
  @spec restart_outdated_databases(t()) :: :ok | {:error, String.t()}
  def restart_outdated_databases(%__MODULE__{} = target) do
    with {:ok, outdated} <- target |> outdated_databases() |> or_not_listed() do
      {healthy, unhealthy} = Enum.split_with(outdated, &(elem(&1, 3) == @healthy))
      Enum.each(unhealthy, &leave_unhealthy(target, &1))
      announce_restarts(target, healthy)
      restart_each(target, healthy)
    end
  end

  defp outdated_databases(target) do
    Enum.reduce_while(@database_namespaces, {:ok, []}, fn namespace, {:ok, found} ->
      case outdated_in(target, namespace) do
        {:ok, outdated} -> {:cont, {:ok, found ++ outdated}}
        error -> {:halt, error}
      end
    end)
  end

  defp or_not_listed({:error, message}),
    do:
      {:error,
       "The PostgreSQL clusters could not be compared with their pods, so none was restarted: " <>
         "#{message}\nRun the command again to restart any whose pods run without its " <>
         "priority class"}

  defp or_not_listed(listed), do: listed

  defp outdated_in(target, namespace) do
    with {:ok, clusters} <-
           kubectl_items(target, ["get", @cnpg_clusters, "-n", namespace | @read_json]),
         {:ok, pods} <- pods_of(target, namespace, clusters) do
      by_cluster = Enum.group_by(pods, &get_in(&1, ["metadata", "labels", "cnpg.io/cluster"]))

      outdated =
        for %{"metadata" => %{"name" => name}} = cluster <- clusters,
            not on_spec?(cluster, Map.get(by_cluster, name, [])),
            do: {namespace, name, class(cluster), get_in(cluster, ["status", "phase"])}

      {:ok, outdated}
    end
  end

  # No cluster, no pods to ask for.
  defp pods_of(_target, _namespace, []), do: {:ok, []}

  defp pods_of(target, namespace, _clusters),
    do: instance_pods(target, namespace, "cnpg.io/podRole=instance")

  defp instance_pods(target, namespace, selector),
    do: kubectl_items(target, ["get", "pods", "-n", namespace, "-l", selector | @read_json])

  # Every pod has what the cluster's spec gives a new one. A field CloudNativePG likewise applies
  # only to a new pod is compared here too. A cluster with no pod yet is CloudNativePG's to make.
  # A spec that gives no class asks for none: Kubernetes gives such a pod a cluster's
  # `globalDefault` class, if one is set, so its pods would never match it.
  defp on_spec?(cluster, pods), do: on_class?(class(cluster), pods)

  defp on_class?(nil, _pods), do: true
  defp on_class?(class, pods), do: Enum.all?(pods, &(class(&1) == class))

  defp class(resource), do: get_in(resource, ["spec", "priorityClassName"])

  # A cluster that is not healthy before its restart may not come back from one, and another
  # restart on every run would only take it down again.
  defp leave_unhealthy(target, {namespace, name, class, phase}) do
    target.progress.(
      "PostgreSQL #{namespace}/#{name} is not restarted, because it is not healthy " <>
        "(phase #{inspect(phase)}). Its pods run without #{class_name(class)} until it is " <>
        "healthy and the command runs again"
    )
  end

  defp announce_restarts(_target, []), do: :ok

  defp announce_restarts(target, outdated) do
    names =
      Enum.map_join(outdated, ", ", fn {namespace, name, _class, _phase} ->
        "#{namespace}/#{name}"
      end)

    target.progress.(
      "The PostgreSQL pods of #{names} do not run with the priority class that their " <>
        "cluster gives. Each cluster is restarted, one at a time, and is down until its new " <>
        "pod is ready, up to about 3 minutes. The console stops while a cluster in " <>
        "#{@namespace} restarts. The applications of an instance in ehos-data stop while that " <>
        "instance restarts"
    )
  end

  defp restart_each(target, outdated) do
    Enum.reduce_while(outdated, :ok, fn database, :ok ->
      case restart_database(target, database) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp restart_database(target, {namespace, name, class, _phase}) do
    target.progress.(
      "Restarting PostgreSQL #{namespace}/#{name}, so that its pods run with " <>
        "#{class_name(class)}, and waiting until it is healthy"
    )

    restarted_at = target.clock.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    with :ok <-
           target
           |> kubectl([
             "annotate",
             @cnpg_clusters,
             name,
             "-n",
             namespace,
             "kubectl.kubernetes.io/restartedAt=#{restarted_at}",
             "--overwrite",
             @request_timeout
           ])
           |> or_not_restarted(namespace, name),
         do: database_healthy(target, namespace, name, @database_polls)
  end

  defp or_not_restarted(:ok, _namespace, _name), do: :ok

  defp or_not_restarted({:error, message}, namespace, name),
    do:
      {:error,
       "PostgreSQL #{namespace}/#{name} could not be restarted: #{message}\nRun the command " <>
         "again to restart it and the clusters after it"}

  defp class_name(nil), do: "no priority class"
  defp class_name(class), do: "the priority class #{class}"

  # Right after the annotation the cluster still says it is healthy, with its old pods: it is
  # restarted once every instance pod is a new one, ready, and the cluster healthy again. A
  # cluster that cannot be asked meanwhile is asked again; the last answer is said if it never is.
  defp database_healthy(target, namespace, name, polls, last \\ nil)

  defp database_healthy(_target, namespace, name, 0, last),
    do:
      {:error,
       "PostgreSQL #{namespace}/#{name} was not healthy on new pods after #{@database_polls} " <>
         "checks, #{div(@database_poll_ms, 1000)} s apart, since its restart (last: #{last}). " <>
         "CloudNativePG may still be restarting it: see `kubectl describe #{@cnpg_clusters} " <>
         "-n #{namespace} #{name}`. Then run the command again, which restarts every cluster " <>
         "whose pods still run without its priority class"}

  defp database_healthy(target, namespace, name, polls, _last) do
    case restarted(target, namespace, name) do
      :ok ->
        target.progress.("PostgreSQL #{namespace}/#{name} is healthy again")
        :ok

      {:waiting, still} ->
        target.clock.sleep(@database_poll_ms)
        database_healthy(target, namespace, name, polls - 1, still)
    end
  end

  defp restarted(target, namespace, name) do
    with {:ok, cluster} <-
           kubectl_json(target, ["get", @cnpg_clusters, name, "-n", namespace | @read_json]),
         {:ok, pods} <-
           instance_pods(target, namespace, "cnpg.io/cluster=#{name},cnpg.io/podRole=instance") do
      restarted(cluster, pods)
    else
      {:error, message} -> {:waiting, message}
    end
  end

  defp restarted(cluster, pods) do
    phase = get_in(cluster, ["status", "phase"])
    ready = Enum.count(pods, &ready?/1)
    instances = get_in(cluster, ["spec", "instances"]) || 1

    if phase == @healthy and ready == instances and length(pods) == instances and
         on_spec?(cluster, pods),
       do: :ok,
       else:
         {:waiting,
          "phase #{inspect(phase)}, #{ready} of #{instances} pods ready, " <>
            "#{Enum.count(pods, &on_spec?(cluster, [&1]))} of #{length(pods)} with " <>
            "#{class_name(class(cluster))}"}
  end

  defp ready?(pod),
    do:
      Enum.any?(
        get_in(pod, ["status", "conditions"]) || [],
        &(&1["type"] == "Ready" and &1["status"] == "True")
      )

  # The items of a list kubectl is asked for.
  defp kubectl_items(target, args) do
    with {:ok, json} <- kubectl_json(target, args), do: {:ok, Map.get(json, "items", [])}
  end

  # kubectl prints the JSON it is asked for from a line that starts with `{`, after any warning the
  # runner merges in first.
  defp kubectl_json(target, args) do
    with {:ok, output} <- kubectl_output(target, args) do
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")
      |> Jason.decode()
      |> json_object(args, output)
    end
  end

  defp json_object({:ok, json}, _args, _output) when is_map(json), do: {:ok, json}

  defp json_object(_not_an_object, args, output),
    do: {:error, "`kubectl #{Enum.join(args, " ")}` did not answer with JSON:\n" <> output}

  defp kubectl_output(target, args) do
    case target.runner.run("kubectl", kubectl_args(target, args)) do
      {output, 0} -> {:ok, output}
      result -> failure("kubectl", result)
    end
  end

  # The token is written when given, so running again with a new one rotates it; without one,
  # the credential already in the cluster is kept. The user and token, when given, are what Helm
  # pulls a release's chart with too, from the same private registry.
  defp credential(target, opts) do
    token = Keyword.get_lazy(opts, :token, fn -> Env.from(opts).get("GHCR_TOKEN") end)

    cond do
      is_binary(token) and String.trim(token) != "" ->
        with {:ok, username} <- username(target, opts),
             :ok <- write_pull_credential(target, @registry, username, String.trim(token)),
             do: {:ok, {username, String.trim(token)}}

      # A release's chart is pulled with the token on every install, while it is private.
      match?(%Source{chart: {:oci, _}}, target.source) ->
        {:error,
         "EHOS's image and chart are in private GHCR packages: set GHCR_TOKEN to a classic " <>
           "GitHub token with read:packages alone (eh-os#218); Helm pulls the chart with it on " <>
           "every installation"}

      true ->
        case pull_credential(target) do
          {:ok, true} ->
            target.progress.("Keeping the pull credential #{@pull_credential} the cluster holds")
            {:ok, nil}

          {:ok, false} ->
            {:error,
             "EHOS's image is in a private GHCR package: set GHCR_TOKEN to a classic GitHub " <>
               "token with read:packages alone (eh-os#218), at least for the first installation"}

          error ->
            error
        end
    end
  end

  defp username(target, opts) do
    case Keyword.get_lazy(opts, :username, fn -> Env.from(opts).get("GHCR_USERNAME") end) do
      name when is_binary(name) and name != "" ->
        {:ok, name}

      _none ->
        gh_login(target.runner)
    end
  end

  # The GitHub CLI's user. The runner merges stderr into the output, and gh may print a notice
  # after the value, such as a new release's: the login is the last line that has a login's form.
  defp gh_login(runner) do
    login =
      case runner.run("gh", ["api", "user", "--jq", ".login"]) do
        {output, 0} ->
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&(&1 =~ ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/))
          |> List.last()

        _no_cli ->
          nil
      end

    if login,
      do: {:ok, String.trim(login)},
      else: {:error, "Set GHCR_USERNAME to the GitHub user the token belongs to"}
  end

  @doc """
  Installs CloudNativePG, cert-manager, trust-manager and Traefik, each waited for. One already
  deployed at its pinned chart version, with the same values, is left as it is (eh-os#220):
  reinstalling it pulled its chart, applied its CRDs and ran its checks again on every run, for
  nothing. One installed or upgraded takes back, by server-side apply, the fields anyone changed by
  hand (ehos-tools#429). Then Traefik's release must hold no ClusterRole or ClusterRoleBinding, and
  the API server must refuse its service account the cluster's Secrets (eh-os D-117). Each one's
  pods run as `system-cluster-critical`, which the kubelet does not evict when the node runs short
  (eh-os D-143), and request the CPU and memory they use, so the scheduler keeps room for them
  (ehos-tools#576); a release installed with neither differs in its values, so is upgraded to them.

  Before any of them, the admission policy `priv/manifests/external-names.yaml`, which admits an
  `ExternalName` Service only in `ehos-addresses` and `ehos-ingress`, since Traefik follows one
  (eh-os D-117, eh-os#828); and `ehos-addresses`, as EHOS's chart makes it, since Traefik's
  chart makes its Role there (eh-os#846).

  Refused, installing nothing, on a cluster where k3s's bundled Traefik is installed
  (`no_bundled_traefik/1`); and, installing no release, where an `ExternalName` Service made
  before the policy is outside those two namespaces, since the policy sees only what is written
  after it.
  """
  @spec prerequisites(t()) :: :ok | {:error, String.t()}
  def prerequisites(%__MODULE__{} = target) do
    with :ok <- no_bundled_traefik(target),
         {:ok, _rendered} <- apply_for_host(target, @external_names),
         :ok <- no_external_names_elsewhere(target),
         # eh-os#846: Traefik's Role there is made with Traefik, before EHOS's chart makes it.
         {:ok, _rendered} <- apply_for_host(target, @addresses_namespace_manifest),
         :ok <-
           Enum.reduce_while(
             prerequisite_releases(),
             :ok,
             &prerequisite_installed(target, &1, &2)
           ),
         do: traefik_confined(target)
  end

  defp prerequisite_installed(target, release, :ok) do
    case prerequisite(target, release) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  # eh-os D-117: Traefik reads only its two namespaces. A release whose upgrade failed keeps the
  # revision before it, whose ClusterRole lets it read every Secret in the cluster, so what the
  # cluster holds is checked, not what was asked for (ehos-tools#429): its release's cluster-wide
  # objects, which name what to look at, then what the API server lets its service account do,
  # whatever binding gives it.
  @traefik_account "system:serviceaccount:#{@ingress_namespace}:traefik"
  @traefik_denied [
    {["list", "secrets", "--all-namespaces"], "list the Secrets of every namespace"},
    {["get", "secrets", "--namespace", @namespace], "read the Secrets in #{@namespace}"}
  ]

  defp traefik_confined(target) do
    with :ok <- no_cluster_rights(target),
         do: Enum.reduce_while(@traefik_denied, :ok, &denied(target, &1, &2))
  end

  defp no_cluster_rights(target) do
    args = [
      "get",
      "clusterrole,clusterrolebinding",
      "--selector",
      "app.kubernetes.io/instance=traefik-#{@ingress_namespace}",
      "--request-timeout=10s",
      "-o",
      "name"
    ]

    case target.runner.run("kubectl", kubectl_args(target, args)) do
      {output, 0} ->
        # Lines kubectl prints besides, a warning, are not objects.
        case Enum.filter(String.split(output, "\n", trim: true), &(&1 =~ ~r/\Aclusterrole/)) do
          [] ->
            :ok

          left ->
            {:error,
             "Traefik's release in #{@ingress_namespace} still has cluster-wide rights " <>
               "(#{Enum.join(left, ", ")}), with which it reads every Secret in the cluster; " <>
               "`helm history traefik -n #{@ingress_namespace}` says why its last upgrade did " <>
               "not remove them"}
        end

      result ->
        failure("kubectl", result)
    end
  end

  # `kubectl auth can-i` exits 0 for yes, and 1 for no and for every error of its own, a refused
  # impersonation, an unreachable API server or an unknown flag among them: only a line `no`, or
  # `no - <reason>`, is a no.
  defp denied(target, {question, what}, :ok) do
    args = ["auth", "can-i"] ++ question ++ ["--as=#{@traefik_account}", "--request-timeout=10s"]

    case target.runner.run("kubectl", kubectl_args(target, args)) do
      {output, 1} = result ->
        if Enum.any?(String.split(output, "\n", trim: true), &(&1 == "no" or &1 =~ ~r/\Ano - /)),
          do: {:cont, :ok},
          else: {:halt, failure("kubectl", result)}

      {_yes, 0} ->
        {:halt,
         {:error,
          "Traefik's service account #{@traefik_account} may #{what}: some binding outside its " <>
            "release gives it Secrets, the keys that sign EHOS's credentials among them " <>
            "(eh-os D-117). Remove that binding"}}

      result ->
        {:halt, failure("kubectl", result)}
    end
  end

  @doc """
  Refuses a cluster where k3s installs its bundled Traefik, the `traefik` or `traefik-crd`
  HelmChart in `kube-system` (eh-os D-117): EHOS installs its own in `#{@ingress_namespace}`, and
  the two would contend for the ports 80 and 443; and k3s, removing its Traefik's CRDs, would take
  every Traefik route with them, the console's among them. A cluster that is not k3s has no
  HelmChart at all. `server/1` switches a server instead, when told to
  ([eh-os#823](https://github.com/EmpoweredHouse/eh-os/issues/823)); a k3d cluster is made again.
  """
  @spec no_bundled_traefik(t()) :: :ok | {:error, String.t()}
  def no_bundled_traefik(%__MODULE__{} = target) do
    with {:ok, bundled} <- bundled_traefik(target) do
      if bundled == "",
        do: :ok,
        else:
          {:error,
           "k3s's bundled Traefik is installed in this cluster (#{helmcharts(bundled)} in " <>
             "kube-system), and EHOS installs its own in #{@ingress_namespace} (eh-os D-117). " <>
             "A cluster is made " <>
             "without it by `disable: [traefik, gateway-api-crd]` in k3s's configuration, or " <>
             "for k3d `--k3s-arg '--disable=traefik@server:*' --k3s-arg " <>
             "'--disable=gateway-api-crd@server:*'`; k3s 1.37 installs its Gateway API CRDs " <>
             "through a binding to cluster-admin, as it does its Traefik, and EHOS uses no " <>
             "Gateway API (eh-os D-148). A server made before is switched by " <>
             "installing EHOS on it with --switch-traefik (eh-os#823)"}
    end
  end

  defp helmcharts(names),
    do: if(String.contains?(names, " "), do: "HelmCharts ", else: "HelmChart ") <> names

  # eh-os#823: a server made before EHOS installed its own Traefik runs k3s's. k3s takes its
  # Traefik out, its CRDs and its `helm-traefik` bindings with it, once its configuration disables
  # it and it starts again: a drop-in under `config.yaml.d`, which adds to a `disable` list the
  # configuration may hold rather than replacing it, then a restart, not waited for here: the
  # cluster is asked until k3s has done. Every Traefik route goes with the CRDs, the console's
  # among them, until the chart is installed again. The server is reached over SSH at the address
  # its tunnel names.
  @drop_in "/etc/rancher/k3s/config.yaml.d/ehos-traefik.yaml"
  @switch_traefik "sudo -n sh -c 'set -eu; mkdir -p /etc/rancher/k3s/config.yaml.d; " <>
                    "umask 077; printf \"disable+:\\n  - traefik\\n\" " <>
                    "> /etc/rancher/k3s/config.yaml.d/ehos-traefik.yaml; " <>
                    "systemctl restart --no-block k3s'"

  # How often, and how many times, the cluster is asked whether k3s has taken its Traefik out.
  @switch_poll_ms 5_000
  @switch_polls 60

  # Whether the server must be switched, and where it is reached; refused, before anything is
  # written, unless the operator agreed to the minutes it costs (`:switch_traefik`).
  defp traefik_switch(target, dir, opts) do
    with {:ok, bundled} <- bundled_traefik(target) do
      cond do
        bundled == "" ->
          {:ok, nil}

        Keyword.get(opts, :switch_traefik) != true ->
          {:error,
           "This server runs k3s's Traefik (#{helmcharts(bundled)} in kube-system), and EHOS " <>
             "installs its own (eh-os D-117). Switching it takes the console and its " <>
             "applications down for a few minutes: run the command again with --switch-traefik " <>
             "when that suits. Nothing was changed."}

        not Server.valid_passphrase?(Server.passphrase(opts)) ->
          {:error,
           "Switching the server reaches it over SSH, as the server's commands do: set " <>
             "EHOS_STATE_PASSPHRASE to its state's passphrase. Nothing was changed."}

        true ->
          switch_address(dir)
      end
    end
  end

  defp switch_address(dir) do
    case address_in(dir) do
      nil -> {:error, "The tunnel's record names no server address: open the tunnel again"}
      address -> {:ok, address}
    end
  end

  defp switch_server(_target, nil, _opts), do: :ok

  defp switch_server(target, address, opts) do
    target.progress.(
      "Switching the server from k3s's Traefik to EHOS's (eh-os D-117): the console and its " <>
        "applications are down for a few minutes"
    )

    with :ok <- remote(opts, address, @switch_traefik),
         do: bundled_traefik_gone(target, @switch_polls)
  end

  defp remote(opts, address, command) do
    server_opts =
      opts
      |> Keyword.take([:name, :home, :runner, :env, :clock, :passphrase, :ssh_key])
      |> Keyword.merge(
        command: opts[:server_command],
        name_option: opts[:name_option],
        name_in_commands: opts[:name_in_commands]
      )
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.put(:address, address)

    case Server.remote(server_opts, command) do
      {:ok, {_output, 0}} ->
        :ok

      # The drop-in may be written though the command failed after, or SSH was lost: k3s would
      # then take its Traefik out at its next restart, whoever restarts it.
      {:ok, {output, status}} ->
        {:error,
         "Switching the server's Traefik failed with exit status #{status}:\n" <>
           output <>
           "\nIf #{@drop_in} was written, k3s takes its Traefik out at its next restart: run " <>
           "the command again with --switch-traefik to finish, or remove the file over SSH"}

      error ->
        error
    end
  end

  # The API server answers again soon after k3s starts; k3s's helm-controller then uninstalls both
  # HelmCharts, and their CRDs are deleted. A cluster that cannot be asked meanwhile is asked
  # again; the last answer is said if it never comes.
  defp bundled_traefik_gone(target, polls, last \\ nil)

  defp bundled_traefik_gone(_target, 0, last),
    do:
      {:error,
       "k3s's Traefik was not gone after #{@switch_polls} checks, #{div(@switch_poll_ms, 1000)} s " <>
         "apart, since k3s was restarted without it (last: #{last}). The console is down until " <>
         "it is. If the cluster does not answer, see on the server `sudo systemctl status k3s` " <>
         "and `sudo journalctl -u k3s`; #{@drop_in} is what disables it. Then run the command " <>
         "again, with --switch-traefik"}

  defp bundled_traefik_gone(target, polls, _last) do
    case {bundled_traefik(target), traefik_crds(target)} do
      {{:ok, ""}, {:ok, ""}} ->
        target.progress.("k3s's Traefik is gone from the server")
        :ok

      answers ->
        target.clock.sleep(@switch_poll_ms)
        bundled_traefik_gone(target, polls - 1, still(answers))
    end
  end

  defp still({{:ok, bundled}, {:ok, crds}}),
    do: "HelmCharts #{inspect(bundled)}, CRDs #{inspect(crds)}"

  defp still({{:error, message}, _crds}), do: message
  defp still({_bundled, {:error, message}}), do: message

  # The Traefik CRDs left, by name, on one line.
  defp traefik_crds(target),
    do:
      read_value(target, [
        "get",
        "crd",
        "--request-timeout=10s",
        "-o",
        ~S|jsonpath={range .items[?(@.spec.group=="traefik.io")]}{.metadata.name} {end}|
      ])

  # The names of k3s's Traefik's HelmCharts the cluster holds, "" for none or on a cluster that is
  # not k3s.
  defp bundled_traefik(target) do
    with {:ok, crd} <-
           read_value(target, [
             "get",
             "crd",
             "helmcharts.helm.cattle.io",
             "--ignore-not-found",
             "--request-timeout=10s",
             "-o",
             "name"
           ]),
         do: bundled_traefik(target, crd)
  end

  defp bundled_traefik(_target, ""), do: {:ok, ""}

  defp bundled_traefik(target, _crd),
    do:
      read_value(target, [
        "get",
        "helmchart",
        "traefik",
        "traefik-crd",
        "-n",
        "kube-system",
        "--ignore-not-found",
        "--request-timeout=10s",
        "-o",
        "jsonpath={.items[*].metadata.name}"
      ])

  # One line kubectl prints, the last, since the runner merges its warnings in first.
  # Asked after the policy is applied, so none is made between the answer and Traefik's install.
  defp no_external_names_elsewhere(target) do
    args = [
      "get",
      "services",
      "--all-namespaces",
      "--field-selector",
      "spec.type=ExternalName",
      "--request-timeout=10s",
      "-o",
      ~S|jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}|
    ]

    case target.runner.run("kubectl", kubectl_args(target, args)) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&Regex.match?(~r{\A[a-z0-9-]+/[a-z0-9.-]+\z}, &1))
        |> Enum.reject(&(hd(String.split(&1, "/")) in @external_name_namespaces))
        |> case do
          [] ->
            :ok

          found ->
            {:error,
             "This cluster has an ExternalName Service outside ehos-addresses and " <>
               "ehos-ingress (#{Enum.join(found, ", ")}), which EHOS's Traefik would follow to " <>
               "whatever it names (eh-os#828). Remove it, or give it another type, and run " <>
               "again. No prerequisite was installed or changed"}
        end

      result ->
        failure("kubectl", result)
    end
  end

  defp read_value(target, args) do
    case target.runner.run("kubectl", kubectl_args(target, args)) do
      {output, 0} -> {:ok, output |> String.split("\n", trim: true) |> List.last("")}
      result -> failure("kubectl", result)
    end
  end

  @doc false
  # Each prerequisite as Helm knows it: its release, namespace, chart and version, and the values
  # it is installed with, which `helm get values` gives back as they are written here.
  #
  # ehos-tools#576: each long-running pod requests half again the most memory it used, idle beside
  # one EHOS installation or issuing and renewing 300 certificates on k3d, rounded up to 16 MiB, and
  # about what CPU it uses between bursts, so the scheduler keeps room for it; Traefik's were set
  # before. No limit: a controller that grew past one would be killed, and only Guaranteed, a CPU
  # and a memory limit each equal to its request, moves the OOM killer's choice much (-997); a
  # request alone takes a pod from BestEffort's 1000 to Burstable's 987 to 995 on an 8 GiB node. The
  # requests come out of what an installation has for EHOS (eh-os D-142).
  def prerequisite_releases do
    [
      %{
        title: "CloudNativePG",
        release: "cnpg",
        namespace: "cnpg-system",
        chart: @cnpg_chart,
        name: "cloudnative-pg",
        version: @cnpg_version,
        # Its operator runs EHOS's databases.
        values: %{
          "priorityClassName" => @critical,
          "resources" => %{"requests" => %{"cpu" => "20m", "memory" => "80Mi"}}
        }
      },
      %{
        title: "cert-manager",
        release: "cert-manager",
        namespace: @cert_manager_namespace,
        chart: @cert_manager_chart,
        name: "cert-manager",
        version: @cert_manager_version,
        # D-62: a certificate's Secret belongs to its Certificate, which an Ingress's belongs to,
        # so a route removed takes its key with it, whoever removes it. Its controller, cainjector
        # and webhook, which refuses writes while it is down, all read the one global class; the
        # top-level `resources` is the controller's alone.
        values: %{
          "crds" => %{"enabled" => true},
          "enableCertificateOwnerRef" => true,
          "global" => %{"priorityClassName" => @critical},
          "resources" => %{"requests" => %{"cpu" => "20m", "memory" => "112Mi"}},
          "cainjector" => %{"resources" => %{"requests" => %{"cpu" => "10m", "memory" => "48Mi"}}},
          "webhook" => %{"resources" => %{"requests" => %{"cpu" => "10m", "memory" => "48Mi"}}}
        }
      },
      %{
        title: "trust-manager",
        release: "trust-manager",
        namespace: @cert_manager_namespace,
        chart: @trust_manager_chart,
        name: "trust-manager",
        version: @trust_manager_version,
        values: %{
          "app" => %{"trust" => %{"namespace" => @cert_manager_namespace}},
          "secretTargets" => %{"enabled" => false},
          "defaultPackage" => %{"enabled" => false},
          "priorityClassName" => @critical,
          "resources" => %{"requests" => %{"cpu" => "10m", "memory" => "48Mi"}}
        }
      },
      %{
        title: "Traefik",
        release: "traefik",
        namespace: @ingress_namespace,
        chart: @traefik_chart,
        name: "traefik",
        version: @traefik_version,
        # The chart labels its pods with the release and its namespace.
        instance: "traefik-#{@ingress_namespace}",
        # Helm installs a chart's CRDs once, and never upgrades them: Traefik's own are applied
        # from the chart pulled, before each install, so a later pin brings its own; no other
        # (Traefik Hub's), for what nothing here runs.
        crds: "traefik/crds/traefik.io_*.yaml",
        values: %{
          "image" => %{
            "registry" => "docker.io",
            "repository" => "traefik",
            "tag" => @traefik_image
          },
          # eh-os D-117: it reads only its own namespace and `ehos-addresses`, by Roles there, never
          # the cluster's secrets (eh-os#846). Namespaced, it reads no IngressClass, so none is
          # made: the addresses name Traefik by the `kubernetes.io/ingress.class` annotation. Its
          # entrypoints are k3s's Traefik's, `web` and `websecure`, on 8443 in the pod.
          "rbac" => %{"namespaced" => true},
          "ingressClass" => %{"enabled" => false},
          # An application's address is an Ingress in `ehos-addresses` to an `ExternalName`
          # Service naming the entry's own Service in its environment (eh-os#828). The console's
          # route, the applications' HSTS and their redirect are in `ehos-ingress`, the route to
          # an `ExternalName` naming the governance plane's Service in `ehos-system`; so is the
          # console's Ingress where TLS ends in front. A list of namespaces replaces the release's
          # own, which the CRD provider reads alone. A Traefik route names another provider's
          # object, `noop@internal` the redirect's, only from `ehos-ingress`, which keeps it so
          # should the provider read more; an address's Ingress names the HSTS middleware there.
          "providers" => %{
            "kubernetesIngress" => %{
              "publishedService" => %{"enabled" => true},
              "allowExternalNameServices" => true,
              "namespaces" => [@addresses_namespace, @ingress_namespace]
            },
            "kubernetesCRD" => %{
              "allowExternalNameServices" => true,
              "crossProviderNamespaces" => [@ingress_namespace]
            }
          },
          # Each client's own address, which the PROXY protocol header names to the governance
          # plane, so it holds each client to its share of the console's connections; behind
          # ServiceLB, a client entering through a node with no Traefik pod is that node's.
          "service" => %{"spec" => %{"externalTrafficPolicy" => "Local"}},
          "api" => %{"dashboard" => false},
          "global" => %{"checkNewVersion" => false},
          # Every request goes through it.
          "priorityClassName" => @critical,
          "resources" => %{"requests" => %{"cpu" => "100m", "memory" => "64Mi"}}
        }
      }
    ]
  end

  defp prerequisite(target, release) do
    if installed?(target, release) do
      # Not installed again, but still waited for, as `helm --wait` did: after a cluster or a
      # server restarts, cert-manager's webhook answers only once its pod is ready, and the CA
      # applied next is checked by it.
      target.progress.("#{release.title} is installed (chart #{release.version}); waiting for it")

      kubectl(target, [
        "wait",
        "--for=condition=Available",
        "deployment",
        "--selector",
        "app.kubernetes.io/instance=#{Map.get(release, :instance, release.release)}",
        "--namespace",
        release.namespace,
        "--timeout=5m"
      ])
    else
      target.progress.("Installing #{release.title} (chart #{release.version})")

      case release do
        %{crds: crds} -> install_with_crds(target, release, crds)
        _none -> install_prerequisite(target, release, release.chart, [])
      end
    end
  end

  # The installer owns these releases: an upgrade takes their fields back from whoever changed them
  # by hand, `kubectl patch` or `kubectl edit`, rather than failing on the conflict and leaving the
  # revision before it running (ehos-tools#429); a release left as it is keeps what was changed.
  # Helm takes them back only by server-side apply, which a release Helm 3 installed client-side is
  # moved to.
  defp install_prerequisite(target, release, chart, args) do
    helm(
      target,
      ["upgrade", "--install", release.release, chart] ++
        ["--namespace", release.namespace, "--create-namespace"] ++
        ["--server-side=true", "--force-conflicts"] ++
        Enum.flat_map(set_values(release.values), &["--set", &1]) ++ args ++ ["--wait"]
    )
  end

  # The chart is pulled by its digest, which Helm checks, its CRDs applied server-side, and the
  # chart installed from what was pulled, without them. A CRD another manager holds differently,
  # another Traefik's, is a conflict that stops the install before anything of it is changed.
  defp install_with_crds(target, release, crds) do
    TmpDir.with_tmp_dir("ehos-#{release.release}", fn dir ->
      with :ok <- helm(target, ["pull", release.chart, "--untar", "--untardir", dir]),
           {:ok, files} <- crd_files(dir, crds),
           :ok <-
             kubectl(
               target,
               ["apply", "--server-side", "--field-manager=ehos-installer"] ++
                 Enum.flat_map(files, &["-f", &1])
             ) do
        chart = dir |> Path.join(crds) |> Path.dirname() |> Path.dirname()
        install_prerequisite(target, release, chart, ["--skip-crds"])
      end
    end)
  end

  defp crd_files(dir, crds) do
    case dir |> Path.join(crds) |> Path.wildcard() |> Enum.sort() do
      [] -> {:error, "The chart pulled has no CRDs at #{crds}"}
      files -> {:ok, files}
    end
  end

  # Deployed at the pinned version with the same values; anything Helm cannot answer, or answers
  # otherwise, installs it again, which is what every run did before.
  defp installed?(target, release) do
    with {:ok, listed} <-
           helm_json(target, [
             "list",
             "--namespace",
             release.namespace,
             "--filter",
             "^#{release.release}$",
             "--output",
             "json"
           ]),
         [%{"chart" => chart, "status" => "deployed"}] <- listed,
         true <- chart == "#{release.name}-#{release.version}",
         {:ok, values} <-
           helm_json(target, [
             "get",
             "values",
             release.release,
             "--namespace",
             release.namespace,
             "--output",
             "json"
           ]) do
      (values || %{}) == release.values
    else
      _other -> false
    end
  end

  defp helm_json(target, args) do
    kubeconfig = if target.kubeconfig, do: ["--kubeconfig", target.kubeconfig], else: []

    case target.runner.run("helm", args ++ ["--kube-context", target.context | kubeconfig]) do
      {output, 0} -> Jason.decode(output)
      _failed -> :error
    end
  end

  @doc false
  # `--set` arguments for nested values, keys sorted so the arguments do not depend on a map's
  # order. A list is Helm's `{a,b}`, of names, which hold no comma.
  def set_values(values, prefix \\ []) do
    values
    |> Enum.sort()
    |> Enum.flat_map(fn
      {key, nested} when is_map(nested) ->
        set_values(nested, prefix ++ [key])

      {key, list} when is_list(list) ->
        ["#{Enum.join(prefix ++ [key], ".")}={#{Enum.join(list, ",")}}"]

      {key, value} ->
        ["#{Enum.join(prefix ++ [key], ".")}=#{value}"]
    end)
  end

  @doc """
  Makes the installation's CA, for the target's host, and waits until it is issued. A cluster
  made before D-62 kept its CA in `ehos-system`, behind namespaced issuers, which go.
  """
  @spec certificate_authority(t()) :: :ok | {:error, String.t()}
  def certificate_authority(%__MODULE__{} = target) do
    target.progress.("Creating the installation's CA for #{target.host} (#{@local_ca})")

    before =
      case ca_certificate(target) do
        {:ok, pem} -> pem
        _none -> nil
      end

    with {:ok, _rendered} <- apply_for_host(target, @local_ca),
         :ok <- wait_for_certificate(target, @cert_manager_namespace, @ca_name),
         {:ok, issued} <- ca_pem(target),
         :ok <- if(current?(issued, target.host), do: :ok, else: renew_ca(target)),
         :ok <- await_current(target, 30) do
      if before && not current?(before, target.host) do
        target.progress.(
          "The CA was issued again, so that it may sign #{target.host} and no IP address; its " <>
            "key is the same. Replace any copy of its old certificate you trusted with the new one"
        )
      end

      kubectl(target, [
        "delete",
        "issuer/#{@ca_name}",
        "issuer/ehos-local-selfsigned",
        "certificate/#{@ca_name}",
        "secret/#{@ca_name}",
        "-n",
        @namespace,
        "--ignore-not-found"
      ])
    end
  end

  # cert-manager issues a CA again when its names change, not when its name constraints do: a CA
  # made before eh-os#218, or one whose host was another before `--host` moved it (eh-os D-124), is
  # renewed, as `cmctl renew` does, with the same key and name, so what it signed still verifies.
  # Its Ready condition may still say the old certificate is: what decides is the issued
  # certificate itself, read until it permits the host and excludes every IP address.
  defp renew_ca(target) do
    issuing =
      Jason.encode!(%{
        "status" => %{
          "conditions" => [
            %{
              "type" => "Issuing",
              "status" => "True",
              "reason" => "ManuallyTriggered",
              "message" => "Its name constraints permit its host alone and no IP address"
            }
          ]
        }
      })

    kubectl(target, [
      "patch",
      "certificate/#{@ca_name}",
      "-n",
      @cert_manager_namespace,
      "--subresource=status",
      "--type=merge",
      "-p",
      issuing
    ])
  end

  defp await_current(target, attempts) do
    with {:ok, pem} <- ca_pem(target) do
      cond do
        current?(pem, target.host) ->
          :ok

        attempts > 1 ->
          target.clock.sleep(2_000)
          await_current(target, attempts - 1)

        true ->
          {:error,
           "The CA #{@ca_name} was not issued again for #{target.host} within a minute: " <>
             "see `kubectl describe certificate #{@ca_name} -n #{@cert_manager_namespace}`"}
      end
    end
  end

  defp ca_pem(target) do
    case ca_certificate(target) do
      {:error, {output, status}} -> failure("kubectl", {output, status})
      result -> result
    end
  end

  @doc """
  Whether a certificate, in PEM, has name constraints that exclude every IPv4 and IPv6 address.
  """
  @spec excludes_every_ip?(String.t()) :: boolean()
  def excludes_every_ip?(pem) do
    with [{:Certificate, der, _}] <- :public_key.pem_decode(pem),
         {:OTPCertificate, tbs, _, _} <- decode_certificate(der),
         {:OTPTBSCertificate, _, _, _, _, _, _, _, _, _, extensions} <- tbs,
         {:Extension, _, _, {:NameConstraints, _permitted, excluded}} <-
           Enum.find(List.wrap(extensions), &match?({:Extension, {2, 5, 29, 30}, _, _}, &1)) do
      ranges = for {:GeneralSubtree, {:iPAddress, range}, _, _} <- List.wrap(excluded), do: range
      <<0::64>> in ranges and <<0::256>> in ranges
    else
      _none -> false
    end
  end

  # The CA as the installation needs it: for its host alone, and no IP address.
  defp current?(pem, host), do: excludes_every_ip?(pem) and permits_only?(pem, host)

  @doc """
  Whether the CA in `pem` permits names under `host` alone: the DNS names its name constraints
  permit are that one host. A CA issued before its host changed permits the old one, and signs
  nothing a client would take for the new one.
  """
  @spec permits_only?(String.t(), String.t()) :: boolean()
  def permits_only?(pem, host) do
    with [{:Certificate, der, _}] <- :public_key.pem_decode(pem),
         {:OTPCertificate, tbs, _, _} <- decode_certificate(der),
         {:OTPTBSCertificate, _, _, _, _, _, _, _, _, _, extensions} <- tbs,
         {:Extension, _, _, {:NameConstraints, permitted, _excluded}} <-
           Enum.find(List.wrap(extensions), &match?({:Extension, {2, 5, 29, 30}, _, _}, &1)) do
      names = for {:GeneralSubtree, {:dNSName, name}, _, _} <- List.wrap(permitted), do: name
      names == [String.to_charlist(host)]
    else
      _none -> false
    end
  end

  # `:public_key` raises on DER that is not a certificate.
  defp decode_certificate(der) do
    :public_key.pkix_decode_cert(der, :otp)
  rescue
    _not_a_certificate -> nil
  end

  @doc """
  Gives pods the console's host and every name under it, through a CoreDNS rule that sends them
  to the ingress (D-45). CoreDNS reads the rule at start, so its pods are rolled out to take it,
  once for each rule: the rule's hash is on their template, and the same rule changes nothing, so
  an upgrade keeps name lookups in the cluster up.
  """
  @spec name_in_cluster(t()) :: :ok | {:error, String.t()}
  # The rule is read from the repository, its path a constant.
  # sobelow_skip ["Traversal.FileModule"]
  def name_in_cluster(%__MODULE__{} = target) do
    target.progress.("Giving pods the name #{target.host} (#{@coredns_custom})")
    coredns = ["-n", "kube-system", "deployment/coredns"]

    # Patching the hash in rolls the pods out after the rule changed, or after a run that applied
    # it and stopped before they took it, and never again while it stays the same.
    with {:ok, rule} <- apply_for_host(target, @coredns_custom),
         hash = :sha256 |> :crypto.hash(rule) |> Base.encode16(case: :lower) |> binary_part(0, 16),
         patch =
           Jason.encode!(%{
             "spec" => %{
               "template" => %{"metadata" => %{"annotations" => %{@coredns_rule => hash}}}
             }
           }),
         :ok <- kubectl(target, ["patch", "--type=merge", "-p", patch | coredns]) do
      kubectl(target, ["rollout", "status", "--timeout=2m" | coredns])
    end
  end

  # Rendered for every host, ehos.localhost included, where it changes nothing: the local
  # cluster, which CI's Cluster job brings up, then runs the rendering a server runs.
  # sobelow_skip ["Traversal.FileModule"]
  defp apply_for_host(target, file) do
    TmpDir.with_tmp_dir("ehos-install", fn dir ->
      path = Path.join(dir, file)
      rendered = file |> manifest() |> File.read!() |> for_host(target.host)
      File.write!(path, rendered)
      with :ok <- kubectl(target, ["apply", "-f", path]), do: {:ok, rendered}
    end)
  end

  @doc """
  Writes `ehos.localhost` as `host` in a manifest: in a regular expression, where its dots are
  escaped once or twice, and as a plain name.

      iex> EhosPlatform.Install.for_host("dnsDomains: [ehos.localhost]", "ehos.1-2-3-4.sslip.io")
      "dnsDomains: [ehos.1-2-3-4.sslip.io]"

      iex> EhosPlatform.Install.for_host(~S"^(.+\\.)?ehos\\.localhost\\.$", "ehos.example.org")
      ~S"^(.+\\.)?ehos\\.example\\.org\\.$"
  """
  @spec for_host(String.t(), String.t()) :: String.t()
  def for_host(contents, host) do
    contents
    |> String.replace(~S"ehos\\.localhost", String.replace(host, ".", ~S"\\."))
    |> String.replace(~S"ehos\.localhost", String.replace(host, ".", ~S"\."))
    |> String.replace(@local_host, host)
  end

  @doc """
  Hands the console's Certificate to the chart in `package`, installed with `values`, when
  cert-manager made it for an Ingress and that chart makes it itself (eh-os D-117). Before D-117
  cert-manager made it from the console's Ingress annotation, owned by that Ingress; since, the
  chart makes it under the same name, and Helm refuses to take over an object it did not make. So
  one Helm did not make is marked as the release's, and freed from the Ingress, whose removal would
  otherwise delete it. Its Secret, and the certificate in it, stay as they are, and the console
  keeps being served while the release is upgraded.

  One an earlier run handed over, freed from the Ingress, of which cert-manager's ingress-shim
  still holds fields, or Helm an update as 0.5.2 left it, is given Helm's field ownership again,
  as its apply (Helm 4 applies server-side).

  Nothing else is done when there is none, when no Ingress owns it, or when the chart being
  installed is one from before D-117, which still asks for it through the Ingress: handed over then,
  cert-manager would stop keeping it in step with the Ingress, a changed host among it. A chart from
  before D-117 installed over one after makes Helm delete it, and its Secret with it, since
  cert-manager owns a Certificate's Secret here (D-62's `enableCertificateOwnerRef`): the console
  has no certificate until cert-manager issues one again for the Ingress.
  """
  @spec adopt_console_certificate(t(), Path.t(), [String.t()]) :: :ok | {:error, String.t()}
  def adopt_console_certificate(%__MODULE__{} = target, package, values) do
    args =
      kubectl_args(target, [
        "get",
        "certificate",
        @tls_secret,
        "-n",
        @namespace,
        "--ignore-not-found",
        "-o",
        "jsonpath={.metadata.name}={.metadata.ownerReferences[*].kind}"
      ])

    # The runner merges stderr into the output, where kubectl warns first: the value is last. What
    # cert-manager made for an Ingress is owned by it; its labels are the Ingress's, Helm's among
    # them, so they cannot tell it from the chart's.
    case target.runner.run("kubectl", args) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last("")
        |> adopt(target, package, values)

      result ->
        failure("kubectl", result)
    end
  end

  defp adopt(@tls_secret <> "=" <> owners, target, package, values) do
    if "Ingress" in String.split(owners),
      do: hand_over_if_the_chart_makes_it(target, package, values),
      # Handed over before, by a run that stopped before Helm took its fields over.
      else: hand_over_fields(target)
  end

  defp adopt(_none, _target, _package, _values), do: :ok

  # The chart, rendered with the values it is installed with, makes the console's Certificate.
  defp hand_over_if_the_chart_makes_it(target, package, values) do
    case target.runner.run(
           "helm",
           ["template", "ehos", package, "--namespace", @namespace] ++ values
         ) do
      {output, 0} ->
        if makes_console_certificate?(output),
          do: hand_over_console_certificate(target),
          else: :ok

      result ->
        failure("helm", result)
    end
  end

  # The rendered documents, read as YAML rather than matched as text, so their keys' order and
  # quoting do not matter.
  defp makes_console_certificate?(rendered) do
    rendered
    |> YamlElixir.read_all_from_string!()
    |> Enum.any?(fn
      %{"kind" => "Certificate", "metadata" => %{"name" => @tls_secret}} -> true
      _other -> false
    end)
  end

  defp hand_over_console_certificate(target) do
    target.progress.("Handing the console's certificate over to the chart")

    patch = %{
      "metadata" => %{
        "ownerReferences" => nil,
        "labels" => %{"app.kubernetes.io/managed-by" => "Helm"},
        "annotations" => %{
          "meta.helm.sh/release-name" => "ehos",
          "meta.helm.sh/release-namespace" => @namespace
        }
      }
    }

    with :ok <-
           kubectl(target, [
             "patch",
             "certificate",
             @tls_secret,
             "-n",
             @namespace,
             "--type=merge",
             "-p",
             Jason.encode!(patch)
           ]),
         do: hand_over_fields(target)
  end

  # Helm 4 installs by server-side apply, as the field manager `helm`, and is refused the fields
  # cert-manager's ingress-shim set, the labels it copied from the Ingress among them. So the
  # shim's entries among the Certificate's managed fields become Helm's apply: Helm then owns what
  # it applies, and drops what the chart no longer sets. Renamed alone they would stay an update,
  # which server-side apply counts as another owner than `helm`'s apply, still in conflict. 0.5.2
  # left them so, as an update of `helm`'s, which is taken over the same way. Nothing tells that
  # one from an update Helm makes when it applies client-side, as it goes on doing for a release
  # Helm 3 installed: there each upgrade that changes the Certificate costs one more patch here.
  defp hand_over_fields(target) do
    args =
      kubectl_args(target, [
        "get",
        "certificate",
        @tls_secret,
        "-n",
        @namespace,
        "--show-managed-fields",
        "-o",
        "jsonpath={.metadata.resourceVersion} {.metadata.managedFields}"
      ])

    with {output, 0} <- target.runner.run("kubectl", args),
         [version, json] <-
           output
           |> String.split("\n", trim: true)
           |> List.last("")
           |> String.split(" ", parts: 2),
         {:ok, fields} when is_list(fields) <- Jason.decode(json) do
      if Enum.any?(fields, &(shims?(&1) or helms?(&1, "Update"))) do
        renamed = helms_apply(fields)

        kubectl(target, [
          "patch",
          "certificate",
          @tls_secret,
          "-n",
          @namespace,
          "--type=json",
          "-p",
          # Refused if cert-manager wrote it since it was read; the next run reads it again.
          Jason.encode!([
            %{"op" => "test", "path" => "/metadata/resourceVersion", "value" => version},
            %{"op" => "replace", "path" => "/metadata/managedFields", "value" => renamed}
          ])
        ])
      else
        :ok
      end
    else
      {:ok, _not_a_list} ->
        {:error, "The console's Certificate's managed fields did not read"}

      [_not_two] ->
        {:error, "The console's Certificate's managed fields did not read"}

      {:error, %Jason.DecodeError{}} ->
        {:error, "The console's Certificate's managed fields did not read"}

      result ->
        failure("kubectl", result)
    end
  end

  # The shim's entries, and Helm's beside them, become one apply of Helm's, where the first of
  # them was: the API server keeps a single entry for each manager's apply. Its API version is that
  # of Helm's apply when there is one, the version Helm applies in.
  defp helms_apply(fields) do
    taken? = &(shims?(&1) or helms?(&1, "Update") or helms?(&1, "Apply"))
    {taken, kept} = Enum.split_with(fields, taken?)
    at = Enum.find_index(fields, taken?)

    entry =
      taken
      |> Enum.find(hd(taken), &helms?(&1, "Apply"))
      |> Map.merge(%{"manager" => "helm", "operation" => "Apply"})
      |> Map.put("fieldsV1", Enum.reduce(taken, %{}, &merge_fields(&2, &1["fieldsV1"] || %{})))

    List.insert_at(kept, at, entry)
  end

  # Of the Certificate itself, not of its status.
  defp shims?(entry),
    do: entry["manager"] == @ingress_shim and entry["subresource"] in [nil, ""]

  defp helms?(entry, operation),
    do:
      entry["manager"] == "helm" and entry["operation"] == operation and
        entry["subresource"] in [nil, ""]

  # Managed fields are a tree of the fields owned; two owners' together is their union.
  defp merge_fields(one, other),
    do: Map.merge(one, other, fn _key, a, b -> merge_fields(a, b) end)

  @doc """
  Waits, for at most two minutes, until cert-manager's Certificate `name` in `namespace` is ready:
  `:ok`, or `{:error, output}` with what `kubectl wait` printed when it is not by then or kubectl
  fails.
  """
  @spec wait_for_certificate(t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def wait_for_certificate(%__MODULE__{} = target, namespace, name) do
    target.progress.("Waiting for the certificate #{namespace}/#{name}")

    kubectl(target, [
      "wait",
      "--for=condition=Ready",
      "certificate/#{name}",
      "-n",
      namespace,
      "--timeout=2m"
    ])
  end

  @doc """
  The certificate of the installation's CA, in PEM, read from the cluster. Its key is never read.
  `{:error, {output, status}}` when kubectl fails, for the caller to explain.
  """
  @spec ca_certificate(t()) ::
          {:ok, String.t()} | {:error, String.t()} | {:error, {String.t(), integer()}}
  def ca_certificate(%__MODULE__{} = target) do
    args =
      kubectl_args(target, [
        "get",
        "secret",
        @ca_name,
        "-n",
        @cert_manager_namespace,
        "-o",
        "jsonpath={.data.ca\\.crt}"
      ])

    # The runner merges stderr into the output, and kubectl prints its warnings before the value,
    # so the value is the last line.
    with {output, 0} <- target.runner.run("kubectl", args),
         {:ok, pem} <-
           output |> String.split("\n", trim: true) |> List.last("") |> Base.decode64(),
         true <- String.starts_with?(pem, "-----BEGIN CERTIFICATE-----") do
      {:ok, pem}
    else
      {output, status} when is_integer(status) -> {:error, {output, status}}
      {:error, :not_found} = result -> failure("kubectl", result)
      _not_a_certificate -> {:error, "The secret #{@ca_name} holds no CA certificate"}
    end
  end

  @doc """
  Whether `ehos-system` holds the pull credential: `{:ok, true}`, `{:ok, false}` when kubectl says
  it is not there or that `ehos-system` is not (ehos-tools#300), and an error when kubectl could not
  say, as when the cluster does not answer. Before, any failure read as none, and environments went
  without it (ehos-tools#174).
  """
  @spec pull_credential(t()) :: {:ok, boolean()} | {:error, String.t()}
  def pull_credential(%__MODULE__{} = target),
    do: secret(target, @pull_credential, "the pull credential")

  defp secret(target, name, what) do
    args = kubectl_args(target, ["get", "secret", name, "-n", @namespace, "-o", "name"])

    case target.runner.run("kubectl", args) do
      {_output, 0} ->
        {:ok, true}

      {output, status} when is_integer(status) ->
        # The Secret's NotFound, or the namespace's on a cluster EHOS was never installed in
        # (ehos-tools#300), is an answer; "the server could not find the requested resource", a
        # proxy's or another server's NotFound, is not.
        if output =~ ~s|(NotFound): secrets "#{name}" not found| or
             output =~ ~s|(NotFound): namespaces "#{@namespace}" not found|,
           do: {:ok, false},
           else:
             {:error,
              "kubectl could not say whether #{@namespace} holds #{what} #{name}:\n" <> output}

      result ->
        failure("kubectl", result)
    end
  end

  @doc """
  Whether `ehos-system` holds the pull credential, reading anything but a clean answer as none.
  Deprecated in its documentation alone, so eh-os, which calls it, still builds with warnings as
  errors against a checkout of this package until it moves to `pull_credential/1` (ehos-tools#174).
  """
  @doc deprecated: "Use pull_credential/1, which says when kubectl could not answer"
  @spec pull_credential?(t()) :: boolean()
  def pull_credential?(%__MODULE__{} = target), do: pull_credential(target) == {:ok, true}

  @doc """
  Writes the pull credential for `registry` into `ehos-system`, replacing one there: a
  `kubernetes.io/dockerconfigjson` Secret, applied from a file only this user reads, which is
  removed after. The token is never an argument of a program, nor in what a failure prints.
  """
  @spec write_pull_credential(t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def write_pull_credential(%__MODULE__{} = target, registry, username, token)
      when is_binary(token) and token != "" do
    target.progress.("Writing the pull credential for #{registry} (#{@pull_credential})")
    auth = Base.encode64("#{username}:#{token}")
    config = %{"auths" => %{registry => %{"username" => username, "auth" => auth}}}
    dockerconfigjson = Base.encode64(Jason.encode!(config))

    secret = %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "type" => "kubernetes.io/dockerconfigjson",
      "metadata" => %{"name" => @pull_credential, "namespace" => @namespace},
      "data" => %{".dockerconfigjson" => dockerconfigjson}
    }

    apply_secret(target, secret, [token, auth, dockerconfigjson], "[the token]")
  end

  @doc """
  Writes the SMTP user's password into `ehos-system` (eh-os D-36), replacing one there: an Opaque
  Secret the chart reads under `password`, applied as the pull credential is. The password is
  never an argument of a program, nor in what a failure prints.
  """
  @spec write_smtp_password(t(), String.t()) :: :ok | {:error, String.t()}
  def write_smtp_password(%__MODULE__{} = target, password)
      when is_binary(password) and password != "" do
    target.progress.("Writing the SMTP password (#{@smtp_secret})")
    encoded = Base.encode64(password)

    secret = %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "type" => "Opaque",
      "metadata" => %{
        "name" => @smtp_secret,
        "namespace" => @namespace,
        "annotations" => %{@restart_pending => "pending"}
      },
      "data" => %{"password" => encoded}
    }

    apply_secret(target, secret, [password, encoded], "[the password]")
  end

  # A Secret, with EHOS's namespace in case it is not there yet, applied from a file only this user
  # reads, which is removed after; what it holds, `hidden`, is replaced in what a failure prints.
  # sobelow_skip ["Traversal.FileModule"]
  defp apply_secret(target, secret, hidden, placeholder) do
    name = secret["metadata"]["name"]

    namespace = %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{"name" => @namespace}
    }

    TmpDir.with_tmp_dir(name, fn dir ->
      path = Path.join(dir, "secret.json")
      list = %{"apiVersion" => "v1", "kind" => "List", "items" => [namespace, secret]}
      # Made exclusively, so nothing already at the path, a link included, is written through.
      :ok = File.write(path, Jason.encode!(list), [:exclusive])
      File.chmod!(path, 0o600)

      # Server-side: a client-side apply keeps the whole object, the value in it, in the
      # `last-applied-configuration` annotation, a second copy anyone who may read the Secret's
      # metadata could read.
      try do
        case kubectl(target, ["apply", "--server-side", "--force-conflicts", "-f", path]) do
          # One written before by a client-side apply keeps that copy until it is removed.
          :ok ->
            kubectl(target, [
              "annotate",
              "secret",
              name,
              "-n",
              @namespace,
              "kubectl.kubernetes.io/last-applied-configuration-"
            ])

          {:error, message} ->
            {:error, Enum.reduce(hidden, message, &String.replace(&2, &1, placeholder))}
        end
      after
        _ = File.rm(path)
      end
    end)
  end

  @doc """
  Installs or upgrades the chart, packaged as a distribution is, and waits until EHOS is ready and
  the console's certificate is issued. A console Certificate cert-manager made for the console's
  Ingress is handed over to a chart that makes it itself first (`adopt_console_certificate/3`).

  ## Options

    * `:repository` and `:digest` — the image, always by digest (required).
    * `:ca_file` — the CA's certificate, which environments are given (D-59) (required).
    * `:allowed_image_prefixes` — where a pod in an environment may pull from (D-55).
    * `:pull_credential?` — whether `ehos-system` holds the pull credential, which is then given
      to environments (D-55).
    * `:own_pull_credential?` — whether EHOS's own pods pull with it too, as on a server, whose
      EHOS image comes from the private registry; the local cluster's comes from its own.
    * `:installation` — what the installation is, the chart's `installation` value (D-90): a map
      of `name`, `provider`, `region` and `size`, each a line of text. None says nothing.
    * `:installed` — what is installed, `version`, `image` and `chart`, the release's `installed`
      value, which nothing in the chart reads and `installed/1` reads back (eh-os D-92). None
      writes none.
    * `:registry_auth` — `{username, token}` for the registry a release's chart is pulled from,
      given to Helm in a registry configuration only this user reads, removed after, never on a
      command line. None leaves Helm its own login, if any.
  """
  @spec chart(t(), keyword()) :: :ok | {:error, String.t()}
  def chart(%__MODULE__{} = target, opts) do
    repository = required!(opts, :repository)
    digest = required!(opts, :digest)
    ca_file = required!(opts, :ca_file)
    prefixes = Keyword.get(opts, :allowed_image_prefixes, ["ghcr.io/empoweredhouse/"])
    pull? = Keyword.get(opts, :pull_credential?, false)

    # D-90: what the installation is, for its page. JSON, since a size such as `4 OCPUs, 24 GB`
    # holds a comma, which `--set` would split on.
    described = described_args(Keyword.get(opts, :installation, %{}))
    # D-92: what runs, for `ehosctl upgrade` to read back through the kubeconfig.
    recorded = installed_args(Keyword.get(opts, :installed))
    # eh-os D-113: how long a sign-in to an application lasts, which the chart checks; JSON, as
    # the installation's description is.
    sign_in = sign_in_args(Keyword.get(opts, :sign_in))
    # eh-os D-105: whether a promotion to production needs a second person; none, the chart's.
    four_eyes = four_eyes_args(Keyword.get(opts, :four_eyes))
    # eh-os D-36: the SMTP server, and the Secret its password is in when it authenticates; JSON,
    # as the sign-in limits are. None: the chart's default, which sends no mail.
    mail = mail_args(Keyword.get(opts, :mail))

    own =
      if Keyword.get(opts, :own_pull_credential?, false),
        do: ["--set", "imagePullSecrets[0].name=#{@pull_credential}"],
        else: []

    values =
      chart_values(target, repository, digest, ca_file, prefixes, pull?) ++
        described ++ recorded ++ sign_in ++ four_eyes ++ mail ++ own

    installed =
      TmpDir.with_tmp_dir("ehos-cluster", fn dir ->
        with {:ok, package} <- chart_reference(target, dir, opts[:registry_auth]),
             :ok <- adopt_console_certificate(target, package, values) do
          target.progress.("Installing EHOS and waiting until it is ready")

          helm(
            target,
            [
              "upgrade",
              "--install",
              "ehos",
              package,
              "--namespace",
              @namespace,
              "--create-namespace",
              "--wait",
              "--timeout",
              "10m"
            ] ++ values
          )
        end
      end)

    with :ok <- installed, do: wait_for_certificate(target, @namespace, @tls_secret)
  end

  defp described_args(empty) when map_size(empty) == 0, do: []

  defp described_args(installation),
    do: ["--set-json", "installation=#{Jason.encode!(installation)}"]

  defp installed_args(nil), do: []
  defp installed_args(installed), do: ["--set-json", "installed=#{Jason.encode!(installed)}"]

  defp sign_in_args(limits) when is_map(limits) and map_size(limits) > 0,
    do: ["--set-json", "governance.signIn=#{Jason.encode!(limits)}"]

  defp sign_in_args(_none), do: []

  defp four_eyes_args(given) when is_boolean(given),
    do: ["--set-json", "governance.promotion.fourEyes=#{given}"]

  defp four_eyes_args(nil), do: []

  defp mail_args(%{"smtp" => %{} = smtp} = mail),
    do: [
      "--set-json",
      "governance.mail=#{Jason.encode!(%{mail | "smtp" => smtp_with_secret(smtp)})}"
    ]

  defp mail_args(_none), do: []

  # A server reached with a user gets the Secret its password is in.
  defp smtp_with_secret(smtp) do
    if smtp["username"] in [nil, ""],
      do: smtp,
      else: Map.put(smtp, "password", %{"secretName" => @smtp_secret, "secretKey" => "password"})
  end

  defp chart_values(target, repository, digest, ca_file, prefixes, pull?) do
    [
      "--set",
      "image.repository=#{repository}",
      "--set",
      "image.digest=#{digest}",
      "--set",
      "governance.host=#{target.host}",
      # D-45: cert-manager issues the console's certificate from the installation's CA. The
      # chart's defaults for the console's URL, https on 443, are what the ingress serves.
      "--set",
      "governance.ingress.tls.secretName=#{@tls_secret}",
      "--set",
      "governance.ingress.annotations.cert-manager\\.io/cluster-issuer=#{@ca_name}",
      # D-62: every application's address gets a certificate of its own from the same CA.
      "--set",
      "environments.ingress.annotations.cert-manager\\.io/cluster-issuer=#{@ca_name}",
      "--set",
      "environments.ingress.tls=true",
      # eh-os D-117: an environment's pods admit Traefik from the namespace it is installed in,
      # whatever the chart's default, so an older chart, installed by this installer, does too.
      "--set",
      "environments.ingressController.namespace=#{@ingress_namespace}",
      # D-55: where a pod in an environment may pull its image from.
      "--set",
      "environments.allowedImagePrefixes={#{Enum.join(prefixes, ",")}}",
      # D-59: the installation's CA certifies the console's host, so environments are given it.
      "--set-file",
      "environments.caCertificate=#{ca_file}"
    ] ++
      if(pull?, do: ["--set", "environments.imagePullSecret=#{@pull_credential}"], else: [])
  end

  # A release's chart is installed by its digest, which Helm checks; a checkout's is packaged first.
  # A release's chart is pulled by its digest, which Helm checks, into the private directory, and
  # installed from there; a checkout's is packaged first.
  defp chart_reference(
         %__MODULE__{source: %Source{chart: {:oci, reference}}} = target,
         dir,
         auth
       ),
       do: pull(target, reference, dir, auth)

  defp chart_reference(%__MODULE__{source: %Source{chart: {:directory, chart}}} = target, dir, _),
    do: package(target.runner, chart, dir)

  # The chart is in GHCR, private while EHOS's packages are (eh-os D-92). Helm is given the
  # credential the image is pulled with, in a registry configuration in the Docker format, only
  # this user reads, for the pull alone: it is removed as soon as the chart is here, not kept for
  # the install's ten minutes. Without one, Helm's own login is used.
  # sobelow_skip ["Traversal.FileModule"]
  defp pull(target, reference, dir, auth) do
    registry = Path.join(dir, "registry.json")
    charts = Path.join(dir, "chart")

    with :ok <- File.mkdir(charts) |> or_cannot_write(charts),
         {:ok, args} <- registry_config(registry, auth) do
      target.progress.("Pulling EHOS's chart by its digest")
      pulled = target.runner.run("helm", ["pull", reference, "--destination", charts | args])
      File.rm(registry)

      case {pulled, Path.wildcard(Path.join(charts, "*.tgz"))} do
        {{_output, 0}, [package]} -> {:ok, package}
        {{_output, 0}, _none} -> {:error, "`helm pull` saved no single chart in #{charts}"}
        {result, _} -> refused(failure("helm", result), auth)
      end
    end
  end

  defp or_cannot_write(:ok, _path), do: :ok

  defp or_cannot_write({:error, reason}, path),
    do: {:error, "#{path} cannot be made: #{:file.format_error(reason)}"}

  defp registry_config(_path, nil), do: {:ok, []}

  defp registry_config(path, {username, token}) do
    auth = Base.encode64("#{username}:#{token}")
    config = Jason.encode!(%{"auths" => %{@registry => %{"auth" => auth}}})

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, device} ->
        written =
          try do
            with :ok <- File.chmod(path, 0o600), do: IO.binwrite(device, config)
          after
            File.close(device)
          end

        if written == :ok,
          do: {:ok, ["--registry-config", path]},
          else: cannot_write_registry(written)

      error ->
        cannot_write_registry(error)
    end
  end

  defp cannot_write_registry({:error, reason}),
    do: {:error, "The registry configuration cannot be written: #{:file.format_error(reason)}"}

  # A chart GHCR would not give says how to give it the credential, rather than Helm's 403 alone.
  defp refused({:error, message} = error, auth) do
    cond do
      not (message =~ ~r/response status code 40[13]|: (unauthorized|denied):/i) ->
        error

      auth ->
        {:error,
         message <>
           "\nGHCR refused EHOS's chart to GHCR_TOKEN: it needs read:packages, and must not " <>
           "have expired"}

      true ->
        {:error,
         message <>
           "\nEHOS's chart is in a private GHCR package: set GHCR_TOKEN to a classic GitHub " <>
           "token with read:packages alone (eh-os#218)"}
    end
  end

  defp package(runner, chart, dir) do
    case runner.run("helm", ["package", chart, "--destination", dir]) do
      {output, 0} ->
        case Regex.run(~r/saved it to: (\S+\.tgz)/, output, capture: :all_but_first) do
          [path] -> {:ok, path}
          nil -> {:error, "`helm package` did not say where it saved the chart:\n" <> output}
        end

      result ->
        failure("helm", result)
    end
  end

  @doc "Runs `kubectl` with `args` against the target. `:ok`, or the error with its output."
  @spec kubectl(t(), [String.t()]) :: :ok | {:error, String.t()}
  def kubectl(%__MODULE__{} = target, args),
    do: run(target.runner, "kubectl", kubectl_args(target, args))

  @doc "The arguments that point `kubectl` at the target, before `args`."
  @spec kubectl_args(t(), [String.t()]) :: [String.t()]
  def kubectl_args(%__MODULE__{kubeconfig: nil, context: context}, args),
    do: ["--context", context | args]

  def kubectl_args(%__MODULE__{kubeconfig: kubeconfig, context: context}, args),
    do: ["--kubeconfig", kubeconfig, "--context", context | args]

  defp helm(target, args) do
    kubeconfig = if target.kubeconfig, do: ["--kubeconfig", target.kubeconfig], else: []
    run(target.runner, "helm", args ++ ["--kube-context", target.context | kubeconfig])
  end

  defp run(runner, program, args) do
    case runner.run(program, args) do
      {_output, 0} -> :ok
      result -> failure(program, result)
    end
  end

  defp failure(program, {:error, :not_found}),
    do:
      {:error,
       "`#{program}` is not installed, or not at the version EHOS pins: `ehosctl doctor` says what is missing (`mix ehos.doctor` in eh-os)"}

  defp failure(program, {output, status}),
    do: {:error, "`#{program}` failed with exit status #{status}:\n" <> output}

  @doc "The path of one of the manifests the installer applies, in this package's `priv/`."
  @spec manifest(String.t()) :: Path.t()
  def manifest(file),
    do: Path.join([Application.app_dir(:ehos_platform), "priv", "manifests", file])
end

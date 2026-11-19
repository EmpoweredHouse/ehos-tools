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
    * `name_in_cluster/1` gives pods the console's host and every name under it with no
      underscore, so they reach the console and applications through the ingress without
      leaving the cluster (D-45);
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

  alias EhosPlatform.AllowedDomains
  alias EhosPlatform.ClockImpl
  alias EhosPlatform.CommandRunnerImpl
  alias EhosPlatform.DomainRecords
  alias EhosPlatform.Env
  alias EhosPlatform.ExternalDatabases
  alias EhosPlatform.Failure
  alias EhosPlatform.Move
  alias EhosPlatform.PublicCertificates
  alias EhosPlatform.Report
  alias EhosPlatform.Server
  alias EhosPlatform.Source
  alias EhosPlatform.TmpDir

  @local_ca "local-ca.yaml"
  @coredns_custom "coredns-custom.yaml"
  @external_names "external-names.yaml"
  @addresses_namespace_manifest "addresses-namespace.yaml"
  # eh-os D-171: the keeper's namespace, made before the chart so that it holds the pull credential
  # before the keeper pulls EHOS's image there.
  @data_namespace_manifest "data-namespace.yaml"
  @data_namespace "ehos-data"
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
  # by the digest of v1.21.2's OCI artifact, so what installs is exactly what was checked. The
  # digests of its five images below move with it, and so does eh-os's chart's
  # `publicCertificates.addresses.solverImage`.
  @cert_manager_version "v1.21.2"
  @cert_manager_chart "oci://quay.io/jetstack/charts/cert-manager@sha256:634dce9c13b56677a2c05e2ab76c312d0be2664022d5dd05815da67e1fd5f610"
  @cert_manager_namespace "cert-manager"
  # eh-os D-155, D-158: the HTTP-01 solver's image, by the digest of v1.21.2's index, which EHOS's
  # chart holds the solver's pod to in `ehos-addresses`.
  @cert_manager_solver "sha256:699b40d622211ab7accad8a21b04c5fbaa1841ef7a12621e8de492dbe27b2503"
  # Its other images, by the digests of v1.21.2's indexes, so what runs is what was checked, not
  # what a tag names at the time (ehos-tools#805). Each is set on its own: the chart's top-level
  # `image` is the controller's alone.
  @cert_manager_controller "sha256:70f532fd9cfde0b09d55687200942399d89838bc2d5d5b45152eb799a15912b8"
  @cert_manager_webhook "sha256:a60e2dac46dbb8a7f3df95c54ce941012f54c2fe022f0ee55aaa1ab40ed957ae"
  @cert_manager_cainjector "sha256:c85268c64f2e0e76684bf5fe8906caff34b82523561c6affe0fae3546bd87562"
  @cert_manager_startupapicheck "sha256:46e75b6866359ffb5d82624f41e3ed1c70b2994982702ced547ce5edb418a8f5"

  # D-59: trust-manager copies the data CA's certificate, and EHOS's, into every environment's
  # namespace. Its trust namespace is cert-manager's, where the data CA's key is kept; it writes
  # ConfigMaps only, and installs no public trust bundle, which nothing here uses.
  @trust_manager_version "v0.25.0"
  @trust_manager_chart "oci://quay.io/jetstack/charts/trust-manager@sha256:ef4540d4c3b7eb8cd498e3420aa5171ccc7434b7fa5e3168f1218d22906dbecb"
  # Its image, by the digest of v0.25.0's index, as cert-manager's (ehos-tools#805); it moves with
  # the chart.
  @trust_manager_image "sha256:0521921c2a46d14d0417336b20bcde69215ef3164f2977cc939d53c6e5224a17"

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
  # eh-os D-158 (eh-os#1301): with public certificates, the console's certificate is in a Secret of
  # another name, so that a move issues it for the new host while the old host serves from the
  # first.
  @public_tls_secret "ehos-governance-public-tls"
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
          progress: (Report.event() -> any()),
          clock: module(),
          server_command: String.t()
        }

  @doc false
  def quiet(_event), do: :ok

  # A required option, refused by its name alone: the options can hold the token, the passphrase,
  # the SMTP password or `:registry_auth`, and the `KeyError` of `Keyword.fetch!/2` holds every
  # one of them (ehos-tools#543). This one holds the key alone, which `ehosctl` prints.
  defp required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key
    end
  end

  @doc "The console's Certificate, and its Secret, under the installation's CA."
  @spec tls_secret() :: String.t()
  def tls_secret, do: @tls_secret

  @doc "The console's Certificate, and its Secret, with public certificates (eh-os D-158)."
  @spec public_tls_secret() :: String.t()
  def public_tls_secret, do: @public_tls_secret

  @doc "The CA's name, which is also its `ClusterIssuer`'s and its Secret's."
  @spec ca_name() :: String.t()
  def ca_name, do: @ca_name

  @typedoc """
  The outcome of a command: `{:ok, report}` saying what was done, as parts, or `{:error, message}`
  saying why it was not: a sentence an operator can act on, or an `EhosPlatform.Failure` that holds
  it with what a program printed.
  """
  @type result :: {:ok, Report.t()} | {:error, Failure.message()}

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

  With public certificates (eh-os D-158), no CA is made for the console's host. Before the chart,
  acme-dns, the two Let's Encrypt account keys and the chart's two ACME issuers are made, or kept
  from an earlier run (`EhosPlatform.PublicCertificates`), and the seven DNS records the company
  makes are checked at its authoritative name servers (`EhosPlatform.DomainRecords`), once acme-dns
  answers on the server's port 53, as Let's Encrypt asks it; until it answers, the install ends
  there, and an installation that runs is warned instead. While a record
  is missing or wrong, the install ends there, with each record, what it is for and what the name
  servers answer: the company makes them, and runs the command again. Once each is right, the chart
  is installed with the ACME issuers and Let's Encrypt's roots, which `ca.crt` then holds. An
  installation that runs is upgraded whatever its records say, and warned of each that changed.
  One that runs under its own CA moves (eh-os#1301): the same two passes, then the console's
  certificate for the new host while the old host serves, and only once it is issued the switch,
  in `EhosPlatform.Move`'s order; until then nothing it serves, and no `ca.crt`, changes.
  `install.json` names the host once the chart serves it. An install under the installation's own
  CA removes what a move that was abandoned left (`EhosPlatform.Move.abandoned_removed/1`).

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
    * `:release_option` — as for `EhosPlatform.Server`: the option of the server's `up` that names
      an EHOS release (`--version` for `ehosctl`). None: the sentences name the release in words.
    * `:token` — the pull credential's token. Defaults to `GHCR_TOKEN`.
    * `:username` — the GitHub user the token belongs to. Defaults to `GHCR_USERNAME`, or the
      GitHub CLI's user.
    * `:switch_traefik` — `true` to switch a server that runs k3s's Traefik, above.
    * `:public_certificates` — `true` to install with certificates from Let's Encrypt (eh-os
      D-158), at a `:host` of the company's own on a server `up` opened port 53 on, below. An
      installation that has them keeps them whether it is given or not; one that runs under its
      own CA moves to them, and to the host, in `EhosPlatform.Move`'s order.
    * `:skip_port_53_check` — `true` goes on when acme-dns does not answer on the server's port 53
      from this machine, with a warning instead of a refusal: for a network that answers DNS
      itself (ehos-tools#891), from which the answer proves nothing. Defaults to false.
    * `:allowed_domains` — the company's domains under which a person may map an application's
      entry (eh-os D-155), written into the chart's `environments.domains.allowed`, each checked
      by `EhosPlatform.AllowedDomains.check/2`, and refused, before anything changes, on an
      installation without public certificates. None leaves it to the chart, which allows none.
    * `:external_databases` and `:external_under_development` — the databases outside the
      installation (eh-os D-170, T-29) and whether the chart takes them, written into the chart's
      `dataResources.external` and `dataResources.externalUnderDevelopment`, as `installed/1`
      reads them back. None writes none, which leaves the chart's: no database, and the list
      refused.
    * `:dns` and `:certificate_log` — the `EhosPlatform.Dns` and `EhosPlatform.CertificateLog`
      the company's records are checked through, `EhosPlatform.DnsImpl` and
      `EhosPlatform.CertificateLogImpl` unless given.
    * `:passphrase` and `:ssh_key` — for the switch, as for `EhosPlatform.Server`. The passphrase
      defaults to `EHOS_STATE_PASSPHRASE`, the key to the one `EhosPlatform.Server.up/1` recorded,
      else `~/.ssh/ehos_oci`.
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
    dir = opts |> Keyword.get(:home, "~/.ehos") |> Env.expand(opts) |> Path.join(name)
    runner = Keyword.get(opts, :runner, CommandRunnerImpl)
    progress = Keyword.get(opts, :progress, &quiet/1)
    server_command = Keyword.get(opts, :server_command, @server_command)
    tunnel = tunnel_command(opts)
    ca_file = Path.join(dir, "ca.crt")

    allowed_domains = Keyword.get(opts, :allowed_domains)

    with {:ok, digest} <- digest(Keyword.get(opts, :digest)),
         :ok <- traefik_serves(Keyword.get(opts, :installed)),
         {:ok, kubeconfig} <- kubeconfig(dir, tunnel),
         {:ok, host} <- host(opts, dir, tunnel),
         :ok <- AllowedDomains.check(allowed_domains || [], host),
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
         {:ok, public} <- public_certificates(target, dir, opts),
         :ok <- allowed_with(allowed_domains, public),
         {:ok, smtp_password} <- smtp_password(target, opts),
         {:ok, registry_auth} <- credential(target, opts),
         :ok <- smtp_written(target, smtp_password),
         {:ok, installation} <- Server.description(dir, name),
         # ehos-tools#887: before anything pulls an image, which the earlier Service can stop.
         :ok <- PublicCertificates.earlier_service_removed(target),
         :ok <- switch_server(target, switch, opts),
         :ok <- prerequisites(target),
         # eh-os D-158: with public certificates, the installation's CA is not made for the
         # console's host.
         :ok <- own_authority(target, public),
         chart_opts = [
           repository: @repository,
           digest: digest,
           # With public certificates, the roots the chart gives workloads are the package's own:
           # a move writes the operator's ca.crt only when it switches (eh-os#1301).
           ca_file: if(public, do: PublicCertificates.roots(), else: ca_file),
           allowed_image_prefixes: ["ghcr.io/empoweredhouse/"],
           pull_credential?: true,
           own_pull_credential?: true,
           installation: installation,
           installed: Keyword.get(opts, :installed),
           sign_in: Keyword.get(opts, :sign_in),
           four_eyes: Keyword.get(opts, :four_eyes),
           mail: Keyword.get(opts, :mail),
           registry_auth: registry_auth,
           public_certificates: if(public, do: []),
           allowed_domains: allowed_domains,
           external_databases: Keyword.get(opts, :external_databases),
           external_under_development: Keyword.get(opts, :external_under_development)
         ],
         {:ok, records} <- domain_records(target, public, chart_opts, opts),
         # What runs is recorded as soon as the chart serves the host, before a move removes
         # the installation's CA and waits for the addresses: a run stopped then leaves the
         # record naming the host that answers.
         record = fn -> recorded(dir, digest, host) end,
         {:ok, waiting} <-
           switch(target, public, ca_file, with_records(chart_opts, records), record, opts),
         # After what runs is recorded: a restart that fails leaves the record true, and the
         # Secret marked, so the next run restarts the plane again. The databases first, so the
         # plane restarts against a database that is up.
         :ok <- restart_outdated_databases(target),
         :ok <- restart_for_password(target, smtp_password) do
      moved(target, public, ca_file)
      waiting_addresses(target, waiting)
      {:ok, running(host, digest, ca_file, public, opts)}
    end
  end

  # eh-os D-158 (eh-os#1301): an installation under its own CA moves to public certificates in
  # `EhosPlatform.Move`'s order. Any other gives pods the host, writes what the operator trusts and
  # installs the chart; one with public certificates then removes an installation's CA a move
  # that stopped after the chart left behind. Returns the addresses still without a certificate.
  defp switch(target, %{moving_from: old} = public, ca_file, chart_opts, record, opts) do
    Move.run(
      target,
      [
        render: fn -> render(target, chart_opts) end,
        # What the operator trusts, and what runs, change only once the chart serves the new
        # host.
        chart: fn ->
          with :ok <- chart(target, chart_opts),
               :ok <- trust(target, public, ca_file),
               do: record.()
        end,
        moving_from: old
      ] ++ Keyword.take(opts, [:certificate_timeout, :addresses_timeout])
    )
  end

  defp switch(target, public, ca_file, chart_opts, record, _opts) do
    with :ok <- name_in_cluster(target),
         :ok <- trust(target, public, ca_file),
         :ok <- chart(target, chart_opts),
         :ok <- record.(),
         :ok <- if(public, do: Move.own_authority_removed(target), else: :ok),
         do: {:ok, []}
  end

  # D-79: what runs, beside the installation's other files, so the next upgrade starts from it.
  defp recorded(dir, digest, host) do
    write_file(
      Path.join(dir, "install.json"),
      Jason.encode_to_iodata!(
        %{"digest" => digest, "host" => host, "repository" => @repository},
        pretty: true
      )
    )
  end

  # Under its own CA, what a move that was abandoned left is removed once the CA is there
  # (eh-os#1301).
  defp own_authority(target, nil) do
    with :ok <- certificate_authority(target), do: Move.abandoned_removed(target)
  end

  defp own_authority(_target, _public), do: :ok

  # Under its own CA at the host it is given, it keeps its host and its issuer: nobody signs in
  # again, but what a pipeline trusts changes all the same.
  defp moved(target, %{moving_from: host}, ca_file) when host == target.host do
    target.progress.(
      {:warning, "The CA of the installation no longer signs the console.",
       "Delete EHOSCTL_CA_PEM from each repository of an application, with the commands under " <>
         "Next. Give any other pipeline #{ca_file} as EHOSCTL_CA_FILE."}
    )
  end

  defp moved(target, %{moving_from: old}, ca_file) do
    target.progress.(
      {:warning, "EHOS moved from #{old} to #{target.host}.",
       "Each person must sign in again, and links to #{old} no longer open. Set the new " <>
         "address, and delete EHOSCTL_CA_PEM, in each repository of an application, with the " <>
         "commands under Next. Give any other pipeline the new EHOSCTL_URL, and #{ca_file} as " <>
         "EHOSCTL_CA_FILE."}
    )
  end

  defp moved(_target, _public, _ca_file), do: :ok

  defp waiting_addresses(_target, []), do: :ok

  defp waiting_addresses(target, waiting) do
    target.progress.(
      {:warning, without_certificate(waiting),
       Enum.map_join(waiting, "\n", &"- #{&1}") <>
         "\ncert-manager continues to ask for each certificate."}
    )
  end

  defp without_certificate([_address]), do: "1 address does not have a certificate yet."

  defp without_certificate(waiting),
    do: "#{length(waiting)} addresses do not have a certificate yet."

  # What runs, and the commands to run next: invite a person, and, after a move, the variables of
  # each repository of an application. A word the person replaces is in capitals, which a shell
  # reads as a word: `<email>` would be a redirection.
  defp running(host, digest, ca_file, public, opts) do
    %Report{
      outcome: "EHOS is running at https://#{host}.",
      values: [{"Image", "#{@repository}@#{digest}"} | trusted(public, ca_file)],
      next: [command(opts, "invite EMAIL") | repositories(public, host, opts)]
    }
  end

  # The CA's value is the path alone, which a script reads from its line.
  defp trusted(nil, ca_file),
    do: [
      {"Certificate",
       "Signed by the CA of the installation. A browser and a pipeline trust it once given the " <>
         "CA file."},
      {"CA", ca_file}
    ]

  defp trusted(_public, ca_file),
    do: [
      {"Certificate",
       "From Let's Encrypt, which browsers trust. The CA file holds its roots, for " <>
         "EHOSCTL_CA_FILE in a pipeline."},
      {"CA", ca_file}
    ]

  # The CI that ehos_app generates reads two variables of its repository: the address, which a
  # new host changes, and the CA, which a move to Let's Encrypt makes stale (ehos-tools#901). Only
  # a person who signed in can list the repositories that EHOS trusts, and the installer acts
  # without one: `trusts list` is ehosctl's own command, not the server's.
  defp repositories(%{moving_from: host}, host, opts), do: [ca_pem(), listed(opts)]

  defp repositories(%{moving_from: _old}, host, opts),
    do: [
      "gh variable set EHOSCTL_URL --repo OWNER/REPOSITORY --body https://#{host}",
      ca_pem(),
      listed(opts)
    ]

  defp repositories(_public, _host, _opts), do: []

  defp ca_pem, do: "gh variable delete EHOSCTL_CA_PEM --repo OWNER/REPOSITORY"
  defp listed(opts), do: "ehosctl trusts list --app APPLICATION#{named(opts)}"

  # eh-os D-155: only the ACME account certifies a domain of the company's own, so the chart refuses
  # allowed domains without public certificates; refused here before anything changes.
  defp allowed_with(domains, nil) when domains not in [nil, []],
    do:
      {:error,
       "Allowed domains need public certificates: Let's Encrypt issues the certificate of each " <>
         "mapped domain. Install with public certificates first, or give no allowed domain. " <>
         "Nothing was changed"}

  defp allowed_with(_domains, _public), do: :ok

  # eh-os D-158: whether the installation has public certificates, `{:ok, %{address: …}}` with the
  # server's address, or `{:ok, nil}`. One whose console's certificate is from the console's ACME
  # issuer keeps them, whether `:public_certificates` is given or not; one that runs under the
  # installation's own CA is refused them, since moving it changes every workload's issuer. A new
  # one gets them when asked, at a host of the company's own, on a server whose port 53 is open.
  defp public_certificates(target, dir, opts) do
    asked? = Keyword.get(opts, :public_certificates) == true

    with {:ok, issuer} <- console_issuer(target),
         do: public_for(issuer, asked?, target, dir, opts)
  end

  defp public_for(issued, asked?, target, dir, opts) do
    acme = PublicCertificates.console_issuer()
    host = target.host

    cond do
      match?({^acme, ^host}, issued) ->
        with {:ok, public} <- public_host(target, dir, opts),
             do: {:ok, Map.put(public, :running?, true)}

      match?({^acme, _host}, issued) ->
        {:error,
         "EHOS runs at #{elem(issued, 1)} with public certificates. It cannot move to " <>
           "#{host} yet: give --host #{elem(issued, 1)}. Nothing was changed"}

      asked? and match?({@ca_name, _old}, issued) ->
        with {:ok, public} <- public_host(target, dir, opts),
             :ok <- Move.refused(target),
             do: {:ok, Map.put(public, :moving_from, elem(issued, 1))}

      asked? and issued != nil ->
        {:error,
         "The console's certificate is issued by #{elem(issued, 0)}, which this installer did " <>
           "not make, so it cannot move the installation to public certificates. Nothing was " <>
           "changed"}

      asked? ->
        public_host(target, dir, opts)

      true ->
        {:ok, nil}
    end
  end

  defp public_host(target, dir, opts) do
    host = target.host
    address = address_in(dir)

    cond do
      String.ends_with?(host, ".sslip.io") ->
        {:error,
         "--public-certificates needs a host of your company's own, with --host: Let's Encrypt " <>
           "does not issue certificates for #{host}. Nothing was changed"}

      DomainRecords.registered_domain?(host) ->
        {:error,
         "#{host} is a registered domain: the cluster would then send every name of your " <>
           "company to the server. Give a host under it, such as ehos.#{host}. Nothing was changed"}

      address == nil ->
        {:error,
         "The server's address is unknown, and the DNS records name it: open the tunnel first " <>
           "(#{tunnel_command(opts)}). Nothing was changed"}

      not port_53_open?(dir) ->
        {:error,
         "Port 53 of the server is closed, and Let's Encrypt asks acme-dns there for the " <>
           "console's certificate: run #{suggested(opts, "up --public-certificates")} first. " <>
           "Nothing was changed"}

      true ->
        {:ok, %{address: address, running?: false}}
    end
  end

  # The server's modules open port 53 when `up` was given `--public-certificates` (eh-os D-158),
  # which it records with the module's other variables.
  # sobelow_skip ["Traversal.FileModule"]
  defp port_53_open?(dir) do
    with {:ok, contents} <- File.read(Path.join(dir, "server.tfvars.json")),
         {:ok, %{"public_certificates" => true}} <- Jason.decode(contents) do
      true
    else
      _closed -> false
    end
  end

  # The issuer of the console's Certificate and the host it is for, or nil when there is none: a new
  # installation.
  defp console_issuer(target) do
    case certificate_kind?(target) do
      {:ok, true} -> read_console_issuer(target)
      {:ok, false} -> {:ok, nil}
      error -> error
    end
  end

  # Under the installation's CA first: a move that stopped before the chart was installed with the
  # new host still runs under it (eh-os#1301).
  defp read_console_issuer(target) do
    case read_issuer(target, @tls_secret) do
      {:ok, nil} -> read_issuer(target, @public_tls_secret)
      result -> result
    end
  end

  defp read_issuer(target, certificate) do
    args =
      kubectl_args(target, [
        "get",
        "certificates.cert-manager.io",
        certificate,
        "-n",
        @namespace,
        "--ignore-not-found",
        "--request-timeout=10s",
        "-o",
        "jsonpath={.spec.issuerRef.name} {.spec.dnsNames[0]}"
      ])

    case target.runner.run("kubectl", args) do
      {output, 0} -> {:ok, issued(output)}
      result -> failure("kubectl", result)
    end
  end

  # A new server has no cert-manager yet, and so no kind Certificate to read: told apart by its CRD,
  # an object the API server answers for. kubectl's "no resource type" would say the same of a
  # running installation whose kind is not served yet, just after a restart.
  defp certificate_kind?(target) do
    with {:ok, name} <-
           read_value(target, [
             "get",
             "crd",
             "certificates.cert-manager.io",
             "--ignore-not-found",
             "--request-timeout=10s",
             "-o",
             "name"
           ]),
         do:
           {:ok,
            name == "customresourcedefinition.apiextensions.k8s.io/certificates.cert-manager.io"}
  end

  # The runner merges stderr into the output, and kubectl can warn before the value or after it:
  # the value is the last line of a name and a host, and none is a new installation.
  defp issued(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/\A([a-z0-9][-a-z0-9.]*)(?: ([a-z0-9][-a-z0-9.]*))?\z/, line) do
        [_, issuer, host] -> {issuer, host}
        [_, issuer] -> {issuer, nil}
        nil -> nil
      end
    end)
  end

  # What environments and `ehosctl` trust for the console: the installation's CA, or, with public
  # certificates, Let's Encrypt's roots (eh-os D-158).
  # sobelow_skip ["Traversal.FileModule"]
  defp trust(target, nil, ca_file) do
    with {:ok, pem} <- ca_pem(target), do: write_file(ca_file, pem)
  end

  defp trust(_target, _public, ca_file),
    do: write_file(ca_file, File.read!(PublicCertificates.roots()))

  # eh-os D-158: acme-dns, the two accounts and their issuers, then the company's records, checked
  # at its authoritative name servers. The chart is installed only once each is right: until then
  # the records are said, with what to change, and nothing else is.
  #
  # The records' values go to the chart, `{:ok, values}`, so the governance plane checks the same
  # records each day and the console shows them (eh-os D-162); `{:ok, nil}` without public
  # certificates. While acme-dns or an account cannot be read, the release's own are kept, since
  # the chart is installed with no `--reuse-values`.
  defp domain_records(_target, nil, _chart_opts, _opts), do: {:ok, nil}

  defp domain_records(target, public, chart_opts, opts) do
    case accounts(target, public, chart_opts) do
      {:ok, challenge, accounts} ->
        values = %{
          address: public.address,
          challenge: challenge,
          console_account: accounts.console,
          addresses_account: accounts.addresses
        }

        checked_values(target, public, values, opts)

      # An installation that runs is upgraded while acme-dns or Let's Encrypt does not answer: its
      # certificates are kept until they must be renewed, which needs both again.
      {:error, message} when public.running? ->
        target.progress.(
          {:warning,
           "acme-dns or a Let's Encrypt account is not ready, so the DNS records were not " <>
             "checked.",
           "The console's certificate cannot be renewed until it is. acme-dns may also have no " <>
             "Service on port 53 until its step succeeds: run this command again. " <>
             "`kubectl -n ehos-acme-dns get pods,services` and `kubectl get clusterissuers` " <>
             "say why: #{message}"}
        )

        {:ok, release_records(target)}

      error ->
        error
    end
  end

  defp checked_values(target, public, values, opts) do
    with :ok <- port_53_answers(target, public, opts),
         :ok <- check_records(target, public, values, opts),
         do: {:ok, values}
  end

  @port_53_retry_ms 10_000

  # ehos-tools#827: `server.tfvars.json` says what `up` was given, not what the server's modules
  # did with it. Modules before EHOS 0.27.0 have no `public_certificates` variable, which OpenTofu
  # only warns of, and keep port 53 closed: asked before anything waits for Let's Encrypt.
  # On a server just made, kube-proxy's rule for port 53 may follow acme-dns's rollout by a few
  # seconds: one more question 10 seconds later, before a refusal (ehos-tools#874). A running
  # installation is warned at once.
  defp port_53_answers(target, public, opts) do
    ask = fn ->
      DomainRecords.acme_dns_answers(target.host, public.address, Keyword.take(opts, [:dns]))
    end

    case {ask.(), public.running?} do
      {{:error, _reason}, false} ->
        target.clock.sleep(@port_53_retry_ms)
        port_53(ask.(), target, public, opts)

      {answer, _running?} ->
        port_53(answer, target, public, opts)
    end
  end

  defp port_53(:ok, _target, _public, _opts), do: :ok

  defp port_53({:error, reason}, target, %{running?: true} = public, opts) do
    target.progress.(
      {:warning,
       "acme-dns on the server, #{public.address}, does not answer on port 53 from this " <>
         "machine (#{reason}).",
       "If Let's Encrypt cannot reach it either, the console's certificate is not renewed. " <>
         "Make sure that the firewall of the server lets DNS in over UDP and TCP." <>
         port_53_local(local_network?(opts), target, public)}
    )

    :ok
  end

  defp port_53({:error, reason}, target, public, opts) do
    if Keyword.get(opts, :skip_port_53_check, false) do
      target.progress.(
        {:warning,
         "acme-dns on the server, #{public.address}, does not answer on port 53 from this " <>
           "machine (#{reason}).",
         "The install goes on, since the check is skipped. If Let's Encrypt cannot reach it " <>
           "either, the console gets no certificate." <>
           port_53_how(local_network?(opts), target, public)}
      )

      :ok
    else
      {:error,
       "acme-dns on the server, #{public.address}, does not answer on port 53 from this " <>
         "machine (#{reason}). Let's Encrypt asks acme-dns there for the console's " <>
         "certificate." <> port_53_cause(target, public, opts) <> " " <> unchanged(public)}
    end
  end

  # ehos-tools#891: a network that answers DNS itself, for any address, gives the parent zone's
  # SOA in place of acme-dns's. The server's release can still be the cause: `server.tfvars.json`
  # records the flag that modules before 0.27.0 ignored.
  defp port_53_cause(target, public, opts) do
    if local_network?(opts) do
      port_53_local(true, target, public) <>
        old_release(opts) <>
        " If port 53 of the server is open, run this command again from another network, such " <>
        "as a phone's hotspot, or with --skip-port-53-check."
    else
      old_release(opts) <> " " <> port_53_dig(target, public)
    end
  end

  defp old_release(opts) do
    " A server that an EHOS release before 0.27.0 made keeps port 53 closed, also with " <>
      "--public-certificates. Run " <>
      suggested(opts, "up --public-certificates" <> release(opts)) <>
      release_in_words(opts) <>
      ", then run this command again. A firewall that was added in " <>
      "the cloud of the server can also keep port 53 closed."
  end

  # What a warning adds: why this machine cannot tell, or how to check by hand.
  defp port_53_how(true, target, public), do: port_53_local(true, target, public)
  defp port_53_how(false, target, public), do: " " <> port_53_dig(target, public)

  defp port_53_local(false, _target, _public), do: ""

  defp port_53_local(true, target, public) do
    " The network of this machine answers DNS itself: an answer came from " <>
      "#{DomainRecords.no_dns_server()}, where no DNS server runs. So this machine cannot tell " <>
      "whether port 53 of the server is open. " <> port_53_dig(target, public)
  end

  defp local_network?(opts),
    do: DomainRecords.local_network_answers?(Keyword.take(opts, [:dns]))

  defp port_53_dig(target, public) do
    "To check by hand: `dig example.com @#{DomainRecords.no_dns_server()}` gives " <>
      "no answer on a network that does not answer DNS itself, and `dig SOA " <>
      "_acme-dns.#{target.host} @#{public.address}` gives the SOA of _acme-dns.#{target.host} " <>
      "once port 53 of the server is open."
  end

  defp release(opts) do
    case Keyword.get(opts, :release_option) do
      nil -> ""
      option -> " #{option} <0.27.0 or later>"
    end
  end

  defp release_in_words(opts) do
    if Keyword.get(opts, :release_option),
      do: "",
      else: " with the modules of EHOS 0.27.0 or later"
  end

  defp unchanged(%{moving_from: old}), do: "EHOS did not move, and still answers at #{old}"
  defp unchanged(_public), do: "EHOS is not installed yet"

  # The records' values the running release holds, or nil when it holds none or cannot be read.
  defp release_records(target) do
    case helm_json(target, [
           "get",
           "values",
           "ehos",
           "--namespace",
           "ehos-system",
           "--output",
           "json"
         ]) do
      {:ok, %{"publicCertificates" => %{"records" => records}}} ->
        PublicCertificates.records(records)

      _none ->
        nil
    end
  end

  defp with_records(chart_opts, nil), do: chart_opts

  defp with_records(chart_opts, values),
    do: Keyword.update!(chart_opts, :public_certificates, &Keyword.put(&1, :records, values))

  defp accounts(target, public, chart_opts) do
    with :ok <- PublicCertificates.pull_credential(target, chart_opts[:registry_auth]),
         {:ok, challenge} <- PublicCertificates.acme_dns(target),
         :ok <- PublicCertificates.account_keys(target),
         :ok <- moving_policy(target, public, chart_opts),
         {:ok, accounts} <-
           PublicCertificates.issuers(target, fn -> render(target, chart_opts) end),
         do: {:ok, challenge, accounts}
  end

  # eh-os#1301: an installation that runs has workloads, which the ACME issuers' policy keeps from
  # being issued a certificate from either account while a move waits for the records.
  defp moving_policy(target, %{moving_from: _old}, chart_opts) do
    with {:ok, rendered} <- render(target, chart_opts), do: Move.issuers(target, rendered)
  end

  defp moving_policy(_target, _public, _chart_opts), do: :ok

  # With the sentence on the network of this machine, no name server answered: the problems are
  # what that network did, not a change of the records, and each is said as it is
  # (ehos-tools#901).
  defp changed(target, problems) do
    if DomainRecords.local_network_note() in problems,
      do: for(problem <- problems, do: target.progress.({:warning, problem, nil})),
      else:
        target.progress.(
          {:warning, "The DNS records for #{target.host} changed.", Enum.join(problems, "\n")}
        )
  end

  defp check_records(target, public, values, opts) do
    records = DomainRecords.records(Map.put(values, :host, target.host))

    records
    |> DomainRecords.check(Keyword.take(opts, [:dns]))
    |> checked(target, public, records, opts)
  end

  # The logs are read on a first install alone: an upgrade would print the same certificates again.
  defp checked(:ok, target, %{running?: true}, _records, _opts) do
    target.progress.({:step, "The DNS records for #{target.host} are in place"})
    :ok
  end

  defp checked(:ok, target, _public, _records, opts) do
    target.progress.({:step, "The DNS records for #{target.host} are in place"})

    for warning <- DomainRecords.warnings(target.host, Keyword.take(opts, [:certificate_log])),
        do: target.progress.({:warning, warning, nil})

    :ok
  end

  # An installation that runs is upgraded whatever the records say, and told what changed: its
  # certificates still have a third of their life when one is renewed.
  defp checked({:error, problems}, target, %{running?: true}, _records, _opts) do
    changed(target, problems)
    :ok
  end

  defp checked({:error, problems}, target, %{moving_from: old}, records, _opts) do
    {:error,
     "EHOS did not move, and still answers at #{old}. acme-dns and the two Let's Encrypt " <>
       "accounts are ready. Make these DNS records for #{target.host}, then run this command " <>
       "again:\n" <>
       DomainRecords.format(records) <>
       "\nWhat your name servers answer now:\n" <>
       Enum.map_join(problems, "\n", &("  - " <> &1))}
  end

  defp checked({:error, problems}, target, _public, records, _opts) do
    {:error,
     "EHOS is not installed yet. acme-dns and the two Let's Encrypt accounts are ready. " <>
       "Make these DNS records for #{target.host}, then run this command again:\n" <>
       DomainRecords.format(records) <>
       "\nWhat your name servers answer now:\n" <>
       Enum.map_join(problems, "\n", &("  - " <> &1))}
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
  @spec traefik_serves(map() | nil) :: :ok | {:error, Failure.message()}
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
  @spec digest(String.t() | nil) :: {:ok, String.t()} | {:error, Failure.message()}
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
    * `:allowed_domains` — the domains that revision allows a mapping under (eh-os D-155), its
      `environments.domains.allowed`; `nil` when it was given none and runs the chart's;
    * `:external_databases` — the databases outside the installation that revision lists (eh-os
      D-170, T-29), its `dataResources.external`, as `EhosPlatform.ExternalDatabases.read_back/1`
      keeps them: the chart's fields alone, each of its type, and only an entry whose managing
      role is in the Secret `ehos-external-<name>`; `nil` when it lists none;
    * `:external_under_development` — its `dataResources.externalUnderDevelopment`, as the chart
      reads it: `true` for `true` or `"true"`, `false` for any other value, and `nil` when it was
      given none;
    * `:warnings` — a sentence for each entry of `dataResources.external` that
      `:external_databases` leaves out, for the caller to say; `[]` when none is;
    * `:revision` — the number of the deployed revision these were read from, which a caller
      reads again to tell that nothing deployed since; `nil` when none was;
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
          allowed_domains: [String.t()] | nil,
          external_databases: [ExternalDatabases.entry()] | nil,
          external_under_development: boolean() | nil,
          warnings: [String.t()],
          revision: pos_integer() | nil,
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
  @spec installed(keyword()) :: {:ok, installed()} | {:error, Failure.message()}
  def installed(opts) do
    case deployed(opts) do
      {:ok, %{values: nil, last: last}} ->
        {:ok, nothing_running(last)}

      {:ok, %{values: values, revision: revision, release: release, last: last} = read} ->
        {:ok,
         values
         |> recorded()
         |> Map.put(:four_eyes_runs, four_eyes_runs(read.runner, release, revision))
         |> Map.put(:revision, revision)
         |> Map.put(:last, last)}

      error ->
        error
    end
  end

  # The Helm release's last deployed revision, through the installation's kubeconfig: its
  # `:values` and `:revision`, `nil` for both when none was ever deployed, and `:last`, as
  # `installed/1` says; with the `:release` arguments that name it to Helm, its `:kubeconfig`
  # and the `:runner`.
  defp deployed(opts) do
    with {:ok, %{runner: runner, kubeconfig: kubeconfig} = target} <- tunnel_target(opts),
         release = [
           "ehos",
           "--namespace",
           @namespace,
           "--kube-context",
           target.context,
           "--kubeconfig",
           kubeconfig
         ],
         # `helm get manifest` has no `--output`: it is given only to the calls that take it.
         on_release = release ++ ["--output", "json"],
         {:ok, revisions} <- history(runner, on_release, opts),
         deployed = deployed_of(revisions),
         {:ok, values} <- deployed_values(deployed, runner, on_release, opts) do
      {:ok,
       %{
         values: values,
         revision: deployed && deployed.revision,
         last: last_of(revisions),
         release: release,
         kubeconfig: kubeconfig,
         runner: runner
       }}
    end
  end

  defp deployed_of(revisions),
    do: revisions |> Enum.filter(&(&1.status == "deployed")) |> List.last()

  # The last revision, when it is not the one that runs.
  defp last_of(revisions) do
    last = List.last(revisions)
    if last != deployed_of(revisions), do: last
  end

  defp deployed_values(nil, _runner, _on_release, _opts), do: {:ok, nil}

  defp deployed_values(%{revision: revision}, runner, on_release, opts),
    do: values(runner, on_release, revision, opts)

  defp nothing_running(last) do
    %{
      running: :none,
      digest: nil,
      host: nil,
      sign_in: nil,
      four_eyes: nil,
      four_eyes_runs: nil,
      mail: nil,
      allowed_domains: nil,
      external_databases: nil,
      external_under_development: nil,
      warnings: [],
      revision: nil,
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
    do:
      {:error, Failure.added(message, "\nIs the tunnel open? #{tunnel_command(opts)} opens it.")}

  # The command that opens the tunnel, quoted, as the operator runs the server's commands
  # (`:server_command`), and naming the installation when the caller asks (`:name_in_commands`):
  # without it, the command reaches whichever installation is the operator's default.
  defp tunnel_command(opts), do: suggested(opts, "tunnel")

  # A command of the server's to suggest, quoted, built as `tunnel_command/1` says.
  defp suggested(opts, subcommand), do: "`#{command(opts, subcommand)}`"

  # The same command on a line of its own, for a report's next commands.
  defp command(opts, subcommand),
    do: "#{Keyword.get(opts, :server_command, @server_command)} #{subcommand}#{named(opts)}"

  defp named(opts) do
    if Keyword.get(opts, :name_in_commands, false),
      do:
        " #{Keyword.get(opts, :name_option, @name_option)} #{Keyword.get(opts, :name, "trial")}",
      else: ""
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
    {external, warnings} = ExternalDatabases.read_back(at(values, ["dataResources", "external"]))

    %{
      running: running(values),
      digest: recorded_digest(at(values, ["image", "digest"])),
      host: recorded_host(at(values, ["governance", "host"])),
      sign_in: sign_in(values),
      four_eyes: four_eyes(values),
      mail: mail(values),
      allowed_domains: allowed_domains(values),
      external_databases: external,
      external_under_development:
        under_development(at(values, ["dataResources", "externalUnderDevelopment"])),
      warnings: warnings
    }
  end

  # eh-os D-170: read as the chart reads it, which takes a list only when this is "true".
  defp under_development(nil), do: nil
  defp under_development(value), do: value in [true, "true"]

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

  # eh-os D-155: a list of names, as `server/1` writes it; anything else is the chart's to refuse,
  # and is not carried into the next install.
  defp allowed_domains(values) do
    case at(values, ["environments", "domains", "allowed"]) do
      [_ | _] = domains -> if Enum.all?(domains, &is_binary/1), do: domains
      _none -> nil
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
  @spec invite(keyword()) :: {:ok, invited()} | {:error, Failure.message()}
  def invite(opts) do
    name = Keyword.get(opts, :name, "trial")
    dir = opts |> Keyword.get(:home, "~/.ehos") |> Env.expand(opts) |> Path.join(name)
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
  @spec email(String.t()) :: {:ok, String.t()} | {:error, Failure.message()}
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
  @spec invite_expression(String.t()) :: {:ok, String.t()} | {:error, Failure.message()}
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
    |> Env.expand(opts)
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
          {:warning,
           "The nodes of the cluster have #{total}m of CPU to allocate, and the pods of EHOS " <>
             "request about 1000m of it.",
           "Kubernetes may then never schedule the grants Job of an application and its " <>
             "rollouts. Give the server 2 CPUs or more. On Oracle, run " <>
             "`#{target.server_command} up --ocpus 2`."}
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
        {:warning, "The cluster runs Kubernetes #{version}, older than 1.#{@recent_minor}.",
         "On it, when the isolation policy of EHOS is deleted and made again, it refuses the " <>
           "pods of each new environment until the API server restarts. Move a server that " <>
           "`#{target.server_command} up` made to 1.#{@recent_minor} by hand one time, with " <>
           "the gateway-api-crd of k3s disabled beside its Traefik. The owner of any other " <>
           "cluster upgrades it."}
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
        target.progress.(
          {:step, "Keeping the SMTP password #{@smtp_secret}: it is the one given"}
        )

        {:ok, :keep}
      else
        {:ok, {:write, password}}
      end
    end
  end

  defp held_secret(target, username) do
    case secret(target, @smtp_secret, "the SMTP password") do
      {:ok, true} ->
        target.progress.({:step, "Keeping the SMTP password #{@smtp_secret} the cluster holds"})
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
    target.progress.(
      {:step, "Restarting the governance plane, so it sends mail with the new password"}
    )

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
  # Each call has a deadline, as the other reads here do, so a tunnel that stops answering costs
  # each check 10 s at most rather than holding the run, a database perhaps down, for ever.
  @request_timeout "--request-timeout=10s"
  @read_json [@request_timeout, "-o", "json"]

  @doc """
  Restarts each CloudNativePG cluster in `ehos-system` and `ehos-data` whose instance pods do not
  run with the priority class its spec gives, one at a time, and waits until each is healthy
  before the next.

  CloudNativePG applies a change to a cluster's `priorityClassName` only to a new pod, so a class
  the chart gives an installation made before it (eh-os D-143) stays off the running instances
  until each is restarted ([ehos-tools#680](https://github.com/EmpoweredHouse/ehos-tools/issues/680)).
  The restart is CloudNativePG's own, the annotation `kubectl.kubernetes.io/restartedAt` on the
  cluster, which makes its pods again. The pods are compared with the spec, never with a version,
  so a cluster whose pods match it is left as it is, and so is one that gives no class or is not
  healthy before its restart. A cluster of one instance is down until its new pod is ready: the
  console for the governance plane's, an instance's applications for theirs.
  """
  @spec restart_outdated_databases(t()) :: :ok | {:error, Failure.message()}
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
       Failure.within(
         message,
         "The PostgreSQL clusters could not be compared with their pods, so none was restarted: ",
         "\nRun the command again to restart any healthy cluster whose pods run without its " <>
           "priority class"
       )}

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

  # Every pod has the priority class the cluster's spec gives a new one; another field CloudNativePG
  # applies only to a new pod would be compared here too. A cluster with no pod yet is
  # CloudNativePG's to make.
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
      {:warning,
       "PostgreSQL #{namespace}/#{name} is not restarted, because it is not healthy " <>
         "(phase #{inspect(phase)}).",
       "Its pods run without #{class_name(class)} until it is healthy and the command runs " <>
         "again."}
    )

    :ok
  end

  defp announce_restarts(_target, []), do: :ok

  defp announce_restarts(target, outdated) do
    names =
      Enum.map_join(outdated, ", ", fn {namespace, name, _class, _phase} ->
        "#{namespace}/#{name}"
      end)

    target.progress.(
      {:warning,
       "The PostgreSQL pods of #{names} run without the priority class of their cluster.",
       "Each cluster is restarted, one at a time. A cluster of one instance is down until its " <>
         "new pod is ready, usually 1 to 3 minutes. The command checks a cluster at most " <>
         "#{@database_polls} times, #{div(@database_poll_ms, 1000)} s apart. The console stops " <>
         "while a cluster in #{@namespace} restarts. The applications of an instance in " <>
         "ehos-data stop while that instance restarts."}
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

  # Asked again just before its restart: a cluster healthy when the clusters were listed may not
  # be once those before it have restarted.
  defp restart_database(target, {namespace, name, class, _phase}) do
    with {:ok, cluster} <-
           target
           |> kubectl_json(["get", @cnpg_clusters, name, "-n", namespace | @read_json])
           |> or_not_restarted(namespace, name) do
      restart_healthy(target, {namespace, name, class, get_in(cluster, ["status", "phase"])})
    end
  end

  defp restart_healthy(target, {namespace, name, class, @healthy}) do
    target.progress.(
      {:step,
       "Restarting PostgreSQL #{namespace}/#{name}, so that its pods run with " <>
         "#{class_name(class)}, and waiting until it is healthy"}
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

  defp restart_healthy(target, database), do: leave_unhealthy(target, database)

  defp or_not_restarted(:ok, _namespace, _name), do: :ok
  defp or_not_restarted({:ok, _value} = read, _namespace, _name), do: read

  defp or_not_restarted({:error, message}, namespace, name),
    do:
      {:error,
       Failure.within(
         message,
         "kubectl did not confirm that PostgreSQL #{namespace}/#{name} was asked to restart: ",
         "\nRun the command again to restart it, once it is healthy, and the clusters after it"
       )}

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
         "-n #{namespace} #{name}`. Once it is healthy, run the command again to restart any " <>
         "cluster whose pods still run without its priority class"}

  defp database_healthy(target, namespace, name, polls, _last) do
    case restarted(target, namespace, name) do
      :ok ->
        target.progress.({:step, "PostgreSQL #{namespace}/#{name} is healthy again"})
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

  # kubectl prints the JSON it is asked for from a line that starts with `{` to one that ends with
  # `}`, among any warning the runner merges in, before it or after it.
  defp kubectl_json(target, args) do
    with {:ok, output} <- kubectl_output(target, args) do
      output |> object_in() |> json_object(args, output)
    end
  end

  # The JSON object kubectl printed, indented over many lines, from the first line that starts
  # with `{` to the last that ends with `}`: the runner merges stderr, so a warning can come
  # before or after it.
  defp object_in(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
    |> Enum.reverse()
    |> Enum.drop_while(&(not String.ends_with?(&1, "}")))
    |> Enum.reverse()
    |> Enum.join("\n")
    |> Jason.decode()
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
            target.progress.(
              {:step, "Keeping the pull credential #{@pull_credential} the cluster holds"}
            )

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
  cert-manager's and trust-manager's images run by the digests of their indexes (ehos-tools#805):
  a release installed without these digests differs in its values the same way, so is upgraded.

  Before any of them, the admission policy `priv/manifests/external-names.yaml`, which admits an
  `ExternalName` Service only in `ehos-addresses` and `ehos-ingress`, since Traefik follows one
  (eh-os D-117, eh-os#828); and `ehos-addresses`, as EHOS's chart makes it, since Traefik's
  chart makes its Role there (eh-os#846).

  Refused, installing nothing, on a cluster where k3s's bundled Traefik is installed
  (`no_bundled_traefik/1`); and, installing no release, where an `ExternalName` Service made
  before the policy is outside those two namespaces, since the policy sees only what is written
  after it.
  """
  @spec prerequisites(t()) :: :ok | {:error, Failure.message()}
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
  @spec no_bundled_traefik(t()) :: :ok | {:error, Failure.message()}
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
      {:step,
       "Switching the server from k3s's Traefik to EHOS's: the console and its applications " <>
         "are down for a few minutes"}
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
         Failure.printed(
           "Switching the server's Traefik failed with exit status #{status}. If #{@drop_in} " <>
             "was written, k3s takes its Traefik out at its next restart: run the command again " <>
             "with --switch-traefik to finish, or remove the file over SSH.",
           "ssh",
           output
         )}

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
        target.progress.({:step, "k3s's Traefik is gone from the server"})
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
        #
        # eh-os D-158 (eh-os#1195): a DNS-01 record is checked through the pod's resolver alone.
        # Otherwise cert-manager asks the zone's name servers by name, and `_acme-dns.<host>`'s is
        # `<host>`, which CoreDNS's rule answers with Traefik; the rule leaves the two names it
        # checks to the server's resolver, which reads what Let's Encrypt reads.
        values: %{
          "acmesolver" => %{"image" => %{"digest" => @cert_manager_solver}},
          "crds" => %{"enabled" => true},
          "dns01RecursiveNameserversOnly" => true,
          "enableCertificateOwnerRef" => true,
          "global" => %{"priorityClassName" => @critical},
          "image" => %{"digest" => @cert_manager_controller},
          "resources" => %{"requests" => %{"cpu" => "20m", "memory" => "112Mi"}},
          "cainjector" => %{
            "image" => %{"digest" => @cert_manager_cainjector},
            "resources" => %{"requests" => %{"cpu" => "10m", "memory" => "48Mi"}}
          },
          "startupapicheck" => %{"image" => %{"digest" => @cert_manager_startupapicheck}},
          "webhook" => %{
            "image" => %{"digest" => @cert_manager_webhook},
            "resources" => %{"requests" => %{"cpu" => "10m", "memory" => "48Mi"}}
          }
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
          "image" => %{"digest" => @trust_manager_image},
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
      target.progress.(
        {:step, "#{release.title} is installed (chart #{release.version}); waiting for it"}
      )

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
      target.progress.({:step, "Installing #{release.title} (chart #{release.version})"})

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
  @spec certificate_authority(t()) :: :ok | {:error, Failure.message()}
  def certificate_authority(%__MODULE__{} = target) do
    target.progress.({:step, "Creating the installation's CA for #{target.host} (#{@local_ca})"})

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
          {:warning,
           "The CA of the installation was issued again, so that it signs #{target.host} and " <>
             "no IP address.",
           "Its key is the same. Replace each copy of its old certificate that you trust with " <>
             "the new one."}
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
  Gives pods the console's host and every name under it with no underscore in a label, through a
  CoreDNS rule that sends them to the ingress (D-45); the server's resolver answers the others,
  acme-dns's among them (eh-os D-158). CoreDNS reads the rule at start, so its pods are rolled
  out to take it, once for each rule: the rule's hash is on their template, and the same rule
  changes nothing, so an upgrade keeps name lookups in the cluster up.
  """
  @spec name_in_cluster(t()) :: :ok | {:error, Failure.message()}
  # The rule is read from the repository, its path a constant.
  # sobelow_skip ["Traversal.FileModule"]
  def name_in_cluster(%__MODULE__{} = target) do
    target.progress.({:step, "Giving pods the name #{target.host} (#{@coredns_custom})"})
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

      iex> EhosPlatform.Install.for_host(~S"^([^._]+\\.)*ehos\\.localhost\\.$", "ehos.example.org")
      ~S"^([^._]+\\.)*ehos\\.example\\.org\\.$"
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
  @spec adopt_console_certificate(t(), Path.t(), [String.t()]) ::
          :ok | {:error, Failure.message()}
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
    target.progress.({:step, "Handing the console's certificate over to the chart"})

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
  Waits, for at most `timeout` (two minutes unless given, as `kubectl wait` reads it), until
  cert-manager's Certificate `name` in `namespace` is ready:
  `:ok`, or `{:error, output}` with what `kubectl wait` printed when it is not by then or kubectl
  fails.
  """
  @spec wait_for_certificate(t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Failure.message()}
  def wait_for_certificate(%__MODULE__{} = target, namespace, name, timeout \\ "2m") do
    target.progress.({:step, "Waiting for the certificate #{namespace}/#{name}"})

    kubectl(target, [
      "wait",
      "--for=condition=Ready",
      "certificate/#{name}",
      "-n",
      namespace,
      "--timeout=#{timeout}"
    ])
  end

  @doc """
  The certificate of the installation's CA, in PEM, read from the cluster. Its key is never read.
  `{:error, {output, status}}` when kubectl fails, for the caller to explain.
  """
  @spec ca_certificate(t()) ::
          {:ok, String.t()} | {:error, Failure.message()} | {:error, {String.t(), integer()}}
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
  @spec pull_credential(t()) :: {:ok, boolean()} | {:error, Failure.message()}
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
  Writes the pull credential for `registry` into `namespace`, `ehos-system` unless given,
  replacing one there: a
  `kubernetes.io/dockerconfigjson` Secret, applied from a file only this user reads, which is
  removed after. The token is never an argument of a program, nor in what a failure prints.
  `namespace` is a name, or the whole Namespace to apply with the Secret.
  """
  @spec write_pull_credential(t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Failure.message()}
  @spec write_pull_credential(t(), String.t(), String.t(), String.t(), String.t() | map()) ::
          :ok | {:error, Failure.message()}
  def write_pull_credential(
        %__MODULE__{} = target,
        registry,
        username,
        token,
        namespace \\ @namespace
      )
      when is_binary(token) and token != "" do
    {name, namespace} = namespace_document(namespace)

    where =
      if name == @namespace, do: @pull_credential, else: "#{name}/#{@pull_credential}"

    target.progress.({:step, "Writing the pull credential for #{registry} (#{where})"})
    auth = Base.encode64("#{username}:#{token}")
    config = %{"auths" => %{registry => %{"username" => username, "auth" => auth}}}
    dockerconfigjson = Base.encode64(Jason.encode!(config))

    apply_secret(
      target,
      pull_secret(name, dockerconfigjson),
      [token, auth, dockerconfigjson],
      "[the token]",
      namespace
    )
  end

  @doc false
  # The `kubernetes.io/dockerconfigjson` Secret of the pull credential in `namespace`.
  @spec pull_secret(String.t(), String.t()) :: map()
  def pull_secret(namespace, dockerconfigjson),
    do: %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "type" => "kubernetes.io/dockerconfigjson",
      "metadata" => %{"name" => @pull_credential, "namespace" => namespace},
      "data" => %{".dockerconfigjson" => dockerconfigjson}
    }

  @doc """
  Writes the SMTP user's password into `ehos-system` (eh-os D-36), replacing one there: an Opaque
  Secret the chart reads under `password`, applied as the pull credential is. The password is
  never an argument of a program, nor in what a failure prints.
  """
  @spec write_smtp_password(t(), String.t()) :: :ok | {:error, Failure.message()}
  def write_smtp_password(%__MODULE__{} = target, password)
      when is_binary(password) and password != "" do
    target.progress.({:step, "Writing the SMTP password (#{@smtp_secret})"})
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

  @doc false
  # A Secret, with its namespace in case it is not there yet, applied from a file only this user
  # reads, which is removed after; what it holds, `hidden`, is replaced in what a failure prints.
  # `EhosPlatform.PublicCertificates` writes its Secrets in cert-manager's namespace through it.
  # `namespace` is the Namespace applied with it, its name alone unless given: a server-side apply
  # takes over what an earlier client-side apply set, and removes the labels and annotations it omits.
  # sobelow_skip ["Traversal.FileModule"]
  @spec apply_secret(t(), map(), [String.t()], String.t(), map() | nil) ::
          :ok | {:error, Failure.message()}
  def apply_secret(%__MODULE__{} = target, secret, hidden, placeholder, namespace \\ nil) do
    name = secret["metadata"]["name"]
    namespace = namespace || bare_namespace(secret["metadata"]["namespace"])
    in_namespace = namespace["metadata"]["name"]

    list = %{"apiVersion" => "v1", "kind" => "List", "items" => [namespace, secret]}

    # Server-side: a client-side apply keeps the whole object, the value in it, in the
    # `last-applied-configuration` annotation, a second copy anyone who may read the Secret's
    # metadata could read.
    with_private_json(name, list, fn path ->
      case kubectl(target, ["apply", "--server-side", "--force-conflicts", "-f", path]) do
        # One written before by a client-side apply keeps that copy until it is removed.
        :ok ->
          kubectl(target, [
            "annotate",
            "secret",
            name,
            "-n",
            in_namespace,
            "kubectl.kubernetes.io/last-applied-configuration-"
          ])

        error ->
          without(error, hidden, placeholder)
      end
    end)
  end

  # `json`, written to a file only this user reads, in a directory of its own, and `fun`
  # called with the file's path; the file is removed after, also when `fun` raises.
  # sobelow_skip ["Traversal.FileModule"]
  defp with_private_json(prefix, json, fun) do
    TmpDir.with_tmp_dir(prefix, fn dir ->
      path = Path.join(dir, "secret.json")
      # Made exclusively, so nothing already at the path, a link included, is written through.
      :ok = File.write(path, Jason.encode!(json), [:exclusive])
      File.chmod!(path, 0o600)

      try do
        fun.(path)
      after
        _ = File.rm(path)
      end
    end)
  end

  @doc """
  The chart that runs on an installation's server, rendered with the values of the Helm
  release's last deployed revision and, over them, the databases outside the installation that
  `opts` gives, as `chart/2` writes them: `helm template` of the chart of the version that runs,
  pulled by its digest, given those values in a file only this user reads, removed after. It
  changes nothing, so a caller lets the chart refuse a change before anything is written (T-29).

  The release's values hold no password: a password is in a Secret the values name.

  It renders the release's own values, not those `server/1` rebuilds from its options. So a
  refusal that only the rebuilt values cause shows at the install, after anything the caller
  wrote before it, such as a managing role's Secret.

  ## Options

    * `:external_databases` and `:external_under_development` — as for `chart/2`.
    * `:token` and `:username` — what Helm pulls the chart with, as for `server/1`; without a
      token, Helm's own login.
    * `:name`, `:home`, `:runner`, `:env`, `:progress`, `:server_command`, `:name_option`,
      `:name_in_commands` — as for `server/1`.
  """
  @spec render_running(keyword()) :: {:ok, String.t()} | {:error, Failure.message()}
  def render_running(opts) do
    with {:ok, %{values: values}} when is_map(values) <- deployed(opts),
         {:ok, chart} <- running_chart(values),
         {:ok, target} <- tunnel_target(opts, "", %Source{chart: {:oci, chart}, modules: "."}),
         {:ok, auth} <- render_auth(target, opts) do
      with_private_json("ehos-values", values, &render_over(target, auth, &1, opts))
    else
      {:ok, %{values: nil}} -> {:error, "No EHOS runs on the server: nothing was rendered"}
      error -> error
    end
  end

  # The release's values in `path`, and the databases outside the installation over them.
  defp render_over(target, auth, path, opts),
    do: with_external_values(opts, &rendered(target, auth, ["-f", path | &1]))

  defp rendered(target, auth, values) do
    TmpDir.with_tmp_dir("ehos-cluster", fn dir ->
      with {:ok, package} <- chart_reference(target, dir, auth),
           do: template(target, package, values)
    end)
  end

  defp running_chart(values) do
    case running(values) do
      %{"chart" => "oci://" <> _ = chart} ->
        {:ok, chart}

      _unknown ->
        {:error,
         "The EHOS that runs recorded no chart of a release, so its chart cannot be rendered. " <>
           "Install a release of EHOS first"}
    end
  end

  # A release's chart is pulled with the token while it is private; without one, Helm's own login.
  defp render_auth(target, opts) do
    token = Keyword.get_lazy(opts, :token, fn -> Env.from(opts).get("GHCR_TOKEN") end)

    if is_binary(token) and String.trim(token) != "" do
      with {:ok, username} <- username(target, opts), do: {:ok, {username, String.trim(token)}}
    else
      {:ok, nil}
    end
  end

  # An error whose message has each of `hidden` replaced by `placeholder`.
  defp without({:error, message}, hidden, placeholder),
    do:
      {:error,
       Failure.map_text(
         message,
         &Enum.reduce(hidden, &1, fn secret, text ->
           String.replace(text, secret, placeholder)
         end)
       )}

  defp without(result, _hidden, _placeholder), do: result

  @doc """
  Writes the managing role of the database outside the installation `name` (eh-os D-170, T-29),
  `username` and `password`, into its Secret, `ehos-external-<name>` in `ehos-data`, through the
  kubeconfig `tunnel` wrote: `EhosPlatform.ExternalDatabases.secret/4`, written to a file only
  this user reads, removed after, as `apply_secret/5` writes one.

  A new Secret is made with `kubectl create`, which refuses one already there. One already there
  is replaced, at the version read, only when the installer made it for the same database: with
  its label, its annotation for `name`, and no owner, as CloudNativePG's Secrets have. Any other
  is refused, with what holds the name, and nothing is written. Neither the password nor its
  base64 is ever an argument of a program, nor in what a failure says. Returns `:created` or
  `:replaced`.

  Options as `installed/1`'s, and `:progress`.
  """
  @spec write_external_secret(keyword(), String.t(), String.t(), String.t()) ::
          {:ok, :created | :replaced} | {:error, Failure.message()}
  def write_external_secret(opts, name, username, password)
      when is_binary(password) and password != "" do
    secret = ExternalDatabases.secret_name(name)
    hidden = [password, Base.encode64(password)]

    with {:ok, target} <- tunnel_target(opts),
         {:ok, held} <- held_external(target, secret) do
      target.progress.(
        {:step, "Writing the managing role of #{name} (#{@data_namespace}/#{secret})"}
      )

      held
      |> external_written(target, name, {username, password})
      |> without(hidden, "[the password]")
    end
  end

  defp external_written(nil, target, name, {username, password}) do
    manifest = ExternalDatabases.secret(name, username, password)

    with_private_json(ExternalDatabases.secret_name(name), manifest, fn path ->
      with :ok <- kubectl(target, ["create", "-f", path]), do: {:ok, :created}
    end)
  end

  defp external_written(held, target, name, {username, password}) do
    secret = ExternalDatabases.secret_name(name)

    case {ExternalDatabases.holder(held, name), get_in(held, ["metadata", "resourceVersion"])} do
      {:ours, version} when is_binary(version) ->
        manifest = ExternalDatabases.secret(name, username, password, version)
        with_private_json(secret, manifest, &replaced(target, &1))

      {:ours, _no_version} ->
        {:error, "kubectl gave the Secret #{@data_namespace}/#{secret} without its version"}

      {{:theirs, why}, _version} ->
        {:error,
         "The Secret #{@data_namespace}/#{secret} is there, and the installer did not make it " <>
           "for #{name}: #{why}. Nothing was written. Remove that Secret if nothing uses it, " <>
           "or give the database another name"}
    end
  end

  defp replaced(target, path) do
    with :ok <- kubectl(target, ["replace", "-f", path]), do: {:ok, :replaced}
  end

  # The Secret `name` in `ehos-data` as kubectl gives it, or nil when it is not there. Its data
  # is in the answer, which is read, never said.
  defp held_external(target, name) do
    args =
      kubectl_args(target, ["get", "secret", name, "-n", @data_namespace, "-o", "json"])

    "kubectl" |> target.runner.run(args) |> held_answer(name)
  end

  # kubectl prints the Secret as indented JSON, after any warning: read whole, never said, since
  # it holds the data.
  defp held_answer({output, 0}, name) do
    case object_in(output) do
      {:ok, %{"kind" => "Secret"} = held} -> {:ok, held}
      _other -> {:error, "kubectl gave something other than the Secret #{name}"}
    end
  end

  defp held_answer({output, status}, name) when is_integer(status) do
    if output =~ ~s|(NotFound): secrets "#{name}" not found|,
      do: {:ok, nil},
      else:
        {:error, "kubectl could not say whether #{@data_namespace} holds #{name}:\n" <> output}
  end

  defp held_answer(result, _name), do: failure("kubectl", result)

  # The installation's cluster through the kubeconfig `tunnel` wrote, for a call that reads or
  # writes objects there, or renders `source`'s chart for its `host`. A call that renders nothing
  # gives neither.
  defp tunnel_target(opts, host \\ "", source \\ %Source{chart: {:directory, "."}, modules: "."}) do
    name = Keyword.get(opts, :name, "trial")
    dir = opts |> Keyword.get(:home, "~/.ehos") |> Env.expand(opts) |> Path.join(name)

    with true <- Server.valid_name?(name) || {:error, Server.name_rule()},
         {:ok, kubeconfig} <- kubeconfig(dir, tunnel_command(opts)) do
      {:ok,
       %__MODULE__{
         context: "ehos-#{name}",
         host: host,
         source: source,
         kubeconfig: kubeconfig,
         runner: Keyword.get(opts, :runner, CommandRunnerImpl),
         progress: Keyword.get(opts, :progress, &quiet/1)
       }}
    end
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
      EHOS image comes from the private registry; the local cluster's comes from its own. Then
      `ehos-data`, where EHOS's keeper runs (eh-os D-171), is made before the chart, as the chart
      makes it, and given a copy of the credential `ehos-system` holds, which must be there
      first: without it, nothing is installed.
    * `:installation` — what the installation is, the chart's `installation` value (D-90): a map
      of `name`, `provider`, `region` and `size`, each a line of text. None says nothing.
    * `:installed` — what is installed, `version`, `image` and `chart`, the release's `installed`
      value, which nothing in the chart reads and `installed/1` reads back (eh-os D-92). None
      writes none.
    * `:public_certificates` — a keyword list for certificates from an ACME server (eh-os
      D-158), the console's and the addresses' ACME issuers then named in place of the
      installation's CA, with `EhosPlatform.PublicCertificates.chart_values/1`'s `:server`,
      `:ca_bundle` and `:records`, the DNS records' values, which the release holds no longer
      without them. The console's certificate is then waited for 10 minutes. None, or `false`: the
      installation's CA.
    * `:allowed_domains` — the chart's `environments.domains.allowed` (eh-os D-155), a list of
      domains `EhosPlatform.AllowedDomains.check/2` takes. None leaves it to the chart, which
      allows none.
    * `:external_databases` — the chart's `dataResources.external` (eh-os D-170), a list of
      `t:EhosPlatform.ExternalDatabases.entry/0`. None leaves it to the chart, which lists none.
    * `:external_under_development` — the chart's `dataResources.externalUnderDevelopment`, which
      a list with an entry needs while EHOS offers it for development only. None leaves it to the
      chart, which is `false`.
    * `:registry_auth` — `{username, token}` for the registry a release's chart is pulled from,
      given to Helm in a registry configuration only this user reads, removed after, never on a
      command line. None leaves Helm its own login, if any.
    * `:values_files` — paths of Helm values files, each given to Helm as `-f`, for chart values
      that no other option sets, such as the `parameters` of an instance's PostgreSQL. A value
      that this function sets wins over the same value in a file. A path must not hold a comma,
      since Helm splits `-f` at commas. None gives no file.
  """
  @spec chart(t(), keyword()) :: :ok | {:error, Failure.message()}
  def chart(%__MODULE__{} = target, opts) do
    installed =
      with_external_values(opts, &upgrade_chart(target, opts, chart_args(target, opts, &1)))

    # eh-os D-158: Let's Encrypt can take minutes for the console's DNS-01 order.
    {secret, timeout} =
      if opts[:public_certificates], do: {@public_tls_secret, "10m"}, else: {@tls_secret, "2m"}

    with :ok <- installed, do: wait_for_certificate(target, @namespace, secret, timeout)
  end

  defp upgrade_chart(target, opts, values) do
    TmpDir.with_tmp_dir("ehos-cluster", fn dir ->
      with {:ok, package} <- chart_reference(target, dir, opts[:registry_auth]),
           :ok <- adopt_console_certificate(target, package, values),
           :ok <- data_pull_credential(target, opts[:own_pull_credential?] not in [nil, false]) do
        target.progress.({:step, "Installing EHOS and waiting until it is ready"})

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
  end

  # eh-os D-170: the databases outside the installation go to Helm in a values file only this
  # user reads, removed after, never in an argument: each holds a CA's PEM, an RDS bundle is
  # about 160 KB, and Linux takes at most 128 KiB in one argument. `fun` gets the file's `-f`, or
  # nothing when `opts` gives neither value.
  defp with_external_values(opts, fun) do
    given =
      %{}
      |> put_given("external", Keyword.get(opts, :external_databases))
      |> put_given("externalUnderDevelopment", Keyword.get(opts, :external_under_development))

    if given == %{},
      do: fun.([]),
      else: with_private_json("ehos-external", %{"dataResources" => given}, &fun.(["-f", &1]))
  end

  defp put_given(map, _key, nil), do: map
  defp put_given(map, key, value), do: Map.put(map, key, value)

  # eh-os D-171: the keeper, in ehos-data, pulls EHOS's image as EHOS's own pods do, and a pod pulls
  # only with a Secret of its own namespace. The namespace is made as the chart makes it, which then
  # takes it over; on an upgrade it is the chart's already. It is made even when the chart lists no
  # instance, and so makes no keeper: it then stays empty but for the credential, and the chart
  # takes it over once it lists one. The namespace goes whole in the apply of the Secret: applied
  # on its own, client-side, a server-side apply of its name alone took its labels back, and Helm
  # then refused it (eh-os#1632). The installer then shares these fields with Helm: a chart that
  # drops or changes one must change data-namespace.yaml with it.
  defp data_pull_credential(_target, false), do: :ok

  defp data_pull_credential(target, true),
    do:
      copy_pull_credential(
        target,
        @data_namespace_manifest |> manifest() |> YamlElixir.read_from_file!(),
        "EHOS's keeper runs in #{@data_namespace} from EHOS's image, which is in a private " <>
          "GHCR package, and #{@namespace} holds no pull credential to copy: set GHCR_TOKEN " <>
          "to a classic GitHub token with read:packages"
      )

  @doc false
  # Copies the pull credential `ehos-system` holds into `namespace`, a name or the Namespace to
  # apply with it, as `apply_secret/5` writes a Secret; `none` is the refusal when `ehos-system`
  # holds none. `EhosPlatform.PublicCertificates` copies it into acme-dns's namespace through it.
  @spec copy_pull_credential(t(), String.t() | map(), String.t()) ::
          :ok | {:error, Failure.message()}
  def copy_pull_credential(%__MODULE__{} = target, namespace, none) do
    # Before kubectl: a namespace of another shape fails before the credential is read.
    namespace = namespace_document(namespace)

    args =
      kubectl_args(target, [
        "get",
        "secret",
        @pull_credential,
        "-n",
        @namespace,
        "--ignore-not-found",
        "-o",
        "jsonpath={.data.\\.dockerconfigjson}"
      ])

    case target.runner.run("kubectl", args) do
      # kubectl may print a warning before the value.
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last("")
        |> copy_credential(target, namespace, none)

      result ->
        failure("kubectl", result)
    end
  end

  defp copy_credential(encoded, target, {name, namespace}, none) do
    case Base.decode64(encoded) do
      {:ok, json} when json != "" ->
        target.progress.({:step, "Copying the pull credential into #{name}/#{@pull_credential}"})
        hidden = [encoded, json | auths(json)]
        secret = pull_secret(name, encoded)
        apply_secret(target, secret, hidden, "[the credential]", namespace)

      _none ->
        {:error, none}
    end
  end

  defp bare_namespace(name),
    do: %{"apiVersion" => "v1", "kind" => "Namespace", "metadata" => %{"name" => name}}

  # A namespace's name, and the Namespace to apply with a Secret in it, from either.
  defp namespace_document(name) when is_binary(name), do: {name, bare_namespace(name)}
  defp namespace_document(%{} = namespace), do: {namespace["metadata"]["name"], namespace}

  # Each registry's `auth` in a `.dockerconfigjson`, and the `user:token` it encodes, longest first,
  # so that a failure that prints one field alone does not print the token.
  defp auths(json) do
    case Jason.decode(json) do
      {:ok, %{"auths" => %{} = registries}} ->
        registries
        |> Map.values()
        |> Enum.flat_map(&auth_values/1)
        # An empty token would put the placeholder between every character of the message.
        |> Enum.reject(&(&1 == ""))
        |> Enum.sort_by(&String.length/1, :desc)

      _not_a_config ->
        []
    end
  end

  defp auth_values(%{"auth" => auth}) when is_binary(auth) and auth != "" do
    case Base.decode64(auth) do
      {:ok, plain} -> [auth, plain | tl(String.split(plain, ":", parts: 2))]
      :error -> [auth]
    end
  end

  defp auth_values(_registry), do: []

  @doc """
  The chart rendered with the values `chart/2` installs it with, as `helm template` writes it:
  `EhosPlatform.PublicCertificates.issuers/2` takes the ACME issuers from it before the chart is
  installed. Options as `chart/2`'s.
  """
  @spec render(t(), keyword()) :: {:ok, String.t()} | {:error, Failure.message()}
  def render(%__MODULE__{} = target, opts) do
    with_external_values(
      opts,
      &rendered(target, opts[:registry_auth], chart_args(target, opts, &1))
    )
  end

  defp template(target, package, values) do
    case target.runner.run(
           "helm",
           ["template", "ehos", package, "--namespace", @namespace] ++ values
         ) do
      {output, 0} -> {:ok, output}
      result -> failure("helm", result)
    end
  end

  defp chart_args(target, opts, external_files) do
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
    # eh-os D-155: the company's domains a person may map an entry to; JSON, as a list.
    allowed = allowed_args(Keyword.get(opts, :allowed_domains))

    own =
      if Keyword.get(opts, :own_pull_credential?, false),
        do: ["--set", "imagePullSecrets[0].name=#{@pull_credential}"],
        else: []

    public = public_args(Keyword.get(opts, :public_certificates))
    issuers = if public == [], do: {@ca_name, @ca_name}, else: acme_issuers()
    secret = if public == [], do: @tls_secret, else: @public_tls_secret

    # Helm puts `--set` over a file whatever their order; the files come first, so the command
    # reads in the order Helm applies it.
    files = values_args(Keyword.get(opts, :values_files))

    # eh-os D-170: the databases outside the installation, in a file of their own after the
    # others (`with_external_values/2`). The managing role's password is in its Secret, never here.
    files ++
      external_files ++
      chart_values(target, repository, digest, ca_file, prefixes, pull?, {secret, issuers}) ++
      described ++ recorded ++ sign_in ++ four_eyes ++ mail ++ allowed ++ own ++ public
  end

  # eh-os D-158: the chart's `publicCertificates`, with cert-manager's own HTTP-01 solver, so its
  # policy and cert-manager name the same digest. `public` is a keyword of
  # `EhosPlatform.PublicCertificates.chart_values/1`'s options, `:server`, `:ca_bundle` and
  # `:records`, or nil.
  defp public_args(nil), do: []
  defp public_args(false), do: []

  defp public_args(public) when is_list(public),
    do:
      PublicCertificates.chart_values(
        Keyword.put(
          public,
          :solver_image,
          "quay.io/jetstack/cert-manager-acmesolver@#{@cert_manager_solver}"
        )
      )

  defp acme_issuers,
    do: {PublicCertificates.console_issuer(), PublicCertificates.addresses_issuer()}

  defp described_args(empty) when map_size(empty) == 0, do: []

  defp described_args(installation),
    do: ["--set-json", "installation=#{Jason.encode!(installation)}"]

  defp values_args(nil), do: []
  defp values_args(files) when is_list(files), do: Enum.flat_map(files, &["-f", &1])

  defp installed_args(nil), do: []
  defp installed_args(installed), do: ["--set-json", "installed=#{Jason.encode!(installed)}"]

  defp sign_in_args(limits) when is_map(limits) and map_size(limits) > 0,
    do: ["--set-json", "governance.signIn=#{Jason.encode!(limits)}"]

  defp sign_in_args(_none), do: []

  defp four_eyes_args(given) when is_boolean(given),
    do: ["--set-json", "governance.promotion.fourEyes=#{given}"]

  defp four_eyes_args(nil), do: []

  defp allowed_args(domains) when is_list(domains),
    do: ["--set-json", "environments.domains.allowed=#{Jason.encode!(domains)}"]

  defp allowed_args(nil), do: []

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

  defp chart_values(
         target,
         repository,
         digest,
         ca_file,
         prefixes,
         pull?,
         {secret, {console, addresses}}
       ) do
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
      "governance.ingress.tls.secretName=#{secret}",
      "--set",
      "governance.ingress.annotations.cert-manager\\.io/cluster-issuer=#{console}",
      # D-62: every application's address gets a certificate of its own from the same CA.
      "--set",
      "environments.ingress.annotations.cert-manager\\.io/cluster-issuer=#{addresses}",
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
      target.progress.({:step, "Pulling EHOS's chart by its digest"})
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
      not (to_string(message) =~ ~r/response status code 40[13]|: (unauthorized|denied):/i) ->
        error

      auth ->
        {:error,
         Failure.added(
           message,
           "\nGHCR refused EHOS's chart to GHCR_TOKEN: it needs read:packages, and must not " <>
             "have expired"
         )}

      true ->
        {:error,
         Failure.added(
           message,
           "\nEHOS's chart is in a private GHCR package: set GHCR_TOKEN to a classic GitHub " <>
             "token with read:packages alone (eh-os#218)"
         )}
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
  @spec kubectl(t(), [String.t()]) :: :ok | {:error, Failure.message()}
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
    do: {:error, Failure.exited(program, status, output)}

  @doc "The path of one of the manifests the installer applies, in this package's `priv/`."
  @spec manifest(String.t()) :: Path.t()
  def manifest(file),
    do: Path.join([Application.app_dir(:ehos_platform), "priv", "manifests", file])
end

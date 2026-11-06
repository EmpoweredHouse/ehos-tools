defmodule EhosPlatform.Move do
  @moduledoc """
  An installation that runs under its own CA moves to public certificates at the target's host
  (eh-os D-158, [eh-os#1301](https://github.com/EmpoweredHouse/eh-os/issues/1301)), in an order in
  which nothing the company's people use changes until the last step can succeed.
  `EhosPlatform.Install.server/1` runs it on a server; eh-os's cluster test runs it on the local
  cluster, with the chart of its checkout.

  Before it, `refused/1` says whether the installation may move, and the installer's first pass
  makes acme-dns and the two account keys (`EhosPlatform.PublicCertificates`), the two ACME
  issuers with their policy (`issuers/2`), and checks the company's records
  (`EhosPlatform.DomainRecords`). Then `run/2`:

    1. the console's certificate for the new host is issued while the old host serves
       (`console_certificate/3`);
    2. CoreDNS's rule names the new host, and the chart is installed with it, the ACME issuers and
       Let's Encrypt's roots, which the caller does: every workload rolls out with the new
       `EHOS_ISSUER`, `EHOS_SIGN_IN_APPLICATIONS` and `EHOS_CA_FILE`, and every address asks for its
       certificate;
    3. the installation's CA and its admission policy, which admits the old host, are removed
       (`own_authority_removed/1`);
    4. every address's certificate is waited for, for at most 15 minutes (`addresses/2`).

  A move that stops before step 2 leaves the old host serving. CoreDNS's rule changes just before
  the chart, since the workloads the chart rolls out reach EHOS at the new host: a chart that then
  fails leaves pods without the old host's name in the cluster until the command runs again.
  """

  alias EhosPlatform.Install
  alias EhosPlatform.PublicCertificates
  alias EhosPlatform.TmpDir

  @namespace "ehos-system"
  @addresses "ehos-addresses"
  @cert_manager "cert-manager"
  @policy "ehos-acme-issuers"
  # Let's Encrypt's limit of new certificates per registered domain in a week.
  @weekly_limit 50
  @certificate_timeout_ms :timer.minutes(10)
  @addresses_timeout_ms :timer.minutes(15)
  @addresses_poll_ms 10_000

  @doc "The Secret, and the Certificate, of the console's certificate with public certificates."
  @spec console_secret() :: String.t()
  def console_secret, do: Install.public_tls_secret()

  @doc """
  `:ok` when the installation may move: no domain is mapped (eh-os D-155), and its addresses and
  the console fit in Let's Encrypt's #{@weekly_limit} new certificates per registered domain in a
  week. The company's other certificates under the same registered domain count against the same
  limit, which nothing here can know.
  """
  @spec refused(Install.t()) :: :ok | {:error, String.t()}
  def refused(%Install{} = target) do
    with :ok <- no_mapped_domain(target), do: within_weekly_limit(target)
  end

  defp no_mapped_domain(target) do
    jsonpath =
      ~S'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}={.spec.domains[*].name}{"\n"}{end}'

    with {:ok, lines} <-
           read(target, ["get", "ehosdeployments.ehos.empowered.house", "-A", "-o", jsonpath]) do
      mapped =
        for line <- lines,
            [_, deployment, domains] <- [Regex.run(~r/\A([-a-z0-9.]+\/[-a-z0-9.]+)=(.*)\z/, line)],
            domains != "",
            do: "#{domains} (#{deployment})"

      if mapped == [],
        do: :ok,
        else:
          {:error,
           "A domain is mapped to an application: #{Enum.join(mapped, ", ")}. If the " <>
             "installation moves, that domain stops answering. Remove each mapping, then run " <>
             "the command again. Nothing was changed"}
    end
  end

  defp within_weekly_limit(target) do
    with {:ok, lines} <-
           read(target, [
             "get",
             "certificates.cert-manager.io",
             "-n",
             @addresses,
             "-o",
             ~S'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}'
           ]) do
      needed = Enum.count(lines, &(&1 =~ ~r/\A[-a-z0-9.]+\z/)) + 1

      if needed <= @weekly_limit,
        do: :ok,
        else:
          {:error,
           "The move needs #{needed} certificates from Let's Encrypt: 1 for the console and " <>
             "1 for each address of an application. Let's Encrypt issues at most " <>
             "#{@weekly_limit} certificates in a week for one registered domain, and the other " <>
             "certificates of your company count too. Remove ephemeral environments until the " <>
             "move needs #{@weekly_limit} or fewer. Nothing was changed"}
    end
  end

  @doc """
  Applies the chart's two ACME issuers, from the chart `rendered` with the new host, with their
  admission policy `#{@policy}` before them: while the move waits for the company's records, no
  namespace but `#{@namespace}` may be issued the console's certificate, and none but
  `#{@addresses}` an address's. Applied on every run of a move, not only when they are missing, so
  that a run with another host than the one before gives the console's issuer that host. Marked as
  the `ehos` release's, so the chart takes them over.
  """
  @spec issuers(Install.t(), String.t()) :: :ok | {:error, String.t()}
  def issuers(%Install{} = target, rendered) do
    all = documents(rendered)

    policy =
      for %{"kind" => kind, "metadata" => %{"name" => @policy}} = document <- all,
          kind in ["ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"],
          do: document

    issuers =
      for %{"kind" => "ClusterIssuer", "metadata" => %{"name" => name}} = document <- all,
          name in [PublicCertificates.console_issuer(), PublicCertificates.addresses_issuer()],
          do: document

    if length(policy) == 2 and length(issuers) == 2 do
      target.progress.("Making the ACME issuers for #{target.host} alone (#{@policy})")
      # Two applies: kubectl goes on past an item it cannot apply, so in one the issuers could
      # be made while the policy was refused.
      with :ok <- apply_documents(target, policy), do: apply_documents(target, issuers)
    else
      {:error,
       "EHOS's chart renders no ACME issuers and #{@policy} policy: it is older than EHOS 0.26.0"}
    end
  end

  @doc """
  Moves the installation, once the company's records are right: `console_certificate/3`, CoreDNS's
  rule for the new host, `chart` (the chart installed with it), `own_authority_removed/1` and
  `addresses/2`. Returns the addresses still without a certificate.

  Options: `:render`, a function that returns the chart rendered as `chart` installs it (required);
  `:chart`, a function that installs it (required); `:certificate_timeout` and
  `:addresses_timeout`, in milliseconds, #{@certificate_timeout_ms} and #{@addresses_timeout_ms}
  unless given.
  """
  @spec run(Install.t(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def run(%Install{} = target, opts) do
    render = Keyword.fetch!(opts, :render)
    chart = Keyword.fetch!(opts, :chart)

    with {:ok, rendered} <- render.(),
         :ok <- console_certificate(target, rendered, opts),
         :ok <- Install.name_in_cluster(target),
         :ok <- chart.(),
         :ok <- own_authority_removed(target),
         do: addresses(target, opts)
  end

  @doc """
  Issues the console's certificate for the target's host into the Secret the chart will use, by
  the chart's own `Certificate` from `rendered`, applied by the installer, while the old host
  serves from another Secret. Once it is issued, the `Certificate` is deleted and its Secret kept,
  so the chart's `Certificate` of the same name finds the Secret current and issues nothing again.
  Not issued within `:certificate_timeout` milliseconds, it is deleted with its Secret, and the
  move stops there, with what cert-manager says.
  """
  @spec console_certificate(Install.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def console_certificate(%Install{} = target, rendered, opts \\ []) do
    timeout = Keyword.get(opts, :certificate_timeout, @certificate_timeout_ms)

    with {:ok, certificate} <- certificate(rendered),
         :ok <- announce(target),
         :ok <- apply_documents(target, [certificate]),
         do: issued(target, wait(target, timeout), timeout)
  end

  defp announce(target) do
    target.progress.(
      "Asking Let's Encrypt for the console's certificate for #{target.host}; the installation " <>
        "still answers at its old host"
    )
  end

  defp certificate(rendered) do
    secret = console_secret()

    case Enum.filter(
           documents(rendered),
           &match?(%{"kind" => "Certificate", "metadata" => %{"name" => ^secret}}, &1)
         ) do
      [certificate] ->
        {:ok, certificate}

      _none ->
        {:error, "EHOS's chart renders no Certificate #{secret}: it is older than EHOS 0.26.0"}
    end
  end

  defp wait(target, timeout) do
    Install.kubectl(target, [
      "wait",
      "--for=condition=Ready",
      "certificate/#{console_secret()}",
      "-n",
      @namespace,
      "--timeout=#{div(timeout, 1000)}s"
    ])
  end

  # Its Secret is kept: cert-manager owns a Certificate's Secret here (D-62's
  # `enableCertificateOwnerRef`), so a delete that cascades would take it too.
  defp issued(target, :ok, _timeout) do
    target.progress.("The console's certificate for #{target.host} is issued")
    delete_certificate(target, "--cascade=orphan")
  end

  defp issued(target, {:error, _waited}, timeout) do
    reason = not_ready_reason(target)

    with :ok <- delete_certificate(target, "--cascade=background") do
      {:error,
       "Let's Encrypt did not issue the certificate of the console for #{target.host} in " <>
         "#{duration(timeout)}. The installation did not move, and still answers at its old " <>
         "host. cert-manager says: #{reason}. Check the DNS records, then run the command again"}
    end
  end

  defp duration(ms) when rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)} minutes"
  defp duration(ms), do: "#{div(ms, 1000)} seconds"

  defp not_ready_reason(target) do
    case read(target, [
           "get",
           "certificate",
           console_secret(),
           "-n",
           @namespace,
           "-o",
           ~S'jsonpath={.status.conditions[?(@.type=="Ready")].message}'
         ]) do
      {:ok, lines} -> lines |> Enum.reject(&warning?/1) |> List.last("nothing")
      _none -> "nothing"
    end
  end

  # What kubectl warns of, in its own form or klog's, which the runner merges into the output.
  defp warning?(line), do: line =~ ~r/\A(Warning: |[IWE]\d{4} )/ or line == ""

  defp delete_certificate(target, cascade) do
    Install.kubectl(target, [
      "delete",
      "certificate",
      console_secret(),
      "-n",
      @namespace,
      "--ignore-not-found",
      cascade
    ])
  end

  @doc """
  Removes the installation's own CA, which no certificate names once the chart has public
  certificates: its `Certificate`, the Secret with its key and its `ClusterIssuer`, the issuer that
  signed it, the copies a cluster made before D-62 kept in `#{@namespace}`, the console's Secret it
  issued, and last the admission policy that admits it for the old host, so that no step that
  fails leaves the CA able to issue without its policy. Nothing is removed while the console's
  `Certificate` still names it. Run again, it removes nothing more.
  """
  @spec own_authority_removed(Install.t()) :: :ok | {:error, String.t()}
  def own_authority_removed(%Install{} = target) do
    ca = Install.ca_name()

    with {:ok, false} <- local_console_certificate?(target),
         :ok <-
           Install.kubectl(target, [
             "delete",
             "certificate/#{ca}",
             "secret/#{ca}",
             "issuer/ehos-local-selfsigned",
             "-n",
             @cert_manager,
             "--ignore-not-found"
           ]),
         :ok <- Install.kubectl(target, ["delete", "clusterissuer/#{ca}", "--ignore-not-found"]),
         :ok <-
           Install.kubectl(target, [
             "delete",
             "issuer/#{ca}",
             "issuer/ehos-local-selfsigned",
             "certificate/#{ca}",
             "secret/#{ca}",
             "secret/#{Install.tls_secret()}",
             "-n",
             @namespace,
             "--ignore-not-found"
           ]) do
      Install.kubectl(target, [
        "delete",
        "validatingadmissionpolicybinding/#{ca}",
        "validatingadmissionpolicy/#{ca}",
        "--ignore-not-found"
      ])
    else
      {:ok, true} ->
        {:error,
         "The console's certificate is still the installation's CA's, so the CA was kept: " <>
           "run the command again"}

      error ->
        error
    end
  end

  # Whether the console's Certificate under the installation's CA is there and still names it; one
  # of that name an ACME issuer issued, as `ehos_platform` 0.14.0 named it, does not count.
  defp local_console_certificate?(target) do
    with {:ok, lines} <-
           read(target, [
             "get",
             "certificate",
             Install.tls_secret(),
             "-n",
             @namespace,
             "--ignore-not-found",
             "-o",
             "jsonpath={.spec.issuerRef.name}"
           ]),
         do: {:ok, Install.ca_name() in lines}
  end

  @doc """
  Waits until every address's `Certificate` in `#{@addresses}` is issued for the new host by the
  addresses' ACME issuer, and ready, for at most
  `:addresses_timeout` milliseconds (#{@addresses_timeout_ms} unless given), and returns the names
  of those still not ready then. cert-manager keeps asking for them on its own.
  """
  @spec addresses(Install.t(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def addresses(%Install{} = target, opts \\ []) do
    timeout = Keyword.get(opts, :addresses_timeout, @addresses_timeout_ms)
    target.progress.("Waiting for each application's address to get its certificate")
    await_addresses(target, div(timeout, @addresses_poll_ms))
  end

  # The move has switched by now: a read that fails is tried again within the wait, and only one
  # that still fails when the wait ends is the move's error.
  defp await_addresses(target, polls_left),
    do: next_poll(target, not_ready(target), polls_left)

  defp next_poll(_target, {:ok, []}, _polls_left), do: {:ok, []}
  defp next_poll(_target, read, polls_left) when polls_left <= 0, do: read

  defp next_poll(target, _read, polls_left) do
    target.clock.sleep(@addresses_poll_ms)
    await_addresses(target, polls_left - 1)
  end

  # An address is done once its Certificate is for a name under the new host, from the addresses'
  # ACME issuer, and ready for the spec it has now: straight after the chart, the operator may not
  # have given it the new host yet, and its Ready may still be the old one's.
  defp not_ready(target) do
    jsonpath =
      ~S'jsonpath={range .items[*]}{.spec.dnsNames[0]}={.spec.issuerRef.name}={.metadata.generation}={.status.conditions[?(@.type=="Ready")].status}={.status.conditions[?(@.type=="Ready")].observedGeneration}{"\n"}{end}'

    with {:ok, lines} <-
           read(target, ["get", "certificates.cert-manager.io", "-n", @addresses, "-o", jsonpath]) do
      waiting =
        for line <- lines,
            [_, name | state] <-
              [Regex.run(~r/\A([-a-z0-9.]+)=([-a-z0-9.]*)=(\d+)=(\w*)=(\d*)\z/, line)],
            not issued?(target, name, state),
            do: name

      {:ok, Enum.sort(waiting)}
    end
  end

  defp issued?(target, name, [issuer, generation, "True", generation]),
    do:
      String.ends_with?(name, "." <> target.host) and
        issuer == PublicCertificates.addresses_issuer()

  defp issued?(_target, _name, _state), do: false

  defp documents(rendered) do
    for %{} = document <- YamlElixir.read_all_from_string!(rendered), do: document
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp apply_documents(target, documents) do
    TmpDir.with_tmp_dir("ehos-move", fn dir ->
      path = Path.join(dir, "move.json")

      File.write!(
        path,
        Jason.encode!(%{
          "apiVersion" => "v1",
          "kind" => "List",
          "items" => Enum.map(documents, &PublicCertificates.helms/1)
        })
      )

      # As Helm 4 applies, server-side as `helm`, so its upgrade owns every field.
      Install.kubectl(target, ["apply", "--server-side", "--field-manager=helm", "-f", path])
    end)
  end

  # The runner merges stderr into the output, where kubectl can warn: each line is read, and the
  # caller keeps those of the form it asked for.
  defp read(target, args) do
    case target.runner.run("kubectl", Install.kubectl_args(target, args)) do
      {output, 0} ->
        {:ok, String.split(output, "\n", trim: true)}

      {:error, :not_found} ->
        {:error,
         "`kubectl` is not installed, or not at the version EHOS pins: `ehosctl doctor` says what is missing"}

      {output, status} ->
        {:error, "`kubectl` failed with exit status #{status}:\n" <> output}
    end
  end
end

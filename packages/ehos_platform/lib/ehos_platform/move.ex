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

  `install.json` names the new host as soon as the chart serves it, in step 2. An install under
  the installation's own CA, run instead of the move again, removes what the move made outside
  the chart (`abandoned_removed/1`). A move that stops before step 2 leaves the old host serving.
  CoreDNS's rule changes just before the chart, since the workloads the chart rolls out reach
  EHOS at the new host: a chart that then fails leaves pods without the old host's name in the
  cluster until the command runs again.
  """

  alias EhosPlatform.Failure
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
  @request_timeout "--request-timeout=10s"
  @acme_dns_namespace "namespace/ehos-acme-dns"

  @doc "The Secret, and the Certificate, of the console's certificate with public certificates."
  @spec console_secret() :: String.t()
  def console_secret, do: Install.public_tls_secret()

  @doc """
  `:ok` when the installation may move: no domain is mapped (eh-os D-155), and its addresses and
  the console fit in Let's Encrypt's #{@weekly_limit} new certificates per registered domain in a
  week. The company's other certificates under the same registered domain count against the same
  limit, which nothing here can know.
  """
  @spec refused(Install.t()) :: :ok | {:error, Failure.message()}
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
  @spec issuers(Install.t(), String.t()) :: :ok | {:error, Failure.message()}
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

    case missing(policy ++ issuers) do
      [] ->
        target.progress.({:step, "Making the ACME issuers for #{target.host} alone (#{@policy})"})
        # Two applies: kubectl goes on past an item it cannot apply, so in one the issuers could
        # be made while the policy was refused.
        with :ok <- apply_documents(target, policy), do: apply_documents(target, issuers)

      missing ->
        {:error,
         "EHOS's chart does not render #{Enum.join(missing, ", ")}: it is older than EHOS " <>
           "0.26.0"}
    end
  end

  # The four documents of the move's issuers, as kind/name, that `found` does not hold.
  defp missing(found) do
    present = for %{"kind" => kind, "metadata" => %{"name" => name}} <- found, do: {kind, name}

    for {kind, name} = document <- [
          {"ValidatingAdmissionPolicy", @policy},
          {"ValidatingAdmissionPolicyBinding", @policy},
          {"ClusterIssuer", PublicCertificates.console_issuer()},
          {"ClusterIssuer", PublicCertificates.addresses_issuer()}
        ],
        document not in present,
        do: "#{kind} #{name}"
  end

  @doc """
  Moves the installation, once the company's records are right: `console_certificate/3`, CoreDNS's
  rule for the new host, `chart` (the chart installed with it), `own_authority_removed/1` and
  `addresses/2`. Returns the addresses still without a certificate.

  Options: `:render`, a function that returns the chart rendered as `chart` installs it (required);
  `:chart`, a function that installs it (required); `:certificate_timeout` and
  `:addresses_timeout`, in milliseconds, #{@certificate_timeout_ms} and #{@addresses_timeout_ms}
  unless given; `:moving_from`, the old host, by which `addresses/2` names an address.
  """
  @spec run(Install.t(), keyword()) :: {:ok, [String.t()]} | {:error, Failure.message()}
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
  @spec console_certificate(Install.t(), String.t(), keyword()) ::
          :ok | {:error, Failure.message()}
  def console_certificate(%Install{} = target, rendered, opts \\ []) do
    timeout = Keyword.get(opts, :certificate_timeout, @certificate_timeout_ms)

    with {:ok, certificate} <- certificate(rendered),
         :ok <- announce(target),
         :ok <- apply_documents(target, [certificate]),
         do: issued(target, wait(target, timeout), timeout)
  end

  defp announce(target) do
    target.progress.(
      {:step,
       "Asking Let's Encrypt for the console's certificate for #{target.host}; the installation " <>
         "still answers at its old host"}
    )

    :ok
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
    target.progress.({:step, "The console's certificate for #{target.host} is issued"})
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
  @spec own_authority_removed(Install.t()) :: :ok | {:error, Failure.message()}
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
  Removes what a move that was abandoned left, or a first install with public certificates that
  stopped at the records, on an installation that runs under its own CA: the console's
  `Certificate` for the new host, which may still ask Let's Encrypt, and its Secret, which a move
  keeps once the certificate is issued; the two ACME issuers; and last their policy `#{@policy}`,
  so that no step that fails leaves the issuers without it. acme-dns and the account keys are
  kept, since the company's records name them and a later move uses them again: when acme-dns is
  there, the run that removes the rest says how to remove it. Nothing there, nothing is said.
  """
  @spec abandoned_removed(Install.t()) :: :ok | {:error, Failure.message()}
  def abandoned_removed(%Install{} = target) do
    with {:ok, lines} <-
           read(
             target,
             ["get" | Enum.map(abandoned(), &elem(&1, 0))] ++
               ["-n", @namespace, "--ignore-not-found", "-o", "name"]
           ),
         found = Enum.reject(lines, &warning?/1),
         left = removable(found),
         :ok <- remove_abandoned(target, left) do
      # Said on the run that removes what a move left alone, not on every install after it.
      if left != [] and @acme_dns_namespace in found, do: acme_dns_kept(target), else: :ok
    end
  end

  # What a move's first pass, and its wait for the console's certificate, make outside the chart,
  # as `kubectl get -o name` names each, as the operator is told it, and how each is removed, in
  # order: the policy last.
  defp abandoned do
    namespaced = ["-n", @namespace, "--ignore-not-found"]
    cluster = ["--ignore-not-found"]
    console = PublicCertificates.console_issuer()
    addresses = PublicCertificates.addresses_issuer()

    [
      {"certificate.cert-manager.io/#{console_secret()}",
       "the console's certificate for the new host",
       ["certificate/#{console_secret()}" | namespaced]},
      {"secret/#{console_secret()}", "its Secret #{@namespace}/#{console_secret()}",
       ["secret/#{console_secret()}" | namespaced]},
      {"clusterissuer.cert-manager.io/#{console}", "the ACME issuer #{console}",
       ["clusterissuer/#{console}" | cluster]},
      {"clusterissuer.cert-manager.io/#{addresses}", "the ACME issuer #{addresses}",
       ["clusterissuer/#{addresses}" | cluster]},
      {"validatingadmissionpolicybinding.admissionregistration.k8s.io/#{@policy}",
       "the binding of their policy #{@policy}",
       ["validatingadmissionpolicybinding/#{@policy}" | cluster]},
      {"validatingadmissionpolicy.admissionregistration.k8s.io/#{@policy}",
       "their policy #{@policy}", ["validatingadmissionpolicy/#{@policy}" | cluster]},
      {@acme_dns_namespace, "acme-dns", :kept}
    ]
  end

  defp removable(found) do
    for {name, label, removal} <- abandoned(),
        name in found,
        removal != :kept,
        do: {label, removal}
  end

  defp remove_abandoned(_target, []), do: :ok

  defp remove_abandoned(target, left) do
    target.progress.(
      {:step,
       "Removing what an earlier run with public certificates left: " <>
         Enum.map_join(left, ", ", fn {label, _removal} -> label end)}
    )

    Enum.reduce_while(left, :ok, fn {_label, removal}, :ok ->
      case Install.kubectl(target, ["delete" | removal]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp acme_dns_kept(target) do
    target.progress.(
      {:warning,
       "acme-dns still runs in ehos-acme-dns, with the account that your _acme-challenge " <>
         "record names.",
       "A later move uses it and the two Let's Encrypt account keys again. To remove them, run " <>
         "`kubectl delete namespace ehos-acme-dns`. Then run `kubectl -n cert-manager delete " <>
         "secret ehos-acme-dns #{PublicCertificates.console_issuer()} " <>
         "#{PublicCertificates.addresses_issuer()}`. A later move then needs new " <>
         "_acme-challenge and CAA records."}
    )

    :ok
  end

  @doc """
  Waits until every address's `Certificate` in `#{@addresses}` is issued for the new host by the
  addresses' ACME issuer, and ready, for at most
  `:addresses_timeout` milliseconds (#{@addresses_timeout_ms} unless given), and returns those
  still not ready then. cert-manager keeps asking for them on its own. Each is named under the new
  host, also while its Certificate still names `:moving_from`, the old host, and by its
  Certificate, `#{@addresses}/<name>`, when its name is under neither or cannot be read. A read
  that fails is tried again within the wait; when the last one fails, the last that did not is the
  answer, and kubectl's error only when none succeeded.
  """
  @spec addresses(Install.t(), keyword()) :: {:ok, [String.t()]} | {:error, Failure.message()}
  def addresses(%Install{} = target, opts \\ []) do
    timeout = Keyword.get(opts, :addresses_timeout, @addresses_timeout_ms)
    target.progress.({:step, "Waiting for each application's address to get its certificate"})
    await_addresses(target, Keyword.get(opts, :moving_from), div(timeout, @addresses_poll_ms))
  end

  # The move has switched by now, so a read that fails does not end it while another can be made:
  # the last read that succeeded is kept, and an error is the answer only when none did.
  defp await_addresses(target, from, polls_left, last \\ nil) do
    read = not_ready(target, from)
    next_poll(target, from, read, polls_left, kept(target, read, last, polls_left))
  end

  defp kept(_target, {:ok, _waiting} = read, _last, _polls_left), do: read

  # Said at each poll that fails, so a step and not a warning; the last poll tries no more.
  defp kept(target, {:error, message}, last, polls_left) do
    again = if polls_left > 0, do: ", trying again", else: ""

    target.progress.(
      {:step, "kubectl could not read the certificates of the addresses#{again}: #{message}"}
    )

    last || {:error, message}
  end

  defp next_poll(_target, _from, {:ok, []}, _polls_left, _kept), do: {:ok, []}
  defp next_poll(_target, _from, _read, polls_left, kept) when polls_left <= 0, do: kept

  defp next_poll(target, from, _read, polls_left, kept) do
    target.clock.sleep(@addresses_poll_ms)
    await_addresses(target, from, polls_left - 1, if(match?({:ok, _}, kept), do: kept))
  end

  # An address is done once its Certificate is for a name under the new host, from the addresses'
  # ACME issuer, and ready for the spec it has now: straight after the chart, the operator may not
  # have given it the new host yet, and its Ready may still be the old one's. A line that cannot be
  # read, a wildcard or a Certificate with no DNS name among them, is not done: it waits under its
  # Certificate's name.
  defp not_ready(target, from) do
    jsonpath =
      ~S'jsonpath={range .items[*]}{.metadata.name}={.spec.dnsNames[0]}={.spec.issuerRef.name}={.metadata.generation}={.status.conditions[?(@.type=="Ready")].status}={.status.conditions[?(@.type=="Ready")].observedGeneration}{"\n"}{end}'

    with {:ok, lines} <-
           read(target, ["get", "certificates.cert-manager.io", "-n", @addresses, "-o", jsonpath]) do
      waiting =
        for line <- lines,
            not warning?(line),
            state = address(line),
            not issued?(target, state),
            uniq: true,
            do: shown(target, from, state)

      {:ok, Enum.sort(waiting)}
    end
  end

  defp address(line) do
    case Regex.run(~r/\A([-a-z0-9.]+)=([-a-z0-9.]*)=([-a-z0-9.]*)=(\d*)=(\w*)=(\d*)\z/, line) do
      [_, certificate, name, issuer, generation, ready, observed] ->
        %{
          certificate: certificate,
          name: name,
          issuer: issuer,
          generation: generation,
          ready: ready,
          observed: observed
        }

      nil ->
        %{certificate: line |> String.split("=", parts: 2) |> hd(), name: ""}
    end
  end

  defp issued?(target, %{
         name: name,
         issuer: issuer,
         ready: "True",
         generation: generation,
         observed: generation
       })
       when generation != "",
       do:
         String.ends_with?(name, "." <> target.host) and
           issuer == PublicCertificates.addresses_issuer()

  defp issued?(_target, _state), do: false

  # What the operator is told to wait for: the address's name under the new host, also while its
  # Certificate still names the old host's, else the Certificate's own name.
  defp shown(target, from, %{name: name, certificate: certificate}) do
    cond do
      String.ends_with?(name, "." <> target.host) ->
        name

      is_binary(from) and String.ends_with?(name, "." <> from) ->
        String.replace_suffix(name, from, target.host)

      true ->
        "#{@addresses}/#{certificate}"
    end
  end

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
  # caller keeps those of the form it asked for. A read that the API server does not answer ends,
  # as `Install`'s reads of the console's issuer do, so a wait polls again rather than hang.
  defp read(target, args) do
    case target.runner.run("kubectl", Install.kubectl_args(target, args ++ [@request_timeout])) do
      {output, 0} ->
        {:ok, String.split(output, "\n", trim: true)}

      {:error, :not_found} ->
        {:error,
         "`kubectl` is not installed, or not at the version EHOS pins: `ehosctl doctor` says what is missing"}

      {output, status} ->
        {:error, Failure.exited("kubectl", status, output)}
    end
  end
end

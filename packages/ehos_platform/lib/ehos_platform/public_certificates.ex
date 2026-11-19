defmodule EhosPlatform.PublicCertificates do
  @moduledoc """
  What an installation with public certificates needs before EHOS's chart can ask Let's Encrypt
  for them (eh-os D-158), made by `EhosPlatform.Install` on the target it installs:

    * `acme_dns/2` runs acme-dns in `ehos-acme-dns` (`priv/manifests/acme-dns.yaml`), registers
      its one account once, keeps the account in `cert-manager/ehos-acme-dns`, where the chart's
      DNS-01 solver reads it, and then runs acme-dns with registration closed;
    * `account_keys/1` makes the two Let's Encrypt account keys, as RSA keys, which cert-manager
      requires, before either issuer, and never again while they are there;
    * `issuers/2` applies the chart's two ACME `ClusterIssuer`s, rendered from the chart, so that
      cert-manager registers the two accounts, and reads their URIs, which the company's `CAA`
      records name; the chart takes them over when it is installed;
    * `chart_values/1` gives the chart its `publicCertificates` values.

  A run again reuses acme-dns's account and both keys, since the company's records name them.
  Nothing here removes them: an uninstall keeps them, and so does a run without public
  certificates, which removes the issuers of a move it abandons
  (`EhosPlatform.Move.abandoned_removed/1`).
  """

  alias EhosPlatform.Failure
  alias EhosPlatform.Install
  alias EhosPlatform.TmpDir

  # eh-os D-158: acme-dns v2.0.2, built by ehos-tools for amd64 and arm64
  # (`packaging/acme-dns/Dockerfile`), by the digest of the index its workflow published, scanned
  # for both and tagged `latest`. Renovate moves it to the next `latest` (ehos-tools T-24).
  @acme_dns_image "ghcr.io/empoweredhouse/acme-dns@sha256:64fc6600f956b70c492605793706450f5a09ed0efb04db7a980aa333e0096989"
  @manifest "acme-dns.yaml"
  @namespace "ehos-acme-dns"
  @pull_credential "ehos-pull-credential"
  # What a container waits with while its image cannot be pulled.
  @pull_reasons ["ErrImagePull", "ImagePullBackOff"]
  @pull_failed "acme-dns's pod cannot pull its image"
  @pull_message @pull_failed <>
                  " from GHCR, where it is a private package. The pull credential " <>
                  "#{@namespace}/#{@pull_credential} is missing, or GHCR refuses it. " <>
                  "Set GHCR_TOKEN to a classic GitHub token with read:packages. " <>
                  "Then run the command again"
  @cert_manager "cert-manager"
  # The Secret the chart's `acmeDNS` solver reads, and its key.
  @account_secret "ehos-acme-dns"
  @account_key "acmedns.json"
  # The chart's two ClusterIssuers, each with the Secret of its account key, of the same name.
  @console "ehos-acme-console"
  @addresses "ehos-acme-addresses"
  @api "http://acme-dns-api.#{@namespace}.svc.cluster.local:8080"
  @server "https://acme-v02.api.letsencrypt.org/directory"
  # Let's Encrypt's roots, ISRG Root X1 and X2, which a workload trusts for EHOS (eh-os D-158),
  # checked against their SHA-256 fingerprints on 5 November 2026:
  # 96:BC:EC:06:26:49:76:F3:74:60:77:9A:CF:28:C5:A7:CF:E8:A3:C0:AA:E1:1A:8F:FC:EE:05:C0:BD:DF:08:C6
  # 69:72:9B:8E:15:A8:6E:FC:17:7A:57:AF:B7:17:1D:FC:64:AD:D2:8C:2F:CA:8C:F1:50:7E:34:45:3C:CB:14:70
  @roots "letsencrypt-roots.pem"

  @doc "The ClusterIssuer of the console's certificate."
  @spec console_issuer() :: String.t()
  def console_issuer, do: @console

  @doc "The ClusterIssuer of every application's address."
  @spec addresses_issuer() :: String.t()
  def addresses_issuer, do: @addresses

  @doc "The path of Let's Encrypt's roots, in this package's `priv/`."
  @spec roots() :: Path.t()
  def roots,
    do: Path.join([Application.app_dir(:ehos_platform), "priv", "certificates", @roots])

  @doc """
  Gives `ehos-acme-dns` the pull credential for GHCR, where acme-dns's image is a private package,
  as EHOS's is: written from `registry_auth`, `{username, token}`, as
  `EhosPlatform.Install.write_pull_credential/5` writes it, or, when that is `nil`, copied from
  `ehos-system`'s, which an earlier install wrote. Without either, it says the token is needed
  rather than leave acme-dns waiting for an image it cannot pull.
  """
  @spec pull_credential(Install.t(), {String.t(), String.t()} | nil) ::
          :ok | {:error, Failure.message()}
  def pull_credential(%Install{} = target, {username, token}),
    do: Install.write_pull_credential(target, "ghcr.io", username, token, namespace())

  def pull_credential(%Install{} = target, nil),
    do:
      Install.copy_pull_credential(
        target,
        namespace(),
        "acme-dns's image is in a private GHCR package, and ehos-system holds no pull " <>
          "credential to copy: set GHCR_TOKEN to a classic GitHub token with read:packages"
      )

  # The Namespace of acme-dns.yaml, which goes whole in the server-side apply of the pull
  # credential: one of its name alone takes over the labels that the client-side apply of
  # acme-dns.yaml set, and removes them, as it did for ehos-data (eh-os#1632). Its document has
  # none of the values the manifest is rendered with.
  defp namespace,
    do:
      @manifest
      |> Install.manifest()
      |> YamlElixir.read_all_from_file!()
      |> Enum.find(&(&1["kind"] == "Namespace"))

  @doc """
  Runs acme-dns for the target's host and returns the name its account answers for, the value of
  the company's `CNAME` at `_acme-challenge.<host>`. acme-dns answers DNS on port 53 of each node's
  `InternalIP`, read from the nodes, and of no other address of theirs (ehos-tools T-25).

  The account is registered only when `cert-manager/ehos-acme-dns` holds none for the host: with
  registration open, through the pod's own loopback, admitting updates from the nodes' pod
  addresses alone; then acme-dns runs again with registration closed.

  Options: `:image`, acme-dns's image, the one this package pins unless given.
  """
  @spec acme_dns(Install.t(), keyword()) :: {:ok, String.t()} | {:error, Failure.message()}
  def acme_dns(%Install{} = target, opts \\ []) do
    image = Keyword.get(opts, :image, @acme_dns_image)

    with {:ok, accounts} <- accounts(target),
         {:ok, addresses} <- node_addresses(target) do
      acme = %{image: image, addresses: addresses}
      with_account(target, acme, accounts, Map.fetch(accounts, target.host))
    end
  end

  @doc """
  Removes acme-dns's Service when it is of type `LoadBalancer`, as an `ehos_platform` before 0.16.1
  made it: ServiceLB's port 53 for it also takes the node's resolver stub on `127.0.0.53`, and the
  node then pulls no image (ehos-tools#887, T-25). `EhosPlatform.Install.server/1` calls it before
  anything pulls an image, on every run, with public certificates or not; `acme_dns/2` makes the
  Service again, as a `ClusterIP`. A Service of another type, or none, is left as it is.
  """
  @spec earlier_service_removed(Install.t()) :: :ok | {:error, Failure.message()}
  def earlier_service_removed(%Install{} = target) do
    args =
      Install.kubectl_args(target, [
        "get",
        "service",
        "acme-dns",
        "-n",
        @namespace,
        "--ignore-not-found",
        "--request-timeout=10s",
        "-o",
        "jsonpath={.spec.type}"
      ])

    case target.runner.run("kubectl", args) do
      {output, 0} ->
        if "LoadBalancer" in String.split(output, "\n", trim: true),
          do: earlier_service_deleted(target),
          else: :ok

      result ->
        failure(result)
    end
  end

  # The Service is gone once k3s has removed its load balancer, the finalizer's work, so a later
  # apply never lands on a Service being deleted. ServiceLB's pod, whose rule takes the resolver,
  # goes after it: its wait only lets the next pulls through sooner, so the run goes on whatever
  # it answers.
  defp earlier_service_deleted(target) do
    target.progress.(
      {:step,
       "Removing acme-dns's Service of type LoadBalancer, which takes the server's DNS resolver"}
    )

    case Install.kubectl(target, [
           "delete",
           "service",
           "acme-dns",
           "-n",
           @namespace,
           "--timeout=60s"
         ]) do
      :ok ->
        _gone = servicelb_gone(target)
        :ok

      {:error, message} ->
        {:error,
         Failure.added(
           message,
           "\nacme-dns's Service of type LoadBalancer is not gone. k3s's ServiceLB removes it " <>
             "once it has removed its own pod for it. Make sure that k3s runs ServiceLB. " <>
             "`kubectl -n #{@namespace} get service acme-dns -o yaml` shows its finalizers. " <>
             "Then run the command again"
         )}
    end
  end

  # Waits up to a minute for ServiceLB's pod of acme-dns's Service to go, and with it the rule that
  # takes port 53 of every local address; what kubectl answers is not the caller's concern.
  defp servicelb_gone(target) do
    Install.kubectl(target, [
      "wait",
      "--for=delete",
      "pods",
      "-n",
      "kube-system",
      "-l",
      "svccontroller.k3s.cattle.io/svcname=acme-dns," <>
        "svccontroller.k3s.cattle.io/svcnamespace=#{@namespace}",
      "--timeout=60s"
    ])
  end

  # ehos-tools T-25: port 53 of the nodes' own addresses, each node's InternalIP, where the provider
  # delivers the server's public address. A ServiceLB hostPort would take port 53 of every local
  # address, the resolver stub of the node on 127.0.0.53 too (ehos-tools#887).
  defp node_addresses(target) do
    args =
      Install.kubectl_args(target, [
        "get",
        "nodes",
        "--request-timeout=10s",
        "-o",
        ~S'jsonpath={.items[*].status.addresses[?(@.type=="InternalIP")].address}'
      ])

    case target.runner.run("kubectl", args) do
      {output, 0} ->
        output |> String.split() |> Enum.filter(&ipv4?/1) |> Enum.uniq() |> addresses()

      result ->
        failure(result)
    end
  end

  defp ipv4?(word), do: match?({:ok, _}, :inet.parse_ipv4strict_address(String.to_charlist(word)))

  defp addresses([]),
    do: {:error, "The nodes name no IPv4 address of their own (status.addresses, InternalIP)"}

  defp addresses(addresses), do: {:ok, addresses}

  defp with_account(target, acme, _accounts, {:ok, %{"fulldomain" => fulldomain} = account}) do
    target.progress.({:step, "Running acme-dns for #{target.host}, with its account"})

    with :ok <- run_acme_dns(target, acme, :closed) do
      nodes_admitted(target, account)
      {:ok, fulldomain}
    end
  end

  defp with_account(target, acme, accounts, _none), do: register(target, acme, accounts)

  # ehos-tools#827: the account admits the pod addresses the nodes had when it was registered. A
  # node added since is outside them, and cert-manager's controller there cannot write the
  # console's record, which is said rather than left to the 10 minutes' wait.
  defp nodes_admitted(target, %{"allowfrom" => [_ | _] = admitted}) do
    with {:ok, cidrs} <- pod_cidrs(target),
         [_ | _] = outside <- cidrs -- admitted do
      target.progress.(
        {:warning,
         "acme-dns admits the record of the console only from #{Enum.join(admitted, ", ")}, " <>
           "the pod addresses of the nodes when its account was registered.",
         "cert-manager on a node with the pod addresses #{Enum.join(outside, ", ")} cannot get " <>
           "or renew the certificate of the console. To register the account again, run " <>
           "`kubectl -n cert-manager delete secret #{@account_secret}`. Then run this command " <>
           "again. Then change the _acme-challenge record to the name that it prints."}
      )
    end
  end

  defp nodes_admitted(_target, _account), do: :ok

  defp register(target, acme, accounts) do
    target.progress.({:step, "Running acme-dns for #{target.host}, and registering its account"})

    with :ok <- opened(target, acme),
         {:ok, account} <- registered_and_kept(target, acme, accounts),
         :ok <- run_acme_dns(target, acme, :closed) do
      {:ok, account["fulldomain"]}
    end
  end

  # A rollout that does not end leaves the open configuration applied: it is closed again too.
  defp opened(target, acme) do
    with {:error, message} <- run_acme_dns(target, acme, :open),
         do: closed_again(target, acme, message)
  end

  # Registration is closed again when a step after it was opened fails, so a failed run never
  # leaves it open; what failed is said.
  defp registered_and_kept(target, acme, accounts) do
    with {:ok, cidrs} <- pod_cidrs(target),
         {:ok, account} <- registered(target, cidrs),
         :ok <- write_accounts(target, Map.put(accounts, target.host, account)) do
      {:ok, account}
    else
      {:error, message} -> closed_again(target, acme, message)
    end
  end

  # What failed, and whether registration could be closed again after it. An image that cannot be
  # pulled ran no pod, so registration was never open: the closed manifest is applied for when the
  # image can be pulled, and its rollout, which would fail the same way 3 minutes later, is not
  # waited for (ehos-tools#874).
  defp closed_again(target, acme, message) do
    closing =
      if String.starts_with?(to_string(message), @pull_failed),
        do: apply_acme_dns(target, acme, :closed),
        else: run_acme_dns(target, acme, :closed)

    case closing do
      :ok ->
        {:error, message}

      {:error, _closing} ->
        {:error,
         Failure.added(
           message,
           "\nacme-dns's registration may still be open: run the command again to close it"
         )}
    end
  end

  # The manifest, rendered, applied, and its pod ready.
  defp run_acme_dns(target, acme, registration) do
    with :ok <- apply_acme_dns(target, acme, registration) do
      pending_restarted(target)
      rolled_out(target)
    end
  end

  # ehos-tools#887: a pod that waits for its image waits up to 5 minutes between pulls, longer
  # than the rollout's wait, and its last failure says why the pull failed then, not now. On a
  # server whose resolver the old Service took, the Service is no longer a LoadBalancer once the
  # manifest is applied (or `earlier_service_removed/1` removed it before), and k3s removes
  # ServiceLB's pod for it, whose rule took the resolver: once that pod is gone, up to a minute, a
  # pod of acme-dns's that is not running yet is replaced by its ReplicaSet, loses nothing, and
  # pulls at once. Both steps only speed the rollout up, so the run goes on whatever they answer.
  defp pending_restarted(target) do
    _gone = servicelb_gone(target)

    _deleted =
      Install.kubectl(target, [
        "delete",
        "pods",
        "-n",
        @namespace,
        "-l",
        "app.kubernetes.io/name=acme-dns",
        "--field-selector=status.phase=Pending",
        "--ignore-not-found",
        "--wait=false",
        "--request-timeout=10s"
      ])

    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp apply_acme_dns(target, acme, registration) do
    rendered =
      @manifest
      |> Install.manifest()
      |> File.read!()
      |> Install.for_host(target.host)
      |> String.replace("ACME_DNS_IMAGE", acme.image)
      |> String.replace("NODE_ADDRESSES", Jason.encode!(acme.addresses))
      |> String.replace("REGISTRATION_CLOSED", to_string(registration == :closed))
      |> String.replace("REGISTRATION_STATE", to_string(registration))

    TmpDir.with_tmp_dir("ehos-acme-dns", fn dir ->
      path = Path.join(dir, @manifest)
      File.write!(path, rendered)
      Install.kubectl(target, ["apply", "-f", path])
    end)
  end

  defp rolled_out(target) do
    case Install.kubectl(target, [
           "rollout",
           "status",
           "deployment/acme-dns",
           "-n",
           @namespace,
           "--timeout=3m"
         ]) do
      :ok -> :ok
      {:error, message} -> {:error, pull_failure(target) || message}
    end
  end

  # ehos-tools#827: a rollout that does not end because the image cannot be pulled says why, and
  # what to change, rather than kubectl's timeout; nil when the pod waits for something else, or
  # cannot be read. A node that cannot resolve the registry's name is said as that, not as the
  # credential (ehos-tools#887).
  defp pull_failure(target) do
    args =
      Install.kubectl_args(target, [
        "get",
        "pods",
        "-n",
        @namespace,
        "-l",
        "app.kubernetes.io/name=acme-dns",
        "--request-timeout=10s",
        "-o",
        ~S'jsonpath={range .items[*].status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}'
      ])

    case target.runner.run("kubectl", args) do
      {output, 0} -> output |> String.split("\n", trim: true) |> pull_refused(target)
      _unreadable -> nil
    end
  end

  defp pull_refused(reasons, target) do
    if Enum.any?(reasons, &(&1 in @pull_reasons)),
      do: target |> last_pull_error() |> pull_message()
  end

  # What the kubelet said of the last pull that failed in the namespace, from its events; nil when
  # it said nothing or cannot be read.
  defp last_pull_error(target) do
    args =
      Install.kubectl_args(target, [
        "get",
        "events",
        "-n",
        @namespace,
        "--field-selector",
        "involvedObject.kind=Pod,reason=Failed",
        "--sort-by=.lastTimestamp",
        "--request-timeout=10s",
        "-o",
        ~S'jsonpath={range .items[*]}{.message}{"\n"}{end}'
      ])

    case target.runner.run("kubectl", args) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "Failed to pull image"))
        |> List.last()

      _unreadable ->
        nil
    end
  end

  # Go's resolver says `lookup <name>: <cause>`, or `lookup <name> on <server>: <cause>`.
  defp pull_message(error) do
    case error && Regex.run(~r/lookup ([A-Za-z0-9.-]+)(?: on \S+)?: [^"\n]+/, error) do
      [lookup, name] ->
        @pull_failed <>
          ": the server cannot resolve #{name} (#{String.trim_trailing(lookup)}). The pull " <>
          "credential is not the cause. On the server, run resolvectl query #{name}, and make " <>
          "sure that the server's DNS resolver answers. Then run the command again"

      _other ->
        @pull_message
    end
  end

  # The accounts acme-dns has, by host, as the solver reads them; none when the Secret is not there.
  defp accounts(target) do
    args =
      Install.kubectl_args(target, [
        "get",
        "secret",
        @account_secret,
        "-n",
        @cert_manager,
        "--ignore-not-found",
        "-o",
        "jsonpath={.data.acmedns\\.json}"
      ])

    case target.runner.run("kubectl", args) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> List.last("") |> decode_accounts()

      result ->
        failure(result)
    end
  end

  defp decode_accounts(""), do: {:ok, %{}}

  defp decode_accounts(encoded) do
    with {:ok, json} <- Base.decode64(encoded),
         {:ok, %{} = accounts} <- Jason.decode(json) do
      {:ok, accounts}
    else
      _other -> {:error, "#{@cert_manager}/#{@account_secret} holds no acme-dns accounts"}
    end
  end

  # D-158: the account's updates are admitted from the cluster's pod addresses alone, the nodes'
  # pod CIDRs; cert-manager's controller writes from one of them.
  defp pod_cidrs(target) do
    args =
      Install.kubectl_args(target, [
        "get",
        "nodes",
        "--request-timeout=10s",
        "-o",
        "jsonpath={.items[*].spec.podCIDRs[*]}"
      ])

    case target.runner.run("kubectl", args) do
      {output, 0} ->
        cidrs = output |> String.split("\n", trim: true) |> List.last("") |> String.split()

        if cidrs != [] and Enum.all?(cidrs, &(&1 =~ ~r|\A[0-9a-f:.]+/\d{1,3}\z|)),
          do: {:ok, cidrs},
          else: {:error, "The nodes name no pod addresses (spec.podCIDRs): #{output}"}

      result ->
        failure(result)
    end
  end

  # The registration answers the account's password, so what a failure says never holds the
  # output.
  defp registered(target, cidrs) do
    body = Jason.encode!(%{"allowfrom" => cidrs})

    args =
      Install.kubectl_args(target, [
        "exec",
        "-n",
        @namespace,
        "deployment/acme-dns",
        "--",
        "wget",
        "-q",
        "-O",
        "-",
        "--header",
        "Content-Type: application/json",
        "--post-data",
        body,
        "http://127.0.0.1:8080/register"
      ])

    case target.runner.run("kubectl", args) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> List.last("") |> Jason.decode() |> account()

      {_output, status} when is_integer(status) ->
        {:error, "acme-dns registered no account: `kubectl exec` exited #{status}"}

      result ->
        failure(result)
    end
  end

  defp account({:ok, %{"fulldomain" => fulldomain, "username" => _, "password" => _} = account})
       when is_binary(fulldomain),
       do: {:ok, account}

  defp account(_other), do: {:error, "acme-dns answered no account to its registration"}

  defp write_accounts(target, accounts) do
    json = Jason.encode!(accounts)
    encoded = Base.encode64(json)
    passwords = for {_host, %{"password" => password}} <- accounts, do: password

    secret = %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "type" => "Opaque",
      "metadata" => %{"name" => @account_secret, "namespace" => @cert_manager},
      "data" => %{@account_key => encoded}
    }

    Install.apply_secret(target, secret, [encoded, json | passwords], "[acme-dns's account]")
  end

  @doc """
  Makes each Let's Encrypt account key that `cert-manager` does not hold yet, `ehos-acme-console`
  and `ehos-acme-addresses`: an RSA key of 2048 bits, in `tls.key`, as cert-manager reads an ACME
  account's key.
  """
  @spec account_keys(Install.t()) :: :ok | {:error, Failure.message()}
  def account_keys(%Install{} = target) do
    Enum.reduce_while([@console, @addresses], :ok, fn name, :ok ->
      case account_key(target, name) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp account_key(target, name) do
    case exists?(target, "secret", name, @cert_manager) do
      {:ok, true} ->
        target.progress.(
          {:step, "Keeping the Let's Encrypt account key #{@cert_manager}/#{name}"}
        )

        :ok

      {:ok, false} ->
        target.progress.({:step, "Making the Let's Encrypt account key #{@cert_manager}/#{name}"})
        key = :public_key.generate_key({:rsa, 2048, 65_537})
        pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
        encoded = Base.encode64(pem)

        secret = %{
          "apiVersion" => "v1",
          "kind" => "Secret",
          "type" => "Opaque",
          "metadata" => %{"name" => name, "namespace" => @cert_manager},
          "data" => %{"tls.key" => encoded}
        }

        Install.apply_secret(target, secret, [encoded, pem], "[the key]")

      error ->
        error
    end
  end

  @doc """
  Applies each of the two ACME ClusterIssuers that is not there yet, from the chart rendered with
  its public certificates' values by `render`, which is called only then: marked as the `ehos`
  release's and applied as Helm applies, so the chart takes them over. Then waits until
  cert-manager has registered both accounts, and returns their URIs: `%{console: uri, addresses:
  uri}`.
  """
  @spec issuers(Install.t(), (-> {:ok, String.t()} | {:error, Failure.message()})) ::
          {:ok, %{console: String.t(), addresses: String.t()}} | {:error, Failure.message()}
  def issuers(%Install{} = target, render) do
    with {:ok, missing} <- missing_issuers(target),
         :ok <- apply_missing(target, missing, render),
         {:ok, console} <- account_uri(target, @console),
         {:ok, addresses} <- account_uri(target, @addresses) do
      {:ok, %{console: console, addresses: addresses}}
    end
  end

  defp missing_issuers(target) do
    Enum.reduce_while([@console, @addresses], {:ok, []}, fn name, {:ok, missing} ->
      case exists?(target, "clusterissuer", name, nil) do
        {:ok, true} -> {:cont, {:ok, missing}}
        {:ok, false} -> {:cont, {:ok, missing ++ [name]}}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_missing(_target, [], _render), do: :ok

  defp apply_missing(target, missing, render) do
    with {:ok, rendered} <- render.(),
         {:ok, documents} <- issuer_documents(rendered) do
      documents
      |> Enum.filter(&(&1["metadata"]["name"] in missing))
      |> Enum.reduce_while(:ok, &apply_next(target, &1, &2))
    end
  end

  defp apply_next(target, document, :ok) do
    case apply_issuer(target, document) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp issuer_documents(rendered) do
    documents =
      for %{"kind" => "ClusterIssuer", "metadata" => %{"name" => name}} = document <-
            YamlElixir.read_all_from_string!(rendered),
          name in [@console, @addresses],
          do: document

    if length(documents) == 2,
      do: {:ok, documents},
      else: {:error, "EHOS's chart renders no ACME ClusterIssuers: it is older than EHOS 0.26.0"}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp apply_issuer(target, %{"metadata" => %{"name" => name}} = document) do
    target.progress.({:step, "Making the ClusterIssuer #{name}, which registers its account"})

    TmpDir.with_tmp_dir("ehos-acme-issuer", fn dir ->
      path = Path.join(dir, "#{name}.json")
      File.write!(path, Jason.encode!(helms(document)))

      # As Helm 4 applies, server-side as `helm`, so its upgrade owns every field.
      Install.kubectl(target, ["apply", "--server-side", "--field-manager=helm", "-f", path])
    end)
  end

  @doc """
  `document`, a Kubernetes object rendered from EHOS's chart, marked as the `ehos` release's, so
  that the chart's install takes it over.
  """
  @spec helms(map()) :: map()
  def helms(document) do
    metadata =
      document["metadata"]
      |> Map.update("labels", %{"app.kubernetes.io/managed-by" => "Helm"}, fn labels ->
        Map.put(labels || %{}, "app.kubernetes.io/managed-by", "Helm")
      end)
      |> Map.update("annotations", %{}, &(&1 || %{}))
      |> update_in(["annotations"], fn annotations ->
        Map.merge(annotations, %{
          "meta.helm.sh/release-name" => "ehos",
          "meta.helm.sh/release-namespace" => "ehos-system"
        })
      end)

    Map.put(document, "metadata", metadata)
  end

  defp account_uri(target, name) do
    with :ok <-
           Install.kubectl(target, [
             "wait",
             "--for=condition=Ready",
             "clusterissuer/#{name}",
             "--timeout=3m"
           ]) do
      args =
        Install.kubectl_args(target, [
          "get",
          "clusterissuer",
          name,
          "-o",
          "jsonpath={.status.acme.uri}"
        ])

      case target.runner.run("kubectl", args) do
        {output, 0} -> uri(name, output |> String.split("\n", trim: true) |> List.last(""))
        result -> failure(result)
      end
    end
  end

  defp uri(_name, "https://" <> _rest = uri), do: {:ok, uri}
  defp uri(name, _none), do: {:error, "The ClusterIssuer #{name} names no ACME account"}

  defp exists?(target, kind, name, namespace) do
    on = if namespace, do: ["-n", namespace], else: []

    args =
      Install.kubectl_args(
        target,
        ["get", kind, name] ++ on ++ ["--ignore-not-found", "-o", "name"]
      )

    case target.runner.run("kubectl", args) do
      {output, 0} -> {:ok, output |> String.split("\n", trim: true) |> List.last("") != ""}
      result -> failure(result)
    end
  end

  @doc """
  The chart's `--set` arguments for public certificates: the ACME server, Let's Encrypt's unless
  `:server` names another, acme-dns's API, and the HTTP-01 solver's image, `:solver_image`
  (required), the one cert-manager runs. `:ca_bundle`, a file, is the CA of a test server such as
  Pebble. `:records`, the values of the company's DNS records that the installer printed and
  checked (the server's address, acme-dns's name for the challenge, and the two accounts' URIs),
  which the governance plane checks each day and the console shows (eh-os D-162).
  """
  @spec chart_values(keyword()) :: [String.t()]
  def chart_values(opts) do
    [
      "--set",
      "publicCertificates.enabled=true",
      "--set",
      "publicCertificates.server=#{Keyword.get(opts, :server, @server)}",
      "--set",
      "publicCertificates.console.acmeDNS.host=#{@api}",
      "--set",
      "publicCertificates.addresses.solverImage=#{Keyword.fetch!(opts, :solver_image)}"
    ] ++
      case Keyword.get(opts, :ca_bundle) do
        nil -> []
        file -> ["--set-file", "publicCertificates.caBundle=#{file}"]
      end ++ records_values(Keyword.get(opts, :records))
  end

  # The records' values as `chart_values/1`'s `:records` holds them, and as the chart names them.
  @record_keys [
    {"address", :address},
    {"challenge", :challenge},
    {"consoleAccount", :console_account},
    {"addressesAccount", :addresses_account}
  ]

  defp records_values(nil), do: []

  defp records_values(values),
    do: [
      "--set-json",
      "publicCertificates.records=" <>
        Jason.encode!(
          Map.new(@record_keys, fn {chart, key} -> {chart, Map.fetch!(values, key)} end)
        )
    ]

  @doc """
  The records' values from the chart's `publicCertificates.records`, as a release holds them, in
  the form `chart_values/1` takes; nil unless all four are there, as text.

      iex> EhosPlatform.PublicCertificates.records(%{
      ...>   "address" => "203.0.113.10",
      ...>   "challenge" => "4f2c._acme-dns.ehos.client.example",
      ...>   "consoleAccount" => "https://acme-v02.api.letsencrypt.org/acme/acct/1",
      ...>   "addressesAccount" => "https://acme-v02.api.letsencrypt.org/acme/acct/2"
      ...> })
      %{
        address: "203.0.113.10",
        challenge: "4f2c._acme-dns.ehos.client.example",
        console_account: "https://acme-v02.api.letsencrypt.org/acme/acct/1",
        addresses_account: "https://acme-v02.api.letsencrypt.org/acme/acct/2"
      }

      iex> EhosPlatform.PublicCertificates.records(%{})
      nil
  """
  @spec records(term()) :: map() | nil
  def records(chart) when is_map(chart) do
    values =
      for {name, key} <- @record_keys, is_binary(chart[name]), into: %{}, do: {key, chart[name]}

    if map_size(values) == length(@record_keys), do: values
  end

  def records(_chart), do: nil

  defp failure({:error, :not_found}),
    do:
      {:error,
       "`kubectl` is not installed, or not at the version EHOS pins: `ehosctl doctor` says what is missing"}

  defp failure({output, status}),
    do: {:error, Failure.exited("kubectl", status, output)}
end

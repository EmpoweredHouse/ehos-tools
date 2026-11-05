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
  certificates.
  """

  alias EhosPlatform.Install
  alias EhosPlatform.TmpDir

  # eh-os D-158: acme-dns v2.0.2, built by ehos-tools for amd64 and arm64
  # (`packaging/acme-dns/Dockerfile`, with golang.org/x/net v0.60.0), by the digest of the index
  # its workflow published from ehos-tools#824 (018e94fa).
  @acme_dns_image "ghcr.io/empoweredhouse/acme-dns@sha256:0f8f30daaed1988d79863d6ca7860599d04ffbe1dedb80d90bffe75968959971"
  @manifest "acme-dns.yaml"
  @namespace "ehos-acme-dns"
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
  Runs acme-dns for the target's host and returns the name its account answers for, the value of
  the company's `CNAME` at `_acme-challenge.<host>`.

  The account is registered only when `cert-manager/ehos-acme-dns` holds none for the host: with
  registration open, through the pod's own loopback, admitting updates from the nodes' pod
  addresses alone; then acme-dns runs again with registration closed.

  Options: `:image`, acme-dns's image, the one this package pins unless given.
  """
  @spec acme_dns(Install.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def acme_dns(%Install{} = target, opts \\ []) do
    image = Keyword.get(opts, :image, @acme_dns_image)

    with {:ok, accounts} <- accounts(target),
         do: with_account(target, image, accounts, Map.fetch(accounts, target.host))
  end

  defp with_account(target, image, _accounts, {:ok, %{"fulldomain" => fulldomain}}) do
    target.progress.("Running acme-dns for #{target.host}, with its account")
    with :ok <- run_acme_dns(target, image, :closed), do: {:ok, fulldomain}
  end

  defp with_account(target, image, accounts, _none), do: register(target, image, accounts)

  defp register(target, image, accounts) do
    target.progress.("Running acme-dns for #{target.host}, and registering its account")

    with :ok <- run_acme_dns(target, image, :open),
         {:ok, account} <- registered_and_kept(target, image, accounts),
         :ok <- run_acme_dns(target, image, :closed) do
      {:ok, account["fulldomain"]}
    end
  end

  # Registration is closed again when a step after it was opened fails, so a failed run never
  # leaves it open; what failed is said.
  defp registered_and_kept(target, image, accounts) do
    with {:ok, cidrs} <- pod_cidrs(target),
         {:ok, account} <- registered(target, cidrs),
         :ok <- write_accounts(target, Map.put(accounts, target.host, account)) do
      {:ok, account}
    else
      error ->
        _closed = run_acme_dns(target, image, :closed)
        error
    end
  end

  # The manifest, rendered, applied, and its pod ready.
  # sobelow_skip ["Traversal.FileModule"]
  defp run_acme_dns(target, image, registration) do
    rendered =
      @manifest
      |> Install.manifest()
      |> File.read!()
      |> Install.for_host(target.host)
      |> String.replace("ACME_DNS_IMAGE", image)
      |> String.replace("REGISTRATION_CLOSED", to_string(registration == :closed))
      |> String.replace("REGISTRATION_STATE", to_string(registration))

    applied =
      TmpDir.with_tmp_dir("ehos-acme-dns", fn dir ->
        path = Path.join(dir, @manifest)
        File.write!(path, rendered)
        Install.kubectl(target, ["apply", "-f", path])
      end)

    with :ok <- applied do
      Install.kubectl(target, [
        "rollout",
        "status",
        "deployment/acme-dns",
        "-n",
        @namespace,
        "--timeout=3m"
      ])
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
        case output |> String.split("\n", trim: true) |> List.last("") do
          "" -> {:ok, %{}}
          encoded -> decode_accounts(encoded)
        end

      result ->
        failure(result)
    end
  end

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
  @spec account_keys(Install.t()) :: :ok | {:error, String.t()}
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
        target.progress.("Keeping the Let's Encrypt account key #{@cert_manager}/#{name}")
        :ok

      {:ok, false} ->
        target.progress.("Making the Let's Encrypt account key #{@cert_manager}/#{name}")
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
  @spec issuers(Install.t(), (-> {:ok, String.t()} | {:error, String.t()})) ::
          {:ok, %{console: String.t(), addresses: String.t()}} | {:error, String.t()}
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
    target.progress.("Making the ClusterIssuer #{name}, which registers its account")

    TmpDir.with_tmp_dir("ehos-acme-issuer", fn dir ->
      path = Path.join(dir, "#{name}.json")
      File.write!(path, Jason.encode!(helms(document)))

      # As Helm 4 applies, server-side as `helm`, so its upgrade owns every field.
      Install.kubectl(target, ["apply", "--server-side", "--field-manager=helm", "-f", path])
    end)
  end

  defp helms(document) do
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
  Pebble.
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
      end
  end

  defp failure({:error, :not_found}),
    do:
      {:error,
       "`kubectl` is not installed, or not at the version EHOS pins: `ehosctl doctor` says what is missing"}

  defp failure({output, status}),
    do: {:error, "`kubectl` failed with exit status #{status}:\n" <> output}
end

defmodule EhosPlatform.PublicCertificatesTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosPlatform.CommandRunnerMock
  alias EhosPlatform.Install
  alias EhosPlatform.PublicCertificates
  alias EhosPlatform.Source

  setup :verify_on_exit!

  @host "ehos.client.example"
  @target %Install{
    context: "ehos-trial",
    host: @host,
    source: Source.checkout("/src/eh-os"),
    runner: CommandRunnerMock
  }
  @account %{
    "username" => "c36f50e8-4632-44f0-83fe-e070fef28a10",
    "password" => "htB9mR5DNiaZwJGfLDnvlvH7Y0gG4l4z0a1hnYZf",
    "fulldomain" => "8e5700ea-a4bf-41c7-8a77-e990661dcc6a._acme-dns.#{@host}",
    "subdomain" => "8e5700ea-a4bf-41c7-8a77-e990661dcc6a",
    "allowfrom" => ["10.42.0.0/24"]
  }
  @image "ghcr.io/empoweredhouse/acme-dns@sha256:" <> String.duplicate("cd", 32)
  @svclb_gone [
    "wait",
    "--for=delete",
    "pods",
    "-n",
    "kube-system",
    "-l",
    "svccontroller.k3s.cattle.io/svcname=acme-dns,svccontroller.k3s.cattle.io/svcnamespace=ehos-acme-dns",
    "--timeout=60s"
  ]
  @pending [
    "delete",
    "pods",
    "-n",
    "ehos-acme-dns",
    "-l",
    "app.kubernetes.io/name=acme-dns",
    "--field-selector=status.phase=Pending",
    "--ignore-not-found",
    "--wait=false",
    "--request-timeout=10s"
  ]
  @addresses_read [
    "get",
    "nodes",
    "--request-timeout=10s",
    "-o",
    ~S'jsonpath={.items[*].status.addresses[?(@.type=="InternalIP")].address}'
  ]

  describe "acme_dns/2" do
    test "registers one account through the pod's loopback, keeps it for the solver, then closes registration" do
      {calls, files} =
        record(fn
          ["get", "secret", "ehos-acme-dns" | _] -> {"", 0}
          ["get", "nodes" | _] -> {"10.42.0.0/24", 0}
          ["exec" | _] -> {"Warning: a line first\n" <> Jason.encode!(@account), 0}
          _other -> {"", 0}
        end)

      assert PublicCertificates.acme_dns(@target, image: @image) == {:ok, @account["fulldomain"]}

      assert [
               ["get", "secret", "ehos-acme-dns", "-n", "cert-manager" | _],
               @addresses_read,
               ["apply", "-f", open],
               @svclb_gone,
               @pending,
               [
                 "rollout",
                 "status",
                 "deployment/acme-dns",
                 "-n",
                 "ehos-acme-dns",
                 "--timeout=3m"
               ],
               [
                 "get",
                 "nodes",
                 "--request-timeout=10s",
                 "-o",
                 "jsonpath={.items[*].spec.podCIDRs[*]}"
               ],
               [
                 "exec",
                 "-n",
                 "ehos-acme-dns",
                 "deployment/acme-dns",
                 "--",
                 "wget",
                 "-q",
                 "-O",
                 "-",
                 "--header",
                 "Content-Type: application/json",
                 "--post-data",
                 ~s({"allowfrom":["10.42.0.0/24"]}),
                 "http://127.0.0.1:8080/register"
               ],
               ["apply", "--server-side", "--force-conflicts", "-f", secret],
               ["annotate", "secret", "ehos-acme-dns", "-n", "cert-manager" | _],
               ["apply", "-f", closed],
               @svclb_gone,
               @pending,
               ["rollout", "status", "deployment/acme-dns" | _]
             ] = calls.()

      assert files.(open) =~ "disable_registration = false"
      assert files.(open) =~ ~s(ehos.empowered.house/registration: "open")
      assert files.(closed) =~ "disable_registration = true"
      assert files.(closed) =~ ~s(ehos.empowered.house/registration: "closed")
      assert files.(closed) =~ "image: #{@image}"
      assert files.(closed) =~ ~s(domain = "_acme-dns.#{@host}")
      assert files.(closed) =~ ~s(records = [ "_acme-dns.#{@host}. NS #{@host}." ])
      refute files.(closed) =~ "ehos.localhost"
      # Its image is in a private package, pulled with the installation's credential.
      assert files.(closed) =~ "name: ehos-pull-credential"

      %{"items" => [_namespace, %{"data" => %{"acmedns.json" => encoded}}]} =
        Jason.decode!(files.(secret))

      assert encoded |> Base.decode64!() |> Jason.decode!() == %{@host => @account}
    end

    test "reuses the account it holds for the host, with registration closed" do
      held = %{@host => @account} |> Jason.encode!() |> Base.encode64()

      {calls, files} =
        record(fn
          ["get", "secret", "ehos-acme-dns" | _] -> {held, 0}
          _other -> {"", 0}
        end)

      assert PublicCertificates.acme_dns(@target, image: @image) == {:ok, @account["fulldomain"]}

      assert [
               ["get", "secret", "ehos-acme-dns" | _],
               @addresses_read,
               ["apply", "-f", closed],
               @svclb_gone,
               @pending,
               ["rollout", "status" | _],
               ["get", "nodes" | _]
             ] = calls.()

      assert files.(closed) =~ "disable_registration = true"
    end

    # ehos-tools#827: a node added after the account was registered.
    test "warns when a node's pod addresses are outside those the account admits" do
      held =
        %{@host => Map.put(@account, "allowfrom", ["10.42.0.0/24"])}
        |> Jason.encode!()
        |> Base.encode64()

      record(fn
        ["get", "secret", "ehos-acme-dns" | _] -> {held, 0}
        ["get", "nodes" | _] -> {"10.42.0.0/24 10.42.1.0/24", 0}
        _other -> {"", 0}
      end)

      test = self()
      target = %{@target | progress: &send(test, {:progress, &1})}

      assert PublicCertificates.acme_dns(target, image: @image) == {:ok, @account["fulldomain"]}

      assert_received {:progress,
                       {:warning,
                        "acme-dns admits the record of the console only from 10.42.0.0/24, the " <>
                          "pod addresses of the nodes when its account was registered.",
                        "cert-manager on a node with the pod addresses 10.42.1.0/24 cannot get " <>
                          "or renew the certificate of the console. To register the account " <>
                          "again, run `kubectl -n cert-manager delete secret ehos-acme-dns`. Then " <>
                          "run this command again. Then change the _acme-challenge record to the " <>
                          "name that it prints."}}
    end

    test "says nothing of the nodes when each is inside what the account admits" do
      held =
        %{@host => Map.put(@account, "allowfrom", ["10.42.0.0/24"])}
        |> Jason.encode!()
        |> Base.encode64()

      record(fn
        ["get", "secret", "ehos-acme-dns" | _] -> {held, 0}
        ["get", "nodes" | _] -> {"10.42.0.0/24", 0}
        _other -> {"", 0}
      end)

      test = self()
      target = %{@target | progress: &send(test, {:progress, &1})}

      assert PublicCertificates.acme_dns(target, image: @image) == {:ok, @account["fulldomain"]}
      refute_received {:progress, {:warning, _head, _explanation}}
    end

    test "says acme-dns registered nothing, and never prints what it answered" do
      record(fn
        ["get", "secret" | _] -> {"", 0}
        ["get", "nodes" | _] -> {"10.42.0.0/24", 0}
        ["exec" | _] -> {~s({"password":"secret-value"}), 0}
        _other -> {"", 0}
      end)

      assert PublicCertificates.acme_dns(@target, image: @image) ==
               {:error, "acme-dns answered no account to its registration"}

      record(fn
        ["get", "secret" | _] -> {"", 0}
        ["get", "nodes" | _] -> {"10.42.0.0/24", 0}
        ["exec" | _] -> {"secret-value\nerror", 1}
        _other -> {"", 0}
      end)

      assert PublicCertificates.acme_dns(@target, image: @image) ==
               {:error, "acme-dns registered no account: `kubectl exec` exited 1"}
    end
  end

  describe "acme_dns/2 when a step after registration opened fails" do
    test "closes registration again, and says what failed" do
      {calls, files} =
        record(fn
          ["get", "secret", "ehos-acme-dns" | _] -> {"", 0}
          ["get", "nodes" | _] -> {"10.42.0.0/24", 0}
          ["exec" | _] -> {"connection refused", 1}
          _other -> {"", 0}
        end)

      assert PublicCertificates.acme_dns(@target, image: @image) ==
               {:error, "acme-dns registered no account: `kubectl exec` exited 1"}

      assert [
               ["get", "secret" | _],
               @addresses_read,
               ["apply", "-f", open],
               @svclb_gone,
               @pending,
               ["rollout", "status" | _],
               ["get", "nodes" | _],
               ["exec" | _],
               ["apply", "-f", closed],
               @svclb_gone,
               @pending,
               ["rollout", "status" | _]
             ] = calls.()

      assert files.(open) =~ "disable_registration = false"
      assert files.(closed) =~ "disable_registration = true"
    end
  end

  test "acme_dns/2 closes registration again when the open rollout does not end" do
    {calls, files} =
      record(fn
        ["get", "secret", "ehos-acme-dns" | _] -> {"", 0}
        # The open rollout does not end; the closed one does.
        ["rollout" | _] -> if Process.put(:rolled, true), do: {"", 0}, else: {"timed out", 1}
        _other -> {"", 0}
      end)

    assert PublicCertificates.acme_dns(@target, image: @image) ==
             {:error, "`kubectl` failed with exit status 1:\ntimed out"}

    assert [
             ["get", "secret" | _],
             @addresses_read,
             ["apply", "-f", open],
             @svclb_gone,
             @pending,
             ["rollout" | _],
             ["get", "pods" | _],
             ["apply", "-f", closed],
             @svclb_gone,
             @pending,
             ["rollout" | _]
           ] = calls.()

    assert files.(open) =~ "disable_registration = false"
    assert files.(closed) =~ "disable_registration = true"
  end

  test "acme_dns/2 says what to change when acme-dns's image cannot be pulled" do
    {calls, files} =
      record(fn
        ["get", "secret", "ehos-acme-dns" | _] -> {"", 0}
        ["rollout" | _] -> {"error: timed out waiting for the condition", 1}
        ["get", "pods" | _] -> {"W1110 10:00:00 a warning\nImagePullBackOff\n", 0}
        _other -> {"", 0}
      end)

    assert PublicCertificates.acme_dns(@target, image: @image) ==
             {:error,
              "acme-dns's pod cannot pull its image from GHCR, where it is a private package. " <>
                "The pull credential ehos-acme-dns/ehos-pull-credential is missing, or GHCR " <>
                "refuses it. Set GHCR_TOKEN to a classic GitHub token with read:packages. Then " <>
                "run the command again"}

    # ehos-tools#874: registration is closed again in the manifest, without a second rollout.
    assert [
             ["get", "secret" | _],
             @addresses_read,
             ["apply", "-f", _open],
             @svclb_gone,
             @pending,
             ["rollout" | _],
             ["get", "pods" | _] = pods,
             ["get", "events" | _],
             ["apply", "-f", closed]
           ] = calls.()

    assert files.(closed) =~ "disable_registration = true"

    assert pods == [
             "get",
             "pods",
             "-n",
             "ehos-acme-dns",
             "-l",
             "app.kubernetes.io/name=acme-dns",
             "--request-timeout=10s",
             "-o",
             ~S'jsonpath={range .items[*].status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}'
           ]
  end

  # ehos-tools#887, T-25: ServiceLB's hostPort took port 53 of every local address, the node's
  # resolver stub on 127.0.0.53 too, and the node resolved no name.
  describe "acme_dns/2 on port 53 of the nodes' own addresses" do
    test "names each node's IPv4 InternalIP as the DNS Service's external IPs, past kubectl's warning" do
      held = %{@host => @account} |> Jason.encode!() |> Base.encode64()

      {calls, files} =
        record(
          fn
            ["get", "secret", "ehos-acme-dns" | _] -> {held, 0}
            _other -> {"", 0}
          end,
          {"Warning: a line first\n10.0.0.5 fd00::5 10.0.0.6 10.0.0.5", 0}
        )

      assert PublicCertificates.acme_dns(@target, image: @image) == {:ok, @account["fulldomain"]}
      assert [_secret, @addresses_read, ["apply", "-f", closed] | _] = calls.()

      documents = YamlElixir.read_all_from_string!(files.(closed))

      assert %{"spec" => dns} =
               Enum.find(
                 documents,
                 &match?(%{"kind" => "Service", "metadata" => %{"name" => "acme-dns"}}, &1)
               )

      assert dns["type"] == "ClusterIP"
      assert dns["externalIPs"] == ["10.0.0.5", "10.0.0.6"]
      assert Enum.map(dns["ports"], &{&1["port"], &1["protocol"]}) == [{53, "UDP"}, {53, "TCP"}]

      # Nothing in the manifest takes a port of the node, which would be every local address.
      for %{"kind" => kind} = document <- documents, kind in ["Service", "Deployment"] do
        refute document["spec"]["type"] in ["LoadBalancer", "NodePort"]
        pod = get_in(document, ["spec", "template", "spec"]) || %{}
        refute pod["hostNetwork"]

        for container <- pod["containers"] || [], port <- container["ports"] || [] do
          refute Map.has_key?(port, "hostPort")
        end
      end
    end

    test "says the nodes name no address of their own, and applies nothing" do
      {calls, _files} = record(fn _args -> {"", 0} end, {"fd00::5", 0})

      assert PublicCertificates.acme_dns(@target, image: @image) ==
               {:error,
                "The nodes name no IPv4 address of their own (status.addresses, InternalIP)"}

      assert [["get", "secret" | _], @addresses_read] = calls.()
    end

    test "says what kubectl said when it cannot read the nodes" do
      record(fn _args -> {"", 0} end, {"The connection to the server was refused", 1})

      assert PublicCertificates.acme_dns(@target, image: @image) ==
               {:error,
                "`kubectl` failed with exit status 1:\nThe connection to the server was refused"}
    end
  end

  # ehos-tools#887: replacing a pod that waits for its image only speeds the rollout up.
  test "acme_dns/2 waits for the rollout when ServiceLB's pod or a waiting pod cannot be handled" do
    held = %{@host => @account} |> Jason.encode!() |> Base.encode64()

    {calls, _files} =
      record(fn
        ["get", "secret", "ehos-acme-dns" | _] -> {held, 0}
        @svclb_gone -> {"error: no matching resources found", 1}
        @pending -> {"error: the server was unable to return a response in the time allotted", 1}
        _other -> {"", 0}
      end)

    assert PublicCertificates.acme_dns(@target, image: @image) == {:ok, @account["fulldomain"]}

    assert [_secret, @addresses_read, ["apply" | _], @svclb_gone, @pending, ["rollout" | _] | _] =
             calls.()
  end

  describe "acme_dns/2 when acme-dns's image cannot be pulled" do
    @events [
      "get",
      "events",
      "-n",
      "ehos-acme-dns",
      "--field-selector",
      "involvedObject.kind=Pod,reason=Failed",
      "--sort-by=.lastTimestamp",
      "--request-timeout=10s",
      "-o",
      ~S'jsonpath={range .items[*]}{.message}{"\n"}{end}'
    ]

    test "says the server cannot resolve the registry's name, not that the credential is wrong" do
      events = """
      W1111 10:00:00 a warning
      Failed to pull image "#{@image}": failed to pull and unpack image "#{@image}": failed to resolve reference "#{@image}": failed to do request: Head "https://ghcr.io/v2/empoweredhouse/acme-dns/manifests/sha256:cd": dial tcp: lookup ghcr.io: Try again
      Error: ErrImagePull
      """

      {calls, files} =
        record(fn
          ["get", "secret", "ehos-acme-dns" | _] -> {"", 0}
          ["rollout" | _] -> {"error: timed out waiting for the condition", 1}
          ["get", "pods" | _] -> {"ErrImagePull\n", 0}
          @events -> {events, 0}
          _other -> {"", 0}
        end)

      assert PublicCertificates.acme_dns(@target, image: @image) ==
               {:error,
                "acme-dns's pod cannot pull its image: the server cannot resolve ghcr.io " <>
                  "(lookup ghcr.io: Try again). The pull credential is not the cause. On the " <>
                  "server, run resolvectl query ghcr.io, and make sure that the server's DNS " <>
                  "resolver answers. Then run the command again"}

      # Registration is closed again in the manifest, without a second rollout, as for a refused
      # credential.
      assert [
               _secret,
               @addresses_read,
               _open,
               @svclb_gone,
               @pending,
               ["rollout" | _],
               _pods,
               @events,
               ["apply", "-f", closed]
             ] =
               calls.()

      assert files.(closed) =~ "disable_registration = true"
    end

    test "names the resolver Go asked, when it said one" do
      record(fn
        ["get", "secret", "ehos-acme-dns" | _] ->
          {"", 0}

        ["rollout" | _] ->
          {"timed out", 1}

        ["get", "pods" | _] ->
          {"ImagePullBackOff\n", 0}

        @events ->
          {~s(Failed to pull image "x": dial tcp: lookup ghcr.io on 127.0.0.53:53: server misbehaving\n),
           0}

        _other ->
          {"", 0}
      end)

      assert {:error, message} = PublicCertificates.acme_dns(@target, image: @image)
      assert message =~ "(lookup ghcr.io on 127.0.0.53:53: server misbehaving)"
    end

    test "says the credential when GHCR refused it" do
      record(fn
        ["get", "secret", "ehos-acme-dns" | _] ->
          {"", 0}

        ["rollout" | _] ->
          {"timed out", 1}

        ["get", "pods" | _] ->
          {"ImagePullBackOff\n", 0}

        @events ->
          {~s(Failed to pull image "x": unexpected status from HEAD request: 401 Unauthorized\n),
           0}

        _other ->
          {"", 0}
      end)

      assert {:error,
              "acme-dns's pod cannot pull its image from GHCR, where it is a private " <> _} =
               PublicCertificates.acme_dns(@target, image: @image)
    end
  end

  describe "earlier_service_removed/1" do
    @service_read [
      "get",
      "service",
      "acme-dns",
      "-n",
      "ehos-acme-dns",
      "--ignore-not-found",
      "--request-timeout=10s",
      "-o",
      "jsonpath={.spec.type}"
    ]

    test "removes acme-dns's Service of type LoadBalancer, past kubectl's warning" do
      for read <- ["Warning: a line first\nLoadBalancer", "LoadBalancer\nWarning: a line after"] do
        {calls, _files} = record(fn _args -> {read, 0} end)

        assert PublicCertificates.earlier_service_removed(@target) == :ok

        assert calls.() == [
                 @service_read,
                 ["delete", "service", "acme-dns", "-n", "ehos-acme-dns", "--timeout=60s"],
                 @svclb_gone
               ]
      end
    end

    test "removes it whatever the wait for ServiceLB's pod answers" do
      {calls, _files} =
        record(fn
          @service_read -> {"LoadBalancer", 0}
          @svclb_gone -> {"error: timed out waiting for the condition", 1}
          _delete -> {"", 0}
        end)

      assert PublicCertificates.earlier_service_removed(@target) == :ok
      assert [@service_read, ["delete" | _], @svclb_gone] = calls.()
    end

    test "says what to check when the Service is not gone, and waits for nothing" do
      {calls, _files} =
        record(fn
          @service_read -> {"LoadBalancer", 0}
          _delete -> {"error: timed out waiting for the condition", 1}
        end)

      assert PublicCertificates.earlier_service_removed(@target) ==
               {:error,
                "`kubectl` failed with exit status 1:\nerror: timed out waiting for the condition" <>
                  "\nacme-dns's Service of type LoadBalancer is not gone. k3s's ServiceLB removes " <>
                  "it once it has removed its own pod for it. Make sure that k3s runs ServiceLB. " <>
                  "`kubectl -n ehos-acme-dns get service acme-dns -o yaml` shows its finalizers. " <>
                  "Then run the command again"}

      assert [@service_read, ["delete" | _]] = calls.()
    end

    test "leaves a Service of another type, or none" do
      for type <- ["ClusterIP", ""] do
        {calls, _files} = record(fn _args -> {type, 0} end)
        assert PublicCertificates.earlier_service_removed(@target) == :ok
        assert calls.() == [@service_read]
      end
    end

    test "says what kubectl said when it cannot read the Service" do
      record(fn _args -> {"The connection to the server was refused", 1} end)

      assert PublicCertificates.earlier_service_removed(@target) ==
               {:error,
                "`kubectl` failed with exit status 1:\nThe connection to the server was refused"}
    end
  end

  describe "pull_credential/2" do
    @held_read [
      "get",
      "secret",
      "ehos-pull-credential",
      "-n",
      "ehos-system",
      "--ignore-not-found",
      "--request-timeout=10s",
      "-o",
      "jsonpath={.data.\\.dockerconfigjson}"
    ]
    @held Base.encode64(~s({"auths":{"ghcr.io":{"auth":"b2N0b2NhdDp0b2tlbg=="}}}))
    # acme-dns.yaml's Namespace, restricted: applied by its name alone, the credential's
    # server-side apply would remove the labels the manifest's client-side apply set.
    @namespace %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{
        "name" => "ehos-acme-dns",
        "labels" => %{
          "pod-security.kubernetes.io/enforce" => "restricted",
          "pod-security.kubernetes.io/audit" => "restricted",
          "pod-security.kubernetes.io/warn" => "restricted"
        }
      }
    }

    test "writes the credential from the token given, with acme-dns's whole namespace" do
      {calls, files} = record(fn _args -> {"", 0} end)

      assert PublicCertificates.pull_credential(@target, {"octocat", "ghp_token"}) == :ok

      assert [["apply", "--server-side", "--force-conflicts", "-f", path], ["annotate" | _]] =
               calls.()

      assert %{"items" => [namespace, secret]} = Jason.decode!(files.(path))
      assert namespace == @namespace

      auth = Base.encode64("octocat:ghp_token")

      assert secret == %{
               "apiVersion" => "v1",
               "kind" => "Secret",
               "type" => "kubernetes.io/dockerconfigjson",
               "metadata" => %{"name" => "ehos-pull-credential", "namespace" => "ehos-acme-dns"},
               "data" => %{
                 ".dockerconfigjson" =>
                   Base.encode64(
                     Jason.encode!(%{
                       "auths" => %{"ghcr.io" => %{"username" => "octocat", "auth" => auth}}
                     })
                   )
               }
             }
    end

    test "copies the credential ehos-system holds when no token is given, with acme-dns's whole namespace" do
      {calls, files} =
        record(fn
          @held_read -> {"Warning: a line first\n" <> @held, 0}
          _args -> {"", 0}
        end)

      assert PublicCertificates.pull_credential(@target, nil) == :ok

      assert [@held_read, ["apply", "--server-side", "--force-conflicts", "-f", path] | _] =
               calls.()

      assert Jason.decode!(files.(path)) == %{
               "apiVersion" => "v1",
               "kind" => "List",
               "items" => [@namespace, Install.pull_secret("ehos-acme-dns", @held)]
             }
    end

    test "says the token is needed when ehos-system holds no credential" do
      record(fn _args -> {"", 0} end)

      assert PublicCertificates.pull_credential(@target, nil) ==
               {:error,
                "acme-dns's image is in a private GHCR package, and ehos-system holds no pull " <>
                  "credential to copy: set GHCR_TOKEN to a classic GitHub token with read:packages"}
    end

    # A jsonpath error makes kubectl print the whole Secret, the credential in it.
    test "says that kubectl cannot read the credential, without what it printed" do
      record(fn @held_read -> {"The connection to the server was refused", 1} end)

      assert PublicCertificates.pull_credential(@target, nil) ==
               {:error,
                "kubectl could not read the pull credential ehos-system/ehos-pull-credential " <>
                  "(exit status 1). Its output is left out, since it can hold the credential."}
    end
  end

  describe "account_keys/1" do
    test "makes each RSA key cert-manager does not hold, and keeps the one it does" do
      {calls, files} =
        record(fn
          ["get", "secret", "ehos-acme-console" | _] -> {"secret/ehos-acme-console", 0}
          _other -> {"", 0}
        end)

      assert PublicCertificates.account_keys(@target) == :ok

      assert [
               ["get", "secret", "ehos-acme-console", "-n", "cert-manager" | _],
               ["get", "secret", "ehos-acme-addresses", "-n", "cert-manager" | _],
               ["apply", "--server-side", "--force-conflicts", "-f", secret],
               ["annotate", "secret", "ehos-acme-addresses", "-n", "cert-manager" | _]
             ] = calls.()

      %{"items" => [%{"metadata" => %{"name" => "cert-manager"}}, key]} =
        Jason.decode!(files.(secret))

      assert key["metadata"] == %{"name" => "ehos-acme-addresses", "namespace" => "cert-manager"}

      [entry] = key["data"]["tls.key"] |> Base.decode64!() |> :public_key.pem_decode()
      rsa = :public_key.pem_entry_decode(entry)
      assert elem(rsa, 0) == :RSAPrivateKey
      modulus = elem(rsa, 2)

      assert modulus |> :binary.encode_unsigned() |> byte_size() == 256
    end
  end

  describe "issuers/2" do
    test "applies each issuer that is missing, as Helm's, and reads both accounts" do
      rendered = """
      ---
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: ehos-acme-console
        labels:
          app.kubernetes.io/name: ehos
      spec:
        acme: {}
      ---
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: ehos-acme-addresses
      spec:
        acme: {}
      """

      {calls, files} =
        record(fn
          ["get", "clusterissuer", "ehos-acme-console", "-o" | _] ->
            {"https://acme/acct/1", 0}

          ["get", "clusterissuer", "ehos-acme-addresses", "-o" | _] ->
            {"https://acme/acct/2", 0}

          ["get", "clusterissuer", "ehos-acme-console" | _] ->
            {"clusterissuer/ehos-acme-console", 0}

          ["get", "clusterissuer", "ehos-acme-addresses" | _] ->
            {"", 0}

          _other ->
            {"", 0}
        end)

      assert PublicCertificates.issuers(@target, fn -> {:ok, rendered} end) ==
               {:ok, %{console: "https://acme/acct/1", addresses: "https://acme/acct/2"}}

      assert [
               ["get", "clusterissuer", "ehos-acme-console", "--ignore-not-found", "-o", "name"],
               [
                 "get",
                 "clusterissuer",
                 "ehos-acme-addresses",
                 "--ignore-not-found",
                 "-o",
                 "name"
               ],
               ["apply", "--server-side", "--field-manager=helm", "-f", issuer],
               [
                 "wait",
                 "--for=condition=Ready",
                 "clusterissuer/ehos-acme-console",
                 "--timeout=3m"
               ],
               ["get", "clusterissuer", "ehos-acme-console", "-o", "jsonpath={.status.acme.uri}"],
               ["wait", "--for=condition=Ready", "clusterissuer/ehos-acme-addresses" | _],
               [
                 "get",
                 "clusterissuer",
                 "ehos-acme-addresses",
                 "-o",
                 "jsonpath={.status.acme.uri}"
               ]
             ] = calls.()

      assert Jason.decode!(files.(issuer))["metadata"] == %{
               "name" => "ehos-acme-addresses",
               "labels" => %{"app.kubernetes.io/managed-by" => "Helm"},
               "annotations" => %{
                 "meta.helm.sh/release-name" => "ehos",
                 "meta.helm.sh/release-namespace" => "ehos-system"
               }
             }
    end

    test "renders nothing when both issuers are there" do
      record(fn
        ["get", "clusterissuer", _name, "--ignore-not-found" | _] -> {"clusterissuer/x", 0}
        ["get", "clusterissuer", _name, "-o" | _] -> {"https://acme/acct/1", 0}
        _other -> {"", 0}
      end)

      assert {:ok, _accounts} =
               PublicCertificates.issuers(@target, fn -> flunk("rendered the chart") end)
    end

    test "refuses a chart that renders no ACME issuers" do
      record(fn _args -> {"", 0} end)

      assert PublicCertificates.issuers(@target, fn -> {:ok, "kind: ConfigMap\n"} end) ==
               {:error,
                "EHOS's chart renders no ACME ClusterIssuers: it is older than EHOS 0.26.0"}
    end
  end

  test "chart_values/1 gives Let's Encrypt unless told, acme-dns's API and the solver's image" do
    assert PublicCertificates.chart_values(solver_image: "quay.io/solver@sha256:aa") == [
             "--set",
             "publicCertificates.enabled=true",
             "--set",
             "publicCertificates.server=https://acme-v02.api.letsencrypt.org/directory",
             "--set",
             "publicCertificates.console.acmeDNS.host=http://acme-dns-api.ehos-acme-dns.svc.cluster.local:8080",
             "--set",
             "publicCertificates.addresses.solverImage=quay.io/solver@sha256:aa"
           ]

    assert PublicCertificates.chart_values(
             solver_image: "s",
             server: "https://pebble:14000/dir",
             ca_bundle: "/tmp/ca.crt"
           ) == [
             "--set",
             "publicCertificates.enabled=true",
             "--set",
             "publicCertificates.server=https://pebble:14000/dir",
             "--set",
             "publicCertificates.console.acmeDNS.host=http://acme-dns-api.ehos-acme-dns.svc.cluster.local:8080",
             "--set",
             "publicCertificates.addresses.solverImage=s",
             "--set-file",
             "publicCertificates.caBundle=/tmp/ca.crt"
           ]
  end

  test "chart_values/1 gives the records' values, for the governance plane (eh-os D-162)" do
    records = %{
      address: "203.0.113.10",
      challenge: "4f2c._acme-dns.ehos.client.example",
      console_account: "https://acme-v02.api.letsencrypt.org/acme/acct/1",
      addresses_account: "https://acme-v02.api.letsencrypt.org/acme/acct/2"
    }

    assert ["--set-json", "publicCertificates.records=" <> json] =
             PublicCertificates.chart_values(solver_image: "s", records: records) |> Enum.take(-2)

    assert Jason.decode!(json) == %{
             "address" => "203.0.113.10",
             "challenge" => "4f2c._acme-dns.ehos.client.example",
             "consoleAccount" => "https://acme-v02.api.letsencrypt.org/acme/acct/1",
             "addressesAccount" => "https://acme-v02.api.letsencrypt.org/acme/acct/2"
           }
  end

  test "roots/0 holds Let's Encrypt's two roots, ISRG Root X1 and X2" do
    fingerprints =
      for {:Certificate, der, _} <-
            PublicCertificates.roots() |> File.read!() |> :public_key.pem_decode(),
          do: :crypto.hash(:sha256, der) |> Base.encode16()

    assert fingerprints == [
             "96BCEC06264976F37460779ACF28C5A7CFE8A3C0AAE11A8FFCEE05C0BDDF08C6",
             "69729B8E15A86EFC177A57AFB7171DFC64ADD28C2FCA8CF1507E34453CCB1470"
           ]
  end

  # Answers each kubectl call with `answer`, given its arguments after the context, and returns a
  # function that lists them, and one that reads a file a call applied, as it was then. The nodes'
  # addresses are `addresses`'s answer.
  defp record(answer, addresses \\ {"10.0.0.5", 0}) do
    {:ok, agent} = Agent.start_link(fn -> {[], %{}} end)

    stub(CommandRunnerMock, :run, fn "kubectl", ["--context", "ehos-trial" | args] ->
      files =
        for arg <- args,
            String.starts_with?(arg, System.tmp_dir!()),
            File.regular?(arg),
            into: %{},
            do: {arg, File.read!(arg)}

      Agent.update(agent, fn {calls, kept} -> {[args | calls], Map.merge(kept, files)} end)
      if args == @addresses_read, do: addresses, else: answer.(args)
    end)

    {fn -> agent |> Agent.get(&elem(&1, 0)) |> Enum.reverse() end,
     fn path -> agent |> Agent.get(&elem(&1, 1)) |> Map.fetch!(path) end}
  end
end

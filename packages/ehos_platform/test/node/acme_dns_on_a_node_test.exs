defmodule EhosPlatform.AcmeDnsOnANodeTest do
  # ehos-tools#887, T-25: acme-dns on a k3s node that resolves through a local stub, as an Ubuntu
  # server that `ehosctl server up` made does. ServiceLB's hostPort took port 53 of every local
  # address, the stub on 127.0.0.53 too, and the node then resolved no name: containerd pulled no
  # image. A k3d node does not resolve through a local stub, so this runs on a node of its own:
  # the `acme-dns on a node` workflow installs k3s on an Ubuntu runner, whose resolver is
  # systemd-resolved's stub, and runs `mix test --only node`. It is excluded elsewhere.
  use ExUnit.Case, async: false

  alias EhosPlatform.DnsImpl
  alias EhosPlatform.DomainRecords
  alias EhosPlatform.Install
  alias EhosPlatform.PublicCertificates
  alias EhosPlatform.Source

  @moduletag :node
  @moduletag :tmp_dir
  @moduletag timeout: :timer.minutes(12)

  @host "ehos.client.example"
  # BusyBox's nc, from the image acme-dns's own is built on (packaging/acme-dns/Dockerfile).
  @probe_image "alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f"
  @stub {127, 0, 0, 53}
  # ServiceLB's pods for acme-dns's Service.
  @svclb [
    "get",
    "pods",
    "-n",
    "kube-system",
    "-l",
    "svccontroller.k3s.cattle.io/svcname=acme-dns",
    "-o",
    "name"
  ]

  setup_all do
    kubeconfig = System.fetch_env!("KUBECONFIG")

    target = %Install{
      context: "default",
      kubeconfig: kubeconfig,
      host: @host,
      source: Source.checkout(File.cwd!()),
      progress: &IO.puts/1
    }

    # The node resolves through the stub, or this test proves nothing.
    assert File.read!("/etc/resolv.conf") =~ ~r/^nameserver 127\.0\.0\.53$/m
    assert resolves_through_stub?("github.com")

    %{target: target}
  end

  # No comma in the name: the test's directory is named after it, and kubectl's `-f` splits at one.
  test "acme-dns answers on port 53 of the node's address and gives the node's stub back",
       %{target: target, tmp_dir: dir} do
    token = {System.fetch_env!("GHCR_USERNAME"), System.fetch_env!("GHCR_TOKEN")}
    assert PublicCertificates.pull_credential(target, token) == :ok

    # The Service as an earlier ehos_platform made it, as on the server where #887 was found:
    # ServiceLB's port 53 takes the stub, and the node resolves no name.
    kubectl!(["apply", "-f", earlier_service!(dir)])
    assert eventually(fn -> not resolves_through_stub?("github.com") end)

    # When it runs again, the installer changes the Service in place, and acme-dns's own image
    # is pulled through the node's resolver.
    assert {:ok, "" <> _challenge} = PublicCertificates.acme_dns(target)

    assert eventually(fn -> kubectl!(@svclb) == "" end)
    # Long enough for any rule a pod's port adds to be in place.
    Process.sleep(:timer.seconds(15))
    assert kubectl!(@svclb) == ""

    assert resolves_through_stub?("github.com")
    assert {_out, 0} = System.cmd("getent", ["hosts", "ghcr.io"])

    address =
      kubectl!([
        "get",
        "nodes",
        "-o",
        ~S'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'
      ])

    assert DomainRecords.acme_dns_answers(@host, address, dns: DnsImpl) == :ok
  end

  # eh-os#1486: acme-dns's API registers and updates the TXT record Let's Encrypt reads for the
  # console's certificate, so its network rule admits cert-manager's controller alone. Each probe
  # is a pod that waits out the moment before its network rules apply, then tries the API's port.
  test "acme-dns's API admits cert-manager's controller and no other pod",
       %{target: target} do
    token = {System.fetch_env!("GHCR_USERNAME"), System.fetch_env!("GHCR_TOKEN")}
    assert PublicCertificates.pull_credential(target, token) == :ok
    assert {:ok, "" <> _challenge} = PublicCertificates.acme_dns(target)

    elsewhere = "acme-dns-probe-#{System.unique_integer([:positive])}"
    kubectl!(["create", "namespace", elsewhere])
    on_exit(fn -> System.cmd("kubectl", ["delete", "namespace", elsewhere, "--wait=false"]) end)

    # cert-manager itself is not installed here: its namespace, and pods with its labels, stand in.
    System.cmd("kubectl", ["create", "namespace", "cert-manager"], stderr_to_stdout: true)

    controller = %{
      "app.kubernetes.io/name" => "cert-manager",
      "app.kubernetes.io/component" => "controller"
    }

    webhook = %{controller | "app.kubernetes.io/component" => "webhook"}

    assert probe_api("cert-manager", controller) == "reached"
    assert probe_api("cert-manager", webhook) == "blocked"
    assert probe_api(elsewhere, controller) == "blocked"
    assert probe_api(elsewhere, %{}) == "blocked"
  end

  # `reached` or `blocked`: a TCP connection to the API's Service, tried for 3 seconds by a pod with
  # `labels` in `namespace` after 10 seconds, so its own rules and the API's are in place.
  defp probe_api(namespace, labels) do
    name = "acme-dns-probe-#{System.unique_integer([:positive])}"

    kubectl!(
      ["run", name, "-n", namespace, "--restart=Never", "--image=#{@probe_image}"] ++
        labels_flag(labels) ++
        [
          "--command",
          "--",
          "sh",
          "-c",
          "sleep 10; if nc -z -w 3 acme-dns-api.ehos-acme-dns.svc.cluster.local 8080; " <>
            "then echo reached; else echo blocked; fi"
        ]
    )

    kubectl!([
      "wait",
      "-n",
      namespace,
      "--for=jsonpath={.status.phase}=Succeeded",
      "pod/#{name}",
      "--timeout=3m"
    ])

    answer = kubectl!(["logs", "-n", namespace, name]) |> String.split("\n") |> List.last()
    kubectl!(["delete", "pod", "-n", namespace, name, "--wait=false"])
    answer
  end

  defp labels_flag(labels) when labels == %{}, do: []

  defp labels_flag(labels),
    do: ["--labels=" <> Enum.map_join(labels, ",", fn {key, value} -> "#{key}=#{value}" end)]

  defp earlier_service!(dir) do
    service = %{
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => %{"name" => "acme-dns", "namespace" => "ehos-acme-dns"},
      "spec" => %{
        "type" => "LoadBalancer",
        "selector" => %{"app.kubernetes.io/name" => "acme-dns"},
        "ports" => [
          %{"name" => "dns-udp", "port" => 53, "targetPort" => "dns-udp", "protocol" => "UDP"},
          %{"name" => "dns-tcp", "port" => 53, "targetPort" => "dns-tcp", "protocol" => "TCP"}
        ]
      }
    }

    path = Path.join(dir, "earlier-service.json")
    File.write!(path, Jason.encode!(service))
    path
  end

  defp kubectl!(args) do
    # kubectl's notes, such as "No resources found", go to stderr, outside the answer.
    {out, 0} = System.cmd("kubectl", args)
    String.trim(out)
  end

  # Whether `check` turns true within 2 minutes.
  defp eventually(check, tries \\ 60) do
    cond do
      check.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(2_000)
        eventually(check, tries - 1)
    end
  end

  defp resolves_through_stub?(name) do
    match?(
      {:ok, _message},
      :inet_res.resolve(String.to_charlist(name), :in, :a,
        nameservers: [{@stub, 53}],
        timeout: 5_000
      )
    )
  end
end

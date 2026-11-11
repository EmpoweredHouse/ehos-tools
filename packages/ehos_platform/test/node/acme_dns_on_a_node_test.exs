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

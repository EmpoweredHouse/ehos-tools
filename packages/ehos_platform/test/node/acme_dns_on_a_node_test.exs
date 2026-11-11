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
  @moduletag timeout: :timer.minutes(10)

  @host "ehos.client.example"
  @stub {127, 0, 0, 53}

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

  test "acme-dns answers on port 53 of the node's address, and the node's stub keeps resolving",
       %{target: target} do
    token = {System.fetch_env!("GHCR_USERNAME"), System.fetch_env!("GHCR_TOKEN")}
    assert PublicCertificates.pull_credential(target, token) == :ok

    # Its own image is pulled through the node's resolver, after the Service is applied.
    assert {:ok, "" <> _challenge} = PublicCertificates.acme_dns(target)

    # Long enough for any rule a pod's port adds to be in place.
    Process.sleep(:timer.seconds(15))

    assert resolves_through_stub?("github.com")
    assert {_out, 0} = System.cmd("getent", ["hosts", "ghcr.io"])

    {address, 0} =
      System.cmd("kubectl", [
        "get",
        "nodes",
        "-o",
        ~S'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'
      ])

    assert DomainRecords.acme_dns_answers(@host, String.trim(address), dns: DnsImpl) == :ok
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

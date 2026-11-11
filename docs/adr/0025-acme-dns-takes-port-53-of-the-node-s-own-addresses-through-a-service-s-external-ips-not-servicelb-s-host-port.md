---
status: accepted
date: 2026-11-11
decision-makers: [emil]
consulted: []
---

# T-25 · acme-dns takes port 53 of the nodes' own addresses through its Service's external IPs, not through ServiceLB's host port

## Context and problem statement

On an installation with public certificates, Let's Encrypt asks acme-dns for the console's DNS-01
record on port 53 of the server's public address
([eh-os D-158](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0158-an-installation-at-a-domain-of-the-company-s-own-serves-the-console-and-every-address-under-certificates-from-a-public-acme-issuer-and-one-on-sslip-io-moves-there-once.md)).
Until now `packages/ehos_platform/priv/manifests/acme-dns.yaml` gave acme-dns a Service of type
`LoadBalancer`, which k3s's ServiceLB serves with a pod whose `hostPort` is 53. The CNI `portmap`
plugin makes that `hostPort` a DNAT rule for every local address of the node, also in the
`OUTPUT` chain (`-m addrtype --dst-type LOCAL`), since the pod names no `hostIP` and ServiceLB
gives no way to name one.

On Ubuntu, `/etc/resolv.conf` names `127.0.0.53`, the stub of systemd-resolved, and that is a local
address too. On the first move of a real installation to public certificates, on a server on
Oracle Cloud that `ehosctl server up` made, the rule sent every lookup of the node to acme-dns,
which answers for its own zone alone. From then on the node resolved no name: containerd could pull
no image, acme-dns's own included, and `install` blamed the GHCR token
([#887](https://github.com/EmpoweredHouse/ehos-tools/issues/887)). CI did not see it, since a k3d
node does not resolve through a local stub.

acme-dns must answer on port 53 of the address Let's Encrypt reaches, and leave every other
address of the node alone. The fix must reach a server that exists, by `ehosctl install` run
again, since the server's cloud-init document runs on its first boot alone.

## Decision drivers

- The node's own resolver keeps answering, whatever it is: a stub on a loopback address, or a
  resolver on another local address.
- An existing server is fixed by running `install` again, with no change on the server by hand.
- acme-dns keeps the restricted Pod Security profile, runs as a user that is not root with no
  capability, and stays behind its NetworkPolicy, which admits its API from cert-manager alone.
- A cluster with more than one node keeps working: the record points at the server's address,
  which is one node's.
- Nothing new to install or keep: k3s as `ehosctl server up` installs it.

## Considered options

1. A `ClusterIP` Service whose `externalIPs` are the nodes' `InternalIP` addresses, which the
   installer reads from the nodes when it applies the manifest.
2. acme-dns on the node's network (`hostNetwork: true`), listening on the node's address alone.
3. The server's resolver pointed past the stub: `/etc/resolv.conf` linked to
   `/run/systemd/resolve/resolv.conf` by the cloud-init document, with the `LoadBalancer` Service
   kept.
4. The `LoadBalancer` Service kept, with acme-dns on another port, and the provider's firewall
   forwarding port 53 to it.

## Decision outcome

Chosen option: **"A `ClusterIP` Service whose `externalIPs` are the nodes' `InternalIP`
addresses"**, because kube-proxy matches its rules on the destination address, so only a packet
sent to a node's own address on port 53 reaches acme-dns, and the stub on `127.0.0.53` and any
other local address are left alone. It keeps acme-dns's pod as it is, and `install` run again
repairs a server that has the problem: before it pulls any image, it deletes acme-dns's Service
when that Service is of type `LoadBalancer`, so k3s's service controller removes ServiceLB's pod
and its rule; acme-dns's step then makes the Service again as a `ClusterIP`.

The `InternalIP` is the address the provider delivers the public address's packets to: on Oracle
Cloud, AWS and GCP the public address is translated to the instance's private address before the
packet reaches the node, and on a provider that puts the public address on the interface, it is
that address.

### Consequences

- Good, because the node's resolver is never touched, whatever the image's DNS setup is.
- Good, because a server that exists is fixed by `install` run again, which is how the fix
  reaches the server where #887 was found. `install` removes the earlier `LoadBalancer` Service
  before the prerequisites' rollouts, which could need an image the node cannot pull until then,
  and also on a run without public certificates.
- Good, because acme-dns keeps its Pod Security profile, its user, its NetworkPolicy and its
  `ClusterIP`, which cert-manager and eh-os's cluster tests reach it through.
- Bad, because the Service names the nodes' addresses, read when `install` runs: a node whose
  address changes, or a node added later, is not served until `install` runs again. Mitigation:
  `install`'s check that acme-dns answers on port 53 of the server's public address
  (`EhosPlatform.DomainRecords.acme_dns_answers/3`) says so on the next run, and the Service's
  comment says it.
- Bad, because `externalIPs` is a field a cluster may refuse (the `DenyServiceExternalIPs`
  admission plugin, after CVE-2020-8554). k3s does not enable it, and EHOS installs onto the k3s
  `ehosctl server up` makes. A cluster that refuses it fails `kubectl apply` with the API
  server's reason, which `install` prints.
- Neutral: kube-proxy marks traffic from outside the cluster for masquerade, so acme-dns sees a
  node's address as the client's. acme-dns does not read the client's address for DNS, and its
  NetworkPolicy admits DNS from anywhere.

### Confirmation

- `EhosPlatform.InstallTest` fails if `server/1` does not remove an acme-dns Service of type
  `LoadBalancer` before the steps that pull an image.
- `EhosPlatform.PublicCertificatesTest` renders the manifest and fails if the DNS Service is of
  type `LoadBalancer` or `NodePort`, if any container in the manifest names a `hostPort` or the
  pod `hostNetwork`, or if its `externalIPs` are not the nodes' `InternalIP` addresses the
  installer read.
- The `acme-dns on a node` workflow (`.github/workflows/acme-dns-node.yml`) installs k3s on an
  Ubuntu runner, whose `/etc/resolv.conf` names `127.0.0.53`, and runs
  `EhosPlatform.AcmeDnsOnANodeTest` there: it runs acme-dns through
  `EhosPlatform.PublicCertificates.acme_dns/2`, and fails if the runner can no longer resolve a
  name through its stub, or if acme-dns does not answer on port 53 of the node's address.

## Pros and cons of the options

### A `ClusterIP` Service with the nodes' addresses as `externalIPs`

- Good, because it matches on the destination address alone (driver 1).
- Good, because `install` applies it to an existing server (driver 2).
- Good, because acme-dns's pod does not change (driver 3).
- Good, because every node's address is named (driver 4), and it uses kube-proxy, which k3s runs
  (driver 5).
- Bad, because the addresses are read at install time.
- Bad, because a cluster with `DenyServiceExternalIPs` refuses it.

### acme-dns on the node's network

- Good, because nothing translates the packets, and acme-dns sees Let's Encrypt's address.
- Bad, because a pod on the node's network is outside the restricted and baseline Pod Security
  profiles: the namespace would run privileged pods.
- Bad, because a NetworkPolicy does not hold a pod on the node's network: acme-dns's API, which
  writes the console's record, would listen on the node's own addresses, held only by the
  provider's firewall.
- Bad, because binding port 53 needs `NET_BIND_SERVICE` or a sysctl on the node, and acme-dns's
  `listen` names one address, so the manifest must name the node too.

### The server's resolver pointed past the stub

- Good, because the `LoadBalancer` Service and the manifest stay as they are.
- Bad, because the cloud-init document runs on the first boot alone: a server that exists, the one
  where #887 was found included, keeps the problem until it is made again, or is changed by hand.
- Bad, because ServiceLB's rule still takes port 53 of every local address: any other DNS server
  on the node, now or later, is taken the same way.
- Bad, because it changes eh-os's server module for a property of one manifest of ehos-tools.

### Another port, forwarded to by the provider's firewall

- Good, because no port 53 rule is on the node.
- Bad, because the security lists of Oracle Cloud, and the firewalls of AWS and GCP, admit or drop
  a packet and do not change its port: each provider would need a load balancer of its own.

## More information

Decided under [#887](https://github.com/EmpoweredHouse/ehos-tools/issues/887).

What showed it, on the server: `iptables -t nat` had `OUTPUT -m addrtype --dst-type LOCAL -j
CNI-HOSTPORT-DNAT`, with `--dports 53` sent to ServiceLB's pod; `dig @127.0.0.53 ghcr.io` had no
answer while the Service was there, and answered once it was deleted.

k3s's ServiceLB removes its DaemonSet in `EnsureLoadBalancerDeleted`, which Kubernetes' service
controller calls when a Service is no longer of type `LoadBalancer`
([k3s `pkg/cloudprovider/loadbalancer.go`](https://github.com/k3s-io/k3s/blob/main/pkg/cloudprovider/loadbalancer.go)).

Revisit if EHOS installs onto a cluster that refuses `externalIPs`, or that runs a load balancer of
its own in place of ServiceLB.

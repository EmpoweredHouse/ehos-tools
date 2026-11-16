# ehos_tunnel

A person's database session reaches the database of an application through the data gateway of
EHOS. This package holds what a client and the data gateway must agree on, byte for byte. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

Three programs use it
([eh-os D-180](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0180-the-data-tunnel-s-wire-is-one-package-in-ehos-tools-ehos-tunnel-that-the-data-gateway-eh-os-s-tests-and-ehosctl-share.md)):

- **The data gateway**, in eh-os. It reads the key in a client's certificate, and it uses the
  words and numbers of the protocol.
- **The tests of eh-os.** They open tunnels through the gateway with the client of this package.
- **`ehosctl db connect` and `ehosctl db tunnel`.** They make the session's key, and they open
  tunnels with the client of this package.

The wire itself is
[eh-os D-179](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0179-ehosctl-reaches-the-data-gateway-at-data-host-with-one-websocket-per-connection-proving-its-session-with-a-self-signed-p-256-certificate-for-the-key-it-sent.md).
A client in another language follows that record, not this package.

## What it does

| Module | For |
| --- | --- |
| `EhosTunnel.Key` | The key of a session: an ECDSA key pair on the curve P-256. `public_key/1` gives the `publicKey` that opens a session. `decode_public_key/1` reads one back and refuses any other key. `fingerprint/1` is the SHA-256 of the key. |
| `EhosTunnel.Certificate` | The certificate that a client presents: self-signed by the key of the session. `gateway_ssl_options/0` are the TLS options of the gateway that accept it. |
| `EhosTunnel.Protocol` | The path `/v1/sessions/<id>/tunnel`, the subprotocol `ehos-tunnel.v1`, the refusals before the upgrade, the close codes after it, the end reasons of a session, and the limits on frames and silence. |
| `EhosTunnel.Client` | A port on the loopback address. Each connection to the port goes through a tunnel of its own to the gateway. The client tells its caller why the gateway refused or closed a tunnel. |

The private key stays in memory. The package writes no file, and a crash report shows neither the
key nor the bytes of a tunnel. The local port is on the loopback address, so any process on the
machine can connect to it; the database still asks for the session's password.

## Depending on it

Tags `ehos_tunnel-vX.Y.Z` release the package, each with a GitHub release. Its `CHANGELOG.md`
tells what each release changed. The package is not on Hex: a project depends on the commit that
a tag names, from this repository's subdirectory.

```elixir
{:ehos_tunnel, "~> 0.1.0",
 github: "EmpoweredHouse/ehos-tools",
 sparse: "packages/ehos_tunnel",
 ref: "<the commit ehos_tunnel-v0.1.0 names>"}
```

It needs Erlang's `:public_key`, `:ssl` and `:crypto`, and Mint's WebSocket client. It needs
nothing of EHOS or Phoenix.

## An example

A client opens a session with a new key, then gives a local port to `psql`. The session's answer
gives `tunnel.url`. EHOS gives the gateway CA in PEM as `gatewayCa`, and the client keeps it from
its first login
([eh-os D-181](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0181-the-data-gateway-s-certificate-comes-from-a-ca-the-chart-makes-which-ehosctl-keeps-from-its-first-login-as-it-keeps-the-data-ca.md)).

```elixir
[{:Certificate, ca, :not_encrypted}] = :public_key.pem_decode(gateway_ca_pem)
key = EhosTunnel.Key.generate()
# Open the session with "publicKey" => EhosTunnel.Key.public_key(key).

{:ok, listener} =
  EhosTunnel.ClientImpl.listen(
    url: session["tunnel"]["url"],
    key: key,
    cacerts: [ca],
    on_event: &IO.inspect/1
  )

port = EhosTunnel.ClientImpl.port(listener)
# psql -h 127.0.0.1 -p <port> …
EhosTunnel.ClientImpl.close(listener)
```

The function `on_event` receives each change of a tunnel. For example,
`{:refused, tunnel, %{status: 409, reason: :ended, end_reason: :expired, …}}` tells that the
session expired before the tunnel opened. `{:closed, tunnel, %{code: 4001, end_reason: :revoked}}`
tells that the gateway ended the session, because its person does not have the right any more.
`EhosTunnel.Client` lists each event.

The gateway reads the key of a client like this:

```elixir
{:ok, spki} = EhosTunnel.Certificate.spki(peer_certificate)
EhosTunnel.Key.fingerprint(spki)
```

## Testing a caller

`EhosTunnel.Client` is a behaviour
([T-20](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)).
A caller names `EhosTunnel.ClientImpl` in its code, and its tests replace it with a mock. With
[Hammox](https://hex.pm/packages/hammox):

```elixir
# test/test_helper.exs
Hammox.defmock(MyTool.TunnelClientMock, for: EhosTunnel.Client)
```

`EhosTunnel.Key`, `EhosTunnel.Certificate` and `EhosTunnel.Protocol` use no network, so a test
calls them directly.

## Next steps

- The wire, and why it is so: [eh-os D-179](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0179-ehosctl-reaches-the-data-gateway-at-data-host-with-one-websocket-per-connection-proving-its-session-with-a-self-signed-p-256-certificate-for-the-key-it-sent.md).
- The options and the events of the client: `EhosTunnel.ClientImpl`.

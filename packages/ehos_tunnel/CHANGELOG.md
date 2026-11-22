# Changelog

All notable changes to `ehos_tunnel` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that does starts with **Breaking:**.

## [Unreleased]

### Changed

- A tunnel whose local connection ends now waits up to 6 seconds for the gateway to close it.
  The new `:close_wait` option of `EhosTunnel.ClientImpl` sets the time.
- The tunnel reports the gateway's close with 4001 as `{:closed, tunnel, close}`, with the end
  reason. Before, the tunnel closed at once and reported `{:ended, tunnel}`, also when the database
  ended the connection because the session ended.
- A close with 1000 from the gateway, or no close in the time, is still reported as
  `{:ended, tunnel}`.

### Security

- The tests of `ehos_tunnel` use Plug 1.20.4 in place of 1.20.3. Plug 1.20.3 did not count
  the framing of a multipart part against the `:length` limit of `Plug.Parsers.MULTIPART`
  (EEF-CVE-2026-120287). An application that uses `ehos_tunnel` does not get Plug from it.

## [0.1.0] - 2026-11-16

### Added

- The package: the wire of the data tunnel, as
  [eh-os D-179](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0179-ehosctl-reaches-the-data-gateway-at-data-host-with-one-websocket-per-connection-proving-its-session-with-a-self-signed-p-256-certificate-for-the-key-it-sent.md)
  sets it.
- `EhosTunnel.Key` makes a session's P-256 key, encodes its `publicKey`, reads one back and
  refuses any other key, and gives its SHA-256 fingerprint.
- `EhosTunnel.Certificate` makes the self-signed certificate that a client presents, reads the key
  from a certificate, and gives the TLS options of a gateway that accepts it.
- `EhosTunnel.Protocol` holds the path, the subprotocol `ehos-tunnel.v1`, the refusals and their
  JSON body, the close codes, the end reasons, and the limits on frames and silence.
- `EhosTunnel.Client` opens a tunnel through the gateway for each connection to a local port, and
  tells why the gateway refused or closed one. `EhosTunnel.ClientImpl` implements it.

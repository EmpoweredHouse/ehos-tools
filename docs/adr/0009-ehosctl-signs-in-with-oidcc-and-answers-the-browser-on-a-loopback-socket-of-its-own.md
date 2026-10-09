---
status: accepted
date: 2026-10-09
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-09 · `ehosctl` signs in with oidcc, and answers the browser on a loopback socket of its own

## Context and problem statement

`ehosctl login` is an OpenID Connect relying party
([eh-os D-89](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0089-ehosctl-signs-a-person-in-as-a-public-client-through-a-loopback-redirect-and-gets-each-credential-by-renewal.md),
[eh-os#325](https://github.com/EmpoweredHouse/eh-os/issues/325)). It reads the provider's
discovery document, sends the browser to the authorization endpoint with PKCE, a `state` and a
`nonce`, and receives the code on `http://127.0.0.1:<port>/callback`. It exchanges the code as a
public client, validates the ID token, renews with `resource`, and revokes on `logout`. Each of
these steps is where a hand-written client goes wrong: a `nonce` not compared, an ID token's
signature not checked against the JWKS, an `iss` taken from the wrong place.

`AGENTS.md` asks for a standard, community-proven library over our own code. EHOS's provider is
already tested against one, [oidcc](https://hex.pm/packages/oidcc): `eh_os_contract_auth` signs
people in to an application's pages with it, and EHOS's token endpoint returns an ID token on
renewal because oidcc refuses a renewal without one.

The browser comes back to a listener `ehosctl` runs for one request. That is a second choice:
a web server, or a socket.

## Decision drivers

1. **The protocol's checks are a library's**, the one EHOS is already tested against.
2. **Nothing that runs a web server in the binary** for one request on the loopback address.
3. **Testable without a browser or a network**: against a fake provider on a local port.
4. **Few dependencies**, since each ships inside the binary (T-06).

## Considered options

1. **oidcc, with its `httpc` adapter, and the callback on a `:gen_tcp` socket**
2. **Our own client over Req**, with the ID token checked through JOSE
3. **oidcc, with the callback on Bandit and Plug**

## Decision outcome

Chosen option: **"oidcc, with the callback on a `:gen_tcp` socket"**. The flow's checks are
oidcc's, the library EHOS is tested against (driver 1). The callback needs nothing beyond OTP
(drivers 2 and 4).

- **oidcc** (3.9, Apache-2.0, the Erlang Ecosystem Foundation's) does the following:
  - reads the discovery document, and refuses one whose `issuer` is not the URL it was asked for;
  - builds the authorization URL, with PKCE (`S256`, required), `state` and `nonce`;
  - exchanges the code with no client authentication (`preferred_auth_methods: [:none]`), and
    validates the ID token: its signature against the JWKS, `iss`, `aud`, `azp`, `exp` and the
    `nonce`.
  It speaks HTTP through OTP's own `httpc`. `ehosctl` hands it hostname checking and the
  system's CA certificates, rather than relying on `httpc`'s defaults.
- **Only `https`.** EHOS signs no one in over plain HTTP: its token endpoint refuses every
  request while its issuer is not `https`. So `ehosctl` accepts an installation's address only
  as an `https` origin, a local one included.
- **`EHOSCTL_CA_FILE`** names a PEM file of CA certificates that `ehosctl` trusts besides the
  system's, as `curl --cacert` names one. A local EHOS's certificate comes from a CA of its own,
  such as the k3d cluster's (eh-os D-45, `_build/k3d/ca.crt`), which the system does not trust.
  When a handshake fails, the error names the TLS alert and this variable.
- **What oidcc does not do, `ehosctl` does in one place, `Ehosctl.SignIn`.** oidcc has no
  revocation, so `logout` posts to the `revocation_endpoint` (RFC 7009) itself. A renewal, with
  `resource` in the body (RFC 8707), is posted by `ehosctl` too: EHOS has rotated the refresh
  token by the time it answers, and oidcc refuses an answer whose ID token it cannot check, or
  that has none, which OpenID Connect Core §12.2 allows. The new refresh token would be lost
  with it, and the sign-in with the next renewal. A renewal needs only the credential and the
  refresh token; who the person is was settled at the sign-in. oidcc does not
  receive the browser's redirect, so `ehosctl` checks that redirect's `state` and `iss`
  (RFC 9207) before the code is exchanged.
- **The callback is a `:gen_tcp` socket** on `127.0.0.1`, on a port the kernel picks. It reads
  each request with the VM's own HTTP parser (`packet: :http_bin`). It answers `/callback` with a
  short page and anything else with a 404, and it closes once the one callback it waits for has
  come or five minutes have passed.
- **The browser** is opened with `open` on macOS and `xdg-open` on Linux. The URL is printed as
  well, for a browser on another screen or a command that failed.

### Consequences

- Good, because the ID token's signature, the `nonce` and the issuer are checked by code that is
  widely used and that EHOS's provider is tested against.
- Good, because the listener is a few dozen lines of OTP, bound to the loopback address alone, and
  gone when the command ends.
- Bad, because oidcc brings `jose` and `telemetry` into the binary. Accepted: both are small, and
  `jose` is what checks the signature.
- Bad, because signing in to a local EHOS needs its CA, named by `EHOSCTL_CA_FILE`, and a
  variable that adds a trusted CA is one more thing that could be set wrongly. Accepted: it only
  adds to the system's CAs, as `curl --cacert` does, and the first run against EHOS's own
  provider showed that plain HTTP is not an option. EHOS refuses sign-in without `https`.
- Bad, because the callback's HTTP handling is ours, small as it is. Mitigation: it reads only
  the request line and headers through the VM's parser, never a body, and answers one fixed page.

### Confirmation

- `Ehosctl.SignInTest` refuses an `http` address, and shows that a certificate from the CA
  `EHOSCTL_CA_FILE` names is trusted, and that the error names the variable when it is not.
- `Ehosctl.LoginTest` signs in against a fake provider on a local port (Bypass). It signs the
  ID token with an Ed25519 key, as EHOS does, and shows the following:
  - a wrong `state`, a wrong `iss` and a wrong `nonce` are each refused;
  - the authorization request carries PKCE `S256`, `state` and `nonce`, and neither `prompt=none`
    nor `resource`;
  - the code is exchanged with `client_id=ehosctl` and no client authentication.

## Pros and cons of the options

### oidcc and a `:gen_tcp` socket

- Good, because the library is EHOS's own relying party's, and the socket needs nothing new.
- Bad, because oidcc is a large library of which `ehosctl` uses a part.

### Our own client over Req

- Good, because it would be short, and Req's test adapter would make tests easy. Req is in the
  binary already, as a dependency of Burrito's, so only JOSE would be new.
- Bad, because the checks oidcc makes would be ours to get right and keep right, which is what
  `AGENTS.md` asks us not to do.

### oidcc and Bandit

- Good, because a real web server handles every edge of HTTP.
- Bad, because it puts Bandit, Plug and their dependencies in the binary to answer one GET on the
  loopback address.

## More information

- Decided under Stage 7's plan, step 4, and accepted by Emil on 9 October 2026, on
  [eh-os#325](https://github.com/EmpoweredHouse/eh-os/issues/325).
- oidcc: <https://github.com/erlef/oidcc>. Its use in `eh_os_contract_auth`:
  <https://github.com/EmpoweredHouse/eh-os-contract>.
- RFC 8252 (native applications: the system browser, the loopback redirect), RFC 9207 (`iss` in
  the authorization response), RFC 7009 (revocation), RFC 8707 (`resource`).
- Revisit if oidcc stops being maintained, or if EHOS adds a part of the protocol oidcc does not
  speak.

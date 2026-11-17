# Data sessions

A data session lets a person read or change the database of one application in one environment, for
a limited time. This page tells how `ehosctl` checks the database and the data gateway. It also
tells what to do when the installation changes a CA. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl login https://ehos.example.com     # keeps the data CA and the gateway CA
ehosctl db trust-ca qUiQTy8PR5uPgZdpSzAYSw0u0cHNKh7A+4XSmaGSpEc=
```

## The two CAs that `ehosctl` keeps

A data session uses two connections, and each connection has a certificate from a CA of the
installation:

- The **data CA** signs the certificate of each database. Your database client checks the
  database against it.
- The **gateway CA** signs the certificate of the data gateway. `ehosctl` checks the data gateway
  against it.

`ehosctl login` gets the two CAs from the installation the first time that you sign in on a
computer. `ehosctl` keeps them in `config.json`, beside the installation. They stay when you sign
out. They go when you remove the installation, or when you sign in to it at another address.

At each later sign-in, `ehosctl` takes a CA again only if it has the same key. The installation
renews a certificate with the same key, so a renewal changes nothing for you. A CA with a new key
is not trusted. If a person takes control of the installation, that person cannot give you a false
CA.

An installation that has no data gateway gives no CAs. `ehosctl login` then keeps none, and
signs you in as usual.

## Trust a CA with a new key

If the administrator of the installation replaces the key of a CA, `ehosctl login` tells you:

```text
ehosctl: staging gives a gateway CA with another key than the one ehosctl keeps, so ehosctl does not trust it, and refuses data sessions that use it. …
```

1. Get the fingerprint of the new CA from the administrator of the installation. Get it in a way
   that does not go through EHOS, such as in person or by phone.
2. Run `ehosctl db trust-ca <fingerprint>`.

`ehosctl` asks the installation for its CAs. If one of them has the fingerprint that you typed,
`ehosctl` keeps that CA. It then prints:

```text
ehosctl now trusts the gateway CA of staging with this fingerprint.
```

If no CA has the fingerprint, `ehosctl` keeps the old CA and exits with 1.

A fingerprint is the SHA-256 of the key of the CA. Type it in base64, as EHOS gives it, or in
hexadecimal, with or without colons.

## Background

- [Why a data session goes through a data gateway, and why `ehosctl` keeps the data CA](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0149-a-person-s-database-session-reaches-its-instance-through-a-data-gateway-of-its-own-not-the-governance-plane.md)
- [Why the data gateway has a CA of its own](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0181-the-data-gateway-s-certificate-comes-from-a-ca-the-chart-makes-which-ehosctl-keeps-from-its-first-login-as-it-keeps-the-data-ca.md)

## Next steps

- [Signing in](login.md)
- [Role bindings](role-bindings.md): a data session needs a role that holds the data capabilities
  of the application in the environment.

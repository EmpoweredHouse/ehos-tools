# Installing EHOS on the server

`ehosctl install` installs a release of EHOS on the server of an installation. This page is for the
installation administrator, who made the server with `ehosctl server up`. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

## Install EHOS the first time

```sh
export GHCR_TOKEN=…                         # a classic token with read:packages alone
ehosctl server tunnel --installation acme
ehosctl install --installation acme         # the newest release; --version 0.5.0 for another
ehosctl server invite you@example.com --installation acme   # the first person: the administrator
ehosctl login --installation acme           # signs in, trusting the CA of the installation
```

1. `install` reads the image and the chart from the `release.json` of the release, each by digest.
   You do not copy a digest.
2. `install` installs the prerequisites, the CA of the installation and the chart, through the
   kubeconfig that `tunnel` wrote.
3. When EHOS runs, `ehosctl` keeps the installation in `config.json` under its name, with the
   address of the console and the CA of the installation. `ehosctl login --installation <name>` then
   needs no `EHOSCTL_CA_FILE`.

`install` needs a GitHub token to read the releases of EHOS while they are private. It also needs
`GHCR_TOKEN` on each `install` while the packages of EHOS are private. The cluster pulls the image
of EHOS with it and keeps it after the first install. Helm pulls the chart with it.

## Choose the address of the console

By default, the host of the console is `ehos.<address>.sslip.io`, from the address of the server.
`--host` gives another host. Give it a DNS record that points to the server. A later `install` or
`upgrade` keeps the host that EHOS serves.

If the server gets a new address, `install` refuses to keep an sslip.io host that names the old
address. This occurs, for example, when a server on Oracle moves to a reserved address. Give
`--host` to move the console. The address of each application moves with it.

## Get the certificates from Let's Encrypt

By default, the installation signs its certificates with a CA of its own, and a browser shows a
warning until a person trusts that CA. With `--public-certificates`, the console and each
application get certificates from Let's Encrypt, which every browser trusts. This needs a host of
your company's own, such as `ehos.client.example`, and the company's DNS.

1. Make the server with port 53 open: `ehosctl server up --public-certificates`. Port 53 is where
   Let's Encrypt asks acme-dns, a DNS server on the server, for the certificate of the console.
2. Run `ehosctl install --installation acme --host ehos.client.example --public-certificates`.
   `install` installs the prerequisites and acme-dns, makes the two Let's Encrypt accounts, and
   stops. It prints seven DNS records, each with its value and what it is for.
3. Make the seven records at the DNS of your company. The
   [guide to the records](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#make-the-dns-records-for-public-certificates)
   tells how for each DNS provider.
4. Run the same command again. `install` asks the name servers of your zone for each record. If
   one is missing or wrong, it says what to change, and installs nothing. If each is correct, it
   installs EHOS.

When EHOS runs, `ca.crt` beside the installation holds the roots of Let's Encrypt, for the
`EHOSCTL_CA_FILE` of a pipeline. A later `install` or `upgrade` keeps the public certificates, the
acme-dns account and both account keys, without the flag. If a record changed, it shows a warning.
If acme-dns or a Let's Encrypt account is not ready, it shows a warning and upgrades EHOS. The
console's certificate cannot be renewed until they are ready again.

`install` refuses `--public-certificates`:

- for a host under sslip.io, which is not your company's;
- for a registered domain, such as `client.example`: give a host under it;
- on a server that `up` made without `--public-certificates`;
- on a server where acme-dns does not answer on port 53 from your machine. A server that `up`
  made from an EHOS release before 0.27.0 keeps port 53 closed. Run
  `ehosctl server up --public-certificates` from EHOS 0.27.0 or later.

On an installation that runs with its own CA, `--public-certificates` moves EHOS to the host and
to certificates from Let's Encrypt. The installation answers at its old host until the
certificate of the console for the new host is issued. If the move ends before EHOS answers at
the new host, you can cancel the move: run `install` without `--public-certificates`. `install` then
removes what the move made, except acme-dns and the account keys. It tells how to remove them.

`install` also refuses another `--host` for an installation with public certificates.

## Allow domains of your company

A person can map a domain of your company to a production application, such as
`ledger.client.example`. First, the installation must allow the domain, or a domain above it.

```sh
ehosctl install --allowed-domain client.example --allowed-domain client.co.uk
```

- Give `--allowed-domain` once for each domain. The list replaces the list that EHOS has.
- `--no-allowed-domains` removes all allowed domains. Remove each mapped domain first: EHOS
  refuses a route for a domain that is not allowed.
- `install` and `upgrade` keep the list that EHOS has unless you give another.
- The installation needs public certificates and EHOS 0.27.0 or later.

`install` refuses, before it changes anything:

- a domain on the [Public Suffix List](https://publicsuffix.org), such as `co.uk` or `github.io`,
  because names under it belong to many owners;
- the host of the console, or a name under it;
- a domain that is not in lowercase, or has fewer than two labels. Give an internationalized
  domain as its A-label (`xn--…`).

[Domains of your company](domains.md) says how to map a domain.

## Set how long a sign-in lasts

`--sign-in-absolute` sets how long a sign-in of a person to an application lasts after the person
signs in at EHOS. `--sign-in-idle` sets how long the sign-in lasts when the person does not use it.

- Format: hours or days, such as `30d` or `14d`.
- Defaults: 12 hours and 1 hour.
- Limits: at most 366 days. The idle limit is at most the absolute limit.

`install` and `upgrade` keep the limits that EHOS uses unless you give others. They refuse a wrong
value before they change anything. Raise the limits only when each application runs
`eh_os_contract_auth` 0.4.0 or later.

## Require a second person for a promotion

From EHOS 0.9.0, `--four-eyes` stops the person who deployed a candidate, or asked for its
promotion, from approving that promotion. Use it for an installation of several people.
`--no-four-eyes` lets them approve. EHOS records each such approval as a self-approval.

- A new installation of EHOS 0.14.0 or later runs without four eyes, unless you give `--four-eyes`.
- A new installation before 0.14.0 runs with four eyes.
- From 0.14.0, a reinstall keeps what the installation had. If the chart cannot tell, four eyes are
  on.

`install` and `upgrade` keep the setting that EHOS uses unless you give one of the two flags. This
includes a value that a person set with Helm.

## Send mail from EHOS

`--smtp-host` and `--mail-from` give EHOS the SMTP server that it sends mail through, and the
address that it sends from. With them, the invitations of the console arrive by email. Without them,
a person must pass on each link.

```sh
SMTP_PASSWORD=… ehosctl install --installation acme --smtp-host smtp.example.com \
  --smtp-username ehos --mail-from ehos@example.com
```

- `--smtp-port` is 587 for STARTTLS by default. Give 465 for TLS from the first byte.
- `--smtp-username` is the user that EHOS signs in as. Give `""` for none.
- TLS is always on and verified.
- The host is a DNS name. The sender and the user are printable ASCII.

`install` reads the password of the user from `SMTP_PASSWORD` only, never from an option. It writes
the password into the Secret `ehos-smtp` in `ehos-system`, and the governance plane restarts to use
it. If `SMTP_PASSWORD` is empty, the cluster keeps the password that it holds, but only for the host
and the user that it was given for.

`install` and `upgrade` keep the SMTP server that EHOS uses unless you give other values.
`--no-mail` stops the mail of EHOS. Give the domain of the sender the SPF and DKIM records of its
provider. Without them, mail servers take the mail for spam.

### Give the relay a user

If the SMTP server has no user, `install` and `upgrade` show a warning and continue. If the relay
admits the server by its address, it admits each application on the server. An application that
names the host of the relay under `needs.egress` can then send as anyone in the domain of the
company. Its mail agreement does not stop it. If applications of others run on the installation,
give EHOS a user of the relay. Then make the relay require that user, not the address of the server.

## What install refuses

Before it changes anything, `install` reads the version, the image and the chart from the Helm
release, in its last deployed revision.

- If the same version runs, `install` installs it again. This changes nothing in place.
- If another version runs, `install` refuses. Run `ehosctl upgrade` to move to another version.
- If the same version runs, but its release now names other digests, `install` refuses.
- If EHOS was installed with `mix ehos.install`, `install` cannot read its version and refuses. Run
  `ehosctl upgrade` to move it to a release.
- If a later revision is still pending, an install or upgrade runs or stopped before it ended.
  `install` refuses, and says how to end it.
- If a later revision failed, `install` says so, and installs.

## Next steps

- [Upgrade EHOS](upgrade.md)
- [Invite the first person](server-invite.md)
- [Read what the installation uses](installation.md)

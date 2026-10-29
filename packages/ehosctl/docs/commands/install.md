# Installing EHOS on the server

```sh
export GHCR_TOKEN=…                         # a classic token with read:packages alone
ehosctl server tunnel --installation acme
ehosctl install --installation acme         # the newest release; --version 0.5.0 for another
ehosctl server invite you@example.com --installation acme   # the first person: the administrator
ehosctl login --installation acme           # signs in, trusting the installation's CA
```

`install` takes the release's image and chart from its `release.json`, each by digest, so nobody
copies a digest, and installs the prerequisites, the installation's CA and the chart through the
kubeconfig `tunnel` wrote. The console's host is `ehos.<address>.sslip.io`, from the server's
address, unless `--host` names another. A later `install` or `upgrade` keeps the host EHOS serves,
and refuses to keep one of sslip.io that names an address the server no longer has, as after a
server on Oracle moves to a reserved address (eh-os D-124): `install --host` moves the console, and
every application's address with it. `--sign-in-absolute` and `--sign-in-idle` set how long a
person's sign-in to an application lasts, in hours or days (`30d`, `14d`), from the sign-in at EHOS
and unused (eh-os D-113): 12 hours and 1 hour when not given, at most 366 days, the idle one at most
the absolute one; `install` and `upgrade` keep the ones EHOS runs with unless given others, and
refuse others before anything changes. Raise them only once every application runs
`eh_os_contract_auth` 0.4.0 or later. `--four-eyes` keeps whoever deployed a candidate or asked
for its promotion from approving that promotion, for an installation of several people (eh-os
D-105, from EHOS 0.9.0); `--no-four-eyes` lets them, each approval recorded as a self-approval.
A new installation of EHOS 0.14.0 or later runs without four eyes unless `--four-eyes` is given,
one before 0.14.0 with them, and from 0.14.0 a reinstall keeps what the installation had, with
four eyes on where the chart cannot tell (eh-os D-128). `install` and `upgrade` keep what EHOS
runs with unless one of them is given, a value set by hand with Helm included. Reading eh-os's
releases needs a GitHub token while it is private. `GHCR_TOKEN` is what the cluster pulls EHOS's
image with, kept there after the first install, and what Helm pulls the chart with while EHOS's
packages are private, so it is needed on every `install` until then.

`--smtp-host` and `--mail-from` give EHOS the SMTP server it sends mail through and the address it
sends from (eh-os D-36), so the console's invitations arrive by email instead of as a link passed on
by hand; `--smtp-port` is 587 for STARTTLS unless given (465 is TLS from the first byte), and
`--smtp-username` the user it authenticates as, `""` for none. TLS is always on and verified. The
host is a DNS name, and the sender and the user are printable ASCII. The user's password is read
from `SMTP_PASSWORD` alone, never an option, and written into the Secret `ehos-smtp` in
`ehos-system`, after which the governance plane restarts to use it; without it, the one the cluster
holds is kept, but only for the host and user it was given for. `install` and `upgrade` keep the
server EHOS runs with unless given other values, and `--no-mail` stops sending. The sender's domain
needs the SPF and DKIM records its provider gives, or the mail is taken for spam.

With no user, `install` and `upgrade` warn, and go on: a relay that admits the server by its
address admits every application on it, and one that names the relay's host under `needs.egress`
can send as anyone in the company's domain, around its mail agreement. Where applications other
than the company's own run, give EHOS a relay user and have the relay require it rather than admit
the server by its address (eh-os D-141).

```sh
SMTP_PASSWORD=… ehosctl install --installation acme --smtp-host smtp.example.com \
  --smtp-username ehos --mail-from ehos@example.com
```

The version, the image and the chart are recorded in the Helm release, and read back first, from
its last deployed revision: the version that runs is installed again, and another is refused, since
moving to it is `upgrade`'s. So is the same version whose release now names other digests, and an
EHOS installed with `mix ehos.install`, whose version cannot be read. A later revision still pending
(an install or upgrade running, or one that was interrupted) is refused, and one that failed is
said. Once EHOS runs, the installation is kept in `config.json` under its name, with the console's
address and the installation's CA, so `ehosctl login --installation <name>` needs no
`EHOSCTL_CA_FILE`.

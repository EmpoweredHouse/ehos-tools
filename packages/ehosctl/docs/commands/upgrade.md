# Upgrading EHOS on the server

`ehosctl upgrade` moves EHOS on the server of an installation to another release. This page is for
the installation administrator. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
export GHCR_TOKEN=…                                # as for install
ehosctl server tunnel --installation acme
ehosctl upgrade --installation acme                # to the newest release, after its notes
ehosctl upgrade --installation acme --to 0.6.0     # to the release that --to names
```

## What upgrade does

1. `upgrade` reads what runs, as `install` does.
2. It prints the notes of each release after the one that runs, up to the target, as `changelog`
   prints them.
3. It installs the target, as `install` does.

`upgrade` keeps these settings of the EHOS that runs, unless you give others:

- the host of the console. `--host` gives another. `upgrade` refuses to keep an sslip.io host that
  names an address that the server no longer has.
- the sign-in limits, from EHOS 0.10.0. `--sign-in-absolute` and `--sign-in-idle` give others.
- four eyes on promotions. `--four-eyes` or `--no-four-eyes` change it.
- the SMTP server that EHOS sends mail through. `--smtp-*`, `--mail-from` and `--no-mail` change it.
- the domains of your company that a person can map, from EHOS 0.27.0. `--allowed-domain` and
  `--no-allowed-domains` change them.

[Installing EHOS on the server](install.md) says what each of these settings does.

## What upgrade asks or refuses

Before `upgrade` changes anything:

- It refuses a lower version, unless you give `--allow-downgrade`. Migrations do not run backwards,
  so the older code meets the database that the newer code left.
- If the target is the version that runs, `upgrade` changes nothing. To install it again, run
  `install`, which also takes `--sign-in-*`, `--four-eyes`, `--no-four-eyes`, the mail options
  and the allowed domains.
- It asks first when a release on the way changes the governance database, because EHOS keeps no
  backup of that database. The `release.json` of a release says this with `migrates`. A release that
  does not say counts as a change. `upgrade` also asks before each downgrade.
- `--yes` answers the question. A run with no answer changes nothing.

## Move a server that runs the Traefik of k3s

A server made from the modules of eh-os before 0.15.0 runs the Traefik of k3s, and EHOS installs its
own. `install` and `upgrade` refuse such a server and change nothing, unless you give
`--switch-traefik`. With the flag:

1. `ehosctl` first checks everything that can still refuse the move.
2. It restarts k3s over SSH without its Traefik. The console and its applications stop for about a
   minute.
3. It installs the Traefik of EHOS before the chart.

`--switch-traefik` needs `EHOS_STATE_PASSPHRASE`. It also needs `--ssh-key` if another key made the
server than the key that `ehosctl server up` recorded, or than `~/.ssh/ehos_oci` when it recorded
none.

## Why PostgreSQL clusters restart

After the chart is installed, `install` and `upgrade` compare the pods of each PostgreSQL cluster in
`ehos-system` and `ehos-data` with the cluster. CloudNativePG gives a changed priority class only to
a new pod. So `ehosctl` restarts each cluster whose pods do not run with its class, one at a time.

- A cluster of one instance stops until its new pod is ready, usually 1 to 3 minutes.
- `ehosctl` checks a cluster at most 120 times, 5 seconds apart.
- The console stops while the database of the governance plane restarts. The applications of an
  instance stop while their instance restarts.
- `ehosctl` says this before the first restart, and prints each restart.
- `ehosctl` does not restart a cluster whose pods already match.
- If a cluster is not healthy just before its restart, `ehosctl` does not restart it, and says so.
  The next run restarts it when it is healthy.

## Move an EHOS that has no recorded version

An EHOS installed with `mix ehos.install` recorded no version. `upgrade` compares the digest of its
image with the images of the releases. If one matches, that release runs. If none matches, the EHOS
can be a build of a later commit. `upgrade` then moves it only with `--allow-unrecorded`, after the
question. From then on, EHOS records its version.

## Next steps

- [See what is in use, and what is newer](versions.md)
- [Read what the installation uses](status.md)

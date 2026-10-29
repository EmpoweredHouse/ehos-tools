# Upgrading EHOS on the server

```sh
export GHCR_TOKEN=…                                # as for install
ehosctl server tunnel --installation acme
ehosctl upgrade --installation acme                # to the newest release, after its notes
ehosctl upgrade --installation acme --to 0.6.0     # to the release --to names
```

`upgrade` reads what runs as `install` does, then prints the notes of every release after it up to
the target, as `changelog` prints them, and installs the target as `install` would, on the
console's host the running EHOS serves unless `--host` gives another (one of sslip.io that names an
address the server no longer has is refused, eh-os D-124), with the sign-in limits it runs with
unless `--sign-in-absolute` or `--sign-in-idle` give others (eh-os D-113, from EHOS 0.10.0), four
eyes on promotions as it runs them unless `--four-eyes` or `--no-four-eyes` say otherwise (eh-os
D-105), and the SMTP server it sends mail through unless `--smtp-*`, `--mail-from` or `--no-mail`
say otherwise. Before it changes anything:

- a lower version is refused unless `--allow-downgrade`: migrations do not run backwards, so the
  older code meets the database the newer one left;
- the version that runs changes nothing (`install` installs it again, and takes `--sign-in-*`,
  `--four-eyes`, `--no-four-eyes` and the mail options too);
- when a release on the way changes the governance database, as its `release.json` says with
  `migrates` (or by not saying), and before any downgrade, it asks first, since EHOS keeps no backup
  of that database; `--yes` answers, and a run with no answer changes nothing.

A server made from eh-os modules before 0.15.0 runs k3s's Traefik, and EHOS installs its own (eh-os
D-117). `install` and `upgrade` refuse such a server, changing nothing, unless `--switch-traefik`
is given: then, once what could still refuse has been decided, k3s is restarted over SSH without
its Traefik, which takes the console and its applications down for about a minute, and EHOS's
Traefik is installed before the chart (eh-os#823). It needs `EHOS_STATE_PASSPHRASE`, and
`--ssh-key` when the server was made with a key other than `~/.ssh/ehos_oci`.

An EHOS installed with `mix ehos.install` recorded no version. Its image's digest is matched against
the releases' images, and one that matches runs that release. One that matches none may be a build
of a later commit, so `upgrade` moves it only with `--allow-unrecorded`, after the question, and
records its version from then on.
